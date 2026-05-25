#!/usr/bin/env bash
# test_poller.sh — PRD-B slice 2 (#71): the host poller process + refcounted registry.
# Proves: register/deregister is refcounted (a slug stays registered while ANY project references
# it); one poller writes ATOMIC, VERSIONED snapshots for ≥2 repos; the effective cadence for a slug
# is the FASTEST (min) registrant cadence; an empty registry makes the poller idle/exit; and
# ensure_poller is idempotent and relaunches a dead pid. Workers are NOT wired here (slice 3).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$(mktemp -d)"
# host-root seams point at a temp dir (NOT the real ~/.harness). Set BEFORE sourcing lib.sh so its
# `${VAR:-default}` resolution picks them up; exported so the nohup'd poller child inherits them.
export HARNESS_HOME="$WORK/host"
export HARNESS_POLLER_DIR="$WORK/host/poller"
export HARNESS_SNAPSHOTS_DIR="$WORK/host/snapshots"
export STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"   # keeps RUN_DIR/worktrees out of the engine tree

source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
POLLER="$HERE/../scripts/poller.sh"
BIN="$HERE/../bin/harness"

PA="$WORK/projA/.harness"; PB="$WORK/projB/.harness"; mkdir -p "$PA" "$PB"

# ── 1) registry refcount + min-cadence selection ─────────────────────────────
# Two projects register the SAME slug at different cadences. The slug must stay registered while
# either still references it, and its effective cadence is the FASTEST of the live registrants.
poller_register acme/widget 60  hz   "$PA"
poller_register acme/widget 300 hzli "$PB"
assert_eq "$(poller_registry_slugs)" "acme/widget" "both projects on one slug -> ONE deduped slug"
assert_eq "$(poller_cadence_for acme/widget)" "60" "effective cadence = fastest registrant (60 vs 300)"

poller_deregister "$PA"
assert_eq "$(poller_registry_slugs)" "acme/widget" "slug STAYS after projA leaves (projB still refs it)"
assert_eq "$(poller_cadence_for acme/widget)" "300" "cadence recomputed to surviving registrant (300)"

poller_deregister "$PB"
assert_eq "$(poller_registry_slugs)" "" "slug GONE once the last project deregisters (refcount 0)"

# deregister removes ONLY the calling project's entries (a second slug projA also holds survives)
poller_register acme/widget 60 hz   "$PA"
poller_register acme/lib    90 hz   "$PA"
poller_register acme/widget 60 hzli "$PB"
poller_deregister "$PB"
assert_eq "$(poller_registry_slugs | tr '\n' ' ')" "acme/lib acme/widget " "dereg(projB) leaves projA's two slugs intact"
poller_deregister "$PA"
assert_eq "$(poller_registry_slugs)" "" "dereg(projA) clears the rest"

# ── 2) one poller writes atomic, versioned snapshots for ≥2 repos ────────────
FIX="$WORK/fixtures"; GHBIN="$WORK/ghbin"; mkdir -p "$FIX" "$GHBIN"
cat > "$FIX/issues_acme__widget.json" <<'JSON'
[ {"number":8,"title":"free","state":"OPEN","body":"","labels":[{"name":"ready-for-agent"}],"author":{"login":"me"}} ]
JSON
cat > "$FIX/issues_acme__lib.json" <<'JSON'
[ {"number":42,"title":"dep","state":"CLOSED","body":"","labels":[],"author":{"login":"me"}} ]
JSON
# fixture-driven gh stub (issue list + api user + api contents) — same shape as test_snapshot.sh.
cat > "$GHBIN/gh" <<'STUB'
#!/usr/bin/env bash
sub="${1:-}"; shift || true
case "$sub" in
  issue)
    action="${1:-}"; shift || true; slug=""
    while [[ $# -gt 0 ]]; do case "$1" in -R) slug="$2"; shift 2;; --json|--state|--limit|--jq) shift 2;; --*) shift;; *) shift;; esac; done
    key="${slug//\//__}"
    [[ "$action" == "list" ]] && { f="$GH_FIXTURE_DIR/issues_${key}.json"; [[ -f "$f" ]] && cat "$f" || echo "[]"; }
    ;;
  api)
    path="${1:-}"; shift || true
    case "$path" in user) printf '%s' "${GH_SELF_LOGIN:-me}";; *) exit 1;; esac
    ;;
  *) exit 1;;
esac
STUB
chmod +x "$GHBIN/gh"

poller_register acme/widget 60 hz "$PA"
poller_register acme/lib    60 hz "$PA"
WS="$HARNESS_SNAPSHOTS_DIR/acme__widget.json"; LS="$HARNESS_SNAPSHOTS_DIR/acme__lib.json"

PATH="$GHBIN:$PATH" GH_FIXTURE_DIR="$FIX" GH_SELF_LOGIN=me HARNESS_OWNER=acme \
  bash "$POLLER" --once
assert_ok "poller --once wrote the acme/widget snapshot" test -f "$WS"
assert_ok "poller --once wrote the acme/lib snapshot"     test -f "$LS"
# atomic: tmp + rename leaves NO partial files behind in the snapshots dir.
assert_eq "$(find "$HARNESS_SNAPSHOTS_DIR" -name '*.tmp*' | wc -l | tr -d ' ')" "0" "no .tmp partial snapshots remain"

assert_ok "widget snapshot is valid, versioned JSON for the right slug" python3 - "$WS" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["schema_version"]>=1, d
assert d["generated_at"]>0, d
assert d["slug"]=="acme/widget", d
assert isinstance(d["issues"],list) and d["issues"][0]["number"]==8, d
PY
assert_ok "lib snapshot carries its own slug + issues" python3 - "$LS" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["slug"]=="acme/lib" and d["issues"][0]["number"]==42, d
PY

# the snapshots are READABLE back through issuelib's snapshot seam (slice-1 contract still holds).
assert_eq "$(HARNESS_SNAPSHOT_FILE="$WS" HARNESS_SNAPSHOT_DIR="$HARNESS_SNAPSHOTS_DIR" \
            HARNESS_OWNER=acme HARNESS_AUTONOMOUS=true HARNESS_AUTHOR_ALLOWLIST= GH_SELF_LOGIN=me \
            PATH="$GHBIN:$PATH" python3 "$HERE/../scripts/issuelib.py" dispatch acme/widget 3)" \
          "$(printf 'IMPL\t8\tISSUE 8 DONE')" "snapshot written by the poller serves dispatch"

# bin/harness poll --once is the documented debug entry (engine-level, no project state needed).
rm -f "$WS"
PATH="$GHBIN:$PATH" GH_FIXTURE_DIR="$FIX" GH_SELF_LOGIN=me HARNESS_OWNER=acme \
  bash "$BIN" poll --once
assert_ok "harness poll --once regenerates the snapshot" test -f "$WS"

# ── 3) empty registry → poller idles/exits (never spins forever) ─────────────
poller_deregister "$PA"
assert_eq "$(poller_registry_slugs)" "" "registry now empty"
rm -f "$WS" "$LS"
# loop mode with an empty registry must return promptly (exit/idle), not hang.
if command -v timeout >/dev/null; then
  timeout 10 bash "$POLLER"; rc=$?
else
  bash "$POLLER"; rc=$?
fi
assert_eq "$rc" "0" "empty-registry poller exits 0 (idle/exit, no spin)"
assert_eq "$(find "$HARNESS_SNAPSHOTS_DIR" -name '*.json' | wc -l | tr -d ' ')" "0" "empty registry writes no snapshots"

# ── 4) ensure_poller: launch-if-dead, idempotent, relaunches a dead pid ──────
# Use the HARNESS_POLLER_CMD seam to stand in a long-lived process for the real loop, so liveness
# is deterministic without depending on the loop's timing.
export HARNESS_POLLER_CMD="sleep 30"
rm -f "$POLLER_PID"
ensure_poller
pid1="$(cat "$POLLER_PID" 2>/dev/null)"
assert_ok "ensure_poller launched a poller when none ran" kill -0 "$pid1"

ensure_poller
pid2="$(cat "$POLLER_PID" 2>/dev/null)"
assert_eq "$pid2" "$pid1" "ensure_poller is idempotent — a live poller is not respawned"

kill "$pid1" 2>/dev/null; wait "$pid1" 2>/dev/null
assert_no "killed poller pid is dead" bash -c "kill -0 $pid1 2>/dev/null"
ensure_poller
pid3="$(cat "$POLLER_PID" 2>/dev/null)"
assert_ok "ensure_poller relaunched after the pid died" kill -0 "$pid3"
assert_ok "relaunched poller has a NEW pid" bash -c "[[ '$pid3' != '$pid1' ]]"
kill "$pid3" 2>/dev/null; wait "$pid3" 2>/dev/null

rm -rf "$WORK"
finish
