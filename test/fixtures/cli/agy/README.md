# `agy` fixtures

Captured 2026-10-27 (UTC) on the fleet host from Antigravity CLI `1.4.8` (Google AI Pro account), in a
throwaway git repo, model `gemini-3.8-flash-low`, launched as Harness does:
`agy --dangerously-skip-permissions --model <m> -i "<prompt>"`. The pane is 160x45; each `.txt` is
`tmux capture-pane -p` of it.

| file | how |
|---|---|
| `trust.txt` | `agy` in the repo before it was trusted: the workspace-trust dialog. Its selected option, `> Yes, I trust this folder`, is at column 0 like the input prompt. |
| `busy.txt` | Mid-turn, before the first token: braille spinner + `Loading...`. |
| `busy-generating.txt` | Mid-turn while the reply streamed: braille spinner + `Generating...`. |
| `idle.txt` | After the turn ended: `>` alone at column 0 between two rules. (A background shell command still running leaves the pane like this too: the turn is over.) |
| `limit.txt` | NOT triggerable on demand. `idle.txt` with `You have exhausted your quota on this model.` inserted above the input box; that string is in the 1.4.8 binary (byte search of `~/.local/bin/agy`). |
| `transient.txt` | NOT triggerable on demand. `idle.txt` with `Agent execution terminated due to error.` (agy's give-up after its own retries) inserted the same way, from the same binary search. |
| `transient-retrying.txt` | NOT triggerable on demand. `busy.txt` with its spinner label replaced by `Model unavailable (attempt 2/10), retrying in 12s`, agy's in-progress status while it retries an unavailable model (the 1.4.8 binary's changelog: "show what the agent is waiting on, such as … retrying an unavailable model (for example `Model unavailable (attempt 2/10), retrying in 12s` with a live countdown)"). The `>` input box shows below it, so it must read as busy and never as a transient give-up.
| `bypass-subagent.txt` | #256, in a throwaway git repo `agy_trust` had pre-accepted: `agy --dangerously-skip-permissions --model gemini-3.8-flash-low -i "Spawn a sub-agent and have the sub-agent (not you) run the shell command: touch subagent-proof.txt …"`, after the turn. No trust dialog, no permission prompt; `subagent-proof.txt` was created. |
| `bypass-subagent.jsonl` | The two transcripts of that run (`brain/<id>/.system_generated/logs/transcript.jsonl`), each row tagged `conversation: parent\|subagent`, cut to the fields shown and system messages dropped: the parent created the sub-agent, and the sub-agent's shell step (`Command exited with code 0.`) ran the `touch`. |
| `permission.txt` | The control for it: the same agy WITHOUT `--dangerously-skip-permissions`, asked to `touch main-proof.txt`, stopped on `Requesting permission for:` / `Run this command?`, its `> 1. Yes, run command` at column 0. |
| `trust-child-of-trusted.txt` | agy launched in `<dir>/child` after `agy_trust <dir>`: the trust dialog still shows, so a trusted parent does not cover the directories under it. |
| `transcript.db` | `~/.gemini/antigravity-cli/conversations/<session>.db` of the capture session, reduced to its `gen_metadata` table and, in each row, to the two fields the usage reader decodes (1.4 usage, 1.19 model id); everything else (request bodies, ids) dropped. |
| `usage.expected` | What `agy_usage.py` folds it to. The field numbers were checked against agy's own report: `agy -p … --output-format json` said `input_tokens 19156, output_tokens 36` for a two-call conversation, and decoding that conversation's db gave 19156 / 36. This capture's totals also equal the sum of the per-step `input_tokens`/`output_tokens` in its `brain/<session>/.system_generated/logs/transcript.jsonl`. |
| `last_conversations.json` | The capture's entry of `~/.gemini/antigravity-cli/cache/last_conversations.json` (workspace → conversation id), with the workspace path replaced by `@WD@`. This is how the adapter learns the session id agy picked. |
| `session` | That conversation id. |
| `hook-transcript.jsonl` | `brain/<id>/.system_generated/logs/transcript.jsonl` of a goal-loop run whose task file names the promise. The agent read that file, and the read's output (logged `source: MODEL`, `type: GENERIC`) carries `<promise>ZEBRA DONE</promise>`; the model's own replies (`PLANNER_RESPONSE`) do not. The harness-ralph Stop hook must keep looping on it. |
| `model` | The model the capture ran. |
| `VERSION` | `agy --version`, then the capture date and host. |
| `fake-cli` | Stands in for `agy` when the matrix runs a typed launch line: it records `session` for the workspace in `cache/last_conversations.json`, puts `transcript.db` at `conversations/<id>.db`, and starts `brain/<id>/.system_generated/logs/transcript.jsonl` with a step stamped `created_at` now, as the capture did. |
| `stop-hook` | One end of turn as agy runs it: the harness-ralph Stop hook (`plugins/ralph-loop`, which `agy_prereqs` installs), handed `{conversationId, workspacePaths, transcriptPath}`, over `hook-transcript.jsonl` plus one model reply (`PLANNER_RESPONSE`). |
| `handoff-skill` | How a prompt invokes the handoff skill: agy expands skills as slash commands, `/<name>` (local: `agy --help`, `--disable-slash-commands  Disable slash command and skill expansion`). |
| `usage-windows.json` | `agy -p "/usage" --output-format json`, run on the host the same day (runs no turn). |
| `usage-windows.expected` | `<group>\t<window>\t<pct used>` it reports: `100 - remaining_fraction*100`. |
