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
  "issue create") echo https://github.com/acme/harness/issues/90;;
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

# ── #1060: a gate red on a file that passes alone releases, and is a comment on ONE tracking issue — not a gate bug ──
# The gate selects its tests with rtdd (#1148) and runs them by name: a stub rtdd selects test_x.sh (and, with no rtdd.files, nothing);
# test_x.sh is red on the gate's run and green when re-run alone.
cat > "$STUB/rtdd" <<'EOF'
#!/usr/bin/env bash
if [[ -f rtdd.files ]]; then printf '{"rounds":[{"round":1,"files":["test/test_x.sh","test/test_y.sh"]},{"round":3,"full_suite":true}]}\n'
else printf '{"rounds":[{"round":1,"files":[]},{"round":2,"files":[]}]}\n'; fi
EOF
chmod +x "$STUB/rtdd"
FL="$RUN_DIR/flaky"; mkdir -p "$FL/test"; git init -q --bare -b main "$FL.git"
: > "$FL/rtdd.files"; : > "$FL/test/test_x.sh"; : > "$FL/test/test_y.sh"
cat > "$FL/test/run.sh" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == test_x.sh ]] && exit 0   # the re-run alone
echo "== test_x.sh =="; echo "FAIL: x lost the race"; echo "FAILED: test_x.sh"; exit 1
EOF
gc "$FL" init -q -b main; gc "$FL" add -A; gc "$FL" commit -qm "feat: init"
gc "$FL" remote add origin "$FL.git"; gc "$FL" push -q -u origin main
: > "$GH_LOG"; : > "$EV"; CHECKOUT="$FL"; rm -rf "$RUN_DIR/autorelease"
release_run prd:1060 > "$RUN_DIR/flaky.log" 2>&1; rc=$?; sha="$(git -C "$FL" rev-parse HEAD)"
assert_eq "$rc" 0 "release_run on a flaky gate returns 0"
assert_ok "the release was published" grep -qE '^release create v0\.1\.0 ' "$GH_LOG"
assert_no "no gate-failed marker" test -e "$HARNESS_AUTORELEASE_DIR/gate-failed-$sha"
assert_no "no gate bug filed" grep -qE '^issue create .*release gate failed' "$GH_LOG"
assert_ok "one tracking issue is created" grep -qE '^issue create .*--title release gate flakes' "$GH_LOG"
assert_ok "and the flake is a comment on it" grep -qE '^issue comment .*test_x\.sh' "$GH_LOG"
assert_no "the flake marker is consumed" test -e "$HARNESS_AUTORELEASE_DIR/gate-flake-$sha"
assert_ok "the release is an event" grep -q "^release_published reason=prd:1060 sha=$sha" "$EV"
# a later flake comments on the existing tracking issue instead of making another
: > "$GH_LOG"; printf 'test_y.sh\n' > "$HARNESS_AUTORELEASE_DIR/gate-flake-feedface"
gh(){ echo "$*" >> "$GH_LOG"; case "$1 $2" in "issue list") echo 55;; esac; return 0; }
release_gate_flake feedface prd:2 >/dev/null 2>&1
assert_no "an open tracking issue is reused" grep -q '^issue create' "$GH_LOG"
assert_ok "the second flake is a comment on #55" grep -qE '^issue comment 55 .*test_y\.sh' "$GH_LOG"
unset -f gh

# ── #333: the filed bug shows the FAILURES, not just the log's tail ──
# The f4756cc gate failed in suites that run early; its last 80 lines were all `ok:`, so the bug
# filed for it showed none of them. The body must carry every FAIL / not ok line under its suite
# header, and whatever run.sh itself printed before the first suite.
GL="$HARNESS_AUTORELEASE_DIR/gate-deadbeef.log"
{ echo "test/run.sh: line 16: test/helpers.sh: No such file or directory"
  echo "== test_alpha.sh =="; echo "  ok: a1"; echo "  FAIL: alpha broke — want [hz] got [hzhn]"; echo "── 1/2 passed"
  echo "== test_beta.sh =="; echo "  ok: b1 is not ok (FAIL) when stubbed"
  echo "== test_gamma.py =="; echo "not ok 3 - gamma broke"
  echo "FAILED: test_gamma.py"; echo "FAILED: test_alpha.sh"; echo "FAILED: test_gamma.py"
  for i in $(seq 1 200); do echo "  ok: filler $i"; done; } > "$GL"
gh(){ local a; echo "$*" >> "$GH_LOG"
  case "$1 $2" in
    "issue list") echo '[]';;
    "issue create") for a; do [[ $prev == --body-file ]] && cp "$a" "$RUN_DIR/bug-body"; prev=$a; done
                    echo "https://github.com/acme/harness/issues/77";;
  esac; return 0; }
prev=""; release_gate_bug deadbeef prd:333 >/dev/null 2>&1
B="$(cat "$RUN_DIR/bug-body" 2>/dev/null)"
assert_eq "$_GATE_BUG" 77 "the red gate's bug is filed"
assert_ok "the body carries the FAIL line" grep -qF 'FAIL: alpha broke — want [hz] got [hzhn]' <<<"$B"
assert_ok "...under its suite header" grep -qF '== test_alpha.sh ==' <<<"$B"
assert_ok "the body carries a not ok line" grep -qF 'not ok 3 - gamma broke' <<<"$B"
assert_ok "...under its suite header" grep -qF '== test_gamma.py ==' <<<"$B"
assert_no "a suite with no failure is not listed" grep -qF '== test_beta.sh ==' <<<"$B"
assert_ok "what run.sh printed before the first suite is shown" grep -qF 'helpers.sh: No such file or directory' <<<"$B"
# #1056: the failing files sorted and unique, in a block a later red gate compares against
assert_eq "$(grep -A5 'Failing test files:' <<<"$B" | grep -c '^FAILED: ')" 2 "the body lists each failing file once, for the next gate to compare"
assert_eq "$(grep '^FAILED: ' <<<"$B" | head -n2 | paste -sd' ' -)" "FAILED: test_alpha.sh FAILED: test_gamma.py" "in sorted order"
assert_ok "the tail is still there" grep -qF 'ok: filler 200' <<<"$B"
unset -f gh

finish
