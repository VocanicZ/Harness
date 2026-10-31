# headless.sh — the headless session backend (#346, PRD #344): lanes run as plain background
# processes with no terminal multiplexer, the groundwork native Windows needs. The key accepts it
# already; until the headless backend lands it runs no lane — sess_start refuses, and every query
# reads as "no session". The contract of each function is in scripts/session/dispatch.sh.
# Sourced by dispatch.sh; defines functions only.
headless_sess_bins(){ :; }
headless_sess_list(){ return 0; }
headless_sess_list_paths(){ return 0; }
headless_sess_panes(){ return 0; }
headless_sess_live(){ return 1; }
headless_sess_start(){ echo "session backend 'headless' cannot start a lane yet (session $1) — set $SESS_CONFIG_VAR=tmux" >&2; return 1; }
headless_sess_send_line(){ return 1; }
headless_sess_type(){ return 1; }
headless_sess_enter(){ return 1; }
headless_sess_clear_line(){ return 1; }
headless_sess_interrupt(){ return 1; }
headless_sess_capture(){ return 1; }
headless_sess_pane_pid(){ return 1; }
headless_sess_kill(){ return 1; }
headless_sess_attach(){ echo "session backend 'headless' has no session to attach to ($1)" >&2; return 1; }
headless_sess_attach_hint(){ echo "harness status"; }
