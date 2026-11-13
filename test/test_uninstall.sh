#!/usr/bin/env bash
# harness-test-timeout-windows: 1800
# test_uninstall.sh — `harness uninstall [--force]` (#61, PRD #52): tear down a Harness
# install/project. Removes the shared host engine (~/.harness/engine) + its PATH symlink, this
# project's state-only .harness/ + the project .gitignore '.harness/' entry, and the deployed
# /harness* operator skills (~/.claude/skills). The default path STOPS a live fleet first
# (stop --clean) and is confirm-gated; --force skips BOTH the stop guard AND the prompt.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; HP="$(mktemp -d)"; tmp_track "$HP"; pin_host_home "$HP/host"   # a test that picks its own HARNESS_HOME pins the host paths first (#541)
UNINSTALL="$HERE/../scripts/uninstall.sh"
CLI="$HERE/../bin/harness"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }

# The host's agy is host state too (#236): remove_skills runs `agy plugin uninstall harness-ralph`,
# and against the real binary that strips agy's goal loop off a live fleet host. Pin BOTH seams at a
# logging stub — export HARNESS_AGY_BIN (overriding any value a live fleet exported, which would
# bypass PATH) and put the stub first on PATH as a fallback. Every subprocess below inherits both.
AGY_STUB_DIR="$(mktemp -d)"; AGY_LOG="$AGY_STUB_DIR/agy.log"; : > "$AGY_LOG"
printf '#!/usr/bin/env bash\necho "$*" >> %q\n' "$AGY_LOG" > "$AGY_STUB_DIR/agy"; chmod +x "$AGY_STUB_DIR/agy"
export HARNESS_AGY_BIN="$AGY_STUB_DIR/agy" PATH="$AGY_STUB_DIR:$PATH"

# mk_layout <root> — build a throwaway install+project under <root>: a shared engine dir, a PATH
# symlink onto it, user-scope /harness* skills (umbrella + per-command) alongside an UNRELATED
# skill that must survive, and a project whose state-only .harness/ + .gitignore carry a removable
# '.harness/' entry (plus unrelated entries that must survive).
mk_layout(){ local root="$1"
  mkdir -p "$root/.harness/engine/bin" "$root/bin" "$root/.claude/skills" \
           "$root/proj/.harness/run/claims" "$root/proj/.harness/worktrees"
  : > "$root/.harness/engine/bin/harness"; chmod +x "$root/.harness/engine/bin/harness"
  ln -sfn "$root/.harness/engine/bin/harness" "$root/bin/harness"
  local s
  # what an install leaves (#439): the umbrella harness/ holds a SKILL.md link, every other skill is a link
  # into the engine's skill/ (#1111: uninstall removes Harness's own, so a bare dir would be the operator's)
  mkdir -p "$root/.claude/skills/harness"; ln -s "$root/.harness/engine/skill/SKILL.md" "$root/.claude/skills/harness/SKILL.md"
  for s in harness-init harness-stop harness-uninstall; do ln -s "$root/.harness/engine/skill/$s" "$root/.claude/skills/$s"; done
  mkdir -p "$root/.claude/skills/to-prd"; : > "$root/.claude/skills/to-prd/SKILL.md"   # unrelated — survives
  cp -R "$HERE/../skill/handoff" "$root/.claude/skills/handoff"   # Harness's own, by its marker (#303)
  printf ': "${HARNESS_MODE:=issue-only}"\n: "${HARNESS_TOPOLOGY:=single}"\n' > "$root/proj/.harness/config"
  printf 'node_modules/\n.harness/\ndist/\n' > "$root/proj/.gitignore"
}

# Existing default/--force/CLI subprocess tests below assert the SINGLE-FLEET behavior (engine +
# PATH link removed). On a multi-fleet test host the real guard would (correctly) trip on live
# sibling workers / a populated poller registry and preserve the engine — host state leaking into a
# temp-layout test. So these tests pin single-fleet by stubbing the overridable guard FALSE in a
# wrapper that sources uninstall.sh then calls main; the multi-fleet path has dedicated tests (R8/R9).
SINGLE_FLEET='source "$1"; other_fleets_depend_on_engine(){ return 1; }; shift; main "$@"'

# ── tracer: --force removes the shared engine ───────────────────────────────────────────
R="$(mktemp -d)"; mk_layout "$R"
out="$(HARNESS_UNINSTALL_NOMAIN=1 HARNESS_HOME="$R/.harness" HARNESS_BIN_DIR="$R/bin" \
       HARNESS_USER_SKILLS="$R/.claude/skills" STATE_DIR="$R/proj/.harness" \
       bash -c "$SINGLE_FLEET" _ "$UNINSTALL" --force </dev/null 2>&1)"; rc=$?
assert "--force exits 0"                "[[ $rc -eq 0 ]]"
assert "--force removes the shared engine" "[[ ! -e '$R/.harness/engine' ]]"
assert "--force removes the PATH symlink"  "[[ ! -L '$R/bin/harness' && ! -e '$R/bin/harness' ]]"
assert "--force removes the project .harness/" "[[ ! -e '$R/proj/.harness' ]]"
assert "--force strips the .gitignore '.harness/' entry" "! grep -qxF '.harness/' '$R/proj/.gitignore'"
assert "--force keeps unrelated .gitignore entries" \
  "grep -qxF 'node_modules/' '$R/proj/.gitignore' && grep -qxF 'dist/' '$R/proj/.gitignore'"
assert "--force removes umbrella /harness skill"   "[[ ! -e '$R/.claude/skills/harness' ]]"
assert "--force removes /harness-init skill"        "[[ ! -e '$R/.claude/skills/harness-init' ]]"
assert "--force removes /harness-uninstall skill"   "[[ ! -e '$R/.claude/skills/harness-uninstall' ]]"
assert "--force keeps unrelated skill (to-prd)"     "[[ -e '$R/.claude/skills/to-prd' ]]"
assert "--force removes Harness's handoff skill (#303)" "[[ ! -e '$R/.claude/skills/handoff' ]]"
assert "--force uninstalls the agy harness-ralph plugin via HARNESS_AGY_BIN" \
  "[[ \"\$(cat '$AGY_LOG')\" == 'plugin uninstall harness-ralph' ]]"

# ── agy is best-effort: a missing or failing HARNESS_AGY_BIN never fails the uninstall ─────
for agy_case in missing failing; do
  RA="$(mktemp -d)"; mk_layout "$RA"
  if [[ $agy_case == missing ]]; then agy_bin="$RA/no-such-agy"
  else agy_bin="$RA/failing-agy"; printf '#!/usr/bin/env bash\nexit 7\n' > "$agy_bin"; chmod +x "$agy_bin"; fi
  HARNESS_AGY_BIN="$agy_bin" HARNESS_UNINSTALL_NOMAIN=1 HARNESS_HOME="$RA/.harness" HARNESS_BIN_DIR="$RA/bin" \
    HARNESS_USER_SKILLS="$RA/.claude/skills" STATE_DIR="$RA/proj/.harness" \
    bash -c "$SINGLE_FLEET" _ "$UNINSTALL" --force </dev/null >/dev/null 2>&1; rca=$?
  assert "$agy_case HARNESS_AGY_BIN: --force still exits 0"        "[[ $rca -eq 0 ]]"
  assert "$agy_case HARNESS_AGY_BIN: still removes the engine"     "[[ ! -e '$RA/.harness/engine' ]]"
  assert "$agy_case HARNESS_AGY_BIN: still removes project state"  "[[ ! -e '$RA/proj/.harness' ]]"
  assert "$agy_case HARNESS_AGY_BIN: still removes /harness skills" "[[ ! -e '$RA/.claude/skills/harness' ]]"
done

# ── confirm guard: declining the default (confirm-gated) path removes NOTHING ───────────
R2="$(mktemp -d)"; mk_layout "$R2"
out2="$(printf 'n\n' | HARNESS_HOME="$R2/.harness" HARNESS_BIN_DIR="$R2/bin" \
        HARNESS_USER_SKILLS="$R2/.claude/skills" STATE_DIR="$R2/proj/.harness" \
        bash "$UNINSTALL" 2>&1)"; rc2=$?
assert "declining exits non-zero"                  "[[ $rc2 -ne 0 ]]"
assert "decline leaves the engine intact"          "[[ -e '$R2/.harness/engine' ]]"
assert "decline leaves the PATH symlink intact"    "[[ -L '$R2/bin/harness' ]]"
assert "decline leaves the project .harness/ intact" "[[ -e '$R2/proj/.harness' ]]"
assert "decline leaves /harness skills intact"     "[[ -e '$R2/.claude/skills/harness' ]]"
assert "decline leaves the .gitignore entry intact" "grep -qxF '.harness/' '$R2/proj/.gitignore'"

# ── default STOPS the fleet first; --force SKIPS the stop guard (precise control flow) ──
# Source with the NOMAIN guard, then stub stop_fleet (records it ran) + the removal funcs (no-op)
# so we observe ONLY which steps main invokes, on real temp paths. Not exported → subprocess
# tests above/below are unaffected.
HARNESS_UNINSTALL_NOMAIN=1
source "$UNINSTALL"
MARK="$(mktemp -u)"
stop_fleet(){ : > "$MARK"; }
remove_engine(){ :; }; remove_path_link(){ :; }; remove_project_state(){ :; }; remove_skills(){ :; }
HARNESS_UNINSTALL_YES=1
rm -f "$MARK"; ( main )         >/dev/null 2>&1; assert "default path runs stop_fleet first" "[[ -e '$MARK' ]]"
rm -f "$MARK"; ( main --force ) >/dev/null 2>&1; assert "--force path SKIPS stop_fleet"      "[[ ! -e '$MARK' ]]"
unset HARNESS_UNINSTALL_NOMAIN HARNESS_UNINSTALL_YES

# ── confirmed default path removes ALL targets (exercises the REAL stop_fleet → stop.sh) ─
# Single-fleet host: insulate the multi-fleet guard from real host state via its env seams —
# HARNESS_UNINSTALL_WORKER_PIDS="" (no foreign workers, signal a off) + HARNESS_POLLER_DIR at an
# empty dir (no registered sibling projects, signal b off) — so the real guard returns FALSE.
R5="$(mktemp -d)"; mk_layout "$R5"
out5="$(HARNESS_UNINSTALL_YES=1 HARNESS_UNINSTALL_WORKER_PIDS="" HARNESS_POLLER_DIR="$R5/empty-poller" \
        HARNESS_HOME="$R5/.harness" HARNESS_BIN_DIR="$R5/bin" \
        HARNESS_USER_SKILLS="$R5/.claude/skills" STATE_DIR="$R5/proj/.harness" \
        bash "$UNINSTALL" 2>&1)"; rc5=$?
assert "confirmed default exits 0"                 "[[ $rc5 -eq 0 ]]"
assert "confirmed default ran stop --clean"        "grep -q 'stop --clean' <<< \"\$out5\""
assert "confirmed default removes the engine"      "[[ ! -e '$R5/.harness/engine' ]]"
assert "confirmed default removes project .harness/" "[[ ! -e '$R5/proj/.harness' ]]"
assert "confirmed default removes /harness skills" "[[ ! -e '$R5/.claude/skills/harness' ]]"

# ── idempotent: a second --force run on an already-removed layout is a clean no-op ──────
out6="$(HARNESS_UNINSTALL_WORKER_PIDS="" HARNESS_POLLER_DIR="$R/empty-poller" \
        HARNESS_HOME="$R/.harness" HARNESS_BIN_DIR="$R/bin" HARNESS_USER_SKILLS="$R/.claude/skills" \
        STATE_DIR="$R/proj/.harness" bash "$UNINSTALL" --force </dev/null 2>&1)"; rc6=$?
assert "second uninstall is idempotent (exit 0)"   "[[ $rc6 -eq 0 ]]"

# ── remove_gitignore_entry: a .gitignore whose ONLY line is '.harness/' (all-lines-removed case) ─
# grep -v exits non-zero when it selects zero lines, so a naive `grep -v … && mv` never strips the
# entry and litters a stray .gitignore.tmp. Assert the entry IS gone AND no .tmp is left behind.
RGI="$(mktemp -d)"; printf '.harness/\n' > "$RGI/.gitignore"
( HARNESS_UNINSTALL_NOMAIN=1; source "$UNINSTALL"; remove_gitignore_entry "$RGI/.gitignore" ) >/dev/null 2>&1
assert "single-line .gitignore: '.harness/' entry is stripped" "! grep -qxF '.harness/' '$RGI/.gitignore'"
assert "single-line .gitignore: no stray .gitignore.tmp left"  "[[ ! -e '$RGI/.gitignore.tmp' ]]"
# and the multi-line case still strips ONLY '.harness/' (regression guard for the fix)
RGI2="$(mktemp -d)"; printf 'node_modules/\n.harness/\ndist/\n' > "$RGI2/.gitignore"
( HARNESS_UNINSTALL_NOMAIN=1; source "$UNINSTALL"; remove_gitignore_entry "$RGI2/.gitignore" ) >/dev/null 2>&1
assert "multi-line .gitignore: '.harness/' stripped"           "! grep -qxF '.harness/' '$RGI2/.gitignore'"
assert "multi-line .gitignore: unrelated entries survive"      "grep -qxF 'node_modules/' '$RGI2/.gitignore' && grep -qxF 'dist/' '$RGI2/.gitignore'"
assert "multi-line .gitignore: no stray .gitignore.tmp left"   "[[ ! -e '$RGI2/.gitignore.tmp' ]]"

# ── multi-fleet guard: other fleets depend on the shared engine → engine + PATH link PRESERVED ─
# Source with NOMAIN, stub other_fleets_depend_on_engine TRUE (no real /proc / registry touched).
# Default (no --force-engine): engine + PATH link survive, but THIS project's state is still removed
# and a warning is emitted. Then --force-engine overrides and removes them.
R8="$(mktemp -d)"; mk_layout "$R8"
out8="$(HARNESS_UNINSTALL_NOMAIN=1 HARNESS_UNINSTALL_YES=1 \
        HARNESS_HOME="$R8/.harness" HARNESS_BIN_DIR="$R8/bin" \
        HARNESS_USER_SKILLS="$R8/.claude/skills" STATE_DIR="$R8/proj/.harness" \
        bash -c 'source "$1"; other_fleets_depend_on_engine(){ return 0; }; main' _ "$UNINSTALL" 2>&1)"; rc8=$?
assert "guard: exits 0"                              "[[ $rc8 -eq 0 ]]"
assert "guard: PRESERVES the shared engine"          "[[ -e '$R8/.harness/engine' ]]"
assert "guard: PRESERVES the PATH symlink"           "[[ -L '$R8/bin/harness' ]]"
assert "guard: still removes THIS project's .harness/" "[[ ! -e '$R8/proj/.harness' ]]"
assert "guard: still removes /harness skills"        "[[ ! -e '$R8/.claude/skills/harness' ]]"
assert "guard: emits a warning about other fleets"   "grep -qi 'other fleets' <<< \"\$out8\""
assert "guard: warning mentions --force-engine"      "grep -q -- '--force-engine' <<< \"\$out8\""

# guard TRUE + --force-engine → engine + PATH link ARE removed (override). POSIX only: on Windows a running worker holds its scripts
# open, so --force-engine is refused while another fleet runs (#490, test_windows_uninstall.sh), whatever host this suite runs on.
R9="$(mktemp -d)"; mk_layout "$R9"
out9="$(HARNESS_PLATFORM=posix HARNESS_UNINSTALL_NOMAIN=1 HARNESS_UNINSTALL_YES=1 \
        HARNESS_HOME="$R9/.harness" HARNESS_BIN_DIR="$R9/bin" \
        HARNESS_USER_SKILLS="$R9/.claude/skills" STATE_DIR="$R9/proj/.harness" \
        bash -c 'source "$1"; other_fleets_depend_on_engine(){ return 0; }; main --force-engine' _ "$UNINSTALL" 2>&1)"; rc9=$?
assert "guard+--force-engine: exits 0"               "[[ $rc9 -eq 0 ]]"
assert "guard+--force-engine: REMOVES the engine"    "[[ ! -e '$R9/.harness/engine' ]]"
assert "guard+--force-engine: REMOVES the PATH link" "[[ ! -L '$R9/bin/harness' && ! -e '$R9/bin/harness' ]]"

# guard FALSE (single-fleet default) → engine + PATH link removed (unchanged behavior)
R10="$(mktemp -d)"; mk_layout "$R10"
out10="$(HARNESS_UNINSTALL_NOMAIN=1 HARNESS_UNINSTALL_YES=1 \
        HARNESS_HOME="$R10/.harness" HARNESS_BIN_DIR="$R10/bin" \
        HARNESS_USER_SKILLS="$R10/.claude/skills" STATE_DIR="$R10/proj/.harness" \
        bash -c 'source "$1"; other_fleets_depend_on_engine(){ return 1; }; main' _ "$UNINSTALL" 2>&1)"; rc10=$?
assert "guard FALSE: exits 0"                        "[[ $rc10 -eq 0 ]]"
assert "guard FALSE: REMOVES the engine (unchanged)" "[[ ! -e '$R10/.harness/engine' ]]"
assert "guard FALSE: REMOVES the PATH link (unchanged)" "[[ ! -L '$R10/bin/harness' && ! -e '$R10/bin/harness' ]]"

# ── R11: remove_project_state refuses a STATE_DIR that is NOT a real project state dir (#105) ─
# rm -rf is strictly destructive and STATE_DIR is honoured from the env verbatim (uninstall.sh:7).
# A legitimately-resolved STATE_DIR is ALWAYS '.../.harness' WITH a config marker, so deleting must
# require BOTH (mirror migrate.sh:25). Non-'.harness' suffix — even WITH a config file inside — must
# NOT be deleted, must name the path in a refusal, and must NOT touch the parent .gitignore.
RV="$(mktemp -d)"; mkdir -p "$RV/victim"; : > "$RV/victim/important.txt"; : > "$RV/victim/config"
printf 'node_modules/\n.harness/\n' > "$RV/.gitignore"
outv="$(HARNESS_UNINSTALL_NOMAIN=1 bash -c 'source "$1"; STATE_DIR="$2" remove_project_state' _ "$UNINSTALL" "$RV/victim" 2>&1)"
assert "R11 non-.harness STATE_DIR is NOT deleted"      "[[ -e '$RV/victim/important.txt' ]]"
assert "R11 refusal names the path"                     "grep -qF '$RV/victim' <<< \"\$outv\""
assert "R11 refusal does NOT strip parent .gitignore"   "grep -qxF '.harness/' '$RV/.gitignore'"

# ── R12: basename '.harness' but NO config marker → refuse, delete nothing, print a refusal ──
RM="$(mktemp -d)"; mkdir -p "$RM/.harness/run"; : > "$RM/.harness/run/keep"
printf '.harness/\n' > "$RM/.gitignore"
outm="$(HARNESS_UNINSTALL_NOMAIN=1 bash -c 'source "$1"; STATE_DIR="$2" remove_project_state' _ "$UNINSTALL" "$RM/.harness" 2>&1)"
assert "R12 .harness without config is NOT deleted"     "[[ -e '$RM/.harness/run/keep' ]]"
assert "R12 refusal printed"                            "grep -qi 'refus' <<< \"\$outm\""
assert "R12 refusal does NOT strip parent .gitignore"   "grep -qxF '.harness/' '$RM/.gitignore'"

# ── R13: valid '.harness' WITH config → removed + parent .gitignore stripped (guard passes real case) ─
RG="$(mktemp -d)"; mkdir -p "$RG/.harness/run"; : > "$RG/.harness/config"
printf 'node_modules/\n.harness/\n' > "$RG/.gitignore"
outg="$(HARNESS_UNINSTALL_NOMAIN=1 bash -c 'source "$1"; STATE_DIR="$2" remove_project_state' _ "$UNINSTALL" "$RG/.harness" 2>&1)"
assert "R13 valid .harness IS removed"                  "[[ ! -e '$RG/.harness' ]]"
assert "R13 parent .gitignore '.harness/' stripped"     "! grep -qxF '.harness/' '$RG/.gitignore'"

# ── R14: a release-based engine (#281): the engine link goes, then every releases/<name> no live
# worker runs from; one a live worker's ENGINE_DIR points into is kept, named, and releases/ stays.
# The worker is exec'd with ENGINE_DIR in its environment, as pool.sh execs pool-worker.sh.
RR="$(mktemp -d)"; mkdir -p "$RR/.harness/releases/v0.1.0/bin" "$RR/.harness/releases/v0.2.0/bin"
echo v0.1.0 > "$RR/.harness/releases/.installed"; echo v0.2.0 >> "$RR/.harness/releases/.installed"
ln -s releases/v0.2.0 "$RR/.harness/engine"
ENGINE_DIR="$RR/.harness/releases/v0.1.0" sleep 300 & live=$!
outr="$(HARNESS_UNINSTALL_NOMAIN=1 HARNESS_HOME="$RR/.harness" HARNESS_UNINSTALL_WORKER_PIDS="$live" \
        bash -c 'source "$1"; remove_engine' _ "$UNINSTALL" 2>&1)"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
assert "R14 the engine link is removed"                 "[[ ! -L '$RR/.harness/engine' && ! -e '$RR/.harness/engine' ]]"
assert "R14 a release no worker runs from is removed"   "[[ ! -e '$RR/.harness/releases/v0.2.0' ]]"
assert "R14 the release a live worker runs from is kept" "[[ -d '$RR/.harness/releases/v0.1.0' ]]"
assert "R14 the kept release is named"                  "grep -qF 'v0.1.0' <<< \"\$outr\""
HARNESS_UNINSTALL_NOMAIN=1 HARNESS_HOME="$RR/.harness" HARNESS_UNINSTALL_WORKER_PIDS="" \
  bash -c 'source "$1"; remove_engine' _ "$UNINSTALL" >/dev/null 2>&1
assert "R14 with no live worker, releases/ goes too"    "[[ ! -e '$RR/.harness/releases' ]]"
rm -rf "$RR"

# ── CLI: `harness help` lists uninstall; `harness uninstall` dispatches via bin/harness ─
assert "help lists uninstall" "\"$CLI\" help 2>&1 | grep -q uninstall"
# end-to-end through the CLI from INSIDE a project (STATE_DIR discovered from cwd), --force path
R7="$(mktemp -d)"; mk_layout "$R7"
out7="$(cd "$R7/proj"; unset STATE_DIR HARNESS_DIR
        HARNESS_UNINSTALL_WORKER_PIDS="" HARNESS_POLLER_DIR="$R7/empty-poller" \
        HARNESS_HOME="$R7/.harness" HARNESS_BIN_DIR="$R7/bin" HARNESS_USER_SKILLS="$R7/.claude/skills" \
          "$CLI" uninstall --force </dev/null 2>&1)"; rc7=$?
assert "CLI uninstall --force exits 0"             "[[ $rc7 -eq 0 ]]"
assert "CLI uninstall removes the engine"          "[[ ! -e '$R7/.harness/engine' ]]"
assert "CLI uninstall removes project state (discovered from cwd)" "[[ ! -e '$R7/proj/.harness' ]]"

# ── #1095: uninstall refuses from inside the state dir it deletes, and while the project's fleet runs ──
# A lane worktree lives at <proj>/.harness/worktrees/<lane>: discovery from there reaches the live
# fleet's own state dir, and `uninstall --force` rm -rf'd it under its workers. Every host path is
# sandboxed here; only the project discovered from cwd could escape, which is what these pin.
mk_guard(){ G="$(mktemp -d)"; mk_layout "$G"; mkdir -p "$G/proj/.harness/worktrees/lane" "$G/tm"
  git -C "$G/proj" init -q 2>/dev/null; }
guard_run(){ # guard_run <cwd> <envs…> -- <args…>  (STATE_DIR etc. unset unless passed)
  local cwd="$1"; shift; local -a e=(); while [[ "${1:-}" != -- ]]; do e+=("$1"); shift; done; shift
  ( cd "$cwd" && env -u STATE_DIR -u HARNESS_DIR -u ENGINE_DIR -u XDG_CONFIG_HOME -u TMUX -u HARNESS_STATE_DIR_OK \
      HOME="$G/hm" HARNESS_HOME="$G/.harness" HARNESS_BIN_DIR="$G/bin" HARNESS_USER_SKILLS="$G/.claude/skills" \
      HARNESS_POLLER_DIR="$G/empty-poller" TMUX_TMPDIR="$G/tm" "${e[@]}" \
      "$CLI" "$@" </dev/null 2>&1 ); }
intact(){ [[ -f "$G/proj/.harness/config" ]] && grep -qxF '.harness/' "$G/proj/.gitignore" \
  && [[ -e "$G/.harness/engine" && -L "$G/bin/harness" && -d "$G/.claude/skills/harness" ]]; }

mk_guard; LANE="$G/proj/.harness/worktrees/lane"
og="$(guard_run "$LANE" HARNESS_UNINSTALL_WORKER_PIDS= -- uninstall --force)"; rcg=$?
assert "1095 cwd under .harness (discovered): rc != 0"          "[[ $rcg -ne 0 ]]"
assert "1095 cwd under .harness (discovered): nothing removed"   "intact"
assert "1095 the message names the state dir"                    "grep -qF '$G/proj/.harness' <<< \"\$og\""
assert "1095 the message names the cwd"                          "grep -qF '$LANE' <<< \"\$og\""
assert "1095 the message says to cd out"                         "grep -q 'cd ' <<< \"\$og\""
for fl in "" "--force-engine" "--force --force-engine"; do
  og="$(guard_run "$LANE" HARNESS_UNINSTALL_WORKER_PIDS= HARNESS_UNINSTALL_YES=1 -- uninstall $fl)"; rcg=$?
  assert "1095 cwd under .harness, flags '${fl:-none}': rc != 0, nothing removed" "[[ $rcg -ne 0 ]] && intact"
done
og="$(guard_run "$G/proj/.harness" HARNESS_UNINSTALL_WORKER_PIDS= -- uninstall --force)"; rcg=$?
assert "1095 cwd == the state dir itself: rc != 0, nothing removed" "[[ $rcg -ne 0 ]] && intact"
# inherited STATE_DIR (a lane exports it)
og="$(guard_run "$LANE" STATE_DIR="$G/proj/.harness" HARNESS_UNINSTALL_WORKER_PIDS= -- uninstall --force --force-engine)"; rcg=$?
assert "1095 inherited STATE_DIR, cwd under it: rc != 0, nothing removed" "[[ $rcg -ne 0 ]] && intact"
assert "1095 inherited case names the state dir"                 "grep -qF '$G/proj/.harness' <<< \"\$og\""
# --state-dir (deliberate)
og="$(guard_run "$LANE" HARNESS_UNINSTALL_WORKER_PIDS= -- --state-dir "$G/proj/.harness" uninstall --force)"; rcg=$?
assert "1095 --state-dir, cwd under it: rc != 0, nothing removed" "[[ $rcg -ne 0 ]] && intact"
# cwd reached through a symlink still counts
ln -s "$LANE" "$G/lanelink"
og="$(guard_run "$G/lanelink" HARNESS_UNINSTALL_WORKER_PIDS= -- uninstall --force)"; rcg=$?
assert "1095 cwd via a symlink into the state dir: rc != 0, nothing removed" "[[ $rcg -ne 0 ]] && intact"
rm -rf "$G"

# live fleet: --force must not delete the state dir under its own workers
mk_guard
if declare -F proc_env >/dev/null && { env STATE_DIR=x sleep 30 & p=$!; sleep 0.2; v="$(proc_env "$p" STATE_DIR)"; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; [[ "$v" == x ]]; }; then
  env STATE_DIR="$G/proj/.harness" sleep 300 & live=$!
  og="$(guard_run "$G/proj" HARNESS_UNINSTALL_WORKER_PIDS="$live" -- uninstall --force)"; rcg=$?
  assert "1095 live worker of this project, --force: rc != 0"      "[[ $rcg -ne 0 ]]"
  assert "1095 live worker of this project: nothing removed"       "intact"
  assert "1095 the message says the fleet is running + harness stop" "grep -q 'harness stop' <<< \"\$og\" && grep -qi 'running' <<< \"\$og\""
  og="$(guard_run "$G/proj" HARNESS_UNINSTALL_WORKER_PIDS="$live" -- uninstall --force --force-engine)"; rcg=$?
  assert "1095 live worker, --force --force-engine: rc != 0, nothing removed" "[[ $rcg -ne 0 ]] && intact"
  # a worker of ANOTHER project does not block removing this one
  kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
  mkdir -p "$G/other/.harness"; env STATE_DIR="$G/other/.harness" sleep 300 & other=$!
  og="$(guard_run "$G/proj" HARNESS_UNINSTALL_WORKER_PIDS="$other" -- uninstall --force)"; rcg=$?
  kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
  assert "1095 a worker of another project does not block: rc 0, state removed" "[[ $rcg -eq 0 && ! -e '$G/proj/.harness' ]]"
else
  echo "  skip: 1095 live-worker case (proc_env cannot read a process environ here)"
fi
rm -rf "$G"

# normal use unchanged: from the project root, no live workers → state dir + .gitignore entry go
mk_guard
og="$(guard_run "$G/proj" HARNESS_UNINSTALL_WORKER_PIDS= -- uninstall --force)"; rcg=$?
assert "1095 from the project root with no workers: rc 0"        "[[ $rcg -eq 0 ]]"
assert "1095 from the project root: state dir removed"           "[[ ! -e '$G/proj/.harness' ]]"
assert "1095 from the project root: .gitignore entry stripped"   "! grep -qxF '.harness/' '$G/proj/.gitignore'"
rm -rf "$G"
# outside any project: engine + skills only
mk_guard; mkdir -p "$G/away"
og="$(guard_run "$G/away" HARNESS_UNINSTALL_WORKER_PIDS= -- uninstall --force)"; rcg=$?
assert "1095 outside any project: rc 0, engine removed, project untouched" "[[ $rcg -eq 0 && ! -e '$G/.harness/engine' && -f '$G/proj/.harness/config' ]]"
rm -rf "$G"
# the usage line documents the refusal
assert "1095 usage says uninstall refuses inside .harness/ or while the fleet runs" \
  "\"$CLI\" help 2>&1 | grep -A2 'uninstall \[--force\]' | grep -qi 'refuses'"

echo "── uninstall ok"
