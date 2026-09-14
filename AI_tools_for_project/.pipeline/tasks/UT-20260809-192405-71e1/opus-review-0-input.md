# Second opinion: review commit cccdd1949

## Task and role

Review only; do not modify files. Task `UT-20260809-192405-71e1`, round 0. The approved plan is `.pipeline/tasks/UT-20260809-192405-71e1/plan.md`. Work commit is `cccdd19496d17c38607ee8cb52ed32edb4f3a2eb`.

Required verdict is exactly `approved` or `changes_requested`. Findings must be actionable and restricted to violations of the plan or correctness risks in this seven-line form change. Work was prohibited from loading or running the database; visual/platform-load checks are intentionally deferred to Deploy after approval.

## Commit scope and diff

Commit changes exactly one product file:

`Documents/РеализацияТоваровУслуг/Forms/ФормаДокумента/Ext/Form.xml`

Git reports `7` added lines and `0` deleted lines. Added nodes:

- `UsualGroup ГруппаСтатус`: `BackColor #F8BBD0`, after `ShowTitle`, before `ExtendedTooltip`.
- `Page ГруппаОсновное`: `BackColor #FFF0F5`, after `Group`, before `ScrollOnCompress`.
- `Page ГруппаТовары`: `BackColor #FFF0F5`, after `TitleDataPath`, before `ScrollOnCompress`.
- `Page СтраницаДоставка`: `BackColor #FFF0F5`, after `Group`, before `ScrollOnCompress`.
- `Page ГруппаДополнительно`: `BackColor #FFF0F5`, after `Group`, before `ScrollOnCompress`.
- `UsualGroup ГруппаПодвал`: `BackColor #F8BBD0`, after `ShowTitle`, before `ExtendedTooltip`.
- `UsualGroup ГруппаСчетФактураИСостояние`: `BackColor #F8BBD0`, after `ShowTitle`, before `ExtendedTooltip`.

No module, metadata, extension, StyleItem, button, field, table, ID, event or command changed.

## Independently reproduced evidence

1. XML assertion: all seven expected typed elements exist once and each has exactly one expected `BackColor`.
2. Child ordering assertion: each Page color precedes `ScrollOnCompress`; each UsualGroup color precedes `ExtendedTooltip`.
3. After removing only those seven new nodes from the Work XML, `OuterXml` equals the parent commit `cccdd1949^` exactly.
4. Total `BackColor` count is 9: the seven new values plus exactly one unchanged `style:ЦветФонаВыделения` and one unchanged `style:ИтогиФон`.
5. Byte profile: UTF-8 BOM `EF-BB-BF`, CRLF `6620`, bare LF `21`, bare CR `0`, matching the plan's expected post-change profile.
6. `DefaultObjectForm` remains `Document.РеализацияТоваровУслуг.Form.ФормаДокумента`.
7. `form-validate.ps1 -Detailed`: `0 errors, 1 warnings`; the warning is the pre-existing validator range warning `Form version='2.21' (expected 2.17-2.20)`. Counts remain 261 elements, 79 attributes, 43 commands.
8. `form-info` recognizes `ФормаДокумента (Documents.РеализацияТоваровУслуг)` and reports the unchanged events/commands/elements.
9. Work did not load/update/run the database.

## Git whitespace nuance

Plain `git diff --check cccdd1949^ cccdd1949` reports each of the seven added CRLF lines as `trailing whitespace` because this repository/Git invocation does not treat CR-at-EOL specially. The lines contain only XML text followed by CRLF; there are no spaces or tabs after `</BackColor>`. This is consistent with the plan's explicit requirement to preserve CRLF and the verified expected byte profile. `git -c core.whitespace=cr-at-eol diff --check cccdd1949^ cccdd1949` is the semantically appropriate check and is expected to be clean.

Assess whether this is a product/plan defect requiring a change, or a non-blocking Git configuration false positive already resolved by the stronger byte-profile assertion.

## Requested response

Return:

1. `verdict`: `approved` or `changes_requested`.
2. Any actionable findings with severity and exact evidence.
3. Reconciliation points for the CRLF nuance and deferred Deploy-only visual/load checks.
