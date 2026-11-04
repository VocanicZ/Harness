#!/usr/bin/env bash
# test_fleet_smoke.sh — test/smoke/fleet_smoke.sh offline (#306): gh, harness and tmux stubbed, the
# sandbox a local bare repo. The real script talks to GitHub and runs a real CLI; this checks the
# parts that would otherwise only be seen on the fleet host — the order it drives the fleet in, that
# an inherited fleet config never reaches the sandbox, and that teardown runs on a pass AND a timeout.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
SMOKE="$HERE/smoke/fleet_smoke.sh"

ROOT="$(mktemp -d)"; tmp_track "$ROOT"

# setup_stubs <closes: 1|0> — fresh stub dir + bare sandbox remote + call log under $ROOT/<n>.
n=0
setup_stubs(){ n=$((n+1)); local d="$ROOT/$n"; mkdir -p "$d/bin" "$d/state"
  D="$d"; CALLS="$d/calls"; : > "$CALLS"
  git init -q --bare -b main "$d/remote.git"
  git clone -q "$d/remote.git" "$d/seed" 2>/dev/null
  git -C "$d/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$d/seed" push -q origin HEAD:main 2>/dev/null
  echo "$1" > "$d/state/closes"
  cat > "$d/bin/gh" <<'EOF'
#!/usr/bin/env bash
S="$(dirname "$0")/../state"; echo "gh $*" >> "$(dirname "$0")/../calls"
case "$1 $2" in
  "api user") echo tester;;
  "repo view") [[ "$*" == *defaultBranchRef* ]] && echo main; exit 0;;
  "issue create")
    c=$(( $(cat "$S/num" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$S/num"
    while (($#)); do [[ "$1" == -b ]] && printf '%s' "$2" > "$S/body.$c"; shift; done
    echo "https://github.com/tester/harness-smoke-codex/issues/$c";;
  "issue view")
    if [[ "$*" == *state,labels* ]]; then
      p=$(( $(cat "$S/polls" 2>/dev/null || echo 0) + 1 )); echo "$p" > "$S/polls"
      if [[ "$(cat "$S/closes")" == 1 && $p -ge 2 ]] || [[ "$(cat "$S/closes")" == cp && -f "$S/resumed" ]]; then printf 'CLOSED\tready-for-agent\n'
      elif [[ -f "$S/paused" && ! -f "$S/resumed" ]]; then printf 'OPEN\tagent-paused,ready-for-agent\n'
      else printf 'OPEN\tagent-working,ready-for-agent\n'; fi
    elif [[ "$*" == *"--json labels"* ]]; then [[ -f "$S/paused" && ! -f "$S/nolabel" ]] && echo "agent-paused,ready-for-agent" || echo "agent-working,ready-for-agent"
    elif [[ "$*" == *"--json comments"* ]]; then [[ -f "$S/paused" && ! -f "$S/nolabel" ]] && echo "<!-- harness-handoff issue=2 branch=issue/2 -->"; exit 0
    elif [[ "$3" == 2 && "$(cat "$S/closes")" == 1 ]]; then echo CLOSED; else echo OPEN; fi;;
  "pr list")
    [[ "$*" == *"--state merged"* && "$(cat "$S/closes")" != 0 ]] && echo "#3 Add smoke file https://x/pull/3 merged 2026-10-29T00:00:00Z"
    [[ "$*" == *"--state all"* ]] && echo "#3 MERGED"; exit 0;;
  "api repos/tester/harness-smoke-codex/branches") printf 'main\nissue/2\n';;
  *) exit 0;;
esac
EOF
  # harness: record argv + the env a real one would read; `init` writes a config like the wizard does.
  cat > "$d/bin/harness" <<'EOF'
#!/usr/bin/env bash
S="$(dirname "$0")/../state"
echo "harness $* | STATE_DIR=${STATE_DIR:-unset} HARNESS_REPO=${HARNESS_REPO:-unset} HARNESS_SESS_PREFIX=${HARNESS_SESS_PREFIX:-unset} CLI=${HARNESS_CLI:-unset} BACKEND=${HARNESS_SESSION_BACKEND:-unset}" >> "$(dirname "$0")/../calls"
# pause --force: the lane checkpoints and is ended (its runner killed, by its own pid); resume: re-dispatched.
[[ "$*" == *" pause --force"* ]] && { touch "$S/paused"; p="$(cat "$HOME/.harness/lanes/"*/pid 2>/dev/null | head -1)"
  [[ $p =~ ^[0-9]+$ ]] && kill -KILL -- "-$p" "$p" 2>/dev/null; echo "FLEET: PAUSED"; }
[[ "$*" == *" resume"* ]] && { touch "$S/resumed"; echo RESUMED; }
[[ "$1" == --version ]] && { echo "harness test"; exit 0; }
if [[ "$1" == init ]]; then mkdir -p .harness
  printf ': "${HARNESS_CLI:=%s}"\n: "${HARNESS_REPO:=%s}"\n: "${HARNESS_SESS_PREFIX:=%s}"\n: "${HARNESS_POOL:=%s}"\n' \
    "$HARNESS_CLI" "$HARNESS_REPO" "$HARNESS_SESS_PREFIX" "$HARNESS_POOL" > .harness/config; fi
exit 0
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/tmux"
  printf '#!/usr/bin/env bash\necho "codex-cli 9.9.9"\n' > "$d/bin/codex"
  printf '#!/usr/bin/env bash\necho "9.9.9 (Claude Code)"\n' > "$d/bin/claude"
  chmod +x "$d/bin/"*; }

# run_smoke [env…] — the script against the current stubs; sets RC and OUT (its log).
run_smoke(){ run_smoke_cli codex "$@"; }
run_smoke_cli(){ local cli="$1"; shift; OUT="$D/smoke.log"
  env PATH="$D/bin:$PATH" SMOKE_HARNESS="$D/bin/harness" SMOKE_REMOTE="$D/remote.git" SMOKE_LOG="$OUT" \
      SMOKE_POLL=0 TMPDIR="$D" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
      "$@" bash "$SMOKE" "$cli" >/dev/null 2>&1; RC=$?; }

# fake_lane <name> — a live headless lane on the host's lane root as the smoke sees it ($HOME=$D):
# started by the engine's own sess_start, its runner a shell that wrote a busy state.json. Its pid is
# tracked and killed at exit, by pid.
LANE_PIDS=()
fake_lane(){ local p
  ( export HARNESS_SESSION_BACKEND=headless HARNESS_HEADLESS_DIR="$D/.harness/lanes"; source "$HERE/../scripts/session/dispatch.sh"
    sess_start "$1" "$D" bash -c 'printf "{\"state\": \"busy\", \"turn\": 1}" > "$HARNESS_LANE_DIR/state.json"; while :; do sleep 1; done' ) >/dev/null 2>&1
  p="$(cat "$D/.harness/lanes/$1/pid" 2>/dev/null)"; [[ $p =~ ^[0-9]+$ ]] && LANE_PIDS+=("$p"); }
kill_lanes(){ local p; for p in ${LANE_PIDS[@]+"${LANE_PIDS[@]}"}; do kill -KILL -- "-$p" "$p" 2>/dev/null; done; }
trap kill_lanes EXIT

# harness_verbs — the subcommand of each harness call, in order: init runs in the clone (the wizard's
# own cwd discovery), every later call names the sandbox's state dir. --version is only the header.
harness_verbs(){ awk '$1 != "harness" { next } $2 == "--state-dir" { $2 = ""; $3 = "" } { v = $0; sub(/ \|.*/, "", v); sub(/^harness +/, "", v); print v }' "$CALLS" \
  | grep -v -- '^--version' | sed 's/ -R .*//; s/ --issue.*//' | paste -sd' ' -; }

echo "── usage"
bash "$SMOKE" >/dev/null 2>&1; assert_eq "$?" 2 "no CLI argument exits 2"
bash "$SMOKE" nosuchcli >/dev/null 2>&1; assert_eq "$?" 2 "a CLI with no adapter exits 2"

echo "── a pass: the fleet's own path, in order, then teardown"
setup_stubs 1
run_smoke STATE_DIR=/some/live/fleet/.harness HARNESS_REPO=evil/live HARNESS_SESS_PREFIX=hz HARNESS_CLI=claude
assert_eq "$RC" 0 "issue closed through a merged PR exits 0"
assert_eq "$(harness_verbs)" "init setup start stats stop --clean" "init → setup → start → stop --clean, each on the sandbox's own state dir"
assert_no "no harness call inherits the live fleet's STATE_DIR / HARNESS_REPO" grep -qE 'STATE_DIR=/some|HARNESS_REPO=evil' "$CALLS"
assert_ok "init is given the sandbox repo, the CLI under test, pool 1" \
  grep -qE '^harness init \| STATE_DIR=unset HARNESS_REPO=tester/harness-smoke-codex HARNESS_SESS_PREFIX=smokecodex CLI=codex' "$CALLS"
assert_eq "$(grep -c ': "${HARNESS_POOL:=1}"' "$OUT")" 1 "the logged config has pool 1"
assert_eq "$(grep -c 'HARNESS_CAP' "$OUT")" 0 "...and no cap (#469)"
assert_ok "the sandbox verifies locally, not on swarm" grep -qF ': "${HARNESS_SWARM:=off}"' "$OUT"
assert_ok "the PRD is filed with the prd label" grep -qE '^gh issue create .*-l prd ' "$CALLS"
assert_ok "the task is filed ready-for-agent" grep -qE '^gh issue create .*-l ready-for-agent ' "$CALLS"
assert_ok "the task's ## Parent names the PRD (#1)" grep -qzE '## Parent'$'\n''#1' "$D/state/body.2"
assert_ok "the log is headed with the CLI's version" grep -qE '== fleet smoke \| cli=codex \| codex-cli 9\.9\.9 \| 20[0-9]{2}-' "$OUT"
assert_ok "the log names the merged PR" grep -qF 'merged PR: #3 Add smoke file' "$OUT"
assert_ok "teardown closes the PRD the run filed" grep -qE '^gh issue close 1 ' "$CALLS"
assert_no "teardown leaves the closed task alone" grep -qE '^gh issue close 2 ' "$CALLS"
assert_ok "teardown deletes the run's branch" grep -qF 'gh api -X DELETE repos/tester/harness-smoke-codex/git/refs/heads/issue/2' "$CALLS"
assert_no "teardown never deletes the default branch" grep -qF 'git/refs/heads/main' "$CALLS"
assert_no "teardown keeps the repo unless asked" grep -qF 'gh repo delete' "$CALLS"
assert_eq "$(ls -d "$D"/harness-smoke-codex.* 2>/dev/null | wc -l)" 0 "teardown removes the clone"
assert_ok "the sandbox was seeded with a test command" bash -c "git -C '$D/seed' pull -q origin main 2>/dev/null; test -x '$D/seed/test/run.sh' && grep -q '^\.harness/$' '$D/seed/.gitignore'"
assert_ok "the fleet's own session end is waited for and logged" grep -qF 'fleet sessions after close: none (ended by the fleet)' "$OUT"
assert_ok "the result line says PASS" grep -qE '== result: PASS' "$OUT"

echo "── a timeout: still torn down, exits 1"
setup_stubs 0
run_smoke SMOKE_TIMEOUT=1
assert_eq "$RC" 1 "an issue that never closes exits 1"
assert_eq "$(harness_verbs)" "init setup start status stop --clean" "a timeout still stops the fleet with --clean"
assert_ok "teardown closes the open task" grep -qE '^gh issue close 2 ' "$CALLS"
assert_ok "teardown closes the open PRD" grep -qE '^gh issue close 1 ' "$CALLS"
assert_ok "the result line says FAIL" grep -qE '== result: FAIL \(rc 1\)' "$OUT"

echo "── a session the fleet never ends: waited for SMOKE_REAP_WAIT, then named"
setup_stubs 1
printf '#!/usr/bin/env bash\n[[ "$1" == ls ]] && echo smokecodex-main-i2\nexit 0\n' > "$D/bin/tmux"
run_smoke SMOKE_REAP_WAIT=0
assert_eq "$RC" 0 "a lingering session does not fail a merged run"
assert_ok "the lingering session is named in the log" grep -qF 'fleet sessions after close: smokecodex-main-i2 still live after 0s' "$OUT"

echo "── SMOKE_DELETE_REPO=1 deletes the sandbox"
setup_stubs 1
run_smoke SMOKE_DELETE_REPO=1
assert_ok "the repo is deleted at teardown" grep -qF 'gh repo delete tester/harness-smoke-codex --yes' "$CALLS"

echo "── the tmux path takes no checkpoint and keeps the default backend"
setup_stubs 1
run_smoke
assert_eq "$RC" 0 "a tmux run passes as before"
assert_no "a tmux run never pauses or resumes the fleet" grep -qE '^harness .* (pause|resume)' "$CALLS"
assert_ok "init is given the tmux backend (the fleet default)" grep -qE '^harness init .*BACKEND=tmux' "$CALLS"
assert_no "the tmux sandbox config keeps the default stuck-turn limit" grep -qF 'HARNESS_TURN_MAX' "$OUT"
assert_no "the tmux log has no backend line" grep -qF '== session backend' "$OUT"
assert_no "the tmux task has no wait step" grep -qF 'sleep' "$D/state/body.2"

echo "── an unknown backend is a usage error"
setup_stubs 1
run_smoke SMOKE_BACKEND=nosuch
assert_eq "$RC" 2 "SMOKE_BACKEND=nosuch exits 2"

echo "── headless: a lane checkpointed mid-session, resumed, and the issue still closes"
setup_stubs cp
fake_lane smokeclaude-main-i2
run_smoke_cli claude HOME="$D" SMOKE_BACKEND=headless SMOKE_CHECKPOINT_AFTER=0
assert_eq "$RC" 0 "the issue closes through a merged PR after its checkpoint and resume"
assert_eq "$(harness_verbs)" "init setup start pause --force resume stats stop --clean" \
  "init → setup → start → pause --force → resume → stats → stop --clean"
assert_ok "init writes the headless backend" grep -qE '^harness init \| .*CLI=claude BACKEND=headless' "$CALLS"
assert_ok "the log names the backend and the checkpoint" grep -qF '== session backend headless | checkpoint+resume on, 0s into the lane' "$OUT"
assert_ok "the sandbox lets the stuck-turn interrupt deliver the checkpoint" grep -qF ': "${HARNESS_TURN_MAX:=120}"' "$OUT"
assert_ok "the sandbox gives the checkpoint time to land" grep -qF ': "${HARNESS_PAUSE_GRACE:=900}"' "$OUT"
assert_ok "the live headless lane is seen through the session seam" grep -qE 'sessions=smokeclaude-main-i2 ' "$OUT"
assert_ok "the checkpoint is logged with the lane it paused" grep -qE '== checkpoint: harness pause --force \(lane smokeclaude-main-i2 up' "$OUT"
assert_ok "after the checkpoint the issue is agent-paused and the lane ended" grep -qF 'after checkpoint: labels=agent-paused,ready-for-agent sessions=none' "$OUT"
assert_ok "the handoff comment is found" grep -qF 'handoff comment posted on #2' "$OUT"
assert_ok "the resume is logged" grep -qF '== resume: harness resume' "$OUT"
assert_ok "the task opens with a wait, so the lane is still mid-task at the checkpoint" grep -qF 'First run `sleep 240`' "$D/state/body.2"
assert_ok "the result line says PASS" grep -qE '== result: PASS' "$OUT"
kill_lanes

echo "── headless: a checkpoint that never confirms fails the run"
setup_stubs cp
touch "$D/state/nolabel"
fake_lane smokeclaude-main-i2
run_smoke_cli claude HOME="$D" SMOKE_BACKEND=headless SMOKE_CHECKPOINT_AFTER=0
assert_eq "$RC" 1 "an issue not agent-paused after pause --force exits 1"
assert_ok "the unconfirmed checkpoint is named" grep -qF 'checkpoint not confirmed: issue #2 is not agent-paused' "$OUT"
assert_no "no resume after an unconfirmed checkpoint" grep -qE '^harness .* resume' "$CALLS"
kill_lanes

echo "── headless: an issue that closes before the checkpoint fails the run"
setup_stubs 1
fake_lane smokeclaude-main-i2
run_smoke_cli claude HOME="$D" SMOKE_BACKEND=headless SMOKE_CHECKPOINT_AFTER=9999 SMOKE_REAP_WAIT=0
assert_eq "$RC" 1 "a run that never checkpointed exits 1"
assert_ok "the missing checkpoint is named" grep -qF 'closed before its lane had run 9999s — no checkpoint was exercised' "$OUT"
assert_ok "teardown shows the lane's drawn screen" grep -qF -- '-- final pane of smokeclaude-main-i2' "$OUT"
kill_lanes

echo "── every run's log names its host"
setup_stubs 1
run_smoke
assert_ok "a Linux run's header names the posix host, its bash and python3" \
  grep -qE '== host posix \| [^|]+ \| bash [0-9][^ ]* \| python3 3\.[0-9]+' "$OUT"

echo "── native Windows (#357): argument handling"
# Usage errors come before any GitHub call. Run them behind a gh / claude / tmux that only fail, so a
# regression that lets one through fails here instead of starting a real fleet against GitHub.
mkdir -p "$ROOT/nogh"; for b in gh claude codex tmux; do printf '#!/usr/bin/env bash\nexit 1\n' > "$ROOT/nogh/$b"; chmod +x "$ROOT/nogh/$b"; done
NOGH="$ROOT/nogh:$PATH"
PATH="$NOGH" SMOKE_PLATFORM=windows SMOKE_BACKEND=tmux bash "$SMOKE" claude >"$ROOT/w.out" 2>&1; assert_eq "$?" 2 "Windows + SMOKE_BACKEND=tmux exits 2"
assert_ok "...saying Windows has no tmux" grep -qF 'native Windows has no tmux — only SMOKE_BACKEND=headless runs there' "$ROOT/w.out"
# every real CLI has a headless runner (#486 was the last): the tmux-only ones here are a made-up CLI's, in a copy of the tree
TMUX_ONLY="$ROOT/tmux-only"; tmux_only_tree "$TMUX_ONLY"; SMOKE_TO="$TMUX_ONLY/test/smoke/fleet_smoke.sh"
PATH="$NOGH" SMOKE_PLATFORM=windows bash "$SMOKE_TO" fakecli >"$ROOT/w.out" 2>&1; assert_eq "$?" 2 "Windows + a tmux-only CLI exits 2"
assert_ok "...naming the CLI tmux-only and the headless CLIs" grep -qF "'fakecli' is tmux-only — the headless backend runs agy claude codex copilot hermes openclaw opencode lanes only" "$ROOT/w.out"
PATH="$NOGH" SMOKE_BACKEND=headless bash "$SMOKE_TO" fakecli >/dev/null 2>&1; assert_eq "$?" 2 "headless + a tmux-only CLI exits 2 on Linux too"
PATH="$NOGH" SMOKE_PLATFORM=dos bash "$SMOKE" claude >"$ROOT/w.out" 2>&1; assert_eq "$?" 2 "an unknown SMOKE_PLATFORM exits 2"
assert_ok "...naming the two it takes" grep -qF "SMOKE_PLATFORM must be windows or posix, not 'dos'" "$ROOT/w.out"

echo "── native Windows: headless by default, the host and doctor in the log"
setup_stubs 1
run_smoke_cli claude HOME="$D" SMOKE_PLATFORM=windows SMOKE_CHECKPOINT=0 SMOKE_LOG= SMOKE_REAP_WAIT=0
WLOG="$(ls "$D"/harness-smoke/claude-headless-windows-*.log 2>/dev/null | head -1)"
assert_eq "$RC" 0 "a Windows run passes"
assert_ok "the default log is named claude-headless-windows-<stamp>.log" test -n "$WLOG"
OUT="${WLOG:-/dev/null}"
assert_ok "with no SMOKE_BACKEND, init is given the headless backend" grep -qE '^harness init \| .*CLI=claude BACKEND=headless' "$CALLS"
assert_eq "$(harness_verbs)" "init setup doctor start stats stop --clean" "init → setup → doctor → start → stats → stop --clean"
assert_ok "the header's first line is the CLI's version and the date" grep -qE '== fleet smoke \| cli=claude \| 9\.9\.9 \(Claude Code\) \| 20[0-9]{2}-' "$OUT"
assert_ok "the header names the windows host" grep -qE '== host windows \| [^|]+ \| bash [0-9][^ ]* \| python3 ' "$OUT"
assert_ok "the header names the headless backend" grep -qF '== session backend headless | checkpoint+resume off' "$OUT"
assert_ok "doctor's exit is logged" grep -qE 'doctor exit [0-9]+' "$OUT"
assert_ok "the result line says PASS" grep -qE '== result: PASS' "$OUT"
setup_stubs 1
run_smoke
assert_no "a Linux run never runs doctor" grep -qE '^harness .*doctor' "$CALLS"

echo "── native Windows: the cmd wrapper"
CMD="$HERE/smoke/fleet_smoke.cmd"
assert_ok "test/smoke/fleet_smoke.cmd exists" test -f "$CMD"
assert_eq "$(grep -c $'\r$' "$CMD")" "$(wc -l < "$CMD")" "every line of it is CRLF (cmd.exe's line ending)"
assert_eq "$(gitattr_eol "$HERE/.." test/smoke/fleet_smoke.cmd)" crlf ".gitattributes checks *.cmd out CRLF"
assert_eq "$(gitattr_eol "$HERE/.." test/smoke/fleet_smoke.sh)" lf "...and the script itself LF"
c="$(tr -d '\r' < "$CMD")"
assert_ok "it defaults to Git's bin\\bash.exe by path" grep -qxF 'if not defined BASH_EXE set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"' <<<"$c"
assert_ok "HARNESS_BASH_EXE overrides it" grep -qxF 'set "BASH_EXE=%HARNESS_BASH_EXE%"' <<<"$c"
assert_ok "a missing bash.exe exits 2" grep -qxF 'if not exist "%BASH_EXE%" exit /b 2' <<<"$c"
assert_ok "it defaults SMOKE_BACKEND to headless" grep -qxF 'if not defined SMOKE_BACKEND set "SMOKE_BACKEND=headless"' <<<"$c"
assert_ok "it hands bash the script beside it with forward slashes (dirname reads no backslash)" \
  bash -c 'grep -qxF "set \"SCRIPT=%~dp0fleet_smoke.sh\"" <<<"$1" && grep -qxF "set \"SCRIPT=%SCRIPT:\\=/%\"" <<<"$1"' _ "$c"
assert_ok "it runs that script through \"%BASH_EXE%\", passing every argument, and exits with its status" \
  bash -c 'grep -qxF "\"%BASH_EXE%\" -l \"%SCRIPT%\" %*" <<<"$1" && grep -qxF "exit /b %ERRORLEVEL%" <<<"$1"' _ "$c"
assert_no "it never runs a bare bash (on the cmd PATH that is WSL's)" grep -qiE '^(bash|bash\.exe|call bash)( |$)' <<<"$c"

echo "── native Windows: the runbook and the README"
RB="$HERE/../docs/windows-smoke.md"
assert_ok "docs/windows-smoke.md exists" test -f "$RB"
for want in 'winget install --id Git.Git' 'winget install --id Python.Python.3' 'winget install --id GitHub.cli' \
    'install.ps1' 'Developer Mode' '"C:\Program Files\Git\bin\bash.exe"' 'WSL' 'uname -s' 'gh auth login' \
    'bash install.sh' 'bash test/smoke/fleet_smoke.sh claude' 'test\smoke\fleet_smoke.cmd claude' \
    'claude-headless-windows-' 'test/smoke/logs/' '#358' 'SMOKE_EXTRA_CONFIG' 'HARNESS_BASH_EXE' 'Store stub' \
    'git config --global user.email' 'GIT_AUTHOR_NAME'; do
  assert_ok "the runbook covers: $want" grep -qF -- "$want" "$RB"
done
RM="$HERE/../README.md"
inst="$(sed -n '/^## Install$/,/^## Quick start$/p' "$RM")"
assert_ok "README Install states native Windows support" grep -qF 'native Windows' <<<"$inst"
assert_ok "...on the headless backend only" grep -qF 'headless session backend only' <<<"$inst"
assert_ok "...with claude lanes only" grep -qF '`claude` lanes only' <<<"$inst"
assert_ok "...linking the runbook" grep -qF '](docs/windows-smoke.md)' <<<"$inst"
assert_no "...and no longer sends Windows users to WSL2 only" grep -qF 'on Windows, run it inside WSL2' <<<"$inst"
assert_ok "the reference's Native Windows section links the runbook" \
  bash -c "sed -n '/^### Native Windows/,/^### /p' '$HERE/../docs/reference.md' | grep -qF '](windows-smoke.md)'"

echo "── the recorded headless run (#354) is committed and shows its checkpoint and resume"
REC="$(ls "$HERE"/smoke/logs/claude-headless-2*.log 2>/dev/null | tail -1)"   # the Linux run: not a -windows- one (#357)
assert_ok "a claude headless smoke log is committed under test/smoke/logs/" test -n "$REC"
assert_ok "it is headed with the claude version and the date" grep -qE '== fleet smoke \| cli=claude \| [0-9.]+ \(Claude Code\) \| 20[0-9]{2}-' "${REC:-/dev/null}"
assert_ok "it ran on the headless backend" grep -qF '== session backend headless | checkpoint+resume on' "${REC:-/dev/null}"
assert_ok "it shows the checkpoint confirmed" grep -qE 'after checkpoint: labels=[^ ]*agent-paused' "${REC:-/dev/null}"
assert_ok "it shows the resume" grep -qF '== resume: harness resume' "${REC:-/dev/null}"
assert_ok "it shows the resumed lane carrying on its session" grep -qF 'carries on agent session' "${REC:-/dev/null}"
assert_ok "it passed" grep -qE '== result: PASS' "${REC:-/dev/null}"

echo "── the recorded native-Windows run (#358) is committed and shows one issue end to end"
WREC="$(ls "$HERE"/smoke/logs/claude-headless-windows-2*.log 2>/dev/null | tail -1)"
assert_ok "a claude headless Windows smoke log is committed under test/smoke/logs/" test -n "$WREC"
assert_ok "it is headed with the claude version and the date" grep -qE '== fleet smoke \| cli=claude \| [0-9.]+ \(Claude Code\) \| 20[0-9]{2}-' "${WREC:-/dev/null}"
assert_ok "it is headed with the Windows version and runtime (Git Bash, a real python3)" \
  grep -qE '== host windows \| MINGW64_NT-10\.0-[0-9]+ .* \| bash [0-9.]+.* \| python3 3\.[0-9]+' "${WREC:-/dev/null}"
assert_ok "it ran on the headless backend" grep -qF '== session backend headless | checkpoint+resume on' "${WREC:-/dev/null}"
assert_ok "its doctor saw a working python3 on Windows" grep -qE '^ +python3: 3\.[0-9.]+ .* ✓' "${WREC:-/dev/null}"
assert_ok "its doctor passed" grep -qF 'doctor exit 0' "${WREC:-/dev/null}"
assert_ok "it shows the checkpoint confirmed" grep -qE 'after checkpoint: labels=[^ ]*agent-paused' "${WREC:-/dev/null}"
assert_ok "it shows the resume" grep -qF '== resume: harness resume' "${WREC:-/dev/null}"
assert_ok "it shows the resumed lane carrying on its session" grep -qF 'carries on agent session' "${WREC:-/dev/null}"
assert_ok "it shows the issue closed through a merged PR" grep -qE 'merged PR: #[0-9]+ .*merged 20[0-9]{2}-' "${WREC:-/dev/null}"
assert_ok "it passed" grep -qE '== result: PASS' "${WREC:-/dev/null}"

echo "── test/run.sh never runs it"
assert_ok "the smoke script exists under test/smoke/" test -f "$SMOKE"
assert_no "run.sh's test_* glob does not reach test/smoke/" bash -c "cd '$HERE' && for t in test_*.sh test_*.py; do echo \"\$t\"; done | grep -q '^smoke/'"
finish
