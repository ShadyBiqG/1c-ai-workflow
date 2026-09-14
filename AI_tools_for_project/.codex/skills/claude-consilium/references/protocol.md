# Claude Consilium Protocol

## Registry

Local ignored path: `.pipeline/local/claude-session.json`.

Fields: `protocol_version`, `session_id`, `model`, `effort`, `updated_at`.

## Transport

The wrapper resolves the newest semver bundled CLI under `%APPDATA%\Claude\claude-code`, then fixed fallbacks. Prompt text is read from a file or generated for compact and written directly to redirected stdin. Stdout/stderr are written beside the requested receipt.

## Success

All actions require exit code 0, valid JSONL, and an event carrying the registered session ID. `Compact` additionally requires `system/compact_boundary`. A missing session, mismatched ID, malformed event, timeout, or unsupported profile is a hard failure; do not create a replacement.

## Permissions

Plan may use `Ask` for draft planning and review. The deterministic boundary controller may use only `Compact` and `Status`. Other roles need an explicit role-policy change before using `Ask`.
