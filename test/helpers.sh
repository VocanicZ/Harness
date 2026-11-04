#!/usr/bin/env bash
# helpers.sh — minimal bash test rig + temp-env setup for the harness pool logic.
# Sourced by test_*.sh AFTER sourcing ../scripts/lib.sh (and ../scripts/drive.sh where needed).
# Overrides unit_complete so tests control "which units are COMPLETE" without GitHub.
TESTS_RUN=0; TESTS_FAIL=0
assert_eq(){ TESTS_RUN=$((TESTS_RUN+1)); if [[ "$1" == "$2" ]]; then echo "  ok: $3"; else echo "  FAIL: $3 — want [$2] got [$1]"; TESTS_FAIL=$((TESTS_FAIL+1)); fi; }
assert_ok(){ local msg="$1"; shift; TESTS_RUN=$((TESTS_RUN+1)); if "$@"; then echo "  ok: $msg"; else echo "  FAIL: $msg — expected success from: $*"; TESTS_FAIL=$((TESTS_FAIL+1)); fi; }
assert_no(){ local msg="$1"; shift; TESTS_RUN=$((TESTS_RUN+1)); if "$@"; then echo "  FAIL: $msg — expected failure from: $*"; TESTS_FAIL=$((TESTS_FAIL+1)); else echo "  ok: $msg"; fi; }
finish(){ echo "── $((TESTS_RUN-TESTS_FAIL))/$TESTS_RUN passed"; [[ $TESTS_FAIL -eq 0 ]]; }

# The per-project CONFIG vars lib.sh exports (scripts/lib.sh) — every one of which a pool worker
# hands down to the agent session that may be running this suite. Deliberately EXCLUDES the four
# host PATH pins (HARNESS_HOME / _POLLER_DIR / _SNAPSHOTS_DIR / _FLEETS_DIR): run.sh and make_env set
# those to throwaways on purpose, so unsetting them here would undo the isolation. Every other
# HARNESS_* the engine exports belongs here — snapshot_gate's HARNESS_SNAPSHOT_FILE/_DIR and each
# adapter's _BIN too (#333); test_hermetic.sh fails on any export this list misses.
HARNESS_CONFIG_VARS="HARNESS_MODE HARNESS_OWNER HARNESS_REPO HARNESS_UNIT HARNESS_CHECKOUT HARNESS_SPEC
  HARNESS_AUTONOMOUS HARNESS_POOL HARNESS_CAP HARNESS_POLL HARNESS_PRIORITY_POLL HARNESS_SESS_PREFIX
  HARNESS_LABEL_READY HARNESS_LABEL_PRD HARNESS_LABEL_WORKING HARNESS_LABEL_BLOCKED
  HARNESS_LABEL_REVIEWED HARNESS_LABEL_COORD HARNESS_LABEL_PAUSED HARNESS_LABEL_BUG
  HARNESS_LABEL_BUG_TRIAGED HARNESS_LABEL_HITL HARNESS_AUTHOR_ALLOWLIST HARNESS_USE_POLLER
  HARNESS_PREFIX_COLLISION HARNESS_WORKTREE_HOOK HARNESS_GAUNTLET_ROUNDS HARNESS_CI_GATE HARNESS_SEED_CI HARNESS_DISABLE_CI
  HARNESS_SECURITY_AUDIT HARNESS_SECURITY_AUDIT_ROUNDS HARNESS_USAGE_CHECKPOINT_PCT HARNESS_USAGE_CMD HARNESS_USAGE_STATUSLINE
  HARNESS_GH_RATE_GUARD HARNESS_GH_BUDGET_PCT HARNESS_GH_RATE_TTL HARNESS_BLOCKED_BACKOFF_MIN HARNESS_SELFPARK_GRACE_MIN
  HARNESS_SWARM HARNESS_SESSION_BACKEND HARNESS_CLI HARNESS_AGY_BIN HARNESS_AGY_FLAGS HARNESS_CODEX_BIN HARNESS_CODEX_FLAGS
  HARNESS_COPILOT_BIN HARNESS_COPILOT_FLAGS HARNESS_OPENCODE_BIN HARNESS_OPENCODE_FLAGS
  HARNESS_AUTORELEASE_DIR HARNESS_RELEASE_REASON HARNESS_RELEASE_REPO HARNESS_RELEASE_CMD
  HARNESS_CLAUDE_BIN HARNESS_CLAUDE_FLAGS HARNESS_HERMES_BIN HARNESS_OPENCLAW_BIN HARNESS_OPENCLAW_TIMEOUT
  HARNESS_TURN_MAX HARNESS_INTERRUPT_WAIT HARNESS_SNAPSHOT_FILE HARNESS_SNAPSHOT_DIR
  HARNESS_MODEL_MANAGER HARNESS_EFFORT_MANAGER HARNESS_MODEL_IMPLEMENTER HARNESS_EFFORT_IMPLEMENTER"

# unset_inherited_config — drop a LIVE fleet's config out of the environment.
#
# The path pins alone were not enough. Config lines are written `: "${VAR:=value}"`, so a pre-set
# env var beats the file BY DESIGN — which means a suite running inside a live agent session read
# that fleet's HARNESS_REPO / HARNESS_AUTONOMOUS instead of the fixture's, and `harness init`'s
# round-trip assertion failed on a developer's machine while passing on a bare one. The product
# behaviour is correct; the test environment was the leak.
#
# CALL IT BEFORE lib.sh IS SOURCED, never after — which is why it is NOT part of make_env. lib.sh
# fills each var with its default at source time, but the runtime readers (sess_orch's
# $HARNESS_SESS_PREFIX, the label lookups) re-read the ENV on every call, so unsetting afterwards
# empties them mid-test rather than restoring defaults. run.sh drops them once before the loop, so
# every test gets a clean process; test_init.sh re-drops for a direct `bash test_init.sh`.
unset_inherited_config(){ unset $HARNESS_CONFIG_VARS; }

# Temp hygiene (#294). make_env's RUN_DIR holds stubs, claims, state and tmux sockets — thousands of
# inodes — and a script calls make_env many times, so an unremoved one per call exhausted a shared
# host's /tmp. tmp_track records a path; tmp_cleanup removes every recorded one. The first
# tmp_track in a shell installs `tmp_cleanup` as its EXIT trap, AFTER any trap already set there. A
# test that sets its OWN EXIT trap later replaces this one, so it must call tmp_cleanup last itself:
#   trap 'tmux kill-server 2>/dev/null; tmp_cleanup' EXIT
# A subshell inherits the list but not the trap: its first tmp_track starts a list of its own, so
# its exit removes only what it made and never the parent's RUN_DIR.
TMP_TRACKED=(); TMP_OWNER=""
# A no-op in a subshell that tracked nothing itself: the list it inherited is the parent's to remove.
tmp_cleanup(){ [[ "$TMP_OWNER" == "$BASHPID" ]] || return 0
  (( ${#TMP_TRACKED[@]} )) && { tmp_kill_rooted "${TMP_TRACKED[@]}"; rm -rf "${TMP_TRACKED[@]}"; }
  TMP_TRACKED=(); return 0; }
# tmp_kill_rooted <dir>… (#419) — stop this user's processes rooted in any <dir>: cwd inside one, or a
# STATE_DIR / HARNESS_HOME / HARNESS_LANE_DIR in their environment inside one. A test that dies before
# its own kill-trap (SIGKILL, a timeout, a branch starting what it should refuse) otherwise leaves the
# workers and lanes it started polling a deleted home for days. By PATH only — never a command-line
# pattern, this is a shared host — and never this shell or an ancestor of it. TERM, then KILL what is
# still up after 2s. No /proc (macOS, Git Bash): nothing to read, so nothing is killed.
tmp_kill_rooted(){ local proc="${HARNESS_PROC_ROOT:-/proc}"
  [[ -d "$proc/self" ]] && command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$proc" "$BASHPID" "$@" <<'PY' 2>/dev/null || true
import os, signal, sys, time
proc, me, dirs = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
roots = {r for d in dirs if d.strip("/") for r in (d.rstrip("/"), os.path.realpath(d))}
inside = lambda p: any(p == r or p.startswith(r + "/") for r in roots)
def status(pid, key):
    try:
        for line in open(f"{proc}/{pid}/status"):
            if line.startswith(key + ":"):
                return line.split()[1]
    except (OSError, IndexError):
        pass
    return ""
keep, chain, p = {os.getpid(), os.getppid()}, set(), me   # this script, its shell, and every ancestor
while p > 1 and p not in chain:
    chain.add(p); ppid = status(p, "PPid"); p = int(ppid) if ppid.isdigit() else 0
keep |= chain
uid, hits = os.getuid(), []
for e in os.listdir(proc):
    if not e.isdigit() or int(e) in keep:
        continue
    try:
        if os.stat(f"{proc}/{e}").st_uid != uid:
            continue
        cwd = os.readlink(f"{proc}/{e}/cwd")
    except OSError:
        continue
    hit = inside(cwd[:-len(" (deleted)")] if cwd.endswith(" (deleted)") else cwd)
    if not hit:
        try:
            env = open(f"{proc}/{e}/environ", "rb").read().split(b"\0")
        except OSError:
            env = []
        hit = any(k in (b"STATE_DIR", b"HARNESS_HOME", b"HARNESS_LANE_DIR") and v and inside(os.fsdecode(v))
                  for k, _, v in (kv.partition(b"=") for kv in env))
    if hit:
        hits.append(int(e))
def alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return status(pid, "State") != "Z"
for sig in (signal.SIGTERM, signal.SIGKILL):
    for pid in hits:
        try:
            os.kill(pid, sig)
        except OSError:
            pass
    deadline = time.time() + 2
    while sig == signal.SIGTERM and time.time() < deadline and any(alive(p) for p in hits):
        time.sleep(0.05)
    hits = [p for p in hits if alive(p)]
PY
}
tmp_track(){
  if [[ "$TMP_OWNER" != "$BASHPID" ]]; then
    local prev=""
    # Only the top-level shell keeps an earlier trap: in a subshell `trap -p` reports the PARENT's.
    if [[ "$BASHPID" == "$$" ]]; then prev="$(trap -p EXIT)"; else TMP_TRACKED=(); fi
    TMP_TRACKED+=("$@"); TMP_OWNER="$BASHPID"
    # `trap -p` prints `trap -- 'CMD' EXIT`; re-split it (this clobbers $@, already recorded) for CMD.
    if [[ -n "$prev" ]]; then eval "set -- $prev"; trap -- "$3; tmp_cleanup" EXIT; else trap tmp_cleanup EXIT; fi
    return 0
  fi
  TMP_TRACKED+=("$@")
}
make_env(){
  RUN_DIR="$(mktemp -d)"; tmp_track "$RUN_DIR"; CLAIMS_DIR="$RUN_DIR/claims"; POOL_LOCK="$RUN_DIR/pool.lock"; PAUSE_FLAG="$RUN_DIR/PAUSED"; mkdir -p "$CLAIMS_DIR"
  # Hermetic state. lib.sh honours an inherited STATE_DIR (scripts/lib.sh:15) and every pool worker
  # exports its project's own to every child, so a test run inside a live agent session resolved
  # CONFIG / WORKTREES_DIR / CHECKOUTS_DIR at that fleet's REAL .harness/ and wrote to it. Re-pin
  # STATE_DIR and everything lib.sh derived from it; export it so child processes (init.sh, spawned
  # scripts) inherit the throwaway one too. Isolating WORKTREES_DIR per test was the old opt-in fix —
  # this makes it the default. See test_hermetic.sh.
  export STATE_DIR="$RUN_DIR/state"
  CONFIG="$STATE_DIR/config"; WORKTREES_DIR="$STATE_DIR/worktrees"; CHECKOUTS_DIR="$STATE_DIR/checkouts"
  # PROJECT_ROOT too: lib.sh:17 derives it from STATE_DIR at source time, and unit_checkout /
  # bug_checkout return it as THE checkout in single topology — leaving it behind would point a
  # test's git operations at the live repo, and would break lib.sh's own
  # "PROJECT_ROOT is the parent of STATE_DIR" invariant (test_path_split.sh).
  PROJECT_ROOT="$RUN_DIR"
  # Host-level state too (lib.sh:86-92). HARNESS_HOME defaults to ~/.harness and is NOT derived from
  # STATE_DIR, so pinning STATE_DIR alone still let tests write the real host poller registry — which
  # is shared by every co-resident fleet, so fixture entries there make `harness start` abort a real
  # fleet on a bogus prefix collision. Same seam, different root.
  export HARNESS_HOME="$RUN_DIR/host"
  # #183: the rate-limit guard probes `gh api rate_limit` from issuelib — a real network call from a
  # test with no stubbed gh binary. Off by default; test_ghrate.sh turns it on against its stub.
  export HARNESS_GH_RATE_GUARD=0
  # The host FLEET registry is the same seam one notch worse (lib.sh:99-100): it too prefers an
  # inherited value over the HARNESS_HOME just set and is exported by every fleet process, but its
  # entries are DELETED by `doctor --fix` (test_doctor.sh calls doctor_main --fix before its own
  # fleet block pins anything) — so an unpinned suite strips a live sibling fleet's prefix
  # reservation off the real host, not just litters it. Pin it beside HARNESS_HOME, before any test
  # can reach it. See test_hermetic.sh's fleet-decoy block.
  export HARNESS_FLEETS_DIR="$HARNESS_HOME/fleets"
  # Claude Code's config too. ensure_trusted seeds EVERY config the launched pane could read —
  # ~/.claude.json, $CLAUDE_CONFIG_DIR/.claude.json, and each ~/.claude-switch/accounts/*/.claude.json
  # — so a test run inside a live agent session (which exports CLAUDE_CONFIG_DIR via .bashrc) wrote
  # fixture /tmp paths straight into the developer's real per-account config. Pin the seam to a
  # throwaway by default and drop the inherited config dir; tests that exercise the fan-out override
  # both explicitly (test_spawn.sh group 3b). Same seam, different root.
  export HARNESS_CLAUDE_CONFIG="$RUN_DIR/claude.json"
  export HARNESS_AGY_TRUST_FILE="$RUN_DIR/agy-settings.json"
  # …and agy's own state dir (#188: conversation ids, transcripts, the usage-window cache).
  export HARNESS_AGY_HOME="$RUN_DIR/agy-home"
  # …and Codex's home (#257: config.toml trust entries, rollouts, the harness-ralph plugin).
  export CODEX_HOME="$RUN_DIR/codex-home"
  # …and Copilot's (#259: config.json trust entries, session-state transcripts).
  export COPILOT_HOME="$RUN_DIR/copilot-home"
  # …and OpenCode's data dir (#261: the opencode.db its sessions and usage live in).
  export XDG_DATA_HOME="$RUN_DIR/xdg-data"
  # …and the operator's Hermes home each lane's own is seeded from (#263: its config.yaml, login, runtime).
  export HARNESS_HERMES_HOME="$RUN_DIR/hermes-home"
  # …and the user skill dirs `harness setup --install` and rtdd_skill_install write into (#303: the
  # handoff skill). Copilot's lives under COPILOT_HOME, pinned above.
  export HARNESS_USER_SKILLS="$RUN_DIR/user-skills" HARNESS_AGY_USER_SKILLS="$RUN_DIR/agy-skills"
  export HARNESS_CODEX_USER_SKILLS="$RUN_DIR/codex-skills"
  # …and `--install`'s fetch of a missing CLI binary (#316): a real npm/curl install off the host's
  # PATH. The matrix's prereqs-named cell turns it back on against its stub npm and curl.
  export HARNESS_INSTALL_CLI_BIN=0
  # …and the label seeding a non-interactive `harness init` does when gh is signed in (#432): a real
  # `gh label create` on the fixture's acme/widget. test_init.sh turns it on against its stub gh.
  export HARNESS_INIT_SEED=0
  # …and the CLIs whose usage windows are read by RUNNING them (#404): agy_limit_usage,
  # hermes_limit_usage and openclaw_limit_usage run `agy` / `hermes` / `openclaw` off PATH, so every
  # usage_watch ran the host's real binary on the operator's real account — a host near its agy weekly
  # limit opened a usage hold in the fixture (test_ghrate.sh). A failing stub of each goes first on
  # PATH; the launch lines still name the bare binary, and a suite that drives its own stub through
  # HARNESS_<CLI>_BIN (or a PATH of its own) still reaches that one. See test_hermetic.sh.
  local cli_stubs="$RUN_DIR/cli-stubs" c; mkdir -p "$cli_stubs"
  for c in agy hermes openclaw; do printf '#!/usr/bin/env bash\nexit 1\n' > "$cli_stubs/$c"; chmod +x "$cli_stubs/$c"; done
  export PATH="$cli_stubs:$PATH"
  unset CLAUDE_CONFIG_DIR
  # …and the transcript search stats.py does for session_end usage (#185): read-only, but a test must
  # not pick up a real session's usage either.
  export HARNESS_CLAUDE_CONFIG_DIRS="$RUN_DIR/claude-config"
  export HARNESS_POLLER_DIR="$HARNESS_HOME/poller" HARNESS_SNAPSHOTS_DIR="$HARNESS_HOME/snapshots"
  POLLER_REGISTRY_DIR="$HARNESS_POLLER_DIR/registry"
  POLLER_PID="$HARNESS_POLLER_DIR/poller.pid"; POLLER_LOCK="$HARNESS_POLLER_DIR/poller.lock"
  mkdir -p "$WORKTREES_DIR" "$CHECKOUTS_DIR" "$POLLER_REGISTRY_DIR" "$HARNESS_SNAPSHOTS_DIR"
  TARGETS_TSV="$RUN_DIR/targets.tsv"; COMPLETE_SET="$RUN_DIR/complete.set"; : > "$TARGETS_TSV"; : > "$COMPLETE_SET"; POLL=0
  # TEST-ONLY unit registry (the engine has none since #473: one fleet = one repo = one unit). Engine tests
  # whose subject is unit-agnostic (claims, the stall banner, supervise, usage…) still want several named
  # units to tell their claims/sessions apart, so write_targets feeds them rows of
  # `id <TAB> repo <TAB> deps <TAB> desc` and these overrides read them — a fixture seam like unit_complete
  # below, never engine behavior. With no rows written the real one-repo functions answer.
  _fx_row(){ awk -F'\t' -v s="$1" '!/^#/ && $1==s {print; exit}' "$TARGETS_TSV"; }
  _fx_rows(){ [[ -s "$TARGETS_TSV" ]] && grep -qv '^#' "$TARGETS_TSV"; }
  all_units(){ if _fx_rows; then awk -F'\t' '!/^#/ && NF>=2 {print $1}' "$TARGETS_TSV"; else fleet_unit; fi; }
  unit_repo(){ if _fx_rows; then _fx_row "$1" | awk -F'\t' '{print $2}'; else echo "$HARNESS_REPO"; fi; }
  unit_desc(){ if _fx_rows; then _fx_row "$1" | awk -F'\t' '{print $4}'; else echo "${HARNESS_REPO##*/}"; fi; }
  unit_checkout(){ if _fx_rows; then echo "$CHECKOUTS_DIR/$(unit_repo "$1" | sed 's#.*/##')"; else fleet_checkout; fi; }
  unit_complete(){ grep -qxF "$1" "$COMPLETE_SET" 2>/dev/null; }
}
# gitattr_eol <tree> <path>… — the eol attribute <tree>'s own .gitattributes gives each path, one per
# line (#404). Asked of a throwaway repository holding only a copy of that file, so it answers for a
# tree that is no git repository: release.sh gates on a `git archive` extract, where `git -C <tree>
# check-attr` dies "not a git repository" and an assertion on it fails on the gate, not the file.
# The host's own attribute files are left out, so only the tree's decides. No .gitattributes: rc 1.
gitattr_eol(){ local tree="$1" t out rc=1; shift
  [[ -f "$tree/.gitattributes" ]] || { echo "gitattr_eol: no $tree/.gitattributes" >&2; return 1; }
  t="$(mktemp -d)" || return 1
  if git init -q "$t" && cp "$tree/.gitattributes" "$t/"; then
    out="$(GIT_ATTR_NOSYSTEM=1 git -C "$t" -c core.attributesFile=/dev/null check-attr eol -- "$@")" && rc=0
  fi
  rm -rf "$t"; (( rc == 0 )) && sed 's/.*: //' <<<"$out"; return $rc; }
write_targets(){ cat > "$TARGETS_TSV"; }
set_complete(){ printf '%s\n' "$@" > "$COMPLETE_SET"; [[ $# -eq 0 ]] && : > "$COMPLETE_SET"; }
unit_complete(){ grep -qxF "$1" "$COMPLETE_SET" 2>/dev/null; }
