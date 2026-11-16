#!/usr/bin/env bash
# test_headless_concurrent_send.sh — #1137 / PRD #475: several senders writing one headless lane at once
# (attach, the engine's cli_send, the supervisor's nudge, a type+Enter) each get every line delivered
# exactly once, never merged into another line and never lost. The lane's inbox is the one atomic path.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
source "$ROOT/scripts/lib.sh"
make_env
export RUN_DIR HARNESS_SESS_PREFIX=hcs HARNESS_SESSION_BACKEND=headless HARNESS_CLI=claude
HL="$ROOT/scripts/cli/claude_headless.py"
S=hcs-main-i1
LANE="$(headless_lane_dir "$S")"; mkdir -p "$LANE"
# A live lane needs only a runner pid and a non-ended state: a sleeper stands in (its pid is ours alone).
sleep 300 & SLP=$!
cleanup(){ [[ ${SLP:-} =~ ^[0-9]+$ ]] && (( SLP > 1 )) && kill "$SLP" 2>/dev/null; tmp_cleanup; }
trap cleanup EXIT
echo "$SLP" > "$LANE/pid"; _hl_ident "$SLP" > "$LANE/started"
printf '{"state": "idle", "turn": 0}\n' > "$LANE/state.json"
assert_ok "the stand-in lane is live" sess_live "$S"

N=${CS_N:-40}
inbox_texts(){ python3 -c '
import json, sys
for l in open(sys.argv[1], encoding="utf-8"):
    if l.strip(): print(json.loads(l)["text"])' "$LANE/inbox.jsonl" 2>/dev/null; }
check(){ local tag="$1" want="$2" got; got="$(inbox_texts | sort)"
  assert_eq "$(wc -l <<<"$got" | tr -d ' ')" "$want" "$tag: every line is one inbox message"
  assert_eq "$(sort -u <<<"$got" | wc -l | tr -d ' ')" "$want" "$tag: none twice"
  assert_eq "$(grep -cvE '^(a|b)-[0-9]+$' <<<"$got")" 0 "$tag: none merged into another or cut"; }

echo "== two cli_send senders at once =="
rm -f "$LANE/inbox.jsonl"
( for i in $(seq 1 $N); do cli_send "$S" "$RUN_DIR" "a-$i"; done ) & P1=$!
( for i in $(seq 1 $N); do cli_send "$S" "$RUN_DIR" "b-$i"; done ) & P2=$!
wait "$P1" "$P2"
check "cli_send x2" $((2 * N))

echo "== a type+Enter sender against a cli_send sender =="
rm -f "$LANE/inbox.jsonl" "$LANE/typed"
( for i in $(seq 1 $N); do sess_type "$S" "a-$i"; sess_enter "$S"; done ) & P1=$!
( for i in $(seq 1 $N); do cli_send "$S" "$RUN_DIR" "b-$i"; done ) & P2=$!
wait "$P1" "$P2"
got="$(inbox_texts | sort)"
assert_eq "$(grep -c '^b-' <<<"$got")" "$N" "the cli_send lines all arrive, whole"
assert_eq "$(grep -c '^b-' <<<"$got" | head -1)" "$(grep '^b-' <<<"$got" | sort -u | wc -l | tr -d ' ')" "…each once"
assert_eq "$(grep -cvE '^(a|b)-[0-9]+$' <<<"$got")" 0 "…and no line is merged into another"
assert_no "nothing is left typed or claimed" bash -c "ls '$LANE'/typed* >/dev/null 2>&1"

echo "== two type+Enter senders: Enter claims the buffer atomically =="
rm -f "$LANE/inbox.jsonl" "$LANE/typed"
( for i in $(seq 1 $N); do sess_type "$S" "a-$i"; sess_enter "$S"; done ) & P1=$!
( for i in $(seq 1 $N); do sess_type "$S" "b-$i"; sess_enter "$S"; done ) & P2=$!
wait "$P1" "$P2"
tot="$(inbox_texts | tr -d '\n' | grep -oE '[ab]-[0-9]+' | wc -l | tr -d ' ')"
assert_eq "$tot" $((2 * N)) "no typed text is lost to a cat-then-rm race"
assert_no "nothing is left typed or claimed" bash -c "ls '$LANE'/typed* >/dev/null 2>&1"
finish
