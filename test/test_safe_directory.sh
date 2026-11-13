#!/usr/bin/env bash
# test_safe_directory.sh — #1115: ensure_safe never writes the user's git config (PRD #475: no --global/--system
# write, nothing for uninstall to remove). safe.directory reaches git through GIT_CONFIG_COUNT/KEY_n/VALUE_n
# (command-line scope), after any entries the user's own environment already carries; a lane launch leaves the global
# config (a temp GIT_CONFIG_GLOBAL) byte-identical and the lane's tmux env carries the checkout and worktree.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; unset_inherited_config
make_env
source "$ROOT/scripts/lib.sh" >/dev/null 2>&1
export GIT_CONFIG_GLOBAL="$RUN_DIR/gitconfig"; printf '[user]\n\tname = keep\n' > "$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_NOSYSTEM=1
BEFORE="$(cat "$GIT_CONFIG_GLOBAL")"
unset GIT_CONFIG_COUNT

echo "== ensure_safe: the global config is untouched, git still sees the entries =="
A="$RUN_DIR/a dir"; B="$RUN_DIR/b"; mkdir -p "$A" "$B"
ensure_safe "$A"; ensure_safe "$B"; ensure_safe "$A"
assert_eq "$(cat "$GIT_CONFIG_GLOBAL")" "$BEFORE" "GIT_CONFIG_GLOBAL unchanged"
assert_eq "$(git config --global --get-all safe.directory 2>/dev/null | wc -l | tr -d ' ')" "0" "no global safe.directory entry"
assert_eq "$(git config --get-all safe.directory | sort | tr '\n' '|')" "$(printf '%s\n' "$A" "$B" | sort | tr '\n' '|')" "git sees both dirs, once each"
assert_eq "$GIT_CONFIG_COUNT" "2" "two entries, the repeat added none"
assert_eq "$(git config --global user.name)" "keep" "the user's own global settings still apply"

echo "== a user's own GIT_CONFIG_* entries are kept =="
out="$( unset _SAFE_BASE; _SAFE_DIRS=(); export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.email GIT_CONFIG_VALUE_0=u@x
  ensure_safe "$A"; git config user.email; echo "$GIT_CONFIG_COUNT"; git config --get-all safe.directory )"
assert_eq "$out" "$(printf 'u@x\n2\n%s' "$A")" "user entry 0 kept, safe.directory appended at 1"

echo "== lane_safe_env: the lane gets the checkout and worktree by -e =="
CHECKOUT="$RUN_DIR/checkout"
out="$( unset _SAFE_BASE GIT_CONFIG_COUNT; _SAFE_DIRS=(); SESSION_ENV=(); LANE_ENV_NAMES=(); lane_safe_env "$RUN_DIR/wt"; printf '%s\n' "${SESSION_ENV[@]}"; echo "${LANE_ENV_NAMES[*]}" )"
assert_ok "COUNT is 2"            grep -qx 'GIT_CONFIG_COUNT=2' <<<"$out"
assert_ok "checkout is entry 0"   grep -qx "GIT_CONFIG_VALUE_0=$CHECKOUT" <<<"$out"
assert_ok "worktree is entry 1"   grep -qx "GIT_CONFIG_VALUE_1=$RUN_DIR/wt" <<<"$out"
assert_ok "hermes passthrough names them" grep -q 'GIT_CONFIG_COUNT' <<<"$(tail -1 <<<"$out")"

echo "== a lane launch leaves the global config unchanged =="
RUN_DIR_L="$RUN_DIR"
(
  HARNESS_SESSION_BACKEND=tmux; STATE_DIR="$RUN_DIR/state"; mkdir -p "$STATE_DIR"
  CHECKOUT="$RUN_DIR/checkout"; mkdir -p "$CHECKOUT" "$RUN_DIR/wt"
  session_live(){ return 1; }; sess_resume_id(){ :; }; write_state(){ :; }; wait_forget(){ :; }
  sess_start(){ printf '%s\n' "$@" > "$RUN_DIR_L/sess_start.args"; return 1; }   # stop after the env is built
  launch_fail(){ :; }; log(){ :; }
  launch_agent hz-main-i9 "$RUN_DIR/wt" >/dev/null 2>&1
)
assert_eq "$(cat "$GIT_CONFIG_GLOBAL")" "$BEFORE" "launch_agent: GIT_CONFIG_GLOBAL unchanged"
assert_ok "launch_agent passed the worktree safe.directory to the session" grep -qx "GIT_CONFIG_VALUE_1=$RUN_DIR/wt" "$RUN_DIR/sess_start.args"

echo "== the source never writes a global/system git config =="
assert_no "no 'git config --global --add' in scripts/" grep -rnE 'git config --(global|system) +--add|safe\.directory' "$ROOT/scripts" --include=*.sh --exclude=lib.sh
assert_no "ensure_safe has no --global" bash -c "sed -n '/^ensure_safe()/,/^  _SAFE_DIRS/p' \"$ROOT/scripts/lib.sh\" | grep -q -- '--global'"
finish
