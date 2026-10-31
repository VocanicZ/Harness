#!/usr/bin/env bash
# lib.sh — shared config + helpers for the Harness orchestrator.
set -uo pipefail
_HARNESS_LIB_SOURCED=1

# ENGINE_DIR / STATE_DIR split (#53): the engine's code+assets and a project's runtime state are
# now distinct roots. ENGINE_DIR is the engine ROOT — the parent of the scripts/ dir this lib.sh
# now lives in (#60); STATE_DIR is the per-project .harness/. bin/harness resolves+exports both
# (engine via realpath of the entrypoint, so a PATH symlink resolves to the real install); when
# sourced directly (tests, a vendored layout with no separation) BOTH default to that engine root —
# the old single-HARNESS_DIR behavior. HARNESS_DIR is retained as that default base (still
# referenced by deployment scripts + tests).
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="${ENGINE_DIR:-$HARNESS_DIR}"
STATE_DIR="${STATE_DIR:-$HARNESS_DIR}"
export ENGINE_DIR STATE_DIR
PROJECT_ROOT="$(cd "$STATE_DIR/.." && pwd)"
# asset paths (read-only engine code/templates) — under ENGINE_DIR; sub-scripts live in scripts/ (#60)
PROMPTS_DIR="$ENGINE_DIR/prompts"
ISSUELIB="$ENGINE_DIR/scripts/issuelib.py"
# state paths (per-project config + runtime, read+write) — under STATE_DIR
CONFIG="$STATE_DIR/config"
TARGETS_TSV="${TARGETS_TSV:-$STATE_DIR/targets.tsv}"
RUN_DIR="${RUN_DIR:-$STATE_DIR/run}"
WORKTREES_DIR="$STATE_DIR/worktrees"
CHECKOUTS_DIR="$STATE_DIR/checkouts"

# config lines are `: "${KEY:=val}"` so pre-existing env overrides the file.
[[ -f "$CONFIG" ]] && source "$CONFIG"

: "${HARNESS_MODE:=issue-only}"        # issue-only | prd | planned
: "${HARNESS_TOPOLOGY:=single}"        # single | multi
: "${HARNESS_OWNER:=}"
: "${HARNESS_REPO:=}"
: "${HARNESS_SPEC:=}"
: "${HARNESS_AUTONOMOUS:=true}"
: "${HARNESS_POOL:=3}"
: "${HARNESS_CAP:=3}"
: "${HARNESS_POLL:=300}"               # resident pool: slow idle/steady-state poll
: "${HARNESS_PRIORITY_POLL:=60}"       # fast cadence for the priority bug lane (#23)
: "${HARNESS_IMPL_MAXITER:=30}"
: "${HARNESS_ORCH_MAXITER:=8}"
: "${HARNESS_INJECT_MAXITER:=15}"
: "${HARNESS_SESS_PREFIX:=hz}"
: "${HARNESS_LABEL_READY:=ready-for-agent}"
: "${HARNESS_LABEL_PRD:=prd}"
: "${HARNESS_LABEL_WORKING:=agent-working}"
: "${HARNESS_LABEL_BLOCKED:=agent-blocked}"
: "${HARNESS_LABEL_REVIEWED:=reviewed}"
: "${HARNESS_LABEL_COORD:=coordination}"
: "${HARNESS_LABEL_PAUSED:=agent-paused}"   # force-paused: checkpointed to GitHub, resumable
: "${HARNESS_LABEL_BUG:=bug}"               # bug-lane: never claimed by the normal pool
: "${HARNESS_LABEL_BUG_TRIAGED:=bug-triaged}"  # bug-lane: triaged, still isolated from the pool
: "${HARNESS_PAUSE_GRACE:=300}"             # seconds pause --force waits for each agent to confirm
: "${HARNESS_MAIN_REPO:=}"             # multi: umbrella repo for coordination issues (optional)
: "${HARNESS_AUTHOR_ALLOWLIST:=}"      # secure-by-default: empty = self-only; comma-sep logins; `*` = allow-any
: "${HARNESS_USE_POLLER:=1}"           # #182: ON by default — workers read the host poller's shared snapshots; 0 = direct-gh polling
: "${HARNESS_PREFIX_COLLISION:=refuse}"  # PRD-B slice 4 (#73): refuse|warn — start-time guard when another active fleet's session prefix collides
: "${HARNESS_STALL_RETRIES:=3}"          # #115: consecutive stalled polls before the watchdog kills a wedged session
: "${HARNESS_ORPHAN_LOCK_MIN:=20}"       # #179: minutes an agent-working issue may sit with no live session before the pool unlocks it
: "${HARNESS_BLOCKED_BACKOFF_MIN:=0}"    # #271: minutes a parked agent-blocked issue is held before an autonomous fleet retries it unchanged; 0 = until it changes
: "${HARNESS_LIMIT_NUDGE_EVERY:=5}"      # #120: re-nudge a quota-parked session every Nth poll (never killed — the quota returns on its own)
: "${HARNESS_USAGE_CHECKPOINT_PCT:=90}"  # #194: checkpoint every live session + hold claims at this % of any usage window
: "${HARNESS_ONE_STOP_PCT:=98}"          # #365: /harness-one recommends APPROVE iff now% + p80% + reserve <= this % of every usage window
: "${HARNESS_ONE_RESERVE_PCT:=2}"        # #365: % of a window held back for the checkpoint (commit, push, handoff) when the budget runs out
: "${HARNESS_ONE_STALE_MIN:=30}"         # #365: a usage reading older than this many minutes (or of unknown age) is stale…
: "${HARNESS_ONE_STALE_PAD_PCT:=3}"      # #365: …and the gate pads it by this many points
: "${HARNESS_ONE_LEASE_MIN:=240}"         # #366: minutes a /harness-one claim holds off the reapers after its last `harness one start|phase`
: "${HARNESS_USAGE_CMD:=}"               # #194: command printing `<account>\t<window>\t<pct>\t<resets_at>` lines; overrides the CLI adapter
: "${HARNESS_USAGE_STATUSLINE:=1}"       # #194: 1 = wire each worktree to report its usage windows (cli_usage_setup); 0 = off
: "${HARNESS_GH_RATE_GUARD:=1}"          # #183: 1 = sleep through a GitHub rate limit + hold claims on a low budget; 0 = off
: "${HARNESS_GH_BUDGET_PCT:=20}"         # #183: below this % of the token's core/graphql budget, claim nothing new until the reset
: "${HARNESS_GH_RATE_TTL:=60}"           # #183: seconds a `gh api rate_limit` probe is reused across this host's workers
: "${HARNESS_WORKTREE_HOOK:=}"           # optional project script run in every fresh worktree after `worktree add`
: "${HARNESS_GAUNTLET_ROUNDS:=3}"        # gauntlet review: rounds allowed before the reviewer concedes
: "${HARNESS_SECURITY_AUDIT:=0}"         # 1 = PRD review runs the vendored security-audit skill after the criteria gate
: "${HARNESS_SECURITY_AUDIT_ROUNDS:=2}"  # security audit: rounds with filed findings before the reviewer concedes
: "${HARNESS_SEED_CI:=0}"               # 1 = seed.sh commits a CI workflow + CI-requiring branch protection to unit repos; 0 = off
: "${HARNESS_CI_GATE:=0}"                # #50/#245: 1 = hold unit dispatch while the default branch's GitHub CI is red; 0 = off (default: no GitHub CI)
: "${HARNESS_DISABLE_CI:=1}"             # #245: seeding disables a repo's GitHub Actions — 1 = test-CI only (release/deploy kept); all = every workflow; 0 = off
: "${HARNESS_POOL_TAKES_BUGS:=1}"         # #214: 1 = an idle pool slot takes the oldest bug while the priority lane is busy; 0 = bugs stay on the lane
: "${HARNESS_SWARM:=auto}"               # #202: auto = lanes run full-suite verification as a swarm job when `swarm` is on PATH; off = always local
# #207: HARNESS_TURN_MAX / HARNESS_INTERRUPT_WAIT and the stuck-turn helpers live beside this file,
# shared with supervise.sh (which watches panes no fleet's lib.sh is loaded for).
source "$(dirname "${BASH_SOURCE[0]}")/turn.sh"
# #188: the agent CLI adapter seam — the only reader of the fleet's CLI setting (cli_* functions).
# Each adapter defaults and exports its own config (HARNESS_<CLI>_BIN / _FLAGS) when it is sourced.
source "$(dirname "${BASH_SOURCE[0]}")/cli/dispatch.sh"

export HARNESS_MODE HARNESS_TOPOLOGY HARNESS_OWNER HARNESS_REPO HARNESS_SPEC HARNESS_AUTONOMOUS \
  HARNESS_LABEL_READY HARNESS_LABEL_PRD HARNESS_LABEL_WORKING HARNESS_LABEL_BLOCKED \
  HARNESS_LABEL_REVIEWED HARNESS_LABEL_COORD HARNESS_LABEL_PAUSED HARNESS_MAIN_REPO \
  HARNESS_LABEL_BUG HARNESS_LABEL_BUG_TRIAGED \
  HARNESS_AUTHOR_ALLOWLIST HARNESS_USE_POLLER HARNESS_PREFIX_COLLISION HARNESS_WORKTREE_HOOK \
  HARNESS_GAUNTLET_ROUNDS HARNESS_CI_GATE HARNESS_SEED_CI HARNESS_DISABLE_CI HARNESS_SESS_PREFIX HARNESS_SECURITY_AUDIT HARNESS_SECURITY_AUDIT_ROUNDS \
  HARNESS_USAGE_CHECKPOINT_PCT HARNESS_USAGE_CMD HARNESS_USAGE_STATUSLINE \
  HARNESS_GH_RATE_GUARD HARNESS_GH_BUDGET_PCT HARNESS_GH_RATE_TTL HARNESS_SWARM HARNESS_BLOCKED_BACKOFF_MIN \
  HARNESS_TURN_MAX HARNESS_INTERRUPT_WAIT

OWNER="$HARNESS_OWNER"
CAP="$HARNESS_CAP"; POLL="$HARNESS_POLL"; POOL="$HARNESS_POOL"; PRIORITY_POLL="$HARNESS_PRIORITY_POLL"
IMPL_MAXITER="$HARNESS_IMPL_MAXITER"; ORCH_MAXITER="$HARNESS_ORCH_MAXITER"
CLAIMS_DIR="${CLAIMS_DIR:-$RUN_DIR/claims}"
POOL_LOCK="${POOL_LOCK:-$RUN_DIR/pool.lock}"
PAUSE_FLAG="${PAUSE_FLAG:-$RUN_DIR/PAUSED}"
mkdir -p "$RUN_DIR" "$WORKTREES_DIR" "$CHECKOUTS_DIR" "$CLAIMS_DIR" 2>/dev/null || true

# PRD-B host poller (#71): host-level (NOT per-project) paths under the ~/.harness host root from
# PRD-A. One poller refreshes a raw, versioned snapshot per registered repo into snapshots/; workers
# (slice 3) read those instead of polling GitHub. These are SEAMS — env overrides let tests point
# them at a temp host root. Exported so the nohup'd poller child (ensure_poller) inherits them.
HARNESS_HOME="${HARNESS_HOME:-$HOME/.harness}"
HARNESS_POLLER_DIR="${HARNESS_POLLER_DIR:-$HARNESS_HOME/poller}"
HARNESS_SNAPSHOTS_DIR="${HARNESS_SNAPSHOTS_DIR:-$HARNESS_HOME/snapshots}"
export HARNESS_HOME HARNESS_POLLER_DIR HARNESS_SNAPSHOTS_DIR
POLLER_REGISTRY_DIR="$HARNESS_POLLER_DIR/registry"
POLLER_PID="$HARNESS_POLLER_DIR/poller.pid"
POLLER_LOCK="$HARNESS_POLLER_DIR/poller.lock"

# Host-wide fleet registry (prefix-collision guard). Its own directory, NOT poller/registry: those
# files are poller.sh's GitHub work list, so registering there unconditionally would enroll a fleet
# into shared-token polling it never opted into. Same env-seam discipline as the poller paths above
# so tests can point it at a temp root; exported so sub-scripts inherit it.
HARNESS_FLEETS_DIR="${HARNESS_FLEETS_DIR:-$HARNESS_HOME/fleets}"
export HARNESS_FLEETS_DIR

log(){ printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "${UNIT:-harness}" "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ensure_safe(){ git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$1" || git config --global --add safe.directory "$1"; }
# run_worktree_hook <dir> — run HARNESS_WORKTREE_HOOK inside a freshly added worktree.
# `git worktree add` produces a BARE checkout of the tracked tree: submodules are empty dirs
# (worktree add never inits them), and anything the main checkout carries untracked — toolchain
# symlinks, prebuilt engine/SDK binaries, build artifacts, import/index caches — is absent. A
# repo that needs any of it points HARNESS_WORKTREE_HOOK at a script; it runs once per fresh
# worktree with cwd = that worktree and the path as $1. Empty (the default) = no-op, so this
# changes nothing for repos that clone-and-go.
# Non-fatal by design: a hook failure is logged and the session still launches — agents are
# autonomous and can provision the rest themselves, and a hard fail here would strand the issue
# under agent-working with no session (the #34 failure mode).
run_worktree_hook(){
  local wd="$1" hook="$HARNESS_WORKTREE_HOOK"
  [[ -n "$hook" ]] || return 0
  [[ "$hook" == /* ]] || hook="$PROJECT_ROOT/$hook"   # relative paths resolve against the project root
  [[ -x "$hook" ]] || { log "worktree hook not executable, skipping: $hook"; return 0; }
  log "worktree hook: $hook ($wd)"
  ( cd "$wd" && "$hook" "$wd" ) || log "worktree hook FAILED in $wd — launching anyway"
}
# lane_setting <wd> <model|effort> — the lane's own model or effort, as the worktree hook set it:
# a `model=<m>` / `effort=<e>` line in <wd>/.harness-lane (empty = the CLI's default). The file is
# CLI-neutral; launch_agent hands both to cli_launch, so every CLI launches the lane with them. It
# is kept out of the lane's commits (info/exclude), like the bypass settings.
HARNESS_LANE_FILE=.harness-lane
lane_setting(){ local f="$1/$HARNESS_LANE_FILE" k v out=
  [[ -f "$f" ]] || return 0
  git_exclude "$1" "$HARNESS_LANE_FILE"
  while IFS='=' read -r k v; do [[ "$k" == "$2" ]] && out="${v//[[:space:]]/}"; done < "$f"
  printf '%s' "$out"; }
# git_exclude <dir> <pattern> — add <pattern> to <dir>'s info/exclude (a worktree's own), once.
git_exclude(){ local excl
  # --git-path is relative to <dir> in a plain repo; this shell's cwd is not <dir>.
  excl="$(cd "$1" && git rev-parse --git-path info/exclude 2>/dev/null)" || return 0
  [[ -n "$excl" && "$excl" != /* ]] && excl="$1/$excl"
  [[ -n "$excl" ]] || return 0
  mkdir -p "$(dirname "$excl")"
  grep -qxF "$2" "$excl" 2>/dev/null || echo "$2" >> "$excl"; }
# ensure_trusted <dir> — pre-accept the agent CLI's workspace-trust dialog for <dir> so an autonomous
# (headless) launch in a never-trusted tree doesn't block FOREVER at the "Do you trust the files in
# this folder?" gate (#67). The skip-permissions flags suppress tool-permission prompts but NOT this
# separate gate. Scoped to autonomous runs (consistent with the skip-permissions posture) — a
# supervised launch keeps the CLI's default trust prompt. Where the trust lives is the adapter's
# (cli_trust): claude seeds every account config the pane may read, agy its settings.json.
ensure_trusted(){
  [[ "${HARNESS_AUTONOMOUS:-true}" == true ]] || return 0
  cli_trust "$1"; return 0; }
# ensure_bypass <dir> — the spawned session AND its sub-agents run without approval prompts
# (cli_bypass): an autonomous run has no human to answer one, and a sub-agent that fell back to
# ask mode wedged the lane forever. Scoped to autonomous runs, mirroring ensure_trusted.
ensure_bypass(){
  [[ "${HARNESS_AUTONOMOUS:-true}" == true ]] || return 0
  cli_bypass "$1"; }
is_paused(){ [[ -f "$PAUSE_FLAG" ]]; }

_with_owner(){ case "$1" in */*) echo "$1";; *) [[ -n "$HARNESS_OWNER" ]] && echo "$HARNESS_OWNER/$1" || echo "$1";; esac; }

# --- registry / topology -----------------------------------------------------
# multi: rows of `id <TAB> repo <TAB> deps(comma|-) <TAB> desc` in TARGETS_TSV.
# single: one synthetic unit "main" whose repo is HARNESS_REPO, no deps.
_tgt_row(){ awk -F'\t' -v s="$1" '!/^#/ && $1==s {print; exit}' "$TARGETS_TSV"; }
_tgt_field(){ _tgt_row "$1" | awk -F'\t' -v c="$2" '{print $c}'; }
all_units(){
  if [[ "$HARNESS_TOPOLOGY" == single ]]; then echo main
  else awk -F'\t' '!/^#/ && NF>=2 {print $1}' "$TARGETS_TSV"; fi
}
unit_repo(){ if [[ "$HARNESS_TOPOLOGY" == single ]]; then echo "$HARNESS_REPO"; else _tgt_field "$1" 2; fi; }
unit_deps(){ if [[ "$HARNESS_TOPOLOGY" == single ]]; then echo "-"; else local d; d="$(_tgt_field "$1" 3)"; echo "${d:--}"; fi; }
unit_desc(){ if [[ "$HARNESS_TOPOLOGY" == single ]]; then echo "${HARNESS_REPO##*/}"; else _tgt_field "$1" 4; fi; }
unit_slug(){ _with_owner "$(unit_repo "$1")"; }
unit_checkout(){ if [[ "$HARNESS_TOPOLOGY" == single ]]; then echo "$PROJECT_ROOT"; else echo "$CHECKOUTS_DIR/$(unit_repo "$1" | sed 's#.*/##')"; fi; }

# --- completeness (GitHub = source of truth; tests override unit_complete) ----
unit_complete(){ [[ "$(python3 "$ISSUELIB" complete "$(unit_repo "$1")" 2>/dev/null)" == DONE ]]; }
deps_complete(){
  local deps; deps="$(unit_deps "$1")"
  [[ -z "$deps" || "$deps" == "-" ]] && return 0
  local d ds; IFS=',' read -ra ds <<< "$deps"
  for d in "${ds[@]}"; do unit_complete "$d" || return 1; done
  return 0
}
all_complete(){ local u; for u in $(all_units); do unit_complete "$u" || return 1; done; return 0; }

# --- claims (local filesystem; pool is single-host) --------------------------
is_claimed(){ local f="$CLAIMS_DIR/$1.claim" pid; [[ -f "$f" ]] || return 1
  pid="$(awk '{print $2; exit}' "$f" 2>/dev/null)"; [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; }
clear_stale_claims(){ shopt -s nullglob; local f pid u
  for f in "$CLAIMS_DIR"/*.claim; do pid="$(awk '{print $2; exit}' "$f" 2>/dev/null)"
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then u="$(basename "$f" .claim)"; rm -f "$f"; echo "  cleared stale claim $u"; fi
  done; shopt -u nullglob; }
claimable_units(){ local u; for u in $(all_units); do
    unit_complete "$u" && continue; deps_complete "$u" || continue; is_claimed "$u" && continue; echo "$u"; done; }
claim_next(){ local wid="$1" u lockfd; exec {lockfd}>"$POOL_LOCK"; flock "$lockfd"
  u="$(claimable_units | head -n1)"; [[ -n "$u" ]] && printf '%s %s\n' "$wid" "$$" > "$CLAIMS_DIR/$u.claim"
  flock -u "$lockfd"; exec {lockfd}>&-
  [[ -n "$u" ]] && harness_event claim unit="$u" worker="$wid"
  echo "$u"; }
release_claim(){ rm -f "$CLAIMS_DIR/$1.claim"; harness_event release unit="$1"; }
worker_unit(){ local wid="$1" f; shopt -s nullglob
  for f in "$CLAIMS_DIR"/*.claim; do [[ "$(awk '{print $1; exit}' "$f")" == "$wid" ]] && { basename "$f" .claim; shopt -u nullglob; return; }; done
  shopt -u nullglob; }

# --- priority bug-lane claims (#26, #37) -------------------------------------
# A bug-lane candidate is a repo-qualified token "<repo>#<num>" (#37): GitHub issue numbers are
# per-repo, so in a `multi` topology two repos can each hold a bug #5 — the repo qualifier keeps
# their claims and routing DISTINCT. Bug claims share CLAIMS_DIR with unit claims, keyed
# `bug-<repo-sanitised>-<num>.claim`, so the existing clear_stale_claims sweep (dead-pid claim
# files) covers them too — start --recover frees a stale bug-claim with no extra code. They reuse
# POOL_LOCK so a bug-claim never races a unit-claim on the single host. _repo_bugs (per-repo) and
# _bug_numbers (all repos, globally sorted) are the seams tests override; claimable_bugs filters
# out already-claimed tokens (mirrors claimable_units).
_bug_repos(){ if [[ "$HARNESS_TOPOLOGY" == single ]]; then echo "$HARNESS_REPO"
  else local u; for u in $(all_units); do unit_repo "$u"; done | sort -u; fi; }
# per-repo bug candidates as "<num>\t<phase>" lines (phase: fix|triage), fix-pending-first.
_repo_bugs(){ python3 "$ISSUELIB" bugs "$1" 2>/dev/null; }
# per-repo OPEN bug-lane issues CARRYING agent-working — the lane's stale-claim candidates (#42),
# one bare number per line. The complement of _repo_bugs (which excludes agent-working): reap_lane
# walks these and frees the ones whose sess_bug session is dead. Overridable seam (tests stub it).
_repo_working_bugs(){ python3 "$ISSUELIB" working-bugs "$1" 2>/dev/null; }
# All repos' candidates as "<repo>#<num>" tokens, GLOBALLY fix-pending-first (#37): each repo's
# (num,phase) pairs are tagged with a phase sort-key (0=fix/pending, 1=triage/fresh) then stably
# sorted, so a pending fix in ANY repo drains before a fresh bug in ANY repo. Stable sort keeps
# same-phase candidates in their cross-repo input order. The repo is owner-qualified via _with_owner
# at token construction (#49): the claim key, session, worktree, _checkpoint_target lookup, and
# lane_phase grep all derive from this token, while drive_bug/spawn_bug derive their slug from
# _with_owner — so a BARE repo (multi col-2 `widget`, or single HARNESS_REPO=widget) with
# HARNESS_OWNER set yields ONE shared owner-qualified slug instead of a token/session mismatch.
# _repo_bugs still queries with the RAW repo (the GitHub seam); only the emitted token is qualified.
_bug_numbers(){ local repo qrepo num phase
  for repo in $(_bug_repos); do
    [[ -n "$repo" ]] || continue
    qrepo="$(_with_owner "$repo")"
    _repo_bugs "$repo" | while IFS=$'\t' read -r num phase; do
      [[ -n "$num" ]] || continue
      printf '%s\t%s#%s\n' "$([[ "$phase" == fix ]] && echo 0 || echo 1)" "$qrepo" "$num"
    done
  done | sort -t$'\t' -s -k1,1n | cut -f2-
}
# Claim-file stem for a bug ref. A qualified "<repo>#<num>" sanitises to "bug-<repo>-<num>"
# (/ -> _, # -> -) so two repos' same-numbered bugs are DISTINCT claims; a bare "<num>"
# (single-topology back-compat) -> "bug-<num>".
_bug_claim_key(){ case "$1" in
  *#*) printf 'bug-%s' "$(printf '%s' "$1" | tr '/#' '_-')";;
  *)   printf 'bug-%s' "$1";;
  esac; }
# Repo + number from a bug ref. Qualified token splits directly; a bare number resolves its repo
# via bug_repo (single-topology only — there are no cross-repo collisions there).
_bug_ref_repo(){ case "$1" in *#*) echo "${1%#*}";; *) bug_repo "$1";; esac; }
_bug_ref_num(){  case "$1" in *#*) echo "${1##*#}";; *) echo "$1";; esac; }
is_bug_claimed(){ is_claimed "$(_bug_claim_key "$1")"; }
release_bug_claim(){ release_claim "$(_bug_claim_key "$1")"; }
claimable_bugs(){ local tok; for tok in $(_bug_numbers); do is_bug_claimed "$tok" && continue; echo "$tok"; done; }
# The claim file records "<wid> <pid> <token>": the third field carries the FULL repo-qualified
# ref (#44) so lane_bug / _checkpoint_target recover the real owner/repo without reversing the
# lossy sanitised claim key (owner_repo can't be split back into owner/repo unambiguously).
claim_next_bug(){ local wid="$1" tok lockfd; exec {lockfd}>"$POOL_LOCK"; flock "$lockfd"
  tok="$(claimable_bugs | head -n1)"; [[ -n "$tok" ]] && printf '%s %s %s\n' "$wid" "$$" "$tok" > "$CLAIMS_DIR/$(_bug_claim_key "$tok").claim"
  flock -u "$lockfd"; exec {lockfd}>&-; echo "$tok"; }
# claim_bug <wid> <ref> — claim ONE named bug, the pool's entry to the lane's claims (#214). Same
# claim file and POOL_LOCK as claim_next_bug, so whichever lane gets there first holds it and the
# other is refused: a bug is never offered to both. rc 1 when it is already claimed.
claim_bug(){ local wid="$1" tok="$2" lockfd rc=1; exec {lockfd}>"$POOL_LOCK"; flock "$lockfd"
  if ! is_bug_claimed "$tok"; then
    printf '%s %s %s\n' "$wid" "$$" "$tok" > "$CLAIMS_DIR/$(_bug_claim_key "$tok").claim"; rc=0
  fi
  flock -u "$lockfd"; exec {lockfd}>&-; return "$rc"; }
# pool_bug_claims [unit] — `<claim-file>\t<ref>` for every bug claim a POOL worker holds (#214), live
# or stale; with <unit>, only that unit's. A pool claim's worker id is `pool-<unit>`.
pool_bug_claims(){ local f wid tok; shopt -s nullglob
  for f in "$CLAIMS_DIR"/bug-*.claim; do
    read -r wid _ tok < "$f" 2>/dev/null || continue
    [[ "$wid" == pool-* && -n "$tok" ]] || continue
    [[ -z "${1:-}" || "$wid" == "pool-$1" ]] && printf '%s\t%s\n' "$f" "$tok"
  done; shopt -u nullglob; }
# priority_free_slots — idle priority-lane slots: 1 while the lane is up and holds no bug, else 0.
# A dead lane has no free slot, so the pool picks its bugs up instead of leaving them to wait.
priority_free_slots(){ local p="$RUN_DIR/priority.pid"
  [[ -f "$p" ]] && kill -0 "$(cat "$p" 2>/dev/null)" 2>/dev/null || { echo 0; return; }
  [[ -n "$(lane_bug)" ]] && echo 0 || echo 1; }

# lane_bug — the repo-qualified bug ref the cap-1 priority lane currently holds (its live
# bug-*.claim), or empty when watching. Returns the claim's stored token (third field) so it is
# the SAME "<owner>/<repo>#N" ref the lane claimed (#44) — never the lossy sanitised claim key,
# which can't be split back into owner/repo. Falls back to the stripped key for a legacy claim
# with no stored token (single-topology bare bug-<n>.claim). Mirrors worker_unit for the pool;
# status.sh #35 renders it. Skips stale (dead-pid) claims via is_bug_claimed so a crashed lane
# never shows a phantom bug.
lane_bug(){ local f tok n; shopt -s nullglob
  for f in "$CLAIMS_DIR"/bug-*.claim; do
    [[ "$(awk '{print $1; exit}' "$f" 2>/dev/null)" == pool-* ]] && continue   # a pool worker's (#214)
    tok="$(awk '{print $3; exit}' "$f" 2>/dev/null)"
    n="$(basename "$f" .claim)"; n="${n#bug-}"
    [[ -n "$tok" ]] || tok="$n"
    is_bug_claimed "$tok" && { echo "$tok"; shopt -u nullglob; return; }
  done; shopt -u nullglob; }
# lane_phase <ref> — the phase (triage|fix) of the bug's live session, parsed from its
# hz-bug-<repo-sanitised>-<n>-<phase> tmux session (sess_bug). <ref> is the repo-qualified token
# from lane_bug; it is sanitised the SAME way as the session/claim key (/ -> _, # -> -) so a
# colliding issue number in another repo can't match the wrong session (#44). Empty when no
# session is live. A bare ref (legacy single-topology) sanitises to itself.
lane_phase(){ local key s; key="$(printf '%s' "$1" | tr '/#' '_-')"
  s="$(tmux ls -F '#S' 2>/dev/null | grep -m1 -E "^${HARNESS_SESS_PREFIX}-bug-${key}-" || true)"
  [[ -n "$s" ]] && echo "${s##*-}"; }

# pool_live — is anything resident to claim freshly-injected work? True if any pool worker pid
# (worker-1..POOL.pid) is alive OR the priority lane (priority.pid) is alive. A cleanly-retired
# pool (workers exit 0 on all_complete) leaves only dead-pid files; with no live lane either,
# injected `ready-for-agent` issues sit unclaimed until `harness start --recover`. inject.sh
# uses this to print honest restart guidance instead of the misleading "no restart" (#22).
pool_live(){ local i p
  for ((i=1; i<=POOL; i++)); do
    p="$RUN_DIR/worker-$i.pid"
    [[ -f "$p" ]] && kill -0 "$(cat "$p" 2>/dev/null)" 2>/dev/null && return 0
  done
  p="$RUN_DIR/priority.pid"
  [[ -f "$p" ]] && kill -0 "$(cat "$p" 2>/dev/null)" 2>/dev/null && return 0
  return 1; }

# --- bug-lane phase + repo resolution (#27) ----------------------------------
# Labels encode the phase in place (no child issues): an untriaged `bug` triages, a
# `bug-triaged` fixes. _bug_labels/_bug_state are the overridable GitHub seams so the
# lane logic is testable without touching GitHub; SLUG is set by the caller (drive_bug).
_bug_labels(){ gh issue view "$1" -R "$SLUG" --json labels -q '[.labels[].name]|join(",")' 2>/dev/null; }
_bug_state(){  gh issue view "$1" -R "$SLUG" --json state  -q '.state' 2>/dev/null; }
# fix if already bug-triaged (wins even when `bug` lingers), else triage. The result picks
# the prompt template AND the session phase suffix, so the two phases never share a session.
bug_phase(){ case ",$(_bug_labels "$1")," in *",$HARNESS_LABEL_BUG_TRIAGED,"*) echo fix;; *) echo triage;; esac; }
# Which repo holds bug #n + where its session runs. Single: the one repo, in PROJECT_ROOT.
# Back-compat ONLY for a BARE number (#37): the lane now carries the repo in the claim token
# (_bug_ref_repo splits it directly), so this rescan no longer drives multi-topology routing —
# where colliding numbers made "first repo that lists #n" pick the wrong repo. Kept as a fallback
# for a bare ref; matches the number field of _repo_bugs' "<num>\t<phase>" output.
bug_repo(){ local n="$1" repo
  if [[ "$HARNESS_TOPOLOGY" == single ]]; then echo "$HARNESS_REPO"; return; fi
  for repo in $(_bug_repos); do
    [[ -n "$repo" ]] || continue
    _repo_bugs "$repo" | cut -f1 | grep -qx "$n" && { echo "$repo"; return; }
  done; }
bug_checkout(){ if [[ "$HARNESS_TOPOLOGY" == single ]]; then echo "$PROJECT_ROOT"
  else echo "$CHECKOUTS_DIR/${1##*/}"; fi; }
# bug_worktree <slug> <issue> — the fix-phase worktree path for a bug. Repo-qualified (#37): issue
# numbers are per-repo, so two repos' same-numbered bugs need DISTINCT paths or the second fix
# collides. spawn_bug (create), drive_bug (reap), and sweep_orphan_bug_worktrees (recover) all
# derive the path here so they can never disagree.
bug_worktree(){ echo "$WORKTREES_DIR/bug-$(printf '%s' "$1" | tr '/' '_')-i$2"; }
# triage_worktree <slug> <issue> — the bug-TRIAGE phase worktree path (#5/#109). Triage used to run
# in the shared $CHECKOUT, where a concurrent spawn_orch `render > $CHECKOUT/.harness-task.md` (brief
# clobber) + `git reset --hard origin/<base>` (working-tree yank) could corrupt the in-flight triage.
# Give triage its OWN worktree, exactly like spawn_impl / the fix phase. A DISTINCT `triage-` prefix
# (NOT `bug-`) keeps it off the fix worktree path AND lets sweep_orphan_bug_worktrees tell the two
# apart; repo-qualified (#37) so two repos' same-numbered triages never collide. Its throwaway branch
# is agent/bug-triage-<n> (distinct from the fix phase's issue/<n>). spawn_bug (create), drive_bug +
# reap_lane (reap), and sweep_orphan_bug_worktrees (recover) all derive the path here so they agree.
triage_worktree(){ echo "$WORKTREES_DIR/triage-$(printf '%s' "$1" | tr '/' '_')-i$2"; }
# orch_worktree <slug> <prd> — the DECOMPOSE/REVIEW worktree for one PRD. Multi-PRD makes
# spawn_orch race ITSELF in the shared $CHECKOUT — a concurrent `render > .harness-task.md`
# (prompt clobber) plus `git reset --hard origin/<base>` (working-tree yank) corrupts the other
# session, exactly the failure #5/#109 fixed for bug-triage. Same remedy, same shape. The `orch-`
# prefix sits at the WORKTREES_DIR root (like `triage-`), so reap_team / finalize_unit's
# "$WORKTREES_DIR/$UNIT"-i* glob can never catch it or mis-parse it via ${wd##*-i}.
orch_worktree(){ echo "$WORKTREES_DIR/orch-$(printf '%s' "$1" | tr '/' '_')-p$2"; }
# remove_session_worktrees <checkout> <wd> — the worktrees a session made for itself while it ran in
# <wd>: Claude Code's agent isolation nests them under <wd>/.claude/worktrees/, and agents check out
# base refs under their scratchpad, /tmp/claude-<uid>/<wd with every non-alnum as '-'>/…. Each is a
# full checkout that nothing else ever removes (72 of them, 12.9 GB, piled up on one fleet host).
# Removes every worktree of <checkout> in either place, plus its throwaway worktree-* branch.
# Then the scratch itself (#180): the session's Claude Code scratch dir, and the /tmp/hz-*-<n> base
# checkouts the lane prompts make for issue <n> (resume.md). /tmp is a tmpfs on fleet hosts, so what
# is left there is RAM — 17 finished sessions' dirs plus a 2.4 GB go-build cache on one host.
# HARNESS_TMP_ROOT is the test seam for /tmp.
remove_session_worktrees(){ local checkout="$1" wd="$2" san p b n tmp="${HARNESS_TMP_ROOT:-/tmp}"
  [[ -n "$wd" ]] || return 0
  san="$(printf '%s' "$wd" | sed 's/[^A-Za-z0-9]/-/g')"
  n=""; [[ "$wd" =~ -i([0-9]+)$ ]] && n="${BASH_REMATCH[1]}"
  while IFS=$'\t' read -r p b; do
    case "$p" in "$wd"/*|*/claude-*/"$san"/*) ;; "$tmp"/hz-*-"$n") [[ -n "$n" ]] || continue ;; *) continue ;; esac
    git -C "$checkout" worktree remove --force --force "$p" 2>/dev/null || rm -rf "$p"
    [[ "$b" == worktree-* ]] && git -C "$checkout" branch -D "$b" >/dev/null 2>&1
  done < <(git -C "$checkout" worktree list --porcelain 2>/dev/null | awk '
    /^worktree /{p=substr($0,10)} /^branch /{b=substr($0,19)}
    /^$/{if(p!="")print p"\t"b; p=b=""} END{if(p!="")print p"\t"b}')
  rm -rf "$tmp/claude-$(id -u)/$san"
  return 0; }
# remove_worktree <checkout> <wd> [branch] — best-effort teardown of one worktree (+ optional local
# branch), then prune the registration. Tolerates a missing worktree/branch (idempotent). Falls
# back to rm -rf if `git worktree remove` can't (e.g. dir already gone). Shared by spawn_bug's
# defensive pre-add reap (branch omitted — `worktree add -B` resets it anyway), drive_bug's
# post-fix reap, and the recovery sweep, so all three tear down identically (#34).
remove_worktree(){ local checkout="$1" wd="$2" branch="${3:-}"
  remove_session_worktrees "$checkout" "$wd"
  git -C "$checkout" worktree remove --force "$wd" 2>/dev/null || rm -rf "$wd"
  [[ -n "$branch" ]] && git -C "$checkout" branch -D "$branch" 2>/dev/null || true
  git -C "$checkout" worktree prune 2>/dev/null || true; }
# sweep_orphan_bug_worktrees — crash/new-machine recovery (#34): the priority lane reaps its fix
# worktree in drive_bug, but only if the lane process survives. An unclean host exit kills the lane
# mid-fix, orphaning a bug-<slug>-i<n> worktree on disk; the next spawn_bug fix would then collide
# on `worktree add` (rc 128) and wedge the lane forever. So on recovery, remove every fix worktree
# whose fix session is dead, plus its local issue/<n> branch. Each worktree's owning checkout is
# derived from the worktree itself (--git-common-dir) so this works across single/multi topology.
# Skips a worktree whose session is still LIVE — safe to run while the fleet is up. Walks BOTH the
# fix worktrees (bug-<slug>-i<n>, branch issue/<n>) AND the triage worktrees (triage-<slug>-i<n>,
# branch agent/bug-triage-<n>, #109) — a crashed triage leaks a worktree just like a crashed fix.
sweep_orphan_bug_worktrees(){ shopt -s nullglob; local wd n san base gcd co phase branch
  for wd in "$WORKTREES_DIR"/bug-*-i* "$WORKTREES_DIR"/triage-*-i*; do
    [[ -d "$wd" ]] || continue
    n="${wd##*-i}"; base="${wd##*/}"
    # Recover the sanitised slug + phase from the worktree dir so the session name matches the
    # repo-qualified sess_bug (#44). Passing the already-sanitised slug back through sess_bug is
    # idempotent (no '/' left to translate). The dir prefix encodes the phase + the branch to drop.
    if [[ "$base" == triage-* ]]; then san="${base#triage-}"; phase=triage; branch="agent/bug-triage-$n"
    else san="${base#bug-}"; phase=fix; branch="issue/$n"; fi
    san="${san%-i*}"
    session_live "$(sess_bug "$san" "$n" "$phase")" && continue
    gcd="$(git -C "$wd" rev-parse --git-common-dir 2>/dev/null)" || gcd=""
    co=""
    if [[ -n "$gcd" ]]; then
      [[ "$gcd" != /* ]] && gcd="$wd/$gcd"            # relative result → resolve against the worktree
      co="$(cd "$(dirname "$gcd")" 2>/dev/null && pwd)"
    fi
    if [[ -n "$co" ]]; then remove_worktree "$co" "$wd" "$branch"; else rm -rf "$wd"; fi
    echo "  removed orphan bug worktree $(basename "$wd") (#$n — no live $phase session)"
  done
  shopt -u nullglob; }

# sweep_orphan_orch_worktrees — crash/new-machine recovery for the per-PRD DECOMPOSE/REVIEW
# worktrees, the direct analogue of sweep_orphan_bug_worktrees. An engine killed mid-orch leaves
# orch-<slug>-p<n> on disk with no session; without this the next `worktree add -B agent/orch-<n>`
# fails (rc 128, branch already used by a worktree) and that PRD can never orchestrate again.
sweep_orphan_orch_worktrees(){ shopt -s nullglob; local wd prd u san co
  for u in $(all_units); do
    san="$(printf '%s' "$(unit_slug "$u")" | tr '/' '_')"
    co="$(unit_checkout "$u")"
    for wd in "$WORKTREES_DIR/orch-$san"-p*; do
      prd="${wd##*-p}"
      session_live "$(sess_orch "$u" "$prd")" && continue
      log "recover: sweeping orphaned orch worktree for PRD #$prd ($u)"
      if [[ -n "$co" ]]; then remove_worktree "$co" "$wd" "agent/orch-$prd"; else rm -rf "$wd"; fi
    done
  done
  shopt -u nullglob; }

# recover_orphan_working — crash/new-machine recovery sweep (#43), sibling of sweep_orphan_bug_worktrees.
# GitHub is the source of truth, but a crashed/migrated host leaves issues stuck under
# HARNESS_LABEL_WORKING whose owning tmux session died with the box — invisible to reap_team, which
# only walks LOCAL worktrees. Walk every unit's repo and strip the label from each OPEN working issue
# with NO live session, so dispatch re-claims it. An issue is in flight — and so NEVER swept — when its
# IMPL session (sess_impl) OR its bug-lane session (bug_session_live, the SAME predicate reap_lane #42
# uses) is live. That bug-lane check is what makes --recover safe to run while the fleet is up for the
# priority lane too: without it a live bug's label was stripped, the lane re-claimed it, and spawn_bug
# ripped out the worktree the still-live agent was editing (double-dispatch / corruption). Dead-session
# bug orphans are still freed here; their worktrees are reaped separately by sweep_orphan_bug_worktrees.
# Per-issue progress goes to stderr; the count of issues freed is echoed to stdout.
recover_orphan_working(){ local u slug n freed=0
  for u in $(all_units); do
    slug="$(unit_slug "$u")"
    gh repo view "$slug" >/dev/null 2>&1 || continue   # repo not seeded yet — nothing to free
    while read -r n; do
      [[ -z "$n" ]] && continue
      session_live "$(sess_impl "$u" "$n")" && continue   # live impl session — never sweep
      bug_session_live "$slug" "$n" && continue           # live bug-lane session — never sweep (#43)
      if gh issue edit "$n" -R "$slug" --remove-label "$HARNESS_LABEL_WORKING" >/dev/null 2>&1; then
        echo "  freed $slug#$n (orphaned $HARNESS_LABEL_WORKING — no live session)" >&2
        freed=$((freed+1))
      fi
    done < <(gh issue list -R "$slug" --state open --label "$HARNESS_LABEL_WORKING" \
               --json number,labels \
               -q '.[] | select(([.labels[].name] | index("'"$HARNESS_LABEL_BLOCKED"'")) | not) | .number' \
               2>/dev/null)
  done
  echo "$freed"; }

# --- #179: agent-working locks that nothing will ever clear --------------------------------------
# A reap (reap_team / reap_lane) strips agent-working once its session is gone. If GitHub is
# unreachable at that moment the edit fails, and the reap never comes round again: the worktree it
# keyed off is already removed. The issue then looks claimed forever — no session works on it and
# dispatch skips it. Two repairs, both per poll: a failed unlock is QUEUED and retried until GitHub
# takes it, and the pool sweeps its unit's repo for any lock no live session owns.

# --- #366: the /harness-one lease ---
# `harness one start` works an issue in the INVOKING session — there is no tmux session for the
# reapers to see. Its lease stands in for one: while it is fresh (HARNESS_ONE_LEASE_MIN since the last
# `harness one start|phase` touched it) reap_team keeps off the issue's worktree and the lock sweeps
# keep off its agent-working. A lease nothing refreshes is a session that died; the pool then reaps
# the issue like any dead lane. `harness one release` drops it.
one_lease_file(){ echo "$RUN_DIR/one/$1-i$2.lease"; }   # <unit> <issue>
one_lease_live(){ local f m; f="$(one_lease_file "$1" "$2")"
  m="$(stat -c %Y "$f" 2>/dev/null)" || return 1
  (( $(date +%s) - m < HARNESS_ONE_LEASE_MIN * 60 )); }

# issue_session_live <slug> <n> — does ANY of this fleet's sessions work issue #n of <slug>: an impl
# or orch session of a unit on that repo, or either bug-lane phase (`<prefix>-bug-<slug>-<n>-*`)?
issue_session_live(){ local slug="$1" n="$2" u
  bug_session_live "$slug" "$n" && return 0
  for u in $(all_units); do
    [[ "$(unit_slug "$u")" == "$slug" ]] || continue
    session_live "$(sess_impl "$u" "$n")" && return 0
    one_lease_live "$u" "$n" && return 0   # #366: worked in a /harness-one session
    session_live "$(sess_orch "$u" "$n")" && return 0
  done
  return 1; }
# issue_worktree_present <slug> <n> — a worktree for #n still exists. Its session may be launching
# (spawn creates the worktree, stamps the label, runs the hook, THEN starts the session) or dead —
# either way the reaper that owns the worktree owns the label too, so the sweep keeps off it.
issue_worktree_present(){ local slug="$1" n="$2" u
  [[ -d "$(bug_worktree "$slug" "$n")" || -d "$(triage_worktree "$slug" "$n")" ]] && return 0
  for u in $(all_units); do
    [[ "$(unit_slug "$u")" == "$slug" && -d "$WORKTREES_DIR/$u-i$n" ]] && return 0
  done
  return 1; }

# unlock_issue <slug> <n> — strip agent-working from #n. On a gh failure, queue it in
# $RUN_DIR/pending-unlock for retry_pending_unlocks. Returns gh's verdict.
unlock_issue(){ local slug="$1" n="$2" f="$RUN_DIR/pending-unlock" lockfd
  gh issue edit "$n" -R "$slug" --remove-label "$HARNESS_LABEL_WORKING" >/dev/null 2>&1 && return 0
  exec {lockfd}>"$f.lock"; flock "$lockfd"
  grep -qxF "$slug"$'\t'"$n" "$f" 2>/dev/null || printf '%s\t%s\n' "$slug" "$n" >> "$f"
  flock -u "$lockfd"; exec {lockfd}>&-
  log "could not clear $HARNESS_LABEL_WORKING on $slug#$n (gh failed) — queued, retrying every poll (#179)"
  return 1; }

# parked_file — #271: the park records issuelib.py's `_parked_file` reads (same default, same override).
parked_file(){ printf '%s' "${HARNESS_PARKED_FILE:-$STATE_DIR/run/parked}"; }

# park_issue <slug> <n> — #271: record that the engine freed <slug>#<n> while it carried agent-blocked,
# so an autonomous fleet holds it instead of relaunching a lane into the same blocker. The updatedAt is
# read AFTER the engine's own unlock: that label edit bumps it, and must not count as the change that
# re-enables the issue. Unreadable, it falls back to now — no later edit can predate it either.
park_issue(){ local slug="$1" n="$2" f upd lockfd; f="$(parked_file)"
  upd="$(gh issue view "$n" -R "$slug" --json updatedAt -q .updatedAt 2>/dev/null)"
  [[ "$upd" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || upd="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$f")"
  exec {lockfd}>"$f.lock"; flock "$lockfd"
  { awk -F'\t' -v s="$slug" -v n="$n" '!($1 == s && $2 == n)' "$f" 2>/dev/null
    printf '%s\t%s\t%s\t%s\n' "$slug" "$n" "$(date +%s)" "$upd"; } > "$f.tmp" && mv -f "$f.tmp" "$f"
  flock -u "$lockfd"; exec {lockfd}>&-
  log "parked $slug#$n — $HARNESS_LABEL_BLOCKED; held from dispatch until it changes (#271)"; }

# is_parked <slug> <n> — a park record exists for <slug>#<n>.
is_parked(){ awk -F'\t' -v s="$1" -v n="$2" '$1 == s && $2 == n { f = 1 } END { exit !f }' "$(parked_file)" 2>/dev/null; }

# retry_pending_unlocks — one pass over the queue: clear each lock GitHub now accepts, keep the rest.
# An entry whose issue has a live session again was re-claimed since, so its lock is real — dropped.
# Non-blocking on the queue lock: if another worker is mid-pass, this poll leaves it to them.
retry_pending_unlocks(){ local f="$RUN_DIR/pending-unlock" lockfd slug n keep=""
  [[ -s "$f" ]] || return 0
  exec {lockfd}>"$f.lock"; flock -n "$lockfd" || { exec {lockfd}>&-; return 0; }
  while IFS=$'\t' read -r slug n; do
    [[ -n "$slug" && -n "$n" ]] || continue
    issue_session_live "$slug" "$n" && continue
    if gh issue edit "$n" -R "$slug" --remove-label "$HARNESS_LABEL_WORKING" >/dev/null 2>&1; then
      log "cleared queued $HARNESS_LABEL_WORKING on $slug#$n — re-dispatchable (#179)"
      # #271: this late unlock bumped updatedAt past the park record — re-read it, or it un-parks.
      is_parked "$slug" "$n" && park_issue "$slug" "$n"
    else keep+="$slug"$'\t'"$n"$'\n'; fi
  done < "$f"
  printf '%s' "$keep" > "$f"
  flock -u "$lockfd"; exec {lockfd}>&-; }

# _working_locks <slug> — `<num>\t<updatedAt>` per open, unblocked agent-working issue. Overridable seam.
_working_locks(){ python3 "$ISSUELIB" working "$1" 2>/dev/null; }

# sweep_orphan_locks <unit> — free every lock in the unit's repo that no live session owns and that
# has stood for HARNESS_ORPHAN_LOCK_MIN minutes, with a comment saying why. The bug lane has had this
# since #42 (reap_lane); this is the impl/orch analog. Age is measured from updatedAt, a lower bound
# on when the label went on, so a lock is never freed early. A freed issue is marked for the same
# window: the snapshot may still show the label until the poller next refreshes, and a second
# unlock + comment would be noise.
sweep_orphan_locks(){ local slug n upd since now age grace mark
  slug="$(unit_slug "$1")"; grace=$(( HARNESS_ORPHAN_LOCK_MIN * 60 ))
  while IFS=$'\t' read -r n upd; do
    [[ -n "$n" ]] || continue
    issue_session_live "$slug" "$n" && continue       # in flight — never touch
    issue_worktree_present "$slug" "$n" && continue   # launching, or its reaper still owns it
    since="$(date -d "$upd" +%s 2>/dev/null)" || continue   # age unprovable — leave it
    now="$(date +%s)"; age=$(( now - since )); (( age >= grace )) || continue
    mark="$RUN_DIR/unlocked/$(printf '%s' "$slug" | tr '/' '_')-$n"
    [[ -f "$mark" ]] && (( now - $(stat -c %Y "$mark") < grace )) && continue
    mkdir -p "$RUN_DIR/unlocked"; touch "$mark"
    log "unlocking $slug#$n — $HARNESS_LABEL_WORKING with no live session for $(( age / 60 ))m (#179)"
    unlock_issue "$slug" "$n" || continue
    gh issue comment "$n" -R "$slug" --body "harness: cleared stale \`$HARNESS_LABEL_WORKING\` — no live session has owned this issue for over $HARNESS_ORPHAN_LOCK_MIN minutes. The pool will re-dispatch it." >/dev/null 2>&1 || true
  done < <(_working_locks "$slug"); }

# --priority-free (#214) lets dispatch hand an idle pool slot a bug; leaving it off keeps bugs on the lane.
dispatch_actions(){ local pfree=()
  [[ "$HARNESS_POOL_TAKES_BUGS" == 1 ]] && pfree=(--priority-free "$(priority_free_slots)")
  python3 "$ISSUELIB" dispatch "$1" "$2" --allow-orchestration "$3" --busy-prds "${4:-}" "${pfree[@]}"; }

# --- default-branch CI gate (#50) --------------------------------------------
# ci_status_default_branch <slug> — `<verdict>\t<workflow>\t<url>`, verdict ∈ pass|fail|unknown.
# THIS IS THE SEAM tests override (mirrors _repo_bugs / unit_complete); everything below reads the
# verdict through it, so no test needs a live gh or a real Actions run.
ci_status_default_branch(){ python3 "$ISSUELIB" ci-status "$1" 2>/dev/null; }

# ci_gate_ok <slug> — may the pool dispatch NEW work for <slug> right now? 0 = yes.
#
# Non-zero ONLY on a positively-red default branch, because a fleet that halts on uncertainty is
# worse than one that merges a bad commit: every other verdict (unknown / no Actions / gh outage /
# empty output from a HOLD exit) returns 0. HARNESS_CI_GATE=0 — the default since #245, because
# Harness projects run no GitHub CI — disables it outright.
#
# The remedy path is deliberately NOT gated: the priority bug lane claims through a red branch, so
# filing a `bug` issue is how a fleet digs itself out. Nothing here touches live sessions either —
# in-flight work drains normally, exactly like a pause.
ci_gate_ok(){ local slug="$1" verdict wf url
  [[ "$HARNESS_CI_GATE" == 0 ]] && return 0
  IFS=$'\t' read -r verdict wf url < <(ci_status_default_branch "$slug")
  [[ "${verdict:-unknown}" == fail ]] || return 0
  ci_gate_log "$slug" "$wf" "$url"; return 1; }

# hold_reason <stderr-text> — network | rate_limit | other, for a HOLD tick's `hold` event (#185).
hold_reason(){ local e; e="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  if grep -qE 'rate.?limit|http 403|403 forbidden|http 429|too many requests' <<<"$e"; then echo rate_limit
  elif grep -qE 'timeout|timed out|connection|could not resolve|network|tls|ssl|eof|50[0-4]|unavailable' <<<"$e"; then echo network
  else echo other; fi; }
# Deduped per (slug, run url) so a red branch logs once per NEW failure, not once per poll.
ci_gate_log(){ local key="$1:$3"
  [[ "${_CI_GATE_LOGGED:-}" == "$key" ]] && return 0
  _CI_GATE_LOGGED="$key"
  log "CI RED on $1's default branch (workflow '${2:-?}') — holding new dispatch (#50). ${3:-}"
  log "  live sessions keep draining. Remedy: file a \`$HARNESS_LABEL_BUG\` issue (the bug lane is not gated), or set HARNESS_CI_GATE=0 to override."; }

# --- tmux session naming + ralph helpers -------------------------------------
# sess_orch <unit> [prd] — the orchestration session for a unit, qualified by PRD number so several
# PRDs can orchestrate at once (DECOMPOSE #42 while REVIEW #41). The unit-level PLAN/PRD actions
# carry no PRD and use p0.
sess_orch(){ echo "$HARNESS_SESS_PREFIX-$1-p${2:-0}"; }
sess_impl(){ echo "$HARNESS_SESS_PREFIX-$1-i$2"; }
sess_inject(){ echo "$HARNESS_SESS_PREFIX-inject-$1"; }
# Priority bug-lane session: <slug> <issue> <phase>. The slug (sanitised / -> _) is embedded so
# the session name carries the REPO (#44): issue numbers are per-repo, so in `multi` two repos can
# each hold a bug #N — a bare-number session collided, and every deriver that re-parsed it
# (lane_phase, _checkpoint_target, sweep_orphan_bug_worktrees) lost the repo. The <phase> suffix
# keeps triage and fix on DISTINCT sessions (separate session-ids / fresh context) for the same
# issue (#27). The sanitised-slug-and-number segment matches the bug claim key (_bug_claim_key).
sess_bug(){ echo "$HARNESS_SESS_PREFIX-bug-$(printf '%s' "$1" | tr '/' '_')-$2-$3"; }
# The `$` alternative keeps matching the BARE legacy orch name, so an orch session already in
# flight when the engine upgrades is still counted and reaped instead of orphaned.
team_sessions(){ tmux ls -F '#S' 2>/dev/null | grep -E "^$HARNESS_SESS_PREFIX-$1(\$|-i|-p)" || true; }
count_team_sessions(){ team_sessions "$1" | grep -c . ; }
session_live(){ tmux has-session -t "$1" 2>/dev/null; }
# lock_holders <lockfile> — print one `PID<TAB>cmdline` line per process that currently holds the
# file open (any fd). Dependency-free (`fuser`/`lsof` are NOT guaranteed present on every host —
# this box has neither) — it scans /proc/*/fd symlinks for ones resolving to the lock's real path.
# Deduped by pid. The reliable way to answer "who holds start.lock / pool.lock?" — the question
# behind the fd-leak wedge (a killed worker's orphaned `sleep` keeps an inherited flock fd open).
lock_holders(){
  local lf="$1" rl fd tgt pid seen=" "
  rl="$(readlink -f "$lf" 2>/dev/null)" || return 0
  [[ -n "$rl" ]] || return 0
  for fd in /proc/[0-9]*/fd/*; do
    tgt="$(readlink "$fd" 2>/dev/null)" || continue
    [[ "$tgt" == "$rl" ]] || continue
    pid="${fd#/proc/}"; pid="${pid%%/*}"
    [[ "$seen" == *" $pid "* ]] && continue
    seen+="$pid "
    printf '%s\t%s\n' "$pid" "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  done
}
# proc_state_dir <pid> — echo a process's STATE_DIR from its environ (empty if gone/unreadable). Lets
# doctor tell whether a lock-holder belongs to THIS project vs a co-resident sibling fleet.
proc_state_dir(){ tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n 's/^STATE_DIR=//p' | head -1; }
# proc_engine_dir <pid> — the same for ENGINE_DIR: the release directory a process runs from (#279).
# install.sh's rel_prune never removes a release a live process's ENGINE_DIR points into.
proc_engine_dir(){ tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n 's/^ENGINE_DIR=//p' | head -1; }
# lock_free <lockfile> — true iff the lock can be acquired right now (nobody holds it). A non-blocking
# flock in a subshell; the fd closes on subshell exit so this never itself leaves a holder behind.
lock_free(){ ( flock -n 9 ) 9>"$1" 2>/dev/null; }
# tracked_worker_pid <pid> — true iff <pid> is one of THIS project's currently-recorded pool/lane
# pids (RUN_DIR/*.pid). doctor's --fix never kills a tracked, live worker (it may legitimately hold
# pool.lock for the duration of a claim); only untracked orphans are reapable.
tracked_worker_pid(){
  local want="$1" p
  shopt -s nullglob
  for p in "$RUN_DIR"/*.pid; do
    [[ "$(cat "$p" 2>/dev/null)" == "$want" ]] && { shopt -u nullglob; return 0; }
  done
  shopt -u nullglob; return 1
}
# gc_orphan_goals — remove $RUN_DIR/<sess>.goal files whose tmux session is no longer live. A goal
# file is written for EVERY launched session (launch_claude), but is only deleted when a reaper
# actively KILLS a still-live session (reap_done_sessions / finalize_unit / drive_bug). Ralph
# sessions self-exit on their completion promise BEFORE any reaper kills them, and inject sessions
# have no reaper at all — so their goal files leak (confirmed: a stale hz*-inject-<unit>.goal with
# no session). This per-poll sweep GCs every lane's orphaned goal files uniformly. A goal whose
# session is STILL live is left alone: it is an in-flight claim a reaper still owns.
gc_orphan_goals(){
  local f sess
  stats_sweep_ended   # #185: session_end for self-exited sessions (Ralph promise, inject) too
  shopt -s nullglob
  for f in "$RUN_DIR"/*.goal; do
    sess="$(basename "$f" .goal)"
    session_live "$sess" || rm -f "$f" "$RUN_DIR/$sess.wd" "$RUN_DIR/$sess.loop" "$RUN_DIR/$sess.loop.lock"
  done
  shopt -u nullglob
}
# reap_finished_inject <unit> — kill the unit's inject session once its Ralph loop has ended.
# inject sessions are excluded from team_sessions by design (no CAP slot, inject.sh:5), so NO
# goal-check reaper (reap_done_sessions / priority-worker) ever iterates them — a finished injector
# parks at the idle ❯ prompt forever. Authoritative done-signal: the ralph-loop stop-hook removes
# .claude/ralph-loop.local.md the instant the loop ends (promise, max-iter, OR error), leaving the
# session alive but the state file gone. So: live inject session + absent state file ⇒ finished ⇒
# reap. A still-looping session (file present) or a launching/legacy one (no .wd recorded) is left
# untouched. Scoped to THIS fleet+unit's sess_inject; can never touch a driven/team session.
reap_finished_inject(){ local unit="$1" sess wd
  sess="$(sess_inject "$unit")"
  session_live "$sess" || return 0
  wd="$(cat "$RUN_DIR/$sess.wd" 2>/dev/null)" || return 0
  [[ -n "$wd" ]] || return 0
  goal_loop_tick "$sess" "$(tmux capture-pane -p -t "$sess" 2>/dev/null)" || true   # #259: no watchdog tends it
  cli_done "$wd" || return 0   # loop still active → leave it
  log "reaped finished inject session $sess (ralph loop ended)"
  cli_kill "$sess" "$wd" || true
  rm -f "$RUN_DIR/$sess.goal" "$RUN_DIR/$sess.wd"
}
# --- #115: stalled-session watchdog ------------------------------------------
# A transient Anthropic API error (529 Overloaded / 5xx / 429 / "overloaded" / rate limit) aborts a
# driven turn ABNORMALLY: ralph-loop's Stop hook never fires, so the interactive `claude` TUI parks
# at its idle `❯` prompt and the `iteration` counter is frozen — yet `tmux has-session` stays true.
# Every reaper keys off liveness OR goal-satisfaction, so an alive-but-idle session matches NONE of
# them and pins a HARNESS_CAP / lane slot forever. The watchdog below is the missing per-poll path:
# it classifies that exact state and recovers it (nudge → kill after K polls) WITHOUT disturbing a
# busy or a healthy-between-turns session.
#
# Transient-API-error markers as they appear in the TUI pane (cli_transient_re). Matched only IN
# COMBINATION with the idle prompt + the absence of an active turn, so an in-scrollback string alone
# never trips it. Every pane regex is the CLI adapter's (scripts/cli/<cli>.sh, #188).
# session_stalled <pane-text> — true iff the captured pane is the #115 wedge: an idle interactive
# prompt (`❯`) with NO active turn ("(esc to interrupt)" absent ⇒ not mid-tool-use / not a busy
# spinner) AND a transient-API-error marker. A busy session (esc-to-interrupt present) and a healthy
# idle session (no error marker) both return false — the two no-false-positive guarantees.
#
# An active turn shows ONE OF TWO hints, and both must count. The ordinary spinner prints
# "(esc to interrupt)", but while a long-running shell command is in flight the TUI REPLACES it with
# "(ctrl+b ctrl+b (twice) to run in background)". Keying on the spinner alone declared a lane running
# a multi-minute build/test suite "not mid-turn"; an error marker anywhere in its own tool output —
# a 500 in a log tail, the literal words "API Error" — then satisfied the rest of session_stalled and
# the lane was nudged ×K and KILLED mid-work, over and over, never finishing the command it was on.
# Matched on the stable tail of the hint so a change to the key prefix does not reopen this. (#188: on
# a Harness worktree the custom status line hides "(esc to interrupt)" altogether, so cli_busy_re
# also keys on the spinner's own "… (<timer> ·" shape.)
session_active_turn(){ cli_pane_busy "$1"; }
session_stalled(){ local pane="$1"
  session_active_turn "$pane" && return 1                         # active turn → never stalled
  cli_pane_prompt "$pane" || return 1                             # no idle prompt (or a dialog) → not parked
  _cli_re_hits "$(cli_transient_re)" "$pane"; }                   # …and a transient-error marker
# --- #120: quota-parked watchdog ---------------------------------------------
# A plan usage-limit hit is NOT the #115 transient wedge and must not be treated as one. It parks a
# session in one of TWO shapes, neither of which any reaper or the #115 watchdog can see:
#   (menu) the interactive `claude` TUI raises a blocking choice — "1. Stop and wait for limit to
#          reset / 2. Add funds / 3. Switch to Team plan" — and BLOCKS ON A KEYPRESS. There is no
#          idle `❯` (the menu owns the pane) and no spinner, so session_stalled never matches. The
#          process stays alive, tmux has-session stays true, and the lane pins its CAP slot until a
#          human presses Enter. Observed: 4 lanes idle 12h AFTER the quota had already reset.
#   (idle) the turn aborts and the pane drops to `❯` with "You've hit your session limit · resets
#          <t>". This DOES look like #115 (the stall regex even matches `rate.?limit`), but killing
#          it is wrong: the work is not wedged, the account is out of quota. Kill-after-K would
#          destroy K live lanes' in-flight context while the quota is still exhausted.
# So quota is handled FIRST and separately, and is NEVER killed: menu → press Enter (option 1, the
# default-highlighted "wait for reset"); idle → nudge to resume, backed off to every Nth poll so an
# exhausted account is not re-probed every poll for the hours a weekly limit can last. Both clear
# the #115 stall counter, so a quota park can never escalate into a kill.
# Credit exhaustion ("You're out of usage credits. Run /usage-credits to keep using <model> or /model
# to switch models.") is the SAME class as a limit park and must be listed here: it too aborts the turn
# and drops the pane to idle ❯, but it matched none of the limit alternatives, so it fell through to
# the #115 stall path and the session was nudged ×K then KILLED — and every re-dispatch re-provisions
# a worktree and dies again instantly, burning the lane in a loop for as long as the account is dry.
# The menu and idle strings are cli_limit_menu_re / cli_limit_re.
# limit_reset <pane-text> — the "resets <when>" a limit message names, for the rate_limited event.
limit_reset(){ printf '%s' "$1" | grep -oE 'resets [^·│]*' | tail -1 | sed 's/^resets //; s/[[:space:]]*$//'; }
# session_limit_menu <pane-text> — true iff the pane is BLOCKED on the interactive limit menu.
session_limit_menu(){ _cli_re_hits "$(cli_limit_menu_re)" "$1"; }
# session_limit_idle <pane-text> — true iff a limit-aborted turn left the pane at the idle `❯`.
session_limit_idle(){ local pane="$1"
  session_active_turn "$pane" && return 1                         # active turn → not parked
  cli_pane_prompt "$pane" || return 1                             # no idle prompt (or a dialog) → not parked
  _cli_re_hits "$(cli_limit_re)" "$pane"; }
# _watchdog_limit_pick <sess> — answer the blocking menu with its default choice ("stop and wait for
# limit to reset"). A bare Enter, never a typed line: the pane is a menu, not a prompt.
_watchdog_limit_pick(){ tmux send-keys -t "$1" Enter 2>/dev/null || true; }
# _watchdog_limit_nudge <sess> — re-submit a continue once the quota is back. Same live-pane
# send-keys pattern as _watchdog_nudge (#108 guard honoured: a plain line, never `exec claude …`).
_watchdog_limit_nudge(){ local sess="$1"
  cli_send "$sess" "$(cat "$RUN_DIR/$sess.wd" 2>/dev/null)" "Please continue — the usage limit has reset; resume the in-flight task where you left off."; }
# _watchdog_nudge <sess> — re-submit a continue into a session this watchdog has classified STALLED,
# so the agent resumes its preserved in-flight context now the transient error has cleared. Uses the
# exact send-keys-into-a-live-pane pattern as pause.sh:82-83. It NEVER types a second `exec claude …`
# (honours the #108 live-session guard) — only a plain continue line — and is only ever reached from
# watchdog_session AFTER session_stalled is true, so a healthy/busy pane is never typed into.
_watchdog_nudge(){ local sess="$1"
  cli_send "$sess" "$(cat "$RUN_DIR/$sess.wd" 2>/dev/null)" "Please continue — the transient API error has cleared; resume the in-flight task."; }
# _watchdog_turn_interrupt <sess> <pane-text> — #207: interrupt a turn that queued input cannot reach
# (see turn.sh), log a turn_interrupted event, and forget the queued-nudge state so a LATER stuck
# turn is judged afresh. When the turn never reports `Interrupted`, the state is kept and the next
# poll tries again.
_watchdog_turn_interrupt(){ local sess="$1" pane="$2" secs
  secs="$(turn_secs "$pane")"
  log "watchdog: $sess has run one turn for ${secs}s with input queued behind it — Escape, then Enter to deliver it (#207)"
  turn_interrupt "$sess" || { log "watchdog: $sess did not report Interrupted after Escape — retrying next poll (#207)"; return 0; }
  stats_sess_event "$sess" turn_interrupted turn_s="$secs" queued_nudges="$(turn_queued_nudges "$pane")"
  rm -f "$RUN_DIR/$sess.turnq"; }
# --- #259: the Harness-driven goal loop ----------------------------------------
# A CLI whose own hook cannot hold the goal loop open (cli_loop = driven; copilot's agentStop gives up
# after 8 blocks, below HARNESS_IMPL_MAXITER) is looped here, once per poll, by whoever tends the
# session (watchdog_session, reap_finished_inject). A session idle at its prompt with its state file
# (write_state) present has ended a turn: the reply to its last prompt (cli_last_reply) goes through
# ralph-loop's contract — scripts/goal_loop.py, of which Codex's Stop hook runs a copy (#307) — which
# ends the loop on the promise or at max_iterations by removing the state file (cli_done), or counts
# the next iteration. The next
# prompt is that iteration's line plus the bootstrap, never the task text (#213). Each prompt is
# answered once: <sess>.loop keeps the id of the last one the loop has read, under a lock, since
# several workers may tend one pool session. A pane parked at a usage limit is the limit watchdog's:
# re-prompting it would only burn iterations. rc 0 = the tick acted (re-prompted or ended the loop).
GOAL_LOOP_PY="$ENGINE_DIR/scripts/goal_loop.py"
goal_loop_tick(){ local sess="$1" pane="$2" wd lockfd rc
  [[ "$(cli_loop)" == driven ]] || return 1
  wd="$(cat "$RUN_DIR/$sess.wd" 2>/dev/null)"; [[ -n "$wd" ]] || return 1
  cli_done "$wd" && return 1
  cli_pane_prompt "$pane" && ! cli_pane_busy "$pane" || return 1
  session_limit_idle "$pane" && return 1
  exec {lockfd}>"$RUN_DIR/$sess.loop.lock"; flock -n "$lockfd" || { exec {lockfd}>&-; return 1; }
  _goal_loop_step "$sess" "$wd"; rc=$?
  flock -u "$lockfd"; exec {lockfd}>&-; return "$rc"; }
_goal_loop_step(){ local sess="$1" wd="$2" uuid sid out pid reply
  uuid="$(sed -n 's/^session_id: //p' "$wd/.claude/ralph-loop.local.md" 2>/dev/null)"
  sid="$(cli_session_id "$wd" "$uuid")"; [[ -n "$sid" ]] || return 1
  out="$(cli_last_reply "$wd" "$sid")" || return 1
  pid="$(head -1 <<<"$out")"; reply="$(tail -n +2 <<<"$out")"
  [[ -n "$pid" && "$pid" != "$(cat "$RUN_DIR/$sess.loop" 2>/dev/null)" ]] || return 1
  echo "$pid" > "$RUN_DIR/$sess.loop"
  out="$(python3 -c 'import json, sys; print(json.dumps({"cwd": sys.argv[1], "last_assistant_message": sys.argv[2]}))' \
    "$wd" "$reply" | (cd "$wd" && python3 "$GOAL_LOOP_PY") 2>/dev/null)"
  if cli_done "$wd"; then log "goal loop: $sess ended its loop (promise or max iterations)"; return 0; fi
  [[ -n "$out" ]] || return 1
  out="$(python3 -c 'import json, sys; print(json.loads(sys.stdin.read())["reason"].splitlines()[0])' <<<"$out" 2>/dev/null)" || return 1
  log "goal loop: $sess ended a turn without its promise — ${out%% |*}"
  cli_send "$sess" "$wd" "$out $HARNESS_BOOTSTRAP_PROMPT"; }
# watchdog_session <sess> — examine ONE live session for the #115 wedge and recover it. State (the
# count of CONSECUTIVE stalled polls) lives in $RUN_DIR/<sess>.stall and is cleared the instant the
# session is no longer stalled (recovered/busy/dead) — so a session that resumes after a nudge starts
# any LATER stall from zero. On each stalled poll, nudge; once the count reaches HARNESS_STALL_RETRIES
# the session is killed so the existing reap → re-dispatch path (reap_team / reap_lane) frees the slot
# and the next poll re-claims the issue. A non-live session is a no-op (its counter is GC'd).
watchdog_session(){ local sess="$1" stallf="$RUN_DIR/$1.stall" limitf="$RUN_DIR/$1.limit" pane n
  session_live "$sess" || { rm -f "$stallf" "$limitf" "$RUN_DIR/$sess.limitcp" "$RUN_DIR/$sess.turnq" "$RUN_DIR/$sess.loop" "$RUN_DIR/$sess.loop.lock"; return 0; }
  pane="$(tmux capture-pane -p -t "$sess" 2>/dev/null)" || { rm -f "$stallf" "$limitf"; return 0; }
  # #120 quota park — checked FIRST and never killed; see session_limit_menu/_idle above.
  if session_limit_menu "$pane"; then
    rm -f "$stallf"
    limit_checkpoint_once "$sess" "$pane"   # #194: frozen — it cannot /handoff, so checkpoint it mechanically
    log "watchdog: $sess blocked on the usage-limit menu — answering 'wait for reset' (#120)"
    stats_sess_event "$sess" rate_limited reset="$(limit_reset "$pane")"
    _watchdog_limit_pick "$sess"; return 0
  fi
  if session_limit_idle "$pane"; then
    rm -f "$stallf"
    limit_checkpoint_once "$sess" "$pane"
    n=$(( $(cat "$limitf" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$limitf"
    if (( n == 1 || n % HARNESS_LIMIT_NUDGE_EVERY == 0 )); then
      log "watchdog: $sess parked at its idle prompt by the usage limit (poll $n) — nudging to resume (#120)"
      (( n == 1 )) && stats_sess_event "$sess" rate_limited reset="$(limit_reset "$pane")"
      stats_sess_event "$sess" nudge reason=rate_limit
      _watchdog_limit_nudge "$sess"
    fi
    return 0
  fi
  rm -f "$limitf" "$RUN_DIR/$sess.limitcp"
  # #207 one endless turn with nudges queued behind it — interrupt so the queued text is delivered.
  if turn_should_interrupt "$pane" "$RUN_DIR/$sess.turnq"; then
    rm -f "$stallf"; _watchdog_turn_interrupt "$sess" "$pane"; return 0
  fi
  # #259: a driven goal loop's fresh reply comes first. The turn that answered a nudge ends with the
  # error line still on screen, which session_stalled would read as the wedge again.
  if goal_loop_tick "$sess" "$pane"; then rm -f "$stallf"; return 0; fi
  if ! session_stalled "$pane"; then rm -f "$stallf"; return 0; fi
  n=$(( $(cat "$stallf" 2>/dev/null || echo 0) + 1 ))
  if (( n >= HARNESS_STALL_RETRIES )); then
    log "watchdog: $sess wedged at its idle prompt after a transient API error for $n polls — killing for reap → re-dispatch (#115)"
    stats_sess_event "$sess" watchdog_kill reason=transient_api_error
    cli_kill "$sess" "$(cat "$RUN_DIR/$sess.wd" 2>/dev/null)" || true
    rm -f "$stallf"
  else
    echo "$n" > "$stallf"
    log "watchdog: $sess wedged at its idle prompt after a transient API error (poll $n/$HARNESS_STALL_RETRIES) — nudging to resume (#115)"
    stats_sess_event "$sess" nudge reason=transient_api_error
    _watchdog_nudge "$sess"
  fi; }
# watchdog_team — run the watchdog over every live session of the CURRENT unit ($UNIT). The pool's
# per-poll hook (drive_unit), the cap-N analog of the lane's in-loop watchdog_session call.
watchdog_team(){ local s
  while read -r s; do [[ -z "$s" ]] && continue; watchdog_session "$s"; done < <(team_sessions "$UNIT"); }

# bug_session_live <slug> <n> — is EITHER phase's session for bug #n in <slug> live? The SINGLE
# liveness predicate the lane's per-poll reap (#42, reap_lane) and start --recover's bug-aware skip
# (#43) both use, so the two reconciliation paths can never disagree about whether a bug is in
# flight. The slug is REQUIRED: sess_bug embeds the repo (#44), so the session name can't be rebuilt
# from the issue number alone — both callers already hold the slug and pass it. A bug whose session
# is live is NEVER swept — neither path strips its agent-working nor reaps its worktree.
bug_session_live(){ session_live "$(sess_bug "$1" "$2" triage)" || session_live "$(sess_bug "$1" "$2" fix)"; }
# review_session_live <unit> — true when ANY live orch session for the unit is a REVIEW. Goals are
# PRD-qualified now (`REVIEW:41`), and there can be several orch sessions at once, so this scans
# them all rather than reading a single well-known session name.
review_session_live(){ local s g
  while read -r s; do
    [[ -z "$s" ]] && continue
    g="$(cat "$RUN_DIR/$s.goal" 2>/dev/null)"
    [[ "${g%%:*}" == REVIEW ]] && return 0
  done < <(team_sessions "$1")
  return 1; }
# fleet_session_re / is_fleet_session — the ERE matching THIS fleet's tmux session names. It is
# deliberately PREFIX-BROAD: it claims ANY non-empty session under `<prefix>-`, NOT just the named
# session forms. Why broad and not a per-grammar match (#90): unit ids come from targets.tsv column 1
# and are NOT validated dash-free, so a unit like `web-api` yields the orch session `hz-web-api`
# (sess_orch). A grammar that required the orch unit to be a single dash-free segment (`[^-]+`)
# silently FAILED to match such an orch session — so `harness stop`/`status` LEAKED the live `claude`
# orchestration session. ERE has no negative lookahead, so we cannot express "anything except an impl
# suffix"; the only sound rule is "every session under our prefix is ours". The per-fleet
# HARNESS_SESS_PREFIX IS the ownership boundary, and prefix COLLISION between fleets is a separate
# concern guarded at `harness start` by prefixes_collide (below). The trailing dash is load-bearing
# for sibling isolation: `^hz-` requires a literal `-` as the 4th char, so `hzli-main`/`boto-x` are
# NOT in hz's space and hz/hzli/boto coexist untouched.
fleet_session_re(){ printf '^%s-.+$' "$HARNESS_SESS_PREFIX"; }
is_fleet_session(){ local re; re="$(fleet_session_re)"; [[ "$1" =~ $re ]]; }

# derive_prefix [dir] — the DEFAULT tmux session prefix for a project: its directory basename,
# lowercased and reduced to [a-z0-9_], truncated to 10 chars. Dashes are stripped because a dash is
# the session-name grammar separator (sess_orch/sess_impl) and prefixes_collide reads it as such;
# dots and colons are illegal in tmux session names. When the name sanitises to EMPTY (a non-ASCII or
# punctuation-only directory) fall back to `hz` + 4 hex of the path digest, so the result is always a
# non-empty, tmux-safe segment that is deterministic per path and distinct between paths.
#
# `harness init` offers this as the prefix default so two projects on one host do not both land on
# lib.sh's `hz` and cross-kill each other's sessions via stop.sh's ^<prefix>- sweep. lib.sh's own
# HARNESS_SESS_PREFIX default (line 44) deliberately STAYS `hz`: projects initialised before this
# change have no prefix line in their config and must resolve exactly as they always did.
derive_prefix(){
  local dir="${1:-$PROJECT_ROOT}" p
  p="$(basename "$dir" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_' | cut -c1-10)"
  [[ -n "$p" ]] || p="hz$(printf '%s' "$dir" | python3 -c \
    'import hashlib,sys; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest()[:4])')"
  printf '%s\n' "$p"
}

# --- PRD-B slice 4: prefix-collision guard (#73) -----------------------------
# prefixes_collide <a> <b> — do two session prefixes' tmux session spaces overlap? They collide when
# they are EQUAL, or one is a dash-prefix of the other (`a-…` swallows every `b-…` session iff b
# starts with `a-`, and vice-versa) — exactly the case where one fleet's stop/status sweep would
# cross-kill the other. The trailing dash is what spares `hz` vs `hzli` (`hzli` does not start with
# `hz-`), so a prefix family like hz/hzli/boto is NOT flagged.
prefixes_collide(){ local a="$1" b="$2"
  [[ "$a" == "$b" ]] && return 0
  [[ "$b" == "$a-"* ]] && return 0
  [[ "$a" == "$b-"* ]] && return 0
  return 1; }

# tmux_sessions_with_paths — every live tmux session as `<name>\t<session_path>`, empty (rc 0) when
# there is no tmux server at all. The ONE place this invocation is written: colliding_sessions and
# fleet_stale both need exactly this listing, and two hand-copied `tmux ls -F` format strings are two
# things to keep in step.
#
# Only the INVOCATION is shared, deliberately not the membership test. colliding_sessions asks "does
# anything overlap our namespace" and so reads each session's leading segment through
# prefixes_collide; fleet_stale asks the narrower "does THIS registered fleet still have sessions of
# its own" and so wants a literal `<pfx>-` match. Folding those into one predicate would make a
# stale-check refuse on a merely-overlapping neighbour.
tmux_sessions_with_paths(){ tmux ls -F '#{session_name}'$'\t''#{session_path}' 2>/dev/null || true; }

# colliding_sessions — every LIVE tmux session whose prefix space overlaps ours, one
# `<session>\t<session_path>\t<mine|theirs>` line each. This is the guard's ENFORCEMENT signal: tmux
# is the namespace actually at stake, it cannot go stale, and it sees sibling fleets that appear in
# NO registry (an older engine, a hand-set HARNESS_SESS_PREFIX, a session made by hand).
#
# Attribution comes from `session_path`: spawn_impl creates every session as
# `tmux new-session -d -s "$sess" -c "$wd"` with $wd a worktree under the OWNING project's
# STATE_DIR/worktrees/, so the path names the owner. `mine` is the `harness start --recover` case —
# a documented re-run against a live fleet, which must be allowed to proceed.
#
# A session's prefix is read as its leading dash-delimited segment. That UNDER-reads an owner whose
# own prefix contains a dash (`my-app-main-i1` -> `my`), but the under-read is sound: a shorter prefix
# owns strictly MORE of the namespace, so if `my` collides with ours so does `my-app`, and if it does
# not then `my-app-…` lies outside our space anyway — so no genuine collision is missed. The
# under-read can OVER-report when OUR OWN prefix contains a dash (`my-a` vs a sibling's real
# `my-app`): `prefixes_collide my-a my` is true while `prefixes_collide my-a my-app` is false and
# `my-app-main-i1` can never match our `^my-a-.+$` sweep. That direction fails safe — an unnecessary
# refusal, never a missed cross-kill — and is unreachable for a derived prefix, which never
# contains a dash.
colliding_sessions(){
  local name path seg
  while IFS=$'\t' read -r name path; do
    [[ -n "$name" ]] || continue
    seg="${name%%-*}"
    prefixes_collide "$HARNESS_SESS_PREFIX" "$seg" || continue
    if [[ "$path" == "$STATE_DIR" || "$path" == "$STATE_DIR"/* ]]; then
      printf '%s\t%s\tmine\n' "$name" "$path"
    else
      printf '%s\t%s\ttheirs\n' "$name" "$path"
    fi
  done < <(tmux_sessions_with_paths)
}

# fleet_owner_of <session_path> — the project directory owning a fleet session. Sessions live in a
# worktree under <owner STATE_DIR>/worktrees/, so cutting at /worktrees/ yields that STATE_DIR and
# its parent is the project dir. A path that doesn't match (a hand-made session, an unusual layout)
# falls back to itself, so the refusal message still says something true and actionable.
fleet_owner_of(){ local p="$1"
  if [[ "$p" == */worktrees/* ]]; then dirname "${p%%/worktrees/*}"; else printf '%s\n' "$p"; fi; }

# poller_registry_prefixes <self-project> — every OTHER active fleet's recorded session prefix, one
# `<prefix>\t<project>` line per fleet (deduped by project; <self-project> excluded). The cross-fleet
# discovery source for the start-time guard: slice 2 records each fleet's HARNESS_SESS_PREFIX in its
# registry entry; we read it back. A stopped fleet deregisters (no entry), so "has an entry" == active.
# Empty when the registry is absent or holds only this project — the single-fleet no-op.
poller_registry_prefixes(){
  [[ -d "$POLLER_REGISTRY_DIR" ]] || return 0
  SELF="$1" python3 - "$POLLER_REGISTRY_DIR" <<'PY'
import json, os, sys
d, self_prj = sys.argv[1], os.environ["SELF"]
seen = {}
for name in sorted(os.listdir(d)):
    if not name.endswith(".json"):
        continue
    try:
        rec = json.load(open(os.path.join(d, name)))
    except (OSError, ValueError):
        continue
    prj = rec.get("project")
    if not prj or prj == self_prj:
        continue
    seen.setdefault(prj, rec.get("prefix") or "")
for prj, pfx in seen.items():
    print(f"{pfx}\t{prj}")
PY
}

# fleet_stale <prefix> <run_dir> — is a REGISTERED fleet actually dead? True when no live tmux
# session sits under `<prefix>-` AND no pid recorded in its run_dir is alive. A fleet killed with -9
# or lost to a host crash never reaches stop.sh's fleet_deregister, and its leftover reservation must
# not refuse a legitimate restart forever. Both signals are checked because either can outlive the
# other: sessions can survive a dead worker pool (status.sh calls that DEGRADED), and a worker can be
# alive between session spawns.
#
# This applies to the REGISTRY source ONLY. The other two discovery sources — live tmux sessions and
# live worker processes — are alive by construction and can never be stale, so running them through
# a staleness check could only ever produce a false prune (see check_prefix_collision).
#
# Two deliberate limits. A FAILED `tmux ls` (no server, no $TMUX socket, a permissions error) reads
# as "no sessions" — that is the right default here, since the pid check still has to agree before
# anything is pruned. And `kill -0` against ANOTHER user's pid returns EPERM, not success, so a
# cross-user sibling's live fleet can look stale; cross-user detection is out of scope by design
# (see the spec), and a same-user fleet — the only arrangement Harness supports on a host — is read
# correctly.
fleet_stale(){ local pfx="$1" rd="$2" name p _
  while IFS=$'\t' read -r name _; do
    [[ "$name" == "$pfx-"* ]] && return 1
  done < <(tmux_sessions_with_paths)
  for p in "$rd"/*.pid; do
    [[ -e "$p" ]] || continue
    kill -0 "$(cat "$p" 2>/dev/null)" 2>/dev/null && return 1
  done
  return 0; }

# running_fleet_prefixes <self-state-dir> — `<prefix>\t<state-dir>` for every OTHER fleet that has a
# LIVE worker process on this host, deduped by state dir.
#
# The registry-FREE discovery source, and the one that matters. poller_registry_prefixes only has
# entries when HARNESS_USE_POLLER is set — and that is UNSET by default, so the whole start-time
# guard was inert for the ordinary configuration. Three fleets came up on the default `hz` prefix on
# one host and two of them (both `single` topology, hence both unit `main`) spent hours reaping each
# other's `hz-main-i<N>` sessions and worktrees before anyone noticed.
#
# A running worker knows its own identity: lib.sh exports STATE_DIR and HARNESS_SESS_PREFIX, and
# pool.sh/priority.sh fork the workers with that environment. So the live process table IS the
# registry — always present, never stale (a dead fleet has no processes), nothing to write at start
# and nothing to clean up at stop. It also sees fleets that were already running before the fleet
# registry existed, which no file-based registry could.
#
# Reads /proc, like lock_holders does. On a host without /proc this yields nothing and the guard
# degrades to its other two sources — never worse than before.
running_fleet_prefixes(){ local self="$1" pid sd pfx cmd
  command -v pgrep >/dev/null 2>&1 || return 0
  declare -A _seen=()
  for pid in $(pgrep -f '(pool|priority)-worker\.sh' 2>/dev/null); do
    [[ -r "/proc/$pid/environ" && -r "/proc/$pid/cmdline" ]] || continue
    # Match the SCRIPT, not merely a command line that mentions it — a shell running
    # `pgrep -af pool-worker.sh` carries the pattern in its own cmdline and would self-report.
    cmd="$(tr '\0' '\n' < "/proc/$pid/cmdline" | grep -cE '(pool|priority)-worker\.sh$')"
    [[ "${cmd:-0}" -gt 0 ]] || continue
    sd=""; pfx=""
    while IFS= read -r -d '' kv; do
      case "$kv" in
        STATE_DIR=*)           sd="${kv#STATE_DIR=}";;
        HARNESS_SESS_PREFIX=*) pfx="${kv#HARNESS_SESS_PREFIX=}";;
      esac
    done < "/proc/$pid/environ"
    [[ -n "$sd" && "$sd" != "$self" ]] || continue
    [[ -n "${_seen[$sd]:-}" ]] && continue
    _seen[$sd]=1
    printf '%s\t%s\n' "$(_fleet_prefix_for "$sd" "$pfx")" "$sd"
  done; }

# _fleet_prefix_for <state-dir> <env-prefix> — the session prefix a discovered fleet actually uses.
#
# Three sources in descending authority. The worker's own environment is exact, but it is only there
# once lib.sh EXPORTS HARNESS_SESS_PREFIX — which it did not until #167, so every fleet already
# running when that landed has none. Falling back to the project's own config is what lets the guard
# see those fleets at all, and it is the same file lib.sh itself would read. Last resort is lib.sh's
# own default, which is precisely the value that made three fleets collide in the first place — an
# absent config line means `hz`, it does not mean "no prefix".
#
# The config is GREPPED, never sourced: it is another project's file and sourcing it would execute
# whatever is in it. `head -1` matches `:=` semantics — the first assignment is the one that sticks.
_fleet_prefix_for(){ local sd="$1" env_pfx="$2" cfg_pfx=""
  [[ -n "$env_pfx" ]] && { printf '%s' "$env_pfx"; return 0; }
  if [[ -r "$sd/config" ]]; then
    cfg_pfx="$(sed -n 's/^[[:space:]]*:[[:space:]]*"\${HARNESS_SESS_PREFIX:=\([^}"]*\)}".*/\1/p' "$sd/config" | head -1)"
  fi
  printf '%s' "${cfg_pfx:-hz}"; }

# FLEET_ROW_SEP — the field separator of active_fleet_prefixes' rows. ASCII US (0x1f), deliberately
# NOT a tab: tab is IFS *whitespace*, so bash's `read` collapses a RUN of tabs into one delimiter and
# strips trailing ones. A widened row has interior fields that are legitimately empty (a process row
# has no run_dir and no slugs), and under tab those rows silently lose columns — the `source` column
# lands in `run_dir` and the staleness gate reads the wrong thing. With a non-whitespace separator
# every field, empty or not, is preserved exactly. Neither a path, a prefix nor a repo slug can
# contain 0x1f, so nothing can forge a column boundary.
FLEET_ROW_SEP=$'\037'

# active_fleet_prefixes <self-state-dir> — the UNION of the two NON-tmux discovery sources, one
# `<prefix>US<project>US<run_dir>US<slugs>US<source>` line per other active fleet (US =
# $FLEET_ROW_SEP). The seam the start-time guard reads for stages 2 and 3 (and the one tests
# override).
#
# The two sources natively emit DIFFERENT shapes: running_fleet_prefixes yields `<prefix>\t<state-dir>`
# (a process has no run_dir and no slug list to report), fleet_registry_entries yields
# `<prefix>\t<project>\t<run_dir>\t<slugs>`. They are WIDENED to one common row here, with a trailing
# `source` column, rather than being read as two separate loops in the guard, because the difference
# that actually matters downstream is not the arity — it is that exactly ONE of them can go stale.
# Carrying `source` in the row makes that explicit at the point of use: a `process` row is skipped by
# the staleness check by name, so it can never be pruned for the mere absence of a run_dir it was
# never able to supply. Two hand-written loops would leave that as an invariant of the loop ORDER.
#
# poller_registry_prefixes is deliberately NOT read here even though #167's version of this union
# called it: fleet_registry_entries ALREADY unions the poller registry into its own output, and does
# so in the wide shape, so reading it again would re-add the same fleets as rows with no run_dir —
# i.e. as rows that can never be pruned, which is exactly the "a crashed fleet reserves its prefix
# forever" failure the staleness check exists to prevent. It remains exported for uninstall.sh.
active_fleet_prefixes(){ local self="$1" us="$FLEET_ROW_SEP" pfx prj rd slugs
  # Live worker processes FIRST: never stale, so a fleet seen here needs no corroboration. Its rows
  # carry exactly two fields, both required non-empty, so reading them on tab is safe.
  while IFS=$'\t' read -r pfx prj; do
    [[ -n "$pfx" && -n "$prj" ]] || continue
    printf '%s\n' "$pfx$us$prj$us$us${us}process"
  done < <(running_fleet_prefixes "$self")
  # The registry rows CAN carry an empty INTERIOR field (a poller entry has slugs but no run_dir), so
  # translate to the row separator before reading rather than reading them on tab.
  while IFS="$us" read -r pfx prj rd slugs; do
    [[ -n "$pfx" && -n "$prj" ]] || continue
    printf '%s\n' "$pfx$us$prj$us$rd$us$slugs${us}registry"
  done < <(fleet_registry_entries "$self" | tr '\t' "$us")
}

# _prefix_collision_report <owner-dir> <owner-slugs> <live-session-count> [source] — the refusal.
# Names the owner, our own project, and a concrete retry, because the operator's next question is
# always "which project has it, and what do I type instead". Honours HARNESS_PREFIX_COLLISION:
# `refuse` (default) dies, `warn` prints to stderr and returns 0. The engine NEVER edits
# .harness/config itself and never starts under a prefix other than the configured one.
_prefix_collision_report(){ local owner="$1" slugs="$2" n="$3" src="${4:-registry}" sugg msg detail
  sugg="$(derive_prefix "$PROJECT_ROOT")"
  [[ "$sugg" != "$HARNESS_SESS_PREFIX" ]] || sugg="${sugg}2"
  # A sessionless refusal passes n=0, and `0 live tmux session(s)` reads as the message contradicting
  # the refusal it is attached to. Say what is actually true, and say which of the two sessionless
  # sources saw it — "a worker is running" and "a fleet is registered" call for different next moves.
  if   (( n > 0 ));            then detail="$n live tmux session(s)"
  elif [[ "$src" == process ]]; then detail="live worker process, no sessions yet"
  else                              detail="registered, no live sessions yet"; fi
  msg="$(printf 'session prefix %s is in use by another fleet\n  owner:    %s%s\n  prefix:   %s — %s\n  yours:    %s\nretry with a distinct prefix, e.g.:\n  HARNESS_SESS_PREFIX=%s harness start\nor set HARNESS_SESS_PREFIX in %s/config\n(HARNESS_PREFIX_COLLISION=warn overrides)' \
    "$HARNESS_SESS_PREFIX" "$owner" "${slugs:+ (repo $slugs)}" "$HARNESS_SESS_PREFIX" "$detail" \
    "$PROJECT_ROOT" "$sugg" "$STATE_DIR")"
  case "${HARNESS_PREFIX_COLLISION:-refuse}" in
    warn) printf 'WARNING: %s\n' "$msg" >&2; return 0;;
    *)    die "$msg";;
  esac
}

# check_prefix_collision — start-time guard. THREE discovery sources, because each answers a
# question the other two cannot:
#
#   1. LIVE tmux SESSIONS (colliding_sessions) — ENFORCEMENT. A session in our prefix space whose
#      session_path belongs to another project means the namespace is shared RIGHT NOW: our stop.sh
#      would kill their agents mid-edit. Attribution also gives us the `mine` case, so
#      `harness start --recover` against our own live fleet still proceeds.
#   2. LIVE WORKER PROCESSES (running_fleet_prefixes) — a fleet whose workers are up but whose
#      sessions have not spawned yet, and any fleet that predates the fleet registry entirely. This
#      is the source that made the guard work at all without HARNESS_USE_POLLER (#167).
#   3. The fleet REGISTRY (fleet_registry_entries) — RESERVATION. A registered sibling with no
#      sessions and no workers yet still owns its prefix, so two idle fleets can't race into one
#      namespace. It also carries the repo slugs and the owner for the message.
#
# STALENESS applies to source 3 ONLY. Sources 1 and 2 are alive by construction — a dead fleet has
# neither sessions nor processes — so the row's `source` column, not its position in a loop, is what
# gates the fleet_stale prune. A `process` row has no run_dir to offer and must never be read as
# stale for lacking one.
#
# HARNESS_PREFIX_COLLISION: `refuse` (default) dies; `warn` prints to stderr and continues.
check_prefix_collision(){
  local name path who hit_path="" n=0
  # 1) LIVE tmux sessions — the enforcement signal.
  while IFS=$'\t' read -r name path who; do
    [[ "$who" == theirs ]] || continue
    n=$((n+1)); [[ -n "$hit_path" ]] || hit_path="$path"
  done < <(colliding_sessions)
  if (( n > 0 )); then
    local owner; owner="$(fleet_owner_of "$hit_path")"
    # In `refuse` mode the report dies (exits); in `warn` mode it returns 0 and we proceed. Pass its
    # status straight through — do NOT add a `return 1` after this call, which would defeat warn mode.
    _prefix_collision_report "$owner" "$(fleet_slugs_of "$owner")" "$n"
    return $?
  fi
  # 2+3) Sessionless sources, widened to one row shape by active_fleet_prefixes: live worker
  #      processes first (never stale), then the registry (pruned when stale).
  local pfx prj rd slugs src
  # $FLEET_ROW_SEP, not tab: a process row's run_dir and slugs are empty INTERIOR fields, and bash
  # collapses runs of tab (an IFS-whitespace char), which would slide `source` into `run_dir`.
  while IFS="$FLEET_ROW_SEP" read -r pfx prj rd slugs src; do
    [[ -n "$pfx" ]] || continue
    prefixes_collide "$HARNESS_SESS_PREFIX" "$pfx" || continue
    # Staleness is a REGISTRY concern only — see the header. A `process` row that reached here has a
    # live worker behind it; pruning it would be pruning a running fleet.
    #
    # And a registry row with NO run_dir is not evidence of death either. A POLLER record is
    # {slug,cadence,prefix,project} — poller_register never wrote a run_dir — so fleet_stale finds no
    # pidfiles to check and, absent a live `<pfx>-` session, calls a perfectly live fleet stale and
    # waves the start through. That silent wave-through IS the incident this guard exists to prevent,
    # so an absent run_dir must read as "no liveness evidence", never as "dead". The cost is that a
    # poller-only fleet killed with -9 reserves its prefix until `harness stop` / poller_deregister
    # clears it; #167 accepted exactly that trade, and it only reaches fleets on an older engine.
    # Fleets registered in ~/.harness/fleets always carry a run_dir and are still pruned (cases 5/6).
    if [[ "$src" == registry && -n "$rd" ]] && fleet_stale "$pfx" "$rd"; then fleet_deregister "$prj"; continue; fi
    # Same return convention as the tmux path above: pass the report's status through, never `return 1`.
    _prefix_collision_report "$(dirname "$prj")" "$slugs" 0 "$src"
    return $?
  done < <(active_fleet_prefixes "$STATE_DIR")
  return 0
}

# fleet_slugs_of <project-dir> — the repo slugs a registered fleet serves, for the refusal message.
# Empty when that fleet isn't registered (an older engine, a hand-made session): the message still
# names the owning directory, which is the part the operator acts on.
fleet_slugs_of(){ local dir="$1" pfx prj rd slugs
  # $FLEET_ROW_SEP, not tab: a poller row's run_dir is an empty INTERIOR field and bash collapses
  # runs of tab, which would read the slug list as $rd and hand back an empty slug list.
  while IFS="$FLEET_ROW_SEP" read -r pfx prj rd slugs; do
    [[ "$(dirname "$prj")" == "$dir" ]] && { printf '%s\n' "$slugs"; return 0; }
  done < <(fleet_registry_entries "" | tr '\t' "$FLEET_ROW_SEP")
  printf '\n'; }
# swarm_suite_cmd — the full-suite-on-swarm helper as one shell-quoted command, rendered into the lane
# prompts as {{SWARM_SUITE}} (#202). It carries the fleet's mode and run dir explicitly: a Claude
# session does not inherit this process's environment, so it cannot be left to find them itself.
swarm_suite_cmd(){ printf 'HARNESS_SWARM=%q RUN_DIR=%q bash %q' "$HARNESS_SWARM" "$RUN_DIR" "$ENGINE_DIR/scripts/swarm-suite.sh"; }
# rtdd_skill_install — the user-level `rtdd` skill the lane prompts defer to (#187). rtdd v0.3 writes
# no agent files into projects, so this skill is where a lane learns its rounds. Upstream's install
# is idempotent and covers ~/.claude; agy reads its own user skill dir, so an agy fleet also gets the
# skill there, extracted from `rtdd skill prompt`. WARN and return 1 on any failure, never die: a lane
# without the skill still has the prompt's own pointer and the full-suite bar.
rtdd_skill_install(){ local d
  command -v rtdd >/dev/null || return 0   # the missing-binary warning is setup's own
  # --legacy-files is v0.3-only; an older rtdd's skill install merges into ~/.codex and ~/.gemini.
  rtdd --help 2>&1 | grep -q -- '--legacy-files' || {
    echo "  ! rtdd predates v0.3 — lanes need its rounds and fall back to the full suite. Upgrade: rtdd update"
    return 1; }
  rtdd skill install >/dev/null 2>&1 || {
    echo "  ! rtdd skill install failed — lanes run without the rtdd skill. Retry: rtdd skill install"
    return 1; }
  d="$(cli_user_skills_dir)"   # a CLI whose user skills `rtdd skill install` does not reach
  if [[ -n "$d" ]]; then
    d="$d/rtdd"
    mkdir -p "$d" && rtdd skill prompt 2>/dev/null | awk '/^````$/{f=0} f; /^````markdown$/{f=1}' > "$d/SKILL.md.tmp" \
      && [[ -s "$d/SKILL.md.tmp" ]] && mv "$d/SKILL.md.tmp" "$d/SKILL.md" || {
      rm -f "$d/SKILL.md.tmp"
      echo "  ! could not install the rtdd skill for $(cli_name) into $d — retry: harness setup"
      return 1; }
  fi
  echo "  ✓ rtdd skill installed"; }
# {{skill:<name>}} — a skill the prompt names, as the configured CLI invokes it (cli_skill, #315).
# cli_prereqs derives the skills it checks from these same tokens, so a prompt names a skill no other way.
render(){ local tmpl="$1" n; shift
  local -a sk=()
  for n in $(grep -ohE '\{\{skill:[A-Za-z0-9_.-]+\}\}' "$tmpl" "$(dirname "$tmpl")"/_*.md 2>/dev/null | sort -u); do
    n="${n#\{\{skill:}"; n="${n%\}\}}"; sk+=("skill:$n=$(cli_skill "$n")"); done
  python3 - "$tmpl" "$@" "${sk[@]}" <<'PY'
import sys, re, os
tmpl = open(sys.argv[1]).read()
# {{> _part.md}} — a partial from the template's own dir, shared by several prompts so its text has
# one copy (#187). Expanded BEFORE the keys, so a partial can use them like its host template. A
# missing partial stays as its directive, like an unknown key: visible in the prompt, never empty.
def part(m):
    try: body = open(os.path.join(os.path.dirname(sys.argv[1]), m.group(1))).read()
    except OSError: return m.group(0)
    return body.rstrip('\n') + '\n' if m.group(0).endswith('\n') else body
tmpl = re.sub(r'{{>\s*([\w.-]+)\s*}}\n?', part, tmpl)
kv = dict(a.split('=', 1) for a in sys.argv[2:])
sys.stdout.write(re.sub(r'{{(\w+|skill:[\w.-]+)}}', lambda m: kv.get(m.group(1), m.group(0)), tmpl))
PY
}
# fleet_login — the authenticated gh login, i.e. the identity every engine-trusted comment (round
# markers, handoffs) must carry. Empty on failure; callers fail closed. Validated to GitHub's login
# charset so it can be spliced into a jq filter.
fleet_login(){ local me; me="$(gh api user -q .login 2>/dev/null)" || return 0
  [[ "$me" =~ ^[A-Za-z0-9-]+$ ]] && printf '%s' "${me,,}"; }
# _fleet_comments_jq <body-prefix> — jq selecting the bodies of comments the FLEET wrote that start
# with <body-prefix>. Comments are writable by anyone who can see the issue (anyone, on a public
# repo), so an engine decision keyed on comment text must never count one it did not author.
_fleet_comments_jq(){ printf '[.comments[] | select((.author.login // "" | ascii_downcase) == "%s") | .body | select(startswith("%s"))]' "$(fleet_login)" "$1"; }
# _marker_round <prd> <marker> — echo the round (1-based) of a capped review loop whose every LOST
# round leaves a `<!-- <marker> round=N -->` comment on the PRD (see prompts/review.md). Nothing on
# disk, so a resume on another host picks up at the right round. ANY failure — offline, rate limit,
# junk on stdout, an unresolvable fleet login — counts as zero markers and returns round 1: neither a
# transient gh error nor an outsider's forged marker may push the reviewer past the cap into a concede.
_marker_round(){ local prd="$1" marker="$2" n
  [[ -n "$(fleet_login)" ]] || { echo 1; return; }
  n="$(gh issue view "$prd" -R "$SLUG" --json comments \
       -q "$(_fleet_comments_jq "<!-- $marker round=") | length" 2>/dev/null || echo 0)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  echo $(( n + 1 )); }
gauntlet_round(){ _marker_round "$1" harness-gauntlet; }
security_audit_round(){ _marker_round "$1" harness-security-audit; }
# resume_handoff <issue> — body of the LATEST `<!-- harness-handoff issue=<n> … -->` comment the fleet
# itself posted on <issue>, or empty. spawn_impl/spawn_bug render it into resume.md so the resumed
# agent never goes hunting through raw comments for its "prior context" — a stranger could post that
# marker too. The trailing space in the prefix keeps #5 from matching #55's handoff.
resume_handoff(){ [[ -n "$(fleet_login)" ]] || return 0
  gh issue view "$1" -R "$SLUG" --json comments \
    -q "$(_fleet_comments_jq "<!-- harness-handoff issue=$1 ") | last // empty" 2>/dev/null || true; }
write_state(){ local wd="$1" promise="$2" maxiter="$3" uuid="$4"; mkdir -p "$wd/.claude"
  { printf -- '---\nactive: true\niteration: 1\nsession_id: %s\nmax_iterations: %s\ncompletion_promise: "%s"\nstarted_at: "%s"\n---\n\n' \
      "$uuid" "$maxiter" "$promise" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; cat "$wd/.harness-task.md"
  } > "$wd/.claude/ralph-loop.local.md"; }
# --- #185: host-wide event log ------------------------------------------------
# Every fleet on the host appends one JSON line per event to $HARNESS_HOME/events.jsonl, or to
# HARNESS_EVENTS_FILE when set (stats.py does the flock + JSON); `harness stats` reports over it. A launched session's context (uuid, kind,
# issue, prd, model, effort, worktree) is kept in $RUN_DIR/<sess>.stats so its later events — nudge,
# watchdog_kill, session_end — carry it without re-deriving it. Logging NEVER blocks or fails the
# caller: stats.py gives up on a held lock after 2s, `timeout` bounds the rest, every failure is
# swallowed and only the FIRST one per process is logged (to stderr — several callers' stdout is a
# captured return value, e.g. claim_next).
STATS_PY="$ENGINE_DIR/scripts/stats.py"
harness_event(){
  timeout 10 python3 "$STATS_PY" emit "$@" -c "prefix=$HARNESS_SESS_PREFIX" -c "project=$PROJECT_ROOT" \
    -c "repo=${SLUG:-}" -c "unit=${UNIT:-}" >/dev/null 2>&1 && return 0
  [[ -n "${_HARNESS_EVENT_ERR:-}" ]] && return 0
  _HARNESS_EVENT_ERR=1; log "stats: event log write failed (${HARNESS_EVENTS_FILE:-$HARNESS_HOME/events.jsonl}) — logging the rest silently (#185)" >&2
  return 0; }
# stats_sess_event <sess> <event> [k=v …] — an event about one launched session, carrying its context.
stats_sess_event(){ local sess="$1"; shift; harness_event "$1" --ctx "$RUN_DIR/$sess.stats" "${@:2}"; }
# stats_sweep_ended — emit session_end for every launched session whose tmux session is gone, then
# drop its context. Called from every reaper BEFORE it removes worktrees (the ralph state file there
# carries the iteration count). The rename claims the file atomically, so when two lanes sweep the
# shared RUN_DIR at once exactly one emits.
stats_sweep_ended(){ local f s claim
  shopt -s nullglob
  for f in "$RUN_DIR"/*.stats; do
    s="$(basename "$f" .stats)"
    session_live "$s" && continue
    claim="$f.end.$$"; mv "$f" "$claim" 2>/dev/null || continue
    harness_event session_end --ctx "$claim" usage_tsv="$(_stats_cli_usage "$claim")"; rm -f "$claim"
  done
  shopt -u nullglob; }
# _stats_cli_usage <ctx file> — the ended session's per-model usage lines, read by the CLI adapter
# from the CLI's own transcripts (#188); empty when it has none. stats.py prefers a claude
# transcript it finds itself (it also dates the session's last turn from it).
_stats_cli_usage(){ local wd sid files
  IFS=$'\t' read -r wd sid < <(python3 -c 'import json,sys
c = json.load(open(sys.argv[1])); print(c.get("worktree", ""), c.get("session", ""), sep="\t")' "$1" 2>/dev/null)
  sid="$(cli_session_id "$wd" "$sid")"; [[ -n "$sid" ]] || return 0
  files="$(cli_transcripts "$wd" "$sid")"; [[ -n "$files" ]] || return 0
  mapfile -t files <<<"$files"; cli_usage "${files[@]}" 2>/dev/null; return 0; }
# LANE_ENV_NAMES — every name session_env can set: a CLI whose turns' commands do not inherit the
# pane's environment names them to the CLI (hermes: terminal.client_env_passthrough, #313).
LANE_ENV_NAMES=(RTDD_EVENT_LOG HARNESS_SESSION HARNESS_PREFIX HARNESS_REPO HARNESS_KIND HARNESS_ISSUE HARNESS_PRD)
# session_env <uuid> — fill SESSION_ENV with the `-e K=V` pairs `tmux new-session` gives a lane (#186).
# RTDD_EVENT_LOG points every rtdd call the session makes at the host-wide rtdd log, and rtdd copies
# each HARNESS_* var into the event's ctx (VocanicZ/rtdd#503), so `harness stats` can join the call to
# its session, issue and PRD. Set on the session, not the typed command line, so claude and agy alike
# inherit it. KIND/ISSUE/PRD come from the same GOAL parse the launch event uses.
session_env(){ local kv
  SESSION_ENV=(-e "RTDD_EVENT_LOG=${HARNESS_RTDD_EVENTS_FILE:-$HARNESS_HOME/rtdd-events.jsonl}"
    -e "HARNESS_SESSION=$1" -e "HARNESS_PREFIX=$HARNESS_SESS_PREFIX")
  [[ -n "${SLUG:-}" ]] && SESSION_ENV+=(-e "HARNESS_REPO=$SLUG")
  while read -r kv; do [[ -n "$kv" ]] && SESSION_ENV+=(-e "HARNESS_$kv"); done \
    < <(timeout 10 python3 "$STATS_PY" goal-env "${GOAL:-}" "${STAT_PRD:-}" 2>/dev/null)
  return 0; }
# issue_parent_prd <issue> — the PRD an issue's `## Parent` names (empty when unparented / gh fails).
issue_parent_prd(){ gh issue view "$1" -R "$SLUG" --json body -q .body 2>/dev/null | python3 "$STATS_PY" parent-prd "$SLUG" 2>/dev/null || true; }
# #213: the agent's prompt argument is this fixed bootstrap, NEVER the task text. Interpolating
# the task file into the launch line put every lane's whole prompt in its argv, so one lane's
# `pkill -f` on a phrase from its own prompt matched — and killed — every lane on the host. The task stays in
# .harness-task.md (written before launch; write_state copies it for the ralph re-feed).
HARNESS_BOOTSTRAP_PROMPT="Read .harness-task.md in this directory and follow it exactly."
launch_agent(){ local sess="$1" wd="$2" uuid
  # #108: never re-enter a live session. If $sess is already up (e.g. a transiently-dropped
  # agent-working label re-dispatched the same issue), short-circuit BEFORE any side effect — no
  # write_state (don't clobber the running agent's state file), no new-session, and above all no
  # send-keys typing a second `exec claude …` into the live pane. This guard MUST be first.
  if session_live "$sess"; then log "session $sess already live — skipping re-dispatch"; return 0; fi
  uuid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
  write_state "$wd" "${PROMISE:-}" "${MAXITER:-}" "$uuid"
  session_env "$uuid"
  tmux new-session -d -s "$sess" -c "$wd" "${SESSION_ENV[@]}"; sleep 1.5
  # Write the .goal AFTER the session is live, never before. gc_orphan_goals runs at the top of
  # EVERY lane's tick over the shared RUN_DIR and reaps any .goal whose session is not live. Writing
  # the goal before `tmux new-session` opened a cross-lane TOCTOU window: a concurrent sweep in that
  # gap sees session_live=false and deletes the goal of a session that is about to come up — losing
  # it for reap_done_sessions (drive.sh) and inject's REVIEW-in-flight check. Session-first closes
  # the window: a sweep here now finds session_live=true and leaves the goal alone.
  echo "${GOAL:-?}" > "$RUN_DIR/$sess.goal"
  echo "$wd" > "$RUN_DIR/$sess.wd"   # record worktree so reap_finished_inject can find the ralph state file
  ensure_trusted "$wd"   # #67: pre-accept the workspace-trust dialog so a fresh tree doesn't stall here
  ensure_bypass  "$wd"   # default sub-agents to bypassPermissions: the flag only covers the main session
  ensure_usage_statusline "$wd"   # #194: the session's status line reports its usage windows
  local model effort line line_me
  model="$(lane_setting "$wd" model)"; effort="$(lane_setting "$wd" effort)"
  line="$(cli_launch "$wd" "$uuid" "$model" "$effort")"
  tmux send-keys -t "$sess" "$line" Enter
  _launch_first_input "$sess" "$effort"
  # #307: the model and effort this launch runs with, as the CLI's adapter reads them off its own line
  # and lane config — not the lane pin alone, which names neither when the configured flags do.
  line_me="$(cli_model_effort "$line" "$wd")"; model="${line_me%%$'\t'*}"; effort="${line_me#*$'\t'}"
  [[ "$line_me" == *$'\t'* ]] || effort=""
  harness_event launch --write-ctx "$RUN_DIR/$sess.stats" session="$uuid" goal="${GOAL:-}" prd="${STAT_PRD:-}" \
    worktree="$wd" model="$model" effort="$effort" lane="$(cli_lane_settings "$wd" | paste -sd' ')" ralph_iter=1 tmux="$sess"
  log "launched session $sess (cwd $wd)"; }
launch_claude(){ launch_agent "$@"; }
# _launch_first_input <sess> [effort] — a CLI that cannot take its prompt or effort on the command
# line gets them typed once its input prompt first shows (cli_first_input); every other CLI has
# none, and this returns without polling the pane.
_launch_first_input(){ local sess="$1" in i pane
  in="$(cli_first_input "${2:-${HARNESS_EFFORT:-}}")"; [[ -n "$in" ]] || return 0
  for (( i = 0; i < 60; i++ )); do
    pane="$(tmux capture-pane -p -t "$sess" 2>/dev/null)"
    cli_pane_prompt "$pane" && ! cli_pane_busy "$pane" && break
    sleep 1
  done
  while IFS= read -r i; do cli_send "$sess" "" "$i"; done <<<"$in"; }

# --- PRD-B host poller: refcounted registry + supervision (#71) --------------
# A drop-a-file, refcounted registry under $POLLER_REGISTRY_DIR: one file per (repo, registrant)
# named <owner__repo>__<project-sanitised>.json holding {slug,cadence,prefix,project}. The `project`
# (a STATE_DIR path) is the refcount key — a slug stays registered while ANY project references it,
# and deregister removes ONLY the calling project's files. The poller (poller.sh) dedupes by slug
# and refreshes each unique slug at the FASTEST registrant cadence. Slice 3 wires harness start/stop
# to register/deregister + the worker freshness gate; here these are the standalone building blocks.
_poller_slug_file(){ printf '%s' "${1//\//__}"; }   # acme/widget -> acme__widget (matches issuelib)
# registry filename for (slug, project): slug part + project path sanitised to a flat token. The
# authoritative refcount key is the JSON `project` field (read back on deregister); the filename only
# needs to be unique-per-pair + idempotent (same pair -> same file -> overwrite).
_poller_reg_file(){ printf '%s/%s__%s.json' "$POLLER_REGISTRY_DIR" \
  "$(_poller_slug_file "$1")" "$(printf '%s' "$2" | tr -c 'A-Za-z0-9.-' '_')"; }

# poller_register <slug> <cadence> <prefix> <project> — drop/refresh this project's registry file for
# <slug>. Written atomically (tmp + rename) via python so any character in the project path is encoded
# safely as JSON. cadence defaults to the project's HARNESS_PRIORITY_POLL when blank.
poller_register(){
  local slug="$1" cadence="${2:-$HARNESS_PRIORITY_POLL}" prefix="${3:-}" project="$4"
  mkdir -p "$POLLER_REGISTRY_DIR"
  SLUG="$slug" CAD="$cadence" PFX="$prefix" PRJ="$project" python3 - "$(_poller_reg_file "$slug" "$project")" <<'PY'
import json, os, sys, tempfile
f = sys.argv[1]
rec = {"slug": os.environ["SLUG"], "cadence": int(os.environ["CAD"] or 0),
       "prefix": os.environ["PFX"], "project": os.environ["PRJ"]}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(f), prefix=".reg.")
with os.fdopen(fd, "w") as fh:
    json.dump(rec, fh)
os.replace(tmp, f)
PY
}

# poller_deregister <project> — remove every registry file this project owns (matched on the JSON
# `project` field, not the filename, so it is robust to path sanitisation). A slug another project
# still references survives. No-op when the registry dir is absent.
poller_deregister(){
  [[ -d "$POLLER_REGISTRY_DIR" ]] || return 0
  PRJ="$1" python3 - "$POLLER_REGISTRY_DIR" <<'PY'
import json, os, sys
d, prj = sys.argv[1], os.environ["PRJ"]
for name in os.listdir(d):
    if not name.endswith(".json"):
        continue
    p = os.path.join(d, name)
    try:
        rec = json.load(open(p))
    except (OSError, ValueError):
        continue
    if rec.get("project") == prj:
        try: os.remove(p)
        except OSError: pass
PY
}

# --- host-wide fleet registry ------------------------------------------------
# One file per LIVE fleet under $HARNESS_FLEETS_DIR, named from the sanitised STATE_DIR and holding
# {prefix, project, run_dir, slugs, started_at}. `project` (the STATE_DIR) is the identity key and is
# read back on deregister, so the operation survives filename sanitisation — the same discipline as
# poller_deregister. `harness start` writes an entry unconditionally and `harness stop` removes it;
# the start-time prefix guard reads them for RESERVATION (an idle fleet's prefix stays claimed) and
# for naming the owner in its refusal. tmux, not this file, is the guard's enforcement signal.
#
# Every write is BEST-EFFORT: an unwritable or absent $HARNESS_HOME warns once and returns 0. The
# registry is an aid to collision detection, never a gate on starting a fleet.
_fleet_reg_file(){ printf '%s/%s.json' "$HARNESS_FLEETS_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '_')"; }

# fleet_register — record THIS fleet. Idempotent: same project -> same file -> overwritten in place.
fleet_register(){
  if ! mkdir -p "$HARNESS_FLEETS_DIR" 2>/dev/null; then
    printf 'WARNING: cannot create fleet registry at %s — prefix-collision detection degraded\n' \
      "$HARNESS_FLEETS_DIR" >&2; return 0
  fi
  if ! PFX="$HARNESS_SESS_PREFIX" PRJ="$STATE_DIR" RD="$RUN_DIR" \
       SLUGS="$(snapshot_slugs 2>/dev/null | tr '\n' ' ')" \
       python3 - "$(_fleet_reg_file "$STATE_DIR")" <<'PY' 2>/dev/null
import json, os, sys, tempfile, time
f = sys.argv[1]
rec = {"prefix": os.environ["PFX"], "project": os.environ["PRJ"], "run_dir": os.environ["RD"],
       "slugs": os.environ["SLUGS"].split(), "started_at": int(time.time())}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(f), prefix=".fleet.")
with os.fdopen(fd, "w") as fh:
    json.dump(rec, fh)
os.replace(tmp, f)
PY
  then
    printf 'WARNING: fleet registry write failed (%s) — prefix-collision detection degraded\n' \
      "$HARNESS_FLEETS_DIR" >&2
  fi
  return 0
}

# fleet_deregister <project> — remove the entry this project owns, matched on the JSON `project`
# field rather than the filename. No-op when the registry dir is absent.
fleet_deregister(){
  [[ -d "$HARNESS_FLEETS_DIR" ]] || return 0
  PRJ="$1" python3 - "$HARNESS_FLEETS_DIR" <<'PY' 2>/dev/null
import json, os, sys
d, prj = sys.argv[1], os.environ["PRJ"]
for name in os.listdir(d):
    if not name.endswith(".json"):
        continue
    p = os.path.join(d, name)
    try:
        rec = json.load(open(p))
    except (OSError, ValueError):
        continue
    if rec.get("project") == prj:
        try: os.remove(p)
        except OSError: pass
PY
  return 0
}

# fleet_registry_entries <self-project> — every OTHER registered fleet, one
# `<prefix>\t<project>\t<run_dir>\t<slugs space-separated>` line each. Reads BOTH the fleet registry
# and the poller registry (deduped by project, the fleet entry winning) so a poller-enabled fleet
# running an older engine — which registers only in poller/registry — is still seen. A malformed or
# unreadable file is skipped, never fatal.
fleet_registry_entries(){
  SELF="$1" python3 - "$HARNESS_FLEETS_DIR" "$POLLER_REGISTRY_DIR" <<'PY' 2>/dev/null
import json, os, sys
self_prj = os.environ["SELF"]
seen = {}
for d in sys.argv[1:]:                      # fleet registry first: it wins on conflict
    if not os.path.isdir(d):
        continue
    for name in sorted(os.listdir(d)):
        if not name.endswith(".json"):
            continue
        try:
            rec = json.load(open(os.path.join(d, name)))
        except (OSError, ValueError):
            continue
        prj = rec.get("project")
        if not prj or prj == self_prj or prj in seen:
            continue
        slugs = rec.get("slugs") or ([rec["slug"]] if rec.get("slug") else [])
        seen[prj] = (rec.get("prefix") or "", rec.get("run_dir") or "", " ".join(slugs))
for prj, (pfx, rd, slugs) in seen.items():
    print(f"{pfx}\t{prj}\t{rd}\t{slugs}")
PY
  return 0
}

# poller_registry_slugs — the unique slugs currently registered, one per line, sorted (deduped across
# registrants). Empty (no output) when nothing is registered. This is the poller's work list.
poller_registry_slugs(){
  [[ -d "$POLLER_REGISTRY_DIR" ]] || return 0
  python3 - "$POLLER_REGISTRY_DIR" <<'PY'
import json, os, sys
d = sys.argv[1]; slugs = set()
for name in os.listdir(d):
    if not name.endswith(".json"):
        continue
    try:
        rec = json.load(open(os.path.join(d, name)))
    except (OSError, ValueError):
        continue
    s = rec.get("slug")
    if s:
        slugs.add(s)
# Emit NOTHING when empty (no trailing newline) so `mapfile`/command-substitution see a truly empty
# list — a `print("")` would yield one blank line, which the poller loop would mistake for one slug.
if slugs:
    print("\n".join(sorted(slugs)))
PY
}

# poller_cadence_for <slug> — the FASTEST (minimum) cadence among the live registrants for <slug>, so
# the most demanding fleet sets the refresh rate. Falls back to HARNESS_PRIORITY_POLL when <slug> has
# no registrant (or all recorded cadences are non-positive).
poller_cadence_for(){
  [[ -d "$POLLER_REGISTRY_DIR" ]] || { echo "$HARNESS_PRIORITY_POLL"; return; }
  SLUG="$1" DEFLT="$HARNESS_PRIORITY_POLL" python3 - "$POLLER_REGISTRY_DIR" <<'PY'
import json, os, sys
d, slug, dflt = sys.argv[1], os.environ["SLUG"], int(os.environ["DEFLT"])
best = None
for name in os.listdir(d):
    if not name.endswith(".json"):
        continue
    try:
        rec = json.load(open(os.path.join(d, name)))
    except (OSError, ValueError):
        continue
    if rec.get("slug") != slug:
        continue
    c = rec.get("cadence")
    if isinstance(c, int) and c > 0 and (best is None or c < best):
        best = c
print(best if best is not None else dflt)
PY
}

# poller_snapshot_path <slug> — where the poller writes <slug>'s snapshot. Mirrors issuelib's
# _slug_filename so the read seam (HARNESS_SNAPSHOT_DIR) finds it.
poller_snapshot_path(){ printf '%s/%s.json' "$HARNESS_SNAPSHOTS_DIR" "$(_poller_slug_file "$1")"; }

# poller_write_snapshot <slug> — generate the raw snapshot via issuelib and write it ATOMICALLY
# (tmp + rename). Runs issuelib with HARNESS_SNAPSHOT_FILE/_DIR UNSET so it reads gh (the poller's
# job), not a snapshot. On a failed/garbled generation it leaves any existing snapshot UNTOUCHED
# (returns non-zero) — a transient gh failure must never clobber a good snapshot into garbage; it
# just ages into staleness, which workers (slice 3) treat as a hold.
#
# Incremental (#182): the existing snapshot is handed back to issuelib as the cache, so a refresh asks
# GitHub only for what changed since it (`since` + ETag → a free 304 on an unchanged board). Guarded
# by a per-slug flock, so a `harness poll --once` racing the loop never builds on a half-read cache.
poller_write_snapshot(){
  local slug="$1" out tmp lockfd rc=1
  mkdir -p "$HARNESS_SNAPSHOTS_DIR"
  out="$(poller_snapshot_path "$slug")"; tmp="$out.tmp.$$"
  exec {lockfd}>"$out.lock"; flock "$lockfd"
  if HARNESS_SNAPSHOT_FILE= HARNESS_SNAPSHOT_DIR= python3 "$ISSUELIB" snapshot "$slug" "$out" > "$tmp" 2>/dev/null \
     && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$out"; rc=0
  else
    rm -f "$tmp"
  fi
  flock -u "$lockfd"; exec {lockfd}>&-
  return "$rc"
}

# poller_running — is a poller alive (its pidfile names a live process)?
poller_running(){ local pid; pid="$(cat "$POLLER_PID" 2>/dev/null || true)"; [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; }

# ensure_poller — launch the host poller if none is alive. Idempotent and lock-guarded so concurrent
# worker ticks can't double-spawn. The poller is a nohup BACKGROUND process (NOT a tmux session), so
# `harness stop` (which kills ^<prefix>- tmux sessions) never touches it — correct, since other
# fleets may still need it. The pid is recorded under the lock immediately so a near-simultaneous
# caller sees a live pid and stands down. HARNESS_POLLER_CMD overrides the launched command (a test
# seam); production launches scripts/poller.sh.
ensure_poller(){
  mkdir -p "$HARNESS_POLLER_DIR"
  local lockfd
  exec {lockfd}>"$POLLER_LOCK"; flock "$lockfd"
  if poller_running; then flock -u "$lockfd"; exec {lockfd}>&-; return 0; fi
  rm -f "$POLLER_PID"
  # Spawn the poller with fd 9 CLOSED for the child (`9>&-`). start.sh calls ensure_poller while it
  # still holds the double-start lock on fd 9 (start.sh:101, before its own `exec 9>&-`); since
  # `harness stop` never kills the poller, an inherited fd 9 would hold start.lock for the poller's
  # entire (fleet-outliving) life and wedge a later `start --recover` into launching ZERO workers —
  # the same leak class fixed for pool.sh/priority.sh. Closing it here covers every caller (start.sh
  # and the worker snapshot_gate) regardless of its own fd state.
  if [[ -n "${HARNESS_POLLER_CMD:-}" ]]; then
    nohup bash -c "$HARNESS_POLLER_CMD" >> "$HARNESS_POLLER_DIR/poller.log" 2>&1 9>&- &
  else
    nohup bash "$ENGINE_DIR/scripts/poller.sh" >> "$HARNESS_POLLER_DIR/poller.log" 2>&1 9>&- &
  fi
  echo "$!" > "$POLLER_PID"
  flock -u "$lockfd"; exec {lockfd}>&-
}

# --- PRD-B slice 3: wire workers to snapshots behind HARNESS_USE_POLLER (#72) -
# poller_enabled — does this fleet read the host poller's snapshots? ON unless HARNESS_USE_POLLER is
# explicitly off (#182: it was opt-in, no fleet opted in, and every worker polled GitHub itself). An
# EMPTY value — what every config written before #182 carries — means the default, i.e. ON.
poller_enabled(){ case "${HARNESS_USE_POLLER:-1}" in 0|off|OFF|false|FALSE|no|NO) return 1;; esac; return 0; }

# snapshot_slugs — the unique, owner-qualified slugs THIS project serves (single: HARNESS_REPO;
# multi: every targets row). Exactly the set `harness start` registers with the poller and the set
# the workers gate freshness on. Empty when single-topology HARNESS_REPO is blank (hermetic tests).
snapshot_slugs(){
  { if [[ "$HARNESS_TOPOLOGY" == single ]]; then _with_owner "$HARNESS_REPO"
    else local u; for u in $(all_units); do unit_slug "$u"; done; fi; } | awk 'NF && !seen[$0]++'
}

# poller_register_project — register every repo this project serves with the host poller, keyed on
# STATE_DIR (the refcount key) at this project's HARNESS_PRIORITY_POLL cadence and HARNESS_SESS_PREFIX.
# Idempotent (re-drops the same files). Called by `harness start` unless the poller is off (poller_enabled).
poller_register_project(){
  local slug
  for slug in $(snapshot_slugs); do
    poller_register "$slug" "$HARNESS_PRIORITY_POLL" "$HARNESS_SESS_PREFIX" "$STATE_DIR"
  done
}

# ensure_snapshot_fresh <slug> — is <slug>'s host snapshot present, of a KNOWN schema, and fresh
# (now - generated_at <= 3 × the slug's refresh cadence)? Returns 0 (fresh, ready to serve) or
# non-zero (missing/stale/unknown-schema/unreadable → HOLD). NEVER calls gh: the freshness verdict
# is a pure read of the snapshot file + the registry cadence. The refresh interval is the slug's
# effective registrant cadence (poller_cadence_for); 3× tolerates one missed poll cycle.
ensure_snapshot_fresh(){ local slug="$1"
  python3 "$ISSUELIB" snapshot-fresh "$(poller_snapshot_path "$slug")" "$(poller_cadence_for "$slug")" 2>/dev/null; }

# snapshot_gate — the PRD-B dispatch gate the pool + bug lane call before claiming. With
# the poller OFF (HARNESS_USE_POLLER=0) it is a NO-OP (returns 0; the caller keeps today's direct-gh path with no
# snapshot env). With it ON it (1) ensures the host poller is alive EVERY tick — so a killed
# poller self-heals within one tick (G3); (2) requires every repo this project serves to have a
# FRESH snapshot — any stale/missing/unknown-schema one returns non-zero so the caller HOLDS new
# dispatch (no claim, no gh fallback); (3) on success exports HARNESS_SNAPSHOT_FILE/_DIR so the
# issuelib reads behind claim/dispatch are served from the snapshots instead of GitHub. ensure_poller
# is intentionally called BEFORE the export, so the (re)launched poller child never inherits a stale
# HARNESS_SNAPSHOT_FILE — and poller_write_snapshot clears it anyway, belt and braces.
snapshot_gate(){
  poller_enabled || return 0
  ensure_poller
  local slugs slug; slugs="$(snapshot_slugs)"
  [[ -n "$slugs" ]] || return 0
  for slug in $slugs; do ensure_snapshot_fresh "$slug" || return 1; done
  export HARNESS_SNAPSHOT_DIR="$HARNESS_SNAPSHOTS_DIR"
  export HARNESS_SNAPSHOT_FILE="$(poller_snapshot_path "$(printf '%s\n' $slugs | head -n1)")"
  return 0
}

seed_if_needed(){
  local unit="$1" slug; slug="$(unit_slug "$unit")"
  if [[ "$HARNESS_TOPOLOGY" == single ]]; then
    bash "$ENGINE_DIR/scripts/seed.sh" --labels-only "$slug"
    bash "$ENGINE_DIR/scripts/seed.sh" --disable-ci "$slug"   # #245: seed.sh <unit> does this inline
  else
    bash "$ENGINE_DIR/scripts/seed.sh" "$unit"
    local co; co="$(unit_checkout "$unit")"
    [[ -d "$co/.git" ]] || git clone "https://github.com/$slug.git" "$co" 2>/dev/null || true
    ensure_safe "$co"
    run_worktree_hook "$co"   # a multi-topology clone is as bare as a worktree — provision it the same way
  fi
}

# --- checkpoint instruction + target (pause --force, #194 usage checkpoint) ---
# Build the one-line checkpoint instruction sent to a live agent. Single-quoted printf
# format keeps the literal backticks/markers from being command-substituted by THIS shell.
# An empty <branch> (a read-only triage session, #36) emits a no-push variant that still runs
# the handoff skill (skill/handoff, which setup and install.sh place for every CLI, #303) and flips
# agent-working → agent-paused, so the lane is never left orphaned.
_checkpoint_msg(){  # <issue> <slug> <branch> <working-label> <paused-label> [reason]
  local why="${6:-pause requested}" skill; skill="$(cli_skill handoff)"
  if [[ -n "$3" ]]; then
    printf 'HARNESS CHECKPOINT — %s. Stop now. Commit ALL work in progress and push your branch to origin. Then run the %s skill and post the handoff as a GitHub issue comment: gh issue comment %s -R %s --body-file <file>, whose FIRST line is exactly `<!-- harness-handoff issue=%s branch=%s -->`. Then swap labels: gh issue edit %s -R %s --remove-label %s --add-label %s. Do NOT merge or close the issue. Then output your completion promise and exit.' \
      "$why" "$skill" "$1" "$2" "$1" "$3" "$1" "$2" "$4" "$5"
  else
    printf 'HARNESS CHECKPOINT — %s. Stop now. You have no code branch to push (read-only phase). Run the %s skill and post the handoff as a GitHub issue comment: gh issue comment %s -R %s --body-file <file>, whose FIRST line is exactly `<!-- harness-handoff issue=%s -->`. Then swap labels: gh issue edit %s -R %s --remove-label %s --add-label %s. Do NOT merge or close the issue. Then output your completion promise and exit.' \
      "$why" "$skill" "$1" "$2" "$1" "$1" "$2" "$4" "$5"
  fi
}

# Parse a live session name into "<issue> <slug> <branch>" for the checkpoint, setting the
# globals _CP_ISSUE/_CP_SLUG/_CP_BRANCH. Two shapes (#36): impl sessions hz-<unit>-i<issue>
# (branch issue/<issue>), and priority-lane sessions hz-bug-<slug-sanitised>-<n>-(triage|fix) —
# the fix carries branch issue/<n>, triage has none (read-only). Returns 1 for an unrecognised
# session.
#
# The lane session carries the REPO (#44), but only sanitised (/ -> _), which can't be reversed
# unambiguously (owner_repo). So the real owner/repo is recovered from the live bug claim's stored
# token (third field), keyed by the same sanitised slug+number the session embeds. This is the
# routing fix: a colliding issue #N in another repo no longer mis-resolves via the lossy bug_repo
# rescan. A legacy bare session (hz-bug-<n>-(triage|fix)) still falls back to bug_repo.
_checkpoint_target(){  # <session>
  local sess="$1" issue unit phase
  local bug_re="^${HARNESS_SESS_PREFIX}-bug-(.+)-([0-9]+)-(triage|fix)$"
  local bug_bare_re="^${HARNESS_SESS_PREFIX}-bug-([0-9]+)-(triage|fix)$"
  if [[ "$sess" =~ $bug_re ]]; then
    local san="${BASH_REMATCH[1]}"; issue="${BASH_REMATCH[2]}"; phase="${BASH_REMATCH[3]}"
    local tok; tok="$(awk '{print $3; exit}' "$CLAIMS_DIR/bug-${san}-${issue}.claim" 2>/dev/null)"
    if [[ -n "$tok" ]]; then _CP_SLUG="$(_with_owner "$(_bug_ref_repo "$tok")")"
    else _CP_SLUG="$(_with_owner "$(bug_repo "$issue")")"; fi
    _CP_ISSUE="$issue"
    [[ "$phase" == fix ]] && _CP_BRANCH="issue/$issue" || _CP_BRANCH=""
    return 0
  fi
  if [[ "$sess" =~ $bug_bare_re ]]; then
    issue="${BASH_REMATCH[1]}"; phase="${BASH_REMATCH[2]}"
    _CP_ISSUE="$issue"; _CP_SLUG="$(_with_owner "$(bug_repo "$issue")")"
    [[ "$phase" == fix ]] && _CP_BRANCH="issue/$issue" || _CP_BRANCH=""
    return 0
  fi
  if [[ "$sess" =~ ^${HARNESS_SESS_PREFIX}-.*-i[0-9]+$ ]]; then
    issue="${sess##*-i}"
    unit="${sess#"$HARNESS_SESS_PREFIX"-}"; unit="${unit%-i$issue}"
    _CP_ISSUE="$issue"; _CP_SLUG="$(unit_slug "$unit")"; _CP_BRANCH="issue/$issue"
    return 0
  fi
  return 1
}

# #194 usage watch + checkpoint (needs the config above and the helpers in this file).
source "$(dirname "${BASH_SOURCE[0]}")/usage.sh"
source "$(dirname "${BASH_SOURCE[0]}")/ghrate.sh"
