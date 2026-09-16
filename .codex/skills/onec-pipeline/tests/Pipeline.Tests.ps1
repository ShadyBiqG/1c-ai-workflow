BeforeAll {
    $ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
    $ModulePath = Join-Path $ProjectRoot '.codex\skills\onec-pipeline\scripts\PipelineState.psm1'
    Import-Module $ModulePath -Force

    function Copy-TestConfiguration {
        param([string]$Destination)
        Copy-Item -LiteralPath (Join-Path $ProjectRoot '.pipeline\pipeline.json') -Destination $Destination
        return (Get-Content -Raw -LiteralPath $Destination | ConvertFrom-Json)
    }
    function Save-TestConfiguration {
        param($Value, [string]$Path)
        [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    }
    function New-TestTaskArtifactSet {
        param([string]$Root, [string]$TaskId, [string[]]$Paths = @('src/cf/Documents/X'))
        $taskDirectory = Join-Path $Root ".pipeline\tasks\$TaskId"
        [IO.Directory]::CreateDirectory($taskDirectory) | Out-Null
        Save-TestConfiguration ([ordered]@{ protocol_version = 1; task_id = $TaskId; status = 'work'; transitions = @(); correlation_ids = @(); updated_at = [datetime]::UtcNow.ToString('o') }) (Join-Path $taskDirectory 'state.json')
        Save-TestConfiguration ([ordered]@{ protocol_version = 1; complexity = 'small'; summary = 'Тест'; work_items = @([ordered]@{ id = 'work-main'; title = 'Тест'; role = 'worker'; depends_on = @(); paths = $Paths; acceptance_criteria = @('Готово'); test_requirements = @('Тест'); parallel_safe = $false }) }) (Join-Path $taskDirectory 'decomposition.json')
        Save-TestConfiguration ([ordered]@{ protocol_version = 1; task_id = $TaskId; items = @([ordered]@{ id = 'work-main'; status = 'completed' }) }) (Join-Path $taskDirectory 'work-items.json')
        [IO.File]::WriteAllText((Join-Path $taskDirectory 'test-plan.md'), '# План тестирования')
        return $taskDirectory
    }
}

Describe 'Read-PipelineConfiguration' {
    It 'читает JSON независимо от порядка и сохраняет специальные символы' {
        $path = Join-Path $TestDrive 'config.json'
        $value = Copy-TestConfiguration $path
        $value.verify.runner_path = "C:\Tools\a'b#c:runner.exe"
        $value.agents.allowed_models += 'gpt-next'
        $value.agents.work_model = 'gpt-next'
        Save-TestConfiguration $value $path
        $actual = Read-PipelineConfiguration -Path $path
        $actual.verify.runner_path | Should -Be "C:\Tools\a'b#c:runner.exe"
        $actual.agents.work_model | Should -Be 'gpt-next'
    }

    It 'отклоняет модель вне agents.allowed_models с именем ключа' {
        $path = Join-Path $TestDrive 'model.json'; $value = Copy-TestConfiguration $path
        $value.agents.work_model = 'unknown-model'; Save-TestConfiguration $value $path
        { Read-PipelineConfiguration -Path $path } | Should -Throw -ExpectedMessage '*agents.work_model*agents.allowed_models*'
    }

    It 'отклоняет недопустимый tests_scope' {
        $path = Join-Path $TestDrive 'scope.json'; $value = Copy-TestConfiguration $path
        $value.verify.tests_scope = 'changed'; Save-TestConfiguration $value $path
        { Read-PipelineConfiguration -Path $path } | Should -Throw -ExpectedMessage '*verify.tests_scope*'
    }

    It 'отклоняет строку вместо boolean' {
        $path = Join-Path $TestDrive 'boolean.json'; $value = Copy-TestConfiguration $path
        $value.verify.fail_on_not_run = 'sometimes'; Save-TestConfiguration $value $path
        { Read-PipelineConfiguration -Path $path } | Should -Throw -ExpectedMessage '*verify.fail_on_not_run*true or false*'
    }

    It 'отклоняет таймаут вне диапазона' {
        $path = Join-Path $TestDrive 'timeout.json'; $value = Copy-TestConfiguration $path
        $value.verify.timeout_seconds = 10; Save-TestConfiguration $value $path
        { Read-PipelineConfiguration -Path $path } | Should -Throw -ExpectedMessage '*verify.timeout_seconds*60*14400*'
    }

    It 'отклоняет цикл зависимостей с именами проверок' {
        $path = Join-Path $TestDrive 'cycle.json'; $value = Copy-TestConfiguration $path
        $value.verify.checks = @('a', 'b'); $value.verify.depends_on = [ordered]@{ a = @('b'); b = @('a') }; Save-TestConfiguration $value $path
        { Read-PipelineConfiguration -Path $path } | Should -Throw -ExpectedMessage '*verify.depends_on*cycle*a*b*'
    }

    It 'отклоняет зависимость от отсутствующей проверки' {
        $path = Join-Path $TestDrive 'missing.json'; $value = Copy-TestConfiguration $path
        $value.verify.checks = @('a'); $value.verify.depends_on = [ordered]@{ a = @('missing') }; Save-TestConfiguration $value $path
        { Read-PipelineConfiguration -Path $path } | Should -Throw -ExpectedMessage '*verify.depends_on.a*missing*'
    }
}

Describe 'Install-PipelineToProject' {
    It 'создаёт AGENTS.md и installed.json, но сохраняет существующий AGENTS.md' {
        $target = Join-Path $TestDrive 'project'; [IO.Directory]::CreateDirectory($target) | Out-Null
        $first = & (Join-Path $ProjectRoot 'scripts\Install-PipelineToProject.ps1') -TargetProject $target -SourceProject $ProjectRoot | ConvertFrom-Json
        $first.agents_md | Should -Be 'installed'
        (Get-Item (Join-Path $target 'AGENTS.md')).Length | Should -BeGreaterThan 0
        $installed = Get-Content -Raw (Join-Path $target '.pipeline\installed.json') | ConvertFrom-Json
        $installed.pipeline_version | Should -Not -BeNullOrEmpty
        $installed.source_sha256 | Should -Match '^[a-f0-9]{64}$'
        [IO.File]::WriteAllText((Join-Path $target 'AGENTS.md'), 'пользовательские правила')
        $before = (Get-FileHash (Join-Path $target 'AGENTS.md')).Hash
        $second = & (Join-Path $ProjectRoot 'scripts\Install-PipelineToProject.ps1') -TargetProject $target -SourceProject $ProjectRoot -Force -ResetConfiguration | ConvertFrom-Json
        $second.agents_md | Should -Be 'preserved'
        (Get-FileHash (Join-Path $target 'AGENTS.md')).Hash | Should -Be $before
        $runner = Join-Path $target 'runner.cmd'; [IO.File]::WriteAllText($runner, "@echo off`r`nexit /b 0`r`n")
        [IO.File]::WriteAllText((Join-Path $target 'v8project.yaml'), 'workPath: build')
        $configurationPath = Join-Path $target '.pipeline\pipeline.json'; $configuration = Get-Content -Raw $configurationPath | ConvertFrom-Json
        $configuration.verify.runner_path = $runner; Save-TestConfiguration $configuration $configurationPath
        & git -C $target init --quiet
        $readiness = & (Join-Path $target '.codex\skills\onec-pipeline\scripts\Test-PipelineReadiness.ps1') -ProjectRoot $target | ConvertFrom-Json
        $readiness.status | Should -Be 'ready'; @($readiness.blockers).Count | Should -Be 0
        $readiness.details.pipeline_version | Should -Be $installed.pipeline_version
    }

    It '-WhatIf не изменяет дерево проекта' {
        $target = Join-Path $TestDrive 'whatif'; [IO.Directory]::CreateDirectory($target) | Out-Null
        [IO.File]::WriteAllText((Join-Path $target 'keep.txt'), 'keep')
        $before = (Get-FileHash (Join-Path $target 'keep.txt')).Hash
        & (Join-Path $ProjectRoot 'scripts\Install-PipelineToProject.ps1') -TargetProject $target -SourceProject $ProjectRoot -WhatIf | Out-Null
        (Get-ChildItem -Recurse -File $target).Count | Should -Be 1
        (Get-FileHash (Join-Path $target 'keep.txt')).Hash | Should -Be $before
    }

    It 'мигрирует существующий pipeline.yaml через прежний модуль' {
        $target = Join-Path $TestDrive 'legacy'; $legacyScripts = Join-Path $target '.codex\skills\onec-pipeline\scripts'
        [IO.Directory]::CreateDirectory((Join-Path $target '.pipeline')) | Out-Null; [IO.Directory]::CreateDirectory($legacyScripts) | Out-Null
        [IO.File]::WriteAllText((Join-Path $target '.pipeline\pipeline.yaml'), "verify:`n  runner_path: legacy-runner.exe`n")
        $legacyModule = @'
function Read-PipelineConfiguration {
    param([string]$Path)
    [pscustomobject][ordered]@{
        protocol_version = 1
        verify = [pscustomobject][ordered]@{ runner_path = 'legacy-runner.exe'; checks = @('git_diff') }
    }
}
Export-ModuleMember -Function Read-PipelineConfiguration
'@
        [IO.File]::WriteAllText((Join-Path $legacyScripts 'PipelineState.psm1'), $legacyModule)
        $result = & (Join-Path $ProjectRoot 'scripts\Install-PipelineToProject.ps1') -TargetProject $target -SourceProject $ProjectRoot -Force | ConvertFrom-Json
        Import-Module $ModulePath -Force
        $result.configuration | Should -Be 'migrated'
        (Get-Content -Raw (Join-Path $target '.pipeline\pipeline.json') | ConvertFrom-Json).verify.runner_path | Should -Be 'legacy-runner.exe'
        Test-Path (Join-Path $target '.pipeline\pipeline.yaml') | Should -BeTrue
    }
}

Describe 'VERIFY adapters' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); [IO.Directory]::CreateDirectory($root) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $root '.pipeline\tasks\TASK-20260916-010101-abcd')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'v8project.yaml'), 'workPath: build')
        $configPath = Join-Path $root 'pipeline.json'; $configJson = Copy-TestConfiguration $configPath
        $configJson.verify.checks = @('build'); $configJson.verify.depends_on = [ordered]@{}; Save-TestConfiguration $configJson $configPath
    }

    It 'не считает stderr ошибкой при exit code 0 и сохраняет его в выводе' {
        $runner = Join-Path $root 'runner.cmd'; [IO.File]::WriteAllText($runner, "@echo off`r`necho warning 1>&2`r`nexit /b 0`r`n")
        $configJson.verify.runner_path = $runner; Save-TestConfiguration $configJson $configPath
        $configuration = Read-PipelineConfiguration $configPath; $before = $ErrorActionPreference
        $result = & (Join-Path $ProjectRoot '.codex\skills\onec-pipeline\scripts\verify-checks\build.ps1') -ProjectRoot $root -Configuration $configuration -TaskDirectory (Join-Path $root '.pipeline\tasks\TASK-20260916-010101-abcd')
        $result.status | Should -Be 'passed'; ($result.full_output -join "`n") | Should -Match 'warning'; $ErrorActionPreference | Should -Be $before
    }

    It 'возвращает exit code 3 как failed' {
        $runner = Join-Path $root 'runner3.cmd'; [IO.File]::WriteAllText($runner, "@echo off`r`necho warning 1>&2`r`nexit /b 3`r`n")
        $configJson.verify.runner_path = $runner; Save-TestConfiguration $configJson $configPath
        $result = & (Join-Path $ProjectRoot '.codex\skills\onec-pipeline\scripts\verify-checks\build.ps1') -ProjectRoot $root -Configuration (Read-PipelineConfiguration $configPath) -TaskDirectory (Join-Path $root '.pipeline\tasks\TASK-20260916-010101-abcd')
        $result.status | Should -Be 'failed'; $result.exit_code | Should -Be 3; ($result.full_output -join "`n") | Should -Match 'warning'
    }

    It 'останавливает зависший процесс по таймауту' {
        $runner = Join-Path $root 'slow.cmd'; [IO.File]::WriteAllText($runner, "@echo off`r`nping 127.0.0.1 -n 20 >nul`r`n")
        $configJson.verify.runner_path = $runner; Save-TestConfiguration $configJson $configPath
        $configuration = Read-PipelineConfiguration $configPath; $configuration.verify.timeout_seconds = 1
        $result = & (Join-Path $ProjectRoot '.codex\skills\onec-pipeline\scripts\verify-checks\build.ps1') -ProjectRoot $root -Configuration $configuration -TaskDirectory (Join-Path $root '.pipeline\tasks\TASK-20260916-010101-abcd')
        $result.status | Should -Be 'failed'; $result.timed_out | Should -BeTrue
    }

    It 'возвращает not_run для отсутствующего BSL Language Server' {
        $configJson.verify.bsl_ls_path = 'missing-bsl-language-server.exe'; Save-TestConfiguration $configJson $configPath
        $result = & (Join-Path $ProjectRoot '.codex\skills\onec-pipeline\scripts\verify-checks\bsl_lint.ps1') -ProjectRoot $root -Configuration (Read-PipelineConfiguration $configPath) -TaskDirectory (Join-Path $root '.pipeline\tasks\TASK-20260916-010101-abcd')
        $result.status | Should -Be 'failed'; $result.summary | Should -Match 'missing-bsl-language-server'
    }

    It 'запускает YAxUnit только для затронутого модуля' {
        $runner = Join-Path $root 'tests.cmd'; [IO.File]::WriteAllText($runner, "@echo off`r`nexit /b 0`r`n")
        $configJson.verify.runner_path = $runner; $configJson.verify.tests_scope = 'impacted'; Save-TestConfiguration $configJson $configPath
        $taskDirectory = Join-Path $root '.pipeline\tasks\TASK-20260916-010101-abcd'
        Save-TestConfiguration ([ordered]@{ changed_files = @('src/cf/Documents/X/Ext/ObjectModule.bsl') }) (Join-Path $taskDirectory 'verify-context.json')
        $result = & (Join-Path $ProjectRoot '.codex\skills\onec-pipeline\scripts\verify-checks\tests.ps1') -ProjectRoot $root -Configuration (Read-PipelineConfiguration $configPath) -TaskDirectory $taskDirectory
        $result.status | Should -Be 'passed'; $result.tests_scope | Should -Be 'impacted'; $result.selected_modules | Should -Contain 'X'
        ($result.command -join ' ') | Should -Match 'module X'; ($result.command -join ' ') | Should -Not -Match '\ball\b'
    }

    It 'переходит к all_fallback, если модуль определить нельзя' {
        $runner = Join-Path $root 'fallback.cmd'; [IO.File]::WriteAllText($runner, "@echo off`r`nexit /b 0`r`n")
        $configJson.verify.runner_path = $runner; $configJson.verify.tests_scope = 'impacted'; Save-TestConfiguration $configJson $configPath
        $taskDirectory = Join-Path $root '.pipeline\tasks\TASK-20260916-010101-abcd'
        Save-TestConfiguration ([ordered]@{ changed_files = @('README.md') }) (Join-Path $taskDirectory 'verify-context.json')
        $result = & (Join-Path $ProjectRoot '.codex\skills\onec-pipeline\scripts\verify-checks\tests.ps1') -ProjectRoot $root -Configuration (Read-PipelineConfiguration $configPath) -TaskDirectory $taskDirectory
        $result.status | Should -Be 'passed'; $result.tests_scope | Should -Be 'all_fallback'; $result.fallback_reason | Should -Not -BeNullOrEmpty
        ($result.command -join ' ') | Should -Match '\ball\b'
    }
}

Describe 'git_diff and dependencies' {
    It 'проваливает пустой diff и изменения вне decomposition' {
        $root = Join-Path $TestDrive 'git-project'; [IO.Directory]::CreateDirectory((Join-Path $root 'src\cf\Documents\X')) | Out-Null
        & git -C $root init --quiet; & git -C $root config user.email 'tests@example.invalid'; & git -C $root config user.name 'Pipeline Tests'
        [IO.File]::WriteAllText((Join-Path $root 'src\cf\Documents\X\base.txt'), 'base'); & git -C $root add .; & git -C $root commit --quiet -m baseline
        $task = New-TestTaskArtifactSet -Root $root -TaskId 'TASK-20260916-010101-abcd'
        $configPath = Join-Path $task 'pipeline.json'; Copy-TestConfiguration $configPath | Out-Null; $configuration = Read-PipelineConfiguration $configPath
        $clean = & (Join-Path $ProjectRoot '.codex\skills\onec-pipeline\scripts\verify-checks\git_diff.ps1') -ProjectRoot $root -Configuration $configuration -TaskDirectory $task
        $clean.status | Should -Be 'failed'; $clean.reason | Should -Be 'no_changes'
        [IO.Directory]::CreateDirectory((Join-Path $root 'src\cf\Documents\Y')) | Out-Null; [IO.File]::WriteAllText((Join-Path $root 'src\cf\Documents\Y\ObjectModule.bsl'), 'Процедура Тест() КонецПроцедуры')
        $unexpected = & (Join-Path $ProjectRoot '.codex\skills\onec-pipeline\scripts\verify-checks\git_diff.ps1') -ProjectRoot $root -Configuration $configuration -TaskDirectory $task
        $unexpected.status | Should -Be 'failed'; $unexpected.reason | Should -Be 'unexpected_paths'; $unexpected.unexpected_paths | Should -Contain 'src/cf/Documents/Y/ObjectModule.bsl'
    }

    It 'помечает tests как skipped после упавшего build и пишет duration/log evidence' {
        $root = Join-Path $TestDrive 'verify-project'; [IO.Directory]::CreateDirectory((Join-Path $root '.pipeline\tasks')) | Out-Null
        $taskId = 'TASK-20260916-010102-abcd'; $task = New-TestTaskArtifactSet -Root $root -TaskId $taskId
        [IO.File]::WriteAllText((Join-Path $root 'v8project.yaml'), 'workPath: build')
        $runner = Join-Path $root 'failed.cmd'; [IO.File]::WriteAllText($runner, "@echo off`r`necho failed`r`nexit /b 3`r`n")
        $configPath = Join-Path $root '.pipeline\pipeline.json'; [IO.Directory]::CreateDirectory((Split-Path $configPath)) | Out-Null
        $value = Copy-TestConfiguration $configPath; $value.manager.require_decomposition = $false; $value.manager.require_test_plan = $false
        $value.verify.runner_path = $runner; $value.verify.checks = @('build', 'tests'); $value.verify.depends_on = [ordered]@{ tests = @('build') }; Save-TestConfiguration $value $configPath
        $result = & (Join-Path $ProjectRoot '.codex\skills\onec-pipeline\scripts\Invoke-PipelineVerify.ps1') -TaskId $taskId -ProjectRoot $root -ConfigurationPath $configPath | ConvertFrom-Json
        $result.status | Should -Be 'failed'; $result.blocking_checks | Should -Contain 'tests'
        $evidence = Get-Content -Raw (Join-Path $task 'verify-evidence.json') | ConvertFrom-Json
        $evidence.checks.tests.status | Should -Be 'skipped'; $evidence.checks.tests.log_path | Should -BeNullOrEmpty
        $evidence.checks.build.duration_ms | Should -BeGreaterOrEqual 0
        Test-Path (Join-Path $root $evidence.checks.build.log_path) | Should -BeTrue
    }
}

Describe 'Статические инварианты' {
    It 'все VERIFY checks принимают обязательный TaskDirectory' {
        Get-ChildItem (Join-Path $ProjectRoot '.codex\skills\onec-pipeline\scripts\verify-checks') -Filter '*.ps1' | Where-Object Name -NotLike '_*' | ForEach-Object {
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
            $parameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'TaskDirectory' }
            $parameter | Should -Not -BeNullOrEmpty
            ($parameter.Attributes.NamedArguments.ArgumentName -contains 'Mandatory') | Should -BeTrue
        }
    }

    It 'не присваивает автоматическую переменную Matches' {
        $hits = Select-String -Path (Join-Path $ProjectRoot '.codex\skills\onec-pipeline\scripts\*.ps1') -Pattern '\$matches\s*=' -CaseSensitive:$false
        $hits | Should -BeNullOrEmpty
    }
}
