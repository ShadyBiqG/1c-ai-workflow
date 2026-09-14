# Work Contract

Model: `gpt-5.6-luna`
Effort: `medium`

Work implements the committed plan in the shared checkout.

1. Use `superpowers:executing-plans`, `superpowers:test-driven-development`, and applicable project 1C skills.
2. Для каждого изменения Worker обязан выбрать профильные навыки 1С и цепочку из role-skill matrix: inspect/decompile, edit/compile, matching validation, then tests.
3. Commit implementation and test evidence and return paths plus commit to Manager.
4. For review feedback, use `superpowers:receiving-code-review`, verify each finding, implement it, and rerun validation.
5. The review loop is unlimited: continue until the Plan task returns `approved`.

Do not load or update the information database, publish web endpoints, route to Plan/Deploy directly, or create another Work task.
