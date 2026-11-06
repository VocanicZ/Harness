#!/usr/bin/env bash
# test_fleet_migrate.sh — #467 (PRD #464 §4): scripts/fleet-migrate.sh moves every fleet to the
# one-repo config (HARNESS_UNIT / HARNESS_CHECKOUT, POOL = max(POOL, CAP), no HARNESS_TOPOLOGY, no
# HARNESS_CAP — CAP is gone, #469) and
# rolls its workers onto the new engine: backs up the config, kills only that fleet's worker and
# priority pids (never `harness stop`), then `harness start --state-dir <fleet>`.
# The seven fixtures below are the host's own configs (both line forms), trimmed to what the
# migration reads. `harness start` itself needs tmux/claude/gh, so the roll runs against a stub
# bin/harness that records the call and launches stand-in workers.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
unset_inherited_config
# (#537) STATE_DIR is the LIVE fleet's when a lane runs this directly: `fleet-migrate.sh --all` falls back to it
# as "the folder update ran in", and it now rolls an already-migrated fleet — the lane's own workers.
unset STATE_DIR
ENGINE="$(cd "$HERE/.." && pwd)"
ROOT="$(mktemp -d)"; tmp_track "$ROOT"
pin_host_home "$ROOT/host"   # (#541) the host root every fixture below shares
export HARNESS_EVENTS_FILE="$ROOT/events.jsonl"

# fleet <name> <config body> [targets.tsv body] [checkout dirs…] — a fixture project; prints its .harness dir
fleet(){ local name="$1" cfg="$2" tsv="${3:-}" d="$ROOT/$1/.harness"; shift 3 2>/dev/null || shift $#
  mkdir -p "$d/run" "$d/checkouts"
  printf '%s\n' "$cfg" > "$d/config"
  [[ -n "$tsv" ]] && printf '%b' "$tsv" > "$d/targets.tsv"
  local c; for c in "$@"; do mkdir -p "$d/checkouts/$c/.git"; done
  echo "$d"; }
# read <state-dir> <expr> — evaluate <expr> in a shell that sourced lib.sh on that fleet's config
read_cfg(){ ( unset_inherited_config; export STATE_DIR="$1" HARNESS_HOME="$ROOT/host" HARNESS_GH_RATE_GUARD=0
    unset TARGETS_TSV RUN_DIR; source "$ENGINE/scripts/lib.sh" >/dev/null 2>&1; eval "$2" ); }
migrate(){ bash "$ENGINE/scripts/fleet-migrate.sh" --no-start --state-dir "$1" 2>&1; }
cfgval(){ sed -n "s/^.*$2[:=]\\{1,2\\}\\([^}\"]*\\).*$/\\1/p" "$1/config" | head -n1; }

COMMON='HARNESS_MODE=prd'
# ── the seven host fleets ─────────────────────────────────────────────────────────────────────────
HD="$(fleet harness-dev ': "${HARNESS_MODE:=prd}"
: "${HARNESS_TOPOLOGY:=multi}"
: "${HARNESS_OWNER:=VocanicZ}"
: "${HARNESS_REPO:=VocanicZ/Harness}"
: "${HARNESS_POOL:=2}"
: "${HARNESS_CAP:=1}"
: "${HARNESS_SESS_PREFIX:=hzhn}"
export CLAUDE_CONFIG_DIR="$HOME/.claude-switch/accounts/main"' \
  'harness\tVocanicZ/Harness\t-\tHarness engine\nrtdd\tVocanicZ/rtdd\t-\trtdd — event log\n' Harness rtdd)"
IP="$(fleet ImPrint ': "${HARNESS_MODE:=prd}"
: "${HARNESS_TOPOLOGY:=multi}"            # multi + 1 row: checkout lives in .harness/checkouts, never the root
: "${HARNESS_OWNER:=VocanicZ}"
: "${HARNESS_REPO:=VocanicZ/ImPrint}"
: "${HARNESS_POOL:=1}"                    # host already runs 7 fleets on one account
: "${HARNESS_CAP:=2}"
: "${HARNESS_SESS_PREFIX:=hzip}"          # unique prefix' \
  '# id\trepo\tdeps(comma|-)\tdesc\nimprint\tVocanicZ/Imprinted\t-\tImPrint: invisible image codes\n' ImPrint Imprinted)"
OR="$(fleet ORGE ': "${HARNESS_TOPOLOGY:=multi}"
: "${HARNESS_OWNER:=RainBowCreation}"
: "${HARNESS_REPO:=RainBowCreation/ORGE}"
# One lane: every engine change also lands on the ORGE-ENGINE submodule.
: "${HARNESS_POOL:=1}"
: "${HARNESS_CAP:=2}"
: "${HARNESS_SESS_PREFIX:=hzor}"' \
  '# id\trepo\tdeps(comma|-)\tdesc\norge\tRainBowCreation/ORGE\t-\tORGE\n' ORGE)"
BC="$(fleet bangwa-client ': "${HARNESS_MODE:=prd}"
: "${HARNESS_TOPOLOGY:=multi}"
: "${HARNESS_OWNER:=RainBowCreation}"
: "${HARNESS_REPO:=RainBowCreation/bangwa-client}"
: "${HARNESS_POOL:=2}"
: "${HARNESS_CAP:=3}"
: "${HARNESS_SESS_PREFIX:=bw}"
BANGWA_ACCT="/home/nathanielsong/.claude-switch/accounts/main"
[[ -f "$BANGWA_ACCT/.claude.json" ]] || BANGWA_ACCT="$HOME/.claude-switch/accounts/main"
: "${CLAUDE_CONFIG_DIR:=$BANGWA_ACCT}"' \
  '# id\trepo\tdeps(comma|-)\tdesc\n# One unit, many PRDs\nui\tRainBowCreation/bangwa-client\t-\tBangwa client\n' bangwa-client)"
HG="$(fleet hardcore-gacha-2 ': "${HARNESS_TOPOLOGY:=multi}"
: "${HARNESS_OWNER:=VocanicZ}"
: "${HARNESS_REPO:=VocanicZ/hardcore-gacha-2}"
: "${HARNESS_POOL:=2}"
: "${HARNESS_CAP:=2}"
: "${HARNESS_SESS_PREFIX:=hzg2}"' \
  'neuro\tVocanicZ/hardcore-gacha-2\t-\tNeuro trainable hero AI\n' hardcore-gacha-2)"
SW="$(fleet swarm ': "${HARNESS_TOPOLOGY:=multi}"            # multi + 1 row
: "${HARNESS_OWNER:=VocanicZ}"
: "${HARNESS_REPO:=VocanicZ/swarm}"
: "${HARNESS_POOL:=1}"                    # host already runs 6 fleets
: "${HARNESS_CAP:=2}"
: "${HARNESS_SESS_PREFIX:=hzsw}"' \
  'swarm\tVocanicZ/swarm\t-\tswarm: HTCondor batch layer\n' swarm)"
BW="$(fleet bangwa 'HARNESS_MODE=issue-only
HARNESS_TOPOLOGY=single
HARNESS_OWNER=RainBowCreation
HARNESS_REPO=RainBowCreation/bangwa
HARNESS_POOL=1
HARNESS_CAP=4
HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions --effort high --model opus"
: "${HARNESS_SESS_PREFIX:=hzbw}"')"

# table: fleet-dir  UNIT  REPO  checkout-dir-name|ROOT  POOL  CAP  session-name
check(){ local d="$1" unit="$2" repo="$3" co="$4" pool="$5" cap="$6" sess="$7" out
  out="$(migrate "$d")"
  assert_eq "$(read_cfg "$d" 'echo $(fleet_unit)')" "$unit" "$(basename "$(dirname "$d")"): UNIT is $unit"
  assert_eq "$(read_cfg "$d" 'echo $HARNESS_REPO')" "$repo" "$(basename "$(dirname "$d")"): REPO is $repo"
  assert_eq "$(read_cfg "$d" 'echo $HARNESS_POOL')" "$pool" "$(basename "$(dirname "$d")"): POOL is $pool"
  assert_no "$(basename "$(dirname "$d")"): the HARNESS_CAP line is gone (CAP was $cap, #469)" grep -q 'HARNESS_CAP' "$d/config"
  local want="$d/checkouts/$co"; [[ "$co" == ROOT ]] && want="$(dirname "$d")"
  assert_eq "$(read_cfg "$d" 'echo $(fleet_checkout)')" "$want" "$(basename "$(dirname "$d")"): CHECKOUT is $want"
  assert_ok "$(basename "$(dirname "$d")"): that CHECKOUT exists" test -d "$want"
  assert_no "$(basename "$(dirname "$d")"): HARNESS_TOPOLOGY is gone from the config" grep -q 'HARNESS_TOPOLOGY' "$d/config"
  assert_eq "$(read_cfg "$d" 'echo $(sess_impl "$(fleet_unit)" 7)')" "$sess" "$(basename "$(dirname "$d")"): session name stays $sess"
  assert_eq "$(read_cfg "$d" 'echo $(unit_slug "$(fleet_unit)")')" "$repo" "$(basename "$(dirname "$d")"): unit_slug is the repo"
  assert_ok "$(basename "$(dirname "$d")"): the old config is kept as config.bak-<date>" test -n "$(ls "$d"/config.bak-* 2>/dev/null)"
}
check "$HD" harness VocanicZ/Harness            Harness          2 1 hzhn-harness-i7
check "$IP" imprint VocanicZ/Imprinted          Imprinted        2 2 hzip-imprint-i7
check "$OR" orge    RainBowCreation/ORGE        ORGE             2 2 hzor-orge-i7
check "$BC" ui      RainBowCreation/bangwa-client bangwa-client  3 3 bw-ui-i7
check "$HG" neuro   VocanicZ/hardcore-gacha-2   hardcore-gacha-2 2 2 hzg2-neuro-i7
check "$SW" swarm   VocanicZ/swarm              swarm            2 2 hzsw-swarm-i7
check "$BW" main    RainBowCreation/bangwa      ROOT             4 4 hzbw-main-i7

# the config keeps everything else it had: comments, the account pin, quoted values
assert_ok "inline comments on edited lines survive"   grep -q 'POOL:=2}"  *# host already runs 7 fleets' "$IP/config"
assert_ok "the account pin line survives"              grep -q 'CLAUDE_CONFIG_DIR' "$HD/config"
assert_ok "plain-form quoted values survive"           grep -q '^HARNESS_CLAUDE_FLAGS="--dangerously-skip-permissions' "$BW/config"
assert_ok "a plain-form config gets plain-form keys"   grep -q '^HARNESS_UNIT=main$' "$BW/config"
assert_ok "a := config gets := keys"                   grep -q '^: "${HARNESS_UNIT:=harness}"$' "$HD/config"
assert_eq "$(grep -c 'HARNESS_REPO' "$IP/config")" "1" "ImPrint: the target's repo REPLACES the config's (still one HARNESS_REPO line)"
assert_ok "ImPrint: the renamed repo is the target's"  grep -q 'HARNESS_REPO:=VocanicZ/Imprinted}' "$IP/config"
assert_ok "the backup is the config as it was"         grep -q 'HARNESS_TOPOLOGY:=multi' "$HD"/config.bak-*
assert_ok "...CAP line included"                       grep -q 'HARNESS_CAP:=1' "$HD"/config.bak-*
assert_ok "an inline comment next to the dropped CAP line does not eat the POOL line" grep -q 'POOL:=2}"  *# host already runs 7 fleets' "$IP/config"

# ── the two-row fleet: rtdd leaves targets.tsv, and a fleet_migrated event says so ──
assert_ok "rtdd's row is in targets.tsv.migrated"      grep -q '^rtdd	VocanicZ/rtdd' "$HD/targets.tsv.migrated"
assert_no "rtdd's row is out of targets.tsv"           grep -q '^rtdd' "$HD/targets.tsv"
assert_ok "harness's row stays in targets.tsv"         grep -q '^harness	VocanicZ/Harness' "$HD/targets.tsv"
assert_no "a one-row fleet writes no targets.tsv.migrated" test -e "$IP/targets.tsv.migrated"
ev="$(grep '"fleet_migrated"' "$HARNESS_EVENTS_FILE" | grep '"unit": "harness"')"
assert_ok "a fleet_migrated event for harness-dev"     test -n "$ev"
assert_ok "...naming the dropped unit"                 grep -q '"dropped": "rtdd"' <<<"$ev"
assert_eq "$(grep -c '"fleet_migrated"' "$HARNESS_EVENTS_FILE")" "7" "one fleet_migrated event per fleet"

# ── running it twice changes nothing ──
snap(){ ( cd "$1" && find . -type f -not -path './run/*' | sort | xargs md5sum; ls ) 2>&1; }
before="$(for d in "$HD" "$IP" "$OR" "$BC" "$HG" "$SW" "$BW"; do snap "$d"; done)"; evs="$(wc -l < "$HARNESS_EVENTS_FILE")"
for d in "$HD" "$IP" "$OR" "$BC" "$HG" "$SW" "$BW"; do migrate "$d" >/dev/null; done
after="$(for d in "$HD" "$IP" "$OR" "$BC" "$HG" "$SW" "$BW"; do snap "$d"; done)"
assert_eq "$after" "$before" "a second run leaves every config, backup and targets file byte-identical"
assert_eq "$(wc -l < "$HARNESS_EVENTS_FILE")" "$evs" "...and logs no second event"
assert_eq "$(ls "$HD"/config.bak-* | wc -l)" "1" "...and takes no second backup"

# ── #469: a config #467 already migrated (it kept HARNESS_CAP) loses that line and keeps its POOL ──
M1="$(fleet m-kept ': "${HARNESS_MODE:=prd}"
: "${HARNESS_OWNER:=acme}"
: "${HARNESS_REPO:=acme/k}"
: "${HARNESS_UNIT:=kk}"
: "${HARNESS_CHECKOUT:=/x/k}"
: "${HARNESS_POOL:=3}"
: "${HARNESS_CAP:=3}"        # kept by #467
: "${HARNESS_SESS_PREFIX:=hzk}"')"
M2="$(fleet m-kept-plain 'HARNESS_REPO=acme/p
HARNESS_UNIT=main
HARNESS_CHECKOUT=/x/p
HARNESS_POOL=4
HARNESS_CAP=4
export HARNESS_SESS_PREFIX=hzp')"
out="$(migrate "$M1")"
assert_no "#467-migrated: HARNESS_CAP is gone"          grep -q 'HARNESS_CAP' "$M1/config"
assert_eq "$(read_cfg "$M1" 'echo $HARNESS_POOL')" "3"  "#467-migrated: POOL is kept"
assert_eq "$(read_cfg "$M1" 'echo $HARNESS_UNIT')" "kk" "#467-migrated: the unit is kept"
assert_ok "#467-migrated: the sess prefix line survives" grep -q 'HARNESS_SESS_PREFIX:=hzk' "$M1/config"
assert_ok "#467-migrated: the old config is backed up with its CAP line" grep -q 'HARNESS_CAP:=3' "$M1"/config.bak-*
migrate "$M2" >/dev/null
assert_no "#467-migrated (plain form): HARNESS_CAP is gone" grep -q 'HARNESS_CAP' "$M2/config"
assert_eq "$(grep -c . "$M2/config")" "5" "...and only that line went"
assert_eq "$(read_cfg "$M2" 'echo $HARNESS_POOL')" "4"  "#467-migrated (plain form): POOL is kept"
# a fresh un-migrated config ends in the same place in one pass
M3="$(fleet m-fresh ': "${HARNESS_TOPOLOGY:=single}"
: "${HARNESS_REPO:=acme/k}"
: "${HARNESS_POOL:=3}"
: "${HARNESS_CAP:=3}"')"
migrate "$M3" >/dev/null
assert_no "un-migrated config: no HARNESS_CAP after ONE pass" grep -q 'HARNESS_CAP' "$M3/config"
assert_eq "$(read_cfg "$M3" 'echo $HARNESS_POOL')" "3"  "...POOL is the table's max"
b="$(snap "$M1"; snap "$M2"; snap "$M3")"; evs="$(wc -l < "$HARNESS_EVENTS_FILE")"
migrate "$M1" >/dev/null; migrate "$M2" >/dev/null; migrate "$M3" >/dev/null
assert_eq "$(snap "$M1"; snap "$M2"; snap "$M3")" "$b" "running it twice changes nothing (configs and backups byte-identical)"
assert_eq "$(wc -l < "$HARNESS_EVENTS_FILE")" "$evs" "...and logs no second event"
assert_eq "$(ls "$M1"/config.bak-* | wc -l)" "1"      "...and takes no second backup"
# a config with no CAP line at all is left alone, as before
M4="$(fleet m-nocap ': "${HARNESS_UNIT:=main}"
: "${HARNESS_REPO:=acme/n}"')"; b4="$(snap "$M4")"
out4="$(migrate "$M4")"
assert_eq "$(snap "$M4")" "$b4" "a one-repo config with no CAP line is untouched"
assert_ok "...and reports nothing to do"                 grep -q 'nothing to do' <<<"$out4"

# ── edge: no HARNESS_POOL line, an unreadable pool, a multi config whose targets.tsv is gone ──
E1="$(fleet e-nopool ': "${HARNESS_TOPOLOGY:=single}"
: "${HARNESS_REPO:=acme/w}"
: "${HARNESS_CAP:=5}"')"
migrate "$E1" >/dev/null
assert_eq "$(read_cfg "$E1" 'echo $HARNESS_POOL')" "5" "no POOL line: POOL is written as max(default 3, CAP 5)"
E2="$(fleet e-notsv ': "${HARNESS_TOPOLOGY:=multi}"
: "${HARNESS_REPO:=acme/w}"' '' w)"
assert_ok "a multi config with no targets.tsv still migrates" bash -c "bash '$ENGINE/scripts/fleet-migrate.sh' --no-start --state-dir '$E2' >/dev/null 2>&1"
assert_eq "$(read_cfg "$E2" 'echo $(fleet_unit)')" "main" "...to unit main"
assert_eq "$(read_cfg "$E2" 'echo $(fleet_checkout)')" "$E2/checkouts/w" "...and the clone that exists on disk"
E3="$(fleet e-match ': "${HARNESS_TOPOLOGY:=multi}"
: "${HARNESS_OWNER:=acme}"
: "${HARNESS_REPO:=acme/two}"' 'one\tacme/one\t-\tfirst\ntwo\tacme/two\t-\tsecond\n' one two)"
migrate "$E3" >/dev/null
assert_eq "$(read_cfg "$E3" 'echo $(fleet_unit)')" "two" "the row whose repo matches HARNESS_REPO is kept, not the first"
# #554: a targets.tsv id with a `.` would become a tmux-unsafe HARNESS_UNIT — written as `_` instead
E5="$(fleet e-dotted ': "${HARNESS_TOPOLOGY:=multi}"
: "${HARNESS_REPO:=vercel/next.js}"' 'next.js\tvercel/next.js\t-\tnext\n' next.js)"
migrate "$E5" >/dev/null
assert_eq "$(cfgval "$E5" HARNESS_UNIT)" "next_js" "#554: a dotted unit id is written tmux-safe (next_js)"
assert_eq "$(read_cfg "$E5" 'echo $(sess_impl "$(fleet_unit)" 7)')" "$(read_cfg "$E5" 'echo $HARNESS_SESS_PREFIX')-next_js-i7" "#554: ...and the session name has no dot"
E4="$(fleet e-clone ': "${HARNESS_TOPOLOGY:=multi}"
: "${HARNESS_REPO:=acme/renamed}"' 'main\tacme/renamed\t-\tx\n')"
mkdir -p "$E4/checkouts/oldname/.git"; git -C "$E4/checkouts/oldname" init -q 2>/dev/null; git -C "$E4/checkouts/oldname" remote add origin https://github.com/acme/renamed.git
migrate "$E4" >/dev/null
assert_eq "$(read_cfg "$E4" 'echo $(fleet_checkout)')" "$E4/checkouts/oldname" "no clone named after the repo: the one whose origin is the repo"

# ── harness update's roll: two registered fleets, live old-loop workers ───────────────────────────
STUB="$ROOT/engine"; mkdir -p "$STUB/bin" "$STUB/scripts"
cp "$ENGINE"/scripts/{fleet-migrate.sh,fleet_migrate.py,stats.py,portable.sh,roll.sh} "$STUB/scripts/"
START_LOG="$ROOT/start.log"; : > "$START_LOG"
cat > "$STUB/bin/harness" <<'STUBEOF'
#!/usr/bin/env bash
# stand-in for `harness start`: record the call and its environment, launch stand-in workers.
[[ "$1" == --state-dir && "$3" == start ]] || exit 9
d="$2"; pool="$(sed -n 's/^.*HARNESS_POOL[:=]*\([0-9]*\).*$/\1/p' "$d/config" | head -n1)"
echo "start $d recover=$([[ " $* " == *" --recover "* ]] && echo yes || echo no) keep_pause=${HARNESS_START_KEEP_PAUSE:-} env_repo=${HARNESS_REPO:-} env_state=${STATE_DIR:-} pool=$pool" >> "$START_LOG"
for ((i = 1; i <= pool; i++)); do nohup sleep 600 >/dev/null 2>&1 9>&- & echo $! > "$d/run/worker-$i.pid"; done
nohup sleep 600 >/dev/null 2>&1 9>&- & echo $! > "$d/run/priority.pid"
STUBEOF
chmod +x "$STUB/bin/harness"; export START_LOG

UA="$(fleet upd-a ': "${HARNESS_TOPOLOGY:=multi}"
: "${HARNESS_REPO:=acme/a}"
: "${HARNESS_POOL:=1}"
: "${HARNESS_CAP:=3}"
: "${HARNESS_SESS_PREFIX:=ua}"' 'alpha\tacme/a\t-\tA\n' a)"
UB="$(fleet upd-b 'HARNESS_TOPOLOGY=single
HARNESS_REPO=acme/b
HARNESS_POOL=2
HARNESS_CAP=1
HARNESS_SESS_PREFIX=ub')"
UC="$(fleet upd-c ': "${HARNESS_TOPOLOGY:=single}"
: "${HARNESS_REPO:=acme/c}"')"   # NOT registered: another folder's fleet
UD="$(fleet upd-d ': "${HARNESS_UNIT:=main}"
: "${HARNESS_REPO:=acme/d}"
: "${HARNESS_POOL:=1}"
: "${HARNESS_SESS_PREFIX:=ud}"')"       # registered, already one repo (rc 10), workers on an OLD release (#537)
UG="$(fleet upd-g ': "${HARNESS_UNIT:=main}"
: "${HARNESS_REPO:=acme/g}"
: "${HARNESS_POOL:=1}"')"       # registered, already one repo (rc 10), workers already on the CURRENT engine
mkdir -p "$ROOT/host/fleets"; export HARNESS_FLEETS_DIR="$ROOT/host/fleets"   # run.sh pins its own; the registry under test is this one
for p in "$UA" "$UB" "$UD" "$UG"; do
  printf '{"prefix": "x", "project": "%s", "run_dir": "%s/run", "slugs": [], "started_at": 1}' "$p" "$p" > "$ROOT/host/fleets/$(basename "$(dirname "$p")").json"
done
# stand-in old-loop workers: one pid per file, each fleet its own. fleet_roll reads a worker's ENGINE_DIR from its
# environment (#477): spawn_eng gives a stand-in one, like a real worker's (the realpath of the release it started on).
spawn(){ nohup sleep 600 >/dev/null 2>&1 9>&- & echo $! > "$1"; }
OLDENG="$ROOT/engine-old"; mkdir -p "$OLDENG"      # an older release dir: any dir that is not the engine under test
spawn_eng(){ ENGINE_DIR="$2" nohup sleep 600 >/dev/null 2>&1 9>&- & echo $! > "$1"; }
for d in "$UA" "$UB" "$UC"; do spawn "$d/run/worker-1.pid"; spawn "$d/run/priority.pid"; done
spawn "$UB/run/worker-2.pid"
for d in "$UD"; do spawn_eng "$d/run/worker-1.pid" "$OLDENG"; spawn_eng "$d/run/priority.pid" "$OLDENG"; done   # rc 10, old release
for d in "$UG"; do spawn_eng "$d/run/worker-1.pid" "$STUB"; spawn_eng "$d/run/priority.pid" "$STUB"; done      # rc 10, current
eng_of(){ ( source "$ENGINE/scripts/portable.sh"; proc_env "$1" ENGINE_DIR ); }   # a process's ENGINE_DIR
pidsof(){ cat "$1"/run/worker-*.pid "$1"/run/priority.pid 2>/dev/null | tr '\n' ' '; }
OLD_A="$(pidsof "$UA")"; OLD_B="$(pidsof "$UB")"; OLD_C="$(pidsof "$UC")"; OLD_D="$(pidsof "$UD")"; CUR_G="$(pidsof "$UG")"
# a lane session and a bystander on a private tmux server — neither may be touched
TMUX_SOCK="lm$$"
if command -v tmux >/dev/null 2>&1; then
  tmux -L "$TMUX_SOCK" new-session -d -s ua-alpha-i5 'sleep 600'; tmux -L "$TMUX_SOCK" new-session -d -s ud-main-i3 'sleep 600'; tmux -L "$TMUX_SOCK" new-session -d -s other-session 'sleep 600'
  trap 'tmux -L "$TMUX_SOCK" kill-server 2>/dev/null; tmp_cleanup' EXIT
fi
BYSTANDER=""; nohup sleep 600 >/dev/null 2>&1 9>&- & BYSTANDER=$!
alive(){ local p; for p in $1; do kill -0 "$p" 2>/dev/null || return 1; done; }
dead(){ local p; for p in $1; do kill -0 "$p" 2>/dev/null && return 1; done; return 0; }

out="$( cd "$UC/.." && STATE_DIR="$UC" HARNESS_REPO=leaked/repo HARNESS_POOL=99 ENGINE_DIR="$STUB" HARNESS_HOME="$ROOT/host" \
        bash "$STUB/scripts/fleet-migrate.sh" --all 2>&1)"
assert_ok "update: fleet A (multi) is migrated"           grep -q 'HARNESS_UNIT:=alpha' "$UA/config"
assert_ok "update: fleet B (plain KEY=val) is migrated"   grep -q '^HARNESS_UNIT=main$' "$UB/config"
assert_eq "$(read_cfg "$UA" 'echo $HARNESS_POOL')" "3" "update: fleet A POOL is max(1,3)"
assert_eq "$(read_cfg "$UB" 'echo $HARNESS_POOL')" "2" "update: fleet B POOL is max(2,1)"
assert_ok "update: A's old worker + priority pids are dead" dead "$OLD_A"
assert_ok "update: B's old worker + priority pids are dead" dead "$OLD_B"
assert_ok "update: the bystander process is untouched"     kill -0 "$BYSTANDER"
# #537: a fleet #467 already migrated (rc 10) still has its OLD-release workers rolled
assert_ok "update: an already-migrated fleet's workers on an older release are killed (#537)" dead "$OLD_D"
assert_ok "update: ...and relaunched, without --recover"   grep -q "^start $UD recover=no " "$START_LOG"
assert_ok "update: ...onto new pids that are running"      alive "$(pidsof "$UD")"
assert_ok "update: ...started from the current engine"     test "$(eng_of "$(cat "$UD/run/worker-1.pid")")" = "$STUB"
assert_ok "update: an already-migrated fleet's workers on the current engine are left running" alive "$CUR_G"
assert_ok "update: ...and not restarted"                   test "$(pidsof "$UG")" = "$CUR_G"
assert_no "update: ...no harness start for it"             grep -q "^start $UG" "$START_LOG"
assert_eq "$(grep -c '^start ' "$START_LOG")" "4" "update: harness start ran for exactly the fleets with a worker to roll (A, B, D and the unregistered current folder's C — not G, already current)"
assert_ok "update: ...for fleet A, without --recover"      grep -q "^start $UA recover=no " "$START_LOG"
assert_ok "update: ...for fleet B, without --recover"      grep -q "^start $UB recover=no " "$START_LOG"
assert_no "update: the start inherits no other fleet's environment" grep -qE 'env_repo=leaked|env_state=[^ ]|pool=99' "$START_LOG"
assert_ok "update: A's workers are running again (3 workers + priority)" alive "$(pidsof "$UA")"
assert_eq "$(ls "$UA"/run/worker-*.pid | wc -l)" "3" "update: A relaunched POOL=3 workers"
assert_ok "update: B's workers are running again"          alive "$(pidsof "$UB")"
assert_ok "update: A's pids are new ones"                  test "$(pidsof "$UA")" != "$OLD_A"
if command -v tmux >/dev/null 2>&1; then
  assert_ok "update: the fleet's live lane session survives" tmux -L "$TMUX_SOCK" has-session -t ua-alpha-i5
  assert_ok "update: another tmux session is untouched"      tmux -L "$TMUX_SOCK" has-session -t other-session
  assert_ok "update: an rc-10 fleet's live lane session survives its roll (#537)" tmux -L "$TMUX_SOCK" has-session -t ud-main-i3
  # ...and the relaunched worker adopts it: the REAL adopt_lanes, run as that fleet's worker, writes the claim.
  adopted="$( unset_inherited_config; export STATE_DIR="$UD" HARNESS_GH_RATE_GUARD=0 HARNESS_SESS_BACKEND=tmux HARNESS_UNIT=main HARNESS_SESS_PREFIX=ud
    unset TARGETS_TSV RUN_DIR; source "$ENGINE/scripts/lib.sh" >/dev/null 2>&1; source "$ENGINE/scripts/drive.sh" >/dev/null 2>&1
    _HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1; source "$ENGINE/scripts/pool-worker.sh" >/dev/null 2>&1
    tmux(){ command tmux -L "$TMUX_SOCK" "$@"; }; mkdir -p "$CLAIMS_DIR"
    as_worker(){ local UNIT REPO SLUG PROJECT DESC CHECKOUT; fleet_ctx; adopt_lanes W7; }; as_worker >/dev/null 2>&1; cat "$CLAIMS_DIR/impl-3.claim" 2>/dev/null )"
  assert_ok "update: ...the relaunched worker adopts the rolled fleet's lane (adopt_lanes writes impl-3.claim, #537)" grep -q '^W7 [0-9]* IMPL:3 ud-main-i3 ' <<<"$adopted"
fi
assert_ok "update: the unregistered current-folder fleet is migrated too" grep -q 'HARNESS_UNIT:=main' "$UC/config"
assert_ok "update: ...and rolled, since it had worker pid files" grep -q "^start $UC recover=no " "$START_LOG"
assert_ok "update: ...onto new pids"                       dead "$OLD_C"
# #469 + #537: a registered fleet #467 already migrated, still carrying HARNESS_CAP (rc 11), loses that line AND
# has its old-release workers rolled — they run the old unit-claim loop whatever its config says.
UF="$(fleet upd-f ': "${HARNESS_UNIT:=main}"
: "${HARNESS_REPO:=acme/f}"
: "${HARNESS_POOL:=2}"
: "${HARNESS_CAP:=2}"')"
printf '{"prefix": "x", "project": "%s", "run_dir": "%s/run", "slugs": [], "started_at": 1}' "$UF" "$UF/run" > "$ROOT/host/fleets/upd-f.json"
spawn_eng "$UF/run/worker-1.pid" "$OLDENG"; spawn_eng "$UF/run/priority.pid" "$OLDENG"; OLD_F="$(pidsof "$UF")"; n="$(grep -c '^start ' "$START_LOG")"
ENGINE_DIR="$STUB" HARNESS_HOME="$ROOT/host" bash "$STUB/scripts/fleet-migrate.sh" --all >/dev/null 2>&1
assert_no "update: a migrated fleet's kept HARNESS_CAP line is dropped" grep -q HARNESS_CAP "$UF/config"
assert_eq "$(read_cfg "$UF" 'echo $HARNESS_POOL')" "2"  "update: ...and its POOL is kept"
assert_ok "update: ...its old-release workers are killed (#537)" dead "$OLD_F"
assert_ok "update: ...and relaunched without --recover"  grep -q "^start $UF recover=no " "$START_LOG"
assert_eq "$(grep -c '^start ' "$START_LOG")" "$((n + 1))" "update: ...by exactly one harness start (the other registered fleets are current)"
assert_ok "update: ...the new workers run"               alive "$(pidsof "$UF")"
assert_ok "update: ...the old config is backed up"      grep -q HARNESS_CAP "$UF"/config.bak-*
# the same rc-11 shape, but its workers already run the current engine: the CAP line goes, nothing is restarted
UH="$(fleet upd-h ': "${HARNESS_UNIT:=main}"
: "${HARNESS_REPO:=acme/h}"
: "${HARNESS_POOL:=1}"
: "${HARNESS_CAP:=1}"')"
printf '{"prefix": "x", "project": "%s", "run_dir": "%s/run", "slugs": [], "started_at": 1}' "$UH" "$UH/run" > "$ROOT/host/fleets/upd-h.json"
spawn_eng "$UH/run/worker-1.pid" "$STUB"; CUR_H="$(pidsof "$UH")"; n="$(grep -c '^start ' "$START_LOG")"
ENGINE_DIR="$STUB" HARNESS_HOME="$ROOT/host" bash "$STUB/scripts/fleet-migrate.sh" --all >/dev/null 2>&1
assert_no "update: a CAP-line fleet on the current engine: the line is dropped" grep -q HARNESS_CAP "$UH/config"
assert_ok "update: ...its workers are left running"      alive "$CUR_H"
assert_eq "$(grep -c '^start ' "$START_LOG")" "$n"      "update: ...and no harness start for it"
# an unregistered fleet with NO live workers is migrated, not started
UE="$(fleet upd-e ': "${HARNESS_TOPOLOGY:=single}"
: "${HARNESS_REPO:=acme/e}"')"
STATE_DIR="$UE" ENGINE_DIR="$STUB" HARNESS_HOME="$ROOT/host" bash "$STUB/scripts/fleet-migrate.sh" --all >/dev/null 2>&1
assert_ok "update: a stopped, unregistered fleet is migrated" grep -q 'HARNESS_UNIT:=main' "$UE/config"
assert_no "update: ...and not started"                     grep -q "^start $UE" "$START_LOG"
# second pass: nothing is migrated, nothing is killed or started
n="$(grep -c '^start ' "$START_LOG")"; pa="$(pidsof "$UA")"; pd="$(pidsof "$UD")"; pf="$(pidsof "$UF")"; pg="$(pidsof "$UG")"; ph="$(pidsof "$UH")"
ENGINE_DIR="$STUB" HARNESS_HOME="$ROOT/host" bash "$STUB/scripts/fleet-migrate.sh" --all >/dev/null 2>&1
assert_eq "$(grep -c '^start ' "$START_LOG")" "$n" "update twice: no second start"
assert_ok "update twice: the workers are the same processes" test "$(pidsof "$UA")" = "$pa"
assert_ok "update twice: ...an already-migrated (rc 10) fleet's rolled workers too (#537)" test "$(pidsof "$UD")" = "$pd"
assert_ok "update twice: ...an rc 11 fleet's"               test "$(pidsof "$UF")" = "$pf"
assert_ok "update twice: ...and the fleets that were current all along" test "$(pidsof "$UG") $(pidsof "$UH")" = "$pg $ph"
assert_ok "update twice: nothing was killed"               alive "$pa $pd $pf $pg $ph"
# a paused fleet is migrated and rolled (fleet_roll, #477) and comes back paused: start is told to keep PAUSED
UP="$(fleet upd-p ': "${HARNESS_TOPOLOGY:=single}"
: "${HARNESS_REPO:=acme/p}"')"; touch "$UP/run/PAUSED"; spawn "$UP/run/worker-1.pid"; OLD_P="$(pidsof "$UP")"
printf '{"prefix": "x", "project": "%s", "run_dir": "%s/run", "slugs": [], "started_at": 1}' "$UP" "$UP/run" > "$ROOT/host/fleets/upd-p.json"
out="$(ENGINE_DIR="$STUB" HARNESS_HOME="$ROOT/host" bash "$STUB/scripts/fleet-migrate.sh" --all 2>&1)"
assert_ok "paused fleet: migrated"                         grep -q 'HARNESS_UNIT:=main' "$UP/config"
assert_ok "paused fleet: old workers stopped"              dead "$OLD_P"
assert_ok "paused fleet: relaunched with the pause kept"    grep -q "^start $UP recover=no keep_pause=1 " "$START_LOG"
assert_ok "paused fleet: the pause flag is still there"    test -e "$UP/run/PAUSED"

# ── harness start migrates its own fleet before launching ──
# start.sh needs tmux/claude/gh to get anywhere; pointed at a missing claude it dies at the first
# prerequisite check — AFTER the migration, which is the order under test.
SF="$(fleet start-own ': "${HARNESS_TOPOLOGY:=multi}"
: "${HARNESS_REPO:=acme/s}"
: "${HARNESS_POOL:=1}"
: "${HARNESS_CAP:=2}"
: "${HARNESS_SESS_PREFIX:=hzst}"
: "${HARNESS_CLAUDE_BIN:=/nonexistent/claude}"' 's1\tacme/s\t-\tS\n' s)"
spawn "$SF/run/worker-1.pid"; OLD_S="$(pidsof "$SF")"
( unset_inherited_config; export HARNESS_HOME="$ROOT/host2" HARNESS_FLEETS_DIR="$ROOT/host2/fleets" HARNESS_POLLER_DIR="$ROOT/host2/poller" HARNESS_SNAPSHOTS_DIR="$ROOT/host2/snapshots"
  STATE_DIR="$SF" ENGINE_DIR="$ENGINE" bash "$ENGINE/scripts/start.sh" >"$ROOT/start.out" 2>&1 )
assert_ok "start: migrated its own fleet's config (UNIT)"  grep -q 'HARNESS_UNIT:=s1' "$SF/config"
assert_eq "$(read_cfg "$SF" 'echo $HARNESS_POOL')" "2" "start: ...and POOL = max(1,2)"
assert_ok "start: ...and stopped the old workers"          dead "$OLD_S"
assert_no "start: HARNESS_TOPOLOGY gone"                   grep -q HARNESS_TOPOLOGY "$SF/config"
assert_no "start: HARNESS_CAP gone (#469)"                 grep -q HARNESS_CAP "$SF/config"
assert_eq "$(grep -c 'CAP is gone; POOL is the number of parallel issues' "$ROOT/start.out")" "1" "start: a config's HARNESS_CAP is ignored with the warning printed exactly once"
# HARNESS_CAP in the environment: ignored, one warning; none without it
SG="$(fleet start-env ': "${HARNESS_UNIT:=main}"
: "${HARNESS_REPO:=acme/g}"
: "${HARNESS_POOL:=1}"
: "${HARNESS_SESS_PREFIX:=hzsg}"
: "${HARNESS_CLAUDE_BIN:=/nonexistent/claude}"')"
start_env(){ ( unset_inherited_config; export HARNESS_HOME="$ROOT/host2" HARNESS_FLEETS_DIR="$ROOT/host2/fleets" HARNESS_POLLER_DIR="$ROOT/host2/poller" HARNESS_SNAPSHOTS_DIR="$ROOT/host2/snapshots"
    [[ -n "${1:-}" ]] && export HARNESS_CAP="$1"
    STATE_DIR="$SG" ENGINE_DIR="$ENGINE" bash "$ENGINE/scripts/start.sh" 2>&1 ) ; }
assert_eq "$(start_env 5 | grep -c 'CAP is gone; POOL is the number of parallel issues')" "1" "start: HARNESS_CAP=5 in the environment: one warning"
assert_eq "$(start_env | grep -c 'CAP is gone')" "0" "start: no HARNESS_CAP anywhere: no warning"
# HARNESS_FLEET_MIGRATE=0 leaves the config's CAP line: still ignored, still one warning
SH="$(fleet start-nomig ': "${HARNESS_UNIT:=main}"
: "${HARNESS_REPO:=acme/h}"
: "${HARNESS_CAP:=5}"
: "${HARNESS_CLAUDE_BIN:=/nonexistent/claude}"')"
assert_eq "$( ( unset_inherited_config; export HARNESS_FLEET_MIGRATE=0 HARNESS_HOME="$ROOT/host2" HARNESS_FLEETS_DIR="$ROOT/host2/fleets" HARNESS_POLLER_DIR="$ROOT/host2/poller" HARNESS_SNAPSHOTS_DIR="$ROOT/host2/snapshots"
    STATE_DIR="$SH" ENGINE_DIR="$ENGINE" bash "$ENGINE/scripts/start.sh" 2>&1 ) | grep -c 'CAP is gone')" "1" "start: a config's HARNESS_CAP the migration did not run on: one warning"
# #566: `harness start` on an already-migrated fleet (rc 10/11) whose live workers run an OLDER engine release stops
# them before pool.sh runs (pool.sh skips a live pid), so the new engine relaunches them; workers already on this
# engine are left alone. Lane sessions are never touched.
SA="$(fleet start-oldw ': "${HARNESS_UNIT:=main}"
: "${HARNESS_REPO:=acme/o}"
: "${HARNESS_POOL:=2}"
: "${HARNESS_CAP:=1}"
: "${HARNESS_SESS_PREFIX:=hzso}"
: "${HARNESS_CLAUDE_BIN:=/nonexistent/claude}"')"
SB="$(fleet start-curw ': "${HARNESS_UNIT:=main}"
: "${HARNESS_REPO:=acme/c}"
: "${HARNESS_POOL:=2}"
: "${HARNESS_CAP:=1}"
: "${HARNESS_SESS_PREFIX:=hzsc}"
: "${HARNESS_CLAUDE_BIN:=/nonexistent/claude}"')"
SC="$(fleet start-cleanold ': "${HARNESS_UNIT:=main}"
: "${HARNESS_REPO:=acme/n}"
: "${HARNESS_POOL:=1}"
: "${HARNESS_SESS_PREFIX:=hzsn}"
: "${HARNESS_CLAUDE_BIN:=/nonexistent/claude}"')"
for d in "$SA" "$SC"; do spawn_eng "$d/run/worker-1.pid" "$OLDENG"; spawn_eng "$d/run/priority.pid" "$OLDENG"; done
spawn_eng "$SA/run/worker-2.pid" "$OLDENG"
for d in "$SB"; do spawn_eng "$d/run/worker-1.pid" "$ENGINE"; spawn_eng "$d/run/worker-2.pid" "$ENGINE"; spawn_eng "$d/run/priority.pid" "$ENGINE"; done
OLD_SA="$(pidsof "$SA")"; CUR_SB="$(pidsof "$SB")"; OLD_SC="$(pidsof "$SC")"
command -v tmux >/dev/null 2>&1 && tmux -L "$TMUX_SOCK" new-session -d -s hzso-main-i9 'sleep 600'
start_fleet(){ ( unset_inherited_config; export HARNESS_HOME="$ROOT/host2" HARNESS_FLEETS_DIR="$ROOT/host2/fleets" HARNESS_POLLER_DIR="$ROOT/host2/poller" HARNESS_SNAPSHOTS_DIR="$ROOT/host2/snapshots"
    STATE_DIR="$1" ENGINE_DIR="$ENGINE" bash "$ENGINE/scripts/start.sh" 2>&1 ); }
start_fleet "$SA" >"$ROOT/start-sa.out"
assert_no "start #566: the leftover HARNESS_CAP line is gone"        grep -q HARNESS_CAP "$SA/config"
assert_ok "start #566: ...the old-engine workers and priority lane are stopped" dead "$OLD_SA"
assert_ok "start #566: ...with the fleet's lane session still up"   bash -c "! command -v tmux >/dev/null || tmux -L '$TMUX_SOCK' has-session -t hzso-main-i9"
start_fleet "$SB" >/dev/null
assert_ok "start #566: workers already on this engine are left running" alive "$CUR_SB"
assert_ok "start #566: ...and keep their pids"                      test "$(pidsof "$SB")" = "$CUR_SB"
start_fleet "$SC" >/dev/null
assert_ok "start #566: a config with no CAP line (rc 10) also stops its old-engine workers" dead "$OLD_SC"
# a worker mid bug-claim is never killed (fleet_roll's rule), the old-engine one without a claim is
SD="$(fleet start-bugclaim ': "${HARNESS_UNIT:=main}"
: "${HARNESS_REPO:=acme/b}"
: "${HARNESS_POOL:=1}"
: "${HARNESS_CLAUDE_BIN:=/nonexistent/claude}"')"
spawn_eng "$SD/run/worker-1.pid" "$OLDENG"; spawn_eng "$SD/run/priority.pid" "$OLDENG"; mkdir -p "$SD/run/claims"
echo "bug-7 $(cat "$SD/run/priority.pid")" > "$SD/run/claims/bug-7.claim"; PRI_SD="$(cat "$SD/run/priority.pid")"; WRK_SD="$(cat "$SD/run/worker-1.pid")"
start_fleet "$SD" >/dev/null
assert_ok "start #566: a priority lane holding a bug claim is left for a later pass" kill -0 "$PRI_SD"
assert_ok "start #566: ...its claim-free sibling worker is stopped" dead "$WRK_SD"
# fleet-migrate.sh --no-start alone: same
SE="$(fleet start-nostart ': "${HARNESS_UNIT:=main}"
: "${HARNESS_REPO:=acme/e}"
: "${HARNESS_POOL:=1}"')"
spawn_eng "$SE/run/worker-1.pid" "$OLDENG"; OLD_SE="$(pidsof "$SE")"
ENGINE_DIR="$ENGINE" bash "$ENGINE/scripts/fleet-migrate.sh" --no-start --quiet --state-dir "$SE" >/dev/null 2>&1
assert_ok "migrate --no-start #566: an rc-10 fleet's old-engine workers are stopped, none relaunched" dead "$OLD_SE"
assert_no "migrate --no-start #566: ...and no harness start is run for it"  grep -q "^start $SE" "$START_LOG"
mig_ln="$(grep -n 'fleet-migrate.sh' "$ENGINE/scripts/start.sh" | head -1 | cut -d: -f1)"
lib_ln="$(grep -n 'lib.sh"' "$ENGINE/scripts/start.sh" | head -1 | cut -d: -f1)"
assert_ok "start.sh migrates BEFORE it sources lib.sh (line $mig_ln < $lib_ln)" test "${mig_ln:-99}" -lt "${lib_ln:-0}"
assert_ok "update.sh runs fleet-migrate.sh --all"          grep -q 'fleet-migrate.sh" --all' "$ENGINE/update.sh"
assert_no "the roll never runs stop.sh or harness stop (it would kill every fleet's sessions)" \
  bash -c "grep -vE '^[[:space:]]*#' '$ENGINE/scripts/fleet-migrate.sh' | grep -qE 'stop\.sh|harness\"? +stop'"

kill $BYSTANDER 2>/dev/null
for f in "$ROOT"/*/.harness/run/*.pid; do kill "$(cat "$f")" 2>/dev/null; done
tmp_cleanup
finish
