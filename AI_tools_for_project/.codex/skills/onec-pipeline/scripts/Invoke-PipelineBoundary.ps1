[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^UT-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$')]
    [string]$TaskId,
    [Parameter(Mandatory = $true)][string]$ControllerThreadId,
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PipelineState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CodexAppServer.psm1') -Force

$taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$TaskId"
$statePath = Join-Path $taskDirectory 'state.json'
$runtimeDirectory = Join-Path $ProjectRoot ".pipeline\runtime\$TaskId"
$threadsPath = Join-Path $ProjectRoot '.pipeline\local\threads.json'
$phaseOnePath = Join-Path $runtimeDirectory 'codex-phase1.json'
[IO.Directory]::CreateDirectory($runtimeDirectory) | Out-Null

$state = Read-PipelineJson -Path $statePath
$registry = Read-PipelineThreadRegistry -Path $threadsPath
$boundaryTargets = @(Get-PipelineBoundaryTargets -Registry $registry -ControllerThreadId $ControllerThreadId)
if ((-not $Force) -and (Test-Path -LiteralPath $phaseOnePath -PathType Leaf)) {
    $existingPhaseOne = Read-PipelineJson -Path $phaseOnePath
    Test-PipelineCompactionPhaseOne -Registry $registry -PhaseOne $existingPhaseOne -TaskId $TaskId | Out-Null
    $existingPhaseOne | ConvertTo-Json -Depth 20
    exit 0
}

try {
    if ($state.status -eq 'intake') {
        $state = Set-PipelineTransition -State $state -Transition 'compacting' -CorrelationId (Get-PipelineCorrelationId -TaskId $TaskId -Transition 'compacting')
        Write-AtomicJson -Path $statePath -Value $state
    }
    elseif ($state.status -ne 'compacting') {
        throw "Boundary cannot start from state: $($state.status)"
    }

    $receipts = New-Object Collections.Generic.List[object]
    foreach ($target in $boundaryTargets) {
        $roleName = $target.role
        $threadId = $target.thread_id
        $roleReceiptPath = Join-Path $runtimeDirectory ("codex-{0}.json" -f $roleName)
        Write-AtomicJson -Path (Join-Path $runtimeDirectory 'boundary-progress.json') -Value ([ordered]@{
            protocol_version = 1; task_id = $TaskId; status = 'running'; role = $roleName; heartbeat_at = [datetime]::UtcNow.ToString('o')
        })
        if ((-not $Force) -and (Test-Path -LiteralPath $roleReceiptPath -PathType Leaf)) {
            $savedReceipt = Read-PipelineJson -Path $roleReceiptPath
            if ($savedReceipt.target -ne $roleName -or $savedReceipt.id -ne $threadId -or $savedReceipt.status -ne 'succeeded' -or $savedReceipt.item_type -ne 'contextCompaction' -or [string]::IsNullOrWhiteSpace([string]$savedReceipt.rearchived_at)) {
                throw "Invalid saved Codex compaction receipt for role: $roleName"
            }
            $receipts.Add($savedReceipt)
            continue
        }
        $unarchiveReceipt = $null
        $receipt = $null
        $archiveReceipt = $null
        $primaryError = $null
        $archiveError = $null
        try {
            $unarchiveReceipt = Invoke-CodexThreadUnarchive -ThreadId $threadId -TimeoutSeconds 30
            $receipt = Invoke-CodexThreadCompaction -ThreadId $threadId -TimeoutSeconds 600
        }
        catch {
            $primaryError = $_
        }
        finally {
            if ($null -ne $unarchiveReceipt) {
                try {
                    $archiveReceipt = Invoke-CodexThreadArchive -ThreadId $threadId -TimeoutSeconds 30
                }
                catch {
                    $archiveError = $_
                }
            }
        }
        if ($null -ne $primaryError -or $null -ne $archiveError) {
            $parts = @()
            if ($null -ne $primaryError) { $parts += "compaction=$($primaryError.Exception.Message)" }
            if ($null -ne $archiveError) { $parts += "rearchive=$($archiveError.Exception.Message)" }
            throw "Codex compaction handoff failed for role $roleName; $($parts -join '; ')"
        }
        if ($null -eq $receipt -or $null -eq $archiveReceipt) {
            throw "Incomplete Codex compaction handoff for role: $roleName"
        }
        $roleReceipt = [pscustomobject][ordered]@{
            target = $roleName
            kind = 'codex'
            id = $threadId
            status = $receipt.status
            lock_handoff = 'desktop_archive_cli_compact_cli_archive'
            unarchived_at = $unarchiveReceipt.completed_at
            item_id = $receipt.item_id
            item_type = $receipt.item_type
            rearchived_at = $archiveReceipt.completed_at
            completed_at = $receipt.completed_at
        }
        Write-AtomicJson -Path $roleReceiptPath -Value $roleReceipt
        $receipts.Add($roleReceipt)
    }

    $phaseOne = [ordered]@{
        protocol_version = 1
        task_id = $TaskId
        status = 'awaiting_app_restore'
        receipts = $receipts.ToArray()
        completed_at = [datetime]::UtcNow.ToString('o')
    }
    Write-AtomicJson -Path (Join-Path $runtimeDirectory 'restore-required.json') -Value ([ordered]@{
        protocol_version = 1
        task_id = $TaskId
        project_id = $registry.project_id
        roles = @('manager', 'plan', 'work', 'deploy')
        status = 'required'
    })
    Test-PipelineCompactionPhaseOne -Registry $registry -PhaseOne ([pscustomobject]$phaseOne) -TaskId $TaskId | Out-Null
    Write-AtomicJson -Path $phaseOnePath -Value $phaseOne
    Write-AtomicJson -Path (Join-Path $runtimeDirectory 'boundary-progress.json') -Value ([ordered]@{
        protocol_version = 1; task_id = $TaskId; status = 'awaiting_app_restore'; heartbeat_at = [datetime]::UtcNow.ToString('o')
    })
    [pscustomobject]$phaseOne | ConvertTo-Json -Depth 20
}
catch {
    $errorRecord = [ordered]@{
        protocol_version = 1
        task_id = $TaskId
        status = 'failed'
        error = $_.Exception.Message
        failed_at = [datetime]::UtcNow.ToString('o')
    }
    Write-AtomicJson -Path (Join-Path $runtimeDirectory 'boundary-error.json') -Value $errorRecord
    Write-AtomicJson -Path (Join-Path $runtimeDirectory 'boundary-progress.json') -Value ([ordered]@{
        protocol_version = 1; task_id = $TaskId; status = 'failed'; error = $_.Exception.Message; heartbeat_at = [datetime]::UtcNow.ToString('o')
    })
    if ($state.status -eq 'compacting') {
        $state = Set-PipelineTransition -State $state -Transition 'blocked' -CorrelationId (Get-PipelineCorrelationId -TaskId $TaskId -Transition 'blocked' -AttemptId ([guid]::NewGuid().ToString('N')))
        Write-AtomicJson -Path $statePath -Value $state
    }
    throw
}
