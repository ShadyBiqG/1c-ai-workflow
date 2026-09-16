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
if ([string]::IsNullOrWhiteSpace($ConfigurationPath)) { $ConfigurationPath = Join-Path $ProjectRoot '.pipeline\pipeline.json' }
$configuration = Read-PipelineConfiguration -Path $ConfigurationPath
$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
$statePath = Join-Path $taskDirectory 'state.json'
$state = Read-PipelineJson -Path $statePath
$runId = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$logDirectory = Join-Path $taskDirectory "verify-logs\$runId"

if ($state.status -eq 'work') {
    Test-PipelineExecutionReady -TaskDirectory $taskDirectory -Configuration $configuration | Out-Null
    $state = Set-PipelineEvent -State $state -Event 'work_completed' -CorrelationId "${TaskId}:work_completed:$runId" -Configuration $configuration
    Write-AtomicJson -Path $statePath -Value $state
}
elseif ($state.status -ne 'verify') { throw "VERIFY can start only from work or verify, got: $($state.status)" }

$checkResults = [ordered]@{}
$changedFiles = @()
foreach ($checkName in @($configuration.verify.checks)) {
    $dependencies = @()
    if ($configuration.verify.depends_on.Contains($checkName)) { $dependencies = @($configuration.verify.depends_on[$checkName]) }
    $blockedDependencies = @($dependencies | Where-Object { -not $checkResults.Contains($_) -or $checkResults[$_].status -ne 'passed' })
    if ($blockedDependencies.Count -gt 0) {
        $checkResults[$checkName] = [pscustomobject][ordered]@{
            status = 'skipped'; summary = "Проверка пропущена: не пройдены зависимости $($blockedDependencies -join ', ')."
            unmet_dependencies = $blockedDependencies; log_path = $null; duration_ms = 0
        }
        continue
    }
    $checkPath = Join-Path $PSScriptRoot ("verify-checks\{0}.ps1" -f $checkName)
    if (-not (Test-Path -LiteralPath $checkPath -PathType Leaf)) {
        $checkResults[$checkName] = [pscustomobject][ordered]@{ status = 'failed'; summary = "Не найдена проверка: $checkName"; log_path = $null; duration_ms = 0 }
        continue
    }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $command = Get-Command -LiteralPath $checkPath
        $missingParameters = @(@('ProjectRoot', 'Configuration', 'TaskDirectory') | Where-Object { -not $command.Parameters.ContainsKey($_) })
        if ($missingParameters.Count -gt 0) { throw "Проверка '$checkName' не поддерживает контракт VERIFY: отсутствуют параметры $($missingParameters -join ', ')." }
        $result = & $checkPath -ProjectRoot $ProjectRoot -Configuration $configuration -TaskDirectory $taskDirectory
        if ($null -eq $result -or $result.status -notin @('passed', 'failed', 'not_run')) { throw "Проверка $checkName вернула некорректный результат." }
    }
    catch { $result = [pscustomobject][ordered]@{ status = 'failed'; summary = $_.Exception.Message; full_output = @($_.ScriptStackTrace) } }
    finally { $stopwatch.Stop() }

    $fullOutput = @()
    if ($result.PSObject.Properties.Name -contains 'full_output') { $fullOutput = @($result.full_output | ForEach-Object { [string]$_ }) }
    $logPath = $null
    if ($result.status -in @('passed', 'failed')) {
        [IO.Directory]::CreateDirectory($logDirectory) | Out-Null
        $logFile = Join-Path $logDirectory "$checkName.log"
        $logText = if ($fullOutput.Count -gt 0) { $fullOutput -join [Environment]::NewLine } else { [string]$result.summary }
        Write-PipelineUtf8NoBom -Path $logFile -Text $logText
        $logPath = $logFile.Substring($ProjectRoot.Length).TrimStart('\', '/').Replace('\', '/')
    }
    if ($result.PSObject.Properties.Name -contains 'full_output') { $result.PSObject.Properties.Remove('full_output') }
    $result | Add-Member -NotePropertyName log_path -NotePropertyValue $logPath -Force
    $result | Add-Member -NotePropertyName duration_ms -NotePropertyValue ([int64]$stopwatch.ElapsedMilliseconds) -Force
    $checkResults[$checkName] = $result
    if ($result.PSObject.Properties.Name -contains 'changed_files') {
        $changedFiles = @($result.changed_files)
        Write-AtomicJson -Path (Join-Path $taskDirectory 'verify-context.json') -Value ([ordered]@{ changed_files = $changedFiles })
    }
}

$failedChecks = @($checkResults.Keys | Where-Object { $checkResults[$_].status -eq 'failed' })
$notRunChecks = @($checkResults.Keys | Where-Object { $checkResults[$_].status -eq 'not_run' })
$skippedChecks = @($checkResults.Keys | Where-Object { $checkResults[$_].status -eq 'skipped' })
$blockingChecks = @($failedChecks + $skippedChecks)
if ([bool]$configuration.verify.fail_on_not_run) { $blockingChecks += $notRunChecks }
$blockingChecks = @($blockingChecks | Select-Object -Unique)
$status = if ($blockingChecks.Count -gt 0) { 'failed' } else { 'passed' }
$nextState = if ($status -eq 'failed') { 'work' } else { Get-PostVerifyTarget -Configuration $configuration }
$evidence = [ordered]@{
    protocol_version = 1; task_id = $TaskId; run_id = $runId; status = $status
    changed_files = $changedFiles; checks = $checkResults; failed_checks = $failedChecks
    not_run_checks = $notRunChecks; skipped_checks = $skippedChecks; blocking_checks = $blockingChecks
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
else { $state = Set-PipelineEvent -State $state -Event 'verify_passed' -CorrelationId "${TaskId}:verify_passed:$runId" -Configuration $configuration -EvidencePath $evidencePath }
Write-AtomicJson -Path $statePath -Value $state
$rationale = if ($blockingChecks.Count -gt 0) { "Блокирующие проверки: $($blockingChecks -join ', ')." } elseif ($notRunChecks.Count -gt 0) { "Необязательные проверки не запущены: $($notRunChecks -join ', ')." } else { 'Все обязательные проверки успешно выполнены.' }
Add-PipelineJournalRecord -TaskDirectory $taskDirectory -Type 'step' -Phase 'verify' -Actor 'verify' -Summary "VERIFY: $status; следующее состояние: $($state.status)." -Rationale $rationale -EvidencePath $evidencePath | Out-Null
[pscustomobject][ordered]@{ task_id = $TaskId; status = $status; next_state = $state.status; evidence_path = $evidencePath; failed_checks = $failedChecks; not_run_checks = $notRunChecks; skipped_checks = $skippedChecks; blocking_checks = $blockingChecks } | ConvertTo-Json -Depth 10
