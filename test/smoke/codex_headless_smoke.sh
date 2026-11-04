#!/usr/bin/env bash
# codex_headless_smoke.sh — #481 / PRD #475: the REAL `codex` binary behind the headless lane runner
# (scripts/cli/codex_headless.py), no fleet, no GitHub. Not part of test/run.sh: it runs the host's codex.
#
#   bash test/smoke/codex_headless_smoke.sh            # log: $SMOKE_LOG, default test/smoke/logs/codex-headless-<utc stamp>.log
#
# A  the host's own codex account, one turn: the lane ends `idle` (a reply) or `limit` (the account's usage
#    limit, with the reset time parsed off codex's message) — never `transient`. A signed-out or broken codex
#    is `transient`, and fails the run.
# B  the same codex binary against a local stand-in Responses endpoint (test/fixtures/cli/codex/stream-json/
#    standin_server.py) and a throwaway CODEX_HOME, so it needs no quota: a first turn starts a thread, a
#    second `exec resume`s the same thread, the lane's state carries both replies and the usage, and the
#    rollout codex wrote carries the rate-limit windows `codex_limit_usage` reads.
# Nothing here writes outside a mktemp dir, except what the host codex itself does for part A (a rollout under
# its CODEX_HOME). Exit 0 = both parts held.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RUNNER="$ROOT/scripts/cli/codex_headless.py"
STANDIN="$ROOT/test/fixtures/cli/codex/stream-json/standin_server.py"
SMOKE_LOG="${SMOKE_LOG:-$HERE/logs/codex-headless-$(date -u +%Y%m%dT%H%M%SZ).log}"
mkdir -p "$(dirname "$SMOKE_LOG")"
T="$(mktemp -d)"; PIDS=()
cleanup(){ local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf -- "$T"; }
trap cleanup EXIT
log(){ printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$SMOKE_LOG"; }
fail=0; bad(){ log "FAIL: $*"; fail=1; }
field(){ python3 "$RUNNER" state --lane "$1" --field "$2" 2>/dev/null; }
# wait_turn <lane> <n> — until turn <n> has ended (not busy), at most 180s.
wait_turn(){ local i; for (( i = 0; i < 1800; i++ )); do
    [[ "$(field "$1" turn)" == "$2" && "$(field "$1" state)" != busy && -n "$(field "$1" state)" ]] && return 0; sleep 0.1; done; return 1; }
# start <lane> <wd> <runner args…> — a runner in the background, its pid kept for cleanup.
start(){ local lane="$1" wd="$2"; shift 2; python3 "$RUNNER" run --lane "$lane" --cwd "$wd" "$@" >"$lane.out" 2>&1 & PIDS+=("$!"); }

log "== codex headless smoke | $(codex --version 2>&1 | head -1) | $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "== host $(uname -s) $(uname -r) | bash ${BASH_VERSION%%(*} | $(python3 --version 2>&1)"

# --- A: the host's account ------------------------------------------------------------------------
log "== A: one turn on the host's own codex account"
mkdir -p "$T/wdA" && git -C "$T/wdA" init -q
start "$T/laneA" "$T/wdA" --message "Reply with exactly the word PONG and nothing else." \
  --flags="--dangerously-bypass-approvals-and-sandbox"
if wait_turn "$T/laneA" 1; then
  st="$(field "$T/laneA" state)"
  log "   turn 1 ended: state=$st exit=$(field "$T/laneA" exit) thread=$(field "$T/laneA" session_id)"
  case "$st" in
    idle)  log "   reply: $(field "$T/laneA" last_reply)" ;;
    limit) at="$(field "$T/laneA" limit_resets_at)"
           log "   the account's usage limit: $(field "$T/laneA" error | cut -c1-200)"
           log "   parsed reset: $at ($(date -u -d "@$at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null))"
           [[ "$at" =~ ^[0-9]+$ ]] || bad "a limit with no parsed reset time"
           log "   pane the watchdog reads: $(python3 "$RUNNER" pane --lane "$T/laneA" | head -1)" ;;
    *)     bad "turn 1 ended $st, not idle or limit: $(field "$T/laneA" error | cut -c1-200)" ;;
  esac
else bad "turn 1 never ended"; fi
python3 "$RUNNER" stop --lane "$T/laneA" >/dev/null 2>&1

# --- B: the same binary, a stand-in endpoint --------------------------------------------------------
log "== B: the codex binary on a local stand-in endpoint (no quota)"
port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 "$STANDIN" "$port" normal & PIDS+=("$!"); sleep 1
mkdir -p "$T/wdB" "$T/home" && git -C "$T/wdB" init -q
export STANDIN_KEY=x
flags="--dangerously-bypass-approvals-and-sandbox -m gpt-5.6-luna -c model_provider=standin -c 'model_providers.standin={name=\"standin\",base_url=\"http://127.0.0.1:$port/v1\",wire_api=\"responses\",env_key=\"STANDIN_KEY\"}'"
CODEX_HOME="$T/home" start "$T/laneB" "$T/wdB" --message "Reply with exactly the word PONG and nothing else." --flags="$flags"
if wait_turn "$T/laneB" 1; then
  thread="$(field "$T/laneB" session_id)"
  log "   turn 1: state=$(field "$T/laneB" state) reply=$(field "$T/laneB" last_reply) thread=$thread"
  [[ "$(field "$T/laneB" state)" == idle && "$(field "$T/laneB" last_reply)" == PONG && ${#thread} == 36 ]] || bad "turn 1 did not end idle with PONG on a thread"
  python3 "$RUNNER" send --lane "$T/laneB" "Now reply with exactly the word DONE and nothing else." >/dev/null
  if wait_turn "$T/laneB" 2; then
    log "   turn 2: state=$(field "$T/laneB" state) reply=$(field "$T/laneB" last_reply) thread=$(field "$T/laneB" session_id)"
    [[ "$(field "$T/laneB" last_reply)" == DONE && "$(field "$T/laneB" session_id)" == "$thread" ]] || bad "turn 2 did not carry on the thread"
    log "   usage in state.json: $(field "$T/laneB" rate_limit)"
    [[ "$(field "$T/laneB" rate_limit)" == *'"status": "allowed"'* && "$(field "$T/laneB" rate_limit)" == *output_tokens* ]] || bad "no usage in state.json"
  else bad "turn 2 never ended"; fi
else bad "turn 1 never ended"; fi
python3 "$RUNNER" stop --lane "$T/laneB" >/dev/null 2>&1
rollout="$(ls "$T"/home/sessions/*/*/*/rollout-*"${thread:-none}".jsonl 2>/dev/null | head -1)"
if [[ -n "$rollout" ]]; then
  log "   the exec turns wrote their rollout: ${rollout#"$T"/}"
  windows="$(CODEX_HOME="$T/home" bash -c "source '$ROOT/scripts/lib.sh' >/dev/null 2>&1; HARNESS_CLI=codex cli_limit_usage | cut -f1-3 | tr '\\t\\n' '  '" 2>/dev/null)"
  log "   codex_limit_usage reads from it: $windows"
else bad "no rollout for the thread"; fi
(( fail )) && { log "== FAILED"; exit 1; }
log "== ok"
