#!/usr/bin/env bash
# test_engine_roll.sh — #602 (PRD #587): a running fleet picks up the PRD's engine changes through the normal engine roll,
# with no manual step. The roll is fleet_roll (scripts/roll.sh), run by `harness update` / `harness start` / supervise.
#   1. a worker on a git-checkout engine that `update` fast-forwarded IN PLACE (same ENGINE_DIR, new scripts) is rolled onto
#      the new loop by the roll itself; a second roll changes nothing
#   2. a worker that predates the code stamp (the one-time migration) is rolled once on a git checkout, never on a release
#   3. a worker on an older release dir is rolled onto the new release's loop
#   4. lanes launched by the rolled engine use the lean-context flags
#   5. `harness update` no longer tells the operator to pause, stop and start by hand
#   6. #643: a live worker of the retired unit-claim loop, named only by a 2-field claims/<unit>.claim (no pid file),
#      is stopped by the roll and its claim removed; one the roll cannot verify is a WARN, never a kill
# The worker is the REAL pool.sh launching a stand-in pool-worker.sh whose "loop" is a version string, so what the test
# watches is which loop the relaunched worker runs. No tmux, no claude, no gh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset ENGINE_DIR STATE_DIR   # a live lane exports its own engine; this test names every engine it runs
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"
REAL="$(cd "$HERE/.." && pwd)"
ROOT="$(mktemp -d)"; tmp_track "$ROOT"
pin_host_home "$ROOT/host"
export HARNESS_EVENTS_FILE="$ROOT/events.jsonl" HARNESS_FLEETS_DIR="$ROOT/host/fleets" HARNESS_GH_RATE_GUARD=0
mkdir -p "$HARNESS_FLEETS_DIR"

# mk_engine <dir> <loop> [git] — a copy of the real engine whose pool-worker.sh is a stand-in loop named <loop>
mk_engine(){ local d="$1"; mkdir -p "$d"; cp -r "$REAL/scripts" "$REAL/bin" "$REAL/prompts" "$d/"
  [[ -f $REAL/VERSION ]] && cp "$REAL/VERSION" "$d/"
  [[ "${3:-}" == git ]] && mkdir -p "$d/.git"
  set_loop "$d" "$2"
  # stand-in for `harness start`: the REAL pool.sh, from this engine, exactly as start.sh runs it
  cat > "$d/bin/harness" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --state-dir && "$3" == start ]] || exit 9
ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"; export ENGINE_DIR
export STATE_DIR="$2" HARNESS_HOME="${HARNESS_HOME:?}"
echo "start $2 $ENGINE_DIR" >> "$START_LOG"
exec bash "$ENGINE_DIR/scripts/pool.sh"
STUB
  chmod +x "$d/bin/harness"; }
# set_loop <engine> <loop> — what an update brings: a different worker loop in the same file
set_loop(){ printf '#!/usr/bin/env bash\necho "loop %s of $ENGINE_DIR"\nexec sleep 600\n' "$2" > "$1/scripts/pool-worker.sh"; }
START_LOG="$ROOT/start.log"; : > "$START_LOG"; export START_LOG

fleet(){ local d="$ROOT/$1/.harness"; mkdir -p "$d/run" "$d/checkouts"
  printf ': "${HARNESS_UNIT:=main}"\n: "${HARNESS_REPO:=acme/%s}"\n: "${HARNESS_POOL:=1}"\n: "${HARNESS_SESS_PREFIX:=%s}"\n' "$1" "$1" > "$d/config"
  printf '{"prefix": "x", "project": "%s", "run_dir": "%s/run", "slugs": [], "started_at": 1}' "$d" "$d" > "$HARNESS_FLEETS_DIR/$1.json"
  echo "$d"; }
# launch <engine> <fleet> — the fleet's worker on that engine, started the way `harness start` starts it
launch(){ ( unset_inherited_config; HARNESS_HOME="$ROOT/host" "$1/bin/harness" --state-dir "$2" start ) >/dev/null 2>&1; sleep 0.3; }
roll(){ # <engine> — `harness update`'s roll, from that engine
  ( unset_inherited_config; unset STATE_DIR; ENGINE_DIR="$1" HARNESS_HOME="$ROOT/host" bash "$1/scripts/fleet-migrate.sh" --all ) 2>&1; sleep 0.3; }
wpid(){ cat "$1/run/worker-1.pid"; }
alive(){ kill -0 "$1" 2>/dev/null; }
wlog(){ cat "$1/run/worker-1.log" 2>/dev/null; }
stampof(){ ( source "$REAL/scripts/portable.sh"; proc_env "$1" HARNESS_ENGINE_STAMP ); }

echo "=== 1. git-checkout engine fast-forwarded in place: the roll moves the worker onto the new loop ==="
ENG="$ROOT/engine-git"; mk_engine "$ENG" v1 git
F1="$(fleet one)"; launch "$ENG" "$F1"
P1="$(wpid "$F1")"
assert_ok "the worker started on loop v1" grep -q '^loop v1 ' <<<"$(wlog "$F1")"
assert_ok "the pool launched it with a code stamp" test -n "$(stampof "$P1")"
out="$(roll "$ENG")"
assert_ok "no change on the engine: the roll leaves the worker alone" alive "$P1"
assert_eq "$(wpid "$F1")" "$P1" "...same pid"
set_loop "$ENG" v2      # `update` ff-pulled a new pool-worker.sh into the SAME directory
out="$(roll "$ENG")"
assert_no "the old worker is gone" alive "$P1"
assert_ok "a new worker is up" alive "$(wpid "$F1")"
assert_ok "...and it runs loop v2, started by the roll with no manual step" grep -q '^loop v2 ' <<<"$(wlog "$F1")"
P2="$(wpid "$F1")"
out="$(roll "$ENG")"
assert_eq "$(wpid "$F1")" "$P2" "a second roll changes nothing"
assert_ok "...the worker is still running" alive "$P2"
assert_eq "$(grep -c "^start $F1 " "$START_LOG")" "2" "harness start ran once for the first launch and once for the roll"
kill "$P2" 2>/dev/null

echo "=== 2. a worker that predates the stamp: rolled once on a git checkout, left alone on a release ==="
F2="$(fleet two)"
( ENGINE_DIR="$ENG" nohup sleep 600 >/dev/null 2>&1 9>&- & echo $! > "$F2/run/worker-1.pid" )
sleep 0.2; PRE="$(wpid "$F2")"
out="$(roll "$ENG")"
assert_no "git checkout: the unstamped worker is rolled (the one-time migration is the roll's own)" alive "$PRE"
assert_ok "...onto a stamped worker" test -n "$(stampof "$(wpid "$F2")")"
kill "$(wpid "$F2")" 2>/dev/null
REL="$ROOT/engine-rel"; mk_engine "$REL" v2
F3="$(fleet three)"
( ENGINE_DIR="$REL" nohup sleep 600 >/dev/null 2>&1 9>&- & echo $! > "$F3/run/worker-1.pid" )
sleep 0.2; RP="$(wpid "$F3")"
out="$(roll "$REL")"
assert_ok "release dir: an unstamped worker on this very release is left alone (its code cannot have changed)" alive "$RP"
kill "$RP" 2>/dev/null

echo "=== 3. a worker on an older release is rolled onto the new release's loop ==="
OLDREL="$ROOT/engine-old"; mk_engine "$OLDREL" v1
NEWREL="$ROOT/engine-new"; mk_engine "$NEWREL" v2
F4="$(fleet four)"; launch "$OLDREL" "$F4"; P4="$(wpid "$F4")"
assert_ok "started on the old release's loop" grep -q '^loop v1 ' <<<"$(wlog "$F4")"
out="$(roll "$NEWREL")"
assert_no "the old-release worker is gone" alive "$P4"
assert_ok "the new one runs the new release's loop" grep -q "^loop v2 of $NEWREL" <<<"$(wlog "$F4")"
kill "$(wpid "$F4")" 2>/dev/null

echo "=== 4. lanes launched by the rolled engine use the lean-context flags ==="
WD="$ROOT/wd"; git init -q "$WD"; printf 'GOAL: x\n' > "$WD/.harness-task.md"
line="$( unset_inherited_config; export HOME="$ROOT/home" CLAUDE_CONFIG_DIR="$ROOT/cfg" HARNESS_AUTONOMOUS=true HARNESS_BOOTSTRAP_PROMPT="Read .harness-task.md"
  RL="$CLAUDE_CONFIG_DIR/plugins/cache/mk/ralph-loop/1.0.1"; mkdir -p "$HOME" "$RL"   # the plugin a lean lane finds its goal loop in
  printf '{"version": 2, "plugins": {"ralph-loop@mk": [{"scope": "user", "installPath": "%s"}]}}' "$RL" > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
  unset CLAUDE_FLAGS HARNESS_CLAUDE_LEAN
  export STATE_DIR="$ROOT/four/.harness" HARNESS_HOME="$ROOT/host" ENGINE_DIR="$NEWREL"
  source "$NEWREL/scripts/lib.sh"; cli_load claude && cli_launch "$WD" 11111111-2222-3333-4444-555555555555 sonnet high )"
assert_ok "the new engine's launch line has --setting-sources project,local" grep -qF -- ' --setting-sources project,local ' <<<"$line"
assert_ok "...and no user MCP servers" grep -qF -- ' --strict-mcp-config ' <<<"$line"

echo "=== 5. harness update tells the operator to do nothing by hand ==="
assert_no "update.sh has no 'pause → stop → start --recover' instruction" grep -q 'harness pause  →' "$REAL/update.sh"
assert_no "...nor says live workers keep the old logic" grep -q 'keep the OLD engine logic' "$REAL/update.sh"
echo "=== 6. #643: a live legacy unit-claim worker that no pid file names is rolled, not ignored ==="
LREL="$ROOT/engine-legacy"; mk_engine "$LREL" v1
F6="$(fleet six)"; mkdir -p "$F6/run/claims"
( ENGINE_DIR="$NEWREL" nohup sleep 600 >/dev/null 2>&1 9>&- & echo $! > "$F6/run/worker-1.pid" )   # the current worker, on the target engine
( ENGINE_DIR="$LREL" nohup sleep 600 >/dev/null 2>&1 9>&- & echo $! > "$ROOT/legacy.pid" )         # the v0.5.0 loop: no pid file
sleep 0.2; CUR="$(wpid "$F6")"; LEG="$(cat "$ROOT/legacy.pid")"
printf '1 %s\n' "$LEG" > "$F6/run/claims/main.claim"                                                # the retired <unit>.claim format
out="$(roll "$NEWREL")"
assert_no "the legacy worker was stopped" alive "$LEG"
assert_no "...its claim file was removed" test -f "$F6/run/claims/main.claim"
assert_ok "...and the roll logged it" grep -q "killed legacy unit-claim worker pid $LEG" <<<"$out"
assert_ok "the current worker on the target engine was left alone" alive "$CUR"
kill "$CUR" 2>/dev/null
echo "-- a legacy claim whose process cannot be verified is a WARN, never a kill"
F7="$(fleet seven)"; mkdir -p "$F7/run/claims"
( ENGINE_DIR="$NEWREL" nohup sleep 600 >/dev/null 2>&1 9>&- & echo $! > "$F7/run/worker-1.pid" )
( env -u ENGINE_DIR nohup sleep 600 >/dev/null 2>&1 9>&- & echo $! > "$ROOT/stranger.pid" )          # no ENGINE_DIR, not a Harness worker
sleep 0.2; CUR7="$(wpid "$F7")"; STR="$(cat "$ROOT/stranger.pid")"
printf '1 %s\n' "$STR" > "$F7/run/claims/main.claim"
out="$(roll "$NEWREL")"
assert_ok "an unverifiable legacy process is still alive" alive "$STR"
assert_ok "...its claim is kept" test -f "$F7/run/claims/main.claim"
assert_ok "...and a WARN says why" grep -q "WARN roll: legacy claim main.claim pid $STR" <<<"$out"
echo "-- impl-/orch-/bug- lane claims and a current-engine worker are not legacy workers"
( ENGINE_DIR="$NEWREL" nohup sleep 600 >/dev/null 2>&1 9>&- & echo $! > "$ROOT/lane.pid" ); sleep 0.2; LANE="$(cat "$ROOT/lane.pid")"
printf 'W1 %s IMPL:5 x-main-i5 -\n' "$LANE" > "$F7/run/claims/impl-5.claim"
out="$(roll "$NEWREL")"
assert_ok "a 5-field lane claim's process is untouched" alive "$LANE"
kill "$CUR7" "$STR" "$LANE" 2>/dev/null

echo "=== 7. #1105: a worker whose ENGINE_DIR is spelled the Windows way (W:/x for /x) is the same engine — the roll leaves it alone ==="
# On Windows export_native_paths hands a worker ENGINE_DIR=C:/x while the roll's own realpath answers /c/x. A cygpath stub that maps W:/x -> /x
# and HARNESS_PLATFORM=windows give a Linux host that two-spelling world; the stamp matches, so only the spelling could make the roll kill it.
WB="$ROOT/winbin"; mkdir -p "$WB"
printf '#!/usr/bin/env bash\n[[ "$1" == -[um] ]] && shift\nprintf "%%s\\n" "${1#W:}"\n' > "$WB/cygpath"; chmod +x "$WB/cygpath"
WENG="$ROOT/engine-win"; mk_engine "$WENG" v1 git
F8="$(fleet eight)"
( ENGINE_DIR="W:$WENG" HARNESS_ENGINE_STAMP="$(engine_stamp "$WENG")" nohup sleep 600 >/dev/null 2>&1 9>&- & echo $! > "$F8/run/worker-1.pid" )
sleep 0.2; WP="$(wpid "$F8")"
out="$( unset_inherited_config; unset STATE_DIR; PATH="$WB:$PATH" HARNESS_PLATFORM=windows ENGINE_DIR="$WENG" HARNESS_HOME="$ROOT/host" bash "$WENG/scripts/fleet-migrate.sh" --all 2>&1 )"
assert_ok "the worker with the W:/ spelling of its engine was not rolled" alive "$WP"
assert_eq "$(wpid "$F8")" "$WP" "...and its pid file still names it"
kill "$WP" 2>/dev/null

finish
