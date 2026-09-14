[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^UT-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')]
    [string]$TaskId,
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$ProjectSnapshotFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pipelineModule = Join-Path $PSScriptRoot 'PipelineState.psm1'
Import-Module $pipelineModule -Force

$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
$statePath = Join-Path $taskDirectory 'state.json'
$compactionPath = Join-Path $taskDirectory 'compaction.json'
$runtimeDirectory = Join-Path $ProjectRoot ".pipeline\runtime\$TaskId"
$threadsPath = Join-Path $ProjectRoot '.pipeline\local\threads.json'
$claudeRegistryPath = Join-Path $ProjectRoot '.pipeline\local\claude-session.json'
$claudeScript = Join-Path $ProjectRoot '.codex\skills\claude-consilium\scripts\Invoke-ClaudeConsilium.ps1'
$phaseOnePath = Join-Path $runtimeDirectory 'codex-phase1.json'
$taskReadyPath = Join-Path $runtimeDirectory 'task-ready.json'

$state = Read-PipelineJson -Path $statePath
try {
    if ($state.status -eq 'plan_requested') {
        $delivery = Read-PipelineJson -Path (Join-Path $runtimeDirectory 'task-ready-delivery.json')
        [ordered]@{
            protocol_version = 1
            task_id = $TaskId
            status = 'ALREADY_DELIVERED'
            manager_thread_id = $delivery.manager_thread_id
            turn_id = $delivery.turn_id
        } | ConvertTo-Json -Depth 10
        exit 0
    }
    if ($state.status -eq 'task_ready_pending') {
        $existingTaskReady = Read-PipelineJson -Path $taskReadyPath
        $existingTaskReady | ConvertTo-Json -Depth 10
        exit 0
    }
    if ($state.status -ne 'compacting') {
        throw "Boundary completion requires compacting state, got: $($state.status)"
    }
    $registry = Read-PipelineThreadRegistry -Path $threadsPath
    $phaseOne = Read-PipelineJson -Path $phaseOnePath
    Test-PipelineCompactionPhaseOne -Registry $registry -PhaseOne $phaseOne -TaskId $TaskId | Out-Null
    $snapshot = Read-PipelineJson -Path $ProjectSnapshotFile
    Test-PipelineProjectSnapshot -Registry $registry -Snapshot $snapshot -TaskId $TaskId -MinimumCapturedAt ([datetime]$phaseOne.completed_at) | Out-Null
    $savedSnapshotPath = Join-Path $runtimeDirectory 'project-restore-snapshot.json'
    Write-AtomicJson -Path $savedSnapshotPath -Value $snapshot

    $claudeOutput = Join-Path $runtimeDirectory 'claude-compact-receipt.json'
    $claudeReceipt = $null
    if (Test-Path -LiteralPath $claudeOutput -PathType Leaf) {
        $claudeReceipt = Read-PipelineJson -Path $claudeOutput
        Test-PipelineClaudeCompactionReceipt -Receipt $claudeReceipt | Out-Null
    }
    else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $claudeScript -Action Compact -OutputFile $claudeOutput -RegistryPath $claudeRegistryPath | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Claude compaction failed with exit code $LASTEXITCODE"
        }
        $claudeReceipt = Read-PipelineJson -Path $claudeOutput
        Test-PipelineClaudeCompactionReceipt -Receipt $claudeReceipt | Out-Null
    }
    $receipts = @($phaseOne.receipts) + @([pscustomobject][ordered]@{
        target = 'opus'
        kind = 'claude'
        id = $claudeReceipt.session_id
        status = $claudeReceipt.status
        compact_boundary = $claudeReceipt.compact_boundary
        compaction_outcome = $claudeReceipt.compaction_outcome
        compact_metadata = $claudeReceipt.compact_metadata
        completed_at = $claudeReceipt.completed_at
    })
    Write-AtomicJson -Path $compactionPath -Value ([ordered]@{
        protocol_version = 1
        task_id = $TaskId
        status = 'succeeded'
        project_restore = [ordered]@{
            status = 'verified'
            captured_at = $snapshot.captured_at
            snapshot_sha256 = Get-FileSha256 -Path $savedSnapshotPath
            runtime_path = ".pipeline/runtime/$TaskId/project-restore-snapshot.json"
        }
        receipts = $receipts
        completed_at = [datetime]::UtcNow.ToString('o')
    })
    $message = "TASK_READY $TaskId Read .pipeline/tasks/$TaskId/request.md and compaction.json, then continue as Manager."
    $taskReady = [ordered]@{
        protocol_version = 1
        task_id = $TaskId
        status = 'TASK_READY'
        manager_thread_id = $registry.roles.manager.thread_id
        message = $message
        message_sha256 = Get-TextSha256 -Text $message
        created_at = [datetime]::UtcNow.ToString('o')
    }
    Write-AtomicJson -Path $taskReadyPath -Value $taskReady
    $state = Set-PipelineTransition -State $state -Transition 'task_ready_pending' -CorrelationId (Get-PipelineCorrelationId -TaskId $TaskId -Transition 'task_ready_pending')
    Write-AtomicJson -Path $statePath -Value $state
    $taskReady | ConvertTo-Json -Depth 10
}
catch {
    if ($state.status -eq 'compacting') {
        $state = Set-PipelineTransition -State $state -Transition 'blocked' -CorrelationId (Get-PipelineCorrelationId -TaskId $TaskId -Transition 'blocked' -AttemptId ([guid]::NewGuid().ToString('N')))
        Write-AtomicJson -Path $statePath -Value $state
    }
    throw
}
