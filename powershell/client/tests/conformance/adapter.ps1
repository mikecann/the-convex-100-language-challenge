#!/usr/bin/pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../Convex.ps1')

$script:AdapterMaximumCommandBytes = 64KB
$script:AdapterReadChunkBytes = 4096

function New-AdapterProtocolException {
    param([string] $Message)
    $errorValue = New-ConvexError -Name ProtocolError -Message $Message
    $exception = [System.Exception]::new($Message)
    $exception.Data['convex'] = $errorValue
    $exception
}

function Write-AdapterEvent {
    param($Writer, [hashtable] $Event)
    $json = $Event | ConvertTo-Json -Depth 64 -Compress
    if ($Writer.PSObject.Properties['TcpStream']) {
        $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes("$json`n")
        $writeTask = $Writer.TcpStream.WriteAsync(
            $bytes,
            0,
            $bytes.Length,
            [Threading.CancellationToken]::None
        )
        if (-not $writeTask.Wait(1000)) {
            # Cancellation alone is not a portable way to interrupt a blocked
            # socket write. Retiring the one controller socket is deterministic.
            $Writer.TcpClient.Dispose()
            throw [IO.IOException]::new('adapter controller stopped reading')
        }
        $writeTask.GetAwaiter().GetResult() | Out-Null
    }
    else {
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
        $stream = $tcp.GetStream()
        $writer = [pscustomobject]@{ TcpStream = $stream; TcpClient = $tcp }
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
