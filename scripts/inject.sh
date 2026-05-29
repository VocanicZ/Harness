#!/usr/bin/env bash
# inject.sh <plan|prd|issue> [--unit <id>] "<brief>"
#   Thin launcher for live work injection. Resolves the unit, refuses to run while a REVIEW
#   session is live, renders prompts/inject.md, and launches a headless Ralph session named
#   hz-inject-<unit> (never collides with team_sessions, so it consumes no CAP/orch slot).
#   The live pool picks up the injected work on its next poll — no fleet restart.
set -uo pipefail

# Source lib.sh only when executed directly (not when sourced by the test).
if [[ -z "${_HARNESS_LIB_SOURCED:-}" ]]; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fi

ALTITUDE="${1:?usage: inject.sh <plan|prd|issue> [--unit <id>] \"<brief>\"}"; shift
case "$ALTITUDE" in plan|prd|issue) ;; *) die "bad altitude: $ALTITUDE (want plan|prd|issue)";; esac

UNIT="main"
if [[ "${1:-}" == "--unit" ]]; then UNIT="${2:?--unit needs an id}"; shift 2; fi

# --force: override the pause guard below. Strip it from the args so it never leaks into the brief.
FORCE=0; _args=()
for _a in "$@"; do
  if [[ "$_a" == "--force" ]]; then FORCE=1; else _args+=("$_a"); fi
done
set -- "${_args[@]+"${_args[@]}"}"
BRIEF="$*"
[[ -n "$BRIEF" ]] || die "a brief is required: inject.sh $ALTITUDE \"<brief>\""

# Safety: never inject while the fleet is paused. Other worker paths (drive.sh, pool-worker.sh,
# priority-worker.sh) all gate on is_paused; inject.sh must too — injecting mutates GitHub/git
# (creates issues, reopens the PRD, clears the reviewed label, commits PLAN.md) while the fleet is
# supposed to be frozen/checkpointing. Refuse by default; --force overrides for the rare case (#90).
if is_paused && [[ "$FORCE" != 1 ]]; then
  die "fleet is PAUSED ($PAUSE_FLAG) — refusing to inject (would mutate GitHub/git while frozen). Run 'harness resume' first, or pass --force to override."
fi

SLUG="$(unit_slug "$UNIT")"; [[ -n "$SLUG" ]] || die "could not resolve repo for unit: $UNIT"
PROJECT="$UNIT"; DESC="$(unit_desc "$UNIT")"; CHECKOUT="$(unit_checkout "$UNIT")"

# Safety: never inject while a REVIEW orchestration session is live for this unit — a REVIEW
# could close the PRD out from under us. All orch actions share sess_orch's name; the .goal
# file records which action it is.
orch="$(sess_orch "$UNIT")"
if session_live "$orch" && [[ "$(cat "$RUN_DIR/$orch.goal" 2>/dev/null)" == REVIEW ]]; then
  die "a REVIEW session ($orch) is live for $UNIT — wait for it to finish, or abort it, then retry"
fi

sess="$(sess_inject "$UNIT")"
session_live "$sess" && die "an injector is already running for $UNIT ($sess)"

PROMISE="INJECT DONE"; MAXITER="$HARNESS_INJECT_MAXITER"; GOAL="INJECT"
render "$PROMPTS_DIR/inject.md" \
  ALTITUDE="$ALTITUDE" BRIEF="$BRIEF" PROJECT="$PROJECT" DESC="$DESC" SLUG="$SLUG" \
  OWNER="$HARNESS_OWNER" SPEC="$HARNESS_SPEC" PROMISE="$PROMISE" \
  LABEL_READY="$HARNESS_LABEL_READY" LABEL_PRD="$HARNESS_LABEL_PRD" \
  LABEL_WORKING="$HARNESS_LABEL_WORKING" LABEL_BLOCKED="$HARNESS_LABEL_BLOCKED" \
  LABEL_REVIEWED="$HARNESS_LABEL_REVIEWED" > "$CHECKOUT/.harness-task.md"

launch_claude "$sess" "$CHECKOUT"
# Be honest about whether anything will pick the work up. A resident pool/lane claims it next
# poll (no restart). A retired pool (workers exited 0 on all_complete, no live lane) leaves the
# new issues unclaimed — say so and point at the recovery command instead of "no restart" (#22).
if pool_live; then
  log "injector launched: $sess (altitude=$ALTITUDE unit=$UNIT) — pool picks it up next poll, no restart"
else
  log "injector launched: $sess (altitude=$ALTITUDE unit=$UNIT) — but the pool is STOPPED (no live workers or lane); the new work will sit unclaimed. Run 'harness start --recover' to pick it up."
fi
