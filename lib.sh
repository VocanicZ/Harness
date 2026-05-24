#!/usr/bin/env bash
# lib.sh — shared config + helpers for the Harness orchestrator.
set -uo pipefail
_HARNESS_LIB_SOURCED=1

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"
CONFIG="$HARNESS_DIR/config"
TARGETS_TSV="${TARGETS_TSV:-$HARNESS_DIR/targets.tsv}"
PROMPTS_DIR="$HARNESS_DIR/prompts"
RUN_DIR="${RUN_DIR:-$HARNESS_DIR/run}"
WORKTREES_DIR="$HARNESS_DIR/worktrees"
CHECKOUTS_DIR="$HARNESS_DIR/checkouts"

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
unit_complete(){ [[ "$(python3 "$HARNESS_DIR/issuelib.py" complete "$(unit_repo "$1")" 2>/dev/null)" == DONE ]]; }
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
_repo_bugs(){ python3 "$HARNESS_DIR/issuelib.py" bugs "$1" 2>/dev/null; }
# All repos' candidates as "<repo>#<num>" tokens, GLOBALLY fix-pending-first (#37): each repo's
# (num,phase) pairs are tagged with a phase sort-key (0=fix/pending, 1=triage/fresh) then stably
# sorted, so a pending fix in ANY repo drains before a fresh bug in ANY repo. Stable sort keeps
# same-phase candidates in their cross-repo input order.
_bug_numbers(){ local repo num phase
  for repo in $(_bug_repos); do
    [[ -n "$repo" ]] || continue
    _repo_bugs "$repo" | while IFS=$'\t' read -r num phase; do
      [[ -n "$num" ]] || continue
      printf '%s\t%s#%s\n' "$([[ "$phase" == fix ]] && echo 0 || echo 1)" "$repo" "$num"
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
claim_next_bug(){ local wid="$1" tok lockfd; exec {lockfd}>"$POOL_LOCK"; flock "$lockfd"
  tok="$(claimable_bugs | head -n1)"; [[ -n "$tok" ]] && printf '%s %s\n' "$wid" "$$" > "$CLAIMS_DIR/$(_bug_claim_key "$tok").claim"
  flock -u "$lockfd"; exec {lockfd}>&-; echo "$tok"; }

# lane_bug — the bug number the cap-1 priority lane currently holds (its live bug-<n>.claim),
# or empty when watching. Mirrors worker_unit for the pool; status.sh #35 renders it. Skips
# stale (dead-pid) claims via is_bug_claimed so a crashed lane never shows a phantom bug.
lane_bug(){ local f n; shopt -s nullglob
  for f in "$CLAIMS_DIR"/bug-*.claim; do n="$(basename "$f" .claim)"; n="${n#bug-}"
    is_bug_claimed "$n" && { echo "$n"; shopt -u nullglob; return; }
  done; shopt -u nullglob; }
# lane_phase <n> — the phase (triage|fix) of bug #n's live session, parsed from the
# hz-bug-<n>-<phase> tmux session (sess_bug); empty when no session is live.
lane_phase(){ local s; s="$(tmux ls -F '#S' 2>/dev/null | grep -m1 -E "^${HARNESS_SESS_PREFIX}-bug-$1-" || true)"
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

dispatch_actions(){ python3 "$HARNESS_DIR/issuelib.py" dispatch "$1" "$2" --allow-orchestration "$3"; }

# --- tmux session naming + ralph helpers -------------------------------------
sess_orch(){ echo "$HARNESS_SESS_PREFIX-$1"; }
sess_impl(){ echo "$HARNESS_SESS_PREFIX-$1-i$2"; }
sess_inject(){ echo "$HARNESS_SESS_PREFIX-inject-$1"; }
# Priority bug-lane session: <issue> <phase>. The phase suffix keeps triage and fix on
# DISTINCT sessions (separate session-ids / fresh context) for the same issue (#27).
sess_bug(){ echo "$HARNESS_SESS_PREFIX-bug-$1-$2"; }
team_sessions(){ tmux ls -F '#S' 2>/dev/null | grep -E "^$HARNESS_SESS_PREFIX-$1(\$|-i)" || true; }
count_team_sessions(){ team_sessions "$1" | grep -c . ; }
session_live(){ tmux has-session -t "$1" 2>/dev/null; }
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
  tmux send-keys -t "$sess" "exec $CLAUDE_BIN --session-id $uuid $CLAUDE_FLAGS \"\$(cat .harness-task.md)\"" Enter
  log "launched session $sess (cwd $wd)"; }

seed_if_needed(){
  local unit="$1" slug; slug="$(unit_slug "$unit")"
  if [[ "$HARNESS_TOPOLOGY" == single ]]; then
    bash "$HARNESS_DIR/seed.sh" --labels-only "$slug"
  else
    bash "$HARNESS_DIR/seed.sh" "$unit"
    local co; co="$(unit_checkout "$unit")"
    [[ -d "$co/.git" ]] || git clone "https://github.com/$slug.git" "$co" 2>/dev/null || true
    ensure_safe "$co"
  fi
}
