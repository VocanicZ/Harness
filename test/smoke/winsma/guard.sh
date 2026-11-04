#!/usr/bin/env bash
# guard.sh — the before/after guard (#479, PRD #475 "Before/after guard"). Sourced by winsma.sh; needs common.sh.
# `before` records the machine files' checksums, the Harness\* task list and ~/.claude.json's projects outside
# C:\hx-<issue>; `after` records them again and FAILS on any difference.
ws_guard(){ local issue="$1" when="$2"
  case "$when" in
    before) ws_call r_guard_snap "$issue" before && ws_log "guard: before recorded";;
    after)  ws_call r_guard_snap "$issue" after || return 1
            ws_call r_guard_check "$issue" | tee -a "${WS_LOG:-/dev/null}"; return "${PIPESTATUS[0]}";;
    *) ws_die "guard takes before or after";;
  esac; }
