# This small educational client implements Convex's documented JSON HTTP API and
# the pinned unversioned /api/sync profile directly in PowerShell. .NET supplies
# ordinary HTTP, TLS, JSON, and WebSocket primitives only.
Set-StrictMode -Version Latest

$script:ConvexJsonDepth = 64
$script:ConvexMaxHttpBytes = 8MB
$script:ConvexMaxLiveBytes = 4MB
$script:ConvexQueueItems = 16
$script:ConvexQueueBytes = 1MB

function ConvertTo-ConvexJson {
  param([Parameter(Mandatory)] $Value)
  $Value | ConvertTo-Json -Depth $script:ConvexJsonDepth -Compress
}

function ConvertFrom-ConvexJson {
  param([Parameter(Mandatory)][string] $Text)
  # -AsHashtable keeps JSON object keys intact and avoids PSObject magic when
  # teaching nested Convex values.
  $Text | ConvertFrom-Json -AsHashtable -Depth $script:ConvexJsonDepth
}

function New-ConvexError {
  param(
    [ValidateSet('FunctionError', 'ProtocolError', 'TransportError', 'ClosedError')][string] $Name,
    [string] $Message,
    $Data,
    [string[]] $Logs = @(),
    [string] $Operation = ''
  )
  [pscustomobject]@{ Name = $Name; Message = $Message; Data = $Data; Logs = @($Logs); Operation = $Operation }
}

function Throw-ConvexError {
  param($Error)
  $exception = [System.Exception]::new($Error.Message)
  $exception.Data['convex'] = $Error
  throw $exception
}

function Get-ConvexError {
  param([Parameter(Mandatory)] $Exception, [string] $Operation = '')
  if ($Exception.Data.Contains('convex')) { return $Exception.Data['convex'] }
  New-ConvexError -Name TransportError -Message $Exception.Message -Operation $Operation
}

function Assert-ConvexPath {
  param([string] $Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -lt 3) {
    Throw-ConvexError (New-ConvexError -Name ProtocolError -Message 'Convex function path is required')
  }
}

function New-ConvexClient {
  param([Parameter(Mandatory)][string] $DeploymentUrl, [string] $ClientVersion = 'powershell-0.1.0')
  $uri = $null
  if (-not [uri]::TryCreate($DeploymentUrl.TrimEnd('/'), [UriKind]::Absolute, [ref] $uri) -or
      $uri.Scheme -notin @('http', 'https') -or -not [string]::IsNullOrEmpty($uri.UserInfo)) {
    Throw-ConvexError (New-ConvexError -Name ProtocolError -Message 'Convex deployment URL must be an absolute http(s) URL without user info')
  }
  [pscustomobject]@{
    Url = $uri.AbsoluteUri.TrimEnd('/'); Token = ''; Version = $ClientVersion; Closed = $false
    Http = [System.Net.Http.HttpClient]::new()
  }
}

function Set-ConvexAuth { param($Client, [AllowEmptyString()][string] $Token) $Client.Token = $Token }

function Close-ConvexClient { param($Client) if (-not $Client.Closed) { $Client.Closed = $true; $Client.Http.Dispose() } }

function Invoke-ConvexFunction {
  param(
    [Parameter(Mandatory)] $Client,
    [ValidateSet('query', 'mutation', 'action')][string] $Operation,
    [Parameter(Mandatory)][string] $Path,
    [hashtable] $FunctionArgs = @{}
  )
  if ($Client.Closed) { Throw-ConvexError (New-ConvexError -Name ClosedError -Message 'Convex client is closed') }
  Assert-ConvexPath $Path
  $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "$($Client.Url)/api/$Operation")
  $request.Headers.TryAddWithoutValidation('Convex-Client', $Client.Version) | Out-Null
  if ($Client.Token) { $request.Headers.TryAddWithoutValidation('Authorization', "Bearer $($Client.Token)") | Out-Null }
  $body = ConvertTo-ConvexJson @{ path = $Path; args = $FunctionArgs; format = 'json' }
  $request.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
  try {
    $response = $Client.Http.Send($request)
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    if ($bytes.Length -gt $script:ConvexMaxHttpBytes) { Throw-ConvexError (New-ConvexError -Name TransportError -Message 'Convex HTTP response exceeds 8 MiB' -Operation $Operation) }
    $decoded = ConvertFrom-ConvexJson ([System.Text.Encoding]::UTF8.GetString($bytes))
  } catch { Throw-ConvexError (Get-ConvexError $_.Exception $Operation) } finally { $request.Dispose() }
  $logs = if ($decoded.ContainsKey('logLines')) { @($decoded.logLines) } else { @() }
  if ($decoded.status -eq 'success' -and $decoded.ContainsKey('value')) { return [pscustomobject]@{ Value = $decoded.value; Logs = $logs } }
  if ($decoded.status -eq 'error') {
    Throw-ConvexError (New-ConvexError -Name FunctionError -Message ([string]($decoded.errorMessage ?? 'Convex function failed')) -Data $decoded.errorData -Logs $logs -Operation $Operation)
  }
  Throw-ConvexError (New-ConvexError -Name ProtocolError -Message "Convex $Operation response had unexpected status" -Operation $Operation)
}

function Get-ConvexQuery { param($Client, [string] $Path, [hashtable] $FunctionArgs = @{}) Invoke-ConvexFunction -Client $Client -Operation query -Path $Path -FunctionArgs $FunctionArgs }
function Invoke-ConvexMutation { param($Client, [string] $Path, [hashtable] $FunctionArgs = @{}) Invoke-ConvexFunction -Client $Client -Operation mutation -Path $Path -FunctionArgs $FunctionArgs }
function Invoke-ConvexAction { param($Client, [string] $Path, [hashtable] $FunctionArgs = @{}) Invoke-ConvexFunction -Client $Client -Operation action -Path $Path -FunctionArgs $FunctionArgs }

function New-ConvexLiveState {
  param([Parameter(Mandatory)][string] $DeploymentUrl, [string] $ClientVersion = 'powershell-0.1.0')
  $uri = [Uri]$DeploymentUrl.TrimEnd('/')
  $scheme = if ($uri.Scheme -eq 'https') { 'wss' } else { 'ws' }
  $endpoint = "${scheme}://$($uri.Authority)$($uri.AbsolutePath.TrimEnd('/'))/api/sync"
  [pscustomobject]@{
    Endpoint = $endpoint; Version = $ClientVersion
    Commands = [System.Collections.Concurrent.BlockingCollection[object]]::new()
    Subscriptions = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
    Closed = $false; Worker = $null; NextQueryId = 0; ConnectionCount = 0; LastCloseReason = 'InitialConnect'; MaxObservedTimestamp = $null
  }
}

$script:ConvexLiveWorker = {
  param($State, $QueueItems, $QueueBytes, $MaxFrameBytes)
  Set-StrictMode -Version Latest
  function Send-Frame($Socket, $Value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 64 -Compress))
    $Socket.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
  }
  function Version-Zero { @{ querySet = 0; identity = 0; ts = 'AAAAAAAAAAA=' } }
  function Same-Version($A, $B) { $A.querySet -eq $B.querySet -and $A.identity -eq $B.identity -and $A.ts -eq $B.ts }
  function Offer($Record, $Update) {
    # Only this WebSocket-owner runspace writes a subscription queue. The
    # adapter drains it under the same lock, so stale generations cannot leak.
    $encoded = [Text.Encoding]::UTF8.GetByteCount(($Update | ConvertTo-Json -Depth 64 -Compress))
    [Threading.Monitor]::Enter($Record.Gate)
    try {
      if (-not $Record.Active) { return }
      if ($Update.ContainsKey('value')) {
        $canonical = $Update.value | ConvertTo-Json -Depth 64 -Compress
        if ($Record.LastValue -eq $canonical) { return }
        $Record.LastValue = $canonical
      }
      while ($Record.Updates.Count -ge $QueueItems -or ($Record.QueuedBytes + $encoded) -gt $QueueBytes) {
        if ($Record.Updates.Count -eq 0) { break }
        $dropped = $Record.Updates.Dequeue(); $Record.QueuedBytes -= $dropped.Bytes
      }
      if ($encoded -le $QueueBytes) { $Record.Updates.Enqueue([pscustomobject]@{ Bytes = $encoded; Event = $Update }); $Record.QueuedBytes += $encoded }
    } finally { [Threading.Monitor]::Exit($Record.Gate) }
  }
  $socket = $null; $version = Version-Zero; $querySet = 0; $delay = 100; $nextConnect = [datetime]::UtcNow; $receiveTask = $null; $frame = [IO.MemoryStream]::new(); $buffer = [byte[]]::new(4096)
  function Retire($Reason, $EmitErrors) {
    if ($null -ne $socket) { try { $socket.Abort() } catch {}; $socket.Dispose(); $socket = $null; $State.ConnectionCount++; $State.LastCloseReason = $Reason }
    $script:version = Version-Zero; $script:querySet = 0; $script:receiveTask = $null; $script:frame.SetLength(0)
    if ($EmitErrors) { foreach ($record in $State.Subscriptions.Values) { Offer $record @{ error = @{ name = 'TransportError'; message = $Reason } } } }
    $script:nextConnect = [datetime]::UtcNow.AddMilliseconds($script:delay); $script:delay = [Math]::Min($script:delay * 2, 15000)
  }
  function Add-Modification($Record) { @{ type = 'Add'; queryId = $Record.QueryId; udfPath = $Record.Path; args = @($Record.Args) } }
  function Send-Modify($Changes) {
    if ($Changes.Count -eq 0) { return }
    Send-Frame $socket @{ type = 'ModifyQuerySet'; baseVersion = $querySet; newVersion = ($querySet + 1); modifications = @($Changes) }; $script:querySet++
  }
  while (-not $State.Closed) {
    try {
      if ($null -eq $socket -and [datetime]::UtcNow -ge $nextConnect -and $State.Subscriptions.Count -gt 0) {
        $candidate = [Net.WebSockets.ClientWebSocket]::new(); $candidate.Options.SetRequestHeader('Convex-Client', $State.Version)
        $candidate.ConnectAsync([Uri]$State.Endpoint, [Threading.CancellationToken]::None).GetAwaiter().GetResult(); $socket = $candidate; $version = Version-Zero; $querySet = 0; $delay = 100
        $connect = @{ type = 'Connect'; sessionId = [guid]::NewGuid().ToString(); connectionCount = $State.ConnectionCount; lastCloseReason = $State.LastCloseReason; clientTs = 0 }
        if ($null -ne $State.MaxObservedTimestamp) { $connect.maxObservedTimestamp = $State.MaxObservedTimestamp }
        Send-Frame $socket $connect; Send-Modify @($State.Subscriptions.Values | ForEach-Object { Add-Modification $_ })
      }
      $command = $null
      if ($State.Commands.TryTake([ref]$command, 20)) {
        if ($command.Kind -eq 'Stop') { $State.Closed = $true; break }
        if ($command.Kind -eq 'DebugDisconnect') { Retire 'DebugDisconnect' $false; $command.Done.Set() | Out-Null; continue }
        if ($command.Kind -eq 'Subscribe') {
          $State.Subscriptions[$command.Record.Id] = $command.Record
          if ($null -ne $socket) { Send-Modify @(Add-Modification $command.Record) }
          $command.Done.Set() | Out-Null; continue
        }
        if ($command.Kind -eq 'Unsubscribe') {
          $old = $null; if ($State.Subscriptions.TryRemove($command.Id, [ref]$old)) { [Threading.Monitor]::Enter($old.Gate); try { $old.Active = $false; $old.Updates.Clear(); $old.QueuedBytes = 0 } finally { [Threading.Monitor]::Exit($old.Gate) }; if ($null -ne $socket) { Send-Modify @(@{ type = 'Remove'; queryId = $old.QueryId }) } }
          $command.Done.Set() | Out-Null; continue
        }
      }
      if ($null -eq $socket) { continue }
      if ($null -eq $receiveTask) { $receiveTask = $socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), [Threading.CancellationToken]::None) }
      if (-not $receiveTask.Wait(1)) { continue } # preserve partial frame state across the poll timeout
      $result = $receiveTask.GetAwaiter().GetResult(); $receiveTask = $null
      if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { Retire 'TransportError' $true; continue }
      if ($result.MessageType -ne [Net.WebSockets.WebSocketMessageType]::Text) { throw 'server sent a non-text WebSocket frame' }
      $frame.Write($buffer, 0, $result.Count); if ($frame.Length -gt $MaxFrameBytes) { throw 'Live frame exceeds 4 MiB' }; if (-not $result.EndOfMessage) { continue }
      $strict = [Text.UTF8Encoding]::new($false, $true); $message = $strict.GetString($frame.GetBuffer(), 0, [int]$frame.Length) | ConvertFrom-Json -AsHashtable -Depth 64; $frame.SetLength(0)
      if ($message.type -in @('Ping', 'MutationResponse', 'ActionResponse')) { continue }
      if ($message.type -ne 'Transition' -or -not (Same-Version $message.startVersion $version)) { throw 'invalid or out-of-order Live transition' }
      foreach ($modification in @($message.modifications)) {
        if ($modification.type -eq 'QueryRemoved') { continue }
        # Query ids belong to the wire profile while adapter subscription ids are
        # human-controlled strings, so resolve through the owner's active set.
        $record = @($State.Subscriptions.Values | Where-Object { $_.QueryId -eq $modification.queryId } | Select-Object -First 1)
        if ($record.Count -eq 0) { continue }; $record = $record[0]
        if ($modification.type -eq 'QueryUpdated') { if (-not $modification.ContainsKey('value')) { throw 'QueryUpdated omitted value' }; Offer $record @{ value = $modification.value; logs = @($modification.logLines) } }
        elseif ($modification.type -eq 'QueryFailed') { Offer $record @{ error = @{ name = 'FunctionError'; message = [string]($modification.errorMessage ?? 'query failed'); data = $modification.errorData }; logs = @($modification.logLines) } }
        else { throw "unsupported Live modification $($modification.type)" }
      }
      $version = $message.endVersion; $State.MaxObservedTimestamp = $version.ts
    } catch { Retire 'ProtocolError' $true }
  }
  if ($null -ne $socket) { try { $socket.Abort() } catch {}; $socket.Dispose() }
}

function Start-ConvexLive { param($State)
  if ($null -ne $State.Worker) { return }
  $ps = [PowerShell]::Create(); [void]$ps.AddScript($script:ConvexLiveWorker).AddArgument($State).AddArgument($script:ConvexQueueItems).AddArgument($script:ConvexQueueBytes).AddArgument($script:ConvexMaxLiveBytes)
  $State.Worker = [pscustomobject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke() }
}

function New-ConvexSubscriptionRecord { param([string] $Id, [int] $QueryId, [string] $Path, [hashtable] $FunctionArgs)
  [pscustomobject]@{ Id = $Id; QueryId = $QueryId; Path = $Path; Args = $FunctionArgs; Active = $true; Gate = [object]::new(); Updates = [System.Collections.Generic.Queue[object]]::new(); QueuedBytes = 0; LastValue = $null }
}

function Add-ConvexSubscription { param($Live, [string] $Id, [string] $Path, [hashtable] $FunctionArgs)
  Assert-ConvexPath $Path; Start-ConvexLive $Live
  $existing = $null; if ($Live.Subscriptions.TryGetValue($Id, [ref]$existing)) { Remove-ConvexSubscription $Live $Id }
  $queryId = $Live.NextQueryId; $Live.NextQueryId++
  $record = New-ConvexSubscriptionRecord -Id $Id -QueryId $queryId -Path $Path -FunctionArgs ([hashtable]$FunctionArgs)
  $done = [Threading.ManualResetEventSlim]::new($false); $Live.Commands.Add([pscustomobject]@{ Kind = 'Subscribe'; Record = $record; Done = $done })
  if (-not $done.Wait(3000)) { throw 'Live subscribe timed out' }; $record
}

function Remove-ConvexSubscription { param($Live, [string] $Id)
  $done = [Threading.ManualResetEventSlim]::new($false); $Live.Commands.Add([pscustomobject]@{ Kind = 'Unsubscribe'; Id = $Id; Done = $done })
  if (-not $done.Wait(3000)) { throw 'Live unsubscribe timed out' }
}

function Receive-ConvexSubscription { param($Record, [int] $TimeoutMilliseconds = 10000)
  $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
  while ([datetime]::UtcNow -lt $deadline) {
    [Threading.Monitor]::Enter($Record.Gate); try { if ($Record.Updates.Count -gt 0) { $item = $Record.Updates.Dequeue(); $Record.QueuedBytes -= $item.Bytes; return $item.Event } } finally { [Threading.Monitor]::Exit($Record.Gate) }
    Start-Sleep -Milliseconds 5
  }
  throw 'timed out waiting for Live update'
}

function Disconnect-ConvexLiveForAdapter { param($Live)
  $done = [Threading.ManualResetEventSlim]::new($false); $Live.Commands.Add([pscustomobject]@{ Kind = 'DebugDisconnect'; Done = $done })
  if (-not $done.Wait(3000)) { throw 'Live disconnect timed out' }
}

function Close-ConvexLive { param($Live)
  if ($Live.Closed) { return }; $Live.Closed = $true
  if ($null -ne $Live.Worker) { $Live.Commands.Add([pscustomobject]@{ Kind = 'Stop' }); $Live.Worker.PowerShell.EndInvoke($Live.Worker.Handle) | Out-Null; $Live.Worker.PowerShell.Dispose() }
}
