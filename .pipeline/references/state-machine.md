# State machine локального development pipeline

Основной маршрут:

```text
plan -> work -> verify -> ready
```

При включённом Deploy конечная часть маршрута меняется:

```text
verify -> [review] -> deploy_pending -> deploy -> ready
                                      deploy_failed
```

`deploy_pending -> deploy` возможен только после явного подтверждения пользователя, связанного с SHA-256 неизменного сценария. `deploy_failed` не повторяется автоматически.

Внутренний маршрут PLAN:

```text
manager -> architect -> architecture_reviewer -> manager
                ^                  |
                +-- changes -------+
```

Только вердикт `approved` для актуального SHA-256 `architecture.md`, выданный другим агентом, открывает Manager переход к завершению PLAN. `changes_requested` возвращает решение Architect без перехода в WORK.

Ошибка обязательного VERIFY:

```text
work -> verify -> verify_failed -> work
```

Маршрут с REVIEW:

```text
work -> verify -> review -> ready
                      |
                      +-> work
```

После успешного VERIFY:

- `review.mode: disabled` — `ready`;
- `review.mode: optional` и reviewer недоступен — `ready`;
- `review.mode: optional` и reviewer доступен — `review`;
- `review.mode: required` — всегда `review`, даже если reviewer сейчас недоступен.

Последний вариант намеренно оставляет задачу ожидающей обязательного REVIEW и не позволяет тихо перейти в `ready`.

## Контроль участия пользователя

Подтверждение плана не добавляет отдельное состояние и не меняет основной маршрут. Для уровней сложности из `manager.plan_approval_for` переход `plan -> work` разрешён только при наличии `plan-approval.json`, хеши которого совпадают с текущими `plan.md`, `test-plan.md` и `decomposition.json`.

Одобрение плана не разрешает deploy, публикацию, внешнюю запись или другое необратимое действие. Для них Manager получает отдельное актуальное подтверждение непосредственно перед действием и фиксирует его в журнале задачи.
