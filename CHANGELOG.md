# Changelog

Notable changes to Harness. Releases and their full notes: [GitHub Releases](https://github.com/VocanicZ/Harness/releases).

## Unreleased

### Caveman in every lane (#377)

- Every session prompt — plan, prd, decompose, review, bug-triage, bug-fix, impl, resume, inject —
  invokes the `caveman` skill at session start through one shared partial, `prompts/_caveman.md`.
  Before, only impl and bug-fix did.
- Scoped: caveman for the session's own output and agent-to-agent comments (handoffs, review
  findings, checkpoint notes); human-facing artifacts (PRD and issue bodies, PR descriptions, docs,
  README, commit messages) stay plain prose; exact strings (code, commands, errors, labels, issue
  refs) are never compressed.

See [docs/reference.md § Lane output style](docs/reference.md#lane-output-style-caveman).

### Roles: model and effort per lane (#375)

- Every lane is a **Manager** (orchestration `-p*`: PLAN, PRD, DECOMPOSE, REVIEW/gauntlet; bug triage;
  the injector) or an **Implementer** (issue lanes `-i*`, incl. `resume.md`; bug fixes), and launches
  with its role's model and effort: `HARNESS_MODEL_MANAGER`, `HARNESS_EFFORT_MANAGER`,
  `HARNESS_MODEL_IMPLEMENTER`, `HARNESS_EFFORT_IMPLEMENTER`.
- Defaults on `claude`: `opus`/`high` (Manager), `sonnet`/`high` (Implementer). Every other CLI: empty =
  the CLI's own default unless configured.
- Precedence: a worktree hook's `.harness-lane` > the role keys > a `--model`/`--effort` in
  `HARNESS_*_FLAGS`. `harness init` asks for and shows both roles.
- **Behaviour change:** a fleet pinning `--model opus` in `HARNESS_CLAUDE_FLAGS` (harness-dev, ORGE,
  bangwa) gets Sonnet implementers after this. Set `HARNESS_MODEL_IMPLEMENTER=opus` in
  `.harness/config` to keep the old behaviour.

See [docs/reference.md § Roles](docs/reference.md#roles-model-and-effort-per-lane).
