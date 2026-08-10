#!/usr/bin/env bash
# test_spawn.sh — regression tests for spawn_orch / spawn_impl bugs:
#   C1: $SPEC unbound variable under set -u
#   I1: multi topology label leak when clone fails
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/../scripts/drive.sh"
source "$HERE/helpers.sh"
make_env

# ── shared setup ─────────────────────────────────────────────────────────────
# A scratch dir that exists but is NOT a git repo (used for single-topology tests).
FAKE_CHECKOUT="$(mktemp -d)"
CALLS="$RUN_DIR/calls"

# drive_unit sets these as locals; for direct spawn_* calls we set them in scope.
UNIT=main
SLUG=acme/widget
PROJECT=main
DESC=widget

# Stub out everything that does real I/O so the test is hermetic.
# Each stub appends a record to $CALLS so we can inspect what was called.
stub_common(){
  : > "$CALLS"
  # tmux: always succeed, record the call
  tmux(){ echo "tmux $*" >> "$CALLS"; return 0; }
  # launch_claude: always succeed
  launch_claude(){ echo "launch_claude $*" >> "$CALLS"; return 0; }
  # render: always succeed (writes nothing to stdout — redirect in spawn_* goes to /dev/null via stub)
  render(){ echo "render $*" >> "$CALLS"; return 0; }
  # default_branch: return "main" without touching network
  default_branch(){ echo main; }
  # ensure_safe: no-op
  ensure_safe(){ :; }
}

# ── Test group 1: C1 — $SPEC must not be unbound ────────────────────────────
# We run spawn_impl and spawn_orch each in a subshell with set -uo pipefail
# so that any unbound-variable expansion causes an immediate nonzero exit.
# The tests assert the subshell exits 0 (no unbound-variable crash).

echo "=== C1: SPEC unbound variable ==="

# Single-topology spawn_impl
assert_ok "spawn_impl: no unbound-var crash (C1)" bash -c '
  set -uo pipefail
  HERE="'"$HERE"'"
  RUN_DIR="'"$RUN_DIR"'"
  WORKTREES_DIR="'"$WORKTREES_DIR"'"
  FAKE_CHECKOUT="'"$FAKE_CHECKOUT"'"
  source "'"$HERE"'/../scripts/lib.sh"
  source "'"$HERE"'/../scripts/drive.sh"
  # Stubs
  tmux(){ :; }; render(){ :; }; launch_claude(){ :; }
  default_branch(){ echo main; }; ensure_safe(){ :; }
  git(){ :; }; gh(){ :; }
  # HARNESS_SPEC intentionally empty (as in a fresh env); SPEC is never defined
  HARNESS_TOPOLOGY=single
  HARNESS_REPO=acme/widget
  HARNESS_SPEC=""
  # drive_unit locals — set here for direct spawn_impl call
  UNIT=main; SLUG=acme/widget; PROJECT=main; DESC=widget
  CHECKOUT="$FAKE_CHECKOUT"
  PROMISE="ISSUE 5 DONE"; MAXITER=30; GOAL="ISSUE:5"
  spawn_impl 5 "ISSUE 5 DONE"
'

# Single-topology spawn_orch
assert_ok "spawn_orch: no unbound-var crash (C1)" bash -c '
  set -uo pipefail
  HERE="'"$HERE"'"
  RUN_DIR="'"$RUN_DIR"'"
  WORKTREES_DIR="'"$WORKTREES_DIR"'"
  FAKE_CHECKOUT="'"$FAKE_CHECKOUT"'"
  source "'"$HERE"'/../scripts/lib.sh"
  source "'"$HERE"'/../scripts/drive.sh"
  tmux(){ :; }; render(){ :; }; launch_claude(){ :; }
  default_branch(){ echo main; }; ensure_safe(){ :; }
  git(){ :; }; gh(){ :; }
  HARNESS_TOPOLOGY=single
  HARNESS_REPO=acme/widget
  HARNESS_SPEC=""
  UNIT=main; SLUG=acme/widget; PROJECT=main; DESC=widget
  CHECKOUT="$FAKE_CHECKOUT"
  PROMISE="PLAN DONE"; MAXITER=8; GOAL="PLAN"
  spawn_orch PLAN "" "PLAN DONE"
'

# ── Test group 2: I1 — clone guard prevents label leak ───────────────────────
echo "=== I1: multi-topology clone guard ==="

# Sub-test A: when git clone FAILS, spawn_impl must return nonzero AND must NOT
# have called gh with --add-label (i.e. label is not applied before the guard).
CALLS_I1="$RUN_DIR/calls_i1"
assert_no "spawn_impl returns nonzero when clone fails (I1)" bash -c '
  set -uo pipefail
  HERE="'"$HERE"'"
  RUN_DIR="'"$RUN_DIR"'"
  WORKTREES_DIR="'"$WORKTREES_DIR"'"
  CALLS_I1="'"$CALLS_I1"'"
  : > "$CALLS_I1"
  source "'"$HERE"'/../scripts/lib.sh"
  source "'"$HERE"'/../scripts/drive.sh"
  # git: rev-parse fails (no repo) and clone fails; everything else succeeds and is recorded.
  # This precisely models a fresh $CHECKOUT dir that is not a git repo + a failing network clone.
  git(){
    echo "git $*" >> "$CALLS_I1"
    # "git -C <dir> rev-parse --git-dir" — signals "not a git repo" → trigger clone path
    [[ "$1" == -C && "$3" == rev-parse ]] && return 1
    # clone: fail to simulate network/permissions error
    [[ "$1" == clone ]] && return 1
    return 0
  }
  gh(){ echo "gh $*" >> "$CALLS_I1"; return 0; }
  tmux(){ echo "tmux $*" >> "$CALLS_I1"; return 0; }
  render(){ echo "render $*" >> "$CALLS_I1"; return 0; }
  launch_claude(){ echo "launch_claude $*" >> "$CALLS_I1"; return 0; }
  default_branch(){ echo main; }; ensure_safe(){ :; }
  HARNESS_TOPOLOGY=multi
  HARNESS_REPO=acme/widget
  HARNESS_SPEC=""
  FRESH_CHECKOUT="$(mktemp -d)"
  UNIT=main; SLUG=acme/widget; PROJECT=main; DESC=widget
  CHECKOUT="$FRESH_CHECKOUT"
  PROMISE="ISSUE 5 DONE"
  spawn_impl 5 "ISSUE 5 DONE"
'

# Sub-test B: confirm no add-label call was recorded (label not leaked)
assert_eq "$(grep -c 'add-label' "$CALLS_I1" 2>/dev/null; true)" "0" \
  "gh --add-label NOT called when clone fails (I1 label leak)"

# Sub-test C: when clone succeeds, spawn_impl SHOULD apply the label
CALLS_I1_OK="$RUN_DIR/calls_i1_ok"
assert_ok "spawn_impl succeeds and labels when clone succeeds (I1)" bash -c '
  set -uo pipefail
  HERE="'"$HERE"'"
  RUN_DIR="'"$RUN_DIR"'"
  WORKTREES_DIR="$(mktemp -d)"
  CALLS_I1_OK="'"$CALLS_I1_OK"'"
  : > "$CALLS_I1_OK"
  source "'"$HERE"'/../scripts/lib.sh"
  source "'"$HERE"'/../scripts/drive.sh"
  git(){
    echo "git $*" >> "$CALLS_I1_OK"
    # rev-parse: always return 1 on first call (no repo yet), then 0 after clone
    if [[ "$1" == -C && "$3" == rev-parse ]]; then
      [[ -d "${2}/.git" ]] && return 0 || return 1
    fi
    # clone: succeed and create a minimal .git dir so rev-parse check passes afterwards
    if [[ "$1" == clone ]]; then
      tgt="${@: -1}"
      mkdir -p "$tgt/.git"
      return 0
    fi
    # worktree add: create the target dir so the render redirect succeeds
    if [[ "$1" == -C && "$3" == worktree ]]; then
      # find the target path argument (after "add -B <branch>")
      local i; for (( i=1; i<=$#; i++ )); do
        local a="${!i}"
        if [[ "$a" == "$WORKTREES_DIR"* ]]; then mkdir -p "$a"; break; fi
      done
    fi
    return 0
  }
  gh(){ echo "gh $*" >> "$CALLS_I1_OK"; return 0; }
  tmux(){ echo "tmux $*" >> "$CALLS_I1_OK"; return 0; }
  render(){ echo "render $*" >> "$CALLS_I1_OK"; return 0; }
  launch_claude(){ echo "launch_claude $*" >> "$CALLS_I1_OK"; return 0; }
  default_branch(){ echo main; }; ensure_safe(){ :; }
  HARNESS_TOPOLOGY=multi
  HARNESS_REPO=acme/widget
  HARNESS_SPEC=""
  FRESH_CHECKOUT="$(mktemp -d)"
  UNIT=main; SLUG=acme/widget; PROJECT=main; DESC=widget
  CHECKOUT="$FRESH_CHECKOUT"
  PROMISE="ISSUE 5 DONE"
  spawn_impl 5 "ISSUE 5 DONE"
'

assert_eq "$(grep -c 'add-label' "$CALLS_I1_OK" 2>/dev/null || echo 0)" "1" \
  "gh --add-label called exactly once when clone succeeds (I1)"

# ── Test group 3: #67 — auto-trust the launch dir so a fresh tree doesn't stall ──
# launch_claude funnels every spawn through an INTERACTIVE Claude TUI in tmux. On a tree that was
# never trusted, Claude Code blocks forever at "Do you trust the files in this folder?" —
# --dangerously-skip-permissions suppresses tool-permission prompts but NOT the workspace-trust
# gate, and the only bypass (-p / non-interactive) is unusable here. ensure_trusted pre-accepts the
# gate by setting projects["$wd"].hasTrustDialogAccepted=true in ~/.claude.json, mirroring
# ensure_safe. Tests point HARNESS_CLAUDE_CONFIG at a temp fixture so the real ~/.claude.json is untouched.
echo "=== #67: ensure_trusted pre-accepts the workspace-trust dialog ==="

# tiny JSON probes (python3 is a hard dep of the harness already)
trusted_of(){ python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); print(d.get("projects",{}).get(sys.argv[2],{}).get("hasTrustDialogAccepted"))' "$1" "$2" 2>/dev/null; }
json_ok(){ python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; }
field_of(){ python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); print(d.get("projects",{}).get(sys.argv[2],{}).get(sys.argv[3],"<absent>"))' "$1" "$2" "$3" 2>/dev/null; }
topkey_of(){ python3 -c 'import json,sys
print(json.load(open(sys.argv[1])).get(sys.argv[2],"<absent>"))' "$1" "$2" 2>/dev/null; }
nproj_of(){ python3 -c 'import json,sys
print(len(json.load(open(sys.argv[1])).get("projects",{})))' "$1" 2>/dev/null; }

# A1: absent config → ensure_trusted creates the file + projects map and trusts the fresh dir.
T_CFG="$RUN_DIR/claude_a1.json"; rm -f "$T_CFG"; T_WD="$(mktemp -d)"
HARNESS_AUTONOMOUS=true HARNESS_CLAUDE_CONFIG="$T_CFG" ensure_trusted "$T_WD"
assert_eq "$(trusted_of "$T_CFG" "$T_WD")" "True" "fresh dir trusted; config created from absent (A1)"
assert_ok "config is valid JSON after creating from absent (A1)" json_ok "$T_CFG"

# A2: a populated config is preserved — every top-level key and every existing project field stays,
# only the new path's trust flag is added.
T_CFG2="$RUN_DIR/claude_a2.json"; T_WD2="$(mktemp -d)"
python3 - "$T_CFG2" <<'PY'
import json,sys
json.dump({
  "userID":"keep-me","numStartups":42,
  "projects":{"/old/proj":{"hasTrustDialogAccepted":True,"allowedTools":["Bash"],"lastCost":1.5}},
}, open(sys.argv[1],"w"), indent=2)
PY
HARNESS_AUTONOMOUS=true HARNESS_CLAUDE_CONFIG="$T_CFG2" ensure_trusted "$T_WD2"
assert_ok "config still valid JSON after merge (A2)" json_ok "$T_CFG2"
assert_eq "$(trusted_of "$T_CFG2" "$T_WD2")" "True" "new path trusted (A2)"
assert_eq "$(topkey_of "$T_CFG2" userID)" "keep-me" "top-level key 'userID' preserved (A2)"
assert_eq "$(topkey_of "$T_CFG2" numStartups)" "42" "top-level key 'numStartups' preserved (A2)"
assert_eq "$(trusted_of "$T_CFG2" /old/proj)" "True" "existing project entry preserved (A2)"
assert_eq "$(field_of "$T_CFG2" /old/proj lastCost)" "1.5" "existing project's other fields preserved (A2)"

# A3: idempotent — re-trusting an already-trusted dir is a no-op (no duplicate entry, no churn).
NPROJ_BEFORE="$(nproj_of "$T_CFG2")"
HARNESS_AUTONOMOUS=true HARNESS_CLAUDE_CONFIG="$T_CFG2" ensure_trusted "$T_WD2"
assert_eq "$(nproj_of "$T_CFG2")" "$NPROJ_BEFORE" "re-trust adds no duplicate project entry (A3)"
assert_eq "$(trusted_of "$T_CFG2" "$T_WD2")" "True" "re-trust leaves the flag true (A3)"
assert_ok "config still valid JSON after idempotent re-trust (A3)" json_ok "$T_CFG2"

# A4: race-safe — many agents call launch_claude near-simultaneously. Concurrent writes against the
# SAME config must neither corrupt the file nor lose any update (the lock/atomic-rename requirement).
T_CFGR="$RUN_DIR/claude_race.json"; rm -f "$T_CFGR"; RPATHS=()
for i in $(seq 1 12); do
  rp="$(mktemp -d)"; RPATHS+=("$rp")
  ( HARNESS_AUTONOMOUS=true HARNESS_CLAUDE_CONFIG="$T_CFGR" ensure_trusted "$rp" ) &
done
wait
assert_ok "config valid JSON after 12 concurrent ensure_trusted (A4 race-safe)" json_ok "$T_CFGR"
RMISS=0; for rp in "${RPATHS[@]}"; do [[ "$(trusted_of "$T_CFGR" "$rp")" == "True" ]] || RMISS=$((RMISS+1)); done
assert_eq "$RMISS" "0" "all 12 concurrently-trusted paths present (A4 no lost update)"

# A5: scoped to autonomous — a supervised launch keeps Claude Code's default trust prompt (no write).
T_CFG5="$RUN_DIR/claude_a5.json"; rm -f "$T_CFG5"; T_WD5="$(mktemp -d)"
HARNESS_AUTONOMOUS=false HARNESS_CLAUDE_CONFIG="$T_CFG5" ensure_trusted "$T_WD5"
assert_no "supervised (HARNESS_AUTONOMOUS=false) does NOT auto-trust (A5)" test -f "$T_CFG5"

# A6: integration — the real launch_claude pre-trusts its launch dir before driving the TUI.
T_CFG6="$RUN_DIR/claude_a6.json"; rm -f "$T_CFG6"
T_WD6="$(mktemp -d)"; echo "do the thing" > "$T_WD6/.harness-task.md"
(
  # has-session must report NOT live (return 1) so the #108 guard doesn't short-circuit this fresh spawn
  tmux(){ [[ "$1" == has-session ]] && return 1; return 0; }; sleep(){ :; }   # never touch the real fleet, no 1.5s wait
  PROMISE="X DONE"; MAXITER=30; GOAL="ISSUE:9"
  HARNESS_AUTONOMOUS=true HARNESS_CLAUDE_CONFIG="$T_CFG6" launch_claude "test-sess-67" "$T_WD6" >/dev/null 2>&1
)
assert_eq "$(trusted_of "$T_CFG6" "$T_WD6")" "True" "launch_claude pre-trusts its launch dir (A6 integration)"

# ── Test group 3b: #67 follow-up — pre-accept must land in the config Claude Code actually READS ──
# Claude Code reads workspace trust from $CLAUDE_CONFIG_DIR/.claude.json when that is set, else
# ~/.claude.json. With the claude-acc account switcher installed, ~/.bashrc exports CLAUDE_CONFIG_DIR
# in EVERY interactive bash — including the one `tmux new-session` opens for the lane — so the pane
# reads ~/.claude-switch/accounts/<acct>/.claude.json while ensure_trusted was writing ~/.claude.json,
# and the #67 gate came back. The account is chosen AFTER ensure_trusted runs (the pool worker carries
# no CLAUDE_CONFIG_DIR of its own), so there is no single correct target: seed them all.
echo "=== #67b: ensure_trusted seeds every config Claude Code might read ==="

# fixture: a $HOME that looks like a claude-acc install with two provisioned accounts
mk_acc_home(){ local h; h="$(mktemp -d)"; mkdir -p "$h/.claude-switch/accounts/main" "$h/.claude-switch/accounts/sub"; printf '%s' "$h"; }

# B1: fan-out — ~/.claude.json AND every per-account config get the trust entry.
T_HOMEB="$(mk_acc_home)"; T_WDB="$(mktemp -d)"
( HOME="$T_HOMEB"; unset HARNESS_CLAUDE_CONFIG; HARNESS_AUTONOMOUS=true; ensure_trusted "$T_WDB" )
assert_eq "$(trusted_of "$T_HOMEB/.claude.json" "$T_WDB")" "True" "~/.claude.json trusted (B1)"
assert_eq "$(trusted_of "$T_HOMEB/.claude-switch/accounts/main/.claude.json" "$T_WDB")" "True" "account 'main' config trusted (B1)"
assert_eq "$(trusted_of "$T_HOMEB/.claude-switch/accounts/sub/.claude.json" "$T_WDB")" "True" "account 'sub' config trusted (B1)"

# B2: an account config is MERGED, never clobbered — it carries that account's identity + history.
T_HOMEB2="$(mk_acc_home)"; T_WDB2="$(mktemp -d)"
T_ACC2="$T_HOMEB2/.claude-switch/accounts/main/.claude.json"
python3 - "$T_ACC2" <<'PY'
import json,sys
json.dump({"oauthAccount":{"emailAddress":"a@b.c"},"numStartups":7,
           "projects":{"/old/proj":{"hasTrustDialogAccepted":True,"lastCost":2.5}}},
          open(sys.argv[1],"w"), indent=2)
PY
( HOME="$T_HOMEB2"; unset HARNESS_CLAUDE_CONFIG; HARNESS_AUTONOMOUS=true; ensure_trusted "$T_WDB2" )
assert_ok "account config still valid JSON after merge (B2)" json_ok "$T_ACC2"
assert_eq "$(trusted_of "$T_ACC2" "$T_WDB2")" "True" "new path trusted in account config (B2)"
assert_eq "$(topkey_of "$T_ACC2" numStartups)" "7" "account identity/top-level keys preserved (B2)"
assert_eq "$(trusted_of "$T_ACC2" /old/proj)" "True" "existing account project entry preserved (B2)"
assert_eq "$(field_of "$T_ACC2" /old/proj lastCost)" "2.5" "existing project's other fields preserved (B2)"

# B3: no account switcher installed → home config only, and no phantom .claude-switch tree is created
# (the unmatched glob must not be written out as a literal path).
T_HOMEB3="$(mktemp -d)"; T_WDB3="$(mktemp -d)"
( HOME="$T_HOMEB3"; unset HARNESS_CLAUDE_CONFIG; HARNESS_AUTONOMOUS=true; ensure_trusted "$T_WDB3" )
assert_eq "$(trusted_of "$T_HOMEB3/.claude.json" "$T_WDB3")" "True" "plain \$HOME still trusted with no switcher (B3)"
assert_no "unmatched account glob creates nothing (B3)" test -e "$T_HOMEB3/.claude-switch"

# B4: CLAUDE_CONFIG_DIR exported into the worker (a config dir outside the switcher) is seeded too.
T_HOMEB4="$(mktemp -d)"; T_CCD="$(mktemp -d)"; T_WDB4="$(mktemp -d)"
( HOME="$T_HOMEB4"; unset HARNESS_CLAUDE_CONFIG; export CLAUDE_CONFIG_DIR="$T_CCD"; HARNESS_AUTONOMOUS=true; ensure_trusted "$T_WDB4" )
assert_eq "$(trusted_of "$T_CCD/.claude.json" "$T_WDB4")" "True" "\$CLAUDE_CONFIG_DIR config trusted (B4)"

# B5: the HARNESS_CLAUDE_CONFIG test seam stays single-file — it must never fan out onto a real $HOME.
T_HOMEB5="$(mk_acc_home)"; T_WDB5="$(mktemp -d)"; T_CFGB5="$RUN_DIR/claude_b5.json"; rm -f "$T_CFGB5"
( HOME="$T_HOMEB5"; HARNESS_AUTONOMOUS=true; HARNESS_CLAUDE_CONFIG="$T_CFGB5" ensure_trusted "$T_WDB5" )
assert_eq "$(trusted_of "$T_CFGB5" "$T_WDB5")" "True" "seam config trusted (B5)"
assert_no "seam does not write \$HOME/.claude.json (B5)" test -e "$T_HOMEB5/.claude.json"
assert_no "seam does not write account configs (B5)" test -e "$T_HOMEB5/.claude-switch/accounts/main/.claude.json"

# ── Test group 4: #108 — guard launch_claude against re-dispatch into a live session ──
# launch_claude must short-circuit to a no-op when its target session is ALREADY live: re-dispatch
# (e.g. a transiently-dropped agent-working label) must never write_state, new-session, or — worst
# of all — send-keys a second `exec claude …` into the running agent's pane. session_live (a thin
# `tmux has-session` wrapper) is the predicate; the guard must be the FIRST action, before any side
# effect. Tests stub tmux so `has-session` reports the live/not-live state we want to model.
echo "=== #108: launch_claude is a no-op for an already-live session ==="

# G1: live session → zero mutating tmux actions, rc 0, state + goal files untouched.
G_WD="$(mktemp -d)"; echo "do the thing" > "$G_WD/.harness-task.md"
mkdir -p "$G_WD/.claude"; printf 'SENTINEL-STATE\n' > "$G_WD/.claude/ralph-loop.local.md"
G_SESS="hzli-live-108"; printf 'SENTINEL-GOAL\n' > "$RUN_DIR/$G_SESS.goal"
G_CALLS="$RUN_DIR/calls_g"; : > "$G_CALLS"
(
  # has-session SUCCEEDS → session is live; record every tmux call so we can prove no mutation.
  tmux(){ echo "tmux $*" >> "$G_CALLS"; [[ "$1" == has-session ]] && return 0; return 0; }
  sleep(){ :; }; log(){ :; }; ensure_trusted(){ :; }; ensure_bypass(){ :; }
  CLAUDE_BIN=true; CLAUDE_FLAGS=""; PROMISE="X DONE"; MAXITER=30; GOAL="ISSUE:108"
  launch_claude "$G_SESS" "$G_WD"
)
assert_eq "$?" "0" "launch_claude returns 0 for an already-live session (#108)"
assert_eq "$(grep -c 'new-session' "$G_CALLS")" "0" "no tmux new-session for a live session (#108)"
assert_eq "$(grep -c 'send-keys' "$G_CALLS")" "0" "no tmux send-keys into a live session's pane (#108)"
assert_eq "$(cat "$G_WD/.claude/ralph-loop.local.md")" "SENTINEL-STATE" "write_state not run; state file untouched (#108)"
assert_eq "$(cat "$RUN_DIR/$G_SESS.goal")" "SENTINEL-GOAL" "goal file untouched for a live session (#108)"

# G2: fresh (not live) → full spawn sequence unchanged (new-session → goal → send-keys exec claude).
G2_WD="$(mktemp -d)"; echo "do the thing" > "$G2_WD/.harness-task.md"
G2_SESS="hzli-fresh-108"; G2_CALLS="$RUN_DIR/calls_g2"; : > "$G2_CALLS"
(
  tmux(){ echo "tmux $*" >> "$G2_CALLS"; [[ "$1" == has-session ]] && return 1; return 0; }
  sleep(){ :; }; log(){ :; }; ensure_trusted(){ :; }; ensure_bypass(){ :; }
  CLAUDE_BIN=true; CLAUDE_FLAGS=""; PROMISE="X DONE"; MAXITER=30; GOAL="ISSUE:108"
  launch_claude "$G2_SESS" "$G2_WD"
)
assert_eq "$(grep -c 'new-session' "$G2_CALLS")" "1" "fresh spawn still calls tmux new-session (#108)"
assert_eq "$(grep -c 'send-keys' "$G2_CALLS")" "1" "fresh spawn still send-keys exec claude (#108)"
assert_ok "fresh spawn writes the goal file (#108)" test -f "$RUN_DIR/$G2_SESS.goal"

finish
