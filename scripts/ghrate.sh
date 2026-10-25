#!/usr/bin/env bash
# ghrate.sh — #183: a rate-limit-aware dispatcher. Sourced by lib.sh (after its config block);
# defines functions only.
#
# Every fleet on a host and every agent session in it spend ONE GitHub token's budget. So:
#   1. a rate-limited gh read (issuelib) records a per-token HOLD with the reset time it read from
#      `gh api rate_limit`; until then issuelib refuses every gh read, and gh_rate_wait sleeps the
#      dispatcher until the reset — one log line per hold, not one per poll;
#   2. below HARNESS_GH_BUDGET_PCT of either budget (core / graphql), gh_budget_low stops new claims
#      and the dispatcher polls at twice its interval until the reset, leaving what is left to the
#      live agents. In-flight sessions are never touched by either.
# The token, not the CLI, is what is limited, so this is the same for every HARNESS_CLI.

# gh_rate_held — print this token's hold reset epoch; true while a hold is open.
gh_rate_held(){ python3 "$ISSUELIB" rate-held 2>/dev/null; }

# gh_rate_wait [fn] — while a hold is open, sleep until its reset, running <fn> (gh-free work, e.g.
# watchdog_team) every POLL seconds meanwhile. Makes no gh call. Returns 0 either way.
gh_rate_wait(){ local fn="${1:-}" reset now left
  reset="$(gh_rate_held)" || return 0
  if [[ "${_GH_RATE_LOGGED:-}" != "$reset" ]]; then
    _GH_RATE_LOGGED="$reset"; now="$(date +%s)"
    log "github rate limit — no gh calls until $(date -d "@$reset" '+%H:%M:%S' 2>/dev/null || echo "$reset") ($(( reset - now ))s); live sessions keep running (#183)"
    harness_event hold reason=rate_limit cause=gh_rate_limit secs="$(( reset - now ))"
  fi
  while now="$(date +%s)"; (( reset > now )); do
    [[ -n "$fn" ]] && "$fn"
    left=$(( reset - now )); sleep "$(( left < POLL ? left : POLL ))"
  done
  return 0; }

# gh_budget_low — true when this token is under HARNESS_GH_BUDGET_PCT of a budget: claim nothing new.
# Logs once per low streak. HARNESS_GH_RATE_GUARD=0 turns it off.
gh_budget_low(){ local low res rem lim reset
  [[ "$HARNESS_GH_RATE_GUARD" == 1 ]] || return 1
  low="$(python3 "$ISSUELIB" rate-low "$HARNESS_GH_BUDGET_PCT" "$HARNESS_GH_RATE_TTL" 2>/dev/null)" \
    || { _GH_LOW_LOGGED=""; return 1; }
  IFS=$'\t' read -r res rem lim reset <<< "$low"
  if [[ "${_GH_LOW_LOGGED:-}" != "$res:$reset" ]]; then
    _GH_LOW_LOGGED="$res:$reset"
    log "github $res budget low ($rem/$lim < ${HARNESS_GH_BUDGET_PCT}%) — no new claims, polling every $(( POLL * 2 ))s until $(date -d "@$reset" '+%H:%M' 2>/dev/null || echo "$reset") (#183)"
  fi
  return 0; }

# gh_rate_report — every token's remaining budget, reset time and hold (harness status).
gh_rate_report(){ local line
  while IFS= read -r line; do [[ -n "$line" ]] && echo "  github: $line"; done \
    < <(python3 "$ISSUELIB" rate-report 2>/dev/null); }
