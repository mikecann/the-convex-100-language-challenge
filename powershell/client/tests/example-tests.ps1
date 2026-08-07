Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load the conversion function from the exact canonical source without running
# its network journey. This keeps the README code and regression under one source.
$examplePath = Join-Path $PSScriptRoot '../../examples/basics/main.ps1'
$tokens = $null
$parseErrors = $null
$exampleAst = [Management.Automation.Language.Parser]::ParseFile(
    $examplePath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count) { throw 'canonical example did not parse' }
$conversionAst = @(
    $exampleAst.FindAll(
        { param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertTo-WholeCount' },
        $true
    )
)[0]
Invoke-Expression $conversionAst.Extent.Text

function Assert-WholeCount($Value, [int]$Expected) {
    $actual = ConvertTo-WholeCount $Value 'test'
    if ($actual -ne $Expected) { throw "whole count expected $Expected, got $actual" }
}

function Assert-RejectedCount($Value) {
    try {
        ConvertTo-WholeCount $Value 'test' | Out-Null
        throw 'invalid count was accepted'
    }
    catch {
        if ($_.Exception.Message -eq 'invalid count was accepted') { throw }
    }
}

Assert-WholeCount ([double]0.0) 0
Assert-WholeCount ([decimal]1.0) 1
Assert-WholeCount ([long][int]::MaxValue) ([int]::MaxValue)
Assert-RejectedCount ([double]0.5)
Assert-RejectedCount '1'
Assert-RejectedCount $true
Assert-RejectedCount ([double]::NaN)
Assert-RejectedCount ([double]::PositiveInfinity)
Assert-RejectedCount ([double][int]::MaxValue + 1)
Write-Output 'PASS PowerShell canonical integral-number decoding regressions'
