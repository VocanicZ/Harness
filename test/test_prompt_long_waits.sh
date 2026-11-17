#!/usr/bin/env bash
# test_prompt_long_waits.sh — #1042, #1066: lanes slept 9-10 minutes in a foreground Bash loop and polled again. Every wake came
# after the 5-minute prompt-cache TTL and rewrote the lane's whole context (72% of two days' spend). The impl, resume,
# bug-fix and review prompts, as rendered, carry the LONG WAITS rule (prompts/_long_waits.md), and the two Windows
# partials (the winsma `run` is the longest wait there is) point at it. The poll interval stays under 270 seconds. Since #1066 the
# rule is the engine's: a lane starts a long job with `harness-wait run` and ends its turn; the engine resumes it once.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"
P="$HERE/../prompts"
flat(){ tr '\n' ' ' | tr -s ' '; }

echo "-- the partial"
w="$(flat <"$P/_long_waits.md")"
assert_ok "names the rule and the issues"                   grep -qF 'LONG WAITS (#1042, #1066)' <<<"$w"
assert_ok "a lane never waits inside its session"           grep -qF 'never wait inside your session; the engine waits for you' <<<"$w"
assert_ok "says why: the 5-minute cache rewrite"            grep -qF 'Your prompt cache lives 5 minutes' <<<"$w"
assert_ok "bans the seq/sleep loop"                         grep -qF 'for i in $(seq 1 58); do' <<<"$w"
assert_ok "bans the timeout/until loop"                     grep -qF 'timeout 585 bash -c "until' <<<"$w"
assert_ok "bans the SECONDS/while loop"                     grep -qF 'end=$((SECONDS+570)); while' <<<"$w"
assert_ok "long jobs start with harness-wait run"           grep -qF '`harness-wait run --deadline-s <most seconds it may take> --log <logfile> -- <command…>`' <<<"$w"
assert_ok "the lane ends its turn"                          grep -qF 'END YOUR TURN at once' <<<"$w"
assert_ok "the engine resumes it once with the result"      grep -qF 'resumes this session ONCE, when the job exits or the deadline passes, with `wait done: <condition>, rc=<n>, log tail: …`' <<<"$w"
assert_ok "other conditions: pid, path, regex"              grep -qF -- '--pid <pid>' <<<"$w"
assert_ok "a polled run_in_background is not allowed"       grep -qF 'a Bash `run_in_background` you then keep polling' <<<"$w"
assert_ok "the usage limit needs nothing from the lane"     grep -qF 'A usage limit needs nothing from you' <<<"$w"
assert_ok "a queue wait parks (#1034)"                      grep -qF 'park the lane where a park exists' <<<"$w"
assert_ok "unavoidable polling stays under 270 seconds"     grep -qF 'under 270 seconds so the cache stays warm' <<<"$w"

echo "-- the sub-agent rule (#1249)"
assert_ok "names the sub-agent rule"                        grep -qF 'SUB-AGENTS (#1249)' <<<"$w"
assert_ok "one fan-out starts in ONE message"               grep -qF 'Start every sub-agent of one fan-out in ONE message' <<<"$w"
assert_ok "briefs say: foreground only, final report last"  grep -qF 'run every command in the foreground: no `run_in_background`, `Monitor` or `harness-wait run` inside a sub-agent, and never end its turn before its final report' <<<"$w"
assert_ok "one notification per sub-agent"                  grep -qF 'notifies you exactly once' <<<"$w"
assert_ok "a notification with others running: no tool call" grep -qF 'while other sub-agents are still running, make no tool calls: write one short line and end your turn' <<<"$w"
assert_ok "a sub-agent is never polled"                     grep -qF 'Never poll a sub-agent (`TaskOutput`, reading its output file, or `sleep`)' <<<"$w"
cp="$(flat <"$P/_checkpoint_subagents.md")"
assert_ok "checkpoint: record worktree and branch"          grep -qF "record each running sub-agent's worktree and branch in the handoff" <<<"$cp"
assert_ok "checkpoint: push what they have, then stop them" grep -qF 'push what they have, then stop them with the sub-agent stop tool before you exit' <<<"$cp"

echo "-- the sub-agent start text carries the foreground line (#1249)"
sub="$(HARNESS_CLI=claude cli_subagent /w /w/g /w/b.md | flat)"
assert_ok "claude {{SUBAGENT}}: still spawns in the dir"    grep -qF 'spawn it with your own sub-agent tool (a fresh context that sees none of yours), working in `/w/g`.' <<<"$sub"
assert_ok "…and its brief says: foreground, final report last" grep -qF 'run every command in the foreground (no `run_in_background`, `Monitor` or `harness-wait run`) and never end its turn before its final report' <<<"$sub"
assert_ok "the task-tree brief template says it too"        grep -qF 'run every command in the foreground' "$HERE/../skill/subagent-task-tree/SKILL.md"
assert_ok "…and the manager brief template"                 grep -qF 'run every command in the foreground' "$HERE/../skill/subagent-task-tree/MANAGER-BRIEF-TEMPLATE.md"

echo "-- every lane prompt, as rendered"
for p in impl.md resume.md bug-fix.md review.md; do
  out="$(render "$P/$p" ISSUE=5 PRD=4 SLUG=acme/widget BRANCH=issue/5 LABEL_WORKING=agent-working LABEL_PAUSED=agent-paused | flat)"
  assert_ok "$p: carries the LONG WAITS rule"               grep -qF 'LONG WAITS (#1042, #1066) — never wait inside your session' <<<"$out"
  assert_ok "$p: …and the harness-wait command"             grep -qF 'harness-wait run --deadline-s' <<<"$out"
  assert_ok "$p: …with the 270-second poll bound"           grep -qF 'under 270 seconds so the cache stays warm' <<<"$out"
  assert_ok "$p: carries the sub-agent wait rule"           grep -qF 'Start every sub-agent of one fan-out in ONE message' <<<"$out"
  assert_ok "$p: …and the foreground brief line"            grep -qF 'run every command in the foreground' <<<"$out"
  assert_no "$p: the partial directive is expanded"         grep -qF '{{> _long_waits.md}}' <<<"$out"
  assert_ok "$p: the SHARED HOST paragraph is intact"       grep -qF 'every fleet on the host. Never signal PID 0, PID 1 or a negative PID.' <<<"$out"
done

echo "-- a checkpoint stops the sub-agents (#1249)"
for p in impl.md resume.md bug-fix.md; do
  out="$(render "$P/$p" ISSUE=5 PRD=4 SLUG=acme/widget BRANCH=issue/5 LABEL_WORKING=agent-working LABEL_PAUSED=agent-paused | flat)"
  assert_ok "$p: checkpoint records running sub-agents"     grep -qF "record each running sub-agent's worktree and branch in the handoff" <<<"$out"
  assert_ok "$p: …and stops them before exit"               grep -qF 'then stop them with the sub-agent stop tool before you exit' <<<"$out"
  assert_no "$p: the checkpoint partial is expanded"        grep -qF '{{> _checkpoint_subagents.md}}' <<<"$out"
done

echo "-- the Windows partials"
for p in _windows_suite.md _windows_rtdd.md; do
  out="$(flat <"$P/$p")"
  assert_ok "$p: points at the LONG WAITS rule"             grep -qF 'LONG WAITS rule applies (#1042)' <<<"$out"
  assert_ok "$p: the winsma run is an engine-owned wait"    grep -qF 'harness-wait run --deadline-s' <<<"$out"
done
finish
