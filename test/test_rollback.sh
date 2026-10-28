#!/usr/bin/env bash
# test_rollback.sh — PRD #274 / #280: a running lane never has code changed under it, a relaunch
# picks up the new release, and a bad release is one `harness update --rollback` away.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/release_fixture.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cd "$T"
export HARNESS_HOME="$T/host" HARNESS_SKIP_RTDD=1 HARNESS_SUPERVISE_UNIT_DIR="$T/units" HARNESS_WEB_UNIT_DIR="$T/units"
H="$HARNESS_HOME"; SRV="$T/srv"; rel_server "$SRV"
rel_publish "$SRV" v0.1.0; rel_publish "$SRV" v0.2.0; rel_install_at "$SRV" v0.1.0
hv(){ env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK bash "$H/engine/bin/harness" "$@"; }

# A worker as pool.sh starts one: ENGINE_DIR is what bin/harness exported (the realpath of the engine
# it was launched through), and the worker reads engine code only later — here, after the flip.
GO="$T/go"
start_worker(){ ( export ENGINE_DIR="$(realpath "$H/engine")"
  while [[ ! -f "$GO" ]]; do sleep 0.1; done; bash "$ENGINE_DIR/scripts/release-marker.sh" ) > "$1" & }
start_worker "$T/w1"; W1=$!
rel_latest "$SRV" v0.2.0; hv update >/dev/null 2>&1
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "engine flipped to B while the worker runs"
touch "$GO"; wait "$W1"
assert_eq "$(cat "$T/w1")" v0.1.0 "the live worker kept running A's files after the flip to B"
rm -f "$GO"; start_worker "$T/w2"; W2=$!; touch "$GO"; wait "$W2"
assert_eq "$(cat "$T/w2")" v0.2.0 "a relaunched worker runs B"

out="$(hv update --rollback 2>&1)"; rc=$?
assert_eq "$rc" 0 "--rollback exits 0"
assert_eq "$(readlink "$H/engine")" releases/v0.1.0 "--rollback returns engine to A"
assert_ok "names from and to" grep -qF 'rolled back Harness v0.2.0 -> v0.1.0' <<<"$out"
assert_ok "B is kept, so the rollback can be undone" test -d "$H/releases/v0.2.0"
assert_no "no stray flip link left" compgen -G "$H/engine.flip.*"

# A second --rollback goes forward again: the rollback was itself a flip, recorded in .installed.
out="$(hv update --rollback 2>&1)"; rc=$?
assert_eq "$rc" 0 "a second --rollback exits 0"
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "a second --rollback returns engine to B"
assert_ok "names from and to again" grep -qF 'rolled back Harness v0.1.0 -> v0.2.0' <<<"$out"

# Nothing to roll back to: non-zero, engine unchanged.
export HARNESS_HOME="$T/host2"; rel_install_at "$SRV" v0.1.0
out="$(env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK bash "$HARNESS_HOME/engine/bin/harness" update --rollback 2>&1)"; rc=$?
assert_eq "$rc" 2 "--rollback with no previous release exits 2"
assert_eq "$(readlink "$HARNESS_HOME/engine")" releases/v0.1.0 "and leaves engine unchanged"
assert_ok "and says so" grep -qF 'no previous release to roll back to; engine unchanged at v0.1.0' <<<"$out"
# A git-checkout engine (not yet migrated to releases) has no release to go back to: --rollback must
# refuse, never fall through to the ff-pull a plain update would run.
export HARNESS_HOME="$T/host3"; mkdir -p "$HARNESS_HOME"; cp -a "$H/releases/v0.1.0" "$HARNESS_HOME/engine"
out="$(env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK bash "$HARNESS_HOME/engine/bin/harness" update --rollback 2>&1)"; rc=$?
assert_eq "$rc" 2 "--rollback on a git-checkout engine exits 2"
assert_ok "and says there is no release to roll back to" grep -qF 'is a git checkout, not a release' <<<"$out"
assert_no "and never tries the ff-pull" grep -qF 'pull --ff-only' <<<"$out"
assert_ok "harness help documents --rollback" grep -qF -- '--rollback' <<<"$(hv help)"
finish
