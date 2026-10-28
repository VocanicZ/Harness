#!/usr/bin/env bash
# test_install_release.sh — PRD #274 / #282: install.sh installs the latest release (or HARNESS_REF's)
# through the same verify-then-flip path as `harness update`, and leaves nothing half-installed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/release_fixture.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cd "$T"
SRV="$T/srv"; rel_server "$SRV"; rel_publish "$SRV" v0.1.0; rel_publish "$SRV" v0.2.0; rel_latest "$SRV" v0.2.0
fresh(){ export HOME="$T/home$1" HARNESS_HOME="$T/home$1/.harness" HARNESS_BIN_DIR="$T/home$1/.local/bin"; mkdir -p "$HOME"; }
inst(){ ( HARNESS_INSTALL_NOMAIN=1 source "$HERE/../install.sh" && place_engine && link_path ); }

fresh 1; out="$(inst 2>&1)"; rc=$?
assert_eq "$rc" 0 "a clean install exits 0"
assert_eq "$(readlink "$HARNESS_HOME/engine")" releases/v0.2.0 "the latest release is installed"
assert_ok "says which release it installed" grep -qF "installed Harness v0.2.0 at $HARNESS_HOME/releases/v0.2.0" <<<"$out"
assert_eq "$(cat "$HARNESS_HOME/releases/.installed")" v0.2.0 "the release is recorded for retention and --rollback"
assert_ok "the PATH link goes through the stable engine path" \
  test "$(readlink "$HARNESS_BIN_DIR/harness")" == "$HARNESS_HOME/engine/bin/harness"
assert_ok "harness --version prints it" \
  grep -q '^harness v0.2.0 ' <<<"$(env -u ENGINE_DIR -u STATE_DIR bash "$HARNESS_BIN_DIR/harness" --version)"
inst >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 "re-installing the same release exits 0"
assert_eq "$(readlink "$HARNESS_HOME/engine")" releases/v0.2.0 "and leaves engine on it"
assert_eq "$(ls -A "$HARNESS_HOME/releases" | sort | xargs)" ".installed v0.2.0" "and downloads nothing new"

fresh 2; HARNESS_REF=v0.1.0 inst >/dev/null 2>&1
assert_eq "$(readlink "$HARNESS_HOME/engine")" releases/v0.1.0 "HARNESS_REF installs that release even when a newer one is latest"
assert_eq "$(sed -n 1p "$HARNESS_HOME/engine/VERSION")" v0.1.0 "the pinned release's VERSION is live"

fresh 3; good="$(cat "$SRV/download/v0.2.0/SHA256SUMS")"
printf '%064d  harness-v0.2.0.tar.gz\n' 0 > "$SRV/download/v0.2.0/SHA256SUMS"
out="$(inst 2>&1)"; rc=$?
assert_no "a bad checksum fails" test "$rc" -eq 0
assert_ok "and names the mismatch" grep -qF 'checksum mismatch for harness-v0.2.0.tar.gz' <<<"$out"
assert_ok "in install's own words" grep -qF 'harness install: checksum mismatch' <<<"$out"
assert_no "no engine symlink is left" test -e "$HARNESS_HOME/engine"
assert_no "no partial release dir is left" test -e "$HARNESS_HOME/releases/v0.2.0"
assert_no "no staging dir is left" compgen -G "$HARNESS_HOME/releases/.staging-*"
printf '%s\n' "$good" > "$SRV/download/v0.2.0/SHA256SUMS"

fresh 4; out="$(HARNESS_REF=v9.9.9 inst 2>&1)"; rc=$?
assert_no "an unknown HARNESS_REF fails" test "$rc" -eq 0
assert_ok "and names the missing release" grep -qF 'no Harness release v9.9.9' <<<"$out"
assert_no "nothing is installed" test -e "$HARNESS_HOME/engine"
assert_no "no release dir is left" test -e "$HARNESS_HOME/releases/v9.9.9"

fresh 5; rel_latest "$SRV" ""; out="$(inst 2>&1)"; rc=$?
assert_no "with nothing published, install fails rather than cloning main" test "$rc" -eq 0
assert_ok "and says the endpoint named no release" grep -qF 'named no release' <<<"$out"
assert_no "and clones nothing" test -e "$HARNESS_HOME/engine"
assert_no "install.sh never clones the engine" grep -qE 'git clone.*HARNESS_REPO_URL' "$HERE/../install.sh"
rel_latest "$SRV" v0.2.0

# The real entrypoint: main runs the whole install (prereqs, place_engine, skills, rtdd, link) and
# its closing line names the release. Prereqs and the networked steps are stubbed on PATH.
fresh 6; STUB="$T/stub6"; mkdir -p "$STUB"
for t in tmux claude; do printf '#!/bin/sh\nexit 0\n' > "$STUB/$t"; chmod +x "$STUB/$t"; done
printf '#!/bin/sh\ncase "$1" in auth) exit 0;; esac\nexit 0\n' > "$STUB/gh"; chmod +x "$STUB/gh"
printf '#!/bin/sh\nexit 1\n' > "$STUB/git"; chmod +x "$STUB/git"   # skill clones fail: best-effort
nope=(); for c in AGY CODEX COPILOT HERMES OPENCLAW OPENCODE; do nope+=("HARNESS_${c}_BIN=$STUB/nope"); done
out="$(env PATH="$STUB:/usr/bin:/bin" HARNESS_SKIP_RTDD=1 HARNESS_CLAUDE_BIN="$STUB/claude" "${nope[@]}" \
  CLAUDE_CONFIG_DIR="$T/home6/.claude" HARNESS_USER_SKILLS="$T/home6/skills" bash "$HERE/../install.sh" 2>&1)"; rc=$?
assert_eq "$rc" 0 "install.sh's main exits 0 on a clean HOME"
assert_eq "$(readlink "$HARNESS_HOME/engine")" releases/v0.2.0 "main installs the latest release"
assert_ok "main's closing message names the release" grep -qF 'Done. Harness v0.2.0 is installed' <<<"$out"
assert_ok "the /harness skills come from the release" test -f "$T/home6/skills/harness/SKILL.md"
finish
