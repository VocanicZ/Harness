#!/usr/bin/env bash
# cleanup.sh — end of a winsma run (#479, PRD #475). Sourced by winsma.sh; needs common.sh.
# Kills the run's recorded pids (and any process whose command line is under C:\hx-<issue>\), deletes its recorded
# tasks and its ~/.claude.json project entries, deletes C:\hx-<issue>\, releases the lock, then checks winsma is
# clean. Names no folder but the numbered one, so C:\hx-smoke\ is out of reach.
ws_cleanup(){ local issue="$1" rc=0
  ws_call r_cleanup "$issue" || rc=1
  ws_call r_clean_check "$issue" | tee -a "${WS_LOG:-/dev/null}"; [[ "${PIPESTATUS[0]}" == 0 ]] || rc=1
  (( rc )) && ws_log "cleanup: winsma NOT clean" || ws_log "cleanup: winsma clean (no hx-$issue, lock released, no run task or process)"
  return $rc; }
