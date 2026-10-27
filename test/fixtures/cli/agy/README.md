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
| `transcript.db` | `~/.gemini/antigravity-cli/conversations/<session>.db` of the capture session, reduced to its `gen_metadata` table and, in each row, to the two fields the usage reader decodes (1.4 usage, 1.19 model id); everything else (request bodies, ids) dropped. |
| `usage.expected` | What `agy_usage.py` folds it to. The field numbers were checked against agy's own report: `agy -p … --output-format json` said `input_tokens 19156, output_tokens 36` for a two-call conversation, and decoding that conversation's db gave 19156 / 36. This capture's totals also equal the sum of the per-step `input_tokens`/`output_tokens` in its `brain/<session>/.system_generated/logs/transcript.jsonl`. |
| `last_conversations.json` | The capture's entry of `~/.gemini/antigravity-cli/cache/last_conversations.json` (workspace → conversation id), with the workspace path replaced by `@WD@`. This is how the adapter learns the session id agy picked. |
| `session` | That conversation id. |
| `hook-transcript.jsonl` | `brain/<id>/.system_generated/logs/transcript.jsonl` of a goal-loop run whose task file names the promise. The agent read that file, and the read's output (logged `source: MODEL`, `type: GENERIC`) carries `<promise>ZEBRA DONE</promise>`; the model's own replies (`PLANNER_RESPONSE`) do not. The harness-ralph Stop hook must keep looping on it. |
| `model` | The model the capture ran. |
| `VERSION` | `agy --version`, then the capture date and host. |
| `fake-cli` | Stands in for `agy` when the matrix runs a typed launch line: it records `session` for the workspace in `cache/last_conversations.json` and puts `transcript.db` at `conversations/<id>.db`, as the capture did. |
| `stop-hook` | One end of turn as agy runs it: the harness-ralph Stop hook (`plugins/ralph-loop`, which `agy_prereqs` installs), handed `{conversationId, workspacePaths, transcriptPath}`, over `hook-transcript.jsonl` plus one model reply (`PLANNER_RESPONSE`). |
| `handoff-skill` | How a prompt invokes the handoff skill: agy expands skills as slash commands, `/<name>` (local: `agy --help`, `--disable-slash-commands  Disable slash command and skill expansion`). |
| `usage-windows.json` | `agy -p "/usage" --output-format json`, run on the host the same day (runs no turn). |
| `usage-windows.expected` | `<group>\t<window>\t<pct used>` it reports: `100 - remaining_fraction*100`. |
