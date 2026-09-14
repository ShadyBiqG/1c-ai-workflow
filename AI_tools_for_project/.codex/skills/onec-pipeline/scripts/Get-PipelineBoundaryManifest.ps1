[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CallerThreadId,
    [string]$ProjectRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
}
$registry = Read-PipelineThreadRegistry -Path (Join-Path $ProjectRoot '.pipeline\local\threads.json')
$targets = @(Get-PipelineBoundaryTargets -Registry $registry -ControllerThreadId $CallerThreadId)
[ordered]@{
    protocol_version = 1
    project_id = $registry.project_id
    controller_thread_id = $CallerThreadId
    targets = $targets
    validated_at = [datetime]::UtcNow.ToString('o')
} | ConvertTo-Json -Depth 10
