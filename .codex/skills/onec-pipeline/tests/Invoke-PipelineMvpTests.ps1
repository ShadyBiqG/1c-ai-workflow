[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message Expected=$Expected Actual=$Actual" }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $thrown = $false
    try { & $Action }
    catch { $thrown = $true }
    if (-not $thrown) { throw $Message }
}

function Write-TestConfiguration {
    param(
        [string]$Path,
        [string]$Mode,
        [bool]$Available,
        [bool]$DeployEnabled = $false,
        [string]$RunnerPath = 'null'
    )
    $text = @"
version: 1
agents:
  controller_model: gpt-5.6-terra
  controller_reasoning: high
  manager_model: gpt-5.6-terra
  manager_reasoning: high
  plan_model: gpt-5.6-sol
  plan_reasoning: high
  work_model: gpt-5.6-luna
  work_reasoning: medium
  deploy_model: gpt-5.6-luna
  deploy_reasoning: medium
manager:
  max_parallel_workers: 3
  require_test_plan: true
  require_decomposition: true
  require_architecture: true
  require_architecture_review: true
  architecture_for:
    - medium
    - large
    - critical
  architecture_review_for:
    - medium
    - large
    - critical
  plan_approval_for:
    - large
    - critical
review:
  mode: $Mode
  available: $($Available.ToString().ToLowerInvariant())
  provider: null
deploy:
  enabled: $($DeployEnabled.ToString().ToLowerInvariant())
  available: $($DeployEnabled.ToString().ToLowerInvariant())
  adapter: $(if ($DeployEnabled) { 'test-adapter' } else { 'null' })
  require_approval: true
verify:
  fail_on_config_dump_info: true
  fail_on_not_run: true
  runner_path: $RunnerPath
  runner_config: v8project.yaml
  checks:
    - git_diff
    - source_validation
    - build
    - tests
"@
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($false)))
}

function New-TestTask {
    param([string]$Root, [string]$TaskId)
    $directory = Join-Path $Root ".pipeline\tasks\$TaskId"
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $state = [ordered]@{ protocol_version = 1; task_id = $TaskId; status = 'work'; transitions = @(); correlation_ids = @(); updated_at = [datetime]::UtcNow.ToString('o') }
    [IO.File]::WriteAllText((Join-Path $directory 'state.json'), ($state | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    $decomposition = [ordered]@{
        protocol_version = 1; complexity = 'small'; summary = 'Test task'
        work_items = @([ordered]@{
            id = 'work-main'; title = 'Test work'; role = 'worker'; depends_on = @(); paths = @('src/')
            acceptance_criteria = @('Completed'); test_requirements = @('Smoke test'); parallel_safe = $false
        })
    }
    [IO.File]::WriteAllText((Join-Path $directory 'decomposition.json'), ($decomposition | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    $workItems = [ordered]@{
        protocol_version = 1; task_id = $TaskId
        items = @([ordered]@{ id = 'work-main'; status = 'completed' })
    }
    [IO.File]::WriteAllText((Join-Path $directory 'work-items.json'), ($workItems | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $directory 'test-plan.md'), '# Test plan')
}

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
$modulePath = Join-Path $projectRoot '.codex\skills\onec-pipeline\scripts\PipelineState.psm1'
$moduleText = [IO.File]::ReadAllText($modulePath, [Text.Encoding]::UTF8)
Assert-Equal ([regex]::Matches($moduleText, '(?m)^function Read-PipelineConfiguration\s*\{').Count) 1 'Read-PipelineConfiguration must be unique.'
Assert-Equal ([regex]::Matches($moduleText, '(?m)^function Get-PostVerifyTarget\s*\{').Count) 1 'Get-PostVerifyTarget must be unique.'

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("onec-workflow-tests-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    & (Join-Path $projectRoot 'scripts\Install-PipelineToProject.ps1') -TargetProject $temporaryRoot -SourceProject $projectRoot | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\SKILL.md')) 'Pipeline installer must copy the local engine skill.'
    Assert-True (Test-Path -LiteralPath (Join-Path $temporaryRoot '.codex\skills\1c-ai-workflow\SKILL.md')) 'Pipeline installer must copy the Manager skill.'
    Assert-True (Test-Path -LiteralPath (Join-Path $temporaryRoot 'scripts\Install-PipelineToProject.ps1')) 'Pipeline installer must copy itself for installed smoke tests.'
    Assert-True (Test-Path -LiteralPath (Join-Path $temporaryRoot '.pipeline\references\workflow-schema.md')) 'Pipeline installer must copy the workflow schema.'
    $configurationPath = Join-Path $temporaryRoot '.pipeline\pipeline.yaml'
    $projectConfiguration = (Get-Content -Raw -LiteralPath $configurationPath) -replace 'runner_path: null', 'runner_path: project-runner.exe'
    [IO.File]::WriteAllText($configurationPath, $projectConfiguration, (New-Object Text.UTF8Encoding($false)))
    $updateResult = (& (Join-Path $projectRoot 'scripts\Install-PipelineToProject.ps1') -TargetProject $temporaryRoot -SourceProject $projectRoot -Force | ConvertFrom-Json)
    Assert-Equal $updateResult.configuration 'preserved' 'Pipeline update must preserve project configuration by default.'
    Assert-True ((Get-Content -Raw -LiteralPath $configurationPath) -match 'runner_path: project-runner\.exe') 'Pipeline update changed project configuration unexpectedly.'
    $resetResult = (& (Join-Path $projectRoot 'scripts\Install-PipelineToProject.ps1') -TargetProject $temporaryRoot -SourceProject $projectRoot -Force -ResetConfiguration | ConvertFrom-Json)
    Assert-Equal $resetResult.configuration 'reset' 'Explicit configuration reset must be reported.'
    Assert-True ((Get-Content -Raw -LiteralPath $configurationPath) -match 'runner_path: null') 'Explicit reset must restore the packaged configuration.'
    & git -C $temporaryRoot init --quiet
    & git -C $temporaryRoot config user.email 'pipeline-tests@example.invalid'
    & git -C $temporaryRoot config user.name 'Pipeline Tests'
    [IO.Directory]::CreateDirectory((Join-Path $temporaryRoot 'src\cf')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $temporaryRoot 'src\cf\ConfigDumpInfo.xml'), '<ConfigDumpInfo />')
    & git -C $temporaryRoot add .
    & git -C $temporaryRoot commit --quiet -m 'baseline'

    $verifyScript = Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Invoke-PipelineVerify.ps1'
    Import-Module (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\PipelineState.psm1') -Force
    Write-TestConfiguration -Path $configurationPath -Mode disabled -Available $false
    $fakeRunnerPath = Join-Path $temporaryRoot 'fake-v8-runner.cmd'
    [IO.File]::WriteAllText($fakeRunnerPath, "@echo off`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $temporaryRoot 'v8project.yaml'), "workPath: build`n", (New-Object Text.UTF8Encoding($false)))
    Write-TestConfiguration -Path $configurationPath -Mode disabled -Available $false -RunnerPath $fakeRunnerPath
    $adapterResult = & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\verify-checks\build.ps1') -ProjectRoot $temporaryRoot -Configuration (Read-PipelineConfiguration -Path $configurationPath)
    Assert-Equal $adapterResult.status 'passed' 'Configured v8-runner adapter must execute successfully.'
    [IO.File]::WriteAllText((Join-Path $temporaryRoot 'AGENTS.md'), '# Project rules')
    $readiness = (& (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Test-PipelineReadiness.ps1') -ProjectRoot $temporaryRoot -ConfigurationPath $configurationPath | ConvertFrom-Json)
    Assert-Equal $readiness.status 'ready' 'A fully configured project must pass pipeline readiness preflight.'
    Write-TestConfiguration -Path $configurationPath -Mode disabled -Available $false -RunnerPath $fakeRunnerPath
    $profiles = @{
        controller = @('gpt-5.6-terra', 'high'); manager = @('gpt-5.6-terra', 'high')
        architect = @('gpt-5.6-sol', 'high'); worker = @('gpt-5.6-luna', 'medium')
        deploy = @('gpt-5.6-luna', 'medium')
    }
    foreach ($role in $profiles.Keys) {
        $profile = (& (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Get-PipelineAgentProfile.ps1') -Role $role -ProjectRoot $temporaryRoot -ConfigurationPath $configurationPath | ConvertFrom-Json)
        Assert-Equal $profile.model $profiles[$role][0] "Wrong model for $role."
        Assert-Equal $profile.reasoning $profiles[$role][1] "Wrong reasoning for $role."
    }
    $requestPath = Join-Path $temporaryRoot 'request.md'
    $planPath = Join-Path $temporaryRoot 'plan.md'
    $testPlanPath = Join-Path $temporaryRoot 'test-plan-input.md'
    $decompositionInputPath = Join-Path $temporaryRoot 'decomposition-input.json'
    $workResultPath = Join-Path $temporaryRoot 'work-result.md'
    $architectureInputPath = Join-Path $temporaryRoot 'architecture-input.md'
    $architectureReviewEvidencePath = Join-Path $temporaryRoot 'architecture-review.md'
    [IO.File]::WriteAllText($requestPath, '# Request')
    [IO.File]::WriteAllText($planPath, '# Plan')
    [IO.File]::WriteAllText($testPlanPath, '# Test plan')
    [IO.File]::WriteAllText($workResultPath, '# Work result')
    [IO.File]::WriteAllText($architectureInputPath, '# Architecture v1')
    [IO.File]::WriteAllText($architectureReviewEvidencePath, '# Architecture review evidence')
    $managerDecomposition = [ordered]@{
        protocol_version = 1; complexity = 'medium'; summary = 'Manager flow'
        work_items = @([ordered]@{
            id = 'work-manager'; title = 'Manager work'; role = 'worker'; depends_on = @(); paths = @('src/')
            acceptance_criteria = @('Completed'); test_requirements = @('Smoke test'); parallel_safe = $false
        })
    }
    [IO.File]::WriteAllText($decompositionInputPath, ($managerDecomposition | ConvertTo-Json -Depth 10))
    $createdTask = (& (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\New-PipelineTask.ps1') -RequestFile $requestPath -ProjectRoot $temporaryRoot | ConvertFrom-Json)
    Assert-True (Test-Path -LiteralPath (Join-Path $createdTask.task_directory 'memory.md')) 'New task must contain persisted memory.'
    Assert-True (Test-Path -LiteralPath (Join-Path $createdTask.task_directory 'journal.json')) 'New task must contain a journal.'
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Save-PipelineDecomposition.ps1') -TaskId $createdTask.task_id -DecompositionFile $decompositionInputPath -ProjectRoot $temporaryRoot | Out-Null
    Assert-Throws -Action {
        & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Complete-PipelinePlan.ps1') -TaskId $createdTask.task_id -PlanFile $planPath -TestPlanFile $testPlanPath -ProjectRoot $temporaryRoot | Out-Null
    } -Message 'PLAN must require an architecture artifact and review.'
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Save-PipelineArchitecture.ps1') -TaskId $createdTask.task_id -ArchitectureFile $architectureInputPath -ArchitectId 'architect-test' -ProjectRoot $temporaryRoot | Out-Null
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Complete-PipelineArchitectureReview.ps1') -TaskId $createdTask.task_id -Verdict changes_requested -EvidenceFile $architectureReviewEvidencePath -ReviewerId 'architecture-reviewer-test' -ProjectRoot $temporaryRoot | Out-Null
    Assert-Throws -Action {
        & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Complete-PipelinePlan.ps1') -TaskId $createdTask.task_id -PlanFile $planPath -TestPlanFile $testPlanPath -ProjectRoot $temporaryRoot | Out-Null
    } -Message 'Changes-requested architecture must block WORK.'
    [IO.File]::WriteAllText($architectureInputPath, '# Architecture v2')
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Save-PipelineArchitecture.ps1') -TaskId $createdTask.task_id -ArchitectureFile $architectureInputPath -ArchitectId 'architect-test' -ProjectRoot $temporaryRoot | Out-Null
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Complete-PipelineArchitectureReview.ps1') -TaskId $createdTask.task_id -Verdict approved -EvidenceFile $architectureReviewEvidencePath -ReviewerId 'architecture-reviewer-test' -ProjectRoot $temporaryRoot | Out-Null
    [IO.File]::AppendAllText((Join-Path $createdTask.task_directory 'architecture.md'), "`nChanged after architecture review")
    Assert-Throws -Action {
        & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Complete-PipelinePlan.ps1') -TaskId $createdTask.task_id -PlanFile $planPath -TestPlanFile $testPlanPath -ProjectRoot $temporaryRoot | Out-Null
    } -Message 'Changed architecture must invalidate prior architecture review.'
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Save-PipelineArchitecture.ps1') -TaskId $createdTask.task_id -ArchitectureFile $architectureInputPath -ArchitectId 'architect-test' -ProjectRoot $temporaryRoot | Out-Null
    Assert-Throws -Action {
        & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Complete-PipelineArchitectureReview.ps1') -TaskId $createdTask.task_id -Verdict approved -EvidenceFile $architectureReviewEvidencePath -ReviewerId 'architect-test' -ProjectRoot $temporaryRoot | Out-Null
    } -Message 'Architect must not review their own architecture.'
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Complete-PipelineArchitectureReview.ps1') -TaskId $createdTask.task_id -Verdict approved -EvidenceFile $architectureReviewEvidencePath -ReviewerId 'architecture-reviewer-test' -ProjectRoot $temporaryRoot | Out-Null
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Complete-PipelinePlan.ps1') -TaskId $createdTask.task_id -PlanFile $planPath -TestPlanFile $testPlanPath -ProjectRoot $temporaryRoot | Out-Null
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Update-PipelineWorkItem.ps1') -TaskId $createdTask.task_id -WorkItemId 'work-manager' -Status in_progress -AgentId 'agent-test' -ProjectRoot $temporaryRoot | Out-Null
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Update-PipelineWorkItem.ps1') -TaskId $createdTask.task_id -WorkItemId 'work-manager' -Status completed -ResultFile $workResultPath -ProjectRoot $temporaryRoot | Out-Null
    $managerResult = (& $verifyScript -TaskId $createdTask.task_id -ProjectRoot $temporaryRoot -ConfigurationPath $configurationPath | ConvertFrom-Json)
    Assert-Equal $managerResult.next_state 'ready' 'Complete Manager flow must reach READY.'
    $memoryInputPath = Join-Path $temporaryRoot 'memory-input.md'
    $summaryInputPath = Join-Path $temporaryRoot 'summary-input.md'
    [IO.File]::WriteAllText($memoryInputPath, '# Updated memory')
    [IO.File]::WriteAllText($summaryInputPath, '# Final summary')
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Save-PipelineMemory.ps1') -TaskId $createdTask.task_id -MemoryFile $memoryInputPath -ProjectRoot $temporaryRoot | Out-Null
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Save-PipelineSummary.ps1') -TaskId $createdTask.task_id -SummaryFile $summaryInputPath -ProjectRoot $temporaryRoot | Out-Null
    Assert-Equal (Get-Content -Raw -LiteralPath (Join-Path $createdTask.task_directory 'memory.md')) '# Updated memory' 'Saved task memory must match its input.'
    Assert-Equal (Get-Content -Raw -LiteralPath (Join-Path $createdTask.task_directory 'summary.md')) '# Final summary' 'Saved task summary must match its input.'
    $managerJournal = Get-Content -Raw -LiteralPath (Join-Path $createdTask.task_directory 'journal.json') | ConvertFrom-Json
    Assert-True (@($managerJournal.entries).Count -ge 8) 'Manager flow must document its significant steps.'

    $smallRequestPath = Join-Path $temporaryRoot 'small-request.md'
    $smallDecompositionPath = Join-Path $temporaryRoot 'small-decomposition.json'
    [IO.File]::WriteAllText($smallRequestPath, '# Small request')
    $smallDecomposition = [ordered]@{
        protocol_version = 1; complexity = 'small'; summary = 'Economy route'
        work_items = @([ordered]@{
            id = 'work-small'; title = 'Small work'; role = 'worker'; depends_on = @(); paths = @('src/')
            acceptance_criteria = @('Completed'); test_requirements = @('Smoke test'); parallel_safe = $false
        })
    }
    [IO.File]::WriteAllText($smallDecompositionPath, ($smallDecomposition | ConvertTo-Json -Depth 10))
    $smallTask = (& (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\New-PipelineTask.ps1') -RequestFile $smallRequestPath -ProjectRoot $temporaryRoot | ConvertFrom-Json)
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Save-PipelineDecomposition.ps1') -TaskId $smallTask.task_id -DecompositionFile $smallDecompositionPath -ProjectRoot $temporaryRoot | Out-Null
    $smallState = (& (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Complete-PipelinePlan.ps1') -TaskId $smallTask.task_id -PlanFile $planPath -TestPlanFile $testPlanPath -ProjectRoot $temporaryRoot | ConvertFrom-Json)
    Assert-Equal $smallState.status 'work' 'Small tasks must use the economy route without separate architecture agents.'

    $largeRequestPath = Join-Path $temporaryRoot 'large-request.md'
    $largeDecompositionPath = Join-Path $temporaryRoot 'large-decomposition.json'
    [IO.File]::WriteAllText($largeRequestPath, '# Large request')
    $largeDecomposition = [ordered]@{
        protocol_version = 1; complexity = 'large'; summary = 'Approval gate'
        work_items = @([ordered]@{
            id = 'work-large'; title = 'Large work'; role = 'worker'; depends_on = @(); paths = @('src/')
            acceptance_criteria = @('Completed'); test_requirements = @('Smoke test'); parallel_safe = $false
        })
    }
    [IO.File]::WriteAllText($largeDecompositionPath, ($largeDecomposition | ConvertTo-Json -Depth 10))
    $largeTask = (& (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\New-PipelineTask.ps1') -RequestFile $largeRequestPath -ProjectRoot $temporaryRoot | ConvertFrom-Json)
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Save-PipelineDecomposition.ps1') -TaskId $largeTask.task_id -DecompositionFile $largeDecompositionPath -ProjectRoot $temporaryRoot | Out-Null
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Save-PipelineArchitecture.ps1') -TaskId $largeTask.task_id -ArchitectureFile $architectureInputPath -ArchitectId 'architect-large' -ProjectRoot $temporaryRoot | Out-Null
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Complete-PipelineArchitectureReview.ps1') -TaskId $largeTask.task_id -Verdict approved -EvidenceFile $architectureReviewEvidencePath -ReviewerId 'architecture-reviewer-large' -ProjectRoot $temporaryRoot | Out-Null
    Assert-Throws -Action {
        & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Complete-PipelinePlan.ps1') -TaskId $largeTask.task_id -PlanFile $planPath -TestPlanFile $testPlanPath -ProjectRoot $temporaryRoot | Out-Null
    } -Message 'Large plan must not enter WORK without explicit approval.'
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Approve-PipelinePlan.ps1') -TaskId $largeTask.task_id -PlanFile $planPath -TestPlanFile $testPlanPath -ProjectRoot $temporaryRoot | Out-Null
    [IO.File]::AppendAllText($planPath, "`nChanged after approval")
    Assert-Throws -Action {
        & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Complete-PipelinePlan.ps1') -TaskId $largeTask.task_id -PlanFile $planPath -TestPlanFile $testPlanPath -ProjectRoot $temporaryRoot | Out-Null
    } -Message 'Changed plan must invalidate prior approval.'
    & (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Approve-PipelinePlan.ps1') -TaskId $largeTask.task_id -PlanFile $planPath -TestPlanFile $testPlanPath -ProjectRoot $temporaryRoot | Out-Null
    $approvedLargeState = (& (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Complete-PipelinePlan.ps1') -TaskId $largeTask.task_id -PlanFile $planPath -TestPlanFile $testPlanPath -ProjectRoot $temporaryRoot | ConvertFrom-Json)
    Assert-Equal $approvedLargeState.status 'work' 'Approved current large plan must enter WORK.'

    $cases = @(
        @{ id = 'TASK-20260914-100001-a001'; mode = 'disabled'; available = $false; expected = 'ready' },
        @{ id = 'TASK-20260914-100002-a002'; mode = 'optional'; available = $false; expected = 'ready' },
        @{ id = 'TASK-20260914-100003-a003'; mode = 'optional'; available = $true; expected = 'review' },
        @{ id = 'TASK-20260914-100004-a004'; mode = 'required'; available = $false; expected = 'review' }
    )
    foreach ($case in $cases) {
        New-TestTask -Root $temporaryRoot -TaskId $case.id
        Write-TestConfiguration -Path $configurationPath -Mode $case.mode -Available $case.available -RunnerPath $fakeRunnerPath
        $result = (& $verifyScript -TaskId $case.id -ProjectRoot $temporaryRoot -ConfigurationPath $configurationPath | ConvertFrom-Json)
        Assert-Equal $result.status 'passed' "VERIFY failed unexpectedly for $($case.mode)."
        Assert-Equal $result.next_state $case.expected "Wrong route for $($case.mode)."
    }

    $reviewEvidence = Join-Path $temporaryRoot 'review-result.txt'
    [IO.File]::WriteAllText($reviewEvidence, 'approved')
    $reviewResult = (& (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Complete-PipelineReview.ps1') -TaskId 'TASK-20260914-100004-a004' -Verdict approved -EvidenceFile $reviewEvidence -ProjectRoot $temporaryRoot | ConvertFrom-Json)
    Assert-Equal $reviewResult.next_state 'ready' 'Approved required REVIEW must lead to READY.'

    $failedTaskId = 'TASK-20260914-100005-a005'
    New-TestTask -Root $temporaryRoot -TaskId $failedTaskId
    Write-TestConfiguration -Path $configurationPath -Mode disabled -Available $false
    [IO.File]::WriteAllText((Join-Path $temporaryRoot 'src\cf\ConfigDumpInfo.xml'), '<ConfigDumpInfo changed="true" />')
    $failedResult = (& $verifyScript -TaskId $failedTaskId -ProjectRoot $temporaryRoot -ConfigurationPath $configurationPath | ConvertFrom-Json)
    Assert-Equal $failedResult.status 'failed' 'ConfigDumpInfo.xml change must fail VERIFY.'
    Assert-Equal $failedResult.next_state 'work' 'Failed VERIFY must return to WORK.'

    & git -C $temporaryRoot checkout --quiet -- 'src/cf/ConfigDumpInfo.xml'
    Remove-Item -LiteralPath $fakeRunnerPath, (Join-Path $temporaryRoot 'v8project.yaml') -Force
    $notRunTaskId = 'TASK-20260914-100007-a007'
    New-TestTask -Root $temporaryRoot -TaskId $notRunTaskId
    Write-TestConfiguration -Path $configurationPath -Mode disabled -Available $false
    $notRunResult = (& $verifyScript -TaskId $notRunTaskId -ProjectRoot $temporaryRoot -ConfigurationPath $configurationPath | ConvertFrom-Json)
    Assert-Equal $notRunResult.status 'failed' 'A configured check that was not run must fail VERIFY by default.'
    Assert-Equal $notRunResult.next_state 'work' 'A not-run mandatory check must return the task to WORK.'
    Assert-True (@($notRunResult.not_run_checks) -contains 'tests') 'VERIFY evidence must expose not-run checks.'

    [IO.File]::WriteAllText($fakeRunnerPath, "@echo off`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $temporaryRoot 'v8project.yaml'), "workPath: build`n", (New-Object Text.UTF8Encoding($false)))

    $deployTaskId = 'TASK-20260914-100006-a006'
    New-TestTask -Root $temporaryRoot -TaskId $deployTaskId
    Write-TestConfiguration -Path $configurationPath -Mode disabled -Available $false -DeployEnabled $true -RunnerPath $fakeRunnerPath
    & git -C $temporaryRoot checkout --quiet -- 'src/cf/ConfigDumpInfo.xml'
    $deployRoute = (& $verifyScript -TaskId $deployTaskId -ProjectRoot $temporaryRoot -ConfigurationPath $configurationPath | ConvertFrom-Json)
    Assert-Equal $deployRoute.next_state 'deploy_pending' 'Enabled Deploy must wait for explicit approval.'
    $deployScenarioPath = Join-Path $temporaryRoot 'deploy-scenario.md'
    $deployEvidencePath = Join-Path $temporaryRoot 'deploy-evidence.md'
    [IO.File]::WriteAllText($deployScenarioPath, '# Backup, apply, verify, rollback')
    [IO.File]::WriteAllText($deployEvidencePath, '# Deploy succeeded')
    $deployApproval = (& (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Approve-PipelineDeploy.ps1') -TaskId $deployTaskId -ScenarioFile $deployScenarioPath -ProjectRoot $temporaryRoot | ConvertFrom-Json)
    Assert-Equal $deployApproval.next_state 'deploy' 'Approved Deploy scenario must enter deploy state.'
    $deployResult = (& (Join-Path $temporaryRoot '.codex\skills\onec-pipeline\scripts\Complete-PipelineDeploy.ps1') -TaskId $deployTaskId -Status succeeded -EvidenceFile $deployEvidencePath -ProjectRoot $temporaryRoot | ConvertFrom-Json)
    Assert-Equal $deployResult.next_state 'ready' 'Successful Deploy must lead to READY.'

    [pscustomobject][ordered]@{
        status = 'passed'
        scenarios = 26
        routes = @('project-installer', 'project-update-preserves-config', 'project-config-explicit-reset', 'project-readiness-preflight', 'v8-runner-adapter', 'agent-model-profiles', 'manager-decomposition', 'small-economy-route', 'persisted-artifacts', 'persisted-memory', 'persisted-summary', 'architecture-required', 'architecture-changes-requested', 'architecture-review-stale', 'architecture-review-independent', 'large-approval-required', 'changed-plan-invalidates-approval', 'disabled', 'optional-unavailable', 'optional-available', 'required-unavailable', 'required-approved', 'verify-failed', 'verify-not-run-failed', 'deploy-approval-required', 'deploy-succeeded')
    } | ConvertTo-Json -Depth 5
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
