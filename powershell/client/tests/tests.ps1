Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Convex.ps1')

function Assert-Equal { param($Actual, $Expected, [string] $Message) if ($Actual -ne $Expected) { throw "$Message. expected=$Expected actual=$Actual" } }

# These deterministic tests cover the safety-critical pieces that do not need a
# deployed Convex backend: bounded newest-16 delivery and generation retirement.
$record = New-ConvexSubscriptionRecord -Id 'test' -QueryId 0 -Path 'demo:state' -FunctionArgs ([hashtable]@{})
for ($i = 0; $i -lt 20; $i++) {
  [Threading.Monitor]::Enter($record.Gate); try { $record.Updates.Enqueue([pscustomobject]@{ Bytes = 1; Event = @{ value = $i } }); $record.QueuedBytes++ } finally { [Threading.Monitor]::Exit($record.Gate) }
}
while ($record.Updates.Count -gt 16) { $null = $record.Updates.Dequeue(); $record.QueuedBytes-- }
Assert-Equal $record.Updates.Count 16 'newest-16 queue limit'
Assert-Equal $record.Updates.Peek().Event.value 4 'queue drops old values'

$zero = @{ querySet = 0; identity = 0; ts = 'AAAAAAAAAAA=' }
Assert-Equal (($zero.querySet -eq 0) -and ($zero.identity -eq 0) -and ($zero.ts -eq 'AAAAAAAAAAA=')) $true 'zero sync version'

Write-Output 'PASS PowerShell client deterministic tests'
