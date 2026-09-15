# 1C AI Workflow

Локальный persisted pipeline для разработки конфигураций 1С через Codex App:

```text
CONTROLLER -> MANAGER -> PLAN[ARCHITECT -> ARCHITECTURE REVIEWER] -> WORK -> VERIFY -> [REVIEW] -> [DEPLOY] -> READY
```

VERIFY обязателен. При ошибке или невозможности запустить обязательную проверку задача автоматически возвращается в WORK, а результаты сохраняются в `.pipeline/tasks/<task-id>/verify-evidence.json`.

## Общение через Manager

Основная точка входа — project skill `$1c-ai-workflow`. Пользователь формулирует Manager только исходную задачу, например:

```text
$1c-ai-workflow Добавь новую проверку качества исходников и доведи задачу до READY.
```

Manager оценивает сложность, при необходимости вызывает Explorer, передаёт исследование Architect, получает независимый вердикт Architecture Reviewer, а затем создаёт decomposition, назначает work items внутренним Worker-агентам, собирает результаты и запускает VERIFY. Пользователь получает от Manager прогресс и единый итог, не управляя исполнителями вручную.

По умолчанию Manager запрашивает явное подтверждение плана для `large` и `critical`. Для `small` и `medium` он продолжает автономно. Отдельное актуальное подтверждение всегда требуется перед deploy, публикацией, внешней записью или другим необратимым действием; одобрение плана такого разрешения не даёт.

Для каждой задачи обязательны `plan.md`, `test-plan.md`, `decomposition.json` и persisted `work-items.json`. Отдельные `architecture.md` и `architecture-review.json` обязательны для сложностей, перечисленных в `manager.architecture_for` и `manager.architecture_review_for`; маршрут `small` обходится без дополнительных модельных ролей. Зависимые work items запускаются только после завершения предшественников; циклические зависимости отклоняются.

Все существенные шаги, решения и подтверждения сохраняются в `.pipeline/tasks/<task-id>/journal.json`. Файл `memory.md` содержит краткий контекст для продолжения в новом чате, а `summary.md` — итог задачи. Полный контракт описан в [артефактах задачи](.pipeline/references/task-artifacts.md); происхождение архитектурных идей — в [матрице влияния](.pipeline/references/design-provenance.md).

## Конфигурация

Настройки находятся в `.pipeline/pipeline.yaml`. REVIEW по умолчанию отключён:

```yaml
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
```

VERIFY выполняется скриптами и модели не требует. Architect и Architecture Reviewer используют профиль Plan, но запускаются как разные агенты.

REVIEW по умолчанию отключён:

```yaml
review:
  mode: disabled
  available: false
  provider: null
```

Режимы:

- `disabled` — успешный VERIFY переводит задачу в READY;
- `optional` — REVIEW запускается только при `available: true`;
- `required` — задача всегда переходит в REVIEW и не достигает READY без положительного вердикта.

## Запуск

Перед первой реальной задачей проверить установку:

```powershell
& .\.codex\skills\onec-pipeline\scripts\Test-PipelineReadiness.ps1
```

Создать задачу:

```powershell
$task = & .\.codex\skills\onec-pipeline\scripts\New-PipelineTask.ps1 `
  -RequestFile .\request.md | ConvertFrom-Json
```

Сохранить архитектуру и независимый вердикт до планирования реализации:

```powershell
& .\.codex\skills\onec-pipeline\scripts\Save-PipelineArchitecture.ps1 `
  -TaskId $task.task_id `
  -ArchitectureFile .\architecture.md `
  -ArchitectId $architectAgentId

& .\.codex\skills\onec-pipeline\scripts\Complete-PipelineArchitectureReview.ps1 `
  -TaskId $task.task_id `
  -Verdict approved `
  -EvidenceFile .\architecture-review.md `
  -ReviewerId $architectureReviewerAgentId
```

Сохранить завершённый план и перейти в WORK:

```powershell
& .\.codex\skills\onec-pipeline\scripts\Save-PipelineDecomposition.ps1 `
  -TaskId $task.task_id `
  -DecompositionFile .\decomposition.json

& .\.codex\skills\onec-pipeline\scripts\Complete-PipelinePlan.ps1 `
  -TaskId $task.task_id `
  -PlanFile .\plan.md `
  -TestPlanFile .\test-plan.md
```

Для `large` и `critical` перед `Complete-PipelinePlan.ps1` Manager фиксирует полученное от пользователя подтверждение:

```powershell
& .\.codex\skills\onec-pipeline\scripts\Approve-PipelinePlan.ps1 `
  -TaskId $task.task_id `
  -PlanFile .\plan.md `
  -TestPlanFile .\test-plan.md
```

Статусы назначенных work items обновляются через `Update-PipelineWorkItem.ps1`; VERIFY не запустится, пока хотя бы один item не завершён.

После выполнения работы запустить обязательный VERIFY:

```powershell
& .\.codex\skills\onec-pipeline\scripts\Invoke-PipelineVerify.ps1 `
  -TaskId $task.task_id
```

Каждая проверка — отдельный скрипт в `.codex/skills/onec-pipeline/scripts/verify-checks/`. `git_diff` работает через Git. `build`, `source_validation` и `tests` используют настроенный `v8-runner`: сборка проекта, проверка модулей Конфигуратором и полный YAxUnit-прогон без повторной сборки. При отсутствии runner или `v8project.yaml` они возвращают явный `not_run`; при `verify.fail_on_not_run: true` (значение по умолчанию) такой результат блокирует READY.

## Проверка MVP

```powershell
& .\.codex\skills\onec-pipeline\tests\Invoke-PipelineMvpTests.ps1
```

Обновление установленного pipeline через `Install-PipelineToProject.ps1 -Force` сохраняет проектный `.pipeline/pipeline.yaml`. Его замена шаблоном поставки выполняется только с дополнительным `-ResetConfiguration`.
