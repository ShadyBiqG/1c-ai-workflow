---
name: onec-pipeline
description: Run the persistent Manager, Plan, Work, and Deploy workflow for this 1C project. Use for task intake, role routing, review loops, context compaction, pipeline recovery, or scenario-gated deployment. Manager must use it for every pipeline task; other roles use their assigned contracts and return results only to Manager.
---

# 1C Agentic Pipeline

Read `AGENTS.md`, `.pipeline/roles/<role>.md`, and the current task artifacts before acting.

## Invariants

- Reuse the registered Controller, Manager, Plan, Work, and Deploy tasks and one registered Claude session.
- Keep all five Codex tasks unpinned and assigned to the saved project in the local registry. An archive handoff is incomplete until Codex App restores the original project assignment.
- Only Controller performs boundary maintenance. Before archiving, it must run `Get-PipelineBoundaryManifest.ps1` with its own registered ID. The validated targets never include Controller.
- Only Manager sends role transitions.
- Before every new task, require verified compaction for all five sessions.
- For Codex Desktop tasks, Manager returns `BOUNDARY_REQUIRED` after intake and ends its turn. The registered Controller uses Codex App to archive the four product roles, runs the hidden phase-one helper, then uses Codex App to restore them under the original saved project and supplies a project snapshot to `Complete-PipelineBoundary.ps1`. This is a writer-lock handoff, never task replacement.
- Send the completion script's exact `TASK_READY` message to the registered Manager with the Codex App thread tool, wait for completion, read the Manager task independently with the Codex App thread tool, save that task-scoped read receipt, then call `Confirm-PipelineTaskReady.ps1 -ThreadReadFile <path>`. Send its exact `routing_release_message` back to Manager; only that second turn releases Plan routing. Planning is forbidden while state is `task_ready_pending`.
- Re-running a boundary reuses validated per-role and Opus receipts. Recover `blocked` only through `Resume-PipelineBoundary.ps1`, which records explicit approval provenance.
- Keep complete results in `.pipeline/tasks/<task-id>/`; send compact envelopes with artifact paths.
- Loop Plan review and Work without a limit until `approved`.
- Require an approval artifact bound to the exact deploy scenario hash before any database write.
- Never create a replacement task or session without explicit user approval.

Use scripts in `scripts/` for deterministic state, Codex App Server compaction, and the deferred task boundary. Use `claude-consilium` for Opus consultations and compaction.

Read `.pipeline/references/message-contracts.md` before routing and [references/state-machine.md](references/state-machine.md) when changing or recovering task state.
