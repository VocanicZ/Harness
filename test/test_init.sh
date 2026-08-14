#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This test asserts what `harness init` WROTE by sourcing it back, and config lines are
# `: "${VAR:=…}"` — so a live fleet's exported HARNESS_REPO / HARNESS_AUTONOMOUS win over the
# fixture's and the round-trip assertion fails on a developer machine while passing on a bare one.
# run.sh drops them for the whole suite; re-drop here so a direct `bash test_init.sh` is safe too.
source "$HERE/helpers.sh"; unset_inherited_config
TMP="$(mktemp -d)"; cp -r "$HERE/.." "$TMP/.harness"   # fake .harness checkout
export HARNESS_DIR="$TMP/.harness"
# HARNESS_DIR alone does NOT isolate this test: lib.sh recomputes it from BASH_SOURCE (scripts/lib.sh:13)
# and then takes STATE_DIR from the environment (:15). Run inside a live fleet — which exports its own
# STATE_DIR — init.sh would write this acme/widget config straight over that project's real config.
export STATE_DIR="$TMP/.harness"
# Host-level state too. lib.sh derives HARNESS_FLEETS_DIR from HARNESS_HOME at source time and then
# EXPORTS it, so an inherited one beats the HARNESS_HOME set here. run.sh now pins it for the whole
# suite, but this file never calls make_env — so on a direct `bash test_init.sh` (no env -u, no
# run.sh) nothing else would, and init.sh's default_prefix (which calls check_prefix_collision) would
# resolve the REAL ~/.harness/fleets, reading and potentially pruning a live fleet's entry. Keep both.
export HARNESS_HOME="$TMP/host"
export HARNESS_FLEETS_DIR="$HARNESS_HOME/fleets"
# stub gh + seed so init does no network
cat > "$TMP/.harness/scripts/seed.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
HARNESS_INIT_NONINTERACTIVE=1 HARNESS_MODE=prd HARNESS_TOPOLOGY=single \
  HARNESS_OWNER=acme HARNESS_REPO=acme/widget HARNESS_AUTONOMOUS=false \
  bash "$TMP/.harness/scripts/init.sh"
CFG="$TMP/.harness/config"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
assert "config written"           "[[ -f '$CFG' ]]"
assert "config uses := form"      "grep -q ':= ' '$CFG' || grep -q ':=issue' '$CFG' || grep -q 'HARNESS_MODE:=prd' '$CFG'"
# round-trip: sourcing config yields the chosen values
( source "$CFG"; [[ "${HARNESS_MODE:-}" == prd && "${HARNESS_REPO:-}" == acme/widget && "${HARNESS_AUTONOMOUS:-}" == false ]] ) \
  && echo "  ok: config round-trips" || { echo "  FAIL: round-trip"; exit 1; }
# env override: pre-set env beats file (because lines are := )
( HARNESS_MODE=planned; source "$CFG"; [[ "$HARNESS_MODE" == planned ]] ) \
  && echo "  ok: env overrides file" || { echo "  FAIL: env override"; exit 1; }
# author allowlist key is written (default empty = self-only) and round-trips
assert "author allowlist key written" "grep -q 'HARNESS_AUTHOR_ALLOWLIST' '$CFG'"
( source "$CFG"; [[ "${HARNESS_AUTHOR_ALLOWLIST-unset}" == "" ]] ) \
  && echo "  ok: author allowlist defaults empty" || { echo "  FAIL: author allowlist default"; exit 1; }
# bug-lane label keys are written with sensible defaults and round-trip
assert "bug label key written"          "grep -q 'HARNESS_LABEL_BUG:=bug' '$CFG'"
assert "bug-triaged label key written"  "grep -q 'HARNESS_LABEL_BUG_TRIAGED:=bug-triaged' '$CFG'"
( source "$CFG"; [[ "${HARNESS_LABEL_BUG:-}" == "bug" && "${HARNESS_LABEL_BUG_TRIAGED:-}" == "bug-triaged" ]] ) \
  && echo "  ok: bug-lane labels round-trip" || { echo "  FAIL: bug-lane label round-trip"; exit 1; }
# cadence keys (#24): both poll cadences are written so they're overridable in .harness/config
assert "priority-poll key written" "grep -q 'HARNESS_PRIORITY_POLL' '$CFG'"
( source "$CFG"; [[ "${HARNESS_POLL:-}" == "300" && "${HARNESS_PRIORITY_POLL:-}" == "60" ]] ) \
  && echo "  ok: poll cadences default 300/60 and round-trip" || { echo "  FAIL: poll cadence defaults"; exit 1; }

# host-poller opt-in (#74, PRD-B): init documents HARNESS_USE_POLLER so a fresh install shows the
# flag exists and is default-OFF (empty = today's direct-gh polling; set = read host snapshots).
assert "use-poller key written" "grep -q 'HARNESS_USE_POLLER' '$CFG'"
( source "$CFG"; [[ "${HARNESS_USE_POLLER-unset}" == "" ]] ) \
  && echo "  ok: HARNESS_USE_POLLER defaults off (empty) and round-trips" || { echo "  FAIL: HARNESS_USE_POLLER default-off"; exit 1; }

# ── state-only init in cwd (#55, PRD #52): `harness init` creates ./.harness/{config,run/claims,
# worktrees} in the CURRENT project dir and places NO engine code there (the engine is one shared
# host install). Run from a pristine project dir, with HARNESS_DIR/STATE_DIR unset so init defaults
# its target to $PWD/.harness.
PROJ="$(mktemp -d)"
( cd "$PROJ"; unset HARNESS_DIR STATE_DIR
  HARNESS_INIT_NONINTERACTIVE=1 HARNESS_MODE=issue-only HARNESS_TOPOLOGY=single \
    HARNESS_OWNER=acme HARNESS_REPO=acme/widget \
    bash "$HERE/../scripts/init.sh" >/dev/null 2>&1 )
assert "init writes ./.harness/config in cwd"          "[[ -f '$PROJ/.harness/config' ]]"
assert "init creates run/ state dir"                   "[[ -d '$PROJ/.harness/run' ]]"
assert "init creates run/claims state dir"             "[[ -d '$PROJ/.harness/run/claims' ]]"
assert "init creates worktrees/ state dir"             "[[ -d '$PROJ/.harness/worktrees' ]]"
# NO engine code is copied into the project's .harness/ (state only).
assert "init places no lib.sh (no engine code)"        "[[ ! -e '$PROJ/.harness/lib.sh' ]]"
assert "init places no bin/harness (no engine code)"   "[[ ! -e '$PROJ/.harness/bin' ]]"
assert "init places no engine *.sh scripts"            "[[ -z \"\$(find '$PROJ/.harness' -maxdepth 1 -name '*.sh' -print -quit 2>/dev/null)\" ]]"

# ── not-in-project error (#55): a state-requiring subcommand run OUTSIDE any Harness project (no
# .harness/config walking up) errors clearly and exits non-zero — not a cryptic deep-in-lib failure.
NOPROJ="$(mktemp -d)"
( cd "$NOPROJ"; unset HARNESS_DIR STATE_DIR
  out="$("$HERE/../bin/harness" status 2>&1)"; rc=$?
  [[ $rc -ne 0 ]] || { echo "  FAIL: subcommand outside a project should exit non-zero (got $rc)"; exit 1; }
  grep -qiE 'harness init|not (in|inside).*[Hh]arness project|\.harness/config' <<<"$out" \
    || { echo "  FAIL: not-in-project error lacks a helpful message — got: $out"; exit 1; }
  echo "  ok: subcommand outside a project errors clearly + non-zero" ) || exit 1

# --- session prefix (#: fleet prefix registry) ------------------------------------------------
# init must PROMPT for and PERSIST HARNESS_SESS_PREFIX. Before this, the key was absent from the
# config entirely, so every project on a host silently inherited lib.sh's `hz` and two fleets shared
# one tmux namespace — `harness stop` in one killed the other's live agents.
assert "session prefix key written" "grep -q 'HARNESS_SESS_PREFIX:=' '$CFG'"
( source "$CFG"; [[ "${HARNESS_SESS_PREFIX:-}" =~ ^[a-z0-9_]{1,10}$ ]] ) \
  && echo "  ok: prefix round-trips as a tmux-safe segment" || { echo "  FAIL: prefix round-trip"; exit 1; }

# The default is DERIVED from the project directory name, not the literal `hz`.
PDIR="$TMP/Widget"; mkdir -p "$PDIR/.harness"
# (No engine copy here: init.sh is invoked below from the REAL repo path, so a copy under
# $PDIR/.harness/scripts would never be read — it was dead weight, and it made the fixture look as
# if `harness init` still vendored engine code into a project, which #55 removed.)
( export STATE_DIR="$PDIR/.harness" HARNESS_DIR="$PDIR/.harness"
  HARNESS_INIT_NONINTERACTIVE=1 HARNESS_TOPOLOGY=single HARNESS_OWNER=acme HARNESS_REPO=acme/widget \
    bash "$HERE/../scripts/init.sh" >/dev/null 2>&1 )
assert "derived prefix written for project dir 'Widget'" "grep -q 'HARNESS_SESS_PREFIX:=widget' '$PDIR/.harness/config'"

# A pre-set env var still wins (non-interactive `ask` honours ${!var}).
PDIR2="$TMP/Widget2"; mkdir -p "$PDIR2/.harness"
( export STATE_DIR="$PDIR2/.harness" HARNESS_DIR="$PDIR2/.harness"
  HARNESS_INIT_NONINTERACTIVE=1 HARNESS_SESS_PREFIX=custom HARNESS_TOPOLOGY=single HARNESS_OWNER=acme \
    HARNESS_REPO=acme/widget bash "$HERE/../scripts/init.sh" >/dev/null 2>&1 )
assert "explicit HARNESS_SESS_PREFIX overrides the derived default" \
  "grep -q 'HARNESS_SESS_PREFIX:=custom' '$PDIR2/.harness/config'"

# init WARNS (never refuses — it starts nothing) when the derived prefix is already claimed, and
# offers the hash fallback instead so the operator isn't left to invent one.
#
# DEVIATION from the brief's literal fixture: the sibling's run_dir must hold a LIVE pid. A registry
# entry with neither a live tmux session (none exists here) nor a live pid is, by fleet_stale's design
# (verified in test_prefix_guard.sh's staleness group), a crashed fleet — check_prefix_collision prunes
# it and lets init through un-warned. Without a live pid this test cannot distinguish "taken" from
# "abandoned", so it would pass vacuously even with the warning path deleted.
PDIR3="$TMP/Widget3"; mkdir -p "$PDIR3/.harness"
export HARNESS_HOME="$TMP/host3"; export HARNESS_FLEETS_DIR="$HARNESS_HOME/fleets"; mkdir -p "$HARNESS_FLEETS_DIR"
SIB_RD="$(mktemp -d)"; sleep 300 & SIB_PID=$!; echo "$SIB_PID" > "$SIB_RD/worker-1.pid"
python3 - "$HARNESS_HOME/fleets/sibling.json" "$PDIR3" "$SIB_RD" <<'PY'
import json, sys
json.dump({"prefix": "widget3", "project": "/elsewhere/.harness",
           "run_dir": sys.argv[3], "slugs": ["acme/other"],
           "started_at": 0}, open(sys.argv[1], "w"))
PY
OUT="$( ( export STATE_DIR="$PDIR3/.harness" HARNESS_DIR="$PDIR3/.harness"
  HARNESS_INIT_NONINTERACTIVE=1 HARNESS_TOPOLOGY=single HARNESS_OWNER=acme HARNESS_REPO=acme/widget \
    bash "$HERE/../scripts/init.sh" ) 2>&1 )"
kill "$SIB_PID" 2>/dev/null; wait "$SIB_PID" 2>/dev/null
assert "init warns that the derived prefix is taken" "grep -qi 'in use\|taken\|collide' <<<\"\$OUT\""
assert "init still writes a config"                  "[[ -f '$PDIR3/.harness/config' ]]"
# Tightened past `!= "widget3"`: that alone would pass even on an EMPTY prefix (the M2 foot-gun —
# a stale/broken engine subshell misread as a collision). Assert the actual fallback shape instead.
( source "$PDIR3/.harness/config"; [[ "${HARNESS_SESS_PREFIX:-}" =~ ^hz[0-9a-f]{4}$ ]] ) \
  && echo "  ok: init proposed the hash-fallback prefix" || { echo "  FAIL: init did not propose a valid hash-fallback prefix (got '${HARNESS_SESS_PREFIX:-}')"; exit 1; }

# M2: a broken/stale ENGINE_DIR (a lib.sh that predates derive_prefix / check_prefix_collision — the
# session-env contamination hazard this host sees for real) must still yield a non-empty, tmux-safe
# prefix, never an empty HARNESS_SESS_PREFIX: prefixes_collide's dash-prefix rule makes an empty
# prefix collide with EVERY other fleet's, so an empty write is a live foot-gun, not a cosmetic one.
BROKEN_ENGINE="$(mktemp -d)"; mkdir -p "$BROKEN_ENGINE/scripts"
cat > "$BROKEN_ENGINE/scripts/lib.sh" <<'EOF'
#!/usr/bin/env bash
# stub: a lib.sh from before derive_prefix / check_prefix_collision existed — sources cleanly but
# defines neither function.
set -uo pipefail
PROJECT_ROOT="${STATE_DIR%/.harness}"
EOF
PDIR4="$TMP/Widget4"; mkdir -p "$PDIR4/.harness"
( export STATE_DIR="$PDIR4/.harness" HARNESS_DIR="$PDIR4/.harness" ENGINE_DIR="$BROKEN_ENGINE"
  HARNESS_INIT_NONINTERACTIVE=1 HARNESS_TOPOLOGY=single HARNESS_OWNER=acme HARNESS_REPO=acme/widget \
    bash "$HERE/../scripts/init.sh" >/dev/null 2>&1 )
( source "$PDIR4/.harness/config"; [[ -n "${HARNESS_SESS_PREFIX:-}" && "${HARNESS_SESS_PREFIX}" =~ ^[a-z0-9_]+$ ]] ) \
  && echo "  ok: a broken/stale engine still yields a non-empty, tmux-safe prefix" \
  || { echo "  FAIL: broken engine yielded an empty or invalid prefix (got '${HARNESS_SESS_PREFIX:-}')"; exit 1; }

# I2: the fixture above cannot catch the real foot-gun, because its stub lib.sh DEFINES PROJECT_ROOT.
# The dangerous ENGINE_DIR is one that does not source at all (a missing / moved engine — the exact
# session-env contamination this host sees): the source fails, PROJECT_ROOT is never set, and under
# `set -u` every reference to it aborts its command substitution, feeding EMPTY stdin to sha1. That
# yields the CONSTANT hz-da39 for every project on the host — silently, with rc=0 — reintroducing the
# shared-prefix cross-kill this whole feature exists to eliminate. The assertion that pins it is not
# "non-empty" but "two differently-named projects get two DIFFERENT prefixes".
MISSING_ENGINE="$(mktemp -d)/gone"     # no scripts/lib.sh at all: `source` fails outright
NODEF_ENGINE="$(mktemp -d)"; mkdir -p "$NODEF_ENGINE/scripts"
cat > "$NODEF_ENGINE/scripts/lib.sh" <<'EOF'
#!/usr/bin/env bash
# stub: sources cleanly but defines NEITHER derive_prefix NOR PROJECT_ROOT — the shape init.sh must
# not depend on. (A partial engine, or one whose own `set -u` aborted it part-way through.)
set -uo pipefail
EOF
init_prefix_under(){   # <engine-dir> <project-dir> -> the prefix init wrote for that project
  local eng="$1" pdir="$2"; mkdir -p "$pdir/.harness"
  ( export STATE_DIR="$pdir/.harness" HARNESS_DIR="$pdir/.harness" ENGINE_DIR="$eng"
    HARNESS_INIT_NONINTERACTIVE=1 HARNESS_TOPOLOGY=single HARNESS_OWNER=acme HARNESS_REPO=acme/widget \
      bash "$HERE/../scripts/init.sh" >/dev/null 2>&1 )
  ( source "$pdir/.harness/config"; printf '%s' "${HARNESS_SESS_PREFIX:-}" )
}
for eng_label in "$NODEF_ENGINE:lib.sh without PROJECT_ROOT" "$MISSING_ENGINE:missing engine"; do
  eng="${eng_label%%:*}"; label="${eng_label#*:}"
  P_A="$(init_prefix_under "$eng" "$TMP/BrokenAlpha")"
  P_B="$(init_prefix_under "$eng" "$TMP/BrokenBravo")"
  assert "broken engine ($label): prefix is non-empty and tmux-safe" \
    "[[ '$P_A' =~ ^[a-z0-9_]+$ ]]"
  # THE assertion: a per-project prefix, not one constant hash of the empty string.
  assert "broken engine ($label): two projects get DIFFERENT prefixes (got '$P_A' vs '$P_B')" \
    "[[ '$P_A' != '$P_B' ]]"
done

echo "── init ok"
