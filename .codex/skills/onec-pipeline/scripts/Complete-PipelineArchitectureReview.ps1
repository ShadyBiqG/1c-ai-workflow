[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^TASK-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')][string]$TaskId,
    [Parameter(Mandatory = $true)][ValidateSet('approved', 'changes_requested')][string]$Verdict,
    [Parameter(Mandatory = $true)][string]$EvidenceFile,
    [Parameter(Mandatory = $true)][string]$ReviewerId,
    [string]$ProjectRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..')) }
if (-not (Test-Path -LiteralPath $EvidenceFile -PathType Leaf)) { throw "Architecture review evidence was not found: $EvidenceFile" }
if ([string]::IsNullOrWhiteSpace($ReviewerId)) { throw 'ReviewerId must not be empty.' }
$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
$state = Read-PipelineJson -Path (Join-Path $taskDirectory 'state.json')
if ($state.status -ne 'plan') { throw "Architecture review can be completed only in plan state, got: $($state.status)" }
$architecturePath = Join-Path $taskDirectory 'architecture.md'
$manifest = Read-PipelineJson -Path (Join-Path $taskDirectory 'architecture.json')
if ($ReviewerId -eq $manifest.architect_id) { throw 'Architecture reviewer must be independent from the architect.' }
$currentArchitectureHash = Get-PipelineFileSha256 -Path $architecturePath
if ($manifest.architecture_sha256 -ne $currentArchitectureHash) {
    throw 'Architecture artifact changed outside Save-PipelineArchitecture.ps1 and must be saved again before review.'
}
$reviewId = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$reviewDirectory = Join-Path $taskDirectory 'architecture-reviews'
[IO.Directory]::CreateDirectory($reviewDirectory) | Out-Null
$savedEvidencePath = Join-Path $reviewDirectory "review-$reviewId.md"
Write-PipelineUtf8NoBom -Path $savedEvidencePath -Text ([IO.File]::ReadAllText((Resolve-Path $EvidenceFile), [Text.Encoding]::UTF8))
$review = [ordered]@{
    protocol_version = 1
    task_id = $TaskId
    decision = $Verdict
    reviewer_id = $ReviewerId
    architect_id = $manifest.architect_id
    architecture_sha256 = $currentArchitectureHash
    evidence_path = $savedEvidencePath
    reviewed_at = [datetime]::UtcNow.ToString('o')
}
$reviewPath = Join-Path $taskDirectory 'architecture-review.json'
Write-AtomicJson -Path $reviewPath -Value $review
$summary = if ($Verdict -eq 'approved') { 'Архитектура одобрена и возвращена Manager.' } else { 'Архитектура возвращена Architect на доработку.' }
Add-PipelineJournalRecord -TaskDirectory $taskDirectory -Type 'decision' -Phase 'plan' -Actor $ReviewerId -Summary $summary -Rationale $Verdict -EvidencePath $savedEvidencePath | Out-Null
[pscustomobject][ordered]@{ task_id = $TaskId; verdict = $Verdict; next_actor = $(if ($Verdict -eq 'approved') { 'manager' } else { 'architect' }); evidence_path = $savedEvidencePath } | ConvertTo-Json -Depth 5
