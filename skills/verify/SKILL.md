---
name: verify
description: Проверка результатов разработки 1С перед приемкой.
---

# Проверка

Обязательный технический gate запускается командой:

```powershell
& .\.codex\skills\onec-pipeline\scripts\Invoke-PipelineVerify.ps1 -TaskId <task-id>
```

Нельзя переводить WORK напрямую в REVIEW или READY. При `failed` прочитать `.pipeline/tasks/<task-id>/verify-evidence.json`, исправить проблему в WORK и повторить VERIFY.
