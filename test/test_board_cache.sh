#!/usr/bin/env bash
# test_board_cache.sh — #182: the host poller refreshes INCREMENTALLY. Each pass hands the previous
# snapshot back to issuelib as the cache, and GitHub is asked only for what changed since it
# (`since` + If-None-Match). Proves, through the real `poller.sh --once` + gh-stub path:
#   - two consecutive polls on an UNCHANGED board make ZERO rate-limited calls (only 304s);
#   - a change on the board is picked up on the next poll, and the snapshot still serves dispatch;
#   - the host poller is ON by default (HARNESS_USE_POLLER empty / unset), and 0 opts out.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$(mktemp -d)"
export HARNESS_HOME="$WORK/host"
export HARNESS_POLLER_DIR="$WORK/host/poller"
export HARNESS_SNAPSHOTS_DIR="$WORK/host/snapshots"
export STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"

source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
POLLER="$HERE/../scripts/poller.sh"
PA="$WORK/projA/.harness"; mkdir -p "$PA"

# ── gh stub: a tiny GitHub. `issue list` (the full fetch) and `api -i` (the conditional REST reads)
# are both served from $BOARD, a REST-shaped issue list; every call is logged with its status so the
# test can count which ones the rate limit would have charged (everything but a 304).
FIX="$WORK/fix"; GHBIN="$WORK/ghbin"; mkdir -p "$FIX" "$GHBIN"
BOARD="$FIX/board.json"; CALLS="$WORK/calls"; : > "$CALLS"
cat > "$BOARD" <<'JSON'
[ {"number":8,"title":"free","state":"open","body":"","labels":[{"name":"ready-for-agent"}],
   "user":{"login":"me","type":"User"},"updated_at":"2026-10-01T00:00:08Z"},
  {"number":3,"title":"done","state":"closed","body":"","labels":[{"name":"ready-for-agent"}],
   "user":{"login":"me","type":"User"},"updated_at":"2026-10-01T00:00:03Z"},
  {"number":5,"title":"a PR","state":"open","body":"","labels":[],"pull_request":{"url":"x"},
   "user":{"login":"me","type":"User"},"updated_at":"2026-10-01T00:00:05Z"} ]
JSON
cat > "$GHBIN/gh" <<'STUB'
#!/usr/bin/env bash
# Every call logs `<status> <args>`; a 304 is the only status GitHub does not charge for.
python3 - "$BOARD" "$@" <<'PY'
import json, sys, hashlib, os
from urllib.parse import urlsplit, parse_qs
board = json.load(open(sys.argv[1])); a = sys.argv[2:]
def out(status, text, rc=0, err=""):
    sys.stdout.write(text); sys.stderr.write(err)
    open(os.environ["GH_CALLS"], "a").write("%s %s\n" % (status, " ".join(a)))
    sys.exit(rc)
if a[:2] == ["issue", "list"]:
    out(200, json.dumps([{"number": i["number"], "title": i["title"], "state": i["state"].upper(),
        "labels": i["labels"], "body": i["body"], "author": {"login": i["user"]["login"]},
        "updatedAt": i["updated_at"]} for i in board if "pull_request" not in i]))
if a[:2] == ["api", "user"]:
    out(200, "me")
if a[:2] == ["api", "-i"]:
    path = a[2]; sent = a[a.index("-H") + 1].split(": ", 1)[1] if "-H" in a else None
    if path.endswith("/contents/"):
        body = json.dumps([{"name": "README.md", "sha": "r1"}])
    else:
        since = parse_qs(urlsplit(path).query).get("since", [""])[0]
        body = json.dumps([i for i in board if i["updated_at"] >= since])
    etag = '"%s"' % hashlib.sha1(body.encode()).hexdigest()
    if sent == etag:
        out(304, "HTTP/2.0 304 Not Modified\nEtag: %s\n\n" % etag, 1, "gh: HTTP 304")
    out(200, "HTTP/2.0 200 OK\nEtag: %s\n\n%s" % (etag, body))
out(404, "", 1, "gh: Not Found (HTTP 404)")
PY
STUB
chmod +x "$GHBIN/gh"

poll(){ PATH="$GHBIN:$PATH" GH_CALLS="$CALLS" BOARD="$BOARD" HARNESS_OWNER=acme bash "$POLLER" --once; }
charged_since(){ tail -n +"$(( $1 + 1 ))" "$CALLS" | grep -vc '^304 '; }
SNAP="$HARNESS_SNAPSHOTS_DIR/acme__widget.json"

poller_register acme/widget 60 hz "$PA"

# ── 1) steady state on an unchanged board: zero charged calls ─────────────────
poll                                                  # first pass: full fetch (no cache yet)
assert_ok "first pass wrote a snapshot" test -f "$SNAP"
assert_ok "first pass was a full fetch" grep -q '^200 issue list' "$CALLS"
poll                                                  # second pass: incremental, primes the ETags
assert_no "second pass did NOT re-download the board" bash -c "[[ \$(grep -c '^200 issue list' '$CALLS') -gt 1 ]]"
mark="$(wc -l < "$CALLS")"
poll; poll                                            # two consecutive polls, nothing changed
assert_eq "$(charged_since "$mark")" "0" "two polls on an unchanged board: 0 rate-limited calls"
assert_eq "$(tail -n +"$(( mark + 1 ))" "$CALLS" | grep -c '^304 ')" "4" "…each answered by 304s (issues + root, twice)"

served(){ HARNESS_SNAPSHOT_FILE="$SNAP" HARNESS_SNAPSHOT_DIR="$HARNESS_SNAPSHOTS_DIR" HARNESS_MODE=issue-only \
          HARNESS_OWNER=acme HARNESS_AUTONOMOUS=true HARNESS_AUTHOR_ALLOWLIST= PATH="$GHBIN:$PATH" GH_CALLS="$CALLS" \
          python3 "$HERE/../scripts/issuelib.py" dispatch acme/widget 3; }
assert_eq "$(served)" "$(printf 'IMPL\t8\tISSUE 8 DONE')" "cached snapshot serves dispatch (PR filtered out)"

# ── 2) a change is picked up on the next poll ─────────────────────────────────
python3 - "$BOARD" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
b.insert(0, {"number": 9, "title": "new", "state": "open", "body": "", "labels": [{"name": "ready-for-agent"}],
             "user": {"login": "me", "type": "User"}, "updated_at": "2026-10-02T00:00:00Z"})
json.dump(b, open(sys.argv[1], "w"))
PY
mark="$(wc -l < "$CALLS")"
poll
assert_eq "$(tail -n +"$(( mark + 1 ))" "$CALLS" | grep -c '^200 api -i repos/acme/widget/issues')" "1" "a changed board costs the delta call alone"
assert_eq "$(served)" "$(printf 'IMPL\t9\tISSUE 9 DONE\nIMPL\t8\tISSUE 8 DONE')" "new issue #9 is served from the merged cache"

# ── 3) on by default; 0 opts out ──────────────────────────────────────────────
assert_ok "HARNESS_USE_POLLER unset -> poller on"  bash -c "unset HARNESS_USE_POLLER; source '$HERE/../scripts/lib.sh'; poller_enabled"
assert_ok "HARNESS_USE_POLLER empty (pre-#182 config) -> poller on" bash -c "HARNESS_USE_POLLER= ; source '$HERE/../scripts/lib.sh'; poller_enabled"
assert_no "HARNESS_USE_POLLER=0 -> poller off"     bash -c "HARNESS_USE_POLLER=0 ; source '$HERE/../scripts/lib.sh'; poller_enabled"

rm -rf "$WORK"
finish
