# e2e.sh — the end-to-end checks on a real Windows host that no earlier task covered (#496, PRD #475 Task 8).
# NOT run by test/run.sh: it is the script `winsma.sh run <issue> <mode> "$(cat e2e.sh)"` sends to the host, where it runs in Git Bash
# inside C:\hx-<issue>\ (cwd = $HX_DIR; HARNESS_HOME, HARNESS_BIN_DIR, HARNESS_USER_SKILLS, TMPDIR, npm_config_cache are the isolation's).
# See docs/windows-smoke.md. Environment (set by the caller, all optional):
#   HX_BRANCH   the branch under test (default issue/496); it must be pushed, the host clones it
#   HX_STAGES   which stages to run, space separated: supervise ops inject supdiag live (default: supervise ops inject)
# Stages:
#   (every stage installs this branch as a local release into the sandbox first, then `harness init` in a clone of the sandbox repo)
#   supervise  mode `install` (CLAUDE_CONFIG_DIR is the sandbox: no sign-in, no token usage). `harness start`, `supervise --install`
#          registers the per-home, logon-only task; the task's own command line runs the supervisor (Task Scheduler cannot: see the log);
#          a pool worker is killed and the supervisor brings it back; `supervise --uninstall` removes the task
#   ops    mode `install`. `harness start`, then
#            web        `harness web` serves the dashboard on a private port (page, JSON, 404), then `web --install` does the same from its task
#            reports    `harness stats` (text, --json, --issue), `harness forecast` and `harness one check|gate` on an event log of fixture
#                       lanes plus a real sandbox issue
#            (misc)     status, poll, migrate, tier, `release --dry-run`
#   inject mode `install`. `harness plan|prd|issue "<brief>"` each launch the injector lane (a stand-in claude, no sign-in), which renders
#          the task file and runs a turn
#   supdiag  mode `install`. One `harness supervise --once` pass over a fleet whose worker was killed: what the supervisor does about it
#   live   mode `base` (the REAL Claude sign-in, the only stage that uses it, under the guard). test/smoke/fleet_smoke.sh claude on this host:
#          claim → headless lane → PR → merge → close, with `pause --force` checkpoint and resume mid-lane; then `harness stats` for the
#          lane's Claude token usage and `harness forecast` for the closed issue.
# winget is a logging stub (never a real install); schtasks is real, and every task name is written to $HX_DIR/tasks BEFORE it is registered
# so cleanup deletes it by name; every process the script starts is recorded in $HX_DIR/pids.
set -u
fail=0; say(){ echo "[$(date -u +%H:%M:%S)] $*"; }
ok(){ if eval "$2"; then say "PASS $1"; else say "FAIL $1"; fail=1; fi; }
st(){ MSYS2_ARG_CONV_EXCL='*' schtasks "$@"; }
BRANCH="${HX_BRANCH:-issue/496}"; STAGES="${HX_STAGES:-supervise ops inject}"
has(){ [[ " $STAGES " == *" $1 "* ]]; }
REPO=VocanicZ/harness-smoke-claude
say "== host: $(uname -srm) | bash $BASH_VERSION | python3 $(python3 --version 2>&1) | MSYS=${MSYS:-}"
case "$(uname -s)" in MINGW*|MSYS*) ;; *) say "FAIL not Git Bash (uname -s must start with MINGW or MSYS)"; exit 1;; esac
say "== clone $BRANCH"
git clone -q --branch "$BRANCH" https://github.com/VocanicZ/Harness.git src || { say "FAIL clone failed"; exit 1; }
say "src at $(git -C src rev-parse --short HEAD)"
HX_U="$(cygpath -u "$HX_DIR")"
CUR=v9.9.96
mkdir -p stubs rel/download
printf '#!/usr/bin/env bash\necho "winget $*" >> "%s/winget.log"\nexit 0\n' "$HX_DIR" > stubs/winget; : > winget.log; chmod +x stubs/winget
export HARNESS_BASE_URL="file:///$HX_DIR/rel/download" HARNESS_API_URL="file:///$HX_DIR/rel/latest.json" \
  HARNESS_WINGET="$HX_DIR/stubs/winget" HARNESS_INSTALL_PREREQS=1 HARNESS_INSTALL_NOPROMPT=1 HARNESS_SKIP_RTDD=1
export TMPDIR="$(cygpath -u "$TMPDIR")"
HOST_PATH="$PATH"
stg="stage/harness-$CUR"; mkdir -p "$stg" "rel/download/$CUR"
git -C src archive HEAD bin scripts prompts skill plugins install.sh update.sh | tar -xf - -C "$stg"
printf '%s\n%040d\n' "$CUR" 0 > "$stg/VERSION"
tar -C stage -czf "rel/download/$CUR/harness-$CUR.tar.gz" "harness-$CUR"
( cd "rel/download/$CUR" && sha256sum "harness-$CUR.tar.gz" > SHA256SUMS )
printf '{"tag_name":"%s"}\n' "$CUR" > rel/latest.json
say "== install this branch as release $CUR into the sandbox ($HARNESS_HOME)"
mkdir -p "$HARNESS_BIN_DIR" "$HARNESS_USER_SKILLS"
HARNESS_REF="$CUR" bash src/install.sh </dev/null 2>&1 | sed 's/^/   /'; irc=${PIPESTATUS[0]}
ok "install.sh exit 0" '(( irc == 0 ))'
(( irc == 0 )) || { say "result: FAIL"; exit 1; }
export PATH="$(cygpath -u "$HARNESS_BIN_DIR"):$HOST_PATH"
say "harness resolves to: $(command -v harness) | $(harness --version 2>&1 | head -1)"
winpid(){ cat "/proc/$1/winpid" 2>/dev/null || echo "$1"; }
# pid_alive <pid> — an MSYS pid (the pid files hold what bash saw) or a Windows one
pid_alive(){ [[ "$1" =~ ^[1-9][0-9]*$ ]] && { kill -0 "$1" 2>/dev/null || tasklist //FI "PID eq $1" 2>/dev/null | grep -q "[^0-9]$1[^0-9]"; }; }
tnames(){ ( source "$HX_DIR/src/scripts/portable.sh"; win_task_name harness-supervise; win_task_name harness-web ); }
SUP=$(tnames | sed -n 1p); WEB=$(tnames | sed -n 2p)
printf '%s\n%s\n' "$SUP" "$WEB" >> "$HX_DIR/tasks"       # recorded before anything is registered
say "this home's tasks: $SUP, $WEB"
H=harness
PY="$HARNESS_HOME/bin/python3"; [[ -x $PY ]] || PY=python
issues_open=""
cleanup_issues(){ local n; for n in $issues_open; do gh issue close "$n" -R "$REPO" -c "i496 winsma run over" >/dev/null 2>&1; done; }
trap cleanup_issues EXIT

setup_project(){   # a clone of the sandbox repo, harness init'ed; the fleet is NOT started
  rm -rf proj; git clone -q "https://github.com/$REPO.git" proj || { say "FAIL sandbox clone failed"; return 1; }
  ( cd proj && HARNESS_INIT_NONINTERACTIVE=1 HARNESS_SESSION_BACKEND=headless HARNESS_CLI=claude HARNESS_MODE=issue-only \
    HARNESS_OWNER=VocanicZ HARNESS_REPO="$REPO" HARNESS_SESS_PREFIX=hxe496 HARNESS_POOL=1 HARNESS_POLL=20 HARNESS_PRIORITY_POLL=40 \
    HARNESS_USE_POLLER=0 HARNESS_AUTONOMOUS=true $H init </dev/null ) 2>&1 | sed 's/^/   /'
  [[ -f proj/.harness/config ]] || { say "FAIL harness init wrote no config"; return 1; }
  printf ': "${HARNESS_SWARM:=off}"\n' >> proj/.harness/config; }
# the first pool worker's pid (a number greater than 1, or nothing) and whether it is alive
worker_pid(){ local f p; for f in "$HX_U"/proj/.harness/run/worker-*.pid; do [[ -f $f ]] || continue
  p="$(head -1 "$f" | tr -dc 0-9)"; [[ "$p" =~ ^[1-9][0-9]*$ && "$p" != 1 ]] && { echo "$p"; return 0; }; done; return 1; }
# kill_pid <pid> — only a real pid (digits, greater than 1): never 0 (a process group), never 1
kill_pid(){ [[ "$1" =~ ^[1-9][0-9]*$ && "$1" != 1 ]] || return 1
  taskkill //F //T //PID "$(winpid "$1")" >/dev/null 2>&1 || kill -9 "$1" 2>/dev/null; }
# task_ran <task> — Task Scheduler has run it (Last Result 267011 = 0x41303 is "the task has not yet run")
task_ran(){ ! st /Query /TN "$1" /V /FO LIST 2>/dev/null | tr -d '\r' | grep -qE "^Last Result: +267011"; }
# start_like_task <task> <launcher> — the task's own command line (bash.exe <launcher>, exactly its <Exec>), started detached from this
# ssh session and recorded in pids. For a host where Task Scheduler cannot run an InteractiveToken task: nobody is logged on to
# a desktop, as on winsma over ssh (the task is registered and would start at the owner's next logon, #356).
start_like_task(){ local b l pid
  b="$(cygpath -w "$(command -v bash)")"; l="$(cygpath -w "$2")"
  pid="$(powershell -NoProfile -Command "(Start-Process -FilePath '$b' -ArgumentList '$l' -WindowStyle Hidden -PassThru).Id" | tr -d '\r')"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && echo "$pid" >> "$HX_DIR/pids"; echo "$pid"; }
task_diag(){ st /Query /TN "$1" /V /FO LIST 2>&1 | tr -d '\r' | grep -E "^(TaskName|Status|Last Run Time|Last Result|Run As User|Task To Run|Next Run Time|Scheduled Task State)" | sed 's/^/   task| /'; }

# ============================================================================================================================ ops
if has supervise; then
  say "######## stage supervise (sandbox CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR: no sign-in)"
  setup_project || { say "result: FAIL"; exit 1; }
  cd proj || exit 1

  say "---- supervise: --install registers the task, the task runs the supervisor, a killed worker comes back"
  printf 'INTERVAL=15\n' > "$HARNESS_HOME/supervise.conf"
  $H start 2>&1 | sed 's/^/   /'
  for i in $(seq 1 20); do wp="$(worker_pid)" && pid_alive "$wp" && break; sleep 3; done
  say "pool worker pid: ${wp:-none} (alive: $(pid_alive "${wp:-0}" && echo yes || echo no)); run dir: $(ls .harness/run 2>/dev/null | tr '\n' ' ')"
  ok "a pool worker is running after harness start" 'pid_alive "${wp:-0}"'
  $H supervise --install 2>&1 | sed 's/^/   /'
  ok "the supervise task is registered" 'st /Query /TN "$SUP" >/dev/null 2>&1'
  st /Query /TN "$SUP" /XML 2>/dev/null | tr -d '\r' | grep -E "LogonTrigger|BootTrigger" | sed 's/^/   | /'
  ok "…logon-only (no boot trigger)" '! st /Query /TN "$SUP" /XML 2>/dev/null | grep -q BootTrigger'
  say "interactive sessions on this host: $(quser 2>&1 | tr -d '\r' | tr '\n' ';' | cut -c1-200)"
  for i in $(seq 1 10); do task_ran "$SUP" && break; sleep 3; done
  if task_ran "$SUP"; then say "Task Scheduler ran the task itself"
  else say "NOTE Task Scheduler did not run the task (Last Result 267011, the task has not yet run: it is an InteractiveToken task and its user, $(whoami), has no interactive session here: see quser above); starting its own command line (bash.exe <launcher>) instead"
    supsp="$(start_like_task "$SUP" "$HARNESS_HOME/tasks/harness-supervise.sh")"; say "supervisor started as pid $supsp"; fi
  sl="$HARNESS_HOME/supervise.log"; got=0; task_diag "$SUP"
  for i in $(seq 1 40); do [[ -s "$sl" || -s "$HARNESS_HOME/tasks/harness-supervise.log" ]] && { got=1; break; }; sleep 3; done
  say "supervisor wrote a log: $got ($(wc -c < "$sl" 2>/dev/null || echo 0) bytes supervise.log)"
  task_diag "$SUP"; ls -la "$HARNESS_HOME/tasks" 2>&1 | sed 's/^/   tasks| /'; tail -n 5 "$HARNESS_HOME/tasks/harness-supervise.log" 2>&1 | sed 's/^/   launcher-log| /'
  tasklist //V //FO CSV 2>/dev/null | grep -i "bash" | cut -c1-160 | sed 's/^/   proc| /' | head
  ok "the task started the supervisor (it logged)" '(( got ))'
  [[ -s "$sl" ]] && sed 's/^/   | /' "$sl" | tail -n 8
  old="${wp:-0}"
  say "killing worker $old"
  kill_pid "$old"
  sleep 2
  ok "the worker is dead" '! pid_alive "$old"'
  # A supervisor pass takes minutes on Windows (every gh call and python3 is a process spawn), and a pass that began before the kill must end
  # first: allow the supervisor 15 minutes, and show its log as it goes.
  back=0; t0=$SECONDS; for i in $(seq 1 90); do np="$(worker_pid)" && [[ "$np" != "$old" ]] && pid_alive "$np" && { back=1; break; }
    if (( i % 12 == 0 )); then n="$(wc -l < "$sl" 2>/dev/null || echo 0)"; say "…$(( SECONDS - t0 ))s after the kill, supervise.log: $n lines"
      (( n > ${shown:-0} )) && tail -n +"$(( ${shown:-0} + 1 ))" "$sl" | cut -c1-300 | sed 's/^/   | /'; shown=$n; fi; sleep 10; done
  say "worker after the kill: ${np:-none} (alive: $(pid_alive "${np:-0}" && echo yes || echo no)), $(( SECONDS - t0 ))s after the kill"
  [[ -s "$sl" ]] && sed 's/^/   | /' "$sl" | tail -n 12
  ok "the supervisor restarted the killed worker" '(( back ))'
  $H supervise --uninstall 2>&1 | sed 's/^/   /'
  ok "supervise --uninstall removed the task" '! st /Query /TN "$SUP" >/dev/null 2>&1'
  kill_pid "${supsp:-0}"   # the launcher loop this script started by hand (the task would have been ended by --uninstall)
  $H stop --clean 2>&1 | sed 's/^/   /'

  cd ..
fi

if has ops; then
  say "######## stage ops (sandbox CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR: no sign-in)"
  setup_project || { say "result: FAIL"; exit 1; }
  cd proj || exit 1
  $H start 2>&1 | sed 's/^/   /'

  say "---- web: the dashboard is reachable"
  export HARNESS_WEB_PORT=46496 HARNESS_WEB_BIND=127.0.0.1
  port_pids(){ netstat -ano 2>/dev/null | tr -d '\r' | awk -v p=":$HARNESS_WEB_PORT" '$2 ~ p"$" && /LISTENING/ {print $NF}' | sort -u; }
  [[ -z "$(port_pids)" ]] || { say "FAIL port $HARNESS_WEB_PORT is already in use on this host: $(port_pids | tr '\n' ' ')"; fail=1; }
  ( $H web </dev/null >"$HX_DIR/web.out" 2>&1 & echo $! > "$HX_DIR/web.pid" ); wpid="$(cat "$HX_DIR/web.pid")"
  winpid "$wpid" >> "$HX_DIR/pids"
  up=0; for i in $(seq 1 20); do curl -s -o /dev/null -m 3 "http://127.0.0.1:$HARNESS_WEB_PORT/" && { up=1; break; }; sleep 2; done
  ok "harness web answers on 127.0.0.1:$HARNESS_WEB_PORT" '(( up ))'
  page="$(curl -s -m 10 "http://127.0.0.1:$HARNESS_WEB_PORT/" | head -c 400000)"
  say "page: $(printf %s "$page" | wc -c) bytes, title: $(printf %s "$page" | grep -o '<title>[^<]*' | head -1)"
  ok "the page is the Harness dashboard (HTML)" 'grep -qi "<html" <<<"$page" && grep -qi harness <<<"$page"'
  ok "an unknown path is a 404" '[[ "$(curl -s -o /dev/null -m 5 -w %{http_code} "http://127.0.0.1:$HARNESS_WEB_PORT/no-such-page")" == 404 ]]'
  js="$(curl -s -m 10 "http://127.0.0.1:$HARNESS_WEB_PORT/api/host" || true)"; say "api/host: $(printf %s "$js" | head -c 120)"
  kill_pid "$wpid"; sleep 2
  ok "the foreground server is stopped" '! curl -s -o /dev/null -m 3 "http://127.0.0.1:$HARNESS_WEB_PORT/"'
  $H web --install 2>&1 | sed 's/^/   /'
  ok "the web task is registered" 'st /Query /TN "$WEB" >/dev/null 2>&1'
  for i in $(seq 1 10); do task_ran "$WEB" && break; sleep 3; done
  task_ran "$WEB" && say "Task Scheduler ran the web task itself" || { say "NOTE Task Scheduler did not run the web task (no interactive session for $(whoami)); starting its own command line"
    websp="$(start_like_task "$WEB" "$HARNESS_HOME/tasks/harness-web.sh")"; say "web launcher started as pid $websp"; }
  up=0; for i in $(seq 1 30); do curl -s -o /dev/null -m 3 "http://127.0.0.1:$HARNESS_WEB_PORT/" && { up=1; break; }; sleep 3; done
  ok "the web task serves the dashboard" '(( up ))'
  $H web --uninstall 2>&1 | sed 's/^/   /'
  ok "web --uninstall removed the task" '! st /Query /TN "$WEB" >/dev/null 2>&1'
  kill_pid "${websp:-0}"
  # the port was free when this stage began, so whatever listens on it now is a server this script started (the launcher's child)
  for lp in $(port_pids); do say "ending the web server still listening on $HARNESS_WEB_PORT (pid $lp)"; kill_pid "$lp"; done
  sleep 3
  ok "…and the dashboard is gone" '! curl -s -o /dev/null -m 3 "http://127.0.0.1:$HARNESS_WEB_PORT/"'

  say "---- reports: stats, forecast, harness-one on an event log of fixture lanes"
  ev="$HARNESS_HOME/events.jsonl"; : > "$ev"
  for n in 1 2 3 4; do   # four past lanes of the unit, ended 1-4 hours ago (forecast wants 3 for a unit basis)
    t0="$(date -u -d "-$((n + 1)) hours" +%Y-%m-%dT%H:%M:%SZ)"; t1="$(date -u -d "-$n hours" +%Y-%m-%dT%H:%M:%SZ)"
    b='"prefix":"hxe496","repo":"'$REPO'","unit":"harness-smoke-claude","kind":"impl","issue":'$n',"session":"00000000-0000-4000-8000-00000000000'$n'"'
    echo '{"event":"launch","ts":"'$t0'",'$b',"model":"sonnet","effort":"high","ralph_iter":1}' >> "$ev"
    echo '{"event":"session_end","ts":"'$t1'",'$b',"usage":{"claude-sonnet-5-5":{"input":120,"output":4200,"cache_create":30000,"cache_read":900000}}}' >> "$ev"
  done
  # …and a transcript for each (forecast prices the phases from them): explore → test → impl → gate → ship, as test_forecast.py builds them
  "$PY" - "$CLAUDE_CONFIG_DIR" <<'PYEOF'
import json, os, sys
cfg = sys.argv[1]
steps = [("Read", {"file_path": "scripts/lib.sh"}), ("Edit", {"file_path": "test/test_widget.py"}), ("Edit", {"file_path": "scripts/widget.py"}),
         ("Bash", {"command": "bash test/run.sh"}), ("Bash", {"command": "git push -u origin issue/7 && gh pr create --fill"})]
for n in (1, 2, 3, 4):
    sid = "00000000-0000-4000-8000-00000000000%d" % n
    d = os.path.join(cfg, "projects", "-hx-proj-i%d" % n); os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, sid + ".jsonl"), "w") as f:
        for i, (tool, inp) in enumerate(steps):
            mid = "m%d-%d" % (n, i)
            f.write(json.dumps({"type": "assistant", "timestamp": "2026-11-08T10:00:00Z", "requestId": "req-" + mid,
                "message": {"id": mid, "model": "claude-sonnet-5-5",
                            "content": [{"type": "text", "text": "..."}, {"type": "tool_use", "id": mid + "-t", "name": tool, "input": inp}],
                            "usage": {"input_tokens": 0, "output_tokens": 20000 + 5000 * i}}}) + "\n")
PYEOF
  $H stats 2>&1 | sed 's/^/   | /' | head -n 20; src_rc=${PIPESTATUS[0]}
  ok "harness stats exits 0" '(( src_rc == 0 ))'
  sj="$($H stats --json 2>&1)"; src_rc=$?
  ok "harness stats --json is JSON naming the fixture lanes" '(( src_rc == 0 )) && "$PY" -c "import json,sys; d=json.loads(sys.argv[1]); assert d" "$sj" && grep -q sonnet <<<"$sj"'
  $H stats --issue 2 -R "$REPO" 2>&1 | sed 's/^/   | /' | head -n 12; src_rc=${PIPESTATUS[0]}
  ok "harness stats --issue 2 exits 0" '(( src_rc == 0 ))'
  PRD="$(gh issue create -R "$REPO" -l prd -t "i496 winsma PRD" -b "Tracking issue for #496's winsma run. Closed by cleanup." | grep -oE '[0-9]+$')"
  ISS="$(gh issue create -R "$REPO" -l ready-for-agent -t "i496 winsma: reports check" -b "$(printf 'Report check for Harness #496. Nothing is meant to claim this; closed by cleanup.\n\n## Parent\n#%s\n' "$PRD")" | grep -oE '[0-9]+$')"
  issues_open="$ISS $PRD"; say "filed PRD #$PRD and issue #$ISS"
  $H forecast "$ISS" -R "$REPO" 2>&1 | sed 's/^/   | /' | head -n 20; src_rc=${PIPESTATUS[0]}
  ok "harness forecast exits 0" '(( src_rc == 0 ))'
  fj="$($H forecast "$ISS" -R "$REPO" --json 2>&1)"; src_rc=$?
  ok "harness forecast --json is JSON" '(( src_rc == 0 )) && "$PY" -c "import json,sys; json.loads(sys.argv[1])" "$fj"'
  $H one check 2>&1 | sed 's/^/   | /'; src_rc=${PIPESTATUS[0]}
  say "harness one check rc=$src_rc (the fleet is not paused: harness one refuses, as it must)"
  ok "harness one refuses while the fleet is running" '(( src_rc != 0 ))'
  $H pause 2>&1 | sed 's/^/   /'
  $H one check 2>&1 | sed 's/^/   | /'; src_rc=${PIPESTATUS[0]}
  say "harness one check rc=$src_rc (paused)"; ok "harness one check passes once the fleet is paused" '(( src_rc == 0 ))'
  g="$($H one gate "$ISS" -R "$REPO" 2>&1)"; src_rc=$?; echo "$g" | sed 's/^/   | /' | head -n 20
  say "harness one gate rc=$src_rc"
  ok "harness one gate prints a verdict (RECOMMEND: APPROVE or DENY)" 'grep -qE "RECOMMEND: (APPROVE|DENY)" <<<"$g"'
  $H resume 2>&1 | sed 's/^/   /'
  cleanup_issues; issues_open=""

  say "---- the rest of the command surface: status, poll, release --dry-run, migrate, tier, version"
  $H --version 2>&1 | head -n 1 | sed 's/^/   | /'
  vo="$($H status 2>&1)"; src_rc=$?; echo "$vo" | head -n 12 | sed 's/^/   | /'
  ok "harness status exits 0 in a project" '(( src_rc == 0 ))'
  vo="$($H status --all 2>&1)"; src_rc=$?; echo "$vo" | head -n 8 | sed 's/^/   | /'
  ok "harness status --all (every fleet on this host) exits 0" '(( src_rc == 0 ))'
  vo="$($H poll --status 2>&1)"; src_rc=$?; echo "$vo" | head -n 8 | sed 's/^/   | /'
  ok "harness poll --status exits 0" '(( src_rc == 0 ))'
  vo="$($H poll --once 2>&1)"; src_rc=$?; echo "$vo" | head -n 8 | sed 's/^/   | /'
  ok "harness poll --once exits 0" '(( src_rc == 0 ))'
  vo="$($H migrate 2>&1)"; src_rc=$?; echo "$vo" | head -n 8 | sed 's/^/   | /'
  ok "harness migrate exits 0 on a state-only project" '(( src_rc == 0 ))'
  vo="$($H tier decide --criteria 3 --lines 40 --files 2 --subsystems 1 --json 2>&1)"; src_rc=$?; echo "$vo" | head -n 6 | sed 's/^/   | /'
  ok "harness tier decide answers JSON" '(( src_rc == 0 )) && "$PY" -c "import json,sys; json.loads(sys.argv[1])" "$vo"'
  ( cd "$HX_DIR/src" && vo="$(HARNESS_STATE_DIR_OK=1 $H release --dry-run --ref HEAD 2>&1)"; src_rc=$?; echo "$vo" | head -n 14 | sed 's/^/   | /'; echo "$src_rc" > "$HX_DIR/release.rc" )
  ok "harness release --dry-run (cuts nothing) exits 0 in a checkout" '[[ "$(cat "$HX_DIR/release.rc")" == 0 ]]'

  $H stop --clean 2>&1 | sed 's/^/   /'
  cd ..
fi

# ============================================================================================================================ inject
if has inject; then
  say "######## stage inject (sandbox CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR, a stand-in claude: no sign-in)"
  setup_project || { say "result: FAIL"; exit 1; }
  cd proj || exit 1
  say "---- inject: harness plan | prd | issue \"<brief>\" launch the injector lane"
  FK="$HX_DIR/fake"; mkdir -p "$FK"; cp "$HX_DIR"/src/test/fixtures/cli/claude/stream-json/fake-claude "$HX_DIR"/src/test/fixtures/cli/claude/stream-json/*.jsonl "$FK/"
  printf 'normal INJECT DONE\n' > "$FK/plan"; : > "$FK/calls.jsonl"
  # The lane's environment is rebuilt by the detached launcher, so FAKE_CLAUDE_DIR would not reach the stand-in: it is told its
  # directory by a three-line wrapper instead (and so the stand-in works under any launcher).
  cat > "$FK/stand-in.py" <<WRAP
import os, runpy, sys
os.environ["FAKE_CLAUDE_DIR"] = r"$(cygpath -m "$FK")"
sys.argv[0] = r"$(cygpath -m "$FK/fake-claude")"
runpy.run_path(sys.argv[0], run_name="__main__")
WRAP
  # CreateProcess cannot run the python3 shim (a bash script) and finds the Microsoft Store stub on its PATH (exit 9009): name a real python.exe
  PYEXE="$(cygpath -m "$(command -v python)")"; say "stand-in claude: $PYEXE $(cygpath -m "$FK/stand-in.py")"
  export HARNESS_CLAUDE_BIN="$PYEXE $(cygpath -m "$FK/stand-in.py")"
  n=0
  for alt in plan prd issue; do
    n=$((n + 1)); $H $alt "add a rate limiter to the widget ($alt)" 2>&1 | sed 's/^/   /'; irc=${PIPESTATUS[0]}
    ok "harness $alt exits 0" '(( irc == 0 ))'
    ran=0; for i in $(seq 1 30); do [[ "$(wc -l < "$FK/calls.jsonl")" -ge $n ]] && { ran=1; break; }; sleep 2; done
    ok "harness $alt: the injector lane ran a turn (the stand-in claude was called)" '(( ran ))'
    (( ran )) || for f in "$HARNESS_HOME"/lanes/*inject*/{state.json,runner.log,stderr.log}; do echo "   diag| $f:"; head -c 1200 "$f" 2>&1 | sed 's/^/   diag|   /'; echo; done
    ok "harness $alt: the lane's prompt points it at its task file" 'grep -q "harness-task.md" "$FK/calls.jsonl"'
    ok "harness $alt: the task file was rendered into the checkout" 'grep -q "INJECT DONE" .harness-task.md && grep -q "rate limiter to the widget ($alt)" .harness-task.md'
    for i in $(seq 1 20); do grep -q '"state": *"\(ended\|idle\)"' "$HARNESS_HOME"/lanes/*inject*/state.json 2>/dev/null && break; sleep 2; done
    say "injector lane after its turn: $(sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p' "$HARNESS_HOME"/lanes/*inject*/state.json 2>/dev/null | head -1) (a second injector is refused while one lives, so the lane is ended before the next)"
    $H stop --clean 2>&1 | sed 's/^/   /'
  done
  ls "$HARNESS_HOME/lanes" 2>/dev/null | sed 's/^/   lane: /'
  $H stop --clean 2>&1 | sed 's/^/   /'
  cd ..
fi

# ============================================================================================================================ supdiag
if has supdiag; then
  say "######## stage supdiag: what does one supervisor pass do about a killed worker?"
  setup_project || { say "result: FAIL"; exit 1; }
  cd proj || exit 1
  printf 'INTERVAL=15\n' > "$HARNESS_HOME/supervise.conf"
  $H start 2>&1 | sed 's/^/   /'
  for i in $(seq 1 20); do wp="$(worker_pid)" && pid_alive "$wp" && break; sleep 3; done
  say "worker pid ${wp:-none} alive=$(pid_alive "${wp:-0}" && echo yes || echo no)"
  ls "$HARNESS_HOME" | sed 's/^/   home: /'; ls "$HARNESS_HOME/fleets" 2>/dev/null | sed 's/^/   fleets: /'
  kill_pid "$wp"; sleep 3
  say "killed; worker alive=$(pid_alive "${wp:-0}" && echo yes || echo no)"
  # what bin/harness does before it execs the supervisor: the python3 shim first on PATH (a bare python3 here is the Microsoft Store stub)
  export PATH="$(cygpath -u "$HARNESS_HOME")/bin:$PATH"; say "python3 is now $(command -v python3)"
  cat "$HARNESS_HOME"/fleets/*.json 2>&1 | sed 's/^/   fleetrec| /'
  cat .harness/run/worker-1.pid | sed 's/^/   pidfile| /'
  timeout 240 bash -x "$HARNESS_HOME/engine/scripts/supervise.sh" --once > "$HX_DIR/once.x" 2>&1; say "supervise --once rc=$? ($(wc -l < "$HX_DIR/once.x") trace lines)"
  grep -nE "sup_fleets|sup_check_fleet|is_paused|sup_alive|dead=|sup_act|worker-|kill -0|ACT|start" "$HX_DIR/once.x" | head -n 60 | cut -c1-220 | sed 's/^/   once| /'
  tail -n 15 "$HX_DIR/once.x" | cut -c1-220 | sed 's/^/   oncetail| /'
  say "after supervise --once: worker pid $(worker_pid || echo none) alive=$(pid_alive "$(worker_pid || echo 0)" && echo yes || echo no)"
  tail -n 20 "$HARNESS_HOME/supervise.log" 2>/dev/null | sed 's/^/   suplog| /'
  say "---- the same pass with the lib.sh source's stderr and status kept (a copy of supervise.sh in the sandbox engine)"
  sed 's#source "\$SUP_ENGINE_DIR/scripts/lib.sh" >/dev/null 2>&1 || exit 0#source "$SUP_ENGINE_DIR/scripts/lib.sh" 2>"$HX_DIR/libsrc.err"; lrc=$?; echo "libsrc rc=$lrc" >> "$HX_DIR/libsrc.err"; (( lrc == 0 )) || exit 0#' \
    "$HARNESS_HOME/engine/scripts/supervise.sh" > "$HARNESS_HOME/engine/scripts/supervise_dbg.sh"
  grep -c libsrc "$HARNESS_HOME/engine/scripts/supervise_dbg.sh" | sed 's/^/   patched lines: /'
  timeout 240 bash "$HARNESS_HOME/engine/scripts/supervise_dbg.sh" --once > "$HX_DIR/once2.out" 2>&1; say "dbg pass rc=$?"
  tail -n 15 "$HX_DIR/libsrc.err" | cut -c1-250 | sed 's/^/   libsrc| /'
  tail -n 10 "$HX_DIR/once2.out" | cut -c1-250 | sed 's/^/   once2| /'
  say "after the dbg pass: worker pid $(worker_pid || echo none) alive=$(pid_alive "$(worker_pid || echo 0)" && echo yes || echo no)"
  say "---- sup_fleets' python, with its stderr visible"
  python3 - "$HARNESS_HOME/fleets" <<'PYX' 2>&1 | cat -A | head -n 12 | sed 's/^/   fl| /'
import json, os, sys
d = sys.argv[1]
print("dir", repr(d), os.path.isdir(d), os.listdir(d) if os.path.isdir(d) else None)
for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
    if name.endswith(".json"):
        try:
            print(json.load(open(os.path.join(d, name))).get("project") or "")
        except (OSError, ValueError) as e:
            print("ERR", repr(e))
PYX
  say "---- the auto-update's release lookup, as the supervisor does it (sup_rel rel_latest_tag)"
  ( export HARNESS_HOME; HARNESS_INSTALL_NOMAIN=1 source "$HARNESS_HOME/engine/install.sh"; echo "python_probe: $(python_probe 2>&1)"; echo "curl: $(curl -sSL "$HARNESS_API_URL" 2>&1 | head -c 200)"; echo "rel_latest_tag: $(rel_latest_tag 2>&1) rc=$?" ) 2>&1 | sed 's/^/   au| /'
  $H stop --clean 2>&1 | sed 's/^/   /'
  cd ..
fi

# ============================================================================================================================ live
if has live; then
  say "######## stage live (the REAL Claude sign-in, under the guard)"
  say "claude: $(command -v claude) $(claude --version 2>&1 | head -1) | gh: $(gh --version | head -1)"
  [[ -n "${CLAUDE_CONFIG_DIR:-}" ]] && say "NOTE CLAUDE_CONFIG_DIR is set ($CLAUDE_CONFIG_DIR): this stage is meant for mode base"
  printf ': "${HARNESS_USAGE_CHECKPOINT_PCT:=99}"\n' > "$HX_DIR/smoke-extra.conf"
  # the smoke drops every inherited HARNESS_*; the isolation must survive it or the fleet would write the host's real ~/.harness
  export SMOKE_KEEP_ENV="HARNESS_HOME HARNESS_BIN_DIR HARNESS_USER_SKILLS" SMOKE_EXTRA_CONFIG="$HX_DIR/smoke-extra.conf" \
    SMOKE_LOG="$HX_DIR/live-smoke.log" SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-3000}" SMOKE_REPO="$REPO"
  # the smoke's own lines go out raw (they are the log test/test_fleet_smoke.sh reads): header, host, the doctor's windows: section, every poll
  bash src/test/smoke/fleet_smoke.sh claude 2>&1; src_rc=$?
  say "fleet_smoke.sh exited $src_rc"
  ok "fleet_smoke.sh claude exits 0 (== result: PASS)" '(( src_rc == 0 )) && grep -q "== result: PASS" "$SMOKE_LOG"'
  ok "the lane was checkpointed and resumed" 'grep -q "agent-paused" "$SMOKE_LOG" && grep -q "== resume" "$SMOKE_LOG"'
  say "---- the Claude token usage of this run's lanes (harness stats, the sandbox event log)"
  $H stats 2>&1 | sed 's/^/   | /' | head -n 30
  $H stats --json 2>&1 | sed 's/^/   json| /' | head -c 3000; echo
  LI="$(sed -n 's/.*filed PRD #[0-9]* and issue #\([0-9]*\).*/\1/p' "$SMOKE_LOG" | tail -1)"
  if [[ -n "$LI" ]]; then say "---- harness stats --issue $LI and harness forecast $LI on the real lane"
    $H stats --issue "$LI" -R "$REPO" 2>&1 | sed 's/^/   | /' | head -n 20
    $H forecast "$LI" -R "$REPO" 2>&1 | sed 's/^/   | /' | head -n 20; fi
  ok "the event log of the run exists and names a session" 'grep -q session_end "$HARNESS_HOME/events.jsonl"'
  say "events: $(wc -l < "$HARNESS_HOME/events.jsonl" 2>/dev/null) lines in $HARNESS_HOME/events.jsonl"
fi
say "result: $([[ $fail == 0 ]] && echo PASS || echo FAIL)"; exit $fail
