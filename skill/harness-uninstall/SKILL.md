---
name: harness-uninstall
description: Tear down a Harness install/project — remove the shared engine, this project's .harness/, and the /harness skills. Trigger on /harness-uninstall or "uninstall harness", "remove the harness install".
---

# /harness-uninstall — remove Harness

Thin wrapper around `harness uninstall`.

**This is destructive and irreversible.** It removes the shared host engine (`~/.harness/engine`) and
its PATH symlink, this project's `.harness/` config + state (`run/`, `claims/`, `worktrees/`) and the
`.gitignore` `'.harness/'` entry, and every deployed `/harness*` skill (`~/.claude/skills/harness*`).
The default path **stops the fleet first** (`stop --clean`, which discards uncommitted work in
worktrees), then prompts for confirmation. On Windows it also removes this home's Task Scheduler tasks and launchers,
`harness.cmd`, the python3 shim, the poller and the fleet registry, and refuses `--force-engine` while another fleet
still uses the engine. Always confirm with the user before running.

1. Confirm with the user that they want to remove Harness entirely (engine + this project + skills).
2. Run: `harness uninstall`   (it stops the fleet, then prompts y/N before deleting).
3. For an unattended teardown — skip BOTH the stop guard and the prompt, removing immediately
   regardless of any working agent — run: `harness uninstall --force`.
4. Report what was removed.

To just stop the fleet without removing anything, use `/harness-stop`. For operate guidance use `/harness`.
