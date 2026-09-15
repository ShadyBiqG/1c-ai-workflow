[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^TASK-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')][string]$TaskId,
    [string]$ProjectRoot,
    [string]$ConfigurationPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..')) }
if ([string]::IsNullOrWhiteSpace($ConfigurationPath)) { $ConfigurationPath = Join-Path $ProjectRoot '.pipeline\pipeline.yaml' }
$configuration = Read-PipelineConfiguration -Path $ConfigurationPath
$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
$statePath = Join-Path $taskDirectory 'state.json'
$state = Read-PipelineJson -Path $statePath
$runId = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')

if ($state.status -eq 'work') {
    Test-PipelineExecutionReady -TaskDirectory $taskDirectory -Configuration $configuration | Out-Null
    $state = Set-PipelineEvent -State $state -Event 'work_completed' -CorrelationId "${TaskId}:work_completed:$runId" -Configuration $configuration
    Write-AtomicJson -Path $statePath -Value $state
}
elseif ($state.status -ne 'verify') { throw "VERIFY can start only from work or verify, got: $($state.status)" }

$checkResults = [ordered]@{}
$changedFiles = @()
foreach ($checkName in @($configuration.verify.checks)) {
    $checkPath = Join-Path $PSScriptRoot ("verify-checks\{0}.ps1" -f $checkName)
    if (-not (Test-Path -LiteralPath $checkPath -PathType Leaf)) {
        $checkResults[$checkName] = [ordered]@{ status = 'failed'; summary = "Не найдена проверка: $checkName" }
        continue
    }
    try {
        $result = & $checkPath -ProjectRoot $ProjectRoot -Configuration $configuration
        if ($null -eq $result -or $result.status -notin @('passed', 'failed', 'not_run')) { throw "Проверка $checkName вернула некорректный результат." }
        $checkResults[$checkName] = $result
        if ($result.PSObject.Properties.Name -contains 'changed_files') { $changedFiles = @($result.changed_files) }
    }
    catch { $checkResults[$checkName] = [ordered]@{ status = 'failed'; summary = $_.Exception.Message } }
}

$failedChecks = @($checkResults.Keys | Where-Object { $checkResults[$_].status -eq 'failed' })
$notRunChecks = @($checkResults.Keys | Where-Object { $checkResults[$_].status -eq 'not_run' })
$blockingChecks = @($failedChecks)
if ([bool]$configuration.verify.fail_on_not_run) {
    $blockingChecks += $notRunChecks
}
$blockingChecks = @($blockingChecks | Select-Object -Unique)
$status = if ($blockingChecks.Count -gt 0) { 'failed' } else { 'passed' }
$nextState = if ($status -eq 'failed') { 'work' } else { Get-PostVerifyTarget -Configuration $configuration }
$evidence = [ordered]@{
    protocol_version = 1; task_id = $TaskId; run_id = $runId; status = $status
    changed_files = $changedFiles; checks = $checkResults; failed_checks = $failedChecks
    not_run_checks = $notRunChecks; blocking_checks = $blockingChecks
    review = [ordered]@{ mode = $configuration.review.mode; available = [bool]$configuration.review.available; provider = $configuration.review.provider }
    next_state = $nextState; completed_at = [datetime]::UtcNow.ToString('o')
}
$evidencePath = Join-Path $taskDirectory 'verify-evidence.json'
$historyPath = Join-Path $taskDirectory "verify-evidence-$runId.json"
Write-AtomicJson -Path $historyPath -Value $evidence
Write-AtomicJson -Path $evidencePath -Value $evidence

if ($status -eq 'failed') {
    $state = Set-PipelineEvent -State $state -Event 'verify_failed' -CorrelationId "${TaskId}:verify_failed:$runId" -Configuration $configuration -EvidencePath $evidencePath
    $state = Set-PipelineEvent -State $state -Event 'return_to_work' -CorrelationId "${TaskId}:return_to_work:$runId" -Configuration $configuration -EvidencePath $evidencePath
}
else {
    $state = Set-PipelineEvent -State $state -Event 'verify_passed' -CorrelationId "${TaskId}:verify_passed:$runId" -Configuration $configuration -EvidencePath $evidencePath
}
Write-AtomicJson -Path $statePath -Value $state
$rationale = if ($blockingChecks.Count -gt 0) {
    "Блокирующие проверки: $($blockingChecks -join ', ')."
}
elseif ($notRunChecks.Count -gt 0) {
    "Необязательные проверки не запущены: $($notRunChecks -join ', ')."
}
else {
    'Все обязательные проверки успешно выполнены.'
}
Add-PipelineJournalRecord -TaskDirectory $taskDirectory -Type 'step' -Phase 'verify' -Actor 'verify' -Summary "VERIFY: $status; следующее состояние: $($state.status)." -Rationale $rationale -EvidencePath $evidencePath | Out-Null
[pscustomobject][ordered]@{ task_id = $TaskId; status = $status; next_state = $state.status; evidence_path = $evidencePath; failed_checks = $failedChecks; not_run_checks = $notRunChecks; blocking_checks = $blockingChecks } | ConvertTo-Json -Depth 10
