#!/usr/bin/env bash
# autorelease.sh — the fleet cuts its own Harness releases (#283, PRD #274). Sourced by drive.sh (so
# by pool-worker.sh and priority-worker.sh too), after lib.sh. Two triggers, both only for the
# Harness repo itself ($HARNESS_RELEASE_REPO), never another target repo:
#   - the Harness repo has no vX.Y.Z tag at all (#331) → release_tick queues one `bootstrap` per host,
#     released like a PRD close: the first release, which no edge-triggered event may ever cut
#   - a reviewed PRD the engine closes (close_prd)  → queued in `pending` as prd:<n>; release_tick
#     releases it at once, and keeps it queued through a running job or an errored release (#326)
#   - a merged bug fix (reap_team, drive_bug, reap_pool_bugs) → queued in `pending`; release_tick
#     cuts one patch release once the oldest queued fix is $HARNESS_RELEASE_THROTTLE seconds old, so
#     a burst of fixes is one release covering all of them and a late fix waits, never drops
# A red release gate (`harness release` rc 4) files one `bug` issue for that commit and is never
# re-run on it: the fix for that bug is a new commit, which is released like any other.
# State lives host-wide in $HARNESS_AUTORELEASE_DIR (release.sh writes its gate logs there too):
#   prd-<n>             a release was triggered for PRD <n> (CLOSE_PRD is re-emitted every poll)
#   bootstrap           the no-release-yet check ran to an answer: a bootstrap was queued, or a tag exists
#   pending             "<epoch>\t<issue>" per merged fix, "<epoch>\tprd:<n>" per PRD close,
#                       "<epoch>\tbootstrap" for the first release, not yet released
#   gate-failed-<sha>   the gate failed at <sha>; holds the bug issue filed for it, once filed
#   retry-after         epoch before which release_tick does not retry a release that errored
#   release.pid/.log    the background release job, stopped only by this PID

release_dir(){ echo "${HARNESS_AUTORELEASE_DIR:-${HARNESS_HOME:-$HOME/.harness}/autorelease}"; }
release_now(){ echo "${HARNESS_NOW:-$(date +%s)}"; }
release_repo(){ echo "${HARNESS_RELEASE_REPO:-VocanicZ/Harness}"; }

# release_repo_is_engine <slug> — rc 0 iff <slug> is the Harness repo itself (case-insensitive).
release_repo_is_engine(){ [[ -n "${1:-}" && "${1,,}" == "$(release_repo | tr '[:upper:]' '[:lower:]')" ]]; }

# release_on_prd_close <prd> — one release per reviewed PRD close; the marker makes the re-emitted
# CLOSE_PRD polls no-ops (noclobber: the first creator wins even across lanes). The close is queued,
# not kicked: a running job or an errored release leaves it in `pending` for the next tick (#326).
release_on_prd_close(){ local prd="$1" d lockfd; release_repo_is_engine "${SLUG:-}" || return 0
  d="$(release_dir)"; mkdir -p "$d"
  ( set -o noclobber; : > "$d/prd-$prd" ) 2>/dev/null || return 0
  log "auto-release: PRD #$prd closed in $SLUG — releasing"
  lock_acquire "$d/pending.lock" lockfd
  printf '%s\tprd:%s\n' "$(release_now)" "$prd" >> "$d/pending"
  lock_release "$lockfd"
  release_tick; }

# release_on_bug_merge <n> — queue merged fix #n for the next throttled patch release (once per issue).
release_on_bug_merge(){ local n="$1" d lockfd; release_repo_is_engine "${SLUG:-}" || return 0
  d="$(release_dir)"; mkdir -p "$d"
  lock_acquire "$d/pending.lock" lockfd
  if ! cut -f2 "$d/pending" 2>/dev/null | grep -qx -- "$n"; then
    printf '%s\t%s\n' "$(release_now)" "$n" >> "$d/pending"
    log "auto-release: bug #$n merged — queued for the next patch release"
  fi
  lock_release "$lockfd"; }

# release_bootstrap — queue one `bootstrap` release while the Harness repo has no vX.Y.Z tag (#331):
# a PRD close or fix merged under an engine without these hooks was never queued, so nothing else
# would cut the first release. Level-triggered, but asked once per host: the noclobber marker is
# written as soon as the answer is known (no tag → queued; a tag → never needed), and once it exists
# the check makes no git call. A failed fetch is no answer: no marker, so a later tick asks again.
release_bootstrap(){ local d tags lockfd; d="$(release_dir)"; [[ -e "$d/bootstrap" ]] && return 0
  git -C "$CHECKOUT" fetch -q --tags origin 2>/dev/null || return 0
  tags="$(git -C "$CHECKOUT" tag -l 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null)" || return 0
  mkdir -p "$d"; ( set -o noclobber; : > "$d/bootstrap" ) 2>/dev/null || return 0
  [[ -z "$tags" ]] || return 0
  log "auto-release: $SLUG has no release yet — queuing the bootstrap release"
  lock_acquire "$d/pending.lock" lockfd
  printf '%s\tbootstrap\n' "$(release_now)" >> "$d/pending"
  lock_release "$lockfd"; }

# release_tick — once per poll: a release when a PRD close or the bootstrap is queued (no throttle),
# or a patch release when the oldest queued fix has waited the throttle; never before `retry-after`.
release_tick(){ local d now oldest prds nums after; release_repo_is_engine "${SLUG:-}" || return 0
  release_bootstrap
  d="$(release_dir)"; [[ -s "$d/pending" ]] || return 0
  now="$(release_now)"
  after="$(cat "$d/retry-after" 2>/dev/null)"; [[ -n "$after" ]] && (( now < after )) && return 0
  prds="$(cut -f2 "$d/pending" | grep -E '^(prd:|bootstrap$)' | paste -sd' ' -)"
  nums="$(cut -f2 "$d/pending" | grep -vE '^(prd:|bootstrap$)' | paste -sd, -)"
  if [[ -z "$prds" ]]; then
    oldest="$(awk -F'\t' 'NR==1||$1<m{m=$1} END{print m}' "$d/pending")"
    [[ -n "$oldest" ]] && (( now - oldest >= ${HARNESS_RELEASE_THROTTLE:-3600} )) || return 0
  fi
  release_kick "$prds${prds:+${nums:+ }}${nums:+bug:$nums}"; }

# release_tick_lane — the priority lane's release_tick: the bug lane outlives a completed unit, so
# the fixes it merges are released even when no drive_unit poll is running for the Harness repo.
release_tick_lane(){ local repo SLUG CHECKOUT
  for repo in $(_bug_repos); do
    [[ -n "$repo" ]] || continue
    SLUG="$(_with_owner "$repo")"; release_repo_is_engine "$SLUG" || continue
    CHECKOUT="$(bug_checkout "$repo")"; release_tick
  done; }

# release_kick <reason> — release_run as a background job (it runs the whole suite as its gate).
# fd 9 is closed for it: start.sh's double-start lock must not be held by a job that outlives it.
# One job at a time: while one is live, a new kick starts nothing; what it was for stays queued in
# `pending` unless that job's release covers it, so the next tick releases it.
release_kick(){ local d pid; d="$(release_dir)"; mkdir -p "$d"
  pid="$(cat "$d/release.pid" 2>/dev/null)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then return 0; fi
  ( release_run "$@" ) >>"$d/release.log" 2>&1 9>&- &
  echo "$!" > "$d/release.pid"; }

# release_head — the commit to release: origin/<default branch> of the Harness checkout, fresh.
# A failed fetch prints nothing: the stale origin/<base> may predate the merge the release is for (#329).
release_head(){ local base; base="$(default_branch)"
  git -C "$CHECKOUT" fetch -q origin "$base" 2>/dev/null || return 0
  git -C "$CHECKOUT" rev-parse -q --verify "origin/$base^{commit}" 2>/dev/null; }

# release_run <reason> — run `harness release` for the default branch's head, one at a time.
# What it covers is the `pending` it saw before resolving the head: an entry queued after that may
# postdate the commit it releases, so it stays queued for the next tick.
release_run(){ local reason="$1" d lockfd plock start covered sha rc
  d="$(release_dir)"; mkdir -p "$d"
  lock_try "$d/lock" lockfd || { log "auto-release: a release is already running — $reason stays queued for the next tick"; return 0; }
  start="$(release_now)"
  lock_acquire "$d/pending.lock" plock; covered="$(cat "$d/pending" 2>/dev/null)"; lock_release "$plock"
  sha="$(release_head)"
  if [[ -z "$sha" ]]; then
    log "auto-release: cannot resolve the default branch of $CHECKOUT — $reason not released"
    lock_release "$lockfd"; return 0; fi
  # A red gate is never re-run on the same commit; only its bug filing is retried until it lands.
  if [[ -f "$d/gate-failed-$sha" ]]; then
    release_gate_bug "$sha" "$reason"
    lock_release "$lockfd"; return 0; fi
  harness_event release_triggered reason="$reason" sha="$sha"
  ( cd "$CHECKOUT" && HARNESS_RELEASE_REASON="$reason" HARNESS_RELEASE_REPO="$(release_repo)" \
      HARNESS_AUTORELEASE_DIR="$d" bash "${HARNESS_RELEASE_CMD:-$ENGINE_DIR/scripts/release.sh}" --ref "$sha" ); rc=$?
  case "$rc" in
    0) release_clear_pending "$covered"; rm -f "$d/retry-after"
       log "auto-release: released ${sha:0:7} ($reason)"
       harness_event release_published reason="$reason" sha="$sha";;
    4) : > "$d/gate-failed-$sha"
       log "auto-release: release gate failed at ${sha:0:7} ($reason) — filing a bug, not retrying this commit"
       release_gate_bug "$sha" "$reason"
       harness_event release_gate_failed reason="$reason" sha="$sha" issue="$_GATE_BUG";;
    *) echo $(( start + ${HARNESS_RELEASE_THROTTLE:-3600} )) > "$d/retry-after"
       log "auto-release: harness release exited $rc at ${sha:0:7} ($reason) — retrying after the throttle";;
  esac
  lock_release "$lockfd"; return 0; }

# release_clear_pending <entries> — drop the queued entries (lines of `pending`) a release covered.
release_clear_pending(){ local d tmp lockfd; d="$(release_dir)"; [[ -f "$d/pending" && -n "$1" ]] || return 0
  lock_acquire "$d/pending.lock" lockfd
  tmp="$(mktemp "$d/pending.XXXXXX")" \
    && awk 'NR==FNR{c[$0]=1; next} !($0 in c)' <(printf '%s\n' "$1") "$d/pending" > "$tmp" && mv -f "$tmp" "$d/pending"
  lock_release "$lockfd"; }

# release_gate_bug <sha> <reason> — file one bug issue for a red gate at <sha>, idempotently: the
# marker records the issue once filed, and an open bug with the same title is never duplicated.
# Sets _GATE_BUG to the issue number (empty while it is not filed yet).
release_gate_bug(){ local sha="$1" reason="$2" d m short title open url n body log
  d="$(release_dir)"; m="$d/gate-failed-$sha"; short="${sha:0:7}"; _GATE_BUG="$(cat "$m" 2>/dev/null)"
  [[ -n "$_GATE_BUG" ]] && return 0
  title="release gate failed at $short"
  open="$(gh issue list -R "$SLUG" --label "$HARNESS_LABEL_BUG" --state open \
    --search "$title in:title" --json number 2>/dev/null)" || { log "auto-release: cannot list bugs — filing for $short next poll"; return 0; }
  n="$(sed -n 's/.*"number":[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$open" | head -1)"
  if [[ -z "$n" ]]; then
    log="$d/gate-$sha.log"; body="$(mktemp)"
    { echo "\`harness release\` ($reason) ran the release gate (\`test/run.sh\`) at $sha and it failed, so no release was cut."
      echo "The fleet will not re-run the gate on this commit. Fixing this is a new commit, which the next release picks up."
      # #333: the failures first. Suites run alphabetically, so an early one's FAIL lines are far
      # above the tail; each is shown under its suite header, after what run.sh printed itself.
      echo; echo "Failures in the gate log (each under its suite):"
      echo; echo '```'
      awk '!seen && !/^== / { print; next } /^== / { seen = 1; h = $0; shown = 0; next }
           /^ *(FAIL|not ok)/ { if (!shown) print h; shown = 1; print }' "$log" 2>/dev/null | head -n 300
      echo '```'
      echo; echo "Last 80 lines of the gate log (\`$(hostname 2>/dev/null)\`:\`$log\`):"
      echo; echo '```'; tail -n 80 "$log" 2>/dev/null || echo "(no gate log at $log)"; echo '```'
    } > "$body"
    url="$(gh issue create -R "$SLUG" --label "$HARNESS_LABEL_BUG" --title "$title" --body-file "$body" 2>/dev/null)"; rm -f "$body"
    n="${url##*/}"; [[ "$n" =~ ^[0-9]+$ ]] || { log "auto-release: filing the gate bug for $short failed — retrying next poll"; return 0; }
    log "auto-release: filed bug #$n for the red gate at $short"
  fi
  echo "$n" > "$m"; _GATE_BUG="$n"; }
