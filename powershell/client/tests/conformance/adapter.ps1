#!/usr/bin/pwsh
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../../Convex.ps1')

function Write-AdapterEvent { param($Writer, [hashtable] $Event) $Writer.WriteLine(($Event | ConvertTo-Json -Depth 64 -Compress)); $Writer.Flush() }
function Write-AdapterFailure {
  param($Writer, [string] $Id, [string] $SubscriptionId, $Exception)
  $error = Get-ConvexError $Exception
  $detail = @{ name = $error.Name; message = $error.Message }; if ($null -ne $error.Data) { $detail.data = $error.Data }
  $event = @{ type = if ($SubscriptionId) { 'subscription' } else { 'error' }; error = $detail }
  if ($Id) { $event.id = $Id }; if ($SubscriptionId) { $event.subscriptionId = $SubscriptionId }; if ($error.Logs.Count) { $event.logs = @($error.Logs) }
  Write-AdapterEvent $Writer $event
}
function Drain-Subscriptions { param($Writer, $Subscriptions)
  foreach ($entry in @($Subscriptions.GetEnumerator())) {
    $record = $entry.Value
    [Threading.Monitor]::Enter($record.Gate)
    try {
      while ($record.Updates.Count -gt 0) {
        $item = $record.Updates.Dequeue(); $record.QueuedBytes -= $item.Bytes
        if (-not $record.Active) { continue }
        $event = @{ type = 'subscription'; subscriptionId = $entry.Key }
        if ($item.Event.ContainsKey('error')) { $event.error = $item.Event.error } else { $event.value = $item.Event.value }
        if ($item.Event.logs.Count) { $event.logs = @($item.Event.logs) }
        Write-AdapterEvent $Writer $event
      }
    } finally { [Threading.Monitor]::Exit($record.Gate) }
  }
}
function Run-Adapter { param($Reader, $Writer, [string] $Url)
  $client = $null; $live = $null; $subs = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new(); $readTask = $Reader.ReadLineAsync(); $closed = $false
  try {
    while (-not $closed) {
      Drain-Subscriptions $Writer $subs
      if (-not $readTask.Wait(20)) { continue }
      $line = $readTask.GetAwaiter().GetResult(); $readTask = $Reader.ReadLineAsync()
      if ($null -eq $line) { break }; if ($line.Length -gt 65536) { Write-AdapterFailure $Writer '' '' ([Exception]::new('NDJSON command exceeds 64 KiB')); continue }
      try { $command = ConvertFrom-ConvexJson $line; if ($command -isnot [hashtable]) { throw 'command is not a JSON object' } } catch { Write-AdapterFailure $Writer '' '' $_.Exception; continue }
      $id = [string]$command.id
      try {
        switch ($command.op) {
          'hello' { if ($command.protocolVersion -ne 1) { throw 'unsupported adapter protocol version' }; Write-AdapterEvent $Writer @{ protocolVersion = 1; id = $id; type = 'ready'; language = 'powershell'; implementation = 'native-powershell-7.5.0'; runtime = "PowerShell-$($PSVersionTable.PSVersion)" } }
          'close' { foreach ($sid in @($subs.Keys)) { Remove-ConvexSubscription $live $sid }; $subs.Clear(); if ($live) { Close-ConvexLive $live }; if ($client) { Close-ConvexClient $client }; Write-AdapterEvent $Writer @{ id = $id; type = 'closed' }; $closed = $true }
          'setAuth' { if (-not $client) { $client = New-ConvexClient $Url }; Set-ConvexAuth $client ([string]$command.token); Write-AdapterEvent $Writer @{ id = $id; type = 'ack' } }
          { $_ -in @('query', 'mutation', 'action') } { if (-not $client) { $client = New-ConvexClient $Url }; $result = Invoke-ConvexFunction $client $command.op ([string]$command.path) $command.args; $event = @{ id = $id; type = 'result'; value = $result.Value }; if ($result.Logs.Count) { $event.logs = @($result.Logs) }; Write-AdapterEvent $Writer $event }
          'subscribe' { if (-not $live) { $live = New-ConvexLiveState $Url }; $record = Add-ConvexSubscription $live ([string]$command.subscriptionId) ([string]$command.path) $command.args; $subs[[string]$command.subscriptionId] = $record; Write-AdapterEvent $Writer @{ id = $id; type = 'ack' } }
          'unsubscribe' { if ($live) { Remove-ConvexSubscription $live ([string]$command.subscriptionId) }; $old = $null; $subs.TryRemove([string]$command.subscriptionId, [ref]$old) | Out-Null; Write-AdapterEvent $Writer @{ id = $id; type = 'ack' } }
          'debugDisconnect' { if (-not $live) { throw 'Live WebSocket is not connected' }; Disconnect-ConvexLiveForAdapter $live; Write-AdapterEvent $Writer @{ id = $id; type = 'ack' } }
          default { throw "unknown operation $($command.op)" }
        }
      } catch { Write-AdapterFailure $Writer $id '' $_.Exception }
    }
  } finally { if ($live) { Close-ConvexLive $live }; if ($client) { Close-ConvexClient $client } }
}

if ($env:ADAPTER_LISTEN) {
  $parts = $env:ADAPTER_LISTEN.Split(':'); if ($parts.Count -ne 2) { throw 'ADAPTER_LISTEN must be host:port' }
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse($parts[0]), [int]$parts[1]); $listener.Start(); try { $tcp = $listener.AcceptTcpClient(); $stream = $tcp.GetStream(); Run-Adapter -Reader ([IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $false, 4096, $true)) -Writer ([IO.StreamWriter]::new($stream, [Text.Encoding]::UTF8, 4096, $true)) -Url $env:CONVEX_URL } finally { $listener.Stop() }
} else { Run-Adapter -Reader ([Console]::In) -Writer ([Console]::Out) -Url $env:CONVEX_URL }
