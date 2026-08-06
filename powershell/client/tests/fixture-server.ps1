param([int] $Port = 43137, [string] $ReadyFile = '/tmp/powershell-fixture-ready')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$state = [hashtable]::Synchronized(@{
        Sync                  = [object]::new()
        Count                 = 0
        # Start just before the byte boundary so the fixture proves that the
        # client compares Convex's little-endian uint64 timestamps numerically.
        Revision              = 253
        FailureTrigger        = 0
        CloseControlTriggered = $false
        Connections           = 0
        Adds                  = 0
        Stop                  = $false
        ConnectMessages       = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        AddBatches            = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        Sockets               = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
        Workers               = [System.Collections.Generic.List[object]]::new()
    })

$socketWorker = {
    param($Socket, $State)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $State.Sockets.Add($Socket)
    [Threading.Monitor]::Enter($State.Sync)
    try {
        $State.Connections++
        $connectionNumber = $State.Connections
    }
    finally {
        [Threading.Monitor]::Exit($State.Sync)
    }
    $buffer = [byte[]]::new(4096)
    $frame = [IO.MemoryStream]::new()
    $receiveTask = $null
    $queryId = $null
    $queryPath = ''
    $mode = ''
    $owner = [pscustomobject]@{
        Version = @{ querySet = 0; identity = 0; ts = 'AAAAAAAAAAA=' }
    }
    $seenRevision = -1
    $seenFailure = 0

    function New-Version([int] $QuerySet) {
        [Threading.Monitor]::Enter($State.Sync)
        try {
            $State.Revision++
            [byte[]]$timestampBytes = [byte[]]::new(8)
            [uint64]$revision = $State.Revision
            for ($index = 0; $index -lt 8; $index++) {
                $timestampBytes[$index] = [byte](($revision -shr (8 * $index)) -band 0xff)
            }
            $timestamp = [Convert]::ToBase64String($timestampBytes)
        }
        finally {
            [Threading.Monitor]::Exit($State.Sync)
        }
        @{ querySet = $QuerySet; identity = 0; ts = $timestamp }
    }

    function Send-Json($Value, [bool] $Fragmented = $false) {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 64 -Compress))
        if ($Fragmented -and $bytes.Length -gt 8) {
            $split = [Math]::Min($bytes.Length - 1, 17)
            $Socket.SendAsync(
                [ArraySegment[byte]]::new($bytes, 0, $split),
                [Net.WebSockets.WebSocketMessageType]::Text,
                $false,
                [Threading.CancellationToken]::None
            ).GetAwaiter().GetResult() | Out-Null
            Start-Sleep -Milliseconds 10
            $Socket.SendAsync(
                [ArraySegment[byte]]::new($bytes, $split, $bytes.Length - $split),
                [Net.WebSockets.WebSocketMessageType]::Text,
                $true,
                [Threading.CancellationToken]::None
            ).GetAwaiter().GetResult() | Out-Null
            return
        }
        $Socket.SendAsync(
            [ArraySegment[byte]]::new($bytes),
            [Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            [Threading.CancellationToken]::None
        ).GetAwaiter().GetResult() | Out-Null
    }

    function Current-Count {
        [Threading.Monitor]::Enter($State.Sync)
        try { [int]$State.Count } finally { [Threading.Monitor]::Exit($State.Sync) }
    }

    function Send-Transition([object[]] $Modifications, [bool] $Fragmented = $false) {
        $end = New-Version ([int]$owner.Version.querySet)
        Send-Json @{
            type          = 'Transition'
            startVersion  = $owner.Version
            endVersion    = $end
            modifications = @($Modifications)
        } $Fragmented
        $owner.Version = $end
    }

    try {
        while (-not $State.Stop -and $Socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
            if ($null -eq $receiveTask) {
                $receiveTask = $Socket.ReceiveAsync(
                    [ArraySegment[byte]]::new($buffer),
                    [Threading.CancellationToken]::None
                )
            }
            if ($receiveTask.Wait(10)) {
                $result = $receiveTask.GetAwaiter().GetResult()
                $receiveTask = $null
                if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                    break
                }
                $frame.Write($buffer, 0, $result.Count)
                if ($result.EndOfMessage) {
                    $message = [Text.Encoding]::UTF8.GetString($frame.ToArray()) |
                        ConvertFrom-Json -AsHashtable -Depth 64
                    $frame.SetLength(0)
                    if ($message['type'] -eq 'Connect') {
                        $State.ConnectMessages.Enqueue($message)
                    }
                    elseif ($message['type'] -eq 'ModifyQuerySet') {
                        [int[]]$addBatch = @(
                            $message['modifications'] |
                                Where-Object { $_['type'] -eq 'Add' } |
                                ForEach-Object { [int]$_['queryId'] }
                        )
                        if ($addBatch.Count -gt 0) {
                            $State.AddBatches.Enqueue([int[]]$addBatch)
                        }
                        foreach ($change in @($message['modifications'])) {
                            if ($change['type'] -eq 'Add') {
                                [Threading.Monitor]::Enter($State.Sync)
                                try { $State.Adds++ } finally { [Threading.Monitor]::Exit($State.Sync) }
                                $queryId = [int]$change['queryId']
                                $queryPath = [string]$change['udfPath']
                                $arguments = if (@($change['args']).Count) { @($change['args'])[0] } else { @{} }
                                $mode = if ($arguments -is [hashtable] -and $arguments.ContainsKey('mode')) {
                                    [string]$arguments['mode']
                                }
                                else {
                                    ''
                                }
                                if ($mode -eq 'timestampBoundary') {
                                    [Threading.Monitor]::Enter($State.Sync)
                                    try { $State.Revision = 254 } finally { [Threading.Monitor]::Exit($State.Sync) }
                                }
                                if ($mode -eq 'closeControl') {
                                    [Threading.Monitor]::Enter($State.Sync)
                                    try {
                                        $sendClose = -not $State.CloseControlTriggered
                                        $State.CloseControlTriggered = $true
                                    }
                                    finally {
                                        [Threading.Monitor]::Exit($State.Sync)
                                    }
                                    if ($sendClose) {
                                        $Socket.CloseOutputAsync(
                                            [Net.WebSockets.WebSocketCloseStatus]::EndpointUnavailable,
                                            'fixture control close',
                                            [Threading.CancellationToken]::None
                                        ).GetAwaiter().GetResult() | Out-Null
                                        break
                                    }
                                }
                                $end = New-Version ([int]$message['newVersion'])
                                $modifications = [System.Collections.Generic.List[object]]::new()
                                if ($queryPath -eq 'demo:requiresNonzero' -and (Current-Count) -eq 0) {
                                    $modifications.Add(@{
                                            type         = 'QueryFailed'
                                            queryId      = $queryId
                                            errorMessage = 'room empty'
                                            errorData    = @{ code = 'ROOM_EMPTY' }
                                            logLines     = @('fixture failure')
                                        })
                                }
                                else {
                                    $initialValue = @{ count = (Current-Count); text = 'café 🦘' }
                                    if ($mode -eq 'large') {
                                        $initialValue['blob'] = 'x' * (3MB)
                                    }
                                    $modifications.Add(@{
                                            type     = 'QueryUpdated'
                                            queryId  = $queryId
                                            value    = $initialValue
                                            logLines = @('fixture update')
                                        })
                                }
                                if ($mode -eq 'invalidTail') {
                                    $modifications.Add(@{ type = 'UnknownModification'; queryId = $queryId })
                                }
                                if ($mode -eq 'invalidQueryId') {
                                    foreach ($modification in $modifications) {
                                        $modification['queryId'] = [uint64]4294967296
                                    }
                                }
                                if ($mode -eq 'invalidTimestamp') {
                                    $end['ts'] = 'not-base64'
                                }
                                if ($mode -eq 'stalledFrame') {
                                    $payload = @{
                                        type          = 'Transition'
                                        startVersion  = $owner.Version
                                        endVersion    = $end
                                        modifications = @($modifications)
                                    } | ConvertTo-Json -Depth 64 -Compress
                                    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
                                    $half = [Math]::Max(1, [int]($bytes.Length / 2))
                                    $Socket.SendAsync(
                                        [ArraySegment[byte]]::new($bytes, 0, $half),
                                        [Net.WebSockets.WebSocketMessageType]::Text,
                                        $false,
                                        [Threading.CancellationToken]::None
                                    ).GetAwaiter().GetResult() | Out-Null
                                }
                                else {
                                    Send-Json @{
                                        type          = 'Transition'
                                        startVersion  = $owner.Version
                                        endVersion    = $end
                                        modifications = @($modifications)
                                    } ($mode -eq 'fragmented')
                                    $owner.Version = $end
                                    if ($mode -eq 'timestampBoundary') {
                                        $boundaryEnd = New-Version ([int]$owner.Version.querySet)
                                        Send-Json @{
                                            type          = 'Transition'
                                            startVersion  = $owner.Version
                                            endVersion    = $boundaryEnd
                                            modifications = @(@{
                                                    type     = 'QueryUpdated'
                                                    queryId  = $queryId
                                                    value    = @{ count = (Current-Count); text = 'café 🦘' }
                                                    logLines = @('timestamp boundary')
                                                })
                                        }
                                        $owner.Version = $boundaryEnd
                                    }
                                }
                                [Threading.Monitor]::Enter($State.Sync)
                                try {
                                    $seenRevision = $State.Revision
                                    $seenFailure = $State.FailureTrigger
                                }
                                finally {
                                    [Threading.Monitor]::Exit($State.Sync)
                                }
                            }
                        }
                    }
                }
            }
            if ($null -eq $queryId -or $mode -eq 'stalledFrame') {
                continue
            }
            if ($mode -eq 'flood') {
                Send-Transition @(@{
                        type     = 'QueryUpdated'
                        queryId  = $queryId
                        value    = @{ count = (Current-Count); text = 'café 🦘' }
                        logLines = @('fixture flood update')
                    }) $true
                continue
            }
            [Threading.Monitor]::Enter($State.Sync)
            try {
                $currentRevision = $State.Revision
                $currentFailure = $State.FailureTrigger
            }
            finally {
                [Threading.Monitor]::Exit($State.Sync)
            }
            if ($currentFailure -gt $seenFailure) {
                $seenFailure = $currentFailure
                Send-Transition @(@{
                        type         = 'QueryFailed'
                        queryId      = $queryId
                        errorMessage = 'temporary same-value failure'
                        errorData    = @{ code = 'SAME_VALUE' }
                        logLines     = @('one log line')
                    })
                Send-Transition @(@{
                        type     = 'QueryUpdated'
                        queryId  = $queryId
                        value    = @{ count = (Current-Count); text = 'café 🦘' }
                        logLines = @('one recovery log')
                    })
                [Threading.Monitor]::Enter($State.Sync)
                try { $seenRevision = $State.Revision } finally { [Threading.Monitor]::Exit($State.Sync) }
            }
            elseif ($currentRevision -gt $seenRevision) {
                $seenRevision = $currentRevision
                Send-Transition @(@{
                        type     = 'QueryUpdated'
                        queryId  = $queryId
                        value    = @{ count = (Current-Count); text = 'café 🦘' }
                        logLines = @('fixture external update')
                    }) $true
                [Threading.Monitor]::Enter($State.Sync)
                try { $seenRevision = $State.Revision } finally { [Threading.Monitor]::Exit($State.Sync) }
            }
        }
    }
    catch {
        $fixtureMessage = $_.Exception.Message
        if (
            $fixtureMessage -notmatch 'remote party closed' -and
            $fixtureMessage -notmatch "invalid state \('(Aborted|CloseSent)'\)"
        ) {
            [Console]::Error.WriteLine("fixture socket $connectionNumber stopped: $fixtureMessage")
        }
    }
    finally {
        try { $Socket.Abort() } catch {}
        $Socket.Dispose()
    }
}

function Read-RequestBody($Request) {
    $reader = [IO.StreamReader]::new($Request.InputStream, [Text.Encoding]::UTF8)
    try { $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Write-JsonResponse($Response, $Value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 64 -Compress))
    $Response.ContentType = 'application/json'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.Close()
}

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
[IO.File]::WriteAllText($ReadyFile, 'ready', [Text.UTF8Encoding]::new($false))
try {
    while (-not $state.Stop) {
        $context = $listener.GetContext()
        if ($context.Request.IsWebSocketRequest) {
            $webSocketContext = $context.AcceptWebSocketAsync('convex-1.0.0').GetAwaiter().GetResult()
            $powerShell = [PowerShell]::Create()
            [void]$powerShell.AddScript($socketWorker)
            [void]$powerShell.AddArgument($webSocketContext.WebSocket)
            [void]$powerShell.AddArgument($state)
            $worker = [pscustomobject]@{ PowerShell = $powerShell; Handle = $powerShell.BeginInvoke() }
            $state.Workers.Add($worker)
            continue
        }
        $body = Read-RequestBody $context.Request
        $request = if ($body) { $body | ConvertFrom-Json -AsHashtable -Depth 64 } else { @{} }
        $path = [string]$request['path']
        if ($path -eq 'fixture:shutdown') {
            $state.Stop = $true
            Write-JsonResponse $context.Response @{ status = 'success'; value = $true }
            continue
        }
        if ($path -eq 'fixture:metadata') {
            $messages = @($state.ConnectMessages.ToArray())
            $addBatches = @($state.AddBatches.ToArray())
            Write-JsonResponse $context.Response @{
                status   = 'success'
                value    = @{
                    connections     = $state.Connections
                    adds            = $state.Adds
                    connectMessages = $messages
                    addBatches      = $addBatches
                }
                logLines = @('metadata log')
            }
            continue
        }
        if ($path -eq 'fixture:failSame') {
            [Threading.Monitor]::Enter($state.Sync)
            try { $state.FailureTrigger++ } finally { [Threading.Monitor]::Exit($state.Sync) }
            Write-JsonResponse $context.Response @{ status = 'success'; value = $true }
            continue
        }
        if ($path -eq 'demo:increment') {
            [Threading.Monitor]::Enter($state.Sync)
            try { $state.Count++; $state.Revision++; $count = $state.Count } finally { [Threading.Monitor]::Exit($state.Sync) }
            Write-JsonResponse $context.Response @{
                status   = 'success'
                value    = @{ applied = $true; state = @{ count = $count } }
                logLines = @('mutation log')
            }
            continue
        }
        if ($path -eq 'demo:echo') {
            Write-JsonResponse $context.Response @{
                status   = 'success'
                value    = $request['args']['value']
                logLines = @('single log')
            }
            continue
        }
        if ($path -eq 'fixture:huge') {
            Write-JsonResponse $context.Response @{
                status = 'success'
                value  = @{ blob = ('z' * (6MB)) }
            }
            continue
        }
        if ($path -eq 'demo:fail') {
            Write-JsonResponse $context.Response @{
                status       = 'error'
                errorMessage = 'fixture function failed'
                errorData    = @{ code = $request['args']['code'] }
                logLines     = @('failure log')
            }
            continue
        }
        if ($path -eq 'demo:greet') {
            Write-JsonResponse $context.Response @{
                status = 'success'
                value  = @{ message = 'Convex is responding from fixture' }
            }
            continue
        }
        Write-JsonResponse $context.Response @{
            status   = 'success'
            value    = @{ room = $request['args']['room']; count = $state.Count; lastLanguage = $null; latestRunId = $null; updatedAt = $null }
            logLines = @('query log')
        }
    }
}
finally {
    $state.Stop = $true
    foreach ($socket in $state.Sockets) {
        try { $socket.Abort() } catch {}
    }
    $listener.Stop()
    foreach ($worker in $state.Workers) {
        if (-not $worker.Handle.AsyncWaitHandle.WaitOne(2000)) {
            $worker.PowerShell.Stop()
        }
        try { $worker.PowerShell.EndInvoke($worker.Handle) | Out-Null } catch {}
        $worker.PowerShell.Dispose()
    }
}
