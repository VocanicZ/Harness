#!/usr/bin/env bash
# test_lane_role.sh — #375: roles in the engine. Every lane is a Manager (orchestration -p*: PLAN, PRD,
# DECOMPOSE, REVIEW and its gauntlet; bug triage; the injector) or an Implementer (issue lanes -i*,
# also resuming from resume.md; bug fixes), and launches with its role's model and effort:
# HARNESS_MODEL_MANAGER / HARNESS_EFFORT_MANAGER / HARNESS_MODEL_IMPLEMENTER / HARNESS_EFFORT_IMPLEMENTER,
# which default to opus/high and sonnet/high on claude and to the CLI's own default everywhere else.
# Precedence: a worktree hook's .harness-lane > the role keys > a --model/--effort in HARNESS_*_FLAGS.
#
# The fixture lanes are launched through launch_agent with tmux faked, and on claude the line it typed
# is run against a fake claude that records the model it ran as its transcript's model.
# (Every CLI in the matrix: test_cli_matrix.sh's launch-role-model row.)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$ROOT/scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
unset HARNESS_MODEL_MANAGER HARNESS_EFFORT_MANAGER HARNESS_MODEL_IMPLEMENTER HARNESS_EFFORT_IMPLEMENTER
unset HARNESS_CLAUDE_FLAGS CLAUDE_FLAGS CLAUDE_BIN HARNESS_CODEX_FLAGS
HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions --effort high"
HARNESS_CODEX_FLAGS="--no-alt-screen --dangerously-bypass-approvals-and-sandbox -c model_reasoning_effort=high"
HARNESS_SESS_PREFIX=hz

# A fake claude: the model --model names, else `default`; one transcript turn records it.
FAKE="$RUN_DIR/fake-claude"
cat > "$FAKE" <<'PY'
import json, os, sys
model, args = "", sys.argv[1:]
for i, a in enumerate(args):
    if a == "--model" and i + 1 < len(args):
        model = args[i + 1]
with open(os.environ["FAKE_TRANSCRIPT"], "a") as f:
    f.write(json.dumps({"type": "assistant", "message": {"model": model or "default"}}) + "\n")
PY
export HARNESS_CLAUDE_BIN="python3 $FAKE" FAKE_TRANSCRIPT="$RUN_DIR/transcript.jsonl"
export HARNESS_EVENTS_FILE="$RUN_DIR/events.jsonl"

SENT="$RUN_DIR/sent"
tmux(){ case "$1" in has-session) return 1 ;; send-keys) shift; [[ "$1" == -t ]] && shift 2; echo "${*% Enter}" >> "$SENT" ;; esac; return 0; }
sleep(){ :; }
mkdir -p "$WORKTREES_DIR"
# wd — a fresh worktree (a plain repo: no main checkout's settings to leak in).
wd(){ local d; d="$(mktemp -d "$WORKTREES_DIR/lane-XXXX")"; git -C "$d" init -q; echo task > "$d/.harness-task.md"; echo "$d"; }
# launch <sess> <wd> — launch_agent it; prints the line it typed.
launch(){ : > "$SENT"; ( launch_agent "$1" "$2" ) >/dev/null 2>&1; grep -m1 -F 'exec ' "$SENT"; }
# ran <line> <wd> — run the typed line in <wd> against the fake: the model its transcript turn names.
ran(){ : > "$FAKE_TRANSCRIPT"; ( cd "$2" && eval "${1#exec }" ) >/dev/null 2>&1
  python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["message"]["model"])' "$FAKE_TRANSCRIPT" 2>/dev/null; }
# opt <line> <ERE> — every value the option takes on the line, space-separated.
opt(){ grep -oE -- "(^| )$2 [^ ]+" <<<"$1" | awk '{print $NF}' | xargs; }
event(){ python3 -c 'import json,sys
ev = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
e = [e for e in ev if e.get("event") == "launch" and e.get("tmux") == sys.argv[2]][-1]
print(e.get("model", ""), e.get("effort", ""))' "$HARNESS_EVENTS_FILE" "$1"; }

echo "=== 1: every session kind maps to its role ==="
assert_eq "$(sess_role "$(sess_orch main)")"          manager     "orch p0 (PLAN, PRD) is a manager"
assert_eq "$(sess_role "$(sess_orch main 42)")"       manager     "orch -p<n> (DECOMPOSE, REVIEW + gauntlet) is a manager"
assert_eq "$(sess_role "hz-main")"                    manager     "a bare legacy orch session is a manager"
assert_eq "$(sess_role "$(sess_impl main 7)")"        implementer "an issue lane -i<n> (impl.md, resume.md) is an implementer"
assert_eq "$(sess_role "$(sess_impl web-api 12)")"    implementer "…in a dashed multi-topology unit too"
assert_eq "$(sess_role "$(sess_orch web-api 3)")"     manager     "a dashed unit's orch session stays a manager"
assert_eq "$(sess_role "$(sess_bug acme/widget 9 triage)")" manager     "bug triage is a manager"
assert_eq "$(sess_role "$(sess_bug acme/widget 9 fix)")"    implementer "bug fix (and its resume.md) is an implementer"
assert_eq "$(sess_role "$(sess_bug acme/fix-it 9 triage)")" manager     "…triage in a repo whose name holds -fix stays a manager"
assert_eq "$(sess_role "$(sess_inject main)")"        manager     "the injector is a manager"

echo "=== 2: a fixture lane of each role runs its configured model (claude) ==="
W="$(wd)"; line="$(launch "$(sess_orch main 5)" "$W")"
assert_eq "$(ran "$line" "$W")" opus "a manager lane's transcript runs opus by default"
assert_eq "$(opt "$line" --effort)" high "…at --effort high, given once"
assert_eq "$(event "$(sess_orch main 5)")" "opus high" "…and its launch event names opus/high"
W="$(wd)"; line="$(launch "$(sess_impl main 6)" "$W")"
assert_eq "$(ran "$line" "$W")" sonnet "an implementer lane's transcript runs sonnet by default"
assert_eq "$(opt "$line" --effort)" high "…at --effort high, given once"
assert_eq "$(event "$(sess_impl main 6)")" "sonnet high" "…and its launch event names sonnet/high"
W="$(wd)"; line="$(HARNESS_MODEL_IMPLEMENTER=opus HARNESS_EFFORT_IMPLEMENTER=max launch "$(sess_bug acme/widget 8 fix)" "$W")"
assert_eq "$(ran "$line" "$W")" opus "HARNESS_MODEL_IMPLEMENTER=opus: a bug-fix lane runs opus (the old behaviour back)"
assert_eq "$(opt "$line" --effort)" max "…at HARNESS_EFFORT_IMPLEMENTER's effort"
W="$(wd)"; line="$(HARNESS_MODEL_MANAGER=haiku launch "$(sess_inject main)" "$W")"
assert_eq "$(ran "$line" "$W")" haiku "HARNESS_MODEL_MANAGER: the injector runs it"
W="$(wd)"; line="$(HARNESS_MODEL_MANAGER=haiku launch "$(sess_impl main 9)" "$W")"
assert_eq "$(ran "$line" "$W")" sonnet "…and an implementer lane does not"

echo "=== 3: .harness-lane beats the role keys ==="
W="$(wd)"; printf 'model=haiku\neffort=low\n' > "$W/$HARNESS_LANE_FILE"
line="$(HARNESS_MODEL_IMPLEMENTER=opus HARNESS_EFFORT_IMPLEMENTER=max launch "$(sess_impl main 10)" "$W")"
assert_eq "$(ran "$line" "$W")" haiku "the lane's own model runs, not the role's"
assert_eq "$(opt "$line" --model)" haiku "--model is the lane's, given once"
assert_eq "$(opt "$line" --effort)" low "--effort is the lane's, given once"
W="$(wd)"; printf 'effort=low\n' > "$W/$HARNESS_LANE_FILE"
line="$(launch "$(sess_impl main 11)" "$W")"
assert_eq "$(opt "$line" --model) $(opt "$line" --effort)" "sonnet low" "a lane pinning only its effort keeps the role's model"
W="$(wd)"; mkdir -p "$W/.claude"; printf '{"model": "haiku"}' > "$W/.claude/settings.local.json"
line="$(launch "$(sess_impl main 12)" "$W")"
assert_eq "$(ran "$line" "$W")" haiku "a worktree hook's settings.local.json pin beats the role's model too (#374)"

echo "=== 4: the role keys beat a --model/--effort in HARNESS_CLAUDE_FLAGS ==="
W="$(wd)"
line="$(HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions --model opus --effort max" launch "$(sess_impl main 13)" "$W")"
assert_eq "$(ran "$line" "$W")" sonnet "the implementer role's sonnet runs, not the flags' opus"
assert_eq "$(opt "$line" --model)" sonnet "--model is the role's, given once"
assert_eq "$(opt "$line" --effort)" high "--effort is the role's, given once"
W="$(wd)"
line="$(HARNESS_MODEL_IMPLEMENTER="" HARNESS_EFFORT_IMPLEMENTER="" HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions --model opus --effort max" launch "$(sess_impl main 14)" "$W")"
assert_eq "$(opt "$line" --model) $(opt "$line" --effort)" "opus max" "role keys set empty: the flags' --model/--effort stand"

echo "=== 5: on a non-claude CLI an empty role key leaves the CLI's default ==="
HARNESS_CLI=codex
assert_eq "$(role_setting manager model)$(role_setting implementer model)$(role_setting manager effort)$(role_setting implementer effort)" "" \
  "codex ships no role default"
W="$(wd)"; line="$(launch "$(sess_impl main 15)" "$W")"
assert_no "an unset role key: no -m on codex's line (its own default model)" grep -qE -- '(^| )(-m|--model) ' <<<"$line"
assert_eq "$(grep -oF 'model_reasoning_effort=' <<<"$line" | wc -l)" 1 "…and the flags' effort, once"
assert_ok "…which is HARNESS_CODEX_FLAGS' own" grep -qF 'model_reasoning_effort=high' <<<"$line"
W="$(wd)"; line="$(HARNESS_MODEL_MANAGER="" HARNESS_CODEX_FLAGS="--no-alt-screen -m gpt-flags" launch "$(sess_orch main 16)" "$W")"
assert_eq "$(opt "$line" '-m')" gpt-flags "an empty role key: the flags' -m stands"
W="$(wd)"; line="$(HARNESS_MODEL_IMPLEMENTER=gpt-5.5 HARNESS_EFFORT_IMPLEMENTER=low HARNESS_CODEX_FLAGS="--no-alt-screen -m gpt-flags -c model_reasoning_effort=high" launch "$(sess_impl main 17)" "$W")"
assert_eq "$(opt "$line" '-m')" gpt-5.5 "a configured role key reaches codex's line, replacing the flags' -m"
assert_eq "$(grep -oE 'model_reasoning_effort=[a-z]+' <<<"$line" | xargs)" model_reasoning_effort=low "…and its effort replaces the flags' one"
assert_eq "$(event "$(sess_impl main 17)")" "gpt-5.5 low" "…and the launch event names them"
HARNESS_CLI=claude

echo "=== 6: a headless lane carries its role's model and effort ==="
W="$(wd)"; ARGV="$RUN_DIR/argv"
( HARNESS_SESSION_BACKEND=headless
  sess_start(){ shift 2; printf '%s\n' "$@" > "$ARGV"; }
  launch_agent "$(sess_orch main 18)" "$W" ) >/dev/null 2>&1
assert_ok "the headless runner's flags carry --model opus --effort high" grep -qE -- '^--flags=.*--model opus.*--effort high|^--flags=.*--effort high.*--model opus' "$ARGV"
assert_eq "$(event "$(sess_orch main 18)")" "opus high" "…and its launch event names them"
unset -f tmux sleep

echo "=== 7: harness init shows and writes the role keys ==="
# init_cfg <dir> [VAR=val…] — run init non-interactively in a fresh project <dir>; prints its output.
init_cfg(){ local d="$1"; shift; mkdir -p "$d"
  ( cd "$d" && env -u HARNESS_CLI STATE_DIR="$d/.harness" HARNESS_INIT_NONINTERACTIVE=1 \
      HARNESS_SESS_PREFIX=hzrole "$@" bash "$ROOT/scripts/init.sh" ) </dev/null 2>&1; }
cfg_has(){ grep -qxF ": \"\${$2:=$3}\"" "$1/.harness/config"; }
out="$(init_cfg "$RUN_DIR/init-claude")"
for kv in HARNESS_MODEL_MANAGER=opus HARNESS_EFFORT_MANAGER=high HARNESS_MODEL_IMPLEMENTER=sonnet HARNESS_EFFORT_IMPLEMENTER=high; do
  assert_ok "claude: init writes ${kv%%=*}=${kv#*=}" cfg_has "$RUN_DIR/init-claude" "${kv%%=*}" "${kv#*=}"
done
assert_ok "init shows both roles" grep -qF 'roles (claude): manager opus/high, implementer sonnet/high' <<<"$out"
init_cfg "$RUN_DIR/init-codex" HARNESS_CLI=codex >/dev/null
for k in HARNESS_MODEL_MANAGER HARNESS_EFFORT_MANAGER HARNESS_MODEL_IMPLEMENTER HARNESS_EFFORT_IMPLEMENTER; do
  assert_ok "codex: init writes $k empty (the CLI's default)" cfg_has "$RUN_DIR/init-codex" "$k" ""
done
init_cfg "$RUN_DIR/init-pin" HARNESS_MODEL_IMPLEMENTER=opus >/dev/null
assert_ok "an answer (here the environment's) is what init writes" cfg_has "$RUN_DIR/init-pin" HARNESS_MODEL_IMPLEMENTER opus
assert_eq "$(STATE_DIR="$RUN_DIR/init-codex/.harness" bash -c 'source "$1"; cli_load codex; role_setting implementer model; echo "|$(lane_model_effort hz-main-i1 /nonexistent)"' _ "$ROOT/scripts/lib.sh" 2>/dev/null)" \
  "|"$'\t' "a codex fleet loading that config launches with the CLI's own model and effort"

finish
