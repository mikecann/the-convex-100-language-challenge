#!/usr/bin/pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../Convex.ps1')

$script:AdapterMaximumCommandBytes = 64KB
$script:AdapterReadChunkBytes = 4096
$script:AdapterMaximumEncodedEventBytes = 8MB + 64KB
$script:AdapterOutputBudgetBytes = 18MB
$script:AdapterWriteChunkBytes = 16KB
$script:AdapterWriteDeadlineMilliseconds = 1000
$script:AdapterJsonOptions = [Text.Json.JsonSerializerOptions]::new()
$script:AdapterJsonOptions.MaxDepth = 64

function New-AdapterProtocolException {
    param([string] $Message)
    $errorValue = New-ConvexError -Name ProtocolError -Message $Message
    $exception = [System.Exception]::new($Message)
    $exception.Data['convex'] = $errorValue
    $exception
}

function New-AdapterWriter {
    param($Stream, [scriptblock] $Terminate)
    # stdout and the controller socket use the same ordered bounded writer, so
    # the published output bounds hold in both adapter modes.
    [pscustomobject]@{
        Stream         = $Stream
        Terminate      = $Terminate
        OutputGate     = [object]::new()
        ReservedBytes  = 0L
        Failed         = $false
        FailureMessage = ''
    }
}

function Get-AdapterWriteRemaining {
    param($Timer)
    $remaining = $script:AdapterWriteDeadlineMilliseconds - [int]$Timer.ElapsedMilliseconds
    if ($remaining -le 0) {
        throw [TimeoutException]::new('adapter output write deadline expired')
    }
    $remaining
}

function Write-AdapterEvent {
    param($Writer, [hashtable] $Event)
    if ($Writer.Failed) {
        # A partial record already terminated the stream. Writing again would
        # splice a second event onto a truncated NDJSON line.
        throw [IO.IOException]::new([string]$Writer.FailureMessage)
    }
    # Start the cumulative window before the collection hint below so serializing,
    # writing, and the newline are all charged to the same one-second deadline.
    $timer = [Diagnostics.Stopwatch]::StartNew()
    # HTTP decoding temporarily owns the raw response bytes and JSON text, which
    # are dead once the event graph reaches this function. Ask for a background,
    # non-compacting collection instead: a blocking collect or a finalizer wait
    # cannot be bounded, so it would spend an unaccounted part of the deadline.
    [GC]::Collect(2, [GCCollectionMode]::Optimized, $false, $false)
    if (-not [Threading.Monitor]::TryEnter($Writer.OutputGate, (Get-AdapterWriteRemaining $timer))) {
        throw [TimeoutException]::new('adapter output writer stayed busy past its deadline')
    }
    $reservation = 0L
    $failure = $null
    $pipe = $null
    $serializerStream = $null
    $readerStream = $null
    $serializeCancellation = $null
    $writerCompleted = $false
    try {
        # The gate is held for the whole record, so events are ordered and never
        # interleaved. The reservation covers the retained event graph, bounded
        # pipe segments, one stream chunk, and serializer/task overhead without
        # ever materialising an event-sized byte array. Holding the entire budget
        # keeps this check an active invariant: a leaked reservation fails loudly
        # instead of silently doubling the adapter's output memory.
        if (($Writer.ReservedBytes + $script:AdapterOutputBudgetBytes) -gt $script:AdapterOutputBudgetBytes) {
            throw [IO.IOException]::new('adapter encoded-output byte budget exhausted')
        }
        $reservation = [long]$script:AdapterOutputBudgetBytes
        $Writer.ReservedBytes += $reservation

        $pipe = [IO.Pipelines.Pipe]::new()
        $serializerStream = $pipe.Writer.AsStream($true)
        $readerStream = $pipe.Reader.AsStream($true)
        $serializeCancellation = [Threading.CancellationTokenSource]::new()
        $eventType = $Event.GetType()
        $serializeTask = [Text.Json.JsonSerializer]::SerializeAsync(
            $serializerStream,
            $Event,
            $eventType,
            $script:AdapterJsonOptions,
            $serializeCancellation.Token
        )
        [byte[]]$chunk = [byte[]]::new($script:AdapterWriteChunkBytes)
        $encodedBytes = 0L
        $readTask = $readerStream.ReadAsync($chunk, 0, $chunk.Length)
        while ($true) {
            if (-not $readTask.Wait(20)) {
                if ($serializeTask.IsCompleted -and -not $writerCompleted) {
                    $serializeTask.GetAwaiter().GetResult() | Out-Null
                    $pipe.Writer.Complete()
                    $writerCompleted = $true
                }
                Get-AdapterWriteRemaining $timer | Out-Null
                continue
            }
            $count = $readTask.GetAwaiter().GetResult()
            if ($count -eq 0) {
                break
            }
            $encodedBytes += $count
            if (($encodedBytes + 1L) -gt $script:AdapterMaximumEncodedEventBytes) {
                throw [IO.IOException]::new('adapter event exceeds the 8 MiB encoded-output limit')
            }
            $writeTask = $Writer.Stream.WriteAsync(
                $chunk,
                0,
                $count,
                [Threading.CancellationToken]::None
            )
            if (-not $writeTask.Wait((Get-AdapterWriteRemaining $timer))) {
                throw [TimeoutException]::new('adapter output write deadline expired')
            }
            $writeTask.GetAwaiter().GetResult() | Out-Null
            $readTask = $readerStream.ReadAsync($chunk, 0, $chunk.Length)
            if ($serializeTask.IsCompleted -and -not $writerCompleted) {
                $serializeTask.GetAwaiter().GetResult() | Out-Null
                $pipe.Writer.Complete()
                $writerCompleted = $true
            }
        }
        $serializeTask.GetAwaiter().GetResult() | Out-Null
        [byte[]]$newline = @(10)
        $newlineTask = $Writer.Stream.WriteAsync(
            $newline,
            0,
            1,
            [Threading.CancellationToken]::None
        )
        if (-not $newlineTask.Wait((Get-AdapterWriteRemaining $timer))) {
            throw [TimeoutException]::new('adapter output write deadline expired')
        }
        $newlineTask.GetAwaiter().GetResult() | Out-Null
        $flushTask = $Writer.Stream.FlushAsync()
        if (-not $flushTask.Wait((Get-AdapterWriteRemaining $timer))) {
            throw [TimeoutException]::new('adapter output write deadline expired')
        }
        $flushTask.GetAwaiter().GetResult() | Out-Null
    }
    catch {
        $failure = $_.Exception
        if ($null -ne $serializeCancellation) { $serializeCancellation.Cancel() }
        if ($null -ne $pipe) {
            $pipe.Reader.CancelPendingRead()
            $pipe.Writer.CancelPendingFlush()
        }
        # Terminating the stream abandons any partial NDJSON line and interrupts
        # the outstanding kernel write deterministically. For the controller
        # socket that is disposing the sole connection; for stdin mode it is
        # disposing standard output so nothing can follow the truncated record.
        & $Writer.Terminate
    }
    finally {
        $timer.Stop()
        if ($null -ne $pipe -and -not $writerCompleted) {
            try { $pipe.Writer.Complete() } catch {}
        }
        if ($null -ne $pipe) { try { $pipe.Reader.Complete() } catch {} }
        if ($null -ne $serializerStream) { try { $serializerStream.Dispose() } catch {} }
        if ($null -ne $readerStream) { try { $readerStream.Dispose() } catch {} }
        if ($null -ne $serializeCancellation) { $serializeCancellation.Dispose() }
        try {
            $Writer.ReservedBytes -= $reservation
            if ($Writer.ReservedBytes -ne 0L) {
                throw [InvalidOperationException]::new('adapter output reservation was not released exactly')
            }
        }
        finally {
            [Threading.Monitor]::Exit($Writer.OutputGate)
        }
    }
    if ($null -ne $failure) {
        $Writer.Failed = $true
        $Writer.FailureMessage = "adapter controller output failed within $($script:AdapterWriteDeadlineMilliseconds) ms; reserved output bytes after release: $($Writer.ReservedBytes)"
        [Console]::Error.WriteLine($Writer.FailureMessage)
        throw [IO.IOException]::new($Writer.FailureMessage, $failure)
    }
}

function Write-AdapterFailure {
    param($Writer, [string] $Id, [string] $SubscriptionId, $Exception)
    $errorValue = Get-ConvexError $Exception
    $detail = @{ name = $errorValue.Name; message = $errorValue.Message }
    if ($null -ne $errorValue.Data) {
        $detail['data'] = $errorValue.Data
    }
    $event = @{
        type  = if ($SubscriptionId) { 'subscription' } else { 'error' }
        error = $detail
    }
    if ($Id) {
        $event['id'] = $Id
    }
    if ($SubscriptionId) {
        $event['subscriptionId'] = $SubscriptionId
    }
    [string[]] $logs = @($errorValue.Logs)
    if ($logs.Count -gt 0) {
        $event['logs'] = [string[]]$logs
    }
    Write-AdapterEvent $Writer $event
}

function New-BoundedNdjsonReader {
    param($Stream)
    $bytes = [byte[]]::new($script:AdapterReadChunkBytes)
    [pscustomobject]@{
        Stream   = $Stream
        Bytes    = $bytes
        Builder  = [IO.MemoryStream]::new()
        Lines    = [System.Collections.Generic.Queue[object]]::new()
        Overflow = $false
        Eof      = $false
        ReadTask = $Stream.ReadAsync($bytes, 0, $bytes.Length)
    }
}

function Complete-NdjsonLine {
    param($State)
    if ($State.Overflow) {
        $State.Lines.Enqueue([pscustomobject]@{ Kind = 'overflow'; Text = '' })
    }
    else {
        [byte[]]$lineBytes = $State.Builder.ToArray()
        if ($lineBytes.Length -gt 0 -and $lineBytes[-1] -eq 13) {
            if ($lineBytes.Length -eq 1) {
                [byte[]]$lineBytes = @()
            }
            else {
                [byte[]]$lineBytes = $lineBytes[0..($lineBytes.Length - 2)]
            }
        }
        try {
            $text = [Text.UTF8Encoding]::new($false, $true).GetString($lineBytes)
            $State.Lines.Enqueue([pscustomobject]@{ Kind = 'line'; Text = $text })
        }
        catch {
            $State.Lines.Enqueue([pscustomobject]@{ Kind = 'invalidUtf8'; Text = '' })
        }
    }
    $State.Builder.SetLength(0)
    $State.Overflow = $false
}

function Add-NdjsonByte {
    param($State, [byte] $Byte)
    if ($Byte -eq 10) {
        Complete-NdjsonLine $State
        return
    }
    if ($State.Overflow) {
        return
    }
    if (($State.Builder.Length + 1) -gt $script:AdapterMaximumCommandBytes) {
        $State.Builder.SetLength(0)
        $State.Overflow = $true
        return
    }
    $State.Builder.WriteByte($Byte)
}

function Receive-BoundedNdjsonItem {
    param($State, [int] $PollMilliseconds = 20)
    if ($State.Lines.Count -gt 0) {
        return $State.Lines.Dequeue()
    }
    if ($State.Eof) {
        return [pscustomobject]@{ Kind = 'eof'; Text = '' }
    }
    if (-not $State.ReadTask.Wait($PollMilliseconds)) {
        return $null
    }
    $count = $State.ReadTask.GetAwaiter().GetResult()
    if ($count -eq 0) {
        if ($State.Overflow -or $State.Builder.Length -gt 0) {
            Complete-NdjsonLine $State
        }
        $State.Eof = $true
    }
    else {
        for ($index = 0; $index -lt $count; $index++) {
            Add-NdjsonByte $State $State.Bytes[$index]
        }
        $State.ReadTask = $State.Stream.ReadAsync(
            $State.Bytes,
            0,
            $State.Bytes.Length
        )
    }
    if ($State.Lines.Count -gt 0) {
        return $State.Lines.Dequeue()
    }
    if ($State.Eof) {
        return [pscustomobject]@{ Kind = 'eof'; Text = '' }
    }
    $null
}

function Drain-Subscriptions {
    param($Writer, $Live, $Subscriptions)
    if ($null -eq $Live) {
        return
    }
    foreach ($entry in @($Subscriptions.GetEnumerator())) {
        $record = $entry.Value
        while ($true) {
            $item = $null
            [Threading.Monitor]::Enter($Live.QueueGate)
            try {
                if ($record.Updates.Count -gt 0) {
                    $item = $record.Updates.Dequeue()
                    $record.QueuedBytes -= $item.Bytes
                    $Live.PendingCount--
                    $Live.PendingBytes -= $item.Bytes
                }
            }
            finally {
                [Threading.Monitor]::Exit($Live.QueueGate)
            }
            if ($null -eq $item) {
                break
            }
            if (-not $record.Active) {
                continue
            }
            $event = @{ type = 'subscription'; subscriptionId = $entry.Key }
            if ($item.Event.ContainsKey('error')) {
                $event['error'] = $item.Event['error']
            }
            else {
                $event['value'] = $item.Event['value']
            }
            [string[]] $logs = @()
            if ($item.Event.ContainsKey('logs')) {
                [string[]] $logs = @($item.Event['logs'])
            }
            if ($logs.Count -gt 0) {
                $event['logs'] = [string[]]$logs
            }
            Write-AdapterEvent $Writer $event
        }
    }
}

function Assert-AdapterCommand {
    param([hashtable] $Command)

    # A controller can put an unpaired surrogate into an otherwise valid UTF-8
    # line with a \ud800 escape, so the byte-level UTF-8 check upstream does not
    # exclude it. Rune.GetRuneAt throws a plain ArgumentException on that input,
    # which Get-ConvexError would then report as a TransportError even though a
    # malformed command field is a protocol violation. Walk the pairs directly
    # so an ill-formed field is rejected with the right name, and so a valid
    # astral scalar still counts as the single code point JSON Schema measures.
    function Get-JsonStringLength([string] $Value, [string] $Field) {
        $length = 0
        $offset = 0
        while ($offset -lt $Value.Length) {
            $current = $Value[$offset]
            if ([char]::IsLowSurrogate($current)) {
                throw (New-AdapterProtocolException "adapter command $Field is not well-formed Unicode")
            }
            if ([char]::IsHighSurrogate($current)) {
                if (
                    $offset + 1 -ge $Value.Length -or
                    -not [char]::IsLowSurrogate($Value[$offset + 1])
                ) {
                    throw (New-AdapterProtocolException "adapter command $Field is not well-formed Unicode")
                }
                $offset += 2
            }
            else {
                $offset++
            }
            $length++
        }
        $length
    }

    # PowerShell hashtable lookups and -in are case-insensitive, but JSON Schema
    # property names are not. Without an exact-case test, a command carrying
    # "ID" or "OP" would satisfy the required-field check and slip past
    # additionalProperties, so the adapter would accept input the shared schema
    # rejects. Compare key names ordinally instead.
    function Test-CommandKey([hashtable] $Value, [string] $Field) {
        foreach ($key in $Value.Keys) {
            if (([string]$key) -ceq $Field) {
                return $true
            }
        }
        $false
    }

    function Assert-RequiredString(
        [hashtable] $Value,
        [string] $Field,
        [int] $MinimumLength,
        [int] $MaximumLength = [int]::MaxValue
    ) {
        if (-not (Test-CommandKey $Value $Field) -or $Value[$Field] -isnot [string]) {
            throw (New-AdapterProtocolException "adapter command $Field must be a string")
        }
        # JSON Schema measures string length in Unicode code points, not .NET
        # UTF-16 code units. This keeps astral IDs within the shared 128 limit.
        $length = Get-JsonStringLength $Value[$Field] $Field
        if ($length -lt $MinimumLength -or $length -gt $MaximumLength) {
            throw (New-AdapterProtocolException "adapter command $Field length is out of range")
        }
    }

    function Assert-Fields([hashtable] $Value, [string[]] $Required, [string[]] $Allowed) {
        foreach ($field in $Required) {
            if (-not (Test-CommandKey $Value $field)) {
                throw (New-AdapterProtocolException "adapter command omitted $field")
            }
        }
        foreach ($field in $Value.Keys) {
            if (([string]$field) -cnotin $Allowed) {
                throw (New-AdapterProtocolException "adapter command contains unexpected field $([string]$field)")
            }
        }
    }

    Assert-RequiredString $Command 'op' 1
    $operation = $Command['op']
    if ($operation -notin @('hello', 'close', 'setAuth', 'query', 'mutation', 'action', 'subscribe', 'unsubscribe', 'debugDisconnect')) {
        throw (New-AdapterProtocolException "unknown operation $operation")
    }
    Assert-RequiredString $Command 'id' 1 128

    switch ($operation) {
        'hello' {
            Assert-Fields $Command @('protocolVersion', 'id', 'op') @('protocolVersion', 'id', 'op')
            $protocolVersion = $Command['protocolVersion']
            $isVersionOne = $false
            if ($protocolVersion -isnot [bool] -and $protocolVersion -is [ValueType]) {
                try { $isVersionOne = [decimal]$protocolVersion -eq 1 } catch {}
            }
            if (-not $isVersionOne) {
                throw (New-AdapterProtocolException 'unsupported adapter protocol version')
            }
        }
        { $_ -in @('query', 'mutation', 'action') } {
            Assert-Fields $Command @('id', 'op', 'path', 'args') @('id', 'op', 'path', 'args')
            Assert-RequiredString $Command 'path' 3
            if ($Command['args'] -isnot [hashtable]) {
                throw (New-AdapterProtocolException "$operation args must be a JSON object")
            }
        }
        'subscribe' {
            Assert-Fields $Command @('id', 'op', 'subscriptionId', 'path', 'args') @('id', 'op', 'subscriptionId', 'path', 'args')
            Assert-RequiredString $Command 'subscriptionId' 1 128
            Assert-RequiredString $Command 'path' 3
            if ($Command['args'] -isnot [hashtable]) {
                throw (New-AdapterProtocolException 'subscribe args must be a JSON object')
            }
        }
        'unsubscribe' {
            # The shared schema shares one definition between subscribe and
            # unsubscribe, so path and args are optional but permitted here. An
            # unsubscribe carrying them is valid input the controller may send;
            # rejecting it would fail a schema-valid command. Their types and the
            # additionalProperties and length bounds are still enforced exactly.
            Assert-Fields $Command @('id', 'op', 'subscriptionId') @('id', 'op', 'subscriptionId', 'path', 'args')
            Assert-RequiredString $Command 'subscriptionId' 1 128
            if (Test-CommandKey $Command 'path') {
                Assert-RequiredString $Command 'path' 0
            }
            if ((Test-CommandKey $Command 'args') -and $Command['args'] -isnot [hashtable]) {
                throw (New-AdapterProtocolException 'unsubscribe args must be a JSON object')
            }
        }
        'setAuth' {
            Assert-Fields $Command @('id', 'op', 'token') @('id', 'op', 'token')
            Assert-RequiredString $Command 'token' 0
        }
        { $_ -in @('close', 'debugDisconnect') } {
            Assert-Fields $Command @('id', 'op') @('id', 'op')
        }
    }
}

function Run-Adapter {
    param($InputStream, $Writer, [string] $Url)
    $client = $null
    $live = $null
    [string]$authToken = ''
    $subscriptions = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
    $inputState = New-BoundedNdjsonReader $InputStream
    $closed = $false
    try {
        while (-not $closed) {
            Drain-Subscriptions $Writer $live $subscriptions
            $item = Receive-BoundedNdjsonItem $inputState
            if ($null -eq $item) {
                continue
            }
            if ($item.Kind -eq 'eof') {
                break
            }
            if ($item.Kind -eq 'overflow') {
                Write-AdapterFailure $Writer '' '' (
                    New-AdapterProtocolException 'NDJSON command exceeds 64 KiB'
                )
                continue
            }
            if ($item.Kind -eq 'invalidUtf8') {
                Write-AdapterFailure $Writer '' '' (
                    New-AdapterProtocolException 'NDJSON command is not valid UTF-8'
                )
                continue
            }
            try {
                $command = ConvertFrom-ConvexJson $item.Text
            }
            catch {
                Write-AdapterFailure $Writer '' '' (
                    New-AdapterProtocolException "malformed NDJSON command: $($_.Exception.Message)"
                )
                continue
            }
            try {
                if ($command -isnot [hashtable]) {
                    throw (New-AdapterProtocolException 'command is not a JSON object')
                }
                Assert-AdapterCommand $command
            }
            catch {
                Write-AdapterFailure $Writer '' '' $_.Exception
                continue
            }
            $id = $command['id']
            try {
                switch ($command['op']) {
                    'hello' {
                        if ($command['protocolVersion'] -ne 1) {
                            throw (New-AdapterProtocolException 'unsupported adapter protocol version')
                        }
                        Write-AdapterEvent $Writer @{
                            protocolVersion = 1
                            id              = $id
                            type            = 'ready'
                            language        = 'powershell'
                            implementation  = 'native-powershell-7.5.0'
                            runtime         = "PowerShell-$($PSVersionTable.PSVersion)"
                        }
                    }
                    'close' {
                        if ($live) {
                            foreach ($subscriptionId in @($subscriptions.Keys)) {
                                Remove-ConvexSubscription $live $subscriptionId
                            }
                        }
                        $subscriptions.Clear()
                        if ($live) {
                            Close-ConvexLive $live
                        }
                        if ($client) {
                            Close-ConvexClient $client
                        }
                        Write-AdapterEvent $Writer @{ id = $id; type = 'closed' }
                        $closed = $true
                    }
                    'setAuth' {
                        $authToken = [string]$command['token']
                        if (-not $client) {
                            $client = New-ConvexClient $Url
                        }
                        Set-ConvexAuth $client $authToken
                        Write-AdapterEvent $Writer @{ id = $id; type = 'ack' }
                    }
                    { $_ -in @('query', 'mutation', 'action') } {
                        if (-not $client) {
                            $client = New-ConvexClient $Url
                            Set-ConvexAuth $client $authToken
                        }
                        $callArguments = @{
                            Client       = $client
                            Operation    = $command['op']
                            Path         = $command['path']
                            FunctionArgs = [hashtable]$command['args']
                        }
                        $result = Invoke-ConvexFunction @callArguments
                        $event = @{ id = $id; type = 'result'; value = $result.Value }
                        [string[]] $logs = @($result.Logs)
                        if ($logs.Count -gt 0) {
                            $event['logs'] = [string[]]$logs
                        }
                        Write-AdapterEvent $Writer $event
                    }
                    'subscribe' {
                        if ($client) {
                            # The hosted pilot performs HTTP and Live in one
                            # adapter session. Retaining the HTTP TLS pool while
                            # the worker runspace and WebSocket are live crosses
                            # the final adapter's 128 MiB cgroup. Keep auth as
                            # adapter state, but retire the idle HTTP transport
                            # on every subscribe: a query between two subscribes
                            # rebuilds the client, so gating this on the first
                            # subscribe would leave the pool resident for the
                            # rest of the session. Disposal closes those sockets
                            # deterministically; a forced collect and finalizer
                            # wait here would sit outside the client's bounded
                            # subscribe deadline for an unbounded time.
                            Close-ConvexClient $client
                            $client = $null
                        }
                        if (-not $live) {
                            $live = New-ConvexLiveState $Url
                        }
                        $subscriptionArguments = @{
                            Live         = $live
                            Id           = $command['subscriptionId']
                            Path         = $command['path']
                            FunctionArgs = [hashtable]$command['args']
                        }
                        $record = Add-ConvexSubscription @subscriptionArguments
                        $subscriptions[$command['subscriptionId']] = $record
                        Write-AdapterEvent $Writer @{ id = $id; type = 'ack' }
                    }
                    'unsubscribe' {
                        if ($live) {
                            Remove-ConvexSubscription $live $command['subscriptionId']
                        }
                        $old = $null
                        $subscriptions.TryRemove($command['subscriptionId'], [ref]$old) | Out-Null
                        # The adapter's sole Live owner remains alive for the
                        # controller's TCP session. Unsubscribe has already
                        # retired its WebSocket, and stopping this runspace
                        # before publishing the acknowledgement races a later
                        # controller command. Explicit close or input EOF owns
                        # the final worker cleanup.
                        Write-AdapterEvent $Writer @{ id = $id; type = 'ack' }
                    }
                    'debugDisconnect' {
                        if (-not $live) {
                            throw (New-AdapterProtocolException 'Live WebSocket is not connected')
                        }
                        Disconnect-ConvexLiveForAdapter $live
                        Write-AdapterEvent $Writer @{ id = $id; type = 'ack' }
                    }
                    default {
                        throw (New-AdapterProtocolException "unknown operation $($command['op'])")
                    }
                }
            }
            catch {
                Write-AdapterFailure $Writer $id '' $_.Exception
            }
        }
    }
    finally {
        if ($live) {
            Close-ConvexLive $live
        }
        if ($client) {
            Close-ConvexClient $client
        }
    }
}

if ($env:ADAPTER_LISTEN) {
    $parts = $env:ADAPTER_LISTEN.Split(':')
    if ($parts.Count -ne 2) {
        throw 'ADAPTER_LISTEN must be host:port'
    }
    $listener = [Net.Sockets.TcpListener]::new(
        [Net.IPAddress]::Parse($parts[0]),
        [int]$parts[1]
    )
    $listener.Start()
    $tcp = $null
    try {
        $tcp = $listener.AcceptTcpClient()
        $tcp.NoDelay = $true
        # A small send buffer makes a stopped controller visible to the
        # application deadline before multiple near-limit events enter kernel
        # buffering outside the managed byte reservation.
        $tcp.SendBufferSize = $script:AdapterWriteChunkBytes
        $stream = $tcp.GetStream()
        $writer = New-AdapterWriter $stream { $tcp.Dispose() }
        Run-Adapter -InputStream $stream -Writer $writer -Url $env:CONVEX_URL
    }
    finally {
        if ($null -ne $tcp) {
            $tcp.Dispose()
        }
        $listener.Stop()
    }
}
else {
    # Write raw UTF-8 bytes rather than through the console TextWriter so stdin
    # mode gets the same bounded, ordered, byte-exact NDJSON records as TCP.
    # Each record is flushed as it is written, and only the terminal partial-record
    # path closes this handle. A clean shutdown leaves standard output for the
    # runtime to close, so a normal exit cannot fail on a disposed handle.
    $standardOutput = [Console]::OpenStandardOutput()
    $writer = New-AdapterWriter $standardOutput { $standardOutput.Dispose() }
    Run-Adapter -InputStream ([Console]::OpenStandardInput()) -Writer $writer -Url $env:CONVEX_URL
}
