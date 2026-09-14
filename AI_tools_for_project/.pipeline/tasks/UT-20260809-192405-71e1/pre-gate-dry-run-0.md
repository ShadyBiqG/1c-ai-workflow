# Pre-gate dry-run evidence — UT-20260809-192405-71e1

- Transition: `pre_gate_dry_run`
- Commit: `cccdd19496d17c38607ee8cb52ed32edb4f3a2eb`
- Scenario: `.pipeline/tasks/UT-20260809-192405-71e1/deploy-scenario.md`
- Scenario SHA-256: `DB50FC4C1E27CD23ABABAA4D20ACA70C75D0DC94781E085DD9A20E6072C901A7`
- Scenario SHA-256 validation: `VALID` — recomputed from the scenario and matched `.pipeline/tasks/UT-20260809-192405-71e1/deploy-scenario.sha256`.
- Database target: `C:\dev\bases1c\ut11_8_5`
- Database writes: none
- 1C launch: none
- Backup: not created
- Database update: not performed

## Exact executed command

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\git\rMyProjects\UT_demo_for_AI\.codex\skills\db-load-git\scripts\db-load-git.ps1" -InfoBasePath "C:\dev\bases1c\ut11_8_5" -ConfigDir "C:\git\rMyProjects\UT_demo_for_AI" -Source Commit -CommitRange "cccdd19496d17c38607ee8cb52ed32edb4f3a2eb^..cccdd19496d17c38607ee8cb52ed32edb4f3a2eb" -DryRun
```

## Result

- Exit code: `0`
- Selected files: exactly `1`
- Selected file: `Documents/РеализацияТоваровУслуг/Forms/ФормаДокумента/Ext/Form.xml`
- Dry-run status: `no changes applied`

## Captured stdout

```text
Getting changes from cccdd19496d17c38607ee8cb52ed32edb4f3a2eb^..cccdd19496d17c38607ee8cb52ed32edb4f3a2eb...
Git changes detected: 1 files
Files for loading: 1
  Documents/РеализацияТоваровУслуг/Forms/ФормаДокумента/Ext/Form.xml

DryRun mode - no changes applied
```

## Captured stderr

```text
(empty)
```

No backup, configuration load, update, client start, or database write was executed. Pipeline state was not modified by this evidence capture.
