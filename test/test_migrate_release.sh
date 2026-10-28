#!/usr/bin/env bash
# test_migrate_release.sh — PRD #274 / #281: `harness update` moves a git-checkout engine aside
# (local edits kept, no destructive git op) and onto releases; units and the PATH link resolve
# through the stable $HARNESS_HOME/engine path, and a launched worker gets the concrete release.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/release_fixture.sh"
gc(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cd "$T"
export HARNESS_HOME="$T/host" HARNESS_SKIP_RTDD=1 HARNESS_SUPERVISE_UNIT_DIR="$T/units" HARNESS_WEB_UNIT_DIR="$T/units" \
  HARNESS_SUPERVISE_SYSTEMCTL=true HARNESS_SUPERVISE_LOGINCTL=true HARNESS_WEB_SYSTEMCTL=true HARNESS_WEB_LOGINCTL=true
H="$HARNESS_HOME"; SRV="$T/srv"; rel_server "$SRV"; rel_publish "$SRV" v0.2.0; rel_latest "$SRV" v0.2.0
clean(){ env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK "$@"; }

# Today's host: $HARNESS_HOME/engine is a git checkout of this engine, with an uncommitted local edit,
# and units installed from it.
mkdir -p "$H/engine"
( cd "$HERE/.." && tar -cf - bin scripts prompts skill plugins install.sh update.sh ) | tar -xf - -C "$H/engine"
gc "$H/engine" init -q; gc "$H/engine" add -A; gc "$H/engine" commit -qm engine
sha="$(git -C "$H/engine" rev-parse --short=12 HEAD)"
printf '# local edit\n' >> "$H/engine/scripts/lib.sh"
clean bash "$H/engine/bin/harness" supervise --install >/dev/null 2>&1
clean bash "$H/engine/bin/harness" web --install >/dev/null 2>&1

out="$(clean bash "$H/engine/bin/harness" update 2>&1)"; rc=$?
assert_eq "$rc" 0 "the migrating update exits 0"
assert_ok "engine is now a symlink" test -L "$H/engine"
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "engine points at the latest release"
assert_ok "the old tree is kept under releases/git-<sha>" test -d "$H/releases/git-$sha/.git"
assert_ok "its local edit is kept, not discarded" grep -qx '# local edit' "$H/releases/git-$sha/scripts/lib.sh"
assert_eq "$(git -C "$H/releases/git-$sha" status --porcelain | xargs)" "M scripts/lib.sh" "the old tree's git state is untouched"
for u in harness-supervise.service harness-web.service; do
  assert_ok "$u runs the stable engine path" grep -qE "^ExecStart=$H/engine/bin/harness " "$T/units/$u"
  assert_no "$u pins no versioned dir" grep -qF "$H/releases/" "$T/units/$u"
done

# bin/harness through a PATH link: units get the stable path, a launched worker the concrete release.
ln -s "$H/engine/bin/harness" "$T/harness"
v="$(clean bash "$T/harness" --version --verbose)"
assert_ok "a launched worker's ENGINE_DIR is the concrete release" grep -qx "engine: $H/releases/v0.2.0" <<<"$v"
assert_ok "units resolve through the stable engine path" grep -qx "stable: $H/engine" <<<"$v"
clean bash "$T/harness" supervise --install >/dev/null 2>&1
assert_ok "a unit installed from a release still names the stable path" \
  grep -qx "ExecStart=$H/engine/bin/harness supervise" "$T/units/harness-supervise.service"
env -u STATE_DIR ENGINE_DIR="$H/releases/v0.2.0" HARNESS_ENGINE_LINK="$T/elsewhere" \
  bash "$H/releases/v0.2.0/scripts/web.sh" --install >/dev/null 2>&1
assert_ok "an inherited link that is not this engine never redirects a unit" \
  grep -qx "ExecStart=$H/releases/v0.2.0/bin/harness web" "$T/units/harness-web.service"

clean bash "$H/engine/bin/harness" update --rollback >/dev/null 2>&1
assert_eq "$(readlink "$H/engine")" "releases/git-$sha" "--rollback right after migration returns to the old tree"

# The old tree counts as a release for retention: it is one of the previous 2 kept, and once it
# is not, it is still never pruned while a live worker's ENGINE_DIR points into it.
rel_publish "$SRV" v0.3.0; rel_latest "$SRV" v0.3.0; clean bash "$H/engine/bin/harness" update >/dev/null 2>&1
rel_publish "$SRV" v0.4.0; rel_latest "$SRV" v0.4.0; clean bash "$H/engine/bin/harness" update >/dev/null 2>&1
assert_eq "$(readlink "$H/engine")" releases/v0.4.0 "updates go on from the migrated host"
assert_ok "the old tree is kept as one of the previous 2" test -d "$H/releases/git-$sha"
assert_no "an older release beyond them is pruned" test -e "$H/releases/v0.2.0"
ENGINE_DIR="$H/releases/git-$sha" sleep 300 & live=$!
rel_publish "$SRV" v0.5.0; rel_latest "$SRV" v0.5.0; clean bash "$H/engine/bin/harness" update >/dev/null 2>&1
assert_eq "$(readlink "$H/engine")" releases/v0.5.0 "the next update installs v0.5.0"
assert_ok "the old tree is never pruned while a live worker runs from it" test -d "$H/releases/git-$sha/.git"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null

# No release published yet: a git engine is left exactly where it is.
export HARNESS_HOME="$T/host2"; mkdir -p "$HARNESS_HOME"; cp -a "$H/releases/git-$sha" "$HARNESS_HOME/engine"
rel_latest "$SRV" ""; clean bash "$HARNESS_HOME/engine/bin/harness" update >/dev/null 2>&1
assert_ok "with nothing published, the git engine stays a directory" test -d "$HARNESS_HOME/engine/.git"
assert_no "and no releases/ dir appears" test -e "$HARNESS_HOME/releases"

# A git checkout that is NOT the host engine (a dev clone, a test sandbox) updating itself leaves the
# host's git engine alone: it keeps its own ff-pull and never migrates $HARNESS_HOME/engine.
export HARNESS_HOME="$T/host3"; mkdir -p "$HARNESS_HOME"; cp -a "$H/releases/git-$sha" "$HARNESS_HOME/engine"
cp -a "$H/releases/git-$sha" "$T/clone"; rel_latest "$SRV" v0.5.0
clean env ENGINE_DIR="$T/clone" bash "$T/clone/update.sh" >/dev/null 2>&1
assert_ok "another checkout's update leaves the host's git engine a directory" test -d "$HARNESS_HOME/engine/.git"
assert_no "and migrates nothing" test -e "$HARNESS_HOME/releases"
finish
