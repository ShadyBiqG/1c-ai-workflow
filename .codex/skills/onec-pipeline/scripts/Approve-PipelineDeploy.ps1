[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^TASK-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$ScenarioFile,
    [string]$ApprovedBy = 'human:user',
    [string]$Comment,
    [string]$ProjectRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..')) }
if (-not (Test-Path -LiteralPath $ScenarioFile -PathType Leaf)) { throw "Deploy scenario was not found: $ScenarioFile" }
$configuration = Read-PipelineConfiguration -Path (Join-Path $ProjectRoot '.pipeline\pipeline.yaml')
if (-not [bool]$configuration.deploy.enabled -or -not [bool]$configuration.deploy.available) { throw 'Deploy is disabled or unavailable.' }
$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
$statePath = Join-Path $taskDirectory 'state.json'
$state = Read-PipelineJson -Path $statePath
if ($state.status -ne 'deploy_pending') { throw "Deploy can be approved only in deploy_pending state, got: $($state.status)" }
$scenarioPath = Join-Path $taskDirectory 'deploy-scenario.md'
Write-PipelineUtf8NoBom -Path $scenarioPath -Text ([IO.File]::ReadAllText((Resolve-Path $ScenarioFile), [Text.Encoding]::UTF8))
$approval = [ordered]@{
    protocol_version = 1; task_id = $TaskId; decision = 'approved'; approved_by = $ApprovedBy
    approved_at = [datetime]::UtcNow.ToString('o'); comment = $Comment
    scenario_sha256 = Get-PipelineFileSha256 -Path $scenarioPath
}
$approvalPath = Join-Path $taskDirectory 'deploy-approval.json'
Write-AtomicJson -Path $approvalPath -Value $approval
$state = Set-PipelineEvent -State $state -Event 'deploy_approved' -CorrelationId "${TaskId}:deploy_approved:$($approval.scenario_sha256)" -Configuration $configuration -EvidencePath $approvalPath
Write-AtomicJson -Path $statePath -Value $state
Add-PipelineJournalRecord -TaskDirectory $taskDirectory -Type 'approval' -Phase 'deploy' -Actor $ApprovedBy -Summary 'Пользователь одобрил неизменный сценарий Deploy.' -Rationale $Comment -EvidencePath $approvalPath | Out-Null
[pscustomobject][ordered]@{ task_id = $TaskId; next_state = $state.status; scenario_sha256 = $approval.scenario_sha256; approval_path = $approvalPath } | ConvertTo-Json -Depth 5
