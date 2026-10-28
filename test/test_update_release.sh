#!/usr/bin/env bash
# test_update_release.sh — PRD #274 / #279: `harness update` follows releases the way `rtdd update`
# does: semver compare, download + SHA256SUMS verify, extract under releases/, atomic engine flip,
# keep the current release and the previous 2, never prune one a live process runs from.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/release_fixture.sh"
T="$(mktemp -d)"; LIVE=""
trap '[[ -n "$LIVE" ]] && kill "$LIVE" 2>/dev/null; rm -rf "$T"' EXIT; cd "$T"
export HARNESS_HOME="$T/host" HARNESS_SKIP_RTDD=1 HARNESS_SUPERVISE_UNIT_DIR="$T/units" HARNESS_WEB_UNIT_DIR="$T/units"
export HARNESS_SUPERVISE_SYSTEMCTL=true HARNESS_SUPERVISE_LOGINCTL=true HARNESS_WEB_SYSTEMCTL=true HARNESS_WEB_LOGINCTL=true
H="$HARNESS_HOME"; SRV="$T/srv"; rel_server "$SRV"
rel_publish "$SRV" v0.1.0; rel_publish "$SRV" v0.2.0
rel_install_at "$SRV" v0.1.0
upd(){ env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK -u HARNESS_REF bash "$H/engine/bin/harness" update "$@"; }
snap(){ readlink "$H/engine"; ls -A "$H/releases" | sort; }

# ── already current ──
rel_latest "$SRV" v0.1.0; before="$(snap)"
out="$(upd 2>&1)"; rc=$?
assert_eq "$rc" 0 "latest == installed exits 0"
assert_ok "rtdd's message, word for word" grep -qx 'Harness v0.1.0 is the latest release.' <<<"$out"
assert_eq "$(snap)" "$before" "engine target and releases/ unchanged when current"

# ── a newer release ──
rel_latest "$SRV" v0.2.0
out="$(upd 2>&1)"; rc=$?
assert_eq "$rc" 0 "an update exits 0"
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "engine flipped to the new release"
assert_eq "$(sed -n 1p "$H/engine/VERSION")" v0.2.0 "the new release's VERSION is live"
assert_ok "names what it did" grep -qF "updated Harness v0.1.0 -> v0.2.0 at $H/releases/v0.2.0" <<<"$out"
assert_ok "the redeploy tail ran" grep -qx 'Update complete.' <<<"$out"
assert_ok "v0.1.0 kept for rollback" test -d "$H/releases/v0.1.0"
assert_no "no stray flip link left" compgen -G "$H/engine.flip.*"
assert_eq "$(tail -1 "$H/releases/.installed")" v0.2.0 "the flip is recorded in releases/.installed"

# ── a bad checksum changes nothing and leaves nothing ──
rel_publish "$SRV" v0.3.0; rel_latest "$SRV" v0.3.0
good="$(cat "$SRV/download/v0.3.0/SHA256SUMS")"
printf '%064d  harness-v0.3.0.tar.gz\n' 0 > "$SRV/download/v0.3.0/SHA256SUMS"
out="$(upd 2>&1)"; rc=$?
assert_eq "$rc" 3 "a checksum mismatch is an environment failure (exit 3)"
assert_ok "says checksum mismatch" grep -qF 'checksum mismatch for harness-v0.3.0.tar.gz' <<<"$out"
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "engine unchanged after a bad checksum"
assert_no "no partial release dir" test -e "$H/releases/v0.3.0"
assert_no "no staging dir left" compgen -G "$H/releases/.staging-*"
printf '%064d  harness-other.tar.gz\n' 0 > "$SRV/download/v0.3.0/SHA256SUMS"
out="$(upd 2>&1)"; rc=$?
assert_eq "$rc" 3 "an unlisted archive exits 3"
assert_ok "an unlisted archive fails, never skips" grep -qF 'SHA256SUMS carries no entry for harness-v0.3.0.tar.gz' <<<"$out"
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "engine unchanged after an unlisted archive"
printf '%s\n' "$good" > "$SRV/download/v0.3.0/SHA256SUMS"

# ── nothing published; API unreachable ──
rel_latest "$SRV" ""; out="$(upd 2>&1)"; rc=$?
assert_eq "$rc" 0 "no published release is not an error"
assert_ok "says the endpoint named no release" grep -qF 'named no release' <<<"$out"
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "engine unchanged when nothing is published"
out="$(HARNESS_API_URL="file://$T/nope.json" upd 2>&1)"; rc=$?
assert_eq "$rc" 3 "an unreachable API exits 3"
assert_ok "says it could not resolve the latest release" grep -qF "could not resolve the latest release from file://$T/nope.json" <<<"$out"
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "engine unchanged when the API is unreachable"

# ── retention: current + previous 2, plus whatever a live process runs from ──
rel_publish "$SRV" v0.4.0; rel_publish "$SRV" v0.5.0
ENGINE_DIR="$H/releases/v0.1.0" sleep 300 & LIVE=$!
for t in v0.3.0 v0.4.0 v0.5.0; do rel_latest "$SRV" "$t"; upd >/dev/null 2>&1; done
assert_eq "$(ls "$H/releases" | sort | xargs)" "v0.1.0 v0.3.0 v0.4.0 v0.5.0" \
  "kept the current release, the previous 2, and the one a live worker runs from"
kill "$LIVE"; wait "$LIVE" 2>/dev/null; LIVE=""
rel_publish "$SRV" v0.6.0; rel_latest "$SRV" v0.6.0; upd >/dev/null 2>&1
assert_eq "$(ls "$H/releases" | sort | xargs)" "v0.4.0 v0.5.0 v0.6.0" "a release nobody runs is pruned"

# ── semver order, not string order ──
source_install(){ HARNESS_INSTALL_NOMAIN=1 source "$HERE/../install.sh"; }
source_install
assert_eq "$(semver_cmp v0.10.0 v0.9.9)" 1 "0.10.0 is newer than 0.9.9"
assert_eq "$(semver_cmp v0.2.0-rc1 v0.2.0)" -1 "a pre-release sorts below its release"
assert_eq "$(semver_cmp 1.2.3 v1.2.3)" 0 "a leading v is optional"
assert_no "a non-version is refused, not coerced" semver_cmp dev v0.1.0
finish
