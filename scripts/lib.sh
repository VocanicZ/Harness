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
: "${HARNESS_USE_POLLER:=}"            # PRD-B (#72): empty = today's direct-gh polling; set = read host snapshots
: "${HARNESS_PREFIX_COLLISION:=refuse}"  # PRD-B slice 4 (#73): refuse|warn — start-time guard when another active fleet's session prefix collides
: "${HARNESS_STALL_RETRIES:=3}"          # #115: consecutive stalled polls before the watchdog kills a wedged session
: "${HARNESS_LIMIT_NUDGE_EVERY:=5}"      # #120: re-nudge a quota-parked session every Nth poll (never killed — the quota returns on its own)
: "${HARNESS_WORKTREE_HOOK:=}"           # optional project script run in every fresh worktree after `worktree add`
: "${HARNESS_GAUNTLET_ROUNDS:=3}"        # gauntlet review: rounds allowed before the reviewer concedes
: "${HARNESS_CI_GATE:=1}"                # #50: 1 = hold unit dispatch while the default branch's CI is red; 0 = off

export HARNESS_MODE HARNESS_TOPOLOGY HARNESS_OWNER HARNESS_REPO HARNESS_SPEC HARNESS_AUTONOMOUS \
  HARNESS_LABEL_READY HARNESS_LABEL_PRD HARNESS_LABEL_WORKING HARNESS_LABEL_BLOCKED \
  HARNESS_LABEL_REVIEWED HARNESS_LABEL_COORD HARNESS_LABEL_PAUSED HARNESS_MAIN_REPO \
  HARNESS_LABEL_BUG HARNESS_LABEL_BUG_TRIAGED \
  HARNESS_AUTHOR_ALLOWLIST HARNESS_USE_POLLER HARNESS_PREFIX_COLLISION HARNESS_WORKTREE_HOOK \
  HARNESS_GAUNTLET_ROUNDS HARNESS_CI_GATE

OWNER="$HARNESS_OWNER"
CAP="$HARNESS_CAP"; POLL="$HARNESS_POLL"; POOL="$HARNESS_POOL"; PRIORITY_POLL="$HARNESS_PRIORITY_POLL"
IMPL_MAXITER="$HARNESS_IMPL_MAXITER"; ORCH_MAXITER="$HARNESS_ORCH_MAXITER"
CLAUDE_BIN="$HARNESS_CLAUDE_BIN"; CLAUDE_FLAGS="$HARNESS_CLAUDE_FLAGS"
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
# ensure_trusted <dir> — pre-accept Claude Code's workspace-trust dialog for <dir> in ~/.claude.json
# so an autonomous (headless) launch in a never-trusted tree doesn't block FOREVER at the
# "Do you trust the files in this folder?" gate (#67). --dangerously-skip-permissions suppresses
# tool-permission prompts but NOT this separate workspace-trust gate, and the only bypass is
# non-interactive (-p) mode, which the harness can't use (launch_claude drives the interactive TUI).
# Mirrors ensure_safe: a small, idempotent, per-dir helper on the spawn path. Scoped to autonomous
# runs (consistent with the --dangerously-skip-permissions posture) — a supervised launch keeps
# Claude Code's default trust prompt. Atomic + race-safe (flock + tmp-file-and-rename) because
# multiple agents call launch_claude near-simultaneously. HARNESS_CLAUDE_CONFIG is a test seam; in
# production it is unset and ensure_trusted picks the targets itself (see below).
#
# WHICH FILE: Claude Code reads workspace trust from $CLAUDE_CONFIG_DIR/.claude.json when that var is
# set, else ~/.claude.json. Writing only ~/.claude.json silently stopped working once the claude-acc
# account switcher was installed: ~/.bashrc exports CLAUDE_CONFIG_DIR=~/.claude-switch/accounts/<acct>
# in EVERY interactive bash, including the one `tmux new-session` opens for the lane, so the pane
# reads the per-account config while the pre-accept landed in ~/.claude.json — and #67's forever-block
# came back on every new worktree. We cannot resolve the account here: it is chosen AFTER we run, by
# the pane's .bashrc, and the pool worker carries no CLAUDE_CONFIG_DIR of its own (nor can we cache a
# decision — `claude-acc default` may be flipped between spawn and launch). So seed every config the
# pane could possibly read; an entry in a config the pane never opens is inert.
# _trust_config <cfg> <dir> — merge the trust flag for <dir> into one config file. Atomic + flocked.
_trust_config(){
  local dir="$2" cfg="$1" lockfd
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
ensure_trusted(){
  [[ "${HARNESS_AUTONOMOUS:-true}" == true ]] || return 0
  local dir="$1" acct
  # test seam: an explicit config is authoritative and stays single-file (never touches a real $HOME)
  if [[ -n "${HARNESS_CLAUDE_CONFIG:-}" ]]; then _trust_config "$HARNESS_CLAUDE_CONFIG" "$dir"; return 0; fi
  _trust_config "$HOME/.claude.json" "$dir"                       # no switcher, or switcher not active yet
  if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then                      # a worker that DID inherit a config dir
    _trust_config "$CLAUDE_CONFIG_DIR/.claude.json" "$dir"
  fi
  for acct in "$HOME"/.claude-switch/accounts/*/; do              # every claude-acc account the pane may pick
    [[ -d "$acct" ]] || continue                                  # unmatched glob stays literal — skip it
    _trust_config "$acct.claude.json" "$dir"
  done
  return 0
}
# ensure_bypass <dir> — default the spawned session AND its sub-agents to bypassPermissions by merging
# permissions.defaultMode into <dir>/.claude/settings.local.json. --dangerously-skip-permissions only
# sets the MAIN session's mode; Task/sub-agents (subagent-driven-development) do NOT inherit it and
# fall back to "default" (ask) mode, wedging an autonomous run FOREVER on the first mutating-command
# prompt (no human to answer). settings.local.json is read by the session + its sub-agents (cwd-scoped)
# and is git-ignored by convention; we also add it to the worktree's info/exclude so `git add -A` can
# never commit it on installs lacking that global ignore. Scoped to autonomous runs, mirroring
# ensure_trusted. No flock: each session owns a unique <dir>, so there's no shared-file race.
ensure_bypass(){
  [[ "${HARNESS_AUTONOMOUS:-true}" == true ]] || return 0
  local dir="$1" f="$1/.claude/settings.local.json"
  mkdir -p "$dir/.claude"
  F="$f" python3 - <<'PY'
import json, os, tempfile
f = os.environ["F"]
try:
    with open(f) as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        data = {}
except (FileNotFoundError, ValueError):
    data = {}
perms = data.get("permissions")
if not isinstance(perms, dict):
    perms = data["permissions"] = {}
perms["defaultMode"] = "bypassPermissions"
d = os.path.dirname(f) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings.harness.")
try:
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=2)
    os.replace(tmp, f)
except BaseException:
    os.path.exists(tmp) and os.unlink(tmp)
    raise
PY
  local excl; excl="$(git -C "$dir" rev-parse --git-path info/exclude 2>/dev/null)" || return 0
  [[ -n "$excl" ]] || return 0
  mkdir -p "$(dirname "$excl")"
  grep -qxF '.claude/settings.local.json' "$excl" 2>/dev/null || echo '.claude/settings.local.json' >> "$excl"
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

dispatch_actions(){ python3 "$ISSUELIB" dispatch "$1" "$2" --allow-orchestration "$3" --busy-prds "${4:-}"; }

# --- default-branch CI gate (#50) --------------------------------------------
# ci_status_default_branch <slug> — `<verdict>\t<workflow>\t<url>`, verdict ∈ pass|fail|unknown.
# THIS IS THE SEAM tests override (mirrors _repo_bugs / unit_complete); everything below reads the
# verdict through it, so no test needs a live gh or a real Actions run.
ci_status_default_branch(){ python3 "$ISSUELIB" ci-status "$1" 2>/dev/null; }

# ci_gate_ok <slug> — may the pool dispatch NEW work for <slug> right now? 0 = yes.
#
# Non-zero ONLY on a positively-red default branch, because a fleet that halts on uncertainty is
# worse than one that merges a bad commit: every other verdict (unknown / no Actions / gh outage /
# empty output from a HOLD exit) returns 0. HARNESS_CI_GATE=0 disables it outright.
#
# The remedy path is deliberately NOT gated: the priority bug lane claims through a red branch, so
# filing a `bug` issue is how a fleet digs itself out. Nothing here touches live sessions either —
# in-flight work drains normally, exactly like a pause.
ci_gate_ok(){ local slug="$1" verdict wf url
  [[ "$HARNESS_CI_GATE" == 0 ]] && return 0
  IFS=$'\t' read -r verdict wf url < <(ci_status_default_branch "$slug")
  [[ "${verdict:-unknown}" == fail ]] || return 0
  ci_gate_log "$slug" "$wf" "$url"; return 1; }

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
  shopt -s nullglob
  for f in "$RUN_DIR"/*.goal; do
    sess="$(basename "$f" .goal)"
    session_live "$sess" || rm -f "$f" "$RUN_DIR/$sess.wd"
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
  [[ -f "$wd/.claude/ralph-loop.local.md" ]] && return 0   # loop still active → leave it
  log "reaped finished inject session $sess (ralph loop ended)"
  tmux kill-session -t "$sess" 2>/dev/null || true
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
# Transient-API-error markers as they appear in the TUI pane. Matched only IN COMBINATION with the
# idle `❯` prompt + the absence of an active spinner, so an in-scrollback string alone never trips it.
HARNESS_STALL_ERROR_RE='API Error|[Oo]verloaded|overloaded_error|rate.?limit|(^|[^0-9])(429|500|502|503|529)([^0-9]|$)'
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
# Matched on the stable tail of the hint so a change to the key prefix does not reopen this.
HARNESS_ACTIVE_TURN_RE='esc to interrupt|to run in background'
session_active_turn(){ printf '%s' "$1" | grep -qE "$HARNESS_ACTIVE_TURN_RE"; }
session_stalled(){ local pane="$1"
  session_active_turn "$pane" && return 1                         # active turn → never stalled
  printf '%s' "$pane" | grep -qF '❯' || return 1                  # no idle prompt → not parked
  printf '%s' "$pane" | grep -qE "$HARNESS_STALL_ERROR_RE"; }      # …and a transient-error marker
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
HARNESS_LIMIT_MENU_RE='Stop and wait for limit to reset'
# Credit exhaustion ("You're out of usage credits. Run /usage-credits to keep using <model> or /model
# to switch models.") is the SAME class as a limit park and must be listed here: it too aborts the turn
# and drops the pane to idle ❯, but it matched none of the limit alternatives, so it fell through to
# the #115 stall path and the session was nudged ×K then KILLED — and every re-dispatch re-provisions
# a worktree and dies again instantly, burning the lane in a loop for as long as the account is dry.
HARNESS_LIMIT_IDLE_RE="hit your [a-z]+ limit|usage limit reached|limit reached · resets|approaching (your )?usage limit|out of usage credits|out of credits"
# session_limit_menu <pane-text> — true iff the pane is BLOCKED on the interactive limit menu.
session_limit_menu(){ printf '%s' "$1" | grep -qE "$HARNESS_LIMIT_MENU_RE"; }
# session_limit_idle <pane-text> — true iff a limit-aborted turn left the pane at the idle `❯`.
session_limit_idle(){ local pane="$1"
  session_active_turn "$pane" && return 1                         # active turn → not parked
  printf '%s' "$pane" | grep -qF '❯' || return 1                  # no idle prompt → not parked
  printf '%s' "$pane" | grep -qE "$HARNESS_LIMIT_IDLE_RE"; }
# _watchdog_limit_pick <sess> — answer the blocking menu with its default choice ("stop and wait for
# limit to reset"). A bare Enter, never a typed line: the pane is a menu, not a prompt.
_watchdog_limit_pick(){ tmux send-keys -t "$1" Enter 2>/dev/null || true; }
# _watchdog_limit_nudge <sess> — re-submit a continue once the quota is back. Same live-pane
# send-keys pattern as _watchdog_nudge (#108 guard honoured: a plain line, never `exec claude …`).
_watchdog_limit_nudge(){ local sess="$1"
  tmux send-keys -t "$sess" -l "Please continue — the usage limit has reset; resume the in-flight task where you left off." 2>/dev/null || true
  tmux send-keys -t "$sess" Enter 2>/dev/null || true; }
# _watchdog_nudge <sess> — re-submit a continue into a session this watchdog has classified STALLED,
# so the agent resumes its preserved in-flight context now the transient error has cleared. Uses the
# exact send-keys-into-a-live-pane pattern as pause.sh:82-83. It NEVER types a second `exec claude …`
# (honours the #108 live-session guard) — only a plain continue line — and is only ever reached from
# watchdog_session AFTER session_stalled is true, so a healthy/busy pane is never typed into.
_watchdog_nudge(){ local sess="$1"
  tmux send-keys -t "$sess" -l "Please continue — the transient API error has cleared; resume the in-flight task." 2>/dev/null || true
  tmux send-keys -t "$sess" Enter 2>/dev/null || true; }
# watchdog_session <sess> — examine ONE live session for the #115 wedge and recover it. State (the
# count of CONSECUTIVE stalled polls) lives in $RUN_DIR/<sess>.stall and is cleared the instant the
# session is no longer stalled (recovered/busy/dead) — so a session that resumes after a nudge starts
# any LATER stall from zero. On each stalled poll, nudge; once the count reaches HARNESS_STALL_RETRIES
# the session is killed so the existing reap → re-dispatch path (reap_team / reap_lane) frees the slot
# and the next poll re-claims the issue. A non-live session is a no-op (its counter is GC'd).
watchdog_session(){ local sess="$1" stallf="$RUN_DIR/$1.stall" limitf="$RUN_DIR/$1.limit" pane n
  session_live "$sess" || { rm -f "$stallf" "$limitf"; return 0; }
  pane="$(tmux capture-pane -p -t "$sess" 2>/dev/null)" || { rm -f "$stallf" "$limitf"; return 0; }
  # #120 quota park — checked FIRST and never killed; see session_limit_menu/_idle above.
  if session_limit_menu "$pane"; then
    rm -f "$stallf"
    log "watchdog: $sess blocked on the usage-limit menu — answering 'wait for reset' (#120)"
    _watchdog_limit_pick "$sess"; return 0
  fi
  if session_limit_idle "$pane"; then
    rm -f "$stallf"
    n=$(( $(cat "$limitf" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$limitf"
    if (( n == 1 || n % HARNESS_LIMIT_NUDGE_EVERY == 0 )); then
      log "watchdog: $sess parked at idle ❯ by the usage limit (poll $n) — nudging to resume (#120)"
      _watchdog_limit_nudge "$sess"
    fi
    return 0
  fi
  rm -f "$limitf"
  if ! session_stalled "$pane"; then rm -f "$stallf"; return 0; fi
  n=$(( $(cat "$stallf" 2>/dev/null || echo 0) + 1 ))
  if (( n >= HARNESS_STALL_RETRIES )); then
    log "watchdog: $sess wedged at idle ❯ after a transient API error for $n polls — killing for reap → re-dispatch (#115)"
    tmux kill-session -t "$sess" 2>/dev/null || true
    rm -f "$stallf"
  else
    echo "$n" > "$stallf"
    log "watchdog: $sess wedged at idle ❯ after a transient API error (poll $n/$HARNESS_STALL_RETRIES) — nudging to resume (#115)"
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
# own prefix contains a dash (`my-app-main-i1` -> `my`), but the under-read is sound rather than
# approximate: a shorter prefix owns strictly MORE of the namespace, so if `my` collides with ours so
# does `my-app`, and if it does not then `my-app-…` lies outside our space anyway. No genuine
# collision is missed and no false one is introduced.
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
  done < <(tmux ls -F '#{session_name}'$'\t''#{session_path}' 2>/dev/null || true)
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

# check_prefix_collision — start-time guard. Refuse (or warn) when another ACTIVE fleet's session
# prefix collides with ours. Reads slice 2's registry (poller_registry_prefixes); a single /
# non-colliding fleet sees an empty list and proceeds (no behavior change). HARNESS_PREFIX_COLLISION:
# `refuse` (default) dies; `warn` prints to stderr and continues.
check_prefix_collision(){
  local pfx prj hit=""
  while IFS=$'\t' read -r pfx prj; do
    [[ -n "$pfx" ]] || continue
    if prefixes_collide "$HARNESS_SESS_PREFIX" "$pfx"; then hit="$pfx ($prj)"; break; fi
  done < <(poller_registry_prefixes "$STATE_DIR")
  [[ -n "$hit" ]] || return 0
  local msg="session prefix '$HARNESS_SESS_PREFIX' collides with active fleet prefix $hit — set a distinct HARNESS_SESS_PREFIX (or HARNESS_PREFIX_COLLISION=warn to override)"
  case "${HARNESS_PREFIX_COLLISION:-refuse}" in
    warn) printf 'WARNING: %s\n' "$msg" >&2; return 0;;
    *)    die "$msg";;
  esac
}
render(){ local tmpl="$1"; shift; python3 - "$tmpl" "$@" <<'PY'
import sys, re
tmpl = open(sys.argv[1]).read()
kv = dict(a.split('=', 1) for a in sys.argv[2:])
sys.stdout.write(re.sub(r'{{(\w+)}}', lambda m: kv.get(m.group(1), m.group(0)), tmpl))
PY
}
# gauntlet_round <prd> — echo the gauntlet round this review pass will run (1-based).
# Round state is the PRD's own comment stream: every LOST round leaves a
# `<!-- harness-gauntlet round=N -->` marker (see prompts/review.md). Nothing on disk, so a
# resume on another host picks up at the right round. ANY failure — offline, rate limit, junk
# on stdout — counts as zero markers and returns round 1: a transient gh error must never be
# able to push the reviewer past the cap and fake a concede.
gauntlet_round(){ local prd="$1" n
  n="$(gh issue view "$prd" -R "$SLUG" --json comments \
       -q '[.comments[].body | select(test("<!-- harness-gauntlet round="))] | length' 2>/dev/null || echo 0)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  echo $(( n + 1 )); }
write_state(){ local wd="$1" promise="$2" maxiter="$3" uuid="$4"; mkdir -p "$wd/.claude"
  { printf -- '---\nactive: true\niteration: 1\nsession_id: %s\nmax_iterations: %s\ncompletion_promise: "%s"\nstarted_at: "%s"\n---\n\n' \
      "$uuid" "$maxiter" "$promise" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; cat "$wd/.harness-task.md"
  } > "$wd/.claude/ralph-loop.local.md"; }
launch_claude(){ local sess="$1" wd="$2" uuid
  # #108: never re-enter a live session. If $sess is already up (e.g. a transiently-dropped
  # agent-working label re-dispatched the same issue), short-circuit BEFORE any side effect — no
  # write_state (don't clobber the running agent's state file), no new-session, and above all no
  # send-keys typing a second `exec claude …` into the live pane. This guard MUST be first.
  if session_live "$sess"; then log "session $sess already live — skipping re-dispatch"; return 0; fi
  uuid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
  write_state "$wd" "$PROMISE" "$MAXITER" "$uuid"
  tmux new-session -d -s "$sess" -c "$wd"; sleep 1.5
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
  tmux send-keys -t "$sess" "exec $CLAUDE_BIN --session-id $uuid $CLAUDE_FLAGS \"\$(cat .harness-task.md)\"" Enter
  log "launched session $sess (cwd $wd)"; }

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
poller_write_snapshot(){
  local slug="$1" out tmp
  mkdir -p "$HARNESS_SNAPSHOTS_DIR"
  out="$(poller_snapshot_path "$slug")"; tmp="$out.tmp.$$"
  if HARNESS_SNAPSHOT_FILE= HARNESS_SNAPSHOT_DIR= python3 "$ISSUELIB" snapshot "$slug" > "$tmp" 2>/dev/null \
     && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$out"; return 0
  fi
  rm -f "$tmp"; return 1
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
# snapshot_slugs — the unique, owner-qualified slugs THIS project serves (single: HARNESS_REPO;
# multi: every targets row). Exactly the set `harness start` registers with the poller and the set
# the workers gate freshness on. Empty when single-topology HARNESS_REPO is blank (hermetic tests).
snapshot_slugs(){
  { if [[ "$HARNESS_TOPOLOGY" == single ]]; then _with_owner "$HARNESS_REPO"
    else local u; for u in $(all_units); do unit_slug "$u"; done; fi; } | awk 'NF && !seen[$0]++'
}

# poller_register_project — register every repo this project serves with the host poller, keyed on
# STATE_DIR (the refcount key) at this project's HARNESS_PRIORITY_POLL cadence and HARNESS_SESS_PREFIX.
# Idempotent (re-drops the same files). Called by `harness start` only when HARNESS_USE_POLLER is set.
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
# HARNESS_USE_POLLER UNSET it is a NO-OP (returns 0; the caller keeps today's direct-gh path with no
# snapshot env). With the flag SET it (1) ensures the host poller is alive EVERY tick — so a killed
# poller self-heals within one tick (G3); (2) requires every repo this project serves to have a
# FRESH snapshot — any stale/missing/unknown-schema one returns non-zero so the caller HOLDS new
# dispatch (no claim, no gh fallback); (3) on success exports HARNESS_SNAPSHOT_FILE/_DIR so the
# issuelib reads behind claim/dispatch are served from the snapshots instead of GitHub. ensure_poller
# is intentionally called BEFORE the export, so the (re)launched poller child never inherits a stale
# HARNESS_SNAPSHOT_FILE — and poller_write_snapshot clears it anyway, belt and braces.
snapshot_gate(){
  [[ -n "${HARNESS_USE_POLLER:-}" ]] || return 0
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
  else
    bash "$ENGINE_DIR/scripts/seed.sh" "$unit"
    local co; co="$(unit_checkout "$unit")"
    [[ -d "$co/.git" ]] || git clone "https://github.com/$slug.git" "$co" 2>/dev/null || true
    ensure_safe "$co"
    run_worktree_hook "$co"   # a multi-topology clone is as bare as a worktree — provision it the same way
  fi
}
