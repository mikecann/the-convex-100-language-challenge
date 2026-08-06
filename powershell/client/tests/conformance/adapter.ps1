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

function Write-AdapterEvent {
    param($Writer, [hashtable] $Event)
    if ($Writer.PSObject.Properties['Failed'] -and $Writer.Failed) {
        throw [IO.IOException]::new([string]$Writer.FailureMessage)
    }
    if ($Writer.PSObject.Properties['TcpStream']) {
        # HTTP decoding temporarily owns the raw response bytes and JSON text.
        # They are dead once the event graph reaches this function. Reclaim
        # them before the bounded streaming serializer starts.
        [GC]::Collect(2, [GCCollectionMode]::Optimized, $true, $true)

        # Reserve the complete allowance before serialization. This charge
        # covers the retained event graph, bounded pipe segments, one network
        # chunk, and serializer/task overhead without an event-sized byte array.
        # A second event can never accumulate behind the one synchronous writer.
        $reservation = [long]$script:AdapterOutputBudgetBytes
        [Threading.Monitor]::Enter($Writer.OutputGate)
        try {
            if (($Writer.ReservedBytes + $reservation) -gt $script:AdapterOutputBudgetBytes) {
                throw [IO.IOException]::new('adapter encoded-output byte budget exhausted')
            }
            $Writer.ReservedBytes += $reservation
        }
        finally {
            [Threading.Monitor]::Exit($Writer.OutputGate)
        }

        $failure = $null
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $pipe = $null
        $serializerStream = $null
        $readerStream = $null
        $serializeCancellation = $null
        $writerCompleted = $false
        try {
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
                    if ($timer.ElapsedMilliseconds -ge $script:AdapterWriteDeadlineMilliseconds) {
                        throw [TimeoutException]::new('adapter controller write deadline expired')
                    }
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
                $remaining = $script:AdapterWriteDeadlineMilliseconds - [int]$timer.ElapsedMilliseconds
                if ($remaining -le 0) {
                    throw [TimeoutException]::new('adapter controller write deadline expired')
                }
                $writeTask = $Writer.TcpStream.WriteAsync(
                    $chunk,
                    0,
                    $count,
                    [Threading.CancellationToken]::None
                )
                if (-not $writeTask.Wait($remaining)) {
                    throw [TimeoutException]::new('adapter controller write deadline expired')
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
            $remaining = $script:AdapterWriteDeadlineMilliseconds - [int]$timer.ElapsedMilliseconds
            if ($remaining -le 0) {
                throw [TimeoutException]::new('adapter controller write deadline expired')
            }
            [byte[]]$newline = @(10)
            $newlineTask = $Writer.TcpStream.WriteAsync(
                $newline,
                0,
                1,
                [Threading.CancellationToken]::None
            )
            if (-not $newlineTask.Wait($remaining)) {
                throw [TimeoutException]::new('adapter controller write deadline expired')
            }
            $newlineTask.GetAwaiter().GetResult() | Out-Null
        }
        catch {
            $failure = $_.Exception
            if ($null -ne $serializeCancellation) { $serializeCancellation.Cancel() }
            if ($null -ne $pipe) {
                $pipe.Reader.CancelPendingRead()
                $pipe.Writer.CancelPendingFlush()
            }
            # Disposing the sole controller socket abandons any partial NDJSON
            # line and interrupts the outstanding kernel write deterministically.
            $Writer.TcpClient.Dispose()
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
            [Threading.Monitor]::Enter($Writer.OutputGate)
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
    else {
        $json = $Event | ConvertTo-Json -Depth 64 -Compress
        $Writer.WriteLine($json)
        $Writer.Flush()
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
    if (-not $Command.ContainsKey('op') -or [string]::IsNullOrWhiteSpace([string]$Command['op'])) {
        throw (New-AdapterProtocolException 'adapter command omitted op')
    }
    $operation = [string]$Command['op']
    if ($operation -in @('hello', 'close', 'setAuth', 'query', 'mutation', 'action', 'subscribe', 'unsubscribe', 'debugDisconnect')) {
        if (-not $Command.ContainsKey('id') -or [string]::IsNullOrWhiteSpace([string]$Command['id'])) {
            throw (New-AdapterProtocolException "$operation command omitted id")
        }
    }
    if ($operation -in @('query', 'mutation', 'action', 'subscribe')) {
        if (-not $Command.ContainsKey('path') -or [string]::IsNullOrWhiteSpace([string]$Command['path'])) {
            throw (New-AdapterProtocolException "$operation command omitted path")
        }
        if (-not $Command.ContainsKey('args') -or $Command['args'] -isnot [hashtable]) {
            throw (New-AdapterProtocolException "$operation args must be a JSON object")
        }
    }
    if ($operation -in @('subscribe', 'unsubscribe')) {
        if (-not $Command.ContainsKey('subscriptionId') -or [string]::IsNullOrWhiteSpace([string]$Command['subscriptionId'])) {
            throw (New-AdapterProtocolException "$operation command omitted subscriptionId")
        }
    }
    if ($operation -eq 'setAuth' -and -not $Command.ContainsKey('token')) {
        throw (New-AdapterProtocolException 'setAuth command omitted token')
    }
}

function Run-Adapter {
    param($InputStream, $Writer, [string] $Url)
    $client = $null
    $live = $null
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
            $id = if ($command.ContainsKey('id')) { [string]$command['id'] } else { '' }
            try {
                switch ([string]$command['op']) {
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
                        if (-not $client) {
                            $client = New-ConvexClient $Url
                        }
                        Set-ConvexAuth $client ([string]$command['token'])
                        Write-AdapterEvent $Writer @{ id = $id; type = 'ack' }
                    }
                    { $_ -in @('query', 'mutation', 'action') } {
                        if (-not $client) {
                            $client = New-ConvexClient $Url
                        }
                        $callArguments = @{
                            Client       = $client
                            Operation    = [string]$command['op']
                            Path         = [string]$command['path']
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
                        if (-not $live) {
                            $live = New-ConvexLiveState $Url
                        }
                        $subscriptionArguments = @{
                            Live         = $live
                            Id           = [string]$command['subscriptionId']
                            Path         = [string]$command['path']
                            FunctionArgs = [hashtable]$command['args']
                        }
                        $record = Add-ConvexSubscription @subscriptionArguments
                        $subscriptions[[string]$command['subscriptionId']] = $record
                        Write-AdapterEvent $Writer @{ id = $id; type = 'ack' }
                    }
                    'unsubscribe' {
                        if ($live) {
                            Remove-ConvexSubscription $live ([string]$command['subscriptionId'])
                        }
                        $old = $null
                        $subscriptions.TryRemove([string]$command['subscriptionId'], [ref]$old) | Out-Null
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
        $writer = [pscustomobject]@{
            TcpStream      = $stream
            TcpClient      = $tcp
            OutputGate     = [object]::new()
            ReservedBytes  = 0L
            Failed         = $false
            FailureMessage = ''
        }
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
    Run-Adapter -InputStream ([Console]::OpenStandardInput()) -Writer ([Console]::Out) -Url $env:CONVEX_URL
}
