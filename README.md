# 1C AI Workflow

Локальный persisted pipeline для разработки 1С: PLAN → WORK → обязательный VERIFY → опциональный REVIEW → безопасный DEPLOY → READY. Manager хранит состояние и evidence в `.pipeline/tasks/<task-id>/`, поэтому работу можно продолжать в новом чате без опоры на память модели.

## Состав репозитория

- `.codex/skills/1c-ai-workflow/` — навык Manager и контракты ролей;
- `.codex/skills/onec-pipeline/` — state machine, команды, VERIFY adapters и Pester-тесты;
- `.pipeline/` — устанавливаемые конфигурация, роли, шаблон `AGENTS.md` и справочные контракты;
- `scripts/` — инсталляторы навыка и pipeline;
- `.github/workflows/` — CI для PSScriptAnalyzer и Pester;
- `PSScriptAnalyzerSettings.psd1` — документированные исключения анализатора.

Все перечисленные runtime-каталоги копируются `Install-PipelineToProject.ps1`, кроме `.github/` и настроек анализатора: они обслуживают только этот репозиторий.

## Быстрый старт

Требуются Windows PowerShell 5.1 или PowerShell 7, Git и Pester 5. Для реальных VERIFY-проверок дополнительно настраиваются v8-runner и, при использовании `bsl_lint`, BSL Language Server.

```powershell
Install-Module Pester -MinimumVersion 5.7.1 -Scope CurrentUser
& .\.codex\skills\onec-pipeline\tests\Invoke-PipelineMvpTests.ps1
& .\scripts\Install-PipelineToProject.ps1 -TargetProject 'F:\Work\my-1c-project'
```

Инсталлятор создаёт `AGENTS.md` только при его отсутствии, пишет `.pipeline/installed.json` и никогда не заменяет существующий `AGENTS.md`, в том числе с `-Force -ResetConfiguration`. Предварительный просмотр не меняет файлов:

```powershell
& .\scripts\Install-PipelineToProject.ps1 -TargetProject 'F:\Work\my-1c-project' -WhatIf
```

После настройки `verify.runner_path` и наличия `v8project.yaml`:

```powershell
& .\.codex\skills\onec-pipeline\scripts\Test-PipelineReadiness.ps1
$task = & .\.codex\skills\onec-pipeline\scripts\New-PipelineTask.ps1 -RequestFile .\request.md | ConvertFrom-Json
```

Полный порядок команд для архитектуры, decomposition, WORK и VERIFY описан в [INSTALL.md](INSTALL.md).

## Конфигурация

Настройки хранятся в `.pipeline/pipeline.json` и читаются встроенным `ConvertFrom-Json`. Старый `pipeline.yaml` при обновлении распознаётся как прежняя установка: инсталлятор создаёт актуальный JSON и оставляет YAML как резервную копию.

Основные ключи:

| Ключ | По умолчанию | Допустимые значения |
|---|---:|---|
| `agents.allowed_models` | три модели поставки | непустой массив строк |
| `manager.max_parallel_workers` | `3` | `1..8` |
| `verify.fail_on_unexpected_paths` | `true` | boolean |
| `verify.depends_on` | `source_validation/tests → build` | ациклический map проверок |
| `verify.timeout_seconds` | `1800` | `60..14400` |
| `verify.timeout_overrides` | `{}` | map проверки в `60..14400` |
| `verify.bsl_ls_path` | `null` | путь или поиск в `PATH` |
| `verify.bsl_ls_config` | `.bsl-language-server.json` | путь от корня проекта или абсолютный |
| `verify.bsl_lint_max_issues` | `0` | целое `>= 0` |
| `verify.tests_scope` | `impacted` | `impacted`, `all` |

`git_diff` проваливает VERIFY при пустом diff. При обязательной decomposition он сопоставляет изменения с `paths` завершённых work items; неожиданные пути либо блокируют задачу, либо сохраняются как предупреждение в зависимости от `fail_on_unexpected_paths`.

VERIFY сохраняет полный stdout/stderr каждой запущенной проверки в `.pipeline/tasks/<task-id>/verify-logs/<run-id>/`, а в evidence — `log_path`, `duration_ms`, краткий tail и статусы `passed`, `failed`, `not_run` или `skipped`. Непройденная зависимость даёт `skipped` и блокирует READY.

## Проверка качества

```powershell
Install-Module PSScriptAnalyzer -MinimumVersion 1.24.0 -Scope CurrentUser
Invoke-ScriptAnalyzer -Path .\scripts -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path .\.codex\skills\onec-pipeline -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
& .\.codex\skills\onec-pipeline\tests\Invoke-PipelineMvpTests.ps1
```

Pester формирует `TestResults/pester-nunit.xml`; CI запускает обе проверки на каждый push и публикует NUnit-отчёт.
