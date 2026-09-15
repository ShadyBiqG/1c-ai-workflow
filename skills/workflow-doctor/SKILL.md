---
name: workflow-doctor
description: Диагностика настройки и состояния рабочего процесса разработки 1С.
---

# Диагностика рабочего процесса

Проверить:

- читается ли `.pipeline/pipeline.yaml`;
- существует ли `.pipeline/tasks/<task-id>/state.json`;
- соответствует ли текущее состояние допустимому переходу;
- доступен ли Git;
- проходят ли PowerShell syntax validation и smoke-тест `onec-pipeline`.
