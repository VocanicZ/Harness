#!/usr/bin/env bash
# test_auto_release_bootstrap.sh — #331: while the Harness repo has no vX.Y.Z tag at all, the fleet's
# release_tick queues ONE `bootstrap` release (once per host, no throttle) through the same pending →
# release_kick → release_run → harness release path a PRD close takes. PRD #274 closed under an engine
# that predated the auto-release hooks, so no edge-triggered event would ever cut the first release.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"
make_env
export HARNESS_RELEASE_REPO=acme/harness
RLOG="$RUN_DIR/release.log"; REFS="$RUN_DIR/refs"; GH_LOG="$RUN_DIR/gh.log"; GITLOG="$RUN_DIR/git.log"
: > "$RLOG"; : > "$REFS"; : > "$GH_LOG"; : > "$GITLOG"
# Stub release command: logs the reason it was run for (and the --ref to $REFS), exits $STUB_RC.
printf '#!/usr/bin/env bash\necho "$HARNESS_RELEASE_REASON" >> %q\necho "$2" >> %q\nexit "${STUB_RC:-0}"\n' "$RLOG" "$REFS" > "$RUN_DIR/release"
chmod +x "$RUN_DIR/release"; export HARNESS_RELEASE_CMD="$RUN_DIR/release"
gh(){ echo "$*" >> "$GH_LOG"
  case "$1 $2" in
    "issue list")   echo '[]';;
    "issue create") echo "https://github.com/acme/harness/issues/99";;
  esac; return 0; }
harness_event(){ :; }
release_kick(){ release_run "$@"; }               # a background job in production; synchronous here
default_branch(){ echo main; }
git(){ echo "$*" >> "$GITLOG"; command git "$@"; }  # counts every git call release_tick makes
gc(){ command git -C "$1" -c user.name=t -c user.email=t@t "${@:2}"; }

# repo <name> [tag] — a bare origin with one commit on main (tagged <tag> there, if given) and a
# fresh clone of it as $CHECKOUT that has NOT fetched that tag yet; a fresh autorelease dir.
repo(){ local o="$RUN_DIR/$1.git" w="$RUN_DIR/$1-work"
  command git init -q --bare -b main "$o"; command git clone -q "$o" "$w" 2>/dev/null
  gc "$w" commit -q --allow-empty -m 'feat: init'; command git -C "$w" push -q origin main 2>/dev/null
  CHECKOUT="$RUN_DIR/$1-checkout"; command git clone -q --no-tags "$o" "$CHECKOUT" 2>/dev/null
  if [[ -n "${2:-}" ]]; then gc "$w" tag -a "$2" -m "$2"; command git -C "$w" push -q origin "refs/tags/$2" 2>/dev/null; fi
  export HARNESS_AUTORELEASE_DIR="$RUN_DIR/ar-$1"; : > "$RLOG"; : > "$REFS"; : > "$GITLOG"; }

# ── no vX.Y.Z tag in the Harness repo: exactly one bootstrap release ──
SLUG=acme/harness; repo none
HEAD_SHA="$(command git -C "$RUN_DIR/none-work" rev-parse HEAD)"
release_tick >/dev/null 2>&1
assert_eq "$(grep -c . "$RLOG")" 1 "a Harness repo with no release tag gets one release from release_tick"
assert_ok "its reason names the bootstrap" grep -q 'bootstrap' "$RLOG"
assert_eq "$(cat "$REFS")" "$HEAD_SHA" "at the default branch's head"
assert_ok "the once-per-host marker is written" test -e "$HARNESS_AUTORELEASE_DIR/bootstrap"
assert_eq "$(grep -c . "$HARNESS_AUTORELEASE_DIR/pending")" 0 "and the released bootstrap leaves the queue"
: > "$GITLOG"
release_tick >/dev/null 2>&1; release_tick >/dev/null 2>&1
assert_eq "$(grep -c . "$RLOG")" 1 "a later tick cuts no second bootstrap release"
assert_eq "$(grep -c . "$GITLOG")" 0 "and, with the marker there, makes no git call for the check"

# ── a vX.Y.Z tag already on origin: nothing queued ──
SLUG=acme/harness; repo tagged v0.1.0
release_tick >/dev/null 2>&1; release_tick >/dev/null 2>&1
assert_eq "$(grep -c . "$RLOG")" 0 "a repo that already has a release tag queues no bootstrap release"
assert_no "...nor anything in pending" grep -qs bootstrap "$HARNESS_AUTORELEASE_DIR/pending"
assert_eq "$(grep -c '^-C .* fetch' "$GITLOG")" 1 "the tag is looked up once, not every poll"
# A tag outside vX.Y.Z (a hand-made marker, a dev tag) is no release.
repo devtag nightly
release_tick >/dev/null 2>&1
assert_ok "a non-vX.Y.Z tag does not count as a release" grep -q 'bootstrap' "$RLOG"

# ── another target repo: nothing queued, nothing fetched ──
SLUG=acme/widget; repo widget
release_tick >/dev/null 2>&1
assert_eq "$(grep -c . "$RLOG")" 0 "another repo with no tag gets no bootstrap release"
assert_eq "$(grep -c . "$GITLOG")" 0 "and no git call is made for it"
assert_no "...nor a marker" test -e "$HARNESS_AUTORELEASE_DIR/bootstrap"

# ── a failed tag lookup (fetch failed) queues nothing and asks again next tick ──
SLUG=acme/harness; repo offline
command git -C "$CHECKOUT" remote set-url origin "$RUN_DIR/unreachable.git"
release_tick >/dev/null 2>&1
assert_eq "$(grep -c . "$RLOG")" 0 "an unreachable origin queues no bootstrap release"
assert_no "and writes no marker, so a later tick looks again" test -e "$HARNESS_AUTORELEASE_DIR/bootstrap"
command git -C "$CHECKOUT" remote set-url origin "$RUN_DIR/offline.git"
release_tick >/dev/null 2>&1
assert_ok "once origin answers, the bootstrap release is cut" grep -q 'bootstrap' "$RLOG"

# ── an errored release (rc 3) keeps the bootstrap queued until retry-after, then releases it ──
SLUG=acme/harness; repo errored; t0=1800000000
HARNESS_NOW=$t0 STUB_RC=3 release_tick >/dev/null 2>&1
assert_eq "$(grep -c . "$RLOG")" 1 "the bootstrap release ran once and errored"
assert_ok "it stays queued" grep -qP '\tbootstrap$' "$HARNESS_AUTORELEASE_DIR/pending"
HARNESS_NOW=$((t0+600)) release_tick >/dev/null 2>&1
assert_eq "$(grep -c . "$RLOG")" 1 "it is not retried before retry-after"
HARNESS_NOW=$((t0+3600)) release_tick >/dev/null 2>&1
assert_eq "$(grep -c . "$RLOG")" 2 "it is released on the tick after retry-after"
assert_ok "still as the bootstrap" grep -qx 'bootstrap' <(tail -1 "$RLOG")
assert_eq "$(grep -c . "$HARNESS_AUTORELEASE_DIR/pending")" 0 "and then leaves the queue"
HARNESS_NOW=$((t0+7200)) release_tick >/dev/null 2>&1
assert_eq "$(grep -c . "$RLOG")" 2 "and is never released again"

# ── a release job already running: the bootstrap stays queued and is released after it ──
SLUG=acme/harness; repo busy
source "$HERE/../scripts/autorelease.sh"           # the real release_kick (the top stubbed it)
default_branch(){ echo main; }
sleep 300 & HOLD=$!; mkdir -p "$HARNESS_AUTORELEASE_DIR"; echo "$HOLD" > "$HARNESS_AUTORELEASE_DIR/release.pid"
release_tick >/dev/null 2>&1
assert_eq "$(grep -c . "$RLOG")" 0 "a tick while a release job is live starts no bootstrap job"
assert_ok "the bootstrap is queued, not dropped" grep -qP '\tbootstrap$' "$HARNESS_AUTORELEASE_DIR/pending"
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
release_tick >/dev/null 2>&1; wait "$(cat "$HARNESS_AUTORELEASE_DIR/release.pid")" 2>/dev/null
assert_ok "the next tick releases it" grep -qx 'bootstrap' "$RLOG"
release_kick(){ release_run "$@"; }

# ── a red gate (rc 4) on the bootstrap release files the gate bug ──
SLUG=acme/harness; repo red; : > "$GH_LOG"
STUB_RC=4 release_tick >/dev/null 2>&1
assert_eq "$(grep -c '^issue create' "$GH_LOG")" 1 "a red bootstrap gate files one bug issue"
assert_ok "through release_gate_bug's marker" test -s "$HARNESS_AUTORELEASE_DIR/gate-failed-$(command git -C "$RUN_DIR/red-work" rev-parse HEAD)"

# ── a bootstrap queued alongside fixes: one release covers both, without the throttle ──
SLUG=acme/harness; repo mixed
HARNESS_NOW=$t0 release_on_bug_merge 40
HARNESS_NOW=$t0 release_tick >/dev/null 2>&1
assert_eq "$(cat "$RLOG")" "bootstrap bug:40" "one release covers the bootstrap and the queued fix"
assert_eq "$(grep -c . "$HARNESS_AUTORELEASE_DIR/pending")" 0 "and both leave the queue"
finish
