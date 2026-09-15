[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('controller', 'explorer', 'manager', 'plan', 'architect', 'architecture-reviewer', 'test-designer', 'reviewer', 'work', 'worker', 'deploy')][string]$Role,
    [string]$ProjectRoot,
    [string]$ConfigurationPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..')) }
if ([string]::IsNullOrWhiteSpace($ConfigurationPath)) { $ConfigurationPath = Join-Path $ProjectRoot '.pipeline\pipeline.yaml' }
$configuration = Read-PipelineConfiguration -Path $ConfigurationPath
Get-PipelineAgentProfile -Configuration $configuration -Role $Role | ConvertTo-Json -Depth 5
