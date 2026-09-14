Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-PipelineUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $tempPath = Join-Path $directory ([IO.Path]::GetRandomFileName())
    $backupPath = Join-Path $directory ([IO.Path]::GetRandomFileName())
    Write-PipelineUtf8NoBom -Path $tempPath -Text ($Value | ConvertTo-Json -Depth 40)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($tempPath, $Path, $backupPath)
        }
        else {
            [IO.File]::Move($tempPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }
}

function Read-PipelineJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Pipeline JSON file was not found: $Path"
    }
    try {
        return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json)
    }
    catch {
        throw "Invalid pipeline JSON: $Path"
    }
}

function New-PipelineTaskId {
    param(
        [datetime]$Now = [datetime]::UtcNow,
        [string]$Entropy = ([guid]::NewGuid().ToString('N').Substring(0, 4))
    )

    if ($Entropy -notmatch '^[a-fA-F0-9]{4}$') {
        throw 'Task ID entropy must contain exactly four hexadecimal characters.'
    }
    return 'UT-{0}-{1}' -f $Now.ToUniversalTime().ToString('yyyyMMdd-HHmmss'), $Entropy.ToLowerInvariant()
}

function Get-PipelineCorrelationId {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Transition,
        [ValidatePattern('^[A-Za-z0-9._-]{1,100}$')][string]$AttemptId
    )

    if ([string]::IsNullOrWhiteSpace($AttemptId)) {
        return '{0}:{1}' -f $TaskId, $Transition
    }
    return '{0}:{1}:{2}' -f $TaskId, $Transition, $AttemptId
}

function New-PipelineState {
    param([Parameter(Mandatory = $true)][string]$TaskId)

    return [pscustomobject][ordered]@{
        protocol_version = 1
        task_id = $TaskId
        status = 'intake'
        transitions = @()
        correlation_ids = @()
        updated_at = [datetime]::UtcNow.ToString('o')
    }
}

function Set-PipelineTransition {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Transition,
        [Parameter(Mandatory = $true)][string]$CorrelationId
    )

    if (@($State.correlation_ids) -contains $CorrelationId) {
        return $State
    }

    $legal = @{
        intake = @('compacting')
        compacting = @('task_ready_pending', 'blocked')
        task_ready_pending = @('plan_requested')
        plan_requested = @('planned')
        planned = @('work_requested')
        work_requested = @('review_requested')
        review_requested = @('changes_requested', 'approved')
        changes_requested = @('work_requested')
        approved = @('deploy_dry_run')
        deploy_dry_run = @('awaiting_human')
        awaiting_human = @('deploying')
        deploying = @('completed')
        completed = @()
        blocked = @('compacting')
    }
    if (-not $legal.ContainsKey([string]$State.status) -or $legal[[string]$State.status] -notcontains $Transition) {
        throw "Illegal pipeline transition: $($State.status) -> $Transition"
    }

    $record = [pscustomobject][ordered]@{
        from = [string]$State.status
        to = $Transition
        correlation_id = $CorrelationId
        at = [datetime]::UtcNow.ToString('o')
    }
    $State.transitions = @($State.transitions) + $record
    $State.correlation_ids = @($State.correlation_ids) + $CorrelationId
    $State.status = $Transition
    $State.updated_at = [datetime]::UtcNow.ToString('o')
    return $State
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File was not found for SHA-256: $Path"
    }
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function New-ScenarioApproval {
    param(
        [Parameter(Mandatory = $true)][string]$ScenarioPath,
        [Parameter(Mandatory = $true)][string]$ApprovedBy,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $approval = [ordered]@{
        protocol_version = 1
        scenario_path = [IO.Path]::GetFullPath($ScenarioPath)
        scenario_sha256 = Get-FileSha256 -Path $ScenarioPath
        approved_by = $ApprovedBy
        approved_at = [datetime]::UtcNow.ToString('o')
    }
    Write-AtomicJson -Path $OutputPath -Value $approval
    return [pscustomobject]$approval
}

function Test-ScenarioApproval {
    param(
        [Parameter(Mandatory = $true)][string]$ScenarioPath,
        [Parameter(Mandatory = $true)][string]$ApprovalPath
    )

    try {
        $approval = Read-PipelineJson -Path $ApprovalPath
        return $approval.scenario_sha256 -eq (Get-FileSha256 -Path $ScenarioPath)
    }
    catch {
        return $false
    }
}

function Read-PipelineThreadRegistry {
    param([Parameter(Mandatory = $true)][string]$Path)

    $registry = Read-PipelineJson -Path $Path
    if ([string]::IsNullOrWhiteSpace($registry.project_id)) {
        throw 'Pipeline thread registry has no saved project ID.'
    }
    $expected = [ordered]@{
        controller = @('gpt-5.6-terra', 'high')
        manager = @('gpt-5.6-terra', 'high')
        plan = @('gpt-5.6-sol', 'high')
        work = @('gpt-5.6-luna', 'medium')
        deploy = @('gpt-5.6-luna', 'medium')
    }
    foreach ($roleName in $expected.Keys) {
        if ($registry.roles.PSObject.Properties.Name -notcontains $roleName) {
            throw "Pipeline thread registry is missing role: $roleName"
        }
        $role = $registry.roles.$roleName
        if ([string]::IsNullOrWhiteSpace($role.thread_id)) {
            throw "Pipeline thread registry has no thread ID for role: $roleName"
        }
        if ([string]::IsNullOrWhiteSpace($role.title)) {
            throw "Pipeline thread registry has no title for role: $roleName"
        }
        if ($role.model -ne $expected[$roleName][0] -or $role.effort -ne $expected[$roleName][1]) {
            throw "Pipeline thread registry profile mismatch for role: $roleName"
        }
    }
    return $registry
}

function Get-PipelineBoundaryTargets {
    param(
        [Parameter(Mandatory = $true)]$Registry,
        [Parameter(Mandatory = $true)][string]$ControllerThreadId
    )

    if ($Registry.roles.PSObject.Properties.Name -notcontains 'controller' -or $Registry.roles.controller.thread_id -ne $ControllerThreadId) {
        throw 'Boundary caller is not the registered Controller.'
    }
    $targets = New-Object Collections.Generic.List[object]
    $seen = @{}
    foreach ($roleName in @('manager', 'plan', 'work', 'deploy')) {
        if ($Registry.roles.PSObject.Properties.Name -notcontains $roleName) {
            throw "Boundary registry is missing target role: $roleName"
        }
        $role = $Registry.roles.$roleName
        $threadId = [string]$role.thread_id
        if ([string]::IsNullOrWhiteSpace($threadId)) {
            throw "Boundary target has no thread ID: $roleName"
        }
        if ($threadId -eq $ControllerThreadId) {
            throw "Controller must never appear in boundary targets: $roleName"
        }
        if ($seen.ContainsKey($threadId)) {
            throw "Boundary target thread ID is duplicated: $threadId"
        }
        $seen[$threadId] = $true
        $targets.Add([pscustomobject][ordered]@{
            role = $roleName
            thread_id = $threadId
            title = [string]$role.title
        })
    }
    return $targets.ToArray()
}

function Test-PipelineProjectSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Registry,
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][datetime]$MinimumCapturedAt
    )

    foreach ($propertyName in @('project_id', 'roles')) {
        if ($Snapshot.PSObject.Properties.Name -notcontains $propertyName) {
            throw "Pipeline snapshot is missing property: $propertyName"
        }
    }
    if ($Snapshot.PSObject.Properties.Name -notcontains 'task_id' -or $Snapshot.task_id -ne $TaskId) {
        throw "Pipeline snapshot task mismatch. Expected=$TaskId"
    }
    if ($Snapshot.PSObject.Properties.Name -notcontains 'captured_at') {
        throw 'Pipeline snapshot is missing property: captured_at'
    }
    $capturedAt = [datetime]::Parse([string]$Snapshot.captured_at).ToUniversalTime()
    if ($capturedAt -lt $MinimumCapturedAt.ToUniversalTime()) {
        throw "Pipeline snapshot is stale. Captured=$capturedAt Minimum=$MinimumCapturedAt"
    }
    if ($Snapshot.project_id -ne $Registry.project_id) {
        throw "Pipeline snapshot project mismatch. Expected=$($Registry.project_id) Actual=$($Snapshot.project_id)"
    }
    foreach ($roleName in @('manager', 'plan', 'work', 'deploy')) {
        $items = @($Snapshot.roles | Where-Object { $_.role -eq $roleName })
        if ($items.Count -ne 1) {
            throw "Pipeline snapshot must contain exactly one role: $roleName"
        }
        $actual = $items[0]
        $expected = $Registry.roles.$roleName
        foreach ($propertyName in @('thread_id', 'title', 'project_id', 'pinned', 'archived')) {
            if ($actual.PSObject.Properties.Name -notcontains $propertyName) {
                throw "Pipeline snapshot role $roleName is missing property: $propertyName"
            }
        }
        if ($actual.thread_id -ne $expected.thread_id) {
            throw "Pipeline snapshot thread ID mismatch for role: $roleName"
        }
        if ($actual.title -ne $expected.title) {
            throw "Pipeline snapshot title mismatch for role: $roleName"
        }
        if ($actual.project_id -ne $Registry.project_id) {
            throw "Pipeline snapshot project mismatch for role: $roleName"
        }
        if ([bool]$actual.pinned) {
            throw "Pipeline role must not be pinned: $roleName"
        }
        if ([bool]$actual.archived) {
            throw "Pipeline role must be restored from archive: $roleName"
        }
    }
    return $true
}

function Test-PipelineCompactionPhaseOne {
    param(
        [Parameter(Mandatory = $true)]$Registry,
        [Parameter(Mandatory = $true)]$PhaseOne,
        [Parameter(Mandatory = $true)][string]$TaskId
    )

    if ($PhaseOne.task_id -ne $TaskId -or $PhaseOne.status -ne 'awaiting_app_restore') {
        throw 'Codex compaction phase-one task or status mismatch.'
    }
    foreach ($roleName in @('manager', 'plan', 'work', 'deploy')) {
        $receipts = @($PhaseOne.receipts | Where-Object { $_.target -eq $roleName })
        if ($receipts.Count -ne 1) {
            throw "Codex compaction phase must contain exactly one receipt for role: $roleName"
        }
        $receipt = $receipts[0]
        if ($receipt.id -ne $Registry.roles.$roleName.thread_id) {
            throw "Codex compaction thread ID mismatch for role: $roleName"
        }
        if ($receipt.status -ne 'succeeded') {
            throw "Codex compaction did not succeed for role: $roleName"
        }
        if ($receipt.item_type -ne 'contextCompaction') {
            throw "Codex receipt is not contextCompaction for role: $roleName"
        }
        if ([string]::IsNullOrWhiteSpace([string]$receipt.rearchived_at)) {
            throw "Codex role was not rearchived after compaction: $roleName"
        }
    }
    if (@($PhaseOne.receipts).Count -ne 4) {
        throw 'Codex compaction phase must contain exactly four receipts.'
    }
    return $true
}

function Test-PipelineClaudeCompactionReceipt {
    param([Parameter(Mandatory = $true)]$Receipt)

    foreach ($propertyName in @('session_id', 'status', 'compaction_outcome')) {
        if ($Receipt.PSObject.Properties.Name -notcontains $propertyName) {
            throw "Claude compaction receipt is invalid: missing $propertyName"
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Receipt.session_id) -or $Receipt.status -ne 'succeeded' -or $Receipt.compaction_outcome -notin @('compacted', 'not_needed')) {
        throw "Claude compaction receipt is invalid. Status=$($Receipt.status) Outcome=$($Receipt.compaction_outcome)"
    }
    return $true
}

function New-PipelineTaskArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RequestFile,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9._:-]{1,200}$')][string]$IntakeCorrelationId,
        [datetime]$Now = [datetime]::UtcNow,
        [string]$Entropy = ([guid]::NewGuid().ToString('N').Substring(0, 4))
    )

    if (-not (Test-Path -LiteralPath $RequestFile -PathType Leaf)) {
        throw "Task request file was not found: $RequestFile"
    }
    $tasksRoot = Join-Path $ProjectRoot '.pipeline\tasks'
    $requestText = [IO.File]::ReadAllText($RequestFile, [Text.Encoding]::UTF8)
    $requestSha256 = Get-TextSha256 -Text $requestText
    if (Test-Path -LiteralPath $tasksRoot -PathType Container) {
        foreach ($intakePath in Get-ChildItem -LiteralPath $tasksRoot -Filter intake.json -File -Recurse -ErrorAction SilentlyContinue) {
            $intake = Read-PipelineJson -Path $intakePath.FullName
            if ($intake.intake_correlation_id -ne $IntakeCorrelationId) {
                continue
            }
            if ($intake.request_sha256 -ne $requestSha256) {
                throw "Intake correlation was reused with different request content: $IntakeCorrelationId"
            }
            $existingDirectory = Split-Path -Parent $intakePath.FullName
            $existingTaskId = Split-Path -Leaf $existingDirectory
            $existingStatePath = Join-Path $existingDirectory 'state.json'
            $existingState = Read-PipelineJson -Path $existingStatePath
            return [pscustomobject][ordered]@{
                protocol_version = 1
                task_id = $existingTaskId
                task_directory = $existingDirectory
                request_path = Join-Path $existingDirectory 'request.md'
                state_path = Join-Path $existingDirectory 'state.json'
                state_status = $existingState.status
                intake_correlation_id = $IntakeCorrelationId
                reused = $true
            }
        }
    }
    $taskId = New-PipelineTaskId -Now $Now -Entropy $Entropy
    $taskDirectory = Join-Path $ProjectRoot ".pipeline\tasks\$taskId"
    if (Test-Path -LiteralPath $taskDirectory) {
        throw "Pipeline task already exists: $taskId"
    }
    [IO.Directory]::CreateDirectory($taskDirectory) | Out-Null
    $requestPath = Join-Path $taskDirectory 'request.md'
    Write-PipelineUtf8NoBom -Path $requestPath -Text $requestText
    $statePath = Join-Path $taskDirectory 'state.json'
    Write-AtomicJson -Path $statePath -Value (New-PipelineState -TaskId $taskId)
    Write-AtomicJson -Path (Join-Path $taskDirectory 'intake.json') -Value ([ordered]@{
        protocol_version = 1
        task_id = $taskId
        intake_correlation_id = $IntakeCorrelationId
        request_sha256 = $requestSha256
        created_at = [datetime]::UtcNow.ToString('o')
    })
    return [pscustomobject][ordered]@{
        protocol_version = 1
        task_id = $taskId
        task_directory = $taskDirectory
        request_path = $requestPath
        state_path = $statePath
        state_status = 'intake'
        intake_correlation_id = $IntakeCorrelationId
        reused = $false
    }
}

Export-ModuleMember -Function @(
    'Write-PipelineUtf8NoBom',
    'Write-AtomicJson',
    'Read-PipelineJson',
    'New-PipelineTaskId',
    'Get-PipelineCorrelationId',
    'New-PipelineState',
    'Set-PipelineTransition',
    'Get-FileSha256',
    'Get-TextSha256',
    'New-ScenarioApproval',
    'Test-ScenarioApproval',
    'Read-PipelineThreadRegistry',
    'Get-PipelineBoundaryTargets',
    'Test-PipelineProjectSnapshot',
    'Test-PipelineCompactionPhaseOne',
    'Test-PipelineClaudeCompactionReceipt',
    'New-PipelineTaskArtifacts'
)
