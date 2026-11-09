#!/usr/bin/env bash
# test_tmux_one_server.sh — #670 (PRD #587): every call of the tmux backend targets ONE server.
# #596 dropped the caller's TMUX for the launch only; find / type / capture / kill still used it, so a worker with a
# live TMUX on server A while the TMUX_TMPDIR default is server B created the lane on B and looked for it on A.
#   1. live TMUX on server A (a private -S socket), default server B (private TMUX_TMPDIR): the lane is created on B,
#      found, typed into, captured, listed, its pane pid read and killed on B; A is never touched
#   2. a stale TMUX (socket directory gone) is ignored the same way
#   3. a start that leaves no session still fails loudly (rc 1, tmux's error visible) — launch_agent logs launch_failed
#      for that (test_launch_failed.sh)
# Real tmux, two private servers (private TMUX_TMPDIR + a short -S socket); each is killed by its own socket only.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"
command -v tmux >/dev/null || { echo "  skip: tmux not installed"; exit 0; }
T="$(mktemp -d /tmp/t670.XXXXXX)"        # short: a unix socket path is capped near 100 bytes
export TMUX_TMPDIR="$T/b"; mkdir -p "$TMUX_TMPDIR"; unset TMUX TMUX_PANE   # never the host's server
SA="$T/a.sock"
trap 'tmux -S "$SA" kill-server 2>/dev/null; tmux kill-server 2>/dev/null; rm -rf "$T"' EXIT
source "$ROOT/scripts/lib.sh" 2>/dev/null; source "$ROOT/scripts/session/tmux.sh"
on_a(){ tmux -S "$SA" "$@"; }                 # server A, addressed by its socket
on_b(){ env -u TMUX tmux "$@"; }              # server B: the default under TMUX_TMPDIR
not(){ ! "$@"; }
not_on_a(){ ! on_a has-session -t "$1" 2>/dev/null; }
not_on_b(){ ! on_b has-session -t "$1" 2>/dev/null; }
listed(){ tmux_sess_list | grep -qx "$1"; }
lists_a(){ tmux_sess_list | grep -qx keepalive-a; }
paths_has(){ tmux_sess_list_paths | grep -q "^$1"; }
panes_has(){ tmux_sess_panes | grep -q "^$1"; }
captured(){ tmux_sess_capture "$1" | grep -q "$2"; }

echo "== a live TMUX on server A, the default server is B =="
on_a new-session -d -s keepalive-a -c /tmp "sleep 600"
export TMUX="$SA,$(on_a display-message -p '#{pid}'),0"
assert_ok "the live TMUX names server A (its socket exists)" test -S "$SA"
tmux_sess_start lane670 /tmp -e HARNESS_SESSION=u670 "cat"
assert_eq "$?" "0" "tmux_sess_start succeeds"
assert_ok "the lane exists on server B" on_b has-session -t lane670
assert_ok "…and not on server A" not_on_a lane670
assert_ok "tmux_sess_live finds it (it asked B, not A)" tmux_sess_live lane670
assert_ok "tmux_sess_list lists it" listed lane670
assert_ok "…and does not list server A's session" not lists_a
tmux_sess_type lane670 "typed670"; tmux_sess_enter lane670
assert_eq "$?" "0" "tmux_sess_type / enter reach the pane"
for _ in $(seq 30); do captured lane670 typed670 && break; sleep 0.1; done
assert_ok "tmux_sess_capture shows what was typed" captured lane670 typed670
tmux_sess_send_line lane670 "line670"
assert_eq "$?" "0" "tmux_sess_send_line reaches the pane"
pid="$(tmux_sess_pane_pid lane670)"
assert_ok "tmux_sess_pane_pid returns the pane's pid" test -n "${pid//[!0-9]/}"
assert_ok "tmux_sess_list_paths sees it" paths_has lane670
assert_ok "tmux_sess_panes sees it" panes_has lane670
tmux_sess_kill lane670
assert_eq "$?" "0" "tmux_sess_kill kills it"
assert_ok "…on server B" not_on_b lane670
assert_ok "server A's own session survived all of it" on_a has-session -t keepalive-a

echo "== a stale TMUX (its socket directory is gone) =="
export TMUX="$T/gone-dir/default,4242,0"
tmux_sess_start lane670s /tmp "cat"
assert_eq "$?" "0" "the launch succeeds on the default server"
assert_ok "…and the lane is found there" tmux_sess_live lane670s
tmux_sess_kill lane670s

echo "== a start that leaves no session fails loudly =="
mkdir -p "$T/fakebin"
printf '#!/bin/sh\ncase "$1" in new-session) echo "error creating /nonexistent/default (No such file or directory)" >&2; exit 0;; has-session) exit 1;; esac\nexit 0\n' > "$T/fakebin/tmux"
chmod +x "$T/fakebin/tmux"
err="$( PATH="$T/fakebin:$PATH"; export TMUX="$SA,1,0"; tmux_sess_start lane670x /tmp 2>&1 )"; rc=$?
assert_eq "$rc" "1" "no session behind a successful new-session: tmux_sess_start returns 1"
assert_ok "…and tmux's error stays visible" grep -q "error creating" <<<"$err"

finish
