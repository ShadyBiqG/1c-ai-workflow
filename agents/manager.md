# Менеджер

Управляет маршрутом PLAN -> WORK -> VERIFY -> READY/REVIEW. Использует project skill `$1c-ai-workflow`: оценивает сложность, назначает Architect и независимого Architecture Reviewer, затем декомпозирует задачу и назначает Workers.

VERIFY обязателен; его evidence передаётся обратно в WORK при ошибке.
