---
name: claude-consilium
description: Call a persistent Claude Code session as a second opinion through Windows-safe UTF-8 stdin and file transport. Use automatically from the Plan task for every draft plan and implementation review, and use at new-task boundaries to compact the registered Claude session. Also use when a Codex task explicitly needs a permitted Claude model consultation without placing context in command-line arguments.
---

# Claude Consilium

Use `scripts/Invoke-ClaudeConsilium.ps1`. Keep prompts and artifacts in UTF-8 files; pass only short validated flags and paths.

## Actions

- `Initialize`: create the one approved persistent session and registry. Refuse when a registry exists.
- `Ask`: resume the registered session with `-InputFile` and save a receipt with `-OutputFile`.
- `Compact`: resume the same session, send focused `/compact`, and require `compact_boundary`.
- `Status`: read the local registry without calling the model.

Default to `-Model opus -Effort high`. Never replace a missing or invalid session automatically. Do not verify the canonical model name on each call.

Read [references/protocol.md](references/protocol.md) when constructing pipeline artifacts or diagnosing a receipt.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .codex\skills\claude-consilium\scripts\Invoke-ClaudeConsilium.ps1 `
  -Action Ask -InputFile .pipeline\tasks\UT-...\opus-input.md `
  -OutputFile .pipeline\tasks\UT-...\opus-plan-review.json
```
