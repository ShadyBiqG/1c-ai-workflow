[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^TASK-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$PlanFile,
    [Parameter(Mandatory = $true)][string]$TestPlanFile,
    [string]$ProjectRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..')) }
if (-not (Test-Path -LiteralPath $PlanFile -PathType Leaf)) { throw "Plan file was not found: $PlanFile" }
if (-not (Test-Path -LiteralPath $TestPlanFile -PathType Leaf)) { throw "Test plan file was not found: $TestPlanFile" }
$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
$statePath = Join-Path $taskDirectory 'state.json'
$configuration = Read-PipelineConfiguration -Path (Join-Path $ProjectRoot '.pipeline\pipeline.yaml')
$state = Read-PipelineJson -Path $statePath
$decompositionPath = Join-Path $taskDirectory 'decomposition.json'
if ([bool]$configuration.manager.require_decomposition -and -not (Test-Path -LiteralPath $decompositionPath -PathType Leaf)) {
    throw 'Manager decomposition must be saved before completing PLAN.'
}
$decomposition = Read-PipelineJson -Path $decompositionPath
$complexity = [string]$decomposition.complexity
$requiresArchitecture = Test-PipelineManagerGate -Configuration $configuration -Gate architecture -Complexity $complexity
$requiresArchitectureReview = Test-PipelineManagerGate -Configuration $configuration -Gate architecture_review -Complexity $complexity
$architecturePath = Join-Path $taskDirectory 'architecture.md'
if ($requiresArchitecture -and -not (Test-Path -LiteralPath $architecturePath -PathType Leaf)) {
    throw 'An architecture artifact must be saved before completing PLAN.'
}
if ($requiresArchitectureReview) {
    $architectureManifestPath = Join-Path $taskDirectory 'architecture.json'
    $architectureReviewPath = Join-Path $taskDirectory 'architecture-review.json'
    if (-not (Test-Path -LiteralPath $architectureManifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $architectureReviewPath -PathType Leaf)) {
        throw 'An approved independent architecture review is required before completing PLAN.'
    }
    $architectureManifest = Read-PipelineJson -Path $architectureManifestPath
    $architectureReview = Read-PipelineJson -Path $architectureReviewPath
    $currentArchitectureHash = Get-PipelineFileSha256 -Path $architecturePath
    if ($architectureReview.decision -ne 'approved' -or
        $architectureReview.architecture_sha256 -ne $currentArchitectureHash -or
        $architectureManifest.architecture_sha256 -ne $currentArchitectureHash -or
        $architectureReview.reviewer_id -eq $architectureManifest.architect_id) {
        throw 'Architecture review is missing, rejected, stale, or not independent.'
    }
}
if (@($configuration.manager.plan_approval_for) -contains [string]$decomposition.complexity) {
    $approvalPath = Join-Path $taskDirectory 'plan-approval.json'
    if (-not (Test-Path -LiteralPath $approvalPath -PathType Leaf)) {
        throw "Explicit user approval is required for a $($decomposition.complexity) plan. Run Approve-PipelinePlan.ps1 first."
    }
    $approval = Read-PipelineJson -Path $approvalPath
    $approvedPlanPath = Join-Path $taskDirectory 'plan.md'
    $approvedTestPlanPath = Join-Path $taskDirectory 'test-plan.md'
    if ($approval.decision -ne 'approved' -or
        $approval.plan_sha256 -ne (Get-PipelineFileSha256 -Path $PlanFile) -or
        $approval.test_plan_sha256 -ne (Get-PipelineFileSha256 -Path $TestPlanFile) -or
        $approval.plan_sha256 -ne (Get-PipelineFileSha256 -Path $approvedPlanPath) -or
        $approval.test_plan_sha256 -ne (Get-PipelineFileSha256 -Path $approvedTestPlanPath) -or
        $approval.decomposition_sha256 -ne (Get-PipelineFileSha256 -Path $decompositionPath) -or
        ($requiresArchitecture -and $approval.architecture_sha256 -ne (Get-PipelineFileSha256 -Path $architecturePath))) {
        throw 'Plan approval is missing, rejected, or does not match the current plan artifacts.'
    }
}
$savedPlanPath = Join-Path $taskDirectory 'plan.md'
Write-PipelineUtf8NoBom -Path $savedPlanPath -Text ([IO.File]::ReadAllText((Resolve-Path $PlanFile), [Text.Encoding]::UTF8))
$savedTestPlanPath = Join-Path $taskDirectory 'test-plan.md'
Write-PipelineUtf8NoBom -Path $savedTestPlanPath -Text ([IO.File]::ReadAllText((Resolve-Path $TestPlanFile), [Text.Encoding]::UTF8))
$state = Set-PipelineEvent -State $state -Event 'plan_completed' -CorrelationId "${TaskId}:plan_completed" -Configuration $configuration -EvidencePath $savedPlanPath
Write-AtomicJson -Path $statePath -Value $state
Add-PipelineJournalRecord -TaskDirectory $taskDirectory -Type 'step' -Phase 'plan' -Actor 'manager' -Summary 'PLAN завершён, задача передана в WORK.' -EvidencePath $savedPlanPath | Out-Null
$state | ConvertTo-Json -Depth 10
