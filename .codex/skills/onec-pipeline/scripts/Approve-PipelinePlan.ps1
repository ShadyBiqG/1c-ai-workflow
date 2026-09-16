[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^TASK-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$PlanFile,
    [Parameter(Mandatory = $true)][string]$TestPlanFile,
    [string]$ApprovedBy = 'human:user',
    [string]$Comment,
    [string]$ProjectRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..')) }
$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
$state = Read-PipelineJson -Path (Join-Path $taskDirectory 'state.json')
if ($state.status -ne 'plan') { throw "Plan can be approved only in plan state, got: $($state.status)" }
$decompositionPath = Join-Path $taskDirectory 'decomposition.json'
$savedPlanPath = Join-Path $taskDirectory 'plan.md'
$savedTestPlanPath = Join-Path $taskDirectory 'test-plan.md'
$architecturePath = Join-Path $taskDirectory 'architecture.md'
Write-PipelineUtf8NoBom -Path $savedPlanPath -Text ([IO.File]::ReadAllText((Resolve-Path $PlanFile), [Text.Encoding]::UTF8))
Write-PipelineUtf8NoBom -Path $savedTestPlanPath -Text ([IO.File]::ReadAllText((Resolve-Path $TestPlanFile), [Text.Encoding]::UTF8))
$approval = [ordered]@{
    protocol_version = 1
    task_id = $TaskId
    decision = 'approved'
    approved_by = $ApprovedBy
    approved_at = [datetime]::UtcNow.ToString('o')
    comment = $Comment
    plan_sha256 = Get-PipelineFileSha256 -Path $savedPlanPath
    test_plan_sha256 = Get-PipelineFileSha256 -Path $savedTestPlanPath
    decomposition_sha256 = Get-PipelineFileSha256 -Path $decompositionPath
    architecture_sha256 = if (Test-Path -LiteralPath $architecturePath -PathType Leaf) { Get-PipelineFileSha256 -Path $architecturePath } else { $null }
}
$approvalPath = Join-Path $taskDirectory 'plan-approval.json'
Write-AtomicJson -Path $approvalPath -Value $approval
Add-PipelineJournalRecord -TaskDirectory $taskDirectory -Type 'approval' -Phase 'plan' -Actor $ApprovedBy -Summary 'Пользователь явно одобрил план реализации.' -Rationale $Comment -EvidencePath $approvalPath | Out-Null
$approval | ConvertTo-Json -Depth 5
