#!/usr/bin/env bash
# test_fleet_roll_env.sh — #649 (defect B): a fleet's configured CLI binary survives a cross-fleet start.
# Every CLI adapter sources `: "${HARNESS_CLAUDE_BIN:=claude}"; export …` (and the same for the other adapters' _BIN/_FLAGS/_TIMEOUT,
# HARNESS_CLI and HARNESS_SESSION_BACKEND). Config lines are `: "${VAR:=…}"`, so an INHERITED, exported value beats the file. A process that
# had sourced lib.sh (`harness update` -> fleet-migrate --all -> fleet_roll, or supervise) and then ran `harness start --state-dir <fleet B>`
# handed B's workers the engine default (`claude`) instead of B's configured wrapper (/home/claude/bin/claude-main): every priority/bug lane of
# the host launched bare `claude`, outside the host's bwrap lane sandbox.
#   1. the minimal repro: lib.sh sourced for fleet A, then lib.sh for fleet B -> claude_bin is A's/default (documented hazard)
#   2. fleet_roll for B, from a process that sourced lib.sh for A, starts B with B's own HARNESS_CLAUDE_BIN / _FLAGS
#   3. ...and every adapter's _BIN/_FLAGS/_TIMEOUT plus HARNESS_CLI / HARNESS_SESSION_BACKEND
#   4. a path seam (HARNESS_HOME) and an operator knob the roll passes (HARNESS_START_KEEP_PAUSE) still reach the start
# `harness start` is a stub that records the HARNESS_* it was given; the real fleet_roll (scripts/roll.sh) runs. No tmux, no claude, no gh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset ENGINE_DIR STATE_DIR
source "$HERE/helpers.sh"
unset_inherited_config
REAL="$(cd "$HERE/.." && pwd)"
ROOT="$(mktemp -d)"; tmp_track "$ROOT"
pin_host_home "$ROOT/host"
export HARNESS_GH_RATE_GUARD=0 HARNESS_EVENTS_FILE="$ROOT/events.jsonl"
mkdir -p "$HARNESS_FLEETS_DIR"

# fleet <name> <config body> — a fixture project with a dead worker pid file (so a roll starts it); prints its .harness dir
fleet(){ local d="$ROOT/$1/.harness"; mkdir -p "$d/run" "$d/checkouts" "$d/worktrees"
  printf '%s\n' "$2" > "$d/config"
  ( exit 0 ) & local dead=$!; wait "$dead" 2>/dev/null; echo "$dead" > "$d/run/worker-1.pid"
  echo "$d"; }
A="$(fleet a ': "${HARNESS_REPO:=acme/a}"
: "${HARNESS_SESS_PREFIX:=fa}"
: "${HARNESS_CLAUDE_BIN:=/opt/wrapper-a}"
: "${HARNESS_CLAUDE_FLAGS:=--flags-a}"')"
B="$(fleet b ': "${HARNESS_REPO:=acme/b}"
: "${HARNESS_SESS_PREFIX:=fb}"
: "${HARNESS_CLAUDE_BIN:=/opt/wrapper-b}"
: "${HARNESS_CLAUDE_FLAGS:=--flags-b}"
: "${HARNESS_AGY_BIN:=/opt/agy-b}"
: "${HARNESS_AGY_FLAGS:=--agy-b}"
: "${HARNESS_CODEX_BIN:=/opt/codex-b}"
: "${HARNESS_CODEX_FLAGS:=--codex-b}"
: "${HARNESS_COPILOT_BIN:=/opt/copilot-b}"
: "${HARNESS_COPILOT_FLAGS:=--copilot-b}"
: "${HARNESS_OPENCODE_BIN:=/opt/opencode-b}"
: "${HARNESS_OPENCODE_FLAGS:=--opencode-b}"
: "${HARNESS_OPENCLAW_BIN:=/opt/openclaw-b}"
: "${HARNESS_OPENCLAW_TIMEOUT:=77}"
: "${HARNESS_HERMES_BIN:=/opt/hermes-b}"
: "${HARNESS_CLI:=codex}"
: "${HARNESS_SESSION_BACKEND:=headless}"')"
C="$(fleet c ': "${HARNESS_REPO:=acme/c}"
: "${HARNESS_SESS_PREFIX:=fc}"')"   # a fleet that configures no binary at all: the engine default is right for it

# the stub `harness`: records the config vars `harness start` was handed
STUB="$ROOT/harness"; LOG="$ROOT/start.log"
cat > "$STUB" <<'S'
#!/usr/bin/env bash
{ echo "== $2 $3"; env | grep -E '^HARNESS_(CLAUDE|AGY|CODEX|COPILOT|OPENCODE|OPENCLAW|HERMES)_|^HARNESS_(CLI|SESSION_BACKEND|HOME|START_KEEP_PAUSE|REPO)=' | sort; } >> "$START_LOG"
exit 0
S
chmod +x "$STUB"; export START_LOG="$LOG"
got(){ awk -v want="== $1 start" '$0==want{f=1;next} /^== /{f=0} f' "$LOG" | grep "^$2=" | head -1 | cut -d= -f2-; }

echo "=== 1. the hazard: lib.sh for fleet A leaves exported adapter defaults that beat fleet B's config ==="
out="$( env -i PATH="$PATH" HOME="$HOME" bash -c "STATE_DIR='$A' source '$REAL/scripts/lib.sh' >/dev/null 2>&1
  env STATE_DIR='$B' ENGINE_DIR='$REAL' bash -c 'source \"$REAL/scripts/lib.sh\" >/dev/null 2>&1; claude_bin'" )"
assert_eq "$out" "/opt/wrapper-a" "a plain child of an A process resolves A's binary for fleet B (why a cross-fleet launcher must clean the env)"

echo "=== 2. fleet_roll for B from a process that sourced lib.sh for A ==="
: > "$LOG"
( unset_inherited_config; export HARNESS_HOME="$ROOT/host"
  export STATE_DIR="$A" ENGINE_DIR="$REAL"; source "$REAL/scripts/lib.sh" >/dev/null 2>&1   # this process is "in fleet A": A's config is exported
  source "$REAL/scripts/roll.sh"
  fleet_roll "$B" "$REAL" "$STUB" 0 ) >/dev/null 2>&1
assert_eq "$(got "$B" HARNESS_REPO)" "" "B's start is NOT handed A's repo either"
assert_eq "$(got "$B" HARNESS_CLAUDE_BIN)" "" "B's start is NOT handed A's binary through the environment (it loads B's config itself)"
# the stub does not source lib.sh, so a clean env is what B's own config can win in. Prove that with the real loader:
# loaded <fleet> <expr> — the env the stub received, then <fleet>'s lib.sh sourced the way `harness start` does; evaluates <expr>
loaded(){ ( while IFS= read -r l; do [[ $l == HARNESS_*=* ]] && export "${l%%=*}=${l#*=}"; done < <(awk -v want="== $1 start" '$0==want{f=1;next} /^== /{f=0} f' "$LOG")
  export STATE_DIR="$1" ENGINE_DIR="$REAL"; source "$REAL/scripts/lib.sh" >/dev/null 2>&1; eval "$2" ); }
assert_eq "$(loaded "$B" claude_bin)" "/opt/wrapper-b" "...so the lane launch line for B uses B's configured wrapper"
assert_eq "$(loaded "$B" 'echo $HARNESS_CLAUDE_FLAGS')" "--flags-b" "...and B's flags"

echo "=== 3. every adapter, HARNESS_CLI and the session backend ==="
for v in HARNESS_AGY_BIN HARNESS_AGY_FLAGS HARNESS_CODEX_BIN HARNESS_CODEX_FLAGS HARNESS_COPILOT_BIN HARNESS_COPILOT_FLAGS HARNESS_OPENCODE_BIN \
         HARNESS_OPENCODE_FLAGS HARNESS_OPENCLAW_BIN HARNESS_OPENCLAW_TIMEOUT HARNESS_HERMES_BIN HARNESS_CLI HARNESS_SESSION_BACKEND; do
  want="$(grep -o "${v}:=[^}]*" "$B/config" | cut -d= -f2-)"
  assert_eq "$(loaded "$B" "echo \${$v}")" "$want" "B's start loads $v from B's config"
done

echo "=== 4. fleet C (no binary configured), then the seams that must survive ==="
: > "$LOG"
( unset_inherited_config; export HARNESS_HOME="$ROOT/host" STATE_DIR="$A" ENGINE_DIR="$REAL"; source "$REAL/scripts/lib.sh" >/dev/null 2>&1
  source "$REAL/scripts/roll.sh"; fleet_roll "$C" "$REAL" "$STUB" 0 ) >/dev/null 2>&1
assert_eq "$(loaded "$C" claude_bin)" "claude" "fleet C gets the engine default, not A's wrapper"
assert_eq "$(got "$C" HARNESS_HOME)" "$ROOT/host" "HARNESS_HOME (a path seam) still reaches the start"
: > "$LOG"; touch "$C/run/PAUSED"
( unset_inherited_config; export HARNESS_HOME="$ROOT/host" STATE_DIR="$A" ENGINE_DIR="$REAL"; source "$REAL/scripts/lib.sh" >/dev/null 2>&1
  source "$REAL/scripts/roll.sh"; fleet_roll "$C" "$REAL" "$STUB" 0 ) >/dev/null 2>&1
assert_eq "$(got "$C" HARNESS_START_KEEP_PAUSE)" "1" "a paused fleet's roll still passes HARNESS_START_KEEP_PAUSE=1"

finish
