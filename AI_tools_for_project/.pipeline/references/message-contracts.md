# Pipeline Message Contracts

Messages between Codex tasks are compact envelopes. Complete content remains in `.pipeline/tasks/<task-id>/`.

## Envelope

```json
{
  "protocol_version": 1,
  "task_id": "UT-20260809-123456-a1b2",
  "transition": "plan_requested",
  "summary": "Context needed by the receiving role to begin.",
  "artifact_paths": [".pipeline/tasks/UT-.../request.md"],
  "commit": null,
  "round": 0,
  "correlation_id": "UT-...:plan_requested:0"
}
```

`summary` is selected by Manager from the Plan context. Do not paste full plans, diffs, reviews, schemas, or raw logs into messages.

## Legal Transitions

`intake -> compacting -> task_ready_pending -> plan_requested -> planned -> work_requested -> review_requested`

From `review_requested`:

- `changes_requested -> work_requested`, without a round limit;
- `approved -> deploy_dry_run -> awaiting_human -> deploying -> completed`.

Only Manager sends transition envelopes. A repeated `correlation_id` is an idempotent no-op.

Every intake includes a stable `intake_correlation_id`. The intake script stores it with the SHA-256 of normalized UTF-8 request text; a repeated delivery reuses the existing task ID and reports its current state, while changed content under the same key is rejected. Manager then returns `BOUNDARY_REQUIRED <task-id>` to the registered Controller and ends its turn. This is maintenance control, not a product transition. Controller validates its caller ID and four-role target manifest before any archive. It may send the persisted `TASK_READY` only after `compaction.json` contains four Codex receipts, one Opus receipt, and a validated unpinned project snapshot for the registered `project_id`. Completion leaves `task_ready_pending`; Controller must then read the Manager task through Codex App and save a fresh task-scoped read receipt. Only an independently observed completed turn containing the exact persisted message advances to `plan_requested`. Confirmation returns a deterministic `ROUTING_RELEASED <task-id>` message; Controller sends it in a second Manager turn, and Manager routes Plan only after validating `plan_requested`.

## Project Restore Snapshot

Build this file from Codex App `list_threads` after App-unarchive. Do not infer membership from cwd or title alone.

```json
{
  "protocol_version": 1,
  "task_id": "UT-20260809-123456-a1b2",
  "captured_at": "2026-08-09T12:36:00Z",
  "project_id": "local-project-id",
  "roles": [
    { "role": "manager", "thread_id": "...", "title": "Manager", "project_id": "local-project-id", "pinned": false, "archived": false },
    { "role": "plan", "thread_id": "...", "title": "Plan", "project_id": "local-project-id", "pinned": false, "archived": false },
    { "role": "work", "thread_id": "...", "title": "Work", "project_id": "local-project-id", "pinned": false, "archived": false },
    { "role": "deploy", "thread_id": "...", "title": "Deploy", "project_id": "local-project-id", "pinned": false, "archived": false }
  ]
}
```

The registry is scoped by `project_id`. Another project owns different task IDs even when it uses the same five titles: Controller, Manager, Plan, Work, and Deploy.

The snapshot must be captured after phase-one completion. Every role entry must explicitly include `project_id`, `pinned`, and `archived`; missing fields fail closed. On boundary failure, use the audited recovery script and resume existing per-role receipts rather than replacing or recompacting successful sessions.

## Review Verdict

```json
{
  "verdict": "changes_requested",
  "round": 1,
  "findings": [],
  "opus_artifact": ".pipeline/tasks/UT-.../opus-review-1.json",
  "reconciliation": [
    { "finding": "...", "decision": "accepted", "rationale": "..." }
  ]
}
```

The only verdict values are `changes_requested` and `approved`.
