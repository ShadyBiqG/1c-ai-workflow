[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ProjectRoot, [Parameter(Mandatory = $true)]$Configuration, [Parameter(Mandatory = $true)][string]$TaskDirectory)

. (Join-Path $PSScriptRoot '_v8_runner.ps1')
Invoke-PipelineV8RunnerCheck -ProjectRoot $ProjectRoot -Configuration $Configuration -TaskDirectory $TaskDirectory -Name 'build' -Arguments @('build')
