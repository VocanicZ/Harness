#!/usr/bin/env bash
# test_update_prerelease.sh — #331: an engine installed BEFORE releases reaches one in two
# `harness update` runs. Its own update.sh is the pre-release updater (test/fixtures/
# update-prerelease.sh, vendored verbatim from `git show aa6e9fd:update.sh`: the release gate runs
# this suite on a `git archive` with no history), which only fast-forwards to main. The second run is
# main's update.sh: with nothing published it says "named no release" and stays a git checkout; once
# a release exists it migrates the engine onto it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/release_fixture.sh"
gc(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cd "$T"
export HARNESS_HOME="$T/host" HARNESS_SKIP_RTDD=1 HARNESS_SUPERVISE_UNIT_DIR="$T/units" HARNESS_WEB_UNIT_DIR="$T/units" \
  HARNESS_SUPERVISE_SYSTEMCTL=true HARNESS_SUPERVISE_LOGINCTL=true HARNESS_WEB_SYSTEMCTL=true HARNESS_WEB_LOGINCTL=true
H="$HARNESS_HOME"; SRV="$T/srv"; rel_server "$SRV"; rel_latest "$SRV" ""
clean(){ env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK "$@"; }

# origin: a pre-release engine commit (its update.sh the old updater), then main's current tree.
O="$T/origin.git"; W="$T/work"; git init -q --bare -b main "$O"; mkdir -p "$W"
( cd "$HERE/.." && tar -cf - bin scripts prompts skill plugins install.sh update.sh ) | tar -xf - -C "$W"
cp "$HERE/fixtures/update-prerelease.sh" "$W/update.sh"
gc "$W" init -q -b main; gc "$W" add -A; gc "$W" commit -qm 'pre-release engine'
gc "$W" remote add origin "$O"; gc "$W" push -q -u origin main
mkdir -p "$H"; git clone -q "$O" "$H/engine"
assert_ok "the host engine starts on the pre-release updater" cmp -s "$H/engine/update.sh" "$HERE/fixtures/update-prerelease.sh"
cp "$HERE/../update.sh" "$W/update.sh"; gc "$W" commit -qam 'main: the release-aware updater'; gc "$W" push -q origin main
main="$(git -C "$W" rev-parse HEAD)"

# ── 1st update: the old updater only fast-forwards to main ──
out="$(clean bash "$H/engine/bin/harness" update 2>&1)"; rc=$?
assert_eq "$rc" 0 "the first update (the pre-release updater) exits 0"
assert_ok "the engine is still a git checkout" test -d "$H/engine/.git"
assert_no "not a symlink" test -L "$H/engine"
assert_eq "$(git -C "$H/engine" rev-parse HEAD)" "$main" "now at main's commit"
assert_ok "with main's release-aware update.sh" cmp -s "$H/engine/update.sh" "$HERE/../update.sh"

# ── 2nd update, nothing published: says so and stays a git checkout ──
out="$(clean bash "$H/engine/bin/harness" update 2>&1)"; rc=$?
assert_eq "$rc" 0 "the second update with no release exits 0"
assert_ok "it prints 'named no release'" grep -q 'named no release' <<<"$out"
assert_ok "the engine is still a git checkout" test -d "$H/engine/.git"
assert_no "and no releases/ dir appears" test -e "$H/releases"

# ── a release is published: the next update migrates onto it ──
rel_publish "$SRV" v0.1.0; rel_latest "$SRV" v0.1.0
sha="$(git -C "$H/engine" rev-parse --short=12 HEAD)"
out="$(clean bash "$H/engine/bin/harness" update 2>&1)"; rc=$?
assert_eq "$rc" 0 "the migrating update exits 0"
[[ "$rc" == 0 ]] || tail -n 20 <<<"$out"
assert_ok "engine is now a symlink" test -L "$H/engine"
assert_eq "$(readlink "$H/engine")" releases/v0.1.0 "pointing at releases/v0.1.0"
assert_ok "the old tree is kept under releases/git-<sha>" test -d "$H/releases/git-$sha/.git"
assert_ok "harness --version prints v0.1.0" grep -qw 'v0.1.0' <<<"$(clean bash "$H/engine/bin/harness" --version)"
finish
