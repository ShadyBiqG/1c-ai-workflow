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
        protocol_version = 2
        agents = [ordered]@{
            allowed_models = @('gpt-5.6-terra', 'gpt-5.6-sol', 'gpt-5.6-luna')
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
            fail_on_unexpected_paths = $true
            runner_path = $null
            runner_config = 'v8project.yaml'
            timeout_seconds = 1800
            timeout_overrides = [ordered]@{}
            depends_on = [ordered]@{ source_validation = @('build'); tests = @('build') }
            bsl_ls_path = $null
            bsl_ls_config = '.bsl-language-server.json'
            bsl_lint_max_issues = 0
            tests_scope = 'impacted'
            checks = @()
        }
    }

    try { $source = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { throw "Invalid pipeline JSON in ${Path}: $($_.Exception.Message)" }
    if ($null -eq $source) { throw "Invalid pipeline JSON in ${Path}: empty document." }
    $allowedSections = @('version', 'protocol_version', 'agents', 'manager', 'review', 'deploy', 'verify')
    foreach ($property in $source.PSObject.Properties) {
        if ($property.Name -notin $allowedSections) { throw "Unsupported configuration key: $($property.Name)" }
    }
    if ($source.PSObject.Properties.Name -contains 'version') { $configuration.protocol_version = $source.version }
    if ($source.PSObject.Properties.Name -contains 'protocol_version') { $configuration.protocol_version = $source.protocol_version }
    $dependsOnConfigured = $false
    if ($source.PSObject.Properties.Name -contains 'verify' -and $null -ne $source.verify) {
        $dependsOnConfigured = $source.verify.PSObject.Properties.Name -contains 'depends_on'
    }
    foreach ($section in @('agents', 'manager', 'review', 'deploy', 'verify')) {
        if ($source.PSObject.Properties.Name -notcontains $section) { continue }
        foreach ($property in $source.$section.PSObject.Properties) {
            if (-not $configuration[$section].Contains($property.Name)) { throw "Unsupported configuration key: $section.$($property.Name)" }
            if ($section -eq 'verify' -and $property.Name -in @('depends_on', 'timeout_overrides')) {
                $map = [ordered]@{}
                if ($null -ne $property.Value) {
                    foreach ($entry in $property.Value.PSObject.Properties) { $map[$entry.Name] = $entry.Value }
                }
                $configuration[$section][$property.Name] = $map
            }
            else { $configuration[$section][$property.Name] = $property.Value }
        }
    }
    if (-not $dependsOnConfigured) {
        $configuration.verify.depends_on = [ordered]@{}
        if ('source_validation' -in @($configuration.verify.checks) -and 'build' -in @($configuration.verify.checks)) { $configuration.verify.depends_on['source_validation'] = @('build') }
        if ('tests' -in @($configuration.verify.checks) -and 'build' -in @($configuration.verify.checks)) { $configuration.verify.depends_on['tests'] = @('build') }
    }

    if ($configuration.protocol_version -notin @(1,2)) { throw "Unsupported configuration version: $($configuration.protocol_version)" }
    $parsedInteger = 0
    if (-not [int]::TryParse([string]$configuration.manager.max_parallel_workers, [ref]$parsedInteger) -or $parsedInteger -lt 1 -or $parsedInteger -gt 8) {
        throw 'manager.max_parallel_workers must be an integer from 1 to 8.'
    }
    $configuration.manager.max_parallel_workers = $parsedInteger
    foreach ($key in @('require_test_plan', 'require_decomposition', 'require_architecture', 'require_architecture_review')) {
        if ($configuration.manager[$key] -isnot [bool]) { throw "manager.$key must be true or false." }
    }
    if ($configuration.review.available -isnot [bool]) { throw 'review.available must be true or false.' }
    foreach ($key in @('enabled', 'available', 'require_approval')) {
        if ($configuration.deploy[$key] -isnot [bool]) { throw "deploy.$key must be true or false." }
    }
    foreach ($key in @('fail_on_config_dump_info', 'fail_on_not_run', 'fail_on_unexpected_paths')) {
        if ($configuration.verify[$key] -isnot [bool]) { throw "verify.$key must be true or false." }
    }
    if ([bool]$configuration.manager.require_architecture_review -and -not [bool]$configuration.manager.require_architecture) {
        throw 'manager.require_architecture_review requires manager.require_architecture=true.'
    }
    if ($configuration.review.mode -notin @('disabled', 'optional', 'required')) { throw "Unsupported review.mode: $($configuration.review.mode)" }
    $allowedModels = @($configuration.agents.allowed_models)
    if ($allowedModels.Count -eq 0) { throw 'agents.allowed_models must contain at least one model.' }
    $allowedReasoning = @('low', 'medium', 'high', 'xhigh', 'max')
    foreach ($role in @('controller', 'manager', 'plan', 'work', 'deploy')) {
        if ($configuration.agents["${role}_model"] -notin $allowedModels) { throw "Unsupported agents.${role}_model '$($configuration.agents["${role}_model"])': value is not listed in agents.allowed_models." }
        if ($configuration.agents["${role}_reasoning"] -notin $allowedReasoning) { throw "Unsupported agents.${role}_reasoning: $($configuration.agents["${role}_reasoning"])" }
    }
    if ([bool]$configuration.deploy.enabled -and -not [bool]$configuration.deploy.available) {
        throw 'deploy.enabled=true requires deploy.available=true.'
    }
    if ($configuration.verify.checks.Count -eq 0) { throw 'At least one VERIFY check must be configured.' }
    if ([string]::IsNullOrWhiteSpace([string]$configuration.verify.runner_config)) { throw 'verify.runner_config must not be empty.' }
    if ($configuration.verify.tests_scope -notin @('impacted', 'all')) { throw "verify.tests_scope must be 'impacted' or 'all': $($configuration.verify.tests_scope)" }
    if (-not [int]::TryParse([string]$configuration.verify.timeout_seconds, [ref]$parsedInteger) -or $parsedInteger -lt 60 -or $parsedInteger -gt 14400) {
        throw 'verify.timeout_seconds must be an integer from 60 to 14400.'
    }
    $configuration.verify.timeout_seconds = $parsedInteger
    foreach ($name in $configuration.verify.timeout_overrides.Keys) {
        $timeout = $configuration.verify.timeout_overrides[$name]
        if (-not [int]::TryParse([string]$timeout, [ref]$parsedInteger) -or $parsedInteger -lt 60 -or $parsedInteger -gt 14400) { throw "verify.timeout_overrides.$name must be an integer from 60 to 14400." }
        $configuration.verify.timeout_overrides[$name] = $parsedInteger
        if ($name -notin @($configuration.verify.checks)) { throw "verify.timeout_overrides.$name references a check outside verify.checks." }
    }
    if (-not [int]::TryParse([string]$configuration.verify.bsl_lint_max_issues, [ref]$parsedInteger) -or $parsedInteger -lt 0) { throw 'verify.bsl_lint_max_issues must be a non-negative integer.' }
    $configuration.verify.bsl_lint_max_issues = $parsedInteger
    foreach ($name in $configuration.verify.depends_on.Keys) {
        if ($name -notin @($configuration.verify.checks)) { throw "verify.depends_on.$name references a check outside verify.checks." }
        foreach ($dependency in @($configuration.verify.depends_on[$name])) {
            if ($dependency -notin @($configuration.verify.checks)) { throw "verify.depends_on.$name references missing check '$dependency'." }
        }
    }
    $pendingChecks = @($configuration.verify.checks)
    $resolvedChecks = @{}
    while ($resolvedChecks.Count -lt $pendingChecks.Count) {
        $progress = $false
        foreach ($name in $pendingChecks) {
            if ($resolvedChecks.ContainsKey($name)) { continue }
            $dependencies = @()
            if ($configuration.verify.depends_on.Contains($name)) { $dependencies = @($configuration.verify.depends_on[$name]) }
            $unresolved = @($dependencies | Where-Object { -not $resolvedChecks.ContainsKey([string]$_) })
            if ($unresolved.Count -eq 0) { $resolvedChecks[$name] = $true; $progress = $true }
        }
        if (-not $progress) {
            $cycle = @($pendingChecks | Where-Object { -not $resolvedChecks.ContainsKey($_) })
            throw "verify.depends_on contains a cycle: $($cycle -join ', ')."
        }
    }
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
        [string]$EvidencePath,[object]$Payload=$null
    )
    $journalPath = Join-Path $TaskDirectory 'journal.json'
    $journal = if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        Read-PipelineJson -Path $journalPath
    }
    else {
        [pscustomobject][ordered]@{ protocol_version = 2; entries = @() }
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
    $agentProfile = switch ($Role.ToLowerInvariant()) {
        { $_ -in @('controller', 'explorer') } { 'controller'; break }
        'manager' { 'manager'; break }
        { $_ -in @('plan', 'architect', 'architecture-reviewer', 'test-designer', 'reviewer') } { 'plan'; break }
        { $_ -in @('work', 'worker') } { 'work'; break }
        'deploy' { 'deploy'; break }
        default { throw "Unsupported agent role: $Role" }
    }
    return [pscustomobject][ordered]@{
        role = $Role.ToLowerInvariant()
        profile = $agentProfile
        model = $Configuration.agents["${agentProfile}_model"]
        reasoning = $Configuration.agents["${agentProfile}_reasoning"]
    }
}

function New-PipelineState {
    param([Parameter(Mandatory = $true)][string]$TaskId)
    return [pscustomobject][ordered]@{
        protocol_version = 2
        task_id = $TaskId
        status = 'plan'
        applicability = 'pending'
        revision = 0
        transitions = @()
        correlation_ids = @()
        correlation_records = @()
        resume_state = $null
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
        [string]$EvidencePath,
        [object]$Payload=$null
    )
    foreach ($property in @(
        @{Name='revision';Value=0}, @{Name='transitions';Value=@()}, @{Name='correlation_ids';Value=@()},
        @{Name='correlation_records';Value=@()}, @{Name='resume_state';Value=$null}, @{Name='origin_state';Value=$null}
    )) { if ($State.PSObject.Properties.Name -notcontains $property.Name) { $State | Add-Member NoteProperty $property.Name $property.Value } }

    # Compatibility aliases are isolated here until all v1 callers are migrated.
    $legacyAliases = @{
        'plan:plan_completed'='plan_completed_legacy'; 'work:work_completed'='all_work_items_completed'
        'verify:verify_failed'='product_failure'; 'verify_failed:return_to_work'='repair_started'
        'review:review_changes_requested'='review_changes_requested_work'; 'verify:manual_required'='manual_target_pending'
        'manual_ui_required:manual_passed'='manual_evidence_passed'; 'manual_ui_required:manual_failed'='manual_evidence_failed'
        'verify:infrastructure_failed'='infrastructure_failure'; 'infrastructure_failed:resume'='provider_restored'
        'plan:await_user_decision'='material_divergence_detected'; 'awaiting_user_decision:user_decision_received'='human_decision_approved'
        'plan:plan_approval_required'='plan_package_ready'
    }
    $originalEvent = $Event
    $aliasKey = '{0}:{1}' -f $State.status,$Event
    if ($legacyAliases.ContainsKey($aliasKey)) { $Event = $legacyAliases[$aliasKey] }

    $payloadJson = if($null -eq $Payload){'null'}else{$Payload|ConvertTo-Json -Depth 30 -Compress}
    $bindingText = '{0}|{1}|{2}|{3}' -f [string]$State.status,$Event,[string]$EvidencePath,$payloadJson
    $sha=[Security.Cryptography.SHA256]::Create();try{$bindingHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($bindingText)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    if (@($State.correlation_ids) -contains $CorrelationId) {
        $old=@($State.correlation_records|Where-Object{$_.id -eq $CorrelationId}|Select-Object -First 1)
        if ($old.Count -eq 0 -or $old[0].binding_hash -ne $bindingHash) { throw 'Correlation conflict: same id with different event or payload' }
        return $State
    }
    if($State.status -in @('ready','cancelled')){throw "Terminal state cannot accept events: $($State.status)"}

    $from = [string]$State.status
    if ($Event -eq 'cancel_requested') { $target='cancelled' }
    elseif ($Event -eq 'material_divergence_detected' -and $from -in @('plan','work','verify','review','awaiting_plan_approval')) { $State.origin_state=$from; $target='awaiting_user_decision' }
    elseif ($Event -eq 'bound_artifact_changed' -and $from -in @('awaiting_plan_approval','work','verify','review','deploy_pending')) { $target='plan' }
    else {
        $key = '{0}:{1}' -f $from,$Event
        $target = switch ($key) {
            'plan:plan_completed_legacy' { 'work' }
            'plan:plan_package_ready' { if($null -ne $Payload -and $Payload.PSObject.Properties.Name -contains 'approval_required' -and -not [bool]$Payload.approval_required){'work'}else{'awaiting_plan_approval'} }
            'awaiting_user_decision:human_decision_approved' { if($State.origin_state){[string]$State.origin_state}else{'plan'} }
            'awaiting_user_decision:human_decision_rejected' { if($State.origin_state){[string]$State.origin_state}else{'plan'} }
            'awaiting_plan_approval:plan_approved' { 'work' }
            'awaiting_plan_approval:plan_rejected' { 'plan' }
            'work:work_item_started' { 'work' }
            'work:work_item_completed' { 'work' }
            'work:all_work_items_completed' { 'verify' }
            'work:nonmaterial_scope_change' { 'plan' }
            'work:replan_required' { 'plan' }
            'verify:verify_passed' { Get-PostVerifyTarget -Configuration $Configuration }
            'verify:product_failure' { 'verify_failed' }
            'verify:infrastructure_failure' { $State.resume_state='verify';'infrastructure_failed' }
            'verify:manual_target_pending' { 'manual_ui_required' }
            'verify:nonmaterial_scope_change' { 'plan' }
            'verify:material_divergence_detected' { $State.origin_state='verify';'awaiting_user_decision' }
            'verify_failed:repair_started' { 'work' }
            'verify_failed:replan_required' { 'plan' }
            'infrastructure_failed:selective_rerun_started' { if($State.resume_state){[string]$State.resume_state}else{'verify'} }
            'infrastructure_failed:external_evidence_accepted' { if($State.resume_state){[string]$State.resume_state}else{'verify'} }
            'infrastructure_failed:provider_restored' { if($State.resume_state){[string]$State.resume_state}else{'verify'} }
            'manual_ui_required:manual_evidence_passed' { 'verify' }
            'manual_ui_required:manual_evidence_failed' { 'work' }
            'manual_ui_required:manual_evidence_invalid' { 'manual_ui_required' }
            'review:review_approved' { Get-PostReviewTarget -Configuration $Configuration }
            'review:review_changes_requested_work' { 'review_changes_requested' }
            'review:review_changes_requested_plan' { 'plan' }
            'review:review_provider_failed' { $State.resume_state='review';'infrastructure_failed' }
            'review_changes_requested:repair_started' { 'work' }
            'review_changes_requested:replan_required' { 'plan' }
            'deploy_pending:deploy_approved' { 'deploy' }
            'deploy_pending:deploy_rejected' { 'cancelled' }
            'deploy_pending:scenario_changed' { 'plan' }
            'deploy:deploy_succeeded' { 'ready' }
            'deploy:deploy_failed' { 'deploy_failed' }
            'deploy_failed:retry_requested' { 'deploy_pending' }
            'deploy_failed:replan_required' { 'plan' }
            default { throw "Illegal pipeline event: $key" }
        }
    }
    $record = [pscustomobject][ordered]@{
        from = $from
        event = $Event
        original_event = $originalEvent
        to = $target
        correlation_id = $CorrelationId
        evidence_path = $EvidencePath
        binding_hash = $bindingHash
        at = [datetime]::UtcNow.ToString('o')
    }
    $State.transitions = @($State.transitions) + $record
    $State.correlation_ids = @($State.correlation_ids) + $CorrelationId
    $State.correlation_records = @($State.correlation_records) + [pscustomobject]@{id=$CorrelationId;binding_hash=$bindingHash}
    $State.status = $target
    $State.revision = [int]$State.revision + 1
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
