# Deploy evidence — UT-20260809-192405-71e1

- Transition: `deploying`
- Commit: `cccdd19496d17c38607ee8cb52ed32edb4f3a2eb`
- Scenario SHA-256: `DB50FC4C1E27CD23ABABAA4D20ACA70C75D0DC94781E085DD9A20E6072C901A7`
- Approval SHA: matched the scenario SHA before execution.
- Target database: `C:\dev\bases1c\ut11_8_5`
- Target platform: `C:\Program Files\1cv8\8.5.1.1302\bin`

## Preconditions

Passed after correcting Git path quoting with `-c core.quotePath=false`:

- exact commit exists;
- commit scope is exactly one modification of `Documents/РеализацияТоваровУслуг/Forms/ФормаДокумента/Ext/Form.xml`;
- checkout target file equals the approved commit;
- target file database and approved platform executable exist;
- approval SHA matches the unchanged scenario.

## Executed actions

1. Initial backup attempt was blocked before 1C started because the sandbox denied creation of `C:\dev\bases1c\backups`.
2. The same approved backup operation was retried with elevated filesystem permission.
3. `db-dump-dt.ps1` started `1cv8.exe` and failed with exit code `1`:

```text
Running: 1cv8.exe DESIGNER /F "C:\dev\bases1c\ut11_8_5" /DumpIB "C:\dev\bases1c\backups\ut11_8_5-UT-20260809-192405-71e1-predeploy.dt" /Out "C:\Users\benon\AppData\Local\Temp\db_dump_dt_1843835318\dump_dt_log.txt" /DisableStartupDialogs
Error dumping information base (code: 1)
--- Log ---
The infobase user is not authenticated
--- End ---
```

## Root cause and stop decision

The backup operation requires an authenticated infobase user. `.v8-project.json` registers the file database without `user` or `password`, and the platform reported `The infobase user is not authenticated`. The backup file does not exist (`BACKUP_EXISTS=False`).

Per the immutable scenario, backup failure is a hard stop. `db-load-git`, `db-update`, `db-run`, visual acceptance, and recovery were not executed. No configuration load or database update was attempted. Recovery was impossible because no pre-deploy DT was created. Pipeline state was not modified by this evidence capture.

## Evidence status

- Status: `blocked_before_deploy`
- Backup: failed, no DT created
- Load: not run
- Update: not run
- Client/visual acceptance: not run
- Recovery: not run; no backup available
- Required Manager action: provide/authorize authenticated database access or an approved credential configuration, then rerun the unchanged approved scenario from the backup step.
