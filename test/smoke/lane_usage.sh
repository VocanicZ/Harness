#!/usr/bin/env bash
# lane_usage.sh <cli> <session prefix> <issue> — the token usage of a smoke run's headless lane (#1114, PRD #475), one line per
# model: `token usage: lane <name> <model>: in N out N cache_read N cache_write N`. fleet_smoke.sh logs it after the run.
#
# `harness stats` shows a session_end's usage only when the stats sweep found the CLI's transcript, and a headless opencode,
# agy or openclaw lane's sweep does not (its worktree or CLI session lookup is gone by then). The lane directory still holds
# state.json, whose session_id is the CLI's own id for the lane's last session, and the CLI's store still holds the session: so
# this asks the CLI's adapter (cli/<cli>.sh `<cli>_transcripts` + `<cli>_usage`) for it. openclaw keeps no transcript once its
# worktree is gone, but its lane events.jsonl holds every turn's envelope with its usage.
# Needs HARNESS_SESSION_BACKEND=headless and HARNESS_CLI=<cli> in the environment; a lane with no usage is logged as such.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="${1:?cli}"; PREFIX="${2:?prefix}"; ISSUE="${3:?issue}"
source "$HERE/../../scripts/cli/dispatch.sh" >/dev/null 2>&1
source "$HERE/../../scripts/cli/$CLI.sh" >/dev/null 2>&1
root="$(dirname "$(headless_lane_dir x)")"
n=0
for lane in "$root/$PREFIX"-*-i"$ISSUE"; do
  [[ -f "$lane/state.json" ]] || continue
  n=$((n+1))
  IFS=$'\t' read -r sid wd < <(python3 -c 'import json, sys
d = json.load(open(sys.argv[1])); print(d.get("session_id") or "", d.get("cwd") or "", sep="\t")' "$lane/state.json" 2>/dev/null)
  files=(); [[ -n "${sid:-}" ]] && mapfile -t files < <("${CLI}_transcripts" "${wd:-}" "$sid" 2>/dev/null)
  out=""; (( ${#files[@]} )) && [[ -n "${files[0]}" ]] && out="$("${CLI}_usage" "${files[@]}" 2>/dev/null)"
  [[ -z $out && $CLI == openclaw && -s "$lane/events.jsonl" ]] && out="$(openclaw_usage "$lane/events.jsonl" 2>/dev/null)"
  name="$(basename "$lane")"
  if [[ -n $out ]]; then
    while IFS=$'\t' read -r m i o cr cw; do
      echo "token usage: lane $name $m: in ${i:-0} out ${o:-0} cache_read ${cr:-0} cache_write ${cw:-0}"
    done <<<"$out"
  else
    echo "token usage: lane $name: none found for the CLI's session ${sid:-<none>}"
  fi
done
(( n )) || echo "token usage: no lane directory for issue #$ISSUE under $root"
exit 0
