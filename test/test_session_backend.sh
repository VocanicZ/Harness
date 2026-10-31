#!/usr/bin/env bash
# test_session_backend.sh — #346 / PRD #344: the session-backend seam. HARNESS_SESSION_BACKEND is read
# in one place (scripts/session/dispatch.sh), defaults to tmux, is written by `harness init`, reported
# by `harness doctor` and refused when unknown; every lane-lifecycle operation reaches tmux through
# scripts/session/tmux.sh, and no other engine file runs `tmux` (the guard below).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"
_DOCTOR_SOURCED=1 source "$ROOT/scripts/doctor.sh"
make_env

echo "== guard: only the tmux backend runs tmux =="
# The engine files that may still name tmux as a command, each with its reason. Everything else
# reaches a session through sess_* (bash) or session_backend (python).
declare -A ALLOW=(
  [scripts/session/tmux.sh]="the tmux backend itself"
  [scripts/session_backend.py]="the Python views' half of the seam: the tmux argv they run"
  [install.sh]="the installer checks the host's prerequisites before any engine (or config) exists"
)
# tmux_calls <file> — each line of <file> that runs tmux: a tmux subcommand after the word `tmux`
# (comments dropped), `command -v tmux`, or — in Python — "tmux" as an argv element.
TMUX_SUB='ls|list-[a-z]+|has-session|has|new-session|new|send-keys|send|capture-pane|capturep|kill-[a-z]+|display-message|display|attach-session|attach|a|detach-client|set-option|set|show-options|show|split-window|new-window|select-[a-z]+|resize-[a-z]+|pipe-pane|run-shell|wait-for|start-server'
tmux_calls(){ case "$1" in
  *.py) grep -nE "[\"']tmux[\"']" "$1" ;;
  *)    sed -E 's/(^|[[:space:]])#.*$//' "$1" | grep -nE \
          "(^|[^[:alnum:]_./-])tmux[[:space:]]+(-[[:alnum:]]+[[:space:]]+)*($TMUX_SUB)([[:space:]]|\$|[;)|&])|command -v tmux" ;;
  esac; }
# The engine's files as git knows them (tracked or new, never ignored — no __pycache__); off a git
# checkout (a swarm snapshot, a release tarball) every file under the same pathspecs, caches dropped.
repo_files(){
  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$ROOT" ls-files --cached --others --exclude-standard -- "$@"
  else
    local p; for p in "$@"; do ( cd "$ROOT" && find . -type f \( -path "./$p" -o -path "./$p/*" \) 2>/dev/null ) ; done | sed 's#^\./##' | grep -v -e '__pycache__/' -e '\.pyc$'
  fi | sort -u; }
engine_files(){ repo_files install.sh update.sh 'bin/*' 'scripts/*.sh' 'scripts/*.py' 'scripts/*.js'; }

# The guard must be able to fail: each shape of a tmux call it exists to catch is caught.
probe="$RUN_DIR/probe"; mkdir -p "$probe"
printf 'x(){ tmux send-keys -t "$1" Enter; }\n'            > "$probe/a.sh"
printf 'y=$(tmux ls -F "#S" 2>/dev/null)\n'                > "$probe/b.sh"
printf 'sup_act tmux kill-session -t "=$s"\n'              > "$probe/c.sh"
printf '"$@" tmux send-keys -t "$t" Escape\n'              > "$probe/d.sh"
printf 'command -v tmux >/dev/null || die nope\n'          > "$probe/e.sh"
printf 'exec tmux attach -t "$sess"\n'                     > "$probe/f.sh"
printf 'sh(["tmux", "capture-pane", "-p"])\n'              > "$probe/g.py"
for f in "$probe"/*; do assert_ok "the guard catches: $(cat "$f")" test -n "$(tmux_calls "$f")"; done
# …and the prose that only names tmux is not a call.
printf '# tmux kill-session in a comment\necho "1 live tmux session(s)"\nask P "tmux session prefix" x\n' > "$probe/h.sh"
printf '"""the `tmux ls` session list"""\n' > "$probe/i.py"
assert_eq "$(tmux_calls "$probe/h.sh")" "" "a comment, a message and a prompt naming tmux are not calls"
assert_eq "$(tmux_calls "$probe/i.py")" "" "a docstring naming tmux is not a call"

n=0
while read -r f; do
  [[ -n "${ALLOW[$f]:-}" ]] && continue
  hits="$(tmux_calls "$ROOT/$f")"; n=$((n + 1))
  assert_eq "$hits" "" "$f runs no tmux of its own"
done < <(engine_files)
assert_ok "the guard read the engine's files ($n)" test "$n" -gt 30
for f in "${!ALLOW[@]}"; do
  assert_ok "allowlisted $f exists (${ALLOW[$f]})" test -f "$ROOT/$f"
done
assert_ok "the tmux backend does run tmux (the allowlist is not stale)" test -n "$(tmux_calls "$ROOT/scripts/session/tmux.sh")"

echo "== the key is read in one place =="
readers="$(cd "$ROOT" && repo_files scripts bin | while read -r f; do grep -qF HARNESS_SESSION_BACKEND "$f" && echo "$f"; done | xargs)"
assert_eq "$readers" "scripts/session/dispatch.sh scripts/session_backend.py" \
  "only the seam names HARNESS_SESSION_BACKEND (init and doctor go through \$SESS_CONFIG_VAR / sess_backend)"

echo "== config: default, valid values, refusal =="
assert_eq "$(sess_backend)" tmux "HARNESS_SESSION_BACKEND defaults to tmux"
assert_eq "$(sess_backend_list | xargs)" "headless tmux" "the backends: one file each under scripts/session/"
assert_ok "tmux is valid"     sess_backend_check tmux
assert_ok "headless is valid" sess_backend_check headless
assert_no "dispatch is not a backend" sess_backend_check dispatch 2>/dev/null
msg="$(sess_backend_check screen 2>&1)"; rc=$?
assert_eq "$rc" 1 "an unknown backend is refused"
assert_eq "$msg" "unknown HARNESS_SESSION_BACKEND: screen (valid: headless tmux)" "…with a message naming the valid ones"
msg="$(HARNESS_SESSION_BACKEND=screen sess_list 2>&1)"; rc=$?
assert_eq "$rc" 1 "a session call under an unknown backend fails…"
assert_ok "…naming the valid backends" grep -qF "(valid: headless tmux)" <<<"$msg"

echo "== the tmux backend: every operation, the tmux command it runs =="
TL="$RUN_DIR/tmux.log"
tmux(){ local IFS=$'\t'; printf '%s\n' "$*" >> "$TL"; case "$1" in ls) printf 'hz-main-i1\n';; capture-pane) echo SCREEN;; display-message) echo 4242;; esac; return 0; }
: > "$TL"
sess_list >/dev/null; sess_list_paths >/dev/null; sess_panes >/dev/null; sess_live =hz-main-i1
sess_start hz-main-i1 /w -e K=V; sess_send_line hz-main-i1 "exec agent"; sess_type hz-main-i1 "hi there"
sess_enter hz-main-i1; sess_clear_line hz-main-i1; sess_interrupt hz-main-i1
assert_eq "$(sess_capture hz-main-i1)" SCREEN "sess_capture returns the screen"
sess_capture hz-main-i1 40 >/dev/null
assert_eq "$(sess_pane_pid hz-main-i1)" 4242 "sess_pane_pid returns the pane's pid"
sess_kill =hz-main-i1
want="$(printf '%s\n' \
  $'ls\t-F\t#S' $'ls\t-F\t#{session_name}\t#{session_path}' \
  $'list-panes\t-a\t-F\t#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}' \
  $'has-session\t-t\t=hz-main-i1' $'new-session\t-d\t-s\thz-main-i1\t-c\t/w\t-e\tK=V' \
  $'send-keys\t-t\thz-main-i1\texec agent\tEnter' $'send-keys\t-t\thz-main-i1\t-l\thi there' \
  $'send-keys\t-t\thz-main-i1\tEnter' $'send-keys\t-t\thz-main-i1\tC-u' $'send-keys\t-t\thz-main-i1\tEscape' \
  $'capture-pane\t-p\t-t\thz-main-i1' $'capture-pane\t-p\t-S\t-40\t-t\thz-main-i1' \
  $'display-message\t-p\t-t\thz-main-i1\t#{pane_pid}' $'kill-session\t-t\t=hz-main-i1')"
assert_eq "$(cat "$TL")" "$want" "each sess_* runs exactly today's tmux command"
assert_eq "$(sess_bins)" tmux "the tmux backend needs tmux on PATH"
assert_eq "$(sess_attach_hint hz-main-i1)" "tmux attach -t hz-main-i1" "attach hint"
assert_eq "$(sess_describe sess_interrupt t1)" "tmux send-keys -t t1 Escape" "a dry run logs Escape as tmux's command"
assert_eq "$(sess_describe sess_type t1 hello world)" "tmux send-keys -t t1 -l hello world" "…a typed line"
assert_eq "$(sess_describe sess_kill =t1)" "tmux kill-session -t =t1" "…a kill"
assert_eq "$(sess_describe gh issue edit 5)" "gh issue edit 5" "anything not a session call logs as itself"
# The engine's own wrappers go through the seam.
: > "$TL"; session_live hz-x; team_sessions main >/dev/null; tmux_sessions_with_paths >/dev/null
assert_eq "$(cut -f1 "$TL" | xargs)" "has-session ls ls" "session_live / team_sessions / tmux_sessions_with_paths route through sess_*"

echo "== every backend implements the whole interface =="
iface="$(sed -nE 's/^sess_([a-z_]+)\(\)\{ _sess_call \1 .*/\1/p' "$ROOT/scripts/session/dispatch.sh" | sort | xargs)"
assert_ok "the interface is read off dispatch.sh ($iface)" test "$(wc -w <<<"$iface")" -ge 14
for f in scripts/session/tmux.sh scripts/session/headless.sh; do
  b="${f##*/}"; b="${b%.sh}"
  have="$(sed -nE "s/^${b}_sess_([a-z_]+)\(\).*/\1/p" "$ROOT/$f" | grep -vx describe | sort | xargs)"
  assert_eq "$have" "$iface" "$f defines ${b}_sess_<fn> for every interface function"
done

echo "== the headless backend: no tmux; a lane needs its runner's command (#349: test_headless_lane.sh) =="
: > "$TL"
export HARNESS_SESSION_BACKEND=headless
msg="$(sess_start hz-main-i2 /w -e K=V 2>&1)"; rc=$?
assert_eq "$rc" 1 "headless starts no lane without the runner's command"
assert_ok "…and says so" grep -q "headless.*needs the lane runner's command" <<<"$msg"
assert_eq "$(sess_list)" "" "headless lists no session while no lane runs"
assert_no "headless: nothing is live" sess_live hz-main-i1
assert_eq "$(sess_bins)" "python3" "headless needs python3 (its lane runner), no multiplexer binary"
assert_eq "$(cat "$TL")" "" "no tmux ran under headless"
unset HARNESS_SESSION_BACKEND; HARNESS_SESSION_BACKEND=tmux
unset -f tmux

echo "== python: session_backend =="
py(){ python3 - "$ROOT/scripts" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import session_backend as sb, fleetview as fv
calls = []
fv.run_cmd = lambda argv, timeout=20: (calls.append(argv), (0, "s1\t100\n"))[1]
print(sb.backend(), sb.capture_argv("s1") is not None, sorted(fv.host_sessions()), len(calls), sb.attach_hint("s1"))
PY
}
assert_eq "$(py)" "tmux True ['s1'] 1 tmux attach -t s1" "tmux: the views list sessions through tmux's argv"
assert_eq "$(HARNESS_SESSION_BACKEND=headless py)" "headless False [] 0 harness status" "headless: no probe runs, no session is listed"

echo "== harness init writes the key; doctor reports it =="
proj="$RUN_DIR/proj"; mkdir -p "$proj"
init(){ ( cd "$proj" && unset STATE_DIR && HARNESS_INIT_NONINTERACTIVE=1 HARNESS_MODE=issue-only HARNESS_TOPOLOGY=single \
  HARNESS_OWNER=acme HARNESS_REPO=acme/widget HARNESS_SESS_PREFIX=sbt "$@" bash "$ROOT/scripts/init.sh" ) </dev/null; }
init env >/dev/null 2>&1
assert_ok "init writes HARNESS_SESSION_BACKEND (tmux)" grep -qxF ': "${HARNESS_SESSION_BACKEND:=tmux}"' "$proj/.harness/config"
rm -rf "$proj/.harness"; init env HARNESS_SESSION_BACKEND=headless >/dev/null 2>&1
assert_ok "init writes the backend the environment names" grep -qxF ': "${HARNESS_SESSION_BACKEND:=headless}"' "$proj/.harness/config"
rm -rf "$proj/.harness"; out="$(init env HARNESS_SESSION_BACKEND=screen 2>&1)"; rc=$?
assert_eq "$rc" 1 "init refuses an unknown backend"
assert_ok "…naming the valid ones" grep -qF "unknown HARNESS_SESSION_BACKEND: screen (valid: headless tmux)" <<<"$out"
assert_no "…and writes no config" test -f "$proj/.harness/config"

tmux(){ return 1; }
out="$(DOCTOR_FIX=0 doctor_main 2>&1)"; rc=$?
assert_ok "doctor reports the session backend" grep -qxF "session backend: tmux" <<<"$out"
assert_eq "$rc" 0 "…and a known one is healthy"
out="$(HARNESS_SESSION_BACKEND=screen DOCTOR_FIX=0 doctor_main 2>&1)"; rc=$?
assert_ok "doctor flags an unknown backend, naming the valid ones" grep -qF "session backend: screen — UNKNOWN (valid: headless tmux" <<<"$out"
assert_eq "$rc" 1 "…as a problem"
unset -f tmux

echo "== harness start refuses an unknown backend =="
out="$(cd "$proj" && STATE_DIR="$RUN_DIR/nostate" HARNESS_SESSION_BACKEND=screen bash "$ROOT/scripts/start.sh" 2>&1)"; rc=$?
assert_no "start exits non-zero" test "$rc" -eq 0
assert_ok "…with start's own refusal, naming the valid backends" \
  grep -qF "set HARNESS_SESSION_BACKEND in $RUN_DIR/nostate/config to one of: headless tmux" <<<"$out"

echo "== launch_agent stops when the backend cannot start the session =="
# A CLI with no headless lane runner (codex) cannot start a headless lane.
( export HARNESS_SESSION_BACKEND=headless HARNESS_CLI=codex; wd="$RUN_DIR/lwd"; mkdir -p "$wd"
  sess_send_line(){ echo TYPED >> "$RUN_DIR/typed"; }; log(){ echo "$*" >> "$RUN_DIR/launch.log"; }
  : > "$wd/.harness-task.md"; launch_agent hz-main-i9 "$wd" 2>/dev/null ); rc=$?
assert_eq "$rc" 1 "launch_agent fails when sess_start does"
assert_no "…types nothing into the session that never started" test -f "$RUN_DIR/typed"
assert_no "…and records no goal for it" test -f "$RUN_DIR/hz-main-i9.goal"
assert_ok "…and says why" grep -q "hz-main-i9 could not be started (backend headless)" "$RUN_DIR/launch.log"

echo "== docs =="
assert_ok "docs/reference.md documents HARNESS_SESSION_BACKEND and its values" \
  grep -qE '^\| `HARNESS_SESSION_BACKEND` \| `tmux` \|.*`headless`' "$ROOT/docs/reference.md"
finish
