[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^TASK-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$SummaryFile,
    [string]$ProjectRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..')) }
if (-not (Test-Path -LiteralPath $SummaryFile -PathType Leaf)) { throw "Summary file was not found: $SummaryFile" }
$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
$state = Read-PipelineJson -Path (Join-Path $taskDirectory 'state.json')
if ($state.status -ne 'ready') { throw "Task summary can be finalized only in ready state, got: $($state.status)" }
$summaryPath = Join-Path $taskDirectory 'summary.md'
Write-PipelineUtf8NoBom -Path $summaryPath -Text ([IO.File]::ReadAllText((Resolve-Path $SummaryFile), [Text.Encoding]::UTF8))
Add-PipelineJournalRecord -TaskDirectory $taskDirectory -Type 'step' -Phase 'ready' -Actor 'manager' -Summary 'Итоговый артефакт задачи сохранён.' -EvidencePath $summaryPath | Out-Null
[pscustomobject][ordered]@{ task_id = $TaskId; status = $state.status; summary_path = $summaryPath } | ConvertTo-Json -Depth 5
