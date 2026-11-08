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
export HARNESS_CLAUDE_CONFIG_DIRS="$RUN_DIR/no-config-dirs"   # #659: the gate counts transcript spend; the host's are not this test's
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
{"event": "session_end", "ts": "2026-10-01T01:00:00Z", "prefix": "hz", "repo": "acme/widget", "unit": "main", "kind": "impl", "issue": 1, "session": "s1", "usage": {"claude-opus-5-5": {"output": 500000}}}
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
# ── #659: the gate counts the account's spend since the reading, as `harness one phase` does ─────
# The incident: a stale 70% reading, $20 per 1%, $523 of the account's transcripts since — the gate
# printed APPROVE (70 + 3 pad + 1 + 2 = 76%) on data the phase re-check CHECKPOINTed on.
CFG="$RUN_DIR/cfg/main"; mkdir -p "$CFG/projects/p"
printf '{"type":"assistant","timestamp":"%s","message":{"id":"m1","model":"claude-opus-5-5","usage":{"output_tokens":26150000}}}\n' \
  "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" > "$CFG/projects/p/other-session.jsonl"
export HARNESS_ONE_USD_PER_PCT=20 HARNESS_ONE_STOP_PCT=98
EVP="$RUN_DIR/events.p.jsonl"   # no past lane's calibration: the fallback $ per 1% prices the window
cp "$EV" "$EVP"
gate_p(){ "${ONE[@]}" gate 7 -R acme/widget --events "$EVP" --bodies "$BODIES" "$@"; }
stale27(){ mkdir -p "$(_usage_dir)"; touch -d '-27 hours' "$(_usage_dir)/main.json"; }
stale27; stub_usage 70
HARNESS_CLAUDE_CONFIG_DIRS="$RUN_DIR/no-config-dirs" gate_p >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "spend that cannot be counted (no config dir): the stale pad alone, as before"
HARNESS_CLAUDE_CONFIG_DIRS="$CFG" gate_p > "$RUN_DIR/g.out" 2>&1; rc=$?
assert_eq "$rc" "1" "\$523 of spend since the 27h-old 70% reading: DENY (rc 1)"
assert_ok "the text shows the spend added to the reading" grep -q 'read 70% + 26.15% spent since: \$523 in transcripts' "$RUN_DIR/g.out"
assert_ok "the recommendation is DENY" grep -q '^RECOMMEND: DENY' "$RUN_DIR/g.out"
HARNESS_CLAUDE_CONFIG_DIRS="$CFG" gate_p --json > "$RUN_DIR/g.json" 2>/dev/null
assert_eq "$(python3 -c 'import json,sys; w=json.load(open(sys.argv[1]))["windows"][0]; print(w["read"], w["spent_pct"], w["now"])' "$RUN_DIR/g.json")" \
  "70.0 26.15 96.15" "--json carries the reading, the spend and their sum"
fresh; stub_usage 70
HARNESS_CLAUDE_CONFIG_DIRS="$CFG" gate_p >"$RUN_DIR/g2.out" 2>&1; rc=$?; (( rc == 0 )) || cat "$RUN_DIR/g2.out" >&2
assert_eq "$rc" "0" "a fresh reading is not charged for spend from before it was taken: APPROVE"

# one_readings reads the adapter's 5th column (the reading's time) without corrupting resets_at
unset HARNESS_USAGE_CMD; export HARNESS_CLI=claude
mkdir -p "$(_usage_dir)"
printf '{"account":"main","at":%s,"rate_limits":{"seven_day":{"used_percentage":55,"resets_at":%s}}}' \
  "$(( $(date +%s) - 5000 ))" "$future" > "$(_usage_dir)/main.json"
touch "$(_usage_dir)/main.json"   # the file is fresh; the reading's own time is not
got="$(source "$HERE/../scripts/one.sh"; one_readings)"
assert_eq "$(cut -f1-4 <<<"$got")" "$(printf 'main\tseven_day\t55\t%s' "$future")" "one_readings: resets_at is clean with the extra column"
assert_ok "…and the age comes from the reading's own time, not the drop file's" \
  bash -c "a=\$(cut -f5 <<<'$got'); (( a >= 4995 && a <= 5010 ))"

finish
