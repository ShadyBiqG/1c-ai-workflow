# Установка

Требования MVP:

- Windows PowerShell 5.1 или PowerShell 7;
- Git в `PATH`;
- Codex App для orchestration ролей.

Клонируйте репозиторий и выполните smoke-тест:

```powershell
& .\.codex\skills\onec-pipeline\tests\Invoke-PipelineMvpTests.ps1
```

VERIFY-адаптеры используют `v8-runner`, когда в `verify.runner_path` задан путь к исполняемому файлу либо `v8-runner.exe` доступен через `PATH`. Относительный `verify.runner_config` разрешается от корня целевого проекта. Если runner или его конфигурация не найдены, evidence явно получает `not_run`, а VERIFY по умолчанию завершается ошибкой (`verify.fail_on_not_run: true`).

## Глобальный навык

Чтобы `$1c-ai-workflow` был доступен во всех новых чатах Codex, установите его в пользовательский каталог:

```powershell
& .\scripts\Install-WorkflowSkill.ps1
```

Для обновления уже установленной копии:

```powershell
& .\scripts\Install-WorkflowSkill.ps1 -Force
```

После установки откройте новый чат Codex. Если навык не появился в списке, перезапустите Codex App.

## Установка pipeline в рабочий проект

Глобальный навык содержит поведение Manager, а state machine и артефакты устанавливаются в каждый рабочий репозиторий отдельно:

```powershell
& .\scripts\Install-PipelineToProject.ps1 -TargetProject 'F:\Work\my-1c-project'
```

Обновление существующей установки:

```powershell
& .\scripts\Install-PipelineToProject.ps1 -TargetProject 'F:\Work\my-1c-project' -Force
```

При обновлении существующий `.pipeline/pipeline.yaml` сохраняется: локальные пути, REVIEW и Deploy не сбрасываются. Чтобы осознанно заменить конфигурацию значениями из поставки, добавьте `-ResetConfiguration` вместе с `-Force`.

Deploy после установки выключен. Для проекта с `v8project.yaml` задайте `verify.runner_path`; стандартный VERIFY выполняет Git-проверку, сборку, проверку модулей Конфигуратором и полный YAxUnit-прогон. Adapter конкретной тестовой базы для Deploy настраивается отдельно.
