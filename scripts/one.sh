#!/usr/bin/env bash
# one.sh — `harness one`: the /harness-one budget gate (#365, PRD #362). One issue at a time, worked
# in the invoking session, while the fleet itself claims nothing.
#
#   harness one check
#       the precondition: the fleet is PAUSED (is_paused) or its claims are usage-HELD (usage_held,
#       #194). Anything else — a RUNNING, un-held fleet, or a stopped one a `harness start` would
#       bring back un-paused — is refused: its pool would race this session for the claim.
#   harness one gate <issue> [-R owner/repo] [--unit U] [--json]
#       the precondition, then the issue's forecast (forecast.py, #363/#364) against the freshest
#       usage reading of every window (cli_limit_usage), and the recommendation (one.py):
#       APPROVE iff now% + p80% + HARNESS_ONE_RESERVE_PCT <= HARNESS_ONE_STOP_PCT, else DENY.
#       It only recommends — the human decides (skill/harness-one), and nothing is claimed here.
#
# Exit status: check 0 pass / 1 refused; gate 0 APPROVE / 1 DENY / 2 bad args or no forecast / 3 refused.
# Sourced by test/test_one.sh; runs one_main only when executed directly.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# one_check — print why harness-one may run here (rc 0), or why not (stderr, rc 1).
one_check(){ local hf acct win pct reset
  if is_paused; then echo "harness one: the fleet is PAUSED — its pool claims nothing"; return 0; fi
  if usage_held; then
    for hf in "$(_usage_hold_dir)"/*.hold; do
      IFS=$'\t' read -r acct win pct reset < "$hf"
      echo "harness one: claims are usage-HELD (${acct:-?} ${win:-?} window at ${pct:-?}%) — the pool claims nothing until it resets"
      return 0
    done
  fi
  cat >&2 <<EOF
harness one: refused — the fleet is not PAUSED and no account is usage-HELD, so its pool would
  race this session for the claim. Pause it first: harness pause (drain) or harness pause --force.
EOF
  return 1; }

# _one_reading_age <account> <now> — seconds since <account>'s usage was last read, '' = unknown:
# its status-line drop (<usage-dir>/<account>.json, the claude adapter), else the newest usage
# cache another adapter writes (<usage-dir>/<cli>.tsv).
_one_reading_age(){ local f d newest=""
  d="$(_usage_dir)"; f="$d/$(_usage_key "$1").json"
  if [[ -f "$f" ]]; then newest="$(stat -c %Y "$f" 2>/dev/null)"
  else
    for f in "$d"/*.tsv; do
      [[ -f "$f" ]] || continue
      local m; m="$(stat -c %Y "$f" 2>/dev/null)" || continue
      (( m > ${newest:-0} )) && newest="$m"
    done
  fi
  [[ -n "$newest" ]] && echo $(( $2 - newest )) || echo ""; }

# one_readings — the usage readings TSV one.py reads: `<account>\t<window>\t<pct>\t<resets_at>\t<age>`.
# Prints nothing when usage is unavailable (the gate then DENIES: it cannot show the work fits).
one_readings(){ local out acct win pct reset now; now="$(date +%s)"
  out="$(cli_limit_usage 2>/dev/null)" || return 0
  while IFS=$'\t' read -r acct win pct reset; do
    [[ -n "$acct" && -n "$pct" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$acct" "$win" "$pct" "${reset:-0}" "$(_one_reading_age "$acct" "$now")"
  done <<< "$out"; }

# one_gate <issue> [forecast args…] [--json] — precondition, forecast, readings, recommendation.
one_gate(){ local issue="${1:-}" json="" a fc rd rc; shift || true
  [[ "$issue" =~ ^[0-9]+$ ]] || { echo "usage: harness one gate <issue> [-R owner/repo] [--unit U] [--json]" >&2; return 2; }
  local -a fargs=()
  for a in "$@"; do if [[ "$a" == --json ]]; then json=--json; else fargs+=("$a"); fi; done
  one_check >&2 || return 3
  fc="$(mktemp)"; rd="$(mktemp)"
  python3 "$ENGINE_DIR/scripts/forecast.py" "$issue" ${fargs[@]+"${fargs[@]}"} --json > "$fc"; rc=$?
  # rc 1 = no past lanes on the host: its JSON still prints, and the gate DENIES on it.
  if (( rc != 0 && rc != 1 )); then rm -f "$fc" "$rd"; return 2; fi
  one_readings > "$rd"
  python3 "$ENGINE_DIR/scripts/one.py" gate --forecast "$fc" --readings "$rd" \
    --stop "$HARNESS_ONE_STOP_PCT" --reserve "$HARNESS_ONE_RESERVE_PCT" \
    --stale-min "$HARNESS_ONE_STALE_MIN" --stale-pad "$HARNESS_ONE_STALE_PAD_PCT" $json; rc=$?
  rm -f "$fc" "$rd"; return $rc; }

one_main(){ local cmd="${1:-}"; shift || true
  case "$cmd" in
    check) one_check;;
    gate)  one_gate "$@";;
    *) echo "usage: harness one check | harness one gate <issue> [-R owner/repo] [--unit U] [--json]" >&2; return 2;;
  esac; }

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && one_main "$@"
