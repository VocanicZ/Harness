#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"
_HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1
source "$HERE/../scripts/pool-worker.sh"   # defines worker_tick; main() guarded out
source "$HERE/helpers.sh"; make_env
HARNESS_TOPOLOGY=multi
write_targets <<'EOF'
a	acme/a	-	root
b	acme/b	a	needs a
EOF
seed_if_needed(){ :; }            # no real gh
drive_unit(){ set_complete $(cat "$COMPLETE_SET") "$1"; }  # "driving" marks it complete
set_complete
worker_tick W1; assert_eq "$?" "0" "claimed a + drove -> rc 0"
assert_ok "a now complete" unit_complete a
worker_tick W1; assert_eq "$?" "0" "claimed b + drove -> rc 0"
worker_tick W1; assert_eq "$?" "2" "all complete -> rc 2 (resident: idle, not retire)"

# --- resident pool (#24): worker_step idles on all_complete instead of retiring ----
# worker_step wraps worker_tick: rc 0 does work, rc 2 (all_complete) logs an idle banner
# ONCE per idle streak (deduped across polls) and keeps polling — it must NOT exit.
POLL=0
IDLELOG="$RUN_DIR/idle.log"; : > "$IDLELOG"
worker_step W1 >>"$IDLELOG" 2>&1; assert_eq "$?" "2" "worker_step: all_complete -> rc 2 (no exit/retire)"
worker_step W1 >>"$IDLELOG" 2>&1
worker_step W1 >>"$IDLELOG" 2>&1; assert_eq "$?" "2" "worker_step: still resident after 3 polls"
assert_eq "$(grep -c 'idle, watching' "$IDLELOG")" "1" "worker_step: idle banner logged exactly once (deduped)"

# inject new claimable work -> claimed on the NEXT poll with no restart; dedup resets
write_targets <<'EOF'
a	acme/a	-	root
b	acme/b	a	needs a
c	acme/c	-	injected
EOF
worker_step W1 >>"$IDLELOG" 2>&1; assert_eq "$?" "0" "worker_step: injected unit claimed+driven -> rc 0 (no restart)"
assert_ok "injected unit c now complete" unit_complete c
: > "$IDLELOG"
worker_step W1 >>"$IDLELOG" 2>&1; assert_eq "$?" "2" "worker_step: all complete again -> rc 2"
assert_eq "$(grep -c 'idle, watching' "$IDLELOG")" "1" "worker_step: idle banner re-logged after work (dedup reset)"

# ───────────────────── PRD-B slice 3 (#72): pool worker snapshot dispatch gate ─────────────────────
# With HARNESS_USE_POLLER set the pool reads dispatch from the host snapshot instead of GitHub. A
# stale/missing/unknown-schema snapshot HOLDS new dispatch (claim nothing, no gh, deduped banner,
# relaunch the poller) while leaving in-flight claims running; a fresh snapshot serves the claim.
# Flag OFF = today's path (every assertion above ran with it unset). Host-root SEAMS point at a temp
# dir so nothing touches the real ~/.harness; this is the LAST block so its global edits leak nowhere.
S3="$(mktemp -d)"
HARNESS_HOME="$S3/host"; HARNESS_POLLER_DIR="$S3/host/poller"; HARNESS_SNAPSHOTS_DIR="$S3/host/snapshots"
POLLER_REGISTRY_DIR="$HARNESS_POLLER_DIR/registry"; POLLER_PID="$HARNESS_POLLER_DIR/poller.pid"; POLLER_LOCK="$HARNESS_POLLER_DIR/poller.lock"
mkdir -p "$HARNESS_SNAPSHOTS_DIR" "$POLLER_REGISTRY_DIR"
export HARNESS_HOME HARNESS_POLLER_DIR HARNESS_SNAPSHOTS_DIR
export HARNESS_POLLER_CMD="sleep 30"            # stand-in poller: ensure_poller won't launch the real loop
HARNESS_USE_POLLER=1; HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; HARNESS_OWNER=acme
poller_register acme/widget 60 hz "$S3/proj"    # so poller_cadence_for acme/widget = 60 (the refresh interval)
s3_snap(){ cat > "$HARNESS_SNAPSHOTS_DIR/acme__widget.json" <<JSON
{"schema_version":1,"generated_at":$1,"slug":"acme/widget","issues":[{"number":8,"title":"free","state":"OPEN","body":"","labels":[{"name":"ready-for-agent"}],"author":{"login":"me"}}],"has_plan":false,"plan_marker":null,"self_login":"me"}
JSON
}
NOW="$(date +%s)"

# ── ensure_snapshot_fresh: present + known-schema + young = fresh; else HOLD (never a gh call) ──
s3_snap "$NOW";            assert_ok "ensure_snapshot_fresh: fresh snapshot"                 ensure_snapshot_fresh acme/widget
s3_snap "$((NOW-100000))"; assert_no "ensure_snapshot_fresh: stale (generated_at too old)"   ensure_snapshot_fresh acme/widget
rm -f "$HARNESS_SNAPSHOTS_DIR/acme__widget.json"
                           assert_no "ensure_snapshot_fresh: missing snapshot"               ensure_snapshot_fresh acme/widget
printf '{"schema_version":999,"generated_at":%s,"slug":"acme/widget","issues":[]}\n' "$NOW" > "$HARNESS_SNAPSHOTS_DIR/acme__widget.json"
                           assert_no "ensure_snapshot_fresh: unknown/newer schema_version"   ensure_snapshot_fresh acme/widget

# ── snapshot_gate: flag OFF = no-op; flag ON + fresh = serve+export+ensure_poller; stale = hold ──
rm -f "$POLLER_PID"
( unset HARNESS_USE_POLLER; snapshot_gate ); assert_eq "$?" "0" "snapshot_gate: flag OFF -> 0 (today's path)"
assert_ok "snapshot_gate: flag OFF launches no poller" bash -c "[[ ! -f '$POLLER_PID' ]]"

s3_snap "$NOW"; unset HARNESS_SNAPSHOT_FILE HARNESS_SNAPSHOT_DIR
snapshot_gate; assert_eq "$?" "0" "snapshot_gate: flag ON + fresh -> 0 (serve)"
assert_eq "$HARNESS_SNAPSHOT_FILE" "$HARNESS_SNAPSHOTS_DIR/acme__widget.json" "snapshot_gate: fresh exports HARNESS_SNAPSHOT_FILE"
assert_eq "$HARNESS_SNAPSHOT_DIR"  "$HARNESS_SNAPSHOTS_DIR"                    "snapshot_gate: fresh exports HARNESS_SNAPSHOT_DIR"
gp="$(cat "$POLLER_PID" 2>/dev/null)"; assert_ok "snapshot_gate: ensured a poller is alive (self-heal every tick)" kill -0 "$gp"

# kill the poller pid -> the next gate relaunches it (G3 / acceptance: dead poller self-heals)
kill "$gp" 2>/dev/null; wait "$gp" 2>/dev/null
snapshot_gate >/dev/null 2>&1
gp2="$(cat "$POLLER_PID" 2>/dev/null)"; assert_ok "snapshot_gate: relaunched the dead poller"        kill -0 "$gp2"
assert_ok "snapshot_gate: relaunched poller has a NEW pid" bash -c "[[ '$gp2' != '$gp' ]]"

s3_snap "$((NOW-100000))"
snapshot_gate; assert_eq "$?" "1" "snapshot_gate: flag ON + stale -> 1 (hold)"

# ── worker_step: stale HOLDS new dispatch (no claim, no gh), deduped banner; in-flight untouched ──
POLL=0; _IDLE_LOGGED=0
S3CLAIM="$S3/claim.log"; S3GH="$S3/gh.log"; : > "$S3CLAIM"; : > "$S3GH"
claim_next(){ echo called >> "$S3CLAIM"; echo ""; }   # record any claim attempt; never returns a unit
gh(){ echo "$*" >> "$S3GH"; }                          # any gh read on a held tick is a failure
echo "W9 99999" > "$CLAIMS_DIR/inflight.claim"         # an in-flight claim a hold must NOT disturb
S3HOLD="$S3/hold.log"; : > "$S3HOLD"
s3_snap "$((NOW-100000))"                              # stale
worker_step W1 >>"$S3HOLD" 2>&1; assert_eq "$?" "4" "worker_step: stale snapshot HOLDS dispatch (rc 4)"
assert_eq "$(cat "$S3CLAIM")" "" "worker_step: held tick made NO claim"
assert_eq "$(cat "$S3GH")"    "" "worker_step: held tick made NO gh read"
assert_ok "worker_step: held tick left the in-flight claim untouched" bash -c "[[ -f '$CLAIMS_DIR/inflight.claim' ]]"
worker_step W1 >>"$S3HOLD" 2>&1; worker_step W1 >>"$S3HOLD" 2>&1
assert_eq "$(grep -c 'snapshot stale' "$S3HOLD")" "1" "worker_step: hold banner logged once (deduped)"

# fresh again -> dispatch proceeds (claim consulted), still no stray gh (served from the snapshot)
: > "$S3CLAIM"; : > "$S3GH"; s3_snap "$NOW"
worker_step W1 >/dev/null 2>&1
assert_ok "worker_step: fresh snapshot lets dispatch proceed (claim consulted)" bash -c "[[ -s '$S3CLAIM' ]]"
assert_eq "$(cat "$S3GH")" "" "worker_step: fresh dispatch read served from the snapshot (no gh)"
rm -f "$CLAIMS_DIR/inflight.claim"
[[ -f "$POLLER_PID" ]] && kill "$(cat "$POLLER_PID")" 2>/dev/null
rm -rf "$S3"

finish
