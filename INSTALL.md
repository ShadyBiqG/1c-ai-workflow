# Установка и обновление

## Предварительные условия

- Windows PowerShell 5.1 или PowerShell 7;
- Git в `PATH`;
- Pester 5.7.1+ для тестов;
- v8-runner и `v8project.yaml` для build/source validation/YAxUnit;
- BSL Language Server для проверки `bsl_lint`.

Проверка поставки:

```powershell
Install-Module Pester -MinimumVersion 5.7.1 -Scope CurrentUser
& .\.codex\skills\onec-pipeline\tests\Invoke-PipelineMvpTests.ps1
```

## Глобальный навык

```powershell
& .\scripts\Install-WorkflowSkill.ps1
# обновление
& .\scripts\Install-WorkflowSkill.ps1 -Force
```

## Установка в проект

```powershell
& .\scripts\Install-PipelineToProject.ps1 -TargetProject 'F:\Work\my-1c-project' -WhatIf
& .\scripts\Install-PipelineToProject.ps1 -TargetProject 'F:\Work\my-1c-project'
```

Обновление сохраняет проектный `.pipeline/pipeline.json` и `AGENTS.md`:

```powershell
& .\scripts\Install-PipelineToProject.ps1 -TargetProject 'F:\Work\my-1c-project' -Force
```

Только явный `-Force -ResetConfiguration` заменяет JSON шаблоном поставки. `AGENTS.md` не заменяется никогда. Если найдена прежняя установка только с `pipeline.yaml`, создаётся актуальный `pipeline.json`, а YAML остаётся резервной копией.

В `.pipeline/installed.json` фиксируются версия, UTC-время установки и SHA-256 устанавливаемой поставки.

## Подготовка VERIFY

В `.pipeline/pipeline.json` задайте `verify.runner_path` или добавьте `v8-runner.exe` в `PATH`. Проверьте `verify.runner_config`, BSL Language Server и затем выполните:

```powershell
& .\.codex\skills\onec-pipeline\scripts\Test-PipelineReadiness.ps1
```

Ожидаемый результат — `status = ready`, пустой массив `blockers` и версия в `details.pipeline_version`.

## Полный маршрут задачи

```powershell
$task = & .\.codex\skills\onec-pipeline\scripts\New-PipelineTask.ps1 -RequestFile .\request.md | ConvertFrom-Json

& .\.codex\skills\onec-pipeline\scripts\Save-PipelineArchitecture.ps1 `
  -TaskId $task.task_id -ArchitectureFile .\architecture.md -ArchitectId $architectAgentId

& .\.codex\skills\onec-pipeline\scripts\Complete-PipelineArchitectureReview.ps1 `
  -TaskId $task.task_id -Verdict approved -EvidenceFile .\architecture-review.md -ReviewerId $reviewerAgentId

& .\.codex\skills\onec-pipeline\scripts\Save-PipelineDecomposition.ps1 `
  -TaskId $task.task_id -DecompositionFile .\decomposition.json

# Для large/critical сначала Approve-PipelinePlan.ps1.
& .\.codex\skills\onec-pipeline\scripts\Complete-PipelinePlan.ps1 `
  -TaskId $task.task_id -PlanFile .\plan.md -TestPlanFile .\test-plan.md

# После выполнения и завершения всех work items:
& .\.codex\skills\onec-pipeline\scripts\Invoke-PipelineVerify.ps1 -TaskId $task.task_id
```

Deploy по умолчанию выключен. Его включение требует доступного adapter и отдельного human approval неизменного сценария.
