[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)]$Configuration)

. (Join-Path $PSScriptRoot '_v8_runner.ps1')
Invoke-PipelineV8RunnerCheck -ProjectRoot $ProjectRoot -Configuration $Configuration -Name 'tests' -Arguments @(
    'test', 'yaxunit', '--no-build', 'all'
)
