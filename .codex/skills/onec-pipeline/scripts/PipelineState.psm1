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
    $temporaryPath = Join-Path $directory ([IO.Path]::GetRandomFileName())
    $backupPath = Join-Path $directory ([IO.Path]::GetRandomFileName())
    Write-PipelineUtf8NoBom -Path $temporaryPath -Text ($Value | ConvertTo-Json -Depth 40)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($temporaryPath, $Path, $backupPath)
        }
        else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
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

function Read-PipelineConfiguration {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Pipeline configuration was not found: $Path"
    }
    $configuration = [ordered]@{
        protocol_version = 1
        agents = [ordered]@{
            controller_model = 'gpt-5.6-terra'; controller_reasoning = 'high'
            manager_model = 'gpt-5.6-terra'; manager_reasoning = 'high'
            plan_model = 'gpt-5.6-sol'; plan_reasoning = 'high'
            work_model = 'gpt-5.6-luna'; work_reasoning = 'medium'
            deploy_model = 'gpt-5.6-luna'; deploy_reasoning = 'medium'
        }
        manager = [ordered]@{
            max_parallel_workers = 3
            require_test_plan = $true
            require_decomposition = $true
            require_architecture = $true
            require_architecture_review = $true
            architecture_for = @('medium', 'large', 'critical')
            architecture_review_for = @('medium', 'large', 'critical')
            plan_approval_for = @('large', 'critical')
        }
        review = [ordered]@{ mode = 'disabled'; available = $false; provider = $null }
        deploy = [ordered]@{ enabled = $false; available = $false; adapter = $null; require_approval = $true }
        verify = [ordered]@{
            fail_on_config_dump_info = $true
            fail_on_not_run = $true
            runner_path = $null
            runner_config = 'v8project.yaml'
            checks = @()
        }
    }
    $section = $null
    $listKey = $null
    $checks = New-Object Collections.Generic.List[string]
    $planApprovalFor = New-Object Collections.Generic.List[string]
    $architectureFor = New-Object Collections.Generic.List[string]
    $architectureReviewFor = New-Object Collections.Generic.List[string]
    $planApprovalConfigured = $false
    $architectureForConfigured = $false
    $architectureReviewForConfigured = $false
    foreach ($rawLine in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $line = ($rawLine -replace '\s+#.*$', '').TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^version:\s*([0-9]+)\s*$' -and $rawLine -notmatch '^\s') {
            $configuration.protocol_version = [int]$matches[1]
            continue
        }
        if ($line -match '^([A-Za-z_][A-Za-z0-9_-]*):\s*$' -and $rawLine -notmatch '^\s') {
            $section = $matches[1]
            if ($section -notin @('agents', 'manager', 'review', 'deploy', 'verify')) { throw "Unsupported configuration section: $section" }
            $listKey = $null
            continue
        }
        if ($line -match '^\s+([A-Za-z_][A-Za-z0-9_-]*):\s*(.*?)\s*$') {
            $key = $matches[1]
            $value = $matches[2].Trim('"', "'")
            $listKey = if ([string]::IsNullOrWhiteSpace($value)) { $key } else { $null }
            if ($section -eq 'agents') {
                if ($key -notin @(
                    'controller_model', 'controller_reasoning', 'manager_model', 'manager_reasoning',
                    'plan_model', 'plan_reasoning', 'work_model', 'work_reasoning', 'deploy_model', 'deploy_reasoning'
                )) { throw "Unsupported agents setting: $key" }
                $configuration.agents[$key] = $value
            }
            elseif ($section -eq 'manager') {
                switch ($key) {
                    'max_parallel_workers' {
                        $parsedValue = 0
                        if (-not [int]::TryParse($value, [ref]$parsedValue) -or $parsedValue -lt 1 -or $parsedValue -gt 8) {
                            throw 'manager.max_parallel_workers must be an integer from 1 to 8.'
                        }
                        $configuration.manager.max_parallel_workers = $parsedValue
                    }
                    'require_test_plan' {
                        if ($value -notin @('true', 'false')) { throw 'manager.require_test_plan must be true or false.' }
                        $configuration.manager.require_test_plan = $value -eq 'true'
                    }
                    'require_decomposition' {
                        if ($value -notin @('true', 'false')) { throw 'manager.require_decomposition must be true or false.' }
                        $configuration.manager.require_decomposition = $value -eq 'true'
                    }
                    'require_architecture' {
                        if ($value -notin @('true', 'false')) { throw 'manager.require_architecture must be true or false.' }
                        $configuration.manager.require_architecture = $value -eq 'true'
                    }
                    'require_architecture_review' {
                        if ($value -notin @('true', 'false')) { throw 'manager.require_architecture_review must be true or false.' }
                        $configuration.manager.require_architecture_review = $value -eq 'true'
                    }
                    'architecture_for' {
                        if (-not [string]::IsNullOrWhiteSpace($value)) { throw 'manager.architecture_for must be a YAML list.' }
                        $architectureForConfigured = $true
                    }
                    'architecture_review_for' {
                        if (-not [string]::IsNullOrWhiteSpace($value)) { throw 'manager.architecture_review_for must be a YAML list.' }
                        $architectureReviewForConfigured = $true
                    }
                    'plan_approval_for' {
                        if (-not [string]::IsNullOrWhiteSpace($value)) { throw 'manager.plan_approval_for must be a YAML list.' }
                        $planApprovalConfigured = $true
                    }
                    default { throw "Unsupported manager setting: $key" }
                }
            }
            elseif ($section -eq 'review') {
                switch ($key) {
                    'mode' { $configuration.review.mode = $value.ToLowerInvariant() }
                    'available' {
                        if ($value -notin @('true', 'false')) { throw 'review.available must be true or false.' }
                        $configuration.review.available = $value -eq 'true'
                    }
                    'provider' { $configuration.review.provider = if ($value -in @('', 'null', '~')) { $null } else { $value } }
                    default { throw "Unsupported review setting: $key" }
                }
            }
            elseif ($section -eq 'deploy') {
                switch ($key) {
                    { $_ -in @('enabled', 'available', 'require_approval') } {
                        if ($value -notin @('true', 'false')) { throw "deploy.$key must be true or false." }
                        $configuration.deploy[$key] = $value -eq 'true'
                    }
                    'adapter' { $configuration.deploy.adapter = if ($value -in @('', 'null', '~')) { $null } else { $value } }
                    default { throw "Unsupported deploy setting: $key" }
                }
            }
            elseif ($section -eq 'verify') {
                switch ($key) {
                    'fail_on_config_dump_info' {
                        if ($value -notin @('true', 'false')) { throw 'verify.fail_on_config_dump_info must be true or false.' }
                        $configuration.verify.fail_on_config_dump_info = $value -eq 'true'
                    }
                    'fail_on_not_run' {
                        if ($value -notin @('true', 'false')) { throw 'verify.fail_on_not_run must be true or false.' }
                        $configuration.verify.fail_on_not_run = $value -eq 'true'
                    }
                    'runner_path' { $configuration.verify.runner_path = if ($value -in @('', 'null', '~')) { $null } else { $value } }
                    'runner_config' {
                        if ([string]::IsNullOrWhiteSpace($value)) { throw 'verify.runner_config must not be empty.' }
                        $configuration.verify.runner_config = $value
                    }
                    'checks' {
                        if (-not [string]::IsNullOrWhiteSpace($value)) { throw 'verify.checks must be a YAML list.' }
                    }
                    default { throw "Unsupported verify setting: $key" }
                }
            }
            continue
        }
        if ($section -eq 'verify' -and $listKey -eq 'checks' -and $line -match '^\s*-\s*([A-Za-z_][A-Za-z0-9_-]*)\s*$') {
            $checks.Add($matches[1])
            continue
        }
        if ($section -eq 'manager' -and $listKey -eq 'plan_approval_for' -and $line -match '^\s*-\s*([A-Za-z_][A-Za-z0-9_-]*)\s*$') {
            $planApprovalFor.Add($matches[1].ToLowerInvariant())
            continue
        }
        if ($section -eq 'manager' -and $listKey -eq 'architecture_for' -and $line -match '^\s*-\s*([A-Za-z_][A-Za-z0-9_-]*)\s*$') {
            $architectureFor.Add($matches[1].ToLowerInvariant())
            continue
        }
        if ($section -eq 'manager' -and $listKey -eq 'architecture_review_for' -and $line -match '^\s*-\s*([A-Za-z_][A-Za-z0-9_-]*)\s*$') {
            $architectureReviewFor.Add($matches[1].ToLowerInvariant())
            continue
        }
        throw "Unsupported configuration line: $rawLine"
    }
    $configuration.verify.checks = $checks.ToArray()
    if ($planApprovalConfigured) { $configuration.manager.plan_approval_for = $planApprovalFor.ToArray() }
    if ($architectureForConfigured) { $configuration.manager.architecture_for = $architectureFor.ToArray() }
    if ($architectureReviewForConfigured) { $configuration.manager.architecture_review_for = $architectureReviewFor.ToArray() }
    if ($configuration.protocol_version -ne 1) { throw "Unsupported configuration version: $($configuration.protocol_version)" }
    if ([bool]$configuration.manager.require_architecture_review -and -not [bool]$configuration.manager.require_architecture) {
        throw 'manager.require_architecture_review requires manager.require_architecture=true.'
    }
    if ($configuration.review.mode -notin @('disabled', 'optional', 'required')) { throw "Unsupported review.mode: $($configuration.review.mode)" }
    $allowedModels = @('gpt-5.6-terra', 'gpt-5.6-sol', 'gpt-5.6-luna')
    $allowedReasoning = @('low', 'medium', 'high', 'xhigh', 'max')
    foreach ($role in @('controller', 'manager', 'plan', 'work', 'deploy')) {
        if ($configuration.agents["${role}_model"] -notin $allowedModels) { throw "Unsupported agents.${role}_model: $($configuration.agents["${role}_model"])" }
        if ($configuration.agents["${role}_reasoning"] -notin $allowedReasoning) { throw "Unsupported agents.${role}_reasoning: $($configuration.agents["${role}_reasoning"])" }
    }
    if ([bool]$configuration.deploy.enabled -and -not [bool]$configuration.deploy.available) {
        throw 'deploy.enabled=true requires deploy.available=true.'
    }
    if ($configuration.verify.checks.Count -eq 0) { throw 'At least one VERIFY check must be configured.' }
    $unsupportedApprovalComplexities = @($configuration.manager.plan_approval_for | Where-Object { $_ -notin @('small', 'medium', 'large', 'critical') })
    if ($unsupportedApprovalComplexities.Count -gt 0) {
        throw "Unsupported manager.plan_approval_for value: $($unsupportedApprovalComplexities -join ', ')"
    }
    foreach ($settingName in @('architecture_for', 'architecture_review_for')) {
        $unsupportedComplexities = @($configuration.manager[$settingName] | Where-Object { $_ -notin @('small', 'medium', 'large', 'critical') })
        if ($unsupportedComplexities.Count -gt 0) {
            throw "Unsupported manager.$settingName value: $($unsupportedComplexities -join ', ')"
        }
    }
    $reviewWithoutArchitecture = @($configuration.manager.architecture_review_for | Where-Object { $_ -notin @($configuration.manager.architecture_for) })
    if ([bool]$configuration.manager.require_architecture_review -and $reviewWithoutArchitecture.Count -gt 0) {
        throw "manager.architecture_review_for must be a subset of manager.architecture_for: $($reviewWithoutArchitecture -join ', ')"
    }
    return [pscustomobject]$configuration
}

function Test-PipelineManagerGate {
    param(
        [Parameter(Mandatory = $true)]$Configuration,
        [Parameter(Mandatory = $true)][ValidateSet('architecture', 'architecture_review')][string]$Gate,
        [Parameter(Mandatory = $true)][ValidateSet('small', 'medium', 'large', 'critical')][string]$Complexity
    )
    $enabledProperty = if ($Gate -eq 'architecture') { 'require_architecture' } else { 'require_architecture_review' }
    $complexitiesProperty = "${Gate}_for"
    return [bool]$Configuration.manager[$enabledProperty] -and @($Configuration.manager[$complexitiesProperty]) -contains $Complexity
}

function Get-PipelineFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File was not found: $Path" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Add-PipelineJournalRecord {
    param(
        [Parameter(Mandatory = $true)][string]$TaskDirectory,
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Actor,
        [Parameter(Mandatory = $true)][string]$Summary,
        [string]$Rationale,
        [string]$EvidencePath
    )
    $journalPath = Join-Path $TaskDirectory 'journal.json'
    $journal = if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        Read-PipelineJson -Path $journalPath
    }
    else {
        [pscustomobject][ordered]@{ protocol_version = 1; entries = @() }
    }
    $entry = [pscustomobject][ordered]@{
        id = [guid]::NewGuid().ToString('N')
        at = [datetime]::UtcNow.ToString('o')
        type = $Type
        phase = $Phase
        actor = $Actor
        summary = $Summary
        rationale = $Rationale
        evidence_path = $EvidencePath
    }
    $journal.entries = @($journal.entries) + $entry
    Write-AtomicJson -Path $journalPath -Value $journal
    return $entry
}

function Get-PostVerifyTarget {
    param([Parameter(Mandatory = $true)]$Configuration)
    switch ([string]$Configuration.review.mode) {
        'disabled' { return (Get-PostReviewTarget -Configuration $Configuration) }
        'optional' {
            if ([bool]$Configuration.review.available) { return 'review' }
            return (Get-PostReviewTarget -Configuration $Configuration)
        }
        'required' { return 'review' }
        default { throw "Unsupported review.mode: $($Configuration.review.mode)" }
    }
}

function Get-PostReviewTarget {
    param([Parameter(Mandatory = $true)]$Configuration)
    if ([bool]$Configuration.deploy.enabled) { return 'deploy_pending' }
    return 'ready'
}

function Get-PipelineAgentProfile {
    param(
        [Parameter(Mandatory = $true)]$Configuration,
        [Parameter(Mandatory = $true)][string]$Role
    )
    $profile = switch ($Role.ToLowerInvariant()) {
        { $_ -in @('controller', 'explorer') } { 'controller'; break }
        'manager' { 'manager'; break }
        { $_ -in @('plan', 'architect', 'architecture-reviewer', 'test-designer', 'reviewer') } { 'plan'; break }
        { $_ -in @('work', 'worker') } { 'work'; break }
        'deploy' { 'deploy'; break }
        default { throw "Unsupported agent role: $Role" }
    }
    return [pscustomobject][ordered]@{
        role = $Role.ToLowerInvariant()
        profile = $profile
        model = $Configuration.agents["${profile}_model"]
        reasoning = $Configuration.agents["${profile}_reasoning"]
    }
}

function New-PipelineState {
    param([Parameter(Mandatory = $true)][string]$TaskId)
    return [pscustomobject][ordered]@{
        protocol_version = 1
        task_id = $TaskId
        status = 'plan'
        transitions = @()
        correlation_ids = @()
        updated_at = [datetime]::UtcNow.ToString('o')
    }
}

function Test-PipelineDecomposition {
    param([Parameter(Mandatory = $true)]$Decomposition)

    if ($Decomposition.complexity -notin @('small', 'medium', 'large', 'critical')) {
        throw 'Decomposition complexity must be small, medium, large, or critical.'
    }
    $items = @($Decomposition.work_items)
    if ($items.Count -eq 0) { throw 'Decomposition must contain at least one work item.' }
    $ids = @{}
    foreach ($item in $items) {
        foreach ($propertyName in @('id', 'title', 'role', 'depends_on', 'paths', 'acceptance_criteria', 'test_requirements', 'parallel_safe')) {
            if ($item.PSObject.Properties.Name -notcontains $propertyName) { throw "Work item is missing property $propertyName." }
        }
        if ([string]$item.id -notmatch '^[a-z][a-z0-9-]{1,49}$') { throw "Invalid work item id: $($item.id)" }
        if ($ids.ContainsKey([string]$item.id)) { throw "Duplicate work item id: $($item.id)" }
        $ids[[string]$item.id] = $true
        if ([string]::IsNullOrWhiteSpace([string]$item.title)) { throw "Work item has no title: $($item.id)" }
        if ([string]::IsNullOrWhiteSpace([string]$item.role)) { throw "Work item has no role: $($item.id)" }
        if (@($item.acceptance_criteria).Count -eq 0) { throw "Work item has no acceptance criteria: $($item.id)" }
        if (@($item.test_requirements).Count -eq 0) { throw "Work item has no test requirements: $($item.id)" }
    }
    foreach ($item in $items) {
        foreach ($dependency in @($item.depends_on)) {
            if (-not $ids.ContainsKey([string]$dependency)) { throw "Unknown dependency $dependency in work item $($item.id)" }
            if ($dependency -eq $item.id) { throw "Work item cannot depend on itself: $($item.id)" }
        }
    }
    $resolved = @{}
    while ($resolved.Count -lt $items.Count) {
        $progress = $false
        foreach ($item in $items) {
            if ($resolved.ContainsKey([string]$item.id)) { continue }
            $unresolvedDependencies = @($item.depends_on | Where-Object { -not $resolved.ContainsKey([string]$_) })
            if ($unresolvedDependencies.Count -eq 0) {
                $resolved[[string]$item.id] = $true
                $progress = $true
            }
        }
        if (-not $progress) { throw 'Work item dependency graph contains a cycle.' }
    }
    return $true
}

function Test-PipelineExecutionReady {
    param(
        [Parameter(Mandatory = $true)][string]$TaskDirectory,
        [Parameter(Mandatory = $true)]$Configuration
    )
    $decompositionPath = Join-Path $TaskDirectory 'decomposition.json'
    $workItemsPath = Join-Path $TaskDirectory 'work-items.json'
    $testPlanPath = Join-Path $TaskDirectory 'test-plan.md'
    if ([bool]$Configuration.manager.require_decomposition) {
        if (-not (Test-Path -LiteralPath $decompositionPath -PathType Leaf) -or -not (Test-Path -LiteralPath $workItemsPath -PathType Leaf)) {
            throw 'Manager decomposition and work-items state are required before VERIFY.'
        }
        $decomposition = Read-PipelineJson -Path $decompositionPath
        Test-PipelineDecomposition -Decomposition $decomposition | Out-Null
        $workItems = Read-PipelineJson -Path $workItemsPath
        $incomplete = @($workItems.items | Where-Object { $_.status -ne 'completed' })
        if ($incomplete.Count -gt 0) { throw "Incomplete work items: $((@($incomplete.id)) -join ', ')" }
    }
    if ([bool]$Configuration.manager.require_test_plan -and -not (Test-Path -LiteralPath $testPlanPath -PathType Leaf)) {
        throw 'A test plan is required before VERIFY.'
    }
    return $true
}

function Set-PipelineEvent {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Event,
        [Parameter(Mandatory = $true)][string]$CorrelationId,
        [Parameter(Mandatory = $true)]$Configuration,
        [string]$EvidencePath
    )
    if (@($State.correlation_ids) -contains $CorrelationId) { return $State }
    $key = '{0}:{1}' -f $State.status, $Event
    $target = switch ($key) {
        'plan:plan_completed' { 'work' }
        'work:work_completed' { 'verify' }
        'verify:verify_failed' { 'verify_failed' }
        'verify_failed:return_to_work' { 'work' }
        'verify:verify_passed' { Get-PostVerifyTarget -Configuration $Configuration }
        'review:review_approved' { Get-PostReviewTarget -Configuration $Configuration }
        'review:review_changes_requested' { 'work' }
        'deploy_pending:deploy_approved' { 'deploy' }
        'deploy:deploy_succeeded' { 'ready' }
        'deploy:deploy_failed' { 'deploy_failed' }
        default { throw "Illegal pipeline event: $key" }
    }
    $record = [pscustomobject][ordered]@{
        from = [string]$State.status
        event = $Event
        to = $target
        correlation_id = $CorrelationId
        evidence_path = $EvidencePath
        at = [datetime]::UtcNow.ToString('o')
    }
    $State.transitions = @($State.transitions) + $record
    $State.correlation_ids = @($State.correlation_ids) + $CorrelationId
    $State.status = $target
    $State.updated_at = [datetime]::UtcNow.ToString('o')
    return $State
}

function New-PipelineTaskId {
    return 'TASK-{0}-{1}' -f [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 4))
}

Export-ModuleMember -Function @(
    'Write-PipelineUtf8NoBom', 'Write-AtomicJson', 'Read-PipelineJson',
    'Read-PipelineConfiguration', 'Get-PostVerifyTarget', 'Get-PostReviewTarget', 'Get-PipelineAgentProfile', 'New-PipelineState',
    'Set-PipelineEvent', 'New-PipelineTaskId', 'Test-PipelineDecomposition', 'Test-PipelineManagerGate',
    'Test-PipelineExecutionReady', 'Get-PipelineFileSha256', 'Add-PipelineJournalRecord'
)
