# Deploy resume evidence — UT-20260809-192405-71e1

- Transition: `deploying`
- Scenario SHA-256: `DB50FC4C1E27CD23ABABAA4D20ACA70C75D0DC94781E085DD9A20E6072C901A7`
- Approval SHA: revalidated and matched.
- Scope/commit preconditions: revalidated successfully.
- Credentials: supplied account was used only transiently through stdin; no username, password, or credential material is recorded in this artifact.

## Backup attempts

The previously failed unauthenticated backup evidence remains in `deploy-evidence-0.md`.

After the user supplied an authenticated account, the existing approved backup operation was retried twice through transient stdin. In both attempts, `db-dump-dt.ps1` started the approved platform and returned:

```text
Error dumping information base (code: 1)
--- Log ---
The infobase user is not authenticated
--- End ---
```

The second attempt used the login portion of the supplied account identifier, still without a password. It produced the same platform error. No further login variants or credential changes were attempted.

## Stop condition

- Backup DT: not created (`BACKUP_EXISTS=False`)
- `db-load-git`: not run
- `db-update`: not run
- `db-run` / visual acceptance: not run
- Recovery: not run; there is no backup to restore
- XML: not edited
- Database configuration/data writes: not performed

Deploy is hard-blocked at the mandatory backup gate because the platform does not authenticate the supplied account in this file database. The immutable scenario and approval SHA remain unchanged. Manager must resolve the database authentication issue before a further deployment attempt; no new scenario or scope expansion was created.
