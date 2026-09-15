[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^TASK-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')][string]$TaskId,
    [Parameter(Mandatory = $true)][ValidateSet('approved', 'changes_requested')][string]$Verdict,
    [Parameter(Mandatory = $true)][string]$EvidenceFile,
    [string]$ProjectRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..')) }
if (-not (Test-Path -LiteralPath $EvidenceFile -PathType Leaf)) { throw "REVIEW evidence was not found: $EvidenceFile" }
$configuration = Read-PipelineConfiguration -Path (Join-Path $ProjectRoot '.pipeline\pipeline.yaml')
$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
$statePath = Join-Path $taskDirectory 'state.json'
$state = Read-PipelineJson -Path $statePath
$reviewId = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$savedEvidencePath = Join-Path $taskDirectory "review-evidence-$reviewId.txt"
Write-PipelineUtf8NoBom -Path $savedEvidencePath -Text ([IO.File]::ReadAllText((Resolve-Path $EvidenceFile), [Text.Encoding]::UTF8))
$event = if ($Verdict -eq 'approved') { 'review_approved' } else { 'review_changes_requested' }
$state = Set-PipelineEvent -State $state -Event $event -CorrelationId "${TaskId}:${event}:${reviewId}" -Configuration $configuration -EvidencePath $savedEvidencePath
Write-AtomicJson -Path $statePath -Value $state
Add-PipelineJournalRecord -TaskDirectory $taskDirectory -Type 'decision' -Phase 'review' -Actor 'reviewer' -Summary "REVIEW verdict: $Verdict; следующее состояние: $($state.status)." -EvidencePath $savedEvidencePath | Out-Null
[pscustomobject][ordered]@{ task_id = $TaskId; verdict = $Verdict; next_state = $state.status; evidence_path = $savedEvidencePath } | ConvertTo-Json -Depth 5
