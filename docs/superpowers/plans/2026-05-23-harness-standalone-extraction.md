# Harness Standalone Extraction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract Bonsai's in-repo `harness/` into a standalone, public, project-agnostic agent orchestrator (`Harness`) installable into any project via `curl | bash`, supporting 3 pipeline modes and single/multi-repo topologies.

**Architecture:** A fixed pool of workers claims dependency-ready *units* (one repo in single topology; DAG targets in multi), drives each through a GitHub-issue state machine to COMPLETE, releases, repeats. Mode (`issue-only`/`prd`/`planned`) gates which orchestration actions the dispatcher emits; topology selects the unit registry. State lives 100% in GitHub + a small local run dir. Built by porting Bonsai's `harness/` and generalizing.

**Tech Stack:** Bash (engine + CLI), Python 3 stdlib (state machine `issuelib.py`), `gh` CLI (GitHub), `tmux` + `claude` (agent sessions), plain-bash assertion test rig.

**Reference source (the origin to port from):** `/media/nathanielsong/Sata Programming/IdeaProjects/Bonsai/harness/` — referred to below as `$SRC`. Spec: `docs/superpowers/specs/2026-05-23-harness-standalone-extraction-design.md`.

**Naming contract (use these exact names everywhere):**
- Env prefix `HARNESS_*`; session prefix `hz` (configurable `HARNESS_SESS_PREFIX`).
- Registry file `targets.tsv`; var `TARGETS_TSV`.
- Functions: `all_units`, `unit_repo`, `unit_deps`, `unit_desc`, `unit_slug`, `unit_checkout`, `unit_complete`, `deps_complete`, `all_complete`, `is_claimed`, `clear_stale_claims`, `claimable_units`, `claim_next`, `release_claim`, `worker_unit`, `dispatch_actions`, `seed_if_needed`, `drive_unit`, `reap_team`, `reap_done_sessions`, `spawn_orch`, `spawn_impl`, `sess_orch`, `sess_impl`, `team_sessions`, `count_team_sessions`, `session_live`, `render`, `write_state`, `launch_claude`.
- Prompt template keys: `{{PROJECT}} {{DESC}} {{SLUG}} {{OWNER}} {{SPEC}} {{PRD}} {{ISSUE}} {{BRANCH}} {{PROMISE}}`.

**Where to build:** this repo — `/media/nathanielsong/Sata Programming/VSCode/Harness`. It is already created with `git init` done; you work in the repo root. All paths below are relative to the repo root unless prefixed `$SRC`.

---

## File Structure

```
Harness/
├── bin/harness            # CLI dispatcher: init|start|stop|status|attach
├── lib.sh                 # config loader + registry/topology + claim + tmux/ralph helpers
├── issuelib.py            # GitHub-issue state machine: dispatch/status/complete/check
├── drive.sh               # drive_unit + spawn_orch/spawn_impl + reapers
├── pool.sh                # launch HARNESS_POOL workers
├── pool-worker.sh         # one worker: claim→seed→drive→release→repeat→retire
├── seed.sh                # idempotent repo bootstrap: labels, CI, auto-merge
├── start.sh stop.sh status.sh attach.sh   # operations
├── install.sh             # curl|bash bootstrap: prereqs, skills, clone, init
├── prompts/{plan,prd,decompose,impl,review}.md
├── skill/SKILL.md         # the /harness management skill
├── test/{run.sh,helpers.sh,test_*.sh}
├── .gitignore
└── README.md
```

**Local-state contract (set in `lib.sh`):**
- `HARNESS_DIR` = dir of `lib.sh` (the `.harness/` checkout). `PROJECT_ROOT` = `$HARNESS_DIR/..`.
- `CONFIG=$HARNESS_DIR/config`, `TARGETS_TSV=$HARNESS_DIR/targets.tsv`, `PROMPTS_DIR=$HARNESS_DIR/prompts`.
- `RUN_DIR=$HARNESS_DIR/run`, `WORKTREES_DIR=$HARNESS_DIR/worktrees`, `CHECKOUTS_DIR=$HARNESS_DIR/checkouts`.
- `CLAIMS_DIR=$RUN_DIR/claims`, `POOL_LOCK=$RUN_DIR/pool.lock`.
- `unit_checkout <id>`: single topology → `$PROJECT_ROOT`; multi → `$CHECKOUTS_DIR/<repo-name>`.

**Config-override contract:** the wizard writes config lines in `: "${KEY:=value}"` form, so `source "$CONFIG"` only sets unset vars → **pre-existing environment overrides the file**. `lib.sh` then `export`s every `HARNESS_*` so `issuelib.py` reads them via `os.environ`.

---

### Task 1: Scaffold the repo + test runner

**Files:**
- Create: `.gitignore`, `test/run.sh`, `test/helpers.sh`, `test/test_scaffold.sh`

- [ ] **Step 1: Ensure repo dirs exist** (repo + `git init` already done at the path in the header)

```bash
mkdir -p bin prompts skill test
```

- [ ] **Step 2: Write `.gitignore`** (local per-project state must never be committed to the engine repo)

```gitignore
# per-project local state (written by `harness init` / runtime)
/config
/targets.tsv
/run/
/worktrees/
/checkouts/
/prompts/*.local.md
__pycache__/
*.pyc
```

- [ ] **Step 3: Port the test runner** — copy `$SRC/test/run.sh` verbatim to `test/run.sh` (it is project-agnostic already).

- [ ] **Step 4: Write `test/helpers.sh`** (ported from `$SRC/test/helpers.sh`, renamed `team_complete`→`unit_complete`, `MODULES_TSV`→`TARGETS_TSV`)

```bash
#!/usr/bin/env bash
# helpers.sh — minimal bash test rig + temp-env setup for the harness pool logic.
# Sourced by test_*.sh AFTER sourcing ../lib.sh (and ../drive.sh where needed).
# Overrides unit_complete so tests control "which units are COMPLETE" without GitHub.
TESTS_RUN=0; TESTS_FAIL=0
assert_eq(){ TESTS_RUN=$((TESTS_RUN+1)); if [[ "$1" == "$2" ]]; then echo "  ok: $3"; else echo "  FAIL: $3 — want [$2] got [$1]"; TESTS_FAIL=$((TESTS_FAIL+1)); fi; }
assert_ok(){ local msg="$1"; shift; TESTS_RUN=$((TESTS_RUN+1)); if "$@"; then echo "  ok: $msg"; else echo "  FAIL: $msg — expected success from: $*"; TESTS_FAIL=$((TESTS_FAIL+1)); fi; }
assert_no(){ local msg="$1"; shift; TESTS_RUN=$((TESTS_RUN+1)); if "$@"; then echo "  FAIL: $msg — expected failure from: $*"; TESTS_FAIL=$((TESTS_FAIL+1)); else echo "  ok: $msg"; fi; }
finish(){ echo "── $((TESTS_RUN-TESTS_FAIL))/$TESTS_RUN passed"; [[ $TESTS_FAIL -eq 0 ]]; }
make_env(){
  RUN_DIR="$(mktemp -d)"; CLAIMS_DIR="$RUN_DIR/claims"; POOL_LOCK="$RUN_DIR/pool.lock"; mkdir -p "$CLAIMS_DIR"
  TARGETS_TSV="$(mktemp)"; COMPLETE_SET="$(mktemp)"; POLL=0
  HARNESS_TOPOLOGY=multi   # tests that feed targets.tsv use multi; single-topology tests set it themselves
  unit_complete(){ grep -qxF "$1" "$COMPLETE_SET" 2>/dev/null; }
}
write_targets(){ cat > "$TARGETS_TSV"; }
set_complete(){ printf '%s\n' "$@" > "$COMPLETE_SET"; [[ $# -eq 0 ]] && : > "$COMPLETE_SET"; }
unit_complete(){ grep -qxF "$1" "$COMPLETE_SET" 2>/dev/null; }
```

- [ ] **Step 5: Write a smoke test** `test/test_scaffold.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
assert_eq "$(echo ok)" "ok" "rig runs"
finish
```

- [ ] **Step 6: Run it** — `bash test/run.sh` — Expected: `1/1 passed`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "chore: scaffold Harness repo + test rig"
```

---

### Task 2: Config loader + topology registry (`lib.sh` part 1)

**Files:**
- Create: `lib.sh`
- Test: `test/test_registry.sh`

- [ ] **Step 1: Write the failing test** `test/test_registry.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/helpers.sh"
make_env

# multi topology: registry comes from targets.tsv
HARNESS_TOPOLOGY=multi
write_targets <<'EOF'
# id	repo	deps	desc
a	acme/a	-	root
b	acme/b	a	needs a
c	acme/c	a,b	needs a+b
EOF
assert_eq "$(all_units | tr '\n' ' ')" "a b c " "multi: all_units from targets.tsv"
assert_eq "$(unit_repo b)" "acme/b" "multi: unit_repo"
assert_eq "$(unit_deps c)" "a,b" "multi: unit_deps"
assert_eq "$(unit_slug b)" "acme/b" "multi: slug = repo (already owner/repo)"

# bare repo name gets owner prefix
write_targets <<'EOF'
a	a	-	root
EOF
HARNESS_OWNER=acme
assert_eq "$(unit_slug a)" "acme/a" "multi: bare repo name -> owner/repo"

# single topology: one synthetic unit "main", repo from HARNESS_REPO, no deps
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"
assert_eq "$(all_units | tr '\n' ' ')" "main " "single: one unit 'main'"
assert_eq "$(unit_repo main)" "acme/widget" "single: unit_repo = HARNESS_REPO"
assert_eq "$(unit_deps main)" "-" "single: no deps"
finish
```

- [ ] **Step 2: Run it** — `bash test/test_registry.sh` — Expected: FAIL (lib.sh missing).

- [ ] **Step 3: Implement `lib.sh` (config + registry section)**

```bash
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
: "${HARNESS_POLL:=60}"
: "${HARNESS_IMPL_MAXITER:=30}"
: "${HARNESS_ORCH_MAXITER:=8}"
: "${HARNESS_SESS_PREFIX:=hz}"
: "${HARNESS_CLAUDE_BIN:=claude}"
: "${HARNESS_CLAUDE_FLAGS:=--dangerously-skip-permissions --effort high}"
: "${HARNESS_LABEL_READY:=ready-for-agent}"
: "${HARNESS_LABEL_PRD:=prd}"
: "${HARNESS_LABEL_WORKING:=agent-working}"
: "${HARNESS_LABEL_BLOCKED:=agent-blocked}"
: "${HARNESS_LABEL_REVIEWED:=reviewed}"
: "${HARNESS_LABEL_COORD:=coordination}"
: "${HARNESS_MAIN_REPO:=}"             # multi: umbrella repo for coordination issues (optional)

export HARNESS_MODE HARNESS_TOPOLOGY HARNESS_OWNER HARNESS_REPO HARNESS_SPEC HARNESS_AUTONOMOUS \
  HARNESS_LABEL_READY HARNESS_LABEL_PRD HARNESS_LABEL_WORKING HARNESS_LABEL_BLOCKED \
  HARNESS_LABEL_REVIEWED HARNESS_LABEL_COORD HARNESS_MAIN_REPO

OWNER="$HARNESS_OWNER"
CAP="$HARNESS_CAP"; POLL="$HARNESS_POLL"; POOL="$HARNESS_POOL"
IMPL_MAXITER="$HARNESS_IMPL_MAXITER"; ORCH_MAXITER="$HARNESS_ORCH_MAXITER"
CLAUDE_BIN="$HARNESS_CLAUDE_BIN"; CLAUDE_FLAGS="$HARNESS_CLAUDE_FLAGS"
CLAIMS_DIR="${CLAIMS_DIR:-$RUN_DIR/claims}"
POOL_LOCK="${POOL_LOCK:-$RUN_DIR/pool.lock}"
mkdir -p "$RUN_DIR" "$WORKTREES_DIR" "$CHECKOUTS_DIR" "$CLAIMS_DIR" 2>/dev/null || true

log(){ printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "${UNIT:-harness}" "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ensure_safe(){ git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$1" || git config --global --add safe.directory "$1"; }

_with_owner(){ case "$1" in */*) echo "$1";; *) [[ -n "$OWNER" ]] && echo "$OWNER/$1" || echo "$1";; esac; }

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
```

- [ ] **Step 4: Run it** — `bash test/test_registry.sh` — Expected: all `ok`, `… passed`.

- [ ] **Step 5: Run the full suite** — `bash test/run.sh` — Expected: green.

- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: lib.sh config loader + single/multi topology registry"`

---

### Task 3: Completeness, claims, and the claim race (`lib.sh` part 2)

**Files:**
- Modify: `lib.sh` (append)
- Test: `test/test_claim.sh`

- [ ] **Step 1: Write the failing test** `test/test_claim.sh` (ported from `$SRC/test/test_claim.sh`, renamed)

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/helpers.sh"
make_env
HARNESS_TOPOLOGY=multi
write_targets <<'EOF'
a	acme/a	-	root
b	acme/b	a	needs a
c	acme/c	a,b	needs a+b
EOF
set_complete
assert_ok "a no deps -> deps_complete"            deps_complete a
assert_no "b dep a incomplete -> !deps_complete"  deps_complete b
assert_no "nothing complete -> !all_complete"     all_complete
set_complete a
assert_ok "a complete -> b deps_complete"         deps_complete b
assert_no "c needs a+b, b incomplete"             deps_complete c
set_complete a b c
assert_ok "all complete -> all_complete"          all_complete

printf 'W1 %s\n' "$$"     > "$CLAIMS_DIR/a.claim"
printf 'W2 %s\n' "999999" > "$CLAIMS_DIR/b.claim"
assert_ok "live-pid claim is claimed"     is_claimed a
assert_no "dead-pid claim is not claimed" is_claimed b
assert_no "no claim file -> not claimed"  is_claimed c
clear_stale_claims >/dev/null
assert_ok "stale claim removed" bash -c "[[ ! -f '$CLAIMS_DIR/b.claim' ]]"
assert_ok "live claim kept"     bash -c "[[ -f '$CLAIMS_DIR/a.claim' ]]"
rm -f "$CLAIMS_DIR/a.claim"

set_complete
assert_eq "$(claimable_units | tr '\n' ' ')" "a " "only a claimable"
set_complete a
assert_eq "$(claimable_units | tr '\n' ' ')" "b " "a done -> b claimable"
printf 'W1 %s\n' "$$" > "$CLAIMS_DIR/b.claim"
assert_eq "$(claimable_units | tr '\n' ' ')" "" "b claimed -> nothing claimable"
rm -f "$CLAIMS_DIR/b.claim"
set_complete a b
assert_eq "$(claimable_units | tr '\n' ' ')" "c " "a+b done -> c claimable"

set_complete a
got="$(claim_next W1)"; assert_eq "$got" "b" "claim_next returns first claimable"
assert_eq "$(awk '{print $1}' "$CLAIMS_DIR/b.claim")" "W1" "claim records worker id"
assert_eq "$(claim_next W2)" "" "no claimable left -> empty"
assert_eq "$(worker_unit W1)" "b" "worker_unit finds the claim"
release_claim b
assert_ok "release removes claim file" bash -c "[[ ! -f '$CLAIMS_DIR/b.claim' ]]"

# race: two siblings simultaneously claimable -> claimers get DIFFERENT units
write_targets <<'EOF'
a	acme/a	-	r1
d	acme/d	-	r2
EOF
set_complete
( claim_next A > "$RUN_DIR/a.out" ) &
( claim_next B > "$RUN_DIR/b.out" ) &
wait
ra="$(cat "$RUN_DIR/a.out")"; rb="$(cat "$RUN_DIR/b.out")"
assert_ok "both claimers got a unit"        bash -c "[[ -n '$ra' && -n '$rb' ]]"
assert_ok "claimers got DIFFERENT units"    bash -c "[[ '$ra' != '$rb' ]]"
rm -f "$CLAIMS_DIR"/*.claim
finish
```

- [ ] **Step 2: Run it** — Expected: FAIL (functions undefined).

- [ ] **Step 3: Append to `lib.sh`** (ported from `$SRC/lib.sh` lines 53–122, renamed `team_complete`→`unit_complete`, `sp`→`unit`, `claimable_sps`→`claimable_units`, `worker_module`→`worker_unit`; `unit_complete` calls issuelib with the unit's repo)

```bash
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

dispatch_actions(){ python3 "$HARNESS_DIR/issuelib.py" dispatch "$1" "$2" --allow-orchestration "$3"; }

# --- tmux session naming + ralph helpers -------------------------------------
sess_orch(){ echo "$HARNESS_SESS_PREFIX-$1"; }
sess_impl(){ echo "$HARNESS_SESS_PREFIX-$1-i$2"; }
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
      "$uuid" "$maxiter" "$promise" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; cat "$wd/.bonsai-task.md" 2>/dev/null || cat "$wd/.harness-task.md"
  } > "$wd/.claude/ralph-loop.local.md"; }
launch_claude(){ local sess="$1" wd="$2" uuid; uuid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
  write_state "$wd" "$PROMISE" "$MAXITER" "$uuid"; echo "${GOAL:-?}" > "$RUN_DIR/$sess.goal"
  tmux new-session -d -s "$sess" -c "$wd"; sleep 1.5
  tmux send-keys -t "$sess" "exec $CLAUDE_BIN --session-id $uuid $CLAUDE_FLAGS \"\$(cat .harness-task.md)\"" Enter
  log "launched session $sess (cwd $wd)"; }
```

> Note: `write_state` reads `.harness-task.md` (the new task filename); the `.bonsai-task.md` fallback is harmless and can be dropped. Use `.harness-task.md` everywhere in drive.sh.

- [ ] **Step 4: Run it** — `bash test/test_claim.sh` — Expected: all `ok`.
- [ ] **Step 5: Full suite** — `bash test/run.sh` — Expected: green.
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: lib.sh completeness + flock claims + tmux/ralph helpers"`

---

### Task 4: `issuelib.py` — generalize state + dispatch (modes), complete, autonomy

**Files:**
- Create: `issuelib.py`
- Test: `test/test_issuelib.py` (pure-python; stubs `gh` via a fake `compute_state`)

This ports `$SRC/issuelib.py` with these generalizations:
1. `OWNER` from `HARNESS_OWNER`; labels from `HARNESS_LABEL_*` env (defaults match Bonsai).
2. Drop the `bonsai-` prefix strip; display name = `repo.split('/')[-1]`.
3. `dispatch()` gates orchestration by `HARNESS_MODE` (entry stage).
4. `unit_complete` predicate (`complete` CLI) is mode-aware: issue-only ⇒ no open dispatchable issues; prd/planned ⇒ PRD closed + reviewed.
5. Autonomy: `agent-blocked` excluded from `unblocked` only when `HARNESS_AUTONOMOUS != true`.

- [ ] **Step 1: Write the failing test** `test/test_issuelib.py`

```python
import importlib.util, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("issuelib", os.path.join(HERE, "..", "issuelib.py"))
il = importlib.util.module_from_spec(spec); spec.loader.exec_module(il)

def mk(**kw):
    base = dict(slug="acme/widget", has_plan=False, prd=None, prd_open=False, prd_reviewed=False,
                children_exist=False, children_all_closed=False, unblocked=[], open_children=0, total_children=0)
    base.update(kw); return base

def dispatch_with(mode, state, free=3):
    os.environ["HARNESS_MODE"] = mode
    il.compute_state = lambda repo: state           # stub GitHub
    allow = mode in ("planned",) or True            # caller decides; here exercise via dispatch()
    return il.dispatch("acme/widget", free, True)

def test_issue_only_emits_only_impl():
    os.environ["HARNESS_MODE"] = "issue-only"
    il.compute_state = lambda r: mk(prd=None, has_plan=False, children_exist=True, unblocked=[5,6])
    acts = il.dispatch("acme/widget", 3, True)
    assert [a[0] for a in acts] == ["IMPL", "IMPL"], acts
    # never PLAN/PRD/DECOMPOSE even with no plan/prd/children
    il.compute_state = lambda r: mk(prd=None, has_plan=False, children_exist=False, unblocked=[])
    assert il.dispatch("acme/widget", 3, True) == []

def test_prd_mode_decompose_not_plan_or_prd():
    os.environ["HARNESS_MODE"] = "prd"
    # human supplied PRD (prd set), no children yet -> DECOMPOSE, never PLAN/PRD
    il.compute_state = lambda r: mk(prd=10, prd_open=True, has_plan=False, children_exist=False)
    acts = il.dispatch("acme/widget", 3, True)
    assert acts and acts[0][0] == "DECOMPOSE", acts
    # no PRD yet in prd mode -> nothing (human must create it; agent must NOT author PLAN/PRD)
    il.compute_state = lambda r: mk(prd=None, has_plan=False, children_exist=False)
    assert il.dispatch("acme/widget", 3, True) == []

def test_planned_mode_full_pipeline():
    os.environ["HARNESS_MODE"] = "planned"
    il.compute_state = lambda r: mk(prd=None, has_plan=False)
    assert il.dispatch("acme/widget", 3, True)[0][0] == "PLAN"
    il.compute_state = lambda r: mk(prd=None, has_plan=True)
    assert il.dispatch("acme/widget", 3, True)[0][0] == "PRD"
    il.compute_state = lambda r: mk(prd=7, prd_open=True, has_plan=True, children_exist=False)
    assert il.dispatch("acme/widget", 3, True)[0][0] == "DECOMPOSE"
    il.compute_state = lambda r: mk(prd=7, prd_open=True, children_exist=True, children_all_closed=True)
    assert il.dispatch("acme/widget", 3, True)[0][0] == "REVIEW"

def test_complete_predicate_by_mode():
    # issue-only: complete when no open dispatchable issues remain
    os.environ["HARNESS_MODE"] = "issue-only"
    il.compute_state = lambda r: mk(children_exist=True, open_children=0, unblocked=[])
    assert il.is_complete(il.compute_state("x")) is True
    il.compute_state = lambda r: mk(children_exist=True, open_children=2, unblocked=[5,6])
    assert il.is_complete(il.compute_state("x")) is False
    # prd/planned: complete when PRD closed + reviewed
    os.environ["HARNESS_MODE"] = "planned"
    assert il.is_complete(mk(prd=7, prd_open=False, prd_reviewed=True)) is True
    assert il.is_complete(mk(prd=7, prd_open=True, prd_reviewed=True)) is False

if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)
```

- [ ] **Step 2: Run it** — `python3 test/test_issuelib.py` — Expected: FAIL (module missing).

- [ ] **Step 3: Implement `issuelib.py`** (port of `$SRC/issuelib.py` with the 5 generalizations). Key new/changed pieces:

```python
#!/usr/bin/env python3
"""issuelib.py — GitHub-issue state machine for the Harness orchestrator (project-agnostic)."""
import json, os, re, subprocess, sys

OWNER = os.environ.get("HARNESS_OWNER", "")
MODE = lambda: os.environ.get("HARNESS_MODE", "issue-only")
AUTONOMOUS = lambda: os.environ.get("HARNESS_AUTONOMOUS", "true").lower() == "true"
L_READY    = lambda: os.environ.get("HARNESS_LABEL_READY", "ready-for-agent")
L_PRD      = lambda: os.environ.get("HARNESS_LABEL_PRD", "prd")
L_WORKING  = lambda: os.environ.get("HARNESS_LABEL_WORKING", "agent-working")
L_BLOCKED  = lambda: os.environ.get("HARNESS_LABEL_BLOCKED", "agent-blocked")
L_REVIEWED = lambda: os.environ.get("HARNESS_LABEL_REVIEWED", "reviewed")

_BLOCKED_BY_HEADING = re.compile(r"^##\s+Blocked by\s*$", re.IGNORECASE | re.MULTILINE)
_NEXT_HEADING = re.compile(r"^##\s+", re.MULTILINE)
_ISSUE_REF = re.compile(r"(?:([\w.-]+/[\w.-]+))?#(\d+)")

# _gh_json, _repo_slug, parse_blocked_by, _list_issues, _issue_state, _has_plan, _is_unblocked
# port verbatim from $SRC/issuelib.py, EXCEPT:
#   _repo_slug: return repo if "/" in repo else (f"{OWNER}/{repo}" if OWNER else repo)
#   _list_issues label normalisation unchanged.

def _allowed(mode):
    """Which orchestration actions this mode permits (entry-stage gating)."""
    return {
        "issue-only": dict(plan=False, prd=False, decompose=False, review=False),
        "prd":        dict(plan=False, prd=False, decompose=True,  review=True),
        "planned":    dict(plan=True,  prd=True,  decompose=True,  review=True),
    }.get(mode, dict(plan=False, prd=False, decompose=False, review=False))

def compute_state(repo):
    slug = _repo_slug(repo)
    issues = _list_issues(slug)
    prd = next((i for i in issues if L_PRD() in i["_labels"]
                or i.get("title", "").startswith("[AFK] PRD:")), None)
    prd_num = prd["number"] if prd else None
    children = [i for i in issues if L_READY() in i["_labels"] and L_PRD() not in i["_labels"]]
    children_exist = len(children) > 0
    children_all_closed = children_exist and all(i["state"].lower() == "closed" for i in children)
    closed_cache = {}
    unblocked = [i["number"] for i in children
                 if i["state"].lower() == "open"
                 and L_WORKING() not in i["_labels"]
                 and (AUTONOMOUS() or L_BLOCKED() not in i["_labels"])
                 and _is_unblocked(i, slug, closed_cache, prd_num)]
    return {"slug": slug, "has_plan": _has_plan(slug),
            "prd": prd_num, "prd_open": bool(prd) and prd["state"].lower() == "open",
            "prd_reviewed": bool(prd) and L_REVIEWED() in prd["_labels"],
            "children_exist": children_exist, "children_all_closed": children_all_closed,
            "unblocked": unblocked,
            "open_children": sum(1 for i in children if i["state"].lower() == "open"),
            "total_children": len(children)}

def dispatch(repo, free_slots, allow_orchestration):
    s = compute_state(repo); a = _allowed(MODE()); out = []
    if allow_orchestration:
        if a["plan"] and s["prd"] is None and not s["has_plan"]:
            return [("PLAN", "-", "PLAN DONE")]
        if a["prd"] and s["has_plan"] and s["prd"] is None:
            return [("PRD", "-", "PRD DONE")]
        if a["decompose"] and s["prd"] is not None and not s["children_exist"]:
            return [("DECOMPOSE", str(s["prd"]), "DECOMPOSE DONE")]
    for num in s["unblocked"][:max(0, free_slots)]:
        out.append(("IMPL", str(num), f"ISSUE {num} DONE"))
    if not out and allow_orchestration and a["review"] and s["children_all_closed"] and s["prd_open"]:
        out.append(("REVIEW", str(s["prd"]), "REVIEW DONE"))
    return out

def is_complete(s):
    if MODE() == "issue-only":
        return s["children_exist"] and s["open_children"] == 0 and len(s["unblocked"]) == 0
    return s["prd"] is not None and not s["prd_open"] and s["prd_reviewed"]

def main():
    if len(sys.argv) < 3: print(__doc__); sys.exit(2)
    cmd, repo = sys.argv[1], sys.argv[2]
    if cmd == "dispatch":
        free = int(sys.argv[3]) if len(sys.argv) > 3 else 1
        allow = sys.argv[sys.argv.index("--allow-orchestration")+1] == "1" if "--allow-orchestration" in sys.argv else True
        for action, payload, promise in dispatch(repo, free, allow): print(f"{action}\t{payload}\t{promise}")
    elif cmd == "status":
        s = compute_state(repo); prd = f"PRD#{s['prd']}" if s["prd"] else "no-PRD"
        prd += "(open)" if s["prd_open"] else ("(closed)" if s["prd"] else "")
        print(f"{repo}: mode={MODE()} {prd} plan={'Y' if s['has_plan'] else 'N'} "
              f"children={s['total_children']} open={s['open_children']} unblocked={len(s['unblocked'])} "
              f"reviewed={'Y' if s['prd_reviewed'] else 'N'} complete={'Y' if is_complete(s) else 'N'}")
    elif cmd == "complete":
        print("DONE" if is_complete(compute_state(repo)) else "NOTDONE")
    elif cmd == "check":
        goal = sys.argv[3] if len(sys.argv) > 3 else ""; s = compute_state(repo); done = False
        if goal == "PLAN": done = s["has_plan"]
        elif goal == "PRD": done = s["prd"] is not None
        elif goal == "DECOMPOSE": done = s["children_exist"]
        elif goal == "REVIEW": done = (not s["prd_open"]) or len(s["unblocked"]) > 0
        elif goal.startswith("ISSUE:"): done = _issue_state(s["slug"], int(goal.split(":",1)[1])) == "closed"
        print("DONE" if done else "PENDING")
    else: print(f"unknown command: {cmd}", file=sys.stderr); sys.exit(2)

if __name__ == "__main__": main()
```

> Port the helper functions (`_gh_json`, `_repo_slug`, `parse_blocked_by`, `_list_issues`, `_issue_state`, `_has_plan`, `_is_unblocked`) verbatim from `$SRC/issuelib.py:42-113`, applying only the `_repo_slug` OWNER-optional change noted above.

- [ ] **Step 4: Run it** — `python3 test/test_issuelib.py` — Expected: all `ok`, `── all pass`.
- [ ] **Step 5: Make `test/run.sh` also run python tests** — change its loop body to:

```bash
for t in test_*.sh test_*.py; do
  [[ -e "$t" ]] || continue
  echo "== $t =="
  case "$t" in *.py) python3 "$t" || rc=1;; *) bash "$t" || rc=1;; esac
done
```

- [ ] **Step 6: Full suite** — `bash test/run.sh` — Expected: green.
- [ ] **Step 7: Commit** — `git add -A && git commit -m "feat: issuelib.py — mode gating, mode-aware complete, autonomy toggle"`

---

### Task 5: `drive.sh` — generalized drive loop

**Files:**
- Create: `drive.sh`
- Test: `test/test_drive.sh`

Port `$SRC/drive.sh`, renaming `drive_team`→`drive_unit`, `SP`→`UNIT`, `SP_DISP`→`PROJECT`, `sp_*`→`unit_*`, `.bonsai-task.md`→`.harness-task.md`, label literals → `$HARNESS_LABEL_*`. `drive_unit` loops `while ! unit_complete "$UNIT"`. For multi topology, `spawn_orch` checks out the unit's own repo into `unit_checkout`; for single it operates in `PROJECT_ROOT`. Reaping frees `$HARNESS_LABEL_WORKING` on still-open issues.

- [ ] **Step 1: Write the failing test** `test/test_drive.sh` (drives a stubbed dispatch + stubbed sessions; asserts the loop exits when `unit_complete` flips)

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"; source "$HERE/../drive.sh"; source "$HERE/helpers.sh"
make_env
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"; CAP=2; POLL=0
DISPATCHED="$RUN_DIR/dispatched"; : > "$DISPATCHED"

# stubs: no real tmux/gh. spawn_impl just records; sessions are never "live".
spawn_impl(){ echo "IMPL $1" >> "$DISPATCHED"; }
spawn_orch(){ echo "ORCH $1" >> "$DISPATCHED"; }
reap_done_sessions(){ :; }
reap_team(){ :; }
count_team_sessions(){ echo 0; }
# dispatch returns two IMPL the first tick, then nothing; unit completes on tick 2.
TICK="$RUN_DIR/tick"; echo 0 > "$TICK"
dispatch_actions(){ local n; n="$(cat "$TICK")"; n=$((n+1)); echo "$n" > "$TICK"
  if [[ "$n" == 1 ]]; then printf 'IMPL\t5\tISSUE 5 DONE\nIMPL\t6\tISSUE 6 DONE\n'; fi; }
COMPLETE_AFTER=2
unit_complete(){ [[ "$(cat "$TICK")" -ge "$COMPLETE_AFTER" ]]; }

drive_unit main
assert_eq "$(grep -c '^IMPL' "$DISPATCHED")" "2" "drove two IMPL actions on first tick"
assert_ok "loop exited when unit_complete flipped" true
finish
```

- [ ] **Step 2: Run it** — Expected: FAIL (drive.sh missing).

- [ ] **Step 3: Implement `drive.sh`** — port from `$SRC/drive.sh` with renames. The `drive_unit` core:

```bash
#!/usr/bin/env bash
_HARNESS_DRIVE_SOURCED=1
default_branch(){ gh repo view "$SLUG" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main; }
# reap_done_sessions / reap_team / spawn_orch / spawn_impl: port from $SRC/drive.sh:10-68,
#   renaming SP->UNIT, SP_DISP->PROJECT, sp_*->unit_*, .bonsai-task.md->.harness-task.md,
#   'agent-working' -> "$HARNESS_LABEL_WORKING", and rendering prompts with the new keys
#   (PROJECT/DESC/SLUG/OWNER/SPEC/PRD/ISSUE/BRANCH/PROMISE). For multi topology, spawn_orch
#   must `git clone`/update the unit repo into "$CHECKOUT" if absent.
drive_unit(){
  local UNIT="$1" REPO SLUG PROJECT DESC CHECKOUT
  REPO="$(unit_repo "$UNIT")"; [[ -n "$REPO" ]] || { log "unknown unit: $UNIT"; return 1; }
  SLUG="$(unit_slug "$UNIT")"; PROJECT="$UNIT"; DESC="$(unit_desc "$UNIT")"; CHECKOUT="$(unit_checkout "$UNIT")"
  log "drive $SLUG — mode $HARNESS_MODE cap $CAP poll ${POLL}s"
  while ! unit_complete "$UNIT"; do
    reap_done_sessions; reap_team
    local active free allow_orch action payload promise
    active="$(count_team_sessions "$UNIT")"; free=$(( CAP - active ))
    if (( free > 0 )); then
      allow_orch=0; (( active == 0 )) && allow_orch=1
      while IFS=$'\t' read -r action payload promise; do
        [[ -z "$action" ]] && continue
        if [[ "$action" == IMPL ]]; then spawn_impl "$payload" "$promise"; else spawn_orch "$action" "$payload" "$promise"; fi
        sleep 2
      done < <(dispatch_actions "$REPO" "$free" "$allow_orch")
    fi
    sleep "$POLL"
  done
  log "$UNIT COMPLETE"
}
```

- [ ] **Step 4: Run it** — `bash test/test_drive.sh` — Expected: all `ok`.
- [ ] **Step 5: Full suite** — `bash test/run.sh` — Expected: green.
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: drive.sh — generalized unit drive loop"`

---

### Task 6: Worker pool (`pool-worker.sh` + `pool.sh`)

**Files:**
- Create: `pool-worker.sh`, `pool.sh`
- Test: `test/test_worker.sh`

Port `$SRC/pool-worker.sh` + `$SRC/pool.sh`: `_BONSAI_*`→`_HARNESS_*` source guards, `worker_module`→`worker_unit`, `seed_if_needed`/`drive_team`→`drive_unit`, `BONSAI_POOL`→`HARNESS_POOL`.

- [ ] **Step 1: Write the failing test** `test/test_worker.sh` (asserts `worker_tick` return codes: 0 claimed+drove, 1 idle, 2 all-done)

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"; source "$HERE/../drive.sh"
_HARNESS_LIB_SOURCED=1 _HARNESS_DRIVE_SOURCED=1
source "$HERE/../pool-worker.sh"   # defines worker_tick; main() guarded out
source "$HERE/helpers.sh"; make_env
HARNESS_TOPOLOGY=multi
write_targets <<'EOF'
a	acme/a	-	root
b	acme/b	a	needs a
EOF
seed_if_needed(){ :; }            # no real gh
drive_unit(){ set_complete $(cat "$COMPLETE_SET") "$1"; }  # "driving" marks it complete
set_complete
worker_tick W1; assert_eq "$?" "0" "claimed a + drove -> rc 0"
assert_ok "a now complete" unit_complete a
worker_tick W1; assert_eq "$?" "0" "claimed b + drove -> rc 0"
worker_tick W1; assert_eq "$?" "2" "all complete -> rc 2 (retire)"
finish
```

- [ ] **Step 2: Run it** — Expected: FAIL.
- [ ] **Step 3: Implement `pool-worker.sh`** (ported, renamed):

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${_HARNESS_LIB_SOURCED:-}" ]]   && { source "$HERE/lib.sh";   _HARNESS_LIB_SOURCED=1; }
[[ -z "${_HARNESS_DRIVE_SOURCED:-}" ]] && { source "$HERE/drive.sh"; _HARNESS_DRIVE_SOURCED=1; }
worker_tick(){ local wid="$1" u; u="$(claim_next "$wid")"
  if [[ -z "$u" ]]; then all_complete && return 2; return 1; fi
  log "worker $wid claimed $u"; seed_if_needed "$u"; drive_unit "$u"; release_claim "$u"; log "worker $wid released $u"; return 0; }
main(){ local wid="${1:?usage: pool-worker.sh <worker-id>}"; UNIT="worker-$wid"
  log "pool worker $wid up — cap $CAP poll ${POLL}s"
  while true; do worker_tick "$wid"; local rc=$?
    case "$rc" in 0) ;; 2) log "all COMPLETE — worker $wid retiring"; exit 0;; *) sleep "$POLL";; esac
  done; }
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
```

- [ ] **Step 4: Implement `pool.sh`** (ported, `BONSAI_POOL`→`HARNESS_POOL`, paths from lib.sh):

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
echo "Launching $POOL pool worker(s) (cap=$CAP sessions/worker, poll=${POLL}s):"
for ((i=1; i<=POOL; i++)); do
  pidf="$RUN_DIR/worker-$i.pid"
  if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then echo "  worker-$i: already running (pid $(cat "$pidf"))"; continue; fi
  nohup bash "$HARNESS_DIR/pool-worker.sh" "$i" >"$RUN_DIR/worker-$i.log" 2>&1 &
  echo "$!" > "$pidf"; echo "  worker-$i: started (pid $!) — log $RUN_DIR/worker-$i.log"
done
```

- [ ] **Step 5: Run it** — `bash test/test_worker.sh` — Expected: all `ok`.
- [ ] **Step 6: Full suite** — `bash test/run.sh` — Expected: green.
- [ ] **Step 7: Commit** — `git add -A && git commit -m "feat: worker pool (pool-worker.sh + pool.sh)"`

---

### Task 7: `seed.sh` — repo bootstrap with configured labels

**Files:**
- Create: `seed.sh`
- Modify: `lib.sh` (add `seed_if_needed`)
- Test: `test/test_seed.sh`

Generalize `$SRC/seed-repo.sh`: labels from `$HARNESS_LABEL_*`; single topology seeds `HARNESS_REPO` **in place** (no submodule); multi clones/updates each unit repo into `$CHECKOUTS_DIR`. `seed_if_needed` in lib.sh: single → ensure labels on `HARNESS_REPO` (no checkout needed, project root already is the repo); multi → clone repo into checkout + ensure labels.

- [ ] **Step 1: Write the failing test** `test/test_seed.sh` (stubs `gh` to record label-create calls; asserts idempotent + uses configured names)

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"; source "$HERE/helpers.sh"; make_env
HARNESS_LABEL_READY=go HARNESS_LABEL_PRD=spec   # custom names
CALLS="$RUN_DIR/gh.calls"; : > "$CALLS"
gh(){ echo "$*" >> "$CALLS"
  case "$1 $2" in "repo view") return 0;; "label create") return 0;; "api") return 0;; esac; return 0; }
export -f gh
SLUG="acme/widget"
source "$HERE/../seed.sh" --labels-only "$SLUG"   # a label-only entrypoint for the test
assert_ok "created custom ready label" bash -c "grep -q 'label create go' '$CALLS'"
assert_ok "created custom prd label"   bash -c "grep -q 'label create spec' '$CALLS'"
finish
```

> The implementer adds a `--labels-only <slug>` fast path to `seed.sh` so the label vocabulary can be tested without repo creation or CI.

- [ ] **Step 2: Run it** — Expected: FAIL.
- [ ] **Step 3: Implement `seed.sh`** — port `$SRC/seed-repo.sh:1-69`, replacing the fixed `add_label` calls with the configured names:

```bash
add_label "$HARNESS_LABEL_READY"    0e8a16 "Implementation issue an agent may pick up"
add_label "$HARNESS_LABEL_PRD"      5319e7 "PRD tracking issue"
add_label "$HARNESS_LABEL_WORKING"  fbca04 "An agent session currently owns this issue"
add_label "$HARNESS_LABEL_BLOCKED"  b60205 "Blocked — needs another unit or a human"
add_label "$HARNESS_LABEL_REVIEWED" 0052cc "PRD verified against acceptance criteria"
add_label "$HARNESS_LABEL_COORD"    d4c5f9 "Cross-unit coordination"
```

Add the `--labels-only <slug>` branch at the top (create labels on `<slug>`, then exit 0). The default path takes a unit-id, resolves slug, creates the repo if absent (multi only — single assumes the project repo already exists), seeds labels + CI + auto-merge. Add `seed_if_needed` to **lib.sh**:

```bash
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
```

- [ ] **Step 4: Run it** — `bash test/test_seed.sh` — Expected: all `ok`.
- [ ] **Step 5: Full suite** — `bash test/run.sh` — Expected: green.
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: seed.sh — configured-label bootstrap + seed_if_needed"`

---

### Task 8: Prompt templates (generalized, autonomy-branching impl)

**Files:**
- Create: `prompts/{plan,prd,decompose,impl,review}.md`

Port the 5 templates from `$SRC/prompts/`, replacing Bonsai-specific phrasing. Substitution keys: `{{PROJECT}} {{DESC}} {{SLUG}} {{OWNER}} {{SPEC}} {{PRD}} {{ISSUE}} {{BRANCH}} {{PROMISE}}`. Remove "Bonsai 2.0 sub-project" and "submodule of {{MAIN_REPO}}" framing.

- [ ] **Step 1: Write `prompts/impl.md`** with an autonomy branch (the engine renders both blocks; only one is true per config — keep both, headed by the condition, since prompts are static text):

```markdown
You are an implementation engineer on {{PROJECT}} ({{DESC}}).
Running autonomously in a Ralph loop, in a DEDICATED git worktree on a feature branch.
State persists in git + GitHub. Output the completion promise ONLY when genuinely true.

Repo: {{SLUG}}   Branch: {{BRANCH}} (already checked out)
Your issue: #{{ISSUE}}  (already labelled `agent-working` — it is yours)

GOAL: implement issue #{{ISSUE}} via TDD, get it merged, and close the issue.

Steps:
1. Read the issue:  gh issue view {{ISSUE}} -R {{SLUG}}   — note its acceptance criteria.
2. Implement using strict TDD (`test-driven-development` skill): failing test → pass → refactor.
   For sizeable work, dispatch parallel sub-agents (`subagent-driven-development`). Stay in THIS repo.
3. Run the full test suite. All green required.
4. Commit, push, open a PR, enable auto-merge:
     git add -A && git commit -m "feat: <summary> (closes #{{ISSUE}})"
     git push -u origin {{BRANCH}}
     gh pr create -R {{SLUG}} --fill --head {{BRANCH}} --base <default-branch>
     gh pr merge --auto --squash -R {{SLUG}} <pr-number>
5. Confirm the PR is auto-merging (or merged) and the issue will close.

AUTONOMY — if this harness is configured AUTONOMOUS (no human): NEVER apply `agent-blocked`,
never wait for a human/credential/resource. Provision runtimes yourself (`docker compose up -d`,
run setup scripts, install deps). Make ambiguous calls yourself, document them in an issue comment,
and drive the issue to closed. If a route seems impossible, find another and still close it.

AUTONOMY — if this harness is configured NON-autonomous: you MAY park genuinely blocked work by
adding the `agent-blocked` label with a comment explaining exactly what a human must provide.

When the PR is merged (or auto-merging on green) AND the issue is closing, output exactly:
<promise>{{PROMISE}}</promise>
```

- [ ] **Step 2: Write `prompts/decompose.md`** (port `$SRC/prompts/decompose.md`, generalized: cross-unit deps use a coordination issue on `{{OWNER}}`'s umbrella repo only when `HARNESS_MAIN_REPO` is set; otherwise same-repo `#N` refs only; labels are the configured names).

- [ ] **Step 3: Write `prompts/plan.md`, `prompts/prd.md`, `prompts/review.md`** (port from `$SRC/prompts/`, replace "Bonsai 2.0 sub-project {{SP}}" → "{{PROJECT}} ({{DESC}})", drop submodule phrasing, keep skill invocations `writing-plans`/`to-prd`/`to-issues`, keep the `[AFK] PRD:` title + `prd` label convention).

- [ ] **Step 4: Verify substitution** — render impl.md and assert keys resolve:

```bash
source "lib.sh"
render "prompts/impl.md" PROJECT=widget DESC=d SLUG=acme/widget ISSUE=5 BRANCH=issue/5 PROMISE="ISSUE 5 DONE" | grep -q "issue #5" && echo OK
```
Expected: `OK`, and no literal `{{...}}` remain (`! grep -q '{{' <(render ...)`).

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: generalized prompt templates (autonomy-branching impl)"`

---

### Task 9: Operations scripts — `start.sh`, `stop.sh`, `status.sh`, `attach.sh`

**Files:**
- Create: `start.sh`, `stop.sh`, `status.sh`, `attach.sh`
- Test: `test/test_status.sh`

Port from `$SRC/` with renames. `start.sh --recover` sweeps stale pidfiles/claims and frees orphaned `$HARNESS_LABEL_WORKING` labels across all seeded unit repos. `status.sh` prints pool up/down + per-unit `issuelib.py status` + live sessions + open PRs. `attach.sh <unit> [issue]` tmux-attaches `sess_orch`/`sess_impl`.

- [ ] **Step 1: Write the failing test** `test/test_status.sh` (stubs `issuelib.py` via PATH? simpler: assert `status.sh` runs and prints the pool header with workers down)

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RUN_DIR="$(mktemp -d)"
out="$(HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget bash "$HERE/../status.sh" 2>&1 || true)"
echo "$out" | grep -qiE "worker" && echo "  ok: status mentions workers" || { echo "  FAIL"; exit 1; }
echo "── status smoke ok"
```

- [ ] **Step 2: Run it** — Expected: FAIL (status.sh missing).
- [ ] **Step 3: Implement the four scripts** — port from `$SRC/start.sh`, `$SRC/stop.sh`, `$SRC/status.sh`, `$SRC/attach.sh`. Renames: `all_sps`→`all_units`, `sp_slug`→`unit_slug`, `sess_impl`, `agent-working`→`$HARNESS_LABEL_WORKING`, `BONSAI_*`→`HARNESS_*`, drop `bootstrap.sh` reference (no submodule bootstrap in single mode; multi clones in `seed_if_needed`). `start.sh` preflight: `command -v tmux/claude/gh`. Launch `pool.sh`.
- [ ] **Step 4: Run it** — `bash test/test_status.sh` — Expected: `ok`.
- [ ] **Step 5: Full suite** — `bash test/run.sh` — Expected: green.
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: ops scripts start/stop/status/attach"`

---

### Task 10: `bin/harness` CLI dispatcher

**Files:**
- Create: `bin/harness`
- Test: `test/test_cli.sh`

- [ ] **Step 1: Write the failing test** `test/test_cli.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../bin/harness"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
assert "no args prints usage"        "$CLI 2>&1 | grep -qi usage"
assert "unknown cmd errors"          "! $CLI bogus >/dev/null 2>&1"
assert "help lists start/stop/status" "$CLI help 2>&1 | grep -q start && $CLI help 2>&1 | grep -q status"
echo "── cli ok"
```

- [ ] **Step 2: Run it** — Expected: FAIL.
- [ ] **Step 3: Implement `bin/harness`**

```bash
#!/usr/bin/env bash
set -uo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage(){ cat <<EOF
usage: harness <command> [args]
  init                 interactive setup wizard (writes config, creates labels, seeds repo)
  start [--recover]    launch the worker pool (--recover = crash/new-host sweep first)
  stop  [--clean]      stop the pool (--clean also removes worktrees)
  status [--watch [s]] dashboard
  attach <unit> [issue] tmux-attach to a session
EOF
}
cmd="${1:-}"; shift || true
case "$cmd" in
  init)   exec bash "$HARNESS_DIR/init.sh" "$@";;
  start)  exec bash "$HARNESS_DIR/start.sh" "$@";;
  stop)   exec bash "$HARNESS_DIR/stop.sh" "$@";;
  status) exec bash "$HARNESS_DIR/status.sh" "$@";;
  attach) exec bash "$HARNESS_DIR/attach.sh" "$@";;
  help|-h|--help) usage;;
  "") usage; exit 2;;
  *) echo "unknown command: $cmd" >&2; usage; exit 2;;
esac
```

- [ ] **Step 4: Run it** — `bash test/test_cli.sh` — Expected: `ok`.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: bin/harness CLI dispatcher"`

---

### Task 11: `init.sh` — interactive setup wizard

**Files:**
- Create: `init.sh`
- Test: `test/test_init.sh`

The wizard prompts (with defaults), writes `$CONFIG` in `: "${KEY:=val}"` form, runs `seed_if_needed` for label creation, and for multi topology scaffolds `targets.tsv`. **Non-interactive mode** for tests + CI: if stdin is not a TTY or `HARNESS_INIT_NONINTERACTIVE=1`, read values from `HARNESS_*` env and write config without prompting.

- [ ] **Step 1: Write the failing test** `test/test_init.sh` (drives non-interactive; asserts config round-trips and env overrides it)

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; cp -r "$HERE/.." "$TMP/.harness"   # fake .harness checkout
export HARNESS_DIR="$TMP/.harness"
# stub gh + seed so init does no network
cat > "$TMP/.harness/seed.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
HARNESS_INIT_NONINTERACTIVE=1 HARNESS_MODE=prd HARNESS_TOPOLOGY=single \
  HARNESS_OWNER=acme HARNESS_REPO=acme/widget HARNESS_AUTONOMOUS=false \
  bash "$TMP/.harness/init.sh"
CFG="$TMP/.harness/config"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
assert "config written"           "[[ -f '$CFG' ]]"
assert "config uses := form"      "grep -q ':= ' '$CFG' || grep -q ':=issue' '$CFG' || grep -q 'HARNESS_MODE:=prd' '$CFG'"
# round-trip: sourcing config yields the chosen values
( source "$CFG"; [[ "${HARNESS_MODE:-}" == prd && "${HARNESS_REPO:-}" == acme/widget && "${HARNESS_AUTONOMOUS:-}" == false ]] ) \
  && echo "  ok: config round-trips" || { echo "  FAIL: round-trip"; exit 1; }
# env override: pre-set env beats file (because lines are := )
( HARNESS_MODE=planned; source "$CFG"; [[ "$HARNESS_MODE" == planned ]] ) \
  && echo "  ok: env overrides file" || { echo "  FAIL: env override"; exit 1; }
echo "── init ok"
```

- [ ] **Step 2: Run it** — Expected: FAIL.
- [ ] **Step 3: Implement `init.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail
HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CONFIG="$HARNESS_DIR/config"
ni="${HARNESS_INIT_NONINTERACTIVE:-0}"; [[ -t 0 ]] || ni=1
ask(){ local var="$1" prompt="$2" def="$3" val
  if [[ "$ni" == 1 ]]; then val="${!var:-$def}"; else read -rp "$prompt [$def]: " val; val="${val:-$def}"; fi
  printf -v "$var" '%s' "$val"; }
ask HARNESS_MODE       "Mode (issue-only|prd|planned)"   "${HARNESS_MODE:-issue-only}"
ask HARNESS_TOPOLOGY   "Topology (single|multi)"          "${HARNESS_TOPOLOGY:-single}"
ask HARNESS_OWNER      "GitHub owner/org"                 "${HARNESS_OWNER:-}"
[[ "$HARNESS_TOPOLOGY" == single ]] && ask HARNESS_REPO "Target repo (owner/repo)" "${HARNESS_REPO:-}"
[[ "$HARNESS_MODE" == planned ]] && ask HARNESS_SPEC "Spec path (planned mode)" "${HARNESS_SPEC:-}"
ask HARNESS_AUTONOMOUS "Fully autonomous? (true|false)"   "${HARNESS_AUTONOMOUS:-true}"
ask HARNESS_POOL       "Pool workers"                     "${HARNESS_POOL:-3}"
ask HARNESS_CAP        "Sessions per unit"                "${HARNESS_CAP:-3}"
ask HARNESS_POLL       "Poll interval (s)"                "${HARNESS_POLL:-60}"
ask HARNESS_LABEL_READY "Dispatchable label"              "${HARNESS_LABEL_READY:-ready-for-agent}"
ask HARNESS_LABEL_PRD   "PRD label"                       "${HARNESS_LABEL_PRD:-prd}"
{
  echo "# Harness per-project config — written by 'harness init'."
  echo "# Lines use := so a pre-set environment variable overrides this file."
  for v in HARNESS_MODE HARNESS_TOPOLOGY HARNESS_OWNER HARNESS_REPO HARNESS_SPEC HARNESS_AUTONOMOUS \
           HARNESS_POOL HARNESS_CAP HARNESS_POLL HARNESS_LABEL_READY HARNESS_LABEL_PRD \
           HARNESS_LABEL_WORKING HARNESS_LABEL_BLOCKED HARNESS_LABEL_REVIEWED HARNESS_LABEL_COORD; do
    printf ': "${%s:=%s}"\n' "$v" "${!v:-}"
  done
} > "$CONFIG"
echo "wrote $CONFIG"
if [[ "$ni" != 1 ]]; then
  source "$HARNESS_DIR/lib.sh"
  if [[ "$HARNESS_TOPOLOGY" == single ]]; then seed_if_needed main
  else [[ -f "$TARGETS_TSV" ]] || printf '# id\trepo\tdeps(comma|-)\tdesc\n' > "$TARGETS_TSV"; echo "edit $TARGETS_TSV to list your repos + deps"; fi
fi
```

> Note: defaults for `HARNESS_LABEL_WORKING/BLOCKED/REVIEWED/COORD` are written from their current env (set by lib.sh defaults) — ensure `init.sh` sources defaults or hardcodes them in the loop. Simplest: `: "${HARNESS_LABEL_WORKING:=agent-working}"` etc. before the write block.

- [ ] **Step 4: Run it** — `bash test/test_init.sh` — Expected: all `ok`.
- [ ] **Step 5: Full suite** — `bash test/run.sh` — Expected: green.
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: init.sh interactive wizard (non-interactive mode for CI)"`

---

### Task 12: `install.sh` — prereqs, skills, clone, init

**Files:**
- Create: `install.sh`
- Test: `test/test_install.sh`

`install.sh` must: (1) gate prerequisites; (2) ensure required skills; (3) clone/update `.harness`; (4) install `/harness` skill; (5) gitignore `.harness/`; (6) run `harness init`. For testability, factor the prereq gate into a `check_prereqs` function and the skill check into `ensure_skills`, both overridable, and guard `main` so the test can source without executing.

- [ ] **Step 1: Write the failing test** `test/test_install.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# source install.sh with main guarded; PATH stubs to simulate missing tools
export HARNESS_INSTALL_NOMAIN=1
source "$HERE/../install.sh"
# all present -> ok
have(){ return 0; }; gh(){ return 0; }; command(){ return 0; }
PATHBIN="$(mktemp -d)"; export PATH="$PATHBIN:$PATH"
for t in git tmux python3 gh claude; do printf '#!/bin/sh\nexit 0\n' > "$PATHBIN/$t"; chmod +x "$PATHBIN/$t"; done
printf '#!/bin/sh\ncase "$1" in auth) exit 0;; esac\nexit 0\n' > "$PATHBIN/gh"; chmod +x "$PATHBIN/gh"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
assert "prereqs pass when all present" "check_prereqs"
# remove claude -> fail
rm -f "$PATHBIN/claude"
assert "prereqs fail without claude"   "! check_prereqs 2>/dev/null"
printf '#!/bin/sh\nexit 0\n' > "$PATHBIN/claude"; chmod +x "$PATHBIN/claude"
# unauthenticated gh -> fail
printf '#!/bin/sh\ncase "$1" in auth) exit 1;; esac\nexit 0\n' > "$PATHBIN/gh"; chmod +x "$PATHBIN/gh"
assert "prereqs fail when gh not authed" "! check_prereqs 2>/dev/null"
echo "── install ok"
```

- [ ] **Step 2: Run it** — Expected: FAIL.
- [ ] **Step 3: Implement `install.sh`**

```bash
#!/usr/bin/env bash
set -uo pipefail
HARNESS_REPO_URL="${HARNESS_REPO_URL:-https://github.com/RainBowCreation/Harness.git}"
# superpowers + ralph-loop sources (CONFIRM at review — see spec Open assumptions 4/5)
SKILLS_SUPERPOWERS_URL="${SKILLS_SUPERPOWERS_URL:-https://github.com/mattpocock/skills}"

need(){ command -v "$1" >/dev/null 2>&1; }
check_prereqs(){
  local ok=1
  for b in git tmux python3; do need "$b" || { echo "MISSING: $b" >&2; ok=0; }; done
  if ! need gh; then echo "MISSING: gh (install: https://cli.github.com)" >&2; ok=0
  elif ! gh auth status >/dev/null 2>&1; then echo "gh not authenticated — run: gh auth login" >&2; ok=0; fi
  if ! need claude; then echo "MISSING: claude (Claude Code CLI)" >&2; ok=0
  elif ! claude --version >/dev/null 2>&1; then echo "claude present but not runnable (model configured?)" >&2; ok=0; fi
  [[ "$ok" == 1 ]]
}
ensure_skills(){
  # idempotent: install superpowers (writing-plans/to-prd/to-issues/subagent-driven-development/
  # test-driven-development) and ralph-loop into the user's Claude if absent.
  echo "ensuring required Claude skills (superpowers + ralph-loop) ..."
  # CONFIRM mechanism at review (plugin marketplace vs clone into ~/.claude/plugins).
}
main(){
  check_prereqs || { echo "Prerequisites unmet — fix the above and re-run." >&2; exit 1; }
  ensure_skills
  if [[ -d .harness/.git ]]; then git -C .harness pull --ff-only; else git clone "$HARNESS_REPO_URL" .harness; fi
  mkdir -p .claude/skills/harness && cp .harness/skill/SKILL.md .claude/skills/harness/SKILL.md
  grep -qxF '.harness/' .gitignore 2>/dev/null || echo '.harness/' >> .gitignore
  bash .harness/init.sh
  echo "Done. Start with: .harness/bin/harness start   (or ask Claude: /harness)"
}
[[ "${HARNESS_INSTALL_NOMAIN:-0}" == 1 ]] || main "$@"
```

- [ ] **Step 4: Run it** — `bash test/test_install.sh` — Expected: all `ok`.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: install.sh — prereq gate, skill provisioning, clone+init"`

---

### Task 13: `/harness` management skill

**Files:**
- Create: `skill/SKILL.md`
- Test: `test/test_skill.sh`

- [ ] **Step 1: Write the failing test** `test/test_skill.sh`

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/../skill/SKILL.md"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
assert "skill file exists"        "[[ -f '$S' ]]"
assert "has name frontmatter"     "head -5 '$S' | grep -q '^name:'"
assert "has description"          "head -8 '$S' | grep -q '^description:'"
assert "documents start"          "grep -q 'harness start' '$S'"
assert "documents stop"           "grep -q 'harness stop' '$S'"
assert "documents status"         "grep -q 'harness status' '$S'"
echo "── skill ok"
```

- [ ] **Step 2: Run it** — Expected: FAIL.
- [ ] **Step 3: Write `skill/SKILL.md`** (generalized from Bonsai's `/kanban` skill)

```markdown
---
name: harness
description: Operate the Harness agent fleet for this project — start/stop/status the worker pool, watch sessions, and unstick the GitHub-issue board. Trigger on /harness or requests like "start the fleet", "what's the harness doing".
---

# /harness — operate the agent fleet

The board is **GitHub issues**; the dispatcher is the worker pool under `.harness/`. State is 100%
in GitHub + a local run dir, so it is stateless and resumable. Your role is operate + observe +
unstick — never hand-do a unit's PLAN/PRD/IMPL work; let the pool dispatch it.

## Commands
```bash
.harness/bin/harness start            # launch the worker pool
.harness/bin/harness start --recover  # crash/new-host recovery sweep, then launch
.harness/bin/harness status           # one-shot dashboard
.harness/bin/harness status --watch   # live dashboard (Ctrl-C stops watching, NOT the fleet)
.harness/bin/harness attach <unit> [issue]   # tmux-attach to a session
.harness/bin/harness stop             # stop the pool
.harness/bin/harness stop --clean     # also remove worktrees
```

## Reading the dashboard
Per unit it prints the `issuelib.py status` line: `mode=… PRD#… plan=… children=… open=… unblocked=… reviewed=… complete=…`.
- `complete=Y` and idle ⇒ DONE, not stuck.
- `open>0 unblocked=0` with no live session ⇒ likely a mis-pointed `## Blocked by` — investigate.

## Unstick (read-mostly)
- Free a stale lock: `gh issue edit <n> -R <repo> --remove-label agent-working`.
- Fix a wrong dependency: edit the issue's `## Blocked by`.
- Crash/migration: `.harness/bin/harness start --recover`.

## Modes & config
`.harness/config` sets `HARNESS_MODE` (issue-only|prd|planned), topology, labels, pool size. In
`issue-only` just label an issue `ready-for-agent` (not `prd`) and a worker picks it up. In `prd`
mode a human writes one `prd`-labelled issue; the agent decomposes + implements + reviews.

## When NOT to touch
Don't `--clean` while sessions are live unless discarding their worktrees. Don't do a unit's work
by hand — operate the fleet, like a CI operator.
```

- [ ] **Step 4: Run it** — `bash test/test_skill.sh` — Expected: all `ok`.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: /harness management skill"`

---

### Task 14: README + end-to-end dry-run smoke

**Files:**
- Create: `README.md`
- Test: `test/test_e2e.sh`

- [ ] **Step 1: Write `test/test_e2e.sh`** — an offline end-to-end of the issue-only single-repo decision path with `gh` fully stubbed (no network), asserting the pool would dispatch IMPL for two ready issues then report complete when they close.

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HARNESS_MODE=issue-only HARNESS_TOPOLOGY=single HARNESS_REPO=acme/widget HARNESS_OWNER=acme
# stub gh issue list to return two open ready issues, no prd
STUB="$(mktemp -d)"; export PATH="$STUB:$PATH"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "issue list" ]]; then
  echo '[{"number":5,"title":"a","state":"OPEN","labels":[{"name":"ready-for-agent"}],"body":""},
        {"number":6,"title":"b","state":"OPEN","labels":[{"name":"ready-for-agent"}],"body":""}]'
elif [[ "$1" == "api" ]]; then exit 1   # no PLAN.md
else echo '{}'; fi
EOF
chmod +x "$STUB/gh"
out="$(python3 "$HERE/../issuelib.py" dispatch acme/widget 3 --allow-orchestration 1)"
echo "$out" | grep -q '^IMPL	5' && echo "  ok: dispatch IMPL #5" || { echo FAIL; exit 1; }
echo "$out" | grep -q '^IMPL	6' && echo "  ok: dispatch IMPL #6" || { echo FAIL; exit 1; }
echo "$out" | grep -q 'PLAN\|PRD\|DECOMPOSE' && { echo "FAIL: issue-only emitted orchestration"; exit 1; } || echo "  ok: no orchestration in issue-only"
# now both closed -> complete
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "issue list" ]]; then
  echo '[{"number":5,"title":"a","state":"CLOSED","labels":[{"name":"ready-for-agent"}],"body":""},
        {"number":6,"title":"b","state":"CLOSED","labels":[{"name":"ready-for-agent"}],"body":""}]'
elif [[ "$1" == "api" ]]; then exit 1; else echo '{}'; fi
EOF
chmod +x "$STUB/gh"
[[ "$(python3 "$HERE/../issuelib.py" complete acme/widget)" == DONE ]] && echo "  ok: complete when all closed" || { echo FAIL; exit 1; }
echo "── e2e ok"
```

- [ ] **Step 2: Run it** — `bash test/test_e2e.sh` — Expected: all `ok`.
- [ ] **Step 3: Write `README.md`** — install one-liner, the 3 modes table, 2 topologies, config keys, commands, `/harness` skill, prereqs (gh auth, claude+model, superpowers + ralph-loop). Mirror the spec.
- [ ] **Step 4: Full suite** — `bash test/run.sh` — Expected: ALL green.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "docs: README + offline e2e smoke"`

---

### Task 15: Publish + verify install on a throwaway project

**Files:** none new (publish + manual verification)

- [ ] **Step 1: Create the public repo and push**

```bash
# from the repo root
gh repo create RainBowCreation/Harness --public --source=. --remote=origin --push \
  --description "Project-agnostic autonomous agent fleet for a GitHub-issues board"
```
Expected: repo created, `main` pushed.

- [ ] **Step 2: Verify the raw install URL resolves**

```bash
curl -fsSL https://raw.githubusercontent.com/RainBowCreation/Harness/main/install.sh | head -3
```
Expected: prints the install.sh shebang/header (confirms the curl|bash URL in the spec is live).

- [ ] **Step 3: Dry-run install into a scratch dir** (a throwaway repo you own) — run the one-liner, answer the wizard with `issue-only` + `single` + the scratch repo, confirm `.harness/` clones, labels are created (`gh label list`), `.claude/skills/harness/SKILL.md` exists, and `.harness/bin/harness status` renders. Do **not** run `start` unless you intend to spend agent time.

- [ ] **Step 4: Commit any fixes** found during the dry run, push.

---

## Notes for the executor

- Work in this repo — `/media/nathanielsong/Sata Programming/VSCode/Harness`. It is a fresh `git init` repo (not a worktree of Bonsai) so the using-git-worktrees check should detect a normal repo and proceed in place.
- `$SRC` = `/media/nathanielsong/Sata Programming/IdeaProjects/Bonsai/harness/`. Read the named source files to port; apply the rename map in the header. Ports must keep behavior identical except the documented generalizations.
- After every task, the full `bash test/run.sh` must be green before moving on.
- Bonsai's own `harness/` is **not touched** by this plan.
