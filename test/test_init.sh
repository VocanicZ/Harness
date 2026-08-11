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

echo "── init ok"
