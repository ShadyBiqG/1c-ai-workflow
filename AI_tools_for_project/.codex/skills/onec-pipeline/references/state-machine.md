# Pipeline State Machine

## Task Boundary

`intake -> compacting -> task_ready_pending -> plan_requested`

Boundary success requires four Codex `contextCompaction` receipts and one verified Claude outcome (`compacted`, or `not_needed` for an insufficiently populated fresh session). The registered Controller first validates a manifest that excludes itself, then archives Manager, Plan, Work, and Deploy. Phase one CLI-unarchives, compacts, and CLI-rearchives those same four IDs. Controller then uses Codex App to restore every role under the original saved `project_id`; roles stay unpinned. `Complete-PipelineBoundary.ps1` validates a fresh task-scoped snapshot, compacts Opus, persists the exact `TASK_READY` message and stops in `task_ready_pending`. Only `Confirm-PipelineTaskReady.ps1`, supplied with the completed Manager turn receipt and message hash, advances to `plan_requested`.

Each Codex role receipt is persisted immediately. Re-running phase one skips validated role receipts and a complete `codex-phase1.json`; completion likewise reuses a validated Opus receipt and pending message. A failure produces `compacting -> blocked`, preserves the registered IDs, and never creates a replacement. Recovery is explicit: `Resume-PipelineBoundary.ps1 -ApprovedBy <identity>` records an audit artifact and performs `blocked -> compacting`, after which only missing work is resumed.

## Delivery

`plan_requested -> planned -> work_requested -> review_requested`

Review branches:

- `review_requested -> changes_requested -> work_requested`, without a round limit;
- `review_requested -> approved -> deploy_dry_run -> awaiting_human`.

Deployment continues only with an approval whose SHA-256 matches the unchanged scenario:

`awaiting_human -> deploying -> completed`

## Recovery

Every transition carries a unique `correlation_id`. Repeating an applied correlation is a no-op. A timeout means inspect the same registered task/session and its artifacts; it is not permission to create another chat.
