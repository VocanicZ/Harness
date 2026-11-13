#!/usr/bin/env bash
# test_auto_release_reviewed.sh — #1148: a release for a PRD close hands release.sh the sha that PRD's review ran the full suite on
# (`<!-- harness-prd-suite sha=<40 hex> -->`, a comment the fleet's own login wrote), so release.sh reuses that result at the same sha
# and selects rtdd rounds from it otherwise. A bug-only release, a PRD with no record, a forged marker, or an unreadable GitHub hands
# it nothing: release.sh then gates with rtdd rounds from the last tag, never the whole suite.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; source "$HERE/helpers.sh"
make_env
export HARNESS_RELEASE_REPO=acme/harness HARNESS_AUTORELEASE_DIR="$RUN_DIR/autorelease"
mkdir -p "$HARNESS_AUTORELEASE_DIR"; : > "$HARNESS_AUTORELEASE_DIR/bootstrap"
gc(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# a checkout with a few commits, for the "newest reviewed sha wins" ancestry check
CHECKOUT="$RUN_DIR/co"; mkdir -p "$CHECKOUT"; gc "$CHECKOUT" init -q -b main
for i in 1 2 3; do echo "$i" >> "$CHECKOUT/f"; gc "$CHECKOUT" add -A; gc "$CHECKOUT" commit -qm "c$i"; done
S1="$(git -C "$CHECKOUT" rev-parse HEAD~2)"; S2="$(git -C "$CHECKOUT" rev-parse HEAD~1)"; S3="$(git -C "$CHECKOUT" rev-parse HEAD)"
SLUG=acme/harness

# gh stub: the fleet is fleet-bot; PRD comments come from $RUN_DIR/prd-<n>.json through the real jq filter the engine passes.
gh(){
  case "$1 $2" in
    "api user") echo "fleet-bot";;
    "issue view") local n="$3" q=""; while (($#)); do [[ "$1" == -q ]] && { q="$2"; break; }; shift; done
                  [[ -f "$RUN_DIR/prd-$n.json" && ! -e "$RUN_DIR/gh-down" ]] || return 1
                  jq -r "$q" "$RUN_DIR/prd-$n.json" | tr -d '\r';;
  esac; }
marker(){ printf '{"author":{"login":"%s"},"body":"<!-- harness-prd-suite sha=%s -->\\nFull suite green."}' "$1" "$2"; }
prd_comments(){ local n="$1"; shift; printf '{"comments":[%s]}\n' "$(IFS=,; echo "$*")" > "$RUN_DIR/prd-$n.json"; }

# the release command stub records every argument it was given
ARGS="$RUN_DIR/args"; printf '#!/usr/bin/env bash\necho "$*" >> %q\nexit 0\n' "$ARGS" > "$RUN_DIR/release"; chmod +x "$RUN_DIR/release"
export HARNESS_RELEASE_CMD="$RUN_DIR/release"
last_args(){ tail -n1 "$ARGS" 2>/dev/null; }
run_for(){ : > "$ARGS"; release_exec "$S3" "$1"; }

echo "-- a PRD close with a recorded review sha: release.sh is handed it"
prd_comments 5 "$(marker fleet-bot "$S1")"
run_for prd:5
assert_eq "$(last_args)" "--ref $S3 --reviewed-sha $S1 --reviewed-prd 5" "the reviewed sha and PRD follow --ref"

echo "-- the newest marker of a PRD wins"
prd_comments 5 "$(marker fleet-bot "$S1")" "$(marker fleet-bot "$S2")"
run_for prd:5
assert_eq "$(last_args)" "--ref $S3 --reviewed-sha $S2 --reviewed-prd 5" "the later review comment is the one used"

echo "-- a marker anyone else wrote is not a review (it would skip the gate)"
prd_comments 6 "$(marker mallory "$S3")"
run_for prd:6
assert_eq "$(last_args)" "--ref $S3" "a forged marker is ignored: no reviewed sha"

echo "-- no record (an old PRD), a bug-only release, the bootstrap: nothing is handed over"
prd_comments 7 '{"author":{"login":"fleet-bot"},"body":"Reviewed: all acceptance criteria met."}'
run_for prd:7;      assert_eq "$(last_args)" "--ref $S3" "a PRD whose review recorded no sha"
run_for bug:31,32;  assert_eq "$(last_args)" "--ref $S3" "a bug-only release"
run_for bootstrap;  assert_eq "$(last_args)" "--ref $S3" "the bootstrap release"
run_for prd:404;    assert_eq "$(last_args)" "--ref $S3" "a PRD whose comments cannot be read"

echo "-- several PRDs: the newest reviewed sha; one with no record means none"
prd_comments 8 "$(marker fleet-bot "$S1")"; prd_comments 9 "$(marker fleet-bot "$S2")"
run_for "prd:8 prd:9"
assert_eq "$(last_args)" "--ref $S3 --reviewed-sha $S2 --reviewed-prd 9" "of two reviewed PRDs the later sha is used"
run_for "prd:8 prd:7"
assert_eq "$(last_args)" "--ref $S3" "a PRD with no record in the batch leaves it uncovered: the last tag"
run_for "prd:8 bug:3"
assert_eq "$(last_args)" "--ref $S3 --reviewed-sha $S1 --reviewed-prd 8" "bug fixes alongside a reviewed PRD ride on its record"

echo "-- GitHub down: nothing is handed over, the release does not fail on it"
touch "$RUN_DIR/gh-down"; run_for prd:5
assert_eq "$(last_args)" "--ref $S3" "an unreadable PRD is no record"
rm -f "$RUN_DIR/gh-down"

echo "-- release_run passes it through (the whole path from a PRD close)"
: > "$ARGS"; echo "$S3" > "$RUN_DIR/head"; release_head(){ cat "$RUN_DIR/head"; }; harness_event(){ :; }
rm -f "$HARNESS_AUTORELEASE_DIR"/gate-* "$HARNESS_AUTORELEASE_DIR"/result-*
release_run prd:5 >/dev/null 2>&1
assert_eq "$(last_args)" "--ref $S3 --reviewed-sha $S2 --reviewed-prd 5" "release_run -> release_exec -> release.sh"

echo "-- the review prompt tells the reviewer to record the sha its green suite ran on (what the marker above is read from)"
RV="$HERE/../prompts/review.md"
assert_ok "review.md posts the harness-prd-suite marker as the comment's first line" grep -qF '<!-- harness-prd-suite sha=$(git rev-parse HEAD) -->' "$RV"
assert_ok "only for a green run" grep -qF 'Never post it for a red run' "$RV"
assert_ok "the release gate's use is named" grep -qF 'a release at that same sha reuses this result' "$RV"
finish
