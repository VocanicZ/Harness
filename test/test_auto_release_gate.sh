#!/usr/bin/env bash
# test_auto_release_gate.sh — #325: an automatic release runs its gate (test/run.sh) with every
# release / auto-release variable unset. release_run hands release.sh HARNESS_AUTORELEASE_DIR,
# HARNESS_RELEASE_REASON and HARNESS_RELEASE_REPO; the gate used to inherit them, so test_release.sh
# wrote its red-gate fixture's log into the host's real autorelease dir and every automatic release
# failed its own gate. test_auto_release.sh stubs the release command, so it could not see this.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"
make_env
gc(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# ── test_release.sh itself, run with a live auto-release environment ──
SENT="$RUN_DIR/sentinel"; mkdir -p "$SENT"
out="$(HARNESS_AUTORELEASE_DIR="$SENT" HARNESS_RELEASE_REPO=x/y HARNESS_RELEASE_REASON=prd:1 \
  HARNESS_RELEASE_CMD=/bin/false bash "$HERE/test_release.sh" 2>&1)"; rc=$?
assert_eq "$rc" 0 "test_release.sh passes under an inherited HARNESS_AUTORELEASE_DIR"
[[ "$rc" == 0 ]] || tail -n 20 <<<"$out"
assert_eq "$(ls -A "$SENT")" "" "and leaves that dir untouched"

# ── release_run against the real release.sh: stub gh, green fixture gate ──
STUB="$RUN_DIR/bin"; mkdir -p "$STUB"; export GH_LOG="$RUN_DIR/gh.log" PATH="$STUB:$PATH"; : > "$GH_LOG"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "repo view")    echo main;;
  "release view") exit 1;;
esac
exit 0
EOF
chmod +x "$STUB/gh"; unset -f gh
# The fixture's gate is green only when it sees none of the variables release_run hands release.sh —
# exactly what the real test/run.sh needs to pass.
R="$RUN_DIR/harness"; mkdir -p "$R/test"; git init -q --bare -b main "$R.git"
cat > "$R/test/run.sh" <<'EOF'
#!/usr/bin/env bash
env | grep -E '^HARNESS_(AUTORELEASE_DIR|RELEASE_REASON|RELEASE_REPO|RELEASE_CMD)=' && exit 1
exit 0
EOF
gc "$R" init -q -b main; gc "$R" add -A; gc "$R" commit -qm "feat: init"
gc "$R" remote add origin "$R.git"; gc "$R" push -q -u origin main
EV="$RUN_DIR/events"; : > "$EV"; harness_event(){ echo "$*" >> "$EV"; }
export HARNESS_RELEASE_REPO=acme/harness HARNESS_AUTORELEASE_DIR="$RUN_DIR/autorelease"
export HARNESS_RELEASE_CMD="$HERE/../scripts/release.sh"
SLUG=acme/harness; CHECKOUT="$R"
release_run prd:325 > "$RUN_DIR/run.log" 2>&1; rc=$?
sha="$(git -C "$R" rev-parse HEAD)"
assert_eq "$rc" 0 "release_run with the real release.sh returns 0"
assert_ok "its gate passed and the release was published" grep -qE '^release create v0\.1\.0 ' "$GH_LOG"
assert_ok "the tag is pushed" git -C "$R.git" rev-parse -q --verify 'refs/tags/v0.1.0^{tag}'
assert_ok "the release is an event" grep -q "^release_published reason=prd:325 sha=$sha" "$EV"
assert_no "no red-gate marker" test -e "$HARNESS_AUTORELEASE_DIR/gate-failed-$sha"
assert_no "no bug filed" grep -q '^issue create' "$GH_LOG"
[[ -e "$HARNESS_AUTORELEASE_DIR/gate-failed-$sha" ]] && cat "$RUN_DIR/run.log"

finish
