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
: "${HARNESS_CLAUDE_BIN:=claude}"
: "${HARNESS_CLAUDE_FLAGS:=--dangerously-skip-permissions --effort high}"
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

export HARNESS_MODE HARNESS_TOPOLOGY HARNESS_OWNER HARNESS_REPO HARNESS_SPEC HARNESS_AUTONOMOUS \
  HARNESS_LABEL_READY HARNESS_LABEL_PRD HARNESS_LABEL_WORKING HARNESS_LABEL_BLOCKED \
  HARNESS_LABEL_REVIEWED HARNESS_LABEL_COORD HARNESS_LABEL_PAUSED HARNESS_MAIN_REPO \
  HARNESS_LABEL_BUG HARNESS_LABEL_BUG_TRIAGED \
  HARNESS_AUTHOR_ALLOWLIST

OWNER="$HARNESS_OWNER"
CAP="$HARNESS_CAP"; POLL="$HARNESS_POLL"; POOL="$HARNESS_POOL"; PRIORITY_POLL="$HARNESS_PRIORITY_POLL"
IMPL_MAXITER="$HARNESS_IMPL_MAXITER"; ORCH_MAXITER="$HARNESS_ORCH_MAXITER"
CLAUDE_BIN="$HARNESS_CLAUDE_BIN"; CLAUDE_FLAGS="$HARNESS_CLAUDE_FLAGS"
CLAIMS_DIR="${CLAIMS_DIR:-$RUN_DIR/claims}"
POOL_LOCK="${POOL_LOCK:-$RUN_DIR/pool.lock}"
PAUSE_FLAG="${PAUSE_FLAG:-$RUN_DIR/PAUSED}"
mkdir -p "$RUN_DIR" "$WORKTREES_DIR" "$CHECKOUTS_DIR" "$CLAIMS_DIR" 2>/dev/null || true

log(){ printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "${UNIT:-harness}" "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ensure_safe(){ git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$1" || git config --global --add safe.directory "$1"; }
# ensure_trusted <dir> — pre-accept Claude Code's workspace-trust dialog for <dir> in ~/.claude.json
# so an autonomous (headless) launch in a never-trusted tree doesn't block FOREVER at the
# "Do you trust the files in this folder?" gate (#67). --dangerously-skip-permissions suppresses
# tool-permission prompts but NOT this separate workspace-trust gate, and the only bypass is
# non-interactive (-p) mode, which the harness can't use (launch_claude drives the interactive TUI).
# Mirrors ensure_safe: a small, idempotent, per-dir helper on the spawn path. Scoped to autonomous
# runs (consistent with the --dangerously-skip-permissions posture) — a supervised launch keeps
# Claude Code's default trust prompt. Atomic + race-safe (flock + tmp-file-and-rename) because
# multiple agents call launch_claude near-simultaneously. HARNESS_CLAUDE_CONFIG is a test seam; in
# production it is unset so the path is the real ~/.claude.json.
ensure_trusted(){
  [[ "${HARNESS_AUTONOMOUS:-true}" == true ]] || return 0
  local dir="$1" cfg="${HARNESS_CLAUDE_CONFIG:-$HOME/.claude.json}" lockfd
  exec {lockfd}>"$cfg.harness-trust.lock"; flock "$lockfd"
  CFG="$cfg" DIR="$dir" python3 - <<'PY'
import json, os, tempfile
cfg, d = os.environ["CFG"], os.environ["DIR"]
try:
    with open(cfg) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except (FileNotFoundError, ValueError):
    data = {}
projects = data.get("projects")
if not isinstance(projects, dict):
    projects = data["projects"] = {}
entry = projects.get(d)
if not isinstance(entry, dict):
    entry = projects[d] = {}
entry["hasTrustDialogAccepted"] = True
dirn = os.path.dirname(os.path.abspath(cfg)) or "."
os.makedirs(dirn, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".claude.json.harness.")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, cfg)
except BaseException:
    os.path.exists(tmp) and os.unlink(tmp)
    raise
PY
  flock -u "$lockfd"; exec {lockfd}>&-
}
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
  flock -u "$lockfd"; exec {lockfd}>&-; echo "$u"; }
release_claim(){ rm -f "$CLAIMS_DIR/$1.claim"; }
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

# lane_bug — the repo-qualified bug ref the cap-1 priority lane currently holds (its live
# bug-*.claim), or empty when watching. Returns the claim's stored token (third field) so it is
# the SAME "<owner>/<repo>#N" ref the lane claimed (#44) — never the lossy sanitised claim key,
# which can't be split back into owner/repo. Falls back to the stripped key for a legacy claim
# with no stored token (single-topology bare bug-<n>.claim). Mirrors worker_unit for the pool;
# status.sh #35 renders it. Skips stale (dead-pid) claims via is_bug_claimed so a crashed lane
# never shows a phantom bug.
lane_bug(){ local f tok n; shopt -s nullglob
  for f in "$CLAIMS_DIR"/bug-*.claim; do
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
# remove_worktree <checkout> <wd> [branch] — best-effort teardown of one worktree (+ optional local
# branch), then prune the registration. Tolerates a missing worktree/branch (idempotent). Falls
# back to rm -rf if `git worktree remove` can't (e.g. dir already gone). Shared by spawn_bug's
# defensive pre-add reap (branch omitted — `worktree add -B` resets it anyway), drive_bug's
# post-fix reap, and the recovery sweep, so all three tear down identically (#34).
remove_worktree(){ local checkout="$1" wd="$2" branch="${3:-}"
  git -C "$checkout" worktree remove --force "$wd" 2>/dev/null || rm -rf "$wd"
  [[ -n "$branch" ]] && git -C "$checkout" branch -D "$branch" 2>/dev/null || true
  git -C "$checkout" worktree prune 2>/dev/null || true; }
# sweep_orphan_bug_worktrees — crash/new-machine recovery (#34): the priority lane reaps its fix
# worktree in drive_bug, but only if the lane process survives. An unclean host exit kills the lane
# mid-fix, orphaning a bug-<slug>-i<n> worktree on disk; the next spawn_bug fix would then collide
# on `worktree add` (rc 128) and wedge the lane forever. So on recovery, remove every fix worktree
# whose fix session is dead, plus its local issue/<n> branch. Each worktree's owning checkout is
# derived from the worktree itself (--git-common-dir) so this works across single/multi topology.
# Skips a worktree whose fix session is still LIVE — safe to run while the fleet is up.
sweep_orphan_bug_worktrees(){ shopt -s nullglob; local wd n san base gcd co
  for wd in "$WORKTREES_DIR"/bug-*-i*; do
    [[ -d "$wd" ]] || continue
    n="${wd##*-i}"
    # Recover the sanitised slug from the worktree dir (bug-<slug-sanitised>-i<n>) so the fix
    # session name matches the repo-qualified sess_bug (#44). Passing the already-sanitised slug
    # back through sess_bug is idempotent (no '/' left to translate).
    base="${wd##*/}"; san="${base#bug-}"; san="${san%-i*}"
    session_live "$(sess_bug "$san" "$n" fix)" && continue
    gcd="$(git -C "$wd" rev-parse --git-common-dir 2>/dev/null)" || gcd=""
    co=""
    if [[ -n "$gcd" ]]; then
      [[ "$gcd" != /* ]] && gcd="$wd/$gcd"            # relative result → resolve against the worktree
      co="$(cd "$(dirname "$gcd")" 2>/dev/null && pwd)"
    fi
    if [[ -n "$co" ]]; then remove_worktree "$co" "$wd" "issue/$n"; else rm -rf "$wd"; fi
    echo "  removed orphan bug worktree $(basename "$wd") (#$n — no live fix session)"
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

dispatch_actions(){ python3 "$ISSUELIB" dispatch "$1" "$2" --allow-orchestration "$3"; }

# --- tmux session naming + ralph helpers -------------------------------------
sess_orch(){ echo "$HARNESS_SESS_PREFIX-$1"; }
sess_impl(){ echo "$HARNESS_SESS_PREFIX-$1-i$2"; }
sess_inject(){ echo "$HARNESS_SESS_PREFIX-inject-$1"; }
# Priority bug-lane session: <slug> <issue> <phase>. The slug (sanitised / -> _) is embedded so
# the session name carries the REPO (#44): issue numbers are per-repo, so in `multi` two repos can
# each hold a bug #N — a bare-number session collided, and every deriver that re-parsed it
# (lane_phase, _checkpoint_target, sweep_orphan_bug_worktrees) lost the repo. The <phase> suffix
# keeps triage and fix on DISTINCT sessions (separate session-ids / fresh context) for the same
# issue (#27). The sanitised-slug-and-number segment matches the bug claim key (_bug_claim_key).
sess_bug(){ echo "$HARNESS_SESS_PREFIX-bug-$(printf '%s' "$1" | tr '/' '_')-$2-$3"; }
team_sessions(){ tmux ls -F '#S' 2>/dev/null | grep -E "^$HARNESS_SESS_PREFIX-$1(\$|-i)" || true; }
count_team_sessions(){ team_sessions "$1" | grep -c . ; }
session_live(){ tmux has-session -t "$1" 2>/dev/null; }
# bug_session_live <slug> <n> — is EITHER phase's session for bug #n in <slug> live? The SINGLE
# liveness predicate the lane's per-poll reap (#42, reap_lane) and start --recover's bug-aware skip
# (#43) both use, so the two reconciliation paths can never disagree about whether a bug is in
# flight. The slug is REQUIRED: sess_bug embeds the repo (#44), so the session name can't be rebuilt
# from the issue number alone — both callers already hold the slug and pass it. A bug whose session
# is live is NEVER swept — neither path strips its agent-working nor reaps its worktree.
bug_session_live(){ session_live "$(sess_bug "$1" "$2" triage)" || session_live "$(sess_bug "$1" "$2" fix)"; }
render(){ local tmpl="$1"; shift; python3 - "$tmpl" "$@" <<'PY'
import sys, re
tmpl = open(sys.argv[1]).read()
kv = dict(a.split('=', 1) for a in sys.argv[2:])
sys.stdout.write(re.sub(r'{{(\w+)}}', lambda m: kv.get(m.group(1), m.group(0)), tmpl))
PY
}
write_state(){ local wd="$1" promise="$2" maxiter="$3" uuid="$4"; mkdir -p "$wd/.claude"
  { printf -- '---\nactive: true\niteration: 1\nsession_id: %s\nmax_iterations: %s\ncompletion_promise: "%s"\nstarted_at: "%s"\n---\n\n' \
      "$uuid" "$maxiter" "$promise" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; cat "$wd/.harness-task.md"
  } > "$wd/.claude/ralph-loop.local.md"; }
launch_claude(){ local sess="$1" wd="$2" uuid; uuid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
  write_state "$wd" "$PROMISE" "$MAXITER" "$uuid"; echo "${GOAL:-?}" > "$RUN_DIR/$sess.goal"
  tmux new-session -d -s "$sess" -c "$wd"; sleep 1.5
  ensure_trusted "$wd"   # #67: pre-accept the workspace-trust dialog so a fresh tree doesn't stall here
  tmux send-keys -t "$sess" "exec $CLAUDE_BIN --session-id $uuid $CLAUDE_FLAGS \"\$(cat .harness-task.md)\"" Enter
  log "launched session $sess (cwd $wd)"; }

seed_if_needed(){
  local unit="$1" slug; slug="$(unit_slug "$unit")"
  if [[ "$HARNESS_TOPOLOGY" == single ]]; then
    bash "$ENGINE_DIR/scripts/seed.sh" --labels-only "$slug"
  else
    bash "$ENGINE_DIR/scripts/seed.sh" "$unit"
    local co; co="$(unit_checkout "$unit")"
    [[ -d "$co/.git" ]] || git clone "https://github.com/$slug.git" "$co" 2>/dev/null || true
    ensure_safe "$co"
  fi
}
