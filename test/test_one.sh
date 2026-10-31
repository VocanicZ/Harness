#!/usr/bin/env bash
# test_one.sh — #365: `harness one`, the /harness-one budget gate. The precondition refuses a
# RUNNING, un-held fleet and passes a PAUSED or usage-HELD one; `one gate` runs it, then the issue's
# forecast (a fixture event log, HARNESS_ONE_USD_PER_PCT) against a stubbed usage reading: APPROVE
# exactly at HARNESS_ONE_STOP_PCT, DENY just above, a stale reading padded. The threshold math
# itself is test_one.py's.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
export RUN_DIR HARNESS_STATE_DIR_OK=1
mkdir -p "$STATE_DIR"; : > "$STATE_DIR/config"
ONE=(bash "$HERE/../scripts/one.sh")
STUB="$RUN_DIR/usage.stub"; future=$(( $(date +%s) + 3600 ))
export HARNESS_USAGE_CMD="cat '$STUB'"
stub_usage(){ printf 'main\tseven_day\t%s\t%s\n' "$1" "$future" > "$STUB"; }
stub_usage 10

# ── precondition: running / paused / held ────────────────────────────────────
out="$("${ONE[@]}" check 2>&1)"; rc=$?
assert_eq "$rc" "1" "a RUNNING, un-held fleet is refused"
assert_ok "the refusal says the pool would race the claim" grep -q 'race this session for the claim' <<<"$out"
assert_ok "the refusal names harness pause" grep -q 'harness pause' <<<"$out"
"${ONE[@]}" gate 7 -R acme/widget >/dev/null 2>&1; rc=$?
assert_eq "$rc" "3" "gate refuses before forecasting on a running, un-held fleet"

touch "$RUN_DIR/PAUSED"
out="$("${ONE[@]}" check 2>&1)"; rc=$?
assert_eq "$rc" "0" "a PAUSED fleet passes"
assert_ok "and says so" grep -q 'PAUSED' <<<"$out"
rm -f "$RUN_DIR/PAUSED"

mkdir -p "$RUN_DIR/usage-holds"; printf 'main\tseven_day\t91\t%s\n' "$future" > "$RUN_DIR/usage-holds/main.hold"
out="$("${ONE[@]}" check 2>&1)"; rc=$?
assert_eq "$rc" "0" "a usage-HELD fleet passes"
assert_ok "and names the held window" grep -q 'usage-HELD (main seven_day window at 91%)' <<<"$out"

# The engine entry point runs it too.
"$HERE/../bin/harness" one check >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "harness one check is wired into bin/harness"

# ── gate: forecast vs live usage, still HELD ─────────────────────────────────
# One past lane on the host, no transcript: its session_end usage, 400k Opus output tokens = $10,
# and at HARNESS_ONE_USD_PER_PCT=5 its p80 is 2% of the window. The two bodies are the same length,
# so the size scale is 1.
EV="$RUN_DIR/events.jsonl"
cat > "$EV" <<'EOF'
{"event": "launch", "ts": "2026-10-01T00:00:00Z", "prefix": "hz", "repo": "acme/widget", "unit": "main", "kind": "impl", "issue": 1, "session": "s1"}
{"event": "session_end", "ts": "2026-10-01T01:00:00Z", "prefix": "hz", "repo": "acme/widget", "unit": "main", "kind": "impl", "issue": 1, "session": "s1", "usage": {"claude-opus-5-5": {"output": 400000}}}
EOF
BODIES="$RUN_DIR/bodies.json"
printf '[{"number": 1, "body": "%s"}, {"number": 7, "body": "%s"}]\n' "$(printf 'x%.0s' {1..80})" "$(printf 'y%.0s' {1..80})" > "$BODIES"
export HARNESS_ONE_USD_PER_PCT=5
gate(){ "${ONE[@]}" gate 7 -R acme/widget --events "$EV" --bodies "$BODIES" "$@"; }
fresh(){ mkdir -p "$(_usage_dir)"; touch "$(_usage_dir)/main.json"; }
stale(){ mkdir -p "$(_usage_dir)"; touch -d '-2 hours' "$(_usage_dir)/main.json"; }

fresh; stub_usage 94
out="$(gate 2>&1)"; rc=$?
assert_eq "$rc" "0" "94% now + 2% p80 + 2% reserve = 98% = the stop: APPROVE"
assert_ok "the arithmetic is printed" grep -q 'main seven_day: now 94% + p80 2% (fallback) + reserve 2% = 98% <= 98%' <<<"$out"
assert_ok "the forecast is shown first" grep -q '^forecast #7 acme/widget' <<<"$out"
assert_ok "the recommendation" grep -q '^RECOMMEND: APPROVE' <<<"$out"
assert_ok "the human decides" grep -q 'approve / pick another issue / stop' <<<"$out"

stub_usage 94.5
out="$(gate 2>&1)"; rc=$?
assert_eq "$rc" "1" "94.5% now: 98.5% > 98%: DENY"
assert_ok "the DENY names the window" grep -q 'RECOMMEND: DENY — main seven_day: 98.5% > 98%' <<<"$out"

HARNESS_ONE_STOP_PCT=99 gate >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "HARNESS_ONE_STOP_PCT=99 moves the boundary"
HARNESS_ONE_RESERVE_PCT=1 gate >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "HARNESS_ONE_RESERVE_PCT=1 too"
printf ': "${HARNESS_ONE_STOP_PCT:=99}"\n' > "$STATE_DIR/config"
gate >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "the stop % is read from the project config"
: > "$STATE_DIR/config"

stale; stub_usage 91
out="$(gate 2>&1)"; rc=$?
assert_eq "$rc" "0" "a 2-hour-old 91% reading + 3 pad + 2 + 2 = 98%: APPROVE"
assert_ok "the pad is shown" grep -q 'now 91% + 3 stale pad (120m old, > 30m)' <<<"$out"
stub_usage 92
gate >/dev/null 2>&1; rc=$?
assert_eq "$rc" "1" "a stale 92% reading pads past the stop: DENY"

gate --json > "$RUN_DIR/g.json" 2>/dev/null
assert_eq "$(python3 -c 'import json,sys; g=json.load(open(sys.argv[1])); print(g["verdict"], g["stop"], g["reserve"], g["windows"][0]["pad"])' "$RUN_DIR/g.json")" \
  "DENY 98.0 2.0 3.0" "--json carries the verdict and its inputs"

printf '' > "$STUB"
out="$(gate 2>&1)"; rc=$?
assert_eq "$rc" "1" "no usage reading at all: DENY"
assert_ok "and says why" grep -q 'no usage reading' <<<"$out"

"${ONE[@]}" gate nope >/dev/null 2>&1; rc=$?
assert_eq "$rc" "2" "a non-numeric issue is a usage error"
finish
