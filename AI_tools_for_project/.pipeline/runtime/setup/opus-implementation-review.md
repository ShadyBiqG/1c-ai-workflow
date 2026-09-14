Review the current uncommitted implementation changes against:

- docs/superpowers/specs/2026-08-09-onec-agentic-pipeline-design.md
- .pipeline/roles/manager.md
- .pipeline/references/message-contracts.md
- .codex/skills/onec-pipeline/SKILL.md

Read `.pipeline/runtime/setup/implementation-review.diff`, which contains the prepared Git diff. Use only the Read tool on that file and on the four contract files listed above. Do not use Bash, PowerShell, Glob, Grep, Task, web tools, or any other tool. Do not modify files or run 1C. Focus on correctness and reliability of:

1. Codex Desktop writer-lock handoff and two-phase project restoration.
2. The invariant that Manager, Plan, Work, and Deploy remain unpinned under the original saved project with the same IDs and titles.
3. Windows-safe transport and process cleanup.
4. Intake idempotency under duplicated or delayed follow-ups.
5. State transitions and failure recovery.

Return findings ordered by severity with file/line references. If there are no blocking findings, say APPROVED and list residual risks separately. Complete the response directly after reading; do not perform additional repository discovery.
