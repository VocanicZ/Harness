#!/usr/bin/env bash
# credentials.sh — the credential rules (#479, PRD #475 "Credentials"). Sourced by winsma.sh; needs common.sh.
# GH_TOKEN travels on the ssh session's stdin (ws_exec / ws_call --token) and is never written. `scan before`
# lists the files that already hold it; `scan after` fails if the run added one (paths only, never the token).
ws_scan(){ local issue="$1" when="$2"
  case "$when" in
    before) ws_call --token r_cred_scan "$issue" before && ws_log "credentials: before scan recorded";;
    after)  ws_call --token r_cred_scan "$issue" after || return 1
            ws_call r_cred_check "$issue" | tee -a "${WS_LOG:-/dev/null}"; return "${PIPESTATUS[0]}";;
    *) ws_die "scan takes before or after";;
  esac; }
