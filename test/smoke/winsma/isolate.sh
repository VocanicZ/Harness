#!/usr/bin/env bash
# isolate.sh — C:\hx-<issue>\ isolation (#479, PRD #475 "Isolation"). Sourced by winsma.sh; needs common.sh.
# Modes: base | install (+ CLAUDE_CONFIG_DIR) | suite (+ HOME and USERPROFILE under the folder). The venv keeps
# python packages out of the shared python.
ws_isolate(){ local issue="$1"; shift; ws_call r_iso_prepare "$issue" "$@"; }
ws_env(){ ws_call r_iso_env "$1" "${2:-base}"; }
ws_task_add(){ ws_call r_task_add "$@"; }
ws_pid_add(){ ws_call r_pid_add "$@"; }
# ws_exec <issue> <mode> <command string> — run one command on the host inside the isolation; GH_TOKEN (when there
# is one) goes in on stdin, git auth and identity come from the environment, and the command's stdin is empty.
ws_exec(){ local issue="$1" mode="$2" cmd="$3" tflag=""
  [[ -n "$(ws_token)" ]] && tflag=--token
  [[ "${WS_CAP_CHECK:-1}" == 0 ]] || ws_hold_gate "$issue" || return $?   # #1033: the hold cap stops a NEW command, never a running one
  { printf 'export HX_REAL_HOME="${HX_REAL_HOME:-$HOME}"\nr_iso_prepare %q || exit 1\neval "$(r_iso_env %q %q)" || exit 1\n' "$issue" "$issue" "$mode"
    [[ -n "$tflag" ]] && echo 'eval "$(r_cred_env)"'
    printf 'cd "$HX_DIR" || exit 1\nbash -c %q </dev/null\nexit $?\n' "$cmd"; } | ws_stream $tflag | _ws_ssh; }
