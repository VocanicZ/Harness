#!/usr/bin/env bash
# test_claude_trust_lock.sh — #1237: the workspace pre-accept must be written under the lock Claude Code itself takes while
# it saves its config (`<cfg>.lock`, a proper-lockfile directory made with mkdir). Harness's own flock excludes only other
# Harness writers: a Claude save that read the file before Harness's os.replace and wrote it after dropped the pre-accept
# (the lane then sat on the trust dialog), and Harness's own read-modify-write could drop a concurrent Claude save.
#   1. a fake Claude writer holds <cfg>.lock, reads, sleeps, writes back its stale copy; claude_trust runs meanwhile —
#      the pre-accept survives and so do the writer's own changes.
#   2. a stale lock (older than 10 s, no holder) is broken; a bounded wait never blocks launch forever.
#   3. <cfg>.lock never remains after claude_trust returns.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"; source "$HERE/helpers.sh"
make_env
export HARNESS_CLI=claude HARNESS_AUTONOMOUS=true
CFG="$RUN_DIR/cfg.json"; export HARNESS_CLAUDE_CONFIG="$CFG"
LOCK="$CFG.lock"

has_proj(){ python3 -c 'import json,sys
p = json.load(open(sys.argv[1])).get("projects", {}).get(sys.argv[2], {})
sys.exit(0 if p.get("hasTrustDialogAccepted") is True else 1)' "$CFG" "$1"; }
topkey(){ python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], "<absent>"))' "$CFG" "$1"; }

# fake_claude_save <hold seconds> — what Claude Code's saveConfigWithLock does, slowly: take <cfg>.lock (mkdir), read the file,
# hold, write the stale copy back with its own change, release. Prints "locked" once it holds the lock.
fake_claude_save(){ local hold="$1"
  CFG="$CFG" LOCK="$LOCK" HOLD="$hold" python3 - <<'PY'
import json, os, sys, time
cfg, lock, hold = os.environ["CFG"], os.environ["LOCK"], float(os.environ["HOLD"])
os.mkdir(lock)
print("locked", flush=True)
try:
    data = json.load(open(cfg))
    time.sleep(hold)
    data["claudeSaved"] = "yes"
    json.dump(data, open(cfg, "w"))
finally:
    os.rmdir(lock)
PY
}

echo "=== claude_trust waits for a Claude save in flight: neither side's write is lost ==="
rm -rf "$LOCK"; echo '{"userID":"keep","projects":{"/other":{"hasTrustDialogAccepted":true}}}' > "$CFG"
WD="$RUN_DIR/lane-race"; mkdir -p "$WD"
OUT="$RUN_DIR/writer.out"
fake_claude_save 1.5 > "$OUT" &
WPID=$!
for _ in $(seq 1 100); do [[ -s "$OUT" ]] && break; sleep 0.05; done
assert_eq "$(cat "$OUT")" "locked" "the fake Claude writer holds <cfg>.lock"
claude_trust "$WD"
wait "$WPID"
assert_ok "the pre-accept survived the Claude save (projects[<wd>])" has_proj "$WD"
assert_eq "$(topkey claudeSaved)" "yes" "the Claude save's own change survived too"
assert_eq "$(topkey userID)" "keep" "top-level keys survive"
assert_ok "an unrelated project survives" has_proj /other
assert_no "<cfg>.lock is gone after both" test -e "$LOCK"
assert_ok "claude_trusted holds" cli_trusted "$WD"

echo "=== a fresh lock makes claude_trust wait; it returns once the lock is released ==="
mkdir "$LOCK"
( sleep 1.2; rmdir "$LOCK" ) &
RP=$!
t0=$(date +%s%N)
WD2="$RUN_DIR/lane-wait"; mkdir -p "$WD2"
claude_trust "$WD2"
waited=$(( ($(date +%s%N) - t0) >= 1000000000 ? 1 : 0 ))
wait "$RP"
assert_eq "$waited" "1" "claude_trust waited for the held lock (>= 1 s)"
assert_ok "…then wrote the pre-accept" has_proj "$WD2"
assert_no "<cfg>.lock removed" test -e "$LOCK"

echo "=== a stale lock (mtime older than 10 s, no holder) does not block ==="
mkdir "$LOCK"; touch -d '2 minutes ago' "$LOCK"
WD3="$RUN_DIR/lane-stale"; mkdir -p "$WD3"
t0=$(date +%s)
HARNESS_CLAUDE_LOCK_WAIT_S=10 claude_trust "$WD3"
assert_ok "the pre-accept was written" has_proj "$WD3"
assert_eq "$(( $(date +%s) - t0 < 5 ? 1 : 0 ))" "1" "the stale lock was broken at once, not waited out"
assert_no "<cfg>.lock removed" test -e "$LOCK"

echo "=== a lock held past the bound: claude_trust logs it, writes anyway, and never blocks launch forever ==="
mkdir "$LOCK"   # fresh mtime, never released
WD4="$RUN_DIR/lane-held"; mkdir -p "$WD4"
t0=$(date +%s)
HARNESS_CLAUDE_LOCK_WAIT_S=2 claude_trust "$WD4" 2>"$RUN_DIR/held.err"
assert_ok "the pre-accept was still written" has_proj "$WD4"
assert_eq "$(( $(date +%s) - t0 < 8 ? 1 : 0 ))" "1" "returned within the bound"
assert_ok "the timeout was logged" grep -qi "lock" "$RUN_DIR/held.err"
rmdir "$LOCK" 2>/dev/null

echo "=== claude_trust leaves no lock behind on a plain run ==="
WD5="$RUN_DIR/lane-plain"; mkdir -p "$WD5"; claude_trust "$WD5"
assert_no "<cfg>.lock absent" test -e "$LOCK"
assert_ok "trusted" has_proj "$WD5"
finish
