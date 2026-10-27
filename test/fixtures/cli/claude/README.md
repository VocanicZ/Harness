# `claude` fixtures

Captured 2026-10-27 (UTC) on the fleet host from Claude Code `2.1.311`, in a throwaway git repo set up
the way a Harness lane is: workspace trust pre-accepted, `permissions.defaultMode=bypassPermissions`
and Harness's own status line (`usage-statusline.sh`) in `.claude/settings.local.json`. The pane is
160x45; each `.txt` is `tmux capture-pane -p` of it.

| file | how |
|---|---|
| `trust.txt` | `claude --model haiku` in the repo before it was trusted: the workspace-trust dialog. |
| `busy.txt` | Mid-turn while a foreground `python3 -c 'import time; time.sleep(45)'` ran: the spinner plus `(ctrl+b ctrl+b (twice) to run in background)`. |
| `busy-spinner.txt` | Mid-turn while the model was writing (no tool running): the spinner line `✻ Puttering… (1s · ↓ 38 tokens · thinking)` only. No `esc to interrupt` anywhere: Harness's status line hides it (docs/cli-capabilities.md Findings 5, confirmed). |
| `idle.txt` | After the turn ended: `❯` at column 0 in the input box. |
| `limit.txt` | NOT triggerable on demand. `idle.txt` with the limit line a real lane showed (#120, quoted in its issue body) inserted above the input box. |
| `transient.txt` | NOT triggerable on demand. `idle.txt` with the 529 line a real lane showed (#115, quoted in its issue body) inserted above the input box. |
| `transcript.jsonl` | The session's own transcript (`$CLAUDE_CONFIG_DIR/projects/<cwd>/<session>.jsonl`), trimmed to its `user`/`assistant` lines; message text replaced by `(trimmed)`, ids, timestamps, model and usage kept as written. |
| `usage.expected` | What that transcript folds to (`stats.py usage`, deduped per message id). |
| `session` | The `--session-id` the launch passed; the transcript's `sessionId`. |
| `model` | The model the capture ran (`--model haiku`). |
| `VERSION` | `claude --version`, then the capture date and host. |
| `usage-drop.json` | The file `usage-statusline.sh` (Harness's status line) dropped during the capture from the `rate_limits` Claude Code piped it; `cli_limit_usage` reads these. |
| `fake-cli` | Stands in for `claude` when the matrix runs a typed launch line: it writes `transcript.jsonl` where Claude Code writes a session's transcript, `projects/<cwd>/<id>.jsonl`, named by `--session-id` (or by an id it picks itself when the line passes none, as claude does). |
| `stop-hook` | One end of turn as Claude Code runs it: `ralph-loop/stop-hook.sh` in the worktree, handed `{session_id, transcript_path}`, over `transcript.jsonl` written compact (as Claude Code writes it; the capture here is pretty-printed) plus one assistant reply. |
| `ralph-loop/` | `hooks/stop-hook.sh` and `LICENSE` (Apache-2.0) of the `ralph-loop` plugin 1.0.1 from `claude-plugins-official`, the goal loop `claude_prereqs` installs, copied unchanged from the host's plugin cache. |
| `handoff-skill` | How a prompt invokes the handoff skill: Claude Code runs a skill as a slash command, `/<name>` (https://code.claude.com/docs/en/skills). |
| `usage-windows.expected` | `<account>\t<window>\t<pct used>` that drop reports (the test re-dates `resets_at` into the future, since a passed reset is skipped). |
