#!/usr/bin/env bash
# usage.sh — #194: watch plan usage and checkpoint every live session to GitHub BEFORE the limit
# hits. Sourced by lib.sh (after its config block); defines functions only.
#
# #120 already parks and nudges a session the limit has frozen, but a session cut off mid-task
# holds work that exists only in its worktree. So:
#   1. read each account's usage windows through the CLI seam (cli_limit_usage);
#   2. at HARNESS_USAGE_CHECKPOINT_PCT of any window, send every live impl/lane session on that
#      account the same HARNESS CHECKPOINT as `pause --force`, and HOLD new claims (usage_held)
#      until the window resets — then release the hold so the normal resume path re-dispatches the
#      agent-paused issues;
#   3. a session ALREADY frozen at the limit cannot run its handoff skill, so it gets a mechanical
#      checkpoint instead (commit + push its worktree, post a handoff comment with the last screen)
#      and is left alive for #120's nudge. watchdog_session also calls this on the limit message
#      itself, so checkpoints still happen for a CLI that cannot report usage.
#
# Usage lines, from every source: `<account>\t<window>\t<pct>\t<resets_at epoch>`.
# Both dirs resolve per call, off RUN_DIR, like every other run-state path a test re-pins.
_usage_dir(){ echo "${HARNESS_USAGE_DIR:-$RUN_DIR/usage}"; }   # statusline drops (claude adapter)
_usage_hold_dir(){ echo "$RUN_DIR/usage-holds"; }              # one <account>.hold per held account

_usage_key(){ printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# The usage windows themselves are read per CLI by the adapter (cli_limit_usage, scripts/cli/).

# ensure_usage_statusline <dir> — wire a worktree so its sessions report their usage windows, the
# CLI adapter's way (cli_usage_setup). Only Harness-owned trees
# (never PROJECT_ROOT, where the owner works interactively). HARNESS_USAGE_STATUSLINE=0 turns it off.
ensure_usage_statusline(){ local dir="$1"
  [[ "${HARNESS_USAGE_STATUSLINE:-1}" == 1 ]] || return 0
  [[ "$dir" != "$PROJECT_ROOT" ]] || return 0
  cli_usage_setup "$dir"; }

# harness_event <event> [key=value ...] — the host event log writer is lib.sh's (#185, stats.py).

# checkpoint_sessions — every live impl + priority-lane session of this fleet: the sessions
# `pause --force` and the usage checkpoint reach (orch sessions push no branch and own no issue).
checkpoint_sessions(){ tmux ls -F '#S' 2>/dev/null \
  | grep -E "^$HARNESS_SESS_PREFIX-(.*-i[0-9]+|bug-.+-(triage|fix))$" || true; }

# session_account <sess> — the account a session runs on, from the cwd map usage-statusline.sh
# keeps; empty when unknown (no statusline drop yet, or a CLI with no adapter).
session_account(){ local wd; wd="$(cat "$RUN_DIR/$1.wd" 2>/dev/null)" || return 0
  cat "$(_usage_dir)/cwd/$(_usage_key "$wd")" 2>/dev/null || true; }

# mechanical_checkpoint <sess> <pane> — checkpoint a session that cannot run /handoff itself (it is
# frozen at a limit): commit + push its worktree, post a `harness-handoff` comment carrying the
# last screen. The host prototype's checkpoint_and_kill, minus the kill — the session stays alive
# for #120's nudge, so it keeps its agent-working label too (an agent-paused issue with a live
# session would be re-dispatched on top of it). rc 1 = the work could not be pushed anywhere.
mechanical_checkpoint(){ local sess="$1" pane="$2" wd sha pushed="" stamp body
  # An unresolved repo must stop here: `gh -R ""` would fall back to whatever repo the cwd is.
  _checkpoint_target "$sess" && [[ -n "$_CP_SLUG" && "$_CP_SLUG" == */?* ]] \
    || { log "usage: cannot resolve issue/repo for $sess — no checkpoint"; return 1; }
  wd="$(cat "$RUN_DIR/$sess.wd" 2>/dev/null)"
  if [[ -n "$_CP_BRANCH" && -n "$wd" ]] && git -C "$wd" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -n "$(git -C "$wd" status --porcelain -- . ':!.claude' ':!.harness-task.md')" ]]; then
      git -C "$wd" add -A -- . ':!.claude' ':!.harness-task.md'
      git -C "$wd" commit -q --no-verify -m "wip: harness checkpoint of $sess at a usage limit (#$_CP_ISSUE)"
    fi
    sha="$(git -C "$wd" rev-parse --short HEAD)"; stamp="$(date +%Y%m%d%H%M)"
    if git -C "$wd" push -q origin "HEAD:refs/heads/$_CP_BRANCH" 2>/dev/null; then pushed="$_CP_BRANCH"
    elif git -C "$wd" push -q origin "HEAD:refs/heads/$_CP_BRANCH-checkpoint-$stamp" 2>/dev/null; then
      pushed="$_CP_BRANCH-checkpoint-$stamp (origin/$_CP_BRANCH had diverged; merge it by hand)"
    else
      log "usage: ERROR could not push $_CP_BRANCH from $wd for $sess — work stays local"; return 1
    fi
  fi
  body="<!-- harness-handoff issue=$_CP_ISSUE${_CP_BRANCH:+ branch=$_CP_BRANCH} -->
## Checkpoint by Harness (usage limit)
Session \`$sess\` is frozen at a usage limit and cannot run its own /handoff, so Harness checkpointed it mechanically. The session was left running and resumes when the limit resets.
${pushed:+All work in progress was committed and pushed to \`$pushed\` @ \`$sha\`. }This is not the agent's own handoff: rebuild context from the branch's commits and its diff against the base.

Last screen:
\`\`\`
$(tail -30 <<<"$pane" | cut -c1-200)
\`\`\`"
  gh issue comment "$_CP_ISSUE" -R "$_CP_SLUG" --body "$body" >/dev/null 2>&1 \
    || log "usage: handoff comment for $_CP_SLUG#$_CP_ISSUE failed"
  log "usage: mechanical checkpoint of $sess (${pushed:-no branch pushed}) — left running"; }

# limit_checkpoint_once <sess> <pane> — mechanical checkpoint, once per limit episode (the marker
# is cleared by watchdog_session the moment the session is off the limit).
limit_checkpoint_once(){ local mark="$RUN_DIR/$1.limitcp"
  [[ -f "$mark" ]] && return 0
  mechanical_checkpoint "$1" "$2" || return 0
  touch "$mark"; harness_event usage_checkpoint session="$1" reason=limit_message; }

# usage_checkpoint_account <account> <reason> — checkpoint every live session on <account> (or of
# unknown account: a checkpoint loses nothing, a missed one can lose a worktree).
usage_checkpoint_account(){ local acct="$1" reason="$2" sess sa pane msg
  while read -r sess; do
    [[ -z "$sess" ]] && continue
    sa="$(session_account "$sess")"; [[ -z "$sa" || "$sa" == "$acct" ]] || continue
    pane="$(tmux capture-pane -p -t "$sess" 2>/dev/null)"
    if session_limit_menu "$pane" || session_limit_idle "$pane"; then
      limit_checkpoint_once "$sess" "$pane"; continue
    fi
    _checkpoint_target "$sess" || continue
    msg="$(_checkpoint_msg "$_CP_ISSUE" "$_CP_SLUG" "$_CP_BRANCH" "$HARNESS_LABEL_WORKING" "$HARNESS_LABEL_PAUSED" "$reason")"
    cli_send "$sess" "$(cat "$RUN_DIR/$sess.wd" 2>/dev/null)" "$msg"
    log "usage: checkpoint requested: $sess ($_CP_SLUG#$_CP_ISSUE)"
  done < <(checkpoint_sessions); }

# usage_held — true while ANY account is held. New panes pick their account at launch, so a hold
# cannot be steered to a free account: it holds every claim of this fleet.
usage_held(){ compgen -G "$(_usage_hold_dir)/*.hold" >/dev/null; }

# _usage_reading_new <acct> <win> <pct> <reset> — true when this reading differs from the last one
# logged for <acct>/<win> (and records it). Every worker polls the same windows, and a status-line
# drop repeats its reading until the session renders again: only a changed reading is a new one (#364).
_usage_reading_new(){ local f last; f="$RUN_DIR/usage-readings/$(_usage_key "$1")__$(_usage_key "$2")"
  last="$(cat "$f" 2>/dev/null)"; [[ "$last" != "$3"$'\t'"$4" ]] || return 1
  mkdir -p "${f%/*}" 2>/dev/null; printf '%s\t%s' "$3" "$4" > "$f" 2>/dev/null; return 0; }

# usage_watch — one poll: read usage, open a hold (and checkpoint) for an account crossing the
# threshold, release a hold whose window has reset. Every worker calls it; the flock makes the
# crossing fire once. Unavailable usage changes nothing except a hold whose reset time has passed.
# #364: each new reading is logged as one `usage_reading` event per account/window (forecast.py
# calibrates $ per 1% from them), emitted after the lock is released so a slow log never holds the
# other workers' polls.
usage_watch(){ local out lockfd acct win pct reset key hf now r; local -A over=() seen=(); local -a readings=()
  out="$(cli_limit_usage 2>/dev/null)"; local avail=$?
  mkdir -p "$(_usage_hold_dir)"
  exec {lockfd}>"$RUN_DIR/usage.lock"; flock "$lockfd"
  if (( avail == 0 )); then
    rm -f "$RUN_DIR/usage.unavailable"
    while IFS=$'\t' read -r acct win pct reset; do
      [[ -n "$acct" && "${pct%.*}" =~ ^[0-9]+$ ]] || continue   # a malformed line is skipped, never fatal
      (( ${pct%.*} >= HARNESS_USAGE_CHECKPOINT_PCT )) && over[$acct]="$win"$'\t'"$pct"$'\t'"$reset"
      key="$acct"$'\t'"$win"; [[ -n "$win" && -z "${seen[$key]:-}" ]] || continue
      seen[$key]=1; _usage_reading_new "$acct" "$win" "$pct" "$reset" \
        && readings+=("$acct"$'\t'"$win"$'\t'"$pct"$'\t'"$reset")
    done <<< "$out"
    for acct in "${!over[@]}"; do
      hf="$(_usage_hold_dir)/$(_usage_key "$acct").hold"; [[ -f "$hf" ]] && continue
      printf '%s\t%s\n' "$acct" "${over[$acct]}" > "$hf"
      IFS=$'\t' read -r win pct reset <<< "${over[$acct]}"
      log "usage: $acct $win window at ${pct}% (>= ${HARNESS_USAGE_CHECKPOINT_PCT}%) — checkpointing live sessions, holding claims until it resets"
      harness_event usage_checkpoint account="$acct" window="$win" pct="$pct" resets_at="$reset"
      usage_checkpoint_account "$acct" "usage limit near ($win window at ${pct}%)"
    done
  elif [[ ! -f "$RUN_DIR/usage.unavailable" ]]; then
    touch "$RUN_DIR/usage.unavailable"; log "usage: usage unavailable for $(cli_name) — checkpointing on the limit message only"
  fi
  now="$(date +%s)"; shopt -s nullglob
  for hf in "$(_usage_hold_dir)"/*.hold; do
    IFS=$'\t' read -r acct win pct reset < "$hf"
    if (( avail == 0 )); then [[ -n "${over[$acct]:-}" ]] && continue
    else (( ${reset:-0} > now )) && continue; fi
    rm -f "$hf"; log "usage: $acct $win window reset — resuming claims"
    harness_event usage_resume account="$acct" window="$win"
  done
  shopt -u nullglob; flock -u "$lockfd"; exec {lockfd}>&-
  for r in "${readings[@]}"; do
    IFS=$'\t' read -r acct win pct reset <<< "$r"
    harness_event usage_reading account="$acct" window="$win" pct="$pct" resets_at="$reset"
  done
  return 0; }

# usage_report — the windows and holds, one line per account window (harness status).
usage_report(){ local out acct win pct reset hold
  out="$(cli_limit_usage 2>/dev/null)" || { echo "  usage: unavailable for $(cli_name) (checkpoints on the limit message only)"; return 0; }
  [[ -n "$out" ]] || { echo "  usage: no open windows reported"; return 0; }
  while IFS=$'\t' read -r acct win pct reset; do
    [[ -n "$acct" ]] || continue
    hold=""; [[ -f "$(_usage_hold_dir)/$(_usage_key "$acct").hold" ]] && hold="  HOLD (checkpointed; claims paused)"
    printf '  usage: %s %s %s%% (checkpoint at %s%%, resets %s)%s\n' "$acct" "$win" "$pct" \
      "$HARNESS_USAGE_CHECKPOINT_PCT" "$(date -d "@$reset" '+%a %H:%M' 2>/dev/null || echo "$reset")" "$hold"
  done <<< "$out"; }
