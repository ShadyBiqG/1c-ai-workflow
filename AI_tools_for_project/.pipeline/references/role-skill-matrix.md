# Role Skill Matrix

## Common

All roles begin with `superpowers:using-superpowers`. Only Manager routes role transitions.

## Controller

Allowed: task intake transport, boundary manifest validation, Codex App archive/restore, deterministic compaction transport, task/project snapshots, Manager delivery confirmation.
Prohibited: targeting itself; product routing; Plan, Work, Deploy, 1C edit/deploy skills; engineering consultations; deploy approval.

## Manager

Allowed: pipeline state, Git metadata, Codex task send/wait for product routing after `TASK_READY`.
Prohibited: boundary archive/restore/compaction, 1C edit/deploy skills, and engineering consultations with Opus.

## Plan and Reviewer

Allowed read-only 1C skills as needed:

- `cf-info`, `cfe-diff`, `meta-info`, `form-info`, `form-patterns`;
- `subsystem-info`, `role-info`, `skd-info`, `mxl-info`, `xdto-info`;
- `db-list`, `web-info`, `img-grid`;
- `meta-decompile`, `form-decompile`, `skd-decompile`, `mxl-decompile`, `xdto-decompile` when analysis requires their structured representation.

Typical Superpowers chain: `brainstorming -> writing-plans -> claude-consilium`.
Prohibited: edit, compile, remove, database load/update, run, publish, or other mutation skills.

## Work

Required pattern: `info/decompile -> edit/compile/add/remove -> matching validate -> tests`.

Allowed families:

- `cf-edit`, `cf-validate`;
- `cfe-borrow`, `cfe-init`, `cfe-patch-method`, `cfe-validate`;
- `meta-*`, `form-*`, `subsystem-*`, `interface-*`, `role-*`, `skd-*`, `mxl-*`, `xdto-*` within source-edit scope;
- `epf-*`, `erf-*`, `template-*`, `help-add`;
- `support-edit` only when the committed plan explicitly requires it.

Required Superpowers: `executing-plans`, `test-driven-development`, `systematic-debugging` on unexpected behavior, `receiving-code-review`, `verification-before-completion`.
Prohibited: `db-load-*`, `db-update`, `db-run`, `web-publish`, and writes to the information database.

## Deploy

Allowed after dry-run and, for writes, a valid scenario approval:

- `db-list`, `db-load-git`, `db-update`, `db-run`;
- `db-dump-dt` or `db-dump-cf` when the scenario includes backup;
- validators and `web-info`, `web-publish`, `web-test`, `web-stop`, `web-unpublish` within the approved scenario.

Required Superpowers: `executing-plans`, `systematic-debugging` on failure, `verification-before-completion`.
Prohibited: editing source XML or expanding the approved scenario implicitly.
