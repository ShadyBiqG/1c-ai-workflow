[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^TASK-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')][string]$TaskId,
    [Parameter(Mandatory = $true)][ValidateSet('succeeded', 'failed')][string]$Status,
    [Parameter(Mandatory = $true)][string]$EvidenceFile,
    [string]$ProjectRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..')) }
if (-not (Test-Path -LiteralPath $EvidenceFile -PathType Leaf)) { throw "Deploy evidence was not found: $EvidenceFile" }
$configuration = Read-PipelineConfiguration -Path (Join-Path $ProjectRoot '.pipeline\pipeline.yaml')
$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
$statePath = Join-Path $taskDirectory 'state.json'
$state = Read-PipelineJson -Path $statePath
if ($state.status -ne 'deploy') { throw "Deploy can be completed only in deploy state, got: $($state.status)" }
$scenarioPath = Join-Path $taskDirectory 'deploy-scenario.md'
$approval = Read-PipelineJson -Path (Join-Path $taskDirectory 'deploy-approval.json')
if ($approval.decision -ne 'approved' -or $approval.scenario_sha256 -ne (Get-PipelineFileSha256 -Path $scenarioPath)) {
    throw 'Deploy approval is missing or does not match the current scenario.'
}
$runId = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$savedEvidencePath = Join-Path $taskDirectory "deploy-evidence-$runId.md"
Write-PipelineUtf8NoBom -Path $savedEvidencePath -Text ([IO.File]::ReadAllText((Resolve-Path $EvidenceFile), [Text.Encoding]::UTF8))
$event = if ($Status -eq 'succeeded') { 'deploy_succeeded' } else { 'deploy_failed' }
$state = Set-PipelineEvent -State $state -Event $event -CorrelationId "${TaskId}:${event}:$runId" -Configuration $configuration -EvidencePath $savedEvidencePath
Write-AtomicJson -Path $statePath -Value $state
Add-PipelineJournalRecord -TaskDirectory $taskDirectory -Type 'step' -Phase 'deploy' -Actor 'deploy' -Summary "Deploy: $Status; следующее состояние: $($state.status)." -EvidencePath $savedEvidencePath | Out-Null
[pscustomobject][ordered]@{ task_id = $TaskId; status = $Status; next_state = $state.status; evidence_path = $savedEvidencePath } | ConvertTo-Json -Depth 5
