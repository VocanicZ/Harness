#!/usr/bin/env bash
# test_windows_lane_tooling.sh — #495 (PRD #475, Solution 7): lane tooling and skills on native Windows, forced on Linux
# with HARNESS_PLATFORM=windows. Everything runs under a root whose name holds a space ("Win Home", as in
# C:\Users\Some User): HOME, HARNESS_HOME, the skills dir, the project and its lane worktree. Windows' own tools are fakes:
#   schtasks, powershell, taskkill, systemctl, loginctl — accepted and ignored;
#   claude   — records every `plugin …` call, so --with-skills' plugin set can be compared;
#   rtdd.exe — the ONLY rtdd on PATH (there is no `rtdd`): what a Windows host has.
# Covered: the {{skill:…}} check (cli_prereqs) finds, installs and re-finds the prompt-named skills in the Windows skills
# dir; --with-skills installs the same plugins and skills on Windows as on Linux, into the pinned skills dir and never
# the real HOME's; rtdd resolves to rtdd.exe (install, doctor, setup, the supervise task's PATH); a lane-shaped shell in a
# worktree path with spaces runs git, gh, rtdd.exe, python3 (the shim, whose interpreter path holds a space), grep and sed
# with a short TMPDIR.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; source "$HERE/release_fixture.sh"
T="$(mktemp -d)"; tmp_track "$T"
SYS=/usr/bin:/bin   # system tools only: the host's own rtdd, claude and gh are not on a test host's PATH
W="$T/Win Home"; mkdir -p "$W"

# --- the fakes ------------------------------------------------------------------------------------
BIN="$T/bin"; mkdir -p "$BIN"
for b in schtasks powershell taskkill systemctl loginctl; do printf '#!/bin/sh\nexit 0\n' >"$BIN/$b"; done
printf '#!/bin/sh\nexit 0\n' >"$BIN/gh"
cat >"$BIN/claude" <<EOF
#!/usr/bin/env bash
[[ \$1 == plugin ]] && echo "\$*" >> "\${FAKE_CLAUDE_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$BIN/"*
RBIN="$T/rtdd-bin"; mkdir -p "$RBIN"      # where the rtdd installer puts rtdd.exe: its own dir, found by PATH
cat >"$RBIN/rtdd.exe" <<EOF
#!/usr/bin/env bash
echo "rtdd.exe \$*" >> "\${FAKE_RTDD_LOG:-/dev/null}"
[[ \$1 == --help ]] && echo "  --legacy-files"
[[ \$1 == skill && \$2 == prompt ]] && printf '````markdown\nrtdd skill\n````\n'
exit 0
EOF
chmod +x "$RBIN/rtdd.exe"
# a Python whose path holds a space — C:\Program Files\Python313\python.exe
PYDIR="$W/Python 313"; mkdir -p "$PYDIR"
printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v python3)" >"$PYDIR/python"; chmod +x "$PYDIR/python"

# --- skill sources: local git repos standing in for the two upstream clones -------------------------
mk_src(){ local d="$1"; shift; mkdir -p "$d"; for s in "$@"; do mkdir -p "$d/$s"; printf 'name: %s\n' "$s" >"$d/$s/SKILL.md"; done
  git -C "$d" init -q; git -C "$d" -c user.email=t@t -c user.name=t add -A; git -C "$d" -c user.email=t@t -c user.name=t commit -qm init; }
mk_src "$T/matt" to-prd to-issues extra-upstream
mk_src "$T/vocz" subagent-task-tree
export MATTPOCOCK_SKILLS_URL="$T/matt" VOCANICZ_TOOLS_URL="$T/vocz"

# host_env <platform> <root> — a sandboxed host under <root>: a HOME that is NOT where the skills go (HARNESS_USER_SKILLS pins
# them, as a winsma lane does), its own CLAUDE_CONFIG_DIR and HARNESS_HOME.
host_env(){ local plat="$1" root="$2"
  mkdir -p "$root/home" "$root/Claude Data" "$root/hh" "$root/cfg"
  export HOME="$root/home" HARNESS_HOME="$root/hh" HARNESS_BIN_DIR="$root/bin" HARNESS_USER_SKILLS="$root/Claude Data/skills" \
    CLAUDE_CONFIG_DIR="$root/cfg" FAKE_CLAUDE_LOG="$root/claude.calls" HARNESS_PLATFORM="$plat" HARNESS_SKIP_RTDD=1 \
    HARNESS_BASH_EXE=bash HARNESS_PYTHON="$PYDIR/python" HARNESS_CLAUDE_BIN="$BIN/claude" PATH="$BIN:$SYS"
  : >"$FAKE_CLAUDE_LOG"; }

echo "=== --with-skills: the same plugins and skills on Windows as on Linux ==="
# ensure_skills + install_harness_skills are what install.sh and `update.sh --with-skills` run (update.sh sources install.sh).
with_skills(){ local plat="$1" root="$2"; mkdir -p "$root"
  ( host_env "$plat" "$root"; export HARNESS_INSTALL_NOMAIN=1 HARNESS_SKILL_SRC="$R/skill"
    source "$R/install.sh"; ensure_skills; install_harness_skills ) >"$root/out.txt" 2>&1; echo $? >"$root/rc"
  ( cd "$root/Claude Data/skills" 2>/dev/null && find . -maxdepth 1 -mindepth 1 | sort ) >"$root/skills.list"
  sed "s#$root#ROOT#g" "$root/claude.calls" >"$root/plugin.calls"; }
with_skills posix "$T/linux"
with_skills windows "$T/windows"
assert_eq "$(cat "$T/windows/rc")" 0 "windows: ensure_skills + install_harness_skills exit 0"
assert_ok "windows: to-prd, to-issues and subagent-task-tree are in the pinned skills dir" \
  bash -c "cd '$T/windows/Claude Data/skills' && test -f to-prd/SKILL.md && test -f to-issues/SKILL.md && test -f subagent-task-tree/SKILL.md"
assert_no "windows: an upstream skill nobody asked for is not copied" test -e "$T/windows/Claude Data/skills/extra-upstream"
assert_ok "windows: the engine's own skills are linked in (/harness, handoff)" \
  bash -c "cd '$T/windows/Claude Data/skills' && test -e harness/SKILL.md && test -e handoff/SKILL.md"
assert_no "windows: nothing was written to the HOME's own ~/.claude/skills" test -e "$T/windows/home/.claude/skills"
assert_eq "$(cat "$T/windows/skills.list")" "$(cat "$T/linux/skills.list")" "the skills dir holds the same set as on Linux"
assert_eq "$(cat "$T/windows/plugin.calls")" "$(cat "$T/linux/plugin.calls")" "the same plugin calls are made as on Linux"
assert_ok "claude's ralph-loop and superpowers plugins are installed" bash -c "grep -q 'plugin install ralph-loop@' '$T/windows/claude.calls' && grep -q 'plugin install superpowers@' '$T/windows/claude.calls'"

echo "=== update.sh --with-skills on Windows installs into the pinned skills dir ==="
SRV="$T/srv"; rel_server "$SRV"; rel_publish "$SRV" v0.1.0; rel_publish "$SRV" v0.2.0; rel_latest "$SRV" v0.1.0
( host_env windows "$T/upd"; export HARNESS_PYTHON="$PYDIR/python" HARNESS_INSTALL_NOPROMPT=1 HARNESS_SUPERVISE_CONF="$T/none.conf" \
    HARNESS_SCHTASKS="$BIN/schtasks" HARNESS_POWERSHELL="$BIN/powershell" HARNESS_TASKKILL="$BIN/taskkill"
  HARNESS_REF=v0.1.0 bash "$R/install.sh" </dev/null >"$T/upd/install.out" 2>&1; echo "$?" >"$T/upd/install.rc"
  rm -rf "$HARNESS_USER_SKILLS"; : >"$FAKE_CLAUDE_LOG"
  rel_latest "$SRV" v0.2.0
  env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK bash "$HARNESS_HOME/engine/bin/harness" update --with-skills </dev/null >"$T/upd/update.out" 2>&1; echo "$?" >"$T/upd/update.rc" )
assert_eq "$(cat "$T/upd/install.rc")" 0 "install.sh exits 0"
assert_eq "$(cat "$T/upd/update.rc")" 0 "harness update --with-skills exits 0"
assert_eq "$(readlink "$T/upd/hh/engine")" releases/v0.2.0 "the engine flipped to v0.2.0"
assert_ok "to-prd and subagent-task-tree land in the pinned skills dir" \
  bash -c "test -f '$T/upd/Claude Data/skills/to-prd/SKILL.md' && test -f '$T/upd/Claude Data/skills/subagent-task-tree/SKILL.md'"
assert_no "… not in the HOME's ~/.claude/skills" test -e "$T/upd/home/.claude/skills"
assert_ok "the plugins were refreshed through claude" grep -q 'plugin install superpowers@' "$T/upd/claude.calls"

echo "=== the {{skill:…}} check finds the prompt-named skills in the Windows skills dir ==="
( host_env windows "$T/chk"; export HARNESS_INSTALL_NOMAIN=1 HARNESS_SKILL_SRC="$R/skill"
  source "$R/scripts/lib.sh" >/dev/null 2>&1
  export HARNESS_CLI=claude HARNESS_ENGINE_LINK=""
  names="$(cli_prompt_skills | grep -v '^rtdd$' | tr '\n' ' ')"
  echo "names=$names" >"$T/chk/names"
  cli_prereqs >"$T/chk/before.out" 2>&1; echo "$?" >"$T/chk/before.rc"
  cli_prereqs --install >"$T/chk/install.out" 2>&1; echo "$?" >"$T/chk/install.rc"
  mkdir -p "$CLAUDE_CONFIG_DIR/plugins"; echo '{"plugins":{"ralph-loop@m":[],"superpowers@m":[]}}' >"$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
  cli_prereqs >"$T/chk/after.out" 2>&1; echo "$?" >"$T/chk/after.rc"
  cli_skills_dir >"$T/chk/dir" )
assert_eq "$(cat "$T/chk/dir")" "$T/chk/Claude Data/skills" "the CLI's skills dir is the Windows one, spaces and all"
assert_ok "the prompts name skills (caveman, handoff, subagent-task-tree, …)" grep -q 'handoff' "$T/chk/names"
assert_ok "before install: a prompt-named skill is reported MISSING with its dir" grep -q "MISSING claude skill handoff ($T/chk/Claude Data/skills/handoff)" "$T/chk/before.out"
assert_eq "$(cat "$T/chk/install.rc")" 0 "cli_prereqs --install links every prompt-named skill"
for n in $(sed 's/^names=//' "$T/chk/names"); do
  assert_ok "installed: $n is in the Windows skills dir" test -f "$T/chk/Claude Data/skills/$n/SKILL.md"
done
assert_eq "$(cat "$T/chk/after.rc")" 0 "afterwards cli_prereqs finds them all"
assert_ok "… saying so for handoff" grep -q "ok      claude skill handoff ($T/chk/Claude Data/skills/handoff)" "$T/chk/after.out"

echo "=== rtdd resolves to rtdd.exe ==="
RP="$BIN:$RBIN:$SYS"
rtdd_in(){ local plat="$1"; shift; ( export HARNESS_PLATFORM="$plat" PATH="$RP"; source "$R/scripts/portable.sh"; "$@" ); }
assert_eq "$(rtdd_in windows rtdd_exe)" "$RBIN/rtdd.exe" "windows: rtdd_exe is the rtdd.exe on PATH"
assert_no "linux: a lone rtdd.exe is not an rtdd" rtdd_in posix rtdd_exe
printf '#!/bin/sh\nexit 0\n' >"$BIN/rtdd"; chmod +x "$BIN/rtdd"
assert_eq "$(rtdd_in windows rtdd_exe)" "$RBIN/rtdd.exe" "windows: with both on PATH, rtdd.exe wins"
assert_eq "$(rtdd_in posix rtdd_exe)" "$BIN/rtdd" "linux: rtdd is rtdd"
rm -f "$BIN/rtdd"
# install.sh's ensure_rtdd (it must not reinstall) and the doctor's line
out="$( export HARNESS_PLATFORM=windows PATH="$RP" HARNESS_INSTALL_NOMAIN=1 HARNESS_SKIP_RTDD=0 HOME="$W/home"; mkdir -p "$HOME"; source "$R/install.sh"; ensure_rtdd 2>&1 )"
assert_ok "install.sh: rtdd.exe counts as installed (no npx run)" grep -qF "rtdd already installed ($RBIN/rtdd.exe)" <<<"$out"
out="$( export HARNESS_PLATFORM=windows PATH="$RP" HOME="$W/home"; source "$R/scripts/portable.sh"; source "$R/scripts/doctor.sh" 2>/dev/null; doctor_windows_prereqs 2>&1 )"
assert_ok "doctor: rtdd ✓ names rtdd.exe" grep -qF "rtdd: ✓ ($RBIN/rtdd.exe)" <<<"$out"
# setup's skill step drives rtdd.exe
( host_env windows "$T/rt"; export PATH="$BIN:$RBIN:$SYS" FAKE_RTDD_LOG="$T/rt/rtdd.calls" HARNESS_CLI=claude
  source "$R/scripts/lib.sh" >/dev/null 2>&1; rtdd_skill_install >"$T/rt/out" 2>&1; echo $? >"$T/rt/rc" )
assert_eq "$(cat "$T/rt/rc")" 0 "setup: rtdd_skill_install succeeds with only rtdd.exe"
assert_ok "… it ran rtdd.exe skill install" grep -qx 'rtdd.exe skill install' "$T/rt/rtdd.calls"
# the supervise task's PATH reaches rtdd.exe's dir
H="$T/sup/hh"; mkdir -p "$T/sup/home" "$T/sup/bin"
( host_env windows "$T/sup"; export HARNESS_HOME="$H" PATH="$BIN:$RBIN:$SYS" HARNESS_SCHTASKS="$BIN/schtasks" HARNESS_POWERSHELL="$BIN/powershell" \
    HARNESS_TASKKILL="$BIN/taskkill" HARNESS_SUPERVISE_CONF="$T/none.conf" HARNESS_SUPERVISE_SYSTEMCTL="$BIN/systemctl" HARNESS_SUPERVISE_LOGINCTL="$BIN/loginctl"
  rel_install_at "$SRV" v0.2.0
  env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK bash "$H/engine/bin/harness" supervise --install >"$T/sup/out" 2>&1; echo $? >"$T/sup/rc" )
assert_eq "$(cat "$T/sup/rc")" 0 "supervise --install exits 0"
assert_ok "no 'rtdd is not on PATH' warning" bash -c "! grep -q \"'rtdd' is not on PATH\" '$T/sup/out'"
assert_ok "the task's launcher PATH holds rtdd.exe's dir" grep -qF "$RBIN" "$H/tasks/harness-supervise.sh"

echo "=== a lane-shaped shell in a worktree path with spaces ==="
LH="$T/lane/Win Home"; PRJ="$LH/my project"; WT="$PRJ/.harness/worktrees/main i495"; mkdir -p "$PRJ"
git -C "$PRJ" init -q -b main; git -C "$PRJ" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$PRJ" worktree add -q -b issue/495 "$WT" 2>/dev/null
printf 'one\ntwo\n' >"$WT/notes.txt"
LTMP="$T/lane/t"; mkdir -p "$LTMP"          # the short TMPDIR
( host_env windows "$T/lane"; export HARNESS_HOME="$LH/.harness" HOME="$LH"
  mkdir -p "$HARNESS_HOME"
  export HARNESS_INSTALL_NOMAIN=1; source "$R/install.sh"; HARNESS_PYTHON="$PYDIR/python" install_python_shim >/dev/null
  unset HARNESS_PYTHON
  # the lane's env: the shim's dir first on PATH (bin/harness does it), the host tools, rtdd.exe, a short TMPDIR
  cd "$WT" && env -i HOME="$LH" TMPDIR="$LTMP" HARNESS_HOME="$HARNESS_HOME" HARNESS_PLATFORM=windows RTDD_EVENT_LOG="$LH/rtdd-events.jsonl" \
    PATH="$HARNESS_HOME/bin:$BIN:$RBIN:/usr/bin:/bin" FAKE_RTDD_LOG="$T/lane/rtdd.calls" bash -c '
      echo "pwd=$PWD"
      echo "git=$(git rev-parse --abbrev-ref HEAD)"
      echo "gh=$(gh --version >/dev/null 2>&1; echo $?)"
      rtdd.exe which --base origin/main; echo "rtdd=$?"
      echo "py=$(python3 -c "import sys; print(sys.version_info[0])")"
      echo "grep=$(grep -c two notes.txt)"
      echo "sed=$(sed -n 2p notes.txt)"
      f="$(mktemp)"; echo "tmp=$f"; echo "tmpdir_ok=$([[ $f == "$TMPDIR"/* ]] && echo yes || echo no)"
      echo "tmplen=${#f}"' >"$T/lane/out" 2>&1; echo "$?" >"$T/lane/rc" )
assert_eq "$(cat "$T/lane/rc")" 0 "the lane shell ran to the end"
assert_ok "cwd is the worktree, spaces and all" grep -qxF "pwd=$WT" "$T/lane/out"
assert_ok "git: the worktree is on issue/495" grep -qx 'git=issue/495' "$T/lane/out"
assert_ok "gh runs" grep -qx 'gh=0' "$T/lane/out"
assert_ok "rtdd.exe runs with the lane's arguments" grep -qx 'rtdd.exe which --base origin/main' "$T/lane/rtdd.calls"
assert_ok "python3 (the shim, over an interpreter path with a space) is a Python 3" grep -qx 'py=3' "$T/lane/out"
assert_ok "grep" grep -qx 'grep=1' "$T/lane/out"
assert_ok "sed" grep -qx 'sed=two' "$T/lane/out"
assert_ok "mktemp lands in the short TMPDIR" grep -qx 'tmpdir_ok=yes' "$T/lane/out"
shim="$LH/.harness/bin/python3"
assert_ok "the shim's baked interpreter is a plain assignment (no backslash-escaped space in double quotes)" bash -c "! grep -qF 'HARNESS_PYTHON:-' '$shim' || ! grep -F 'HARNESS_PYTHON:-' '$shim' | grep -qF '\\ '"
assert_ok "the shim runs the interpreter whose path has a space" bash -c "'$shim' -c 'print(7*6)' | grep -qx 42"

[[ "$TESTS_FAIL" == 0 ]] && echo "── windows lane tooling ok ($TESTS_RUN checks)" || { echo "── $TESTS_FAIL of $TESTS_RUN failed"; exit 1; }
