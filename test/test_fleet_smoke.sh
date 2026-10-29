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
      if [[ "$(cat "$S/closes")" == 1 && $p -ge 2 ]]; then printf 'CLOSED\tready-for-agent\n'; else printf 'OPEN\tagent-working,ready-for-agent\n'; fi
    elif [[ "$3" == 2 && "$(cat "$S/closes")" == 1 ]]; then echo CLOSED; else echo OPEN; fi;;
  "pr list")
    [[ "$*" == *"--state merged"* && "$(cat "$S/closes")" == 1 ]] && echo "#3 Add smoke file https://x/pull/3 merged 2026-10-29T00:00:00Z"
    [[ "$*" == *"--state all"* ]] && echo "#3 MERGED"; exit 0;;
  "api repos/tester/harness-smoke-codex/branches") printf 'main\nissue/2\n';;
  *) exit 0;;
esac
EOF
  # harness: record argv + the env a real one would read; `init` writes a config like the wizard does.
  cat > "$d/bin/harness" <<'EOF'
#!/usr/bin/env bash
echo "harness $* | STATE_DIR=${STATE_DIR:-unset} HARNESS_REPO=${HARNESS_REPO:-unset} HARNESS_SESS_PREFIX=${HARNESS_SESS_PREFIX:-unset} CLI=${HARNESS_CLI:-unset}" >> "$(dirname "$0")/../calls"
[[ "$1" == --version ]] && { echo "harness test"; exit 0; }
if [[ "$1" == init ]]; then mkdir -p .harness
  printf ': "${HARNESS_CLI:=%s}"\n: "${HARNESS_REPO:=%s}"\n: "${HARNESS_SESS_PREFIX:=%s}"\n: "${HARNESS_POOL:=%s}"\n: "${HARNESS_CAP:=%s}"\n' \
    "$HARNESS_CLI" "$HARNESS_REPO" "$HARNESS_SESS_PREFIX" "$HARNESS_POOL" "$HARNESS_CAP" > .harness/config; fi
exit 0
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/tmux"
  printf '#!/usr/bin/env bash\necho "codex-cli 9.9.9"\n' > "$d/bin/codex"
  chmod +x "$d/bin/"*; }

# run_smoke [env…] — the script against the current stubs; sets RC and OUT (its log).
run_smoke(){ OUT="$D/smoke.log"
  env PATH="$D/bin:$PATH" SMOKE_HARNESS="$D/bin/harness" SMOKE_REMOTE="$D/remote.git" SMOKE_LOG="$OUT" \
      SMOKE_POLL=0 TMPDIR="$D" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
      "$@" bash "$SMOKE" codex >/dev/null 2>&1; RC=$?; }

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
assert_ok "init is given the sandbox repo, the CLI under test, pool 1 and cap 1" \
  grep -qE '^harness init \| STATE_DIR=unset HARNESS_REPO=tester/harness-smoke-codex HARNESS_SESS_PREFIX=smokecodex CLI=codex' "$CALLS"
assert_eq "$(grep -c ': "${HARNESS_\(POOL\|CAP\):=1}"' "$OUT")" 2 "the logged config has pool 1 and cap 1"
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

echo "── test/run.sh never runs it"
assert_ok "the smoke script exists under test/smoke/" test -f "$SMOKE"
assert_no "run.sh's test_* glob does not reach test/smoke/" bash -c "cd '$HERE' && for t in test_*.sh test_*.py; do echo \"\$t\"; done | grep -q '^smoke/'"
finish
