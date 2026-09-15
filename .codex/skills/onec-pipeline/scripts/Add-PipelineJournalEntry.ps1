[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^TASK-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')][string]$TaskId,
    [Parameter(Mandatory = $true)][ValidateSet('step', 'decision', 'question', 'approval', 'risk', 'note')][string]$Type,
    [Parameter(Mandatory = $true)][ValidateSet('plan', 'work', 'verify', 'review', 'ready')][string]$Phase,
    [Parameter(Mandatory = $true)][string]$Summary,
    [string]$Actor = 'manager',
    [string]$Rationale,
    [string]$EvidencePath,
    [string]$ProjectRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..')) }
$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
Read-PipelineJson -Path (Join-Path $taskDirectory 'state.json') | Out-Null
$entry = Add-PipelineJournalRecord -TaskDirectory $taskDirectory -Type $Type -Phase $Phase -Actor $Actor -Summary $Summary -Rationale $Rationale -EvidencePath $EvidencePath
$entry | ConvertTo-Json -Depth 5
