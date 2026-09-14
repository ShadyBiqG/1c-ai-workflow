# Deploy dry-run scenario — UT-20260809-192405-71e1

## Gate and identity

- Scenario purpose: deploy and visually accept the approved pink styling of the main form of `Document.РеализацияТоваровУслуг`.
- Implementation commit: `cccdd19496d17c38607ee8cb52ed32edb4f3a2eb`.
- Approved review: `.pipeline/tasks/UT-20260809-192405-71e1/review-0.json`, verdict `approved`, round `0`.
- Target source checkout: `C:\git\rMyProjects\UT_demo_for_AI`.
- Target database: registered id `ut`, file database `C:\dev\bases1c\ut11_8_5`.
- Target platform: `C:\Program Files\1cv8\8.5.1.1302\bin` from `.v8-project.json`.
- Scope: main configuration only; the sole expected product change is `Documents/РеализацияТоваровУслуг/Forms/ФормаДокумента/Ext/Form.xml`.
- Approval rule: this scenario is read-only until Manager supplies a human approval artifact containing the SHA-256 of this exact unchanged file. No database write, `db-load-git`, `db-update`, `db-run`, backup, or restore is executed by this dry-run preparation.

## Preconditions and stop conditions

Run these checks immediately before any approved execution. A non-zero result is a hard stop.

```powershell
$ErrorActionPreference = 'Stop'
$repo = 'C:\git\rMyProjects\UT_demo_for_AI'
$commit = 'cccdd19496d17c38607ee8cb52ed32edb4f3a2eb'
$target = 'Documents/РеализацияТоваровУслуг/Forms/ФормаДокумента/Ext/Form.xml'
$db = 'C:\dev\bases1c\ut11_8_5'
$v8 = 'C:\Program Files\1cv8\8.5.1.1302\bin'

Set-Location $repo
if ((git rev-parse "$commit^{commit}") -ne $commit) { throw 'Exact implementation commit is unavailable' }
if ((git diff-tree --no-commit-id --name-status -r $commit) -ne "M`t$target") { throw 'Commit scope is not exactly the approved Form.xml' }
if (git diff --quiet $commit -- $target) { } else { throw 'Checkout Form.xml differs from the approved commit; do not deploy' }
if (-not (Test-Path (Join-Path $db '1Cv8.1CD'))) { throw 'Target file database is unavailable' }
if (-not (Test-Path (Join-Path $v8 '1cv8.exe'))) { throw 'Approved 1C platform executable is unavailable' }
```

The pre-existing dirty working tree is not a reason to broaden scope, but any difference in the target file, commit identity, database path, or platform path is a hard stop. Do not clean, reset, stash, or revert unrelated user changes.

## Phase 0 — read-only deploy dry-run

This is the only phase performed while preparing this artifact. It must not start 1C or touch the database.

```powershell
$repo = 'C:\git\rMyProjects\UT_demo_for_AI'
$commit = 'cccdd19496d17c38607ee8cb52ed32edb4f3a2eb'
$targetDb = 'C:\dev\bases1c\ut11_8_5'
$configDir = 'C:\git\rMyProjects\UT_demo_for_AI'
Set-Location $repo

powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.codex\skills\db-load-git\scripts\db-load-git.ps1' `
  -InfoBasePath $targetDb -ConfigDir $configDir -Source Commit `
  -CommitRange "$commit^..$commit" -DryRun
```

Expected dry-run result: exactly one loadable XML file, `Documents/РеализацияТоваровУслуг/Forms/ФормаДокумента/Ext/Form.xml`; no extension is selected and no `-UpdateDB` is used. Any other file, zero files, a source/commit error, or an unexpected warning that prevents exact scope is a hard stop and return to Manager.

## Phase 1 — approved execution order

Execute only after the human approval artifact matches this scenario SHA-256 and after rerunning all preconditions unchanged.

### 1. Backup

Use a full DT backup before the first database write. The planned output is outside the repository:

```powershell
$backup = 'C:\dev\bases1c\backups\ut11_8_5-UT-20260809-192405-71e1-predeploy.dt'
New-Item -ItemType Directory -Path (Split-Path $backup) -Force | Out-Null
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.codex\skills\db-dump-dt\scripts\db-dump-dt.ps1' `
  -V8Path 'C:\Program Files\1cv8\8.5.1.1302\bin' `
  -InfoBasePath 'C:\dev\bases1c\ut11_8_5' -OutputFile $backup
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $backup)) { throw 'Backup failed; stop without loading or updating the database' }
```

Record the backup path, file size, SHA-256, timestamp, and command output in the task evidence. A backup failure is a hard stop.

### 2. Load the exact Git change

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.codex\skills\db-load-git\scripts\db-load-git.ps1' `
  -V8Path 'C:\Program Files\1cv8\8.5.1.1302\bin' `
  -InfoBasePath 'C:\dev\bases1c\ut11_8_5' `
  -ConfigDir 'C:\git\rMyProjects\UT_demo_for_AI' `
  -Source Commit -CommitRange 'cccdd19496d17c38607ee8cb52ed32edb4f3a2eb^..cccdd19496d17c38607ee8cb52ed32edb4f3a2eb'
if ($LASTEXITCODE -ne 0) { throw 'Git load failed; stop and restore the pre-deploy backup' }
```

Expected write: only the seven `BackColor` properties in the approved main form. No extension load is permitted.

### 3. Update the database configuration

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.codex\skills\db-update\scripts\db-update.ps1' `
  -V8Path 'C:\Program Files\1cv8\8.5.1.1302\bin' `
  -InfoBasePath 'C:\dev\bases1c\ut11_8_5'
if ($LASTEXITCODE -ne 0) { throw 'Database configuration update failed; stop and restore the pre-deploy backup' }
```

Expected result: database configuration update completes for the main configuration. No source files are edited by Deploy.

### 4. Visual and functional acceptance

Start the client only after steps 1–3 succeed:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.codex\skills\db-run\scripts\db-run.ps1' `
  -V8Path 'C:\Program Files\1cv8\8.5.1.1302\bin' `
  -InfoBasePath 'C:\dev\bases1c\ut11_8_5'
```

Manually verify and record evidence for:

1. A new realization: pages `Основное`, `Товары`, `Доставка`, and `Дополнительно` show light-pink free container areas; status and lower groups show the stronger pink background.
2. An existing realization: values, visibility, availability, commands, tab navigation, save, and posting remain functional.
3. Semantic colors remain distinct: `style:ЦветФонаВыделения` on `Основное` and `style:ИтогиФон` in the footer are still present and visually distinguishable.
4. System colors of fields, tables, and tab headers are not treated as failures; acceptance concerns the seven approved containers.

Do not create or modify test business data unless the human approval explicitly includes those exact records. If any visual or functional check fails, stop and restore; do not continue testing or make compensating edits.

## Recovery on any failure

After backup creation, any failure in load, update, startup, visual acceptance, save, or posting stops the remaining scenario. Close 1C sessions, preserve logs/screenshots, and restore the exact pre-deploy DT:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.codex\skills\db-load-dt\scripts\db-load-dt.ps1' `
  -V8Path 'C:\Program Files\1cv8\8.5.1.1302\bin' `
  -InfoBasePath 'C:\dev\bases1c\ut11_8_5' `
  -InputFile 'C:\dev\bases1c\backups\ut11_8_5-UT-20260809-192405-71e1-predeploy.dt'
if ($LASTEXITCODE -ne 0) { throw 'Recovery failed; stop and escalate to Manager without retrying writes' }
```

After successful restore, verify that the restore completed and report the original failure, recovery output, backup hash, and remaining uncertainty to Manager. Never retry a failed write or create a new Deploy task in this scenario.

## Evidence and completion gate

Store command output, backup metadata, load/update exit codes, screenshots or equivalent visual evidence, and recovery evidence under `.pipeline/tasks/UT-20260809-192405-71e1/` without changing the approved scenario file. Completion requires all four acceptance checks, no unapproved writes, and a final report to Manager. The scenario remains valid only while its SHA-256 is unchanged.
