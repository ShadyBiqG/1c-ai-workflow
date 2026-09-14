# Final deploy evidence — UT-20260809-192405-71e1

- Commit: `cccdd19496d17c38607ee8cb52ed32edb4f3a2eb`
- Scenario SHA-256: `DB50FC4C1E27CD23ABABAA4D20ACA70C75D0DC94781E085DD9A20E6072C901A7`
- Approval SHA: revalidated unchanged and matched.
- XML source: not edited by Deploy.
- Prior failed backup evidence: preserved in `deploy-evidence-0.md` and `deploy-evidence-1.md`.

## Executed deployment

1. Preconditions passed: exact commit scope, checkout target, platform, file database, and approval SHA.
2. Full DT backup completed successfully.
   - Path: `C:\dev\bases1c\backups\ut11_8_5-UT-20260809-192405-71e1-predeploy.dt`
   - Size: `854538310` bytes
   - SHA-256: `B34AD7B80808A26835AE19ED6D47E617FD4B3FBA124636FCA0BB545ED21664C1`
3. Exact commit load completed successfully.
   - `db-load-git` reported `Files for loading: 1`.
   - Selected file: `Documents/РеализацияТоваровУслуг/Forms/ФормаДокумента/Ext/Form.xml`
   - Final platform result: `Load completed successfully`.
4. Database configuration update completed successfully.
   - Final platform result: `Database configuration updated successfully`.
   - Log result: `Configuration successfully updated`.
5. 1C:Enterprise client launched successfully.
   - PID: `23140`
   - Window title: `Демонстрационная база / Управление торговлей, редакция 11`

## Acceptance status

The client launch was verified, but this environment has no UI-control/navigation capability for opening the new and existing documents and performing the four approved visual/functional scenarios. A desktop screenshot did not expose the 1C window, so the following are intentionally not claimed as verified:

- pink backgrounds on all four pages and status/footer groups;
- preservation of semantic selection and totals colors;
- existing-document save/post behavior;
- new-document save/post behavior and full navigation checks.

No recovery was required: backup, load, and update all succeeded. The deployment writes completed; visual/functional acceptance remains pending a human or UI-capable operator.
