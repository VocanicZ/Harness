#!/usr/bin/env bash
# test_cli_lean.sh — #595 (PRD #587): fleet lanes start lean — without the operator's user-scope skills,
# plugins, MCP servers and hooks — and every skill a lane prompt names still resolves in one.
# Facts (measured, 12 local `claude -p` runs): docs/cli-capabilities.md § Lean lane.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
cli_load claude || exit 1
unset CLAUDE_FLAGS HARNESS_CLAUDE_LEAN HARNESS_CLAUDE_CONFIG_DIRS
HARNESS_BOOTSTRAP_PROMPT="Read .harness-task.md"
UUID=11111111-2222-3333-4444-555555555555
has(){ grep -qF -- "$1" <<<"$2"; }

# A user-scope config dir that has the ralph-loop plugin installed (a full-config launch switches it off, #616),
# and a HOME with nothing in it.
export HOME="$RUN_DIR/home"; mkdir -p "$HOME"
CFG="$RUN_DIR/cfg"; RL="$CFG/plugins/cache/mk/ralph-loop/1.0.1"; mkdir -p "$RL/hooks" "$CFG/plugins"
cat > "$CFG/plugins/installed_plugins.json" <<E
{"version": 2, "plugins": {"ralph-loop@mk": [
  {"scope": "project", "projectPath": "/x", "installPath": "$RUN_DIR/gone"},
  {"scope": "user", "installPath": "$RL"}]}}
E
export CLAUDE_CONFIG_DIR="$CFG"
WD="$RUN_DIR/wd"; git init -q "$WD"; printf 'GOAL: x\n' > "$WD/.harness-task.md"
HARNESS_AUTONOMOUS=true

# --- the launch flags -----------------------------------------------------------------------------
line="$(cli_launch "$WD" "$UUID" sonnet high)"
assert_ok "only the project and local setting sources" has ' --setting-sources project,local ' "$line"
assert_ok "no user MCP servers" has ' --strict-mcp-config ' "$line"
RALPH="$(cd "$HERE/.." && pwd -P)/plugins/claude/harness-ralph"
assert_ok "the goal loop's Stop hook is the engine's own plugin (#616), not the installed ralph-loop" has " --plugin-dir=$RALPH" "$line"
assert_no "…and the user-scope ralph-loop is not loaded" has "$RL" "$line"
assert_ok "the engine plugin ships its hook" test -f "$RALPH/hooks/stop-hook.py" -a -f "$RALPH/hooks/hooks.json" -a -f "$RALPH/.claude-plugin/plugin.json"
assert_ok "tools no lane used are off, AskUserQuestion with them (no human answers)" \
  has ' --disallowedTools=Workflow,ScheduleWakeup,ReportFindings,ListAgents,AskUserQuestion ' "$line"
assert_no "the Skill tool stays: --disable-slash-commands would remove it" has 'disable-slash-commands' "$line"
assert_no "no custom --tools set: it misses the shared prompt cache" has ' --tools' "$line"
assert_ok "the list flags use the = form, so the positional prompt is not swallowed" \
  grep -qE -- ' --disallowedTools=[^ ]+ --plugin-dir=[^ ]+ "Read \.harness-task\.md"$' <<<"$line"
assert_ok "the lane's own model and effort are still on the line" has '--model sonnet --effort high' "$line"
assert_eq "$(HARNESS_AUTONOMOUS=false cli_launch "$WD" "$UUID" "" "" | grep -c AskUserQuestion)" 0 \
  "a fleet with a human keeps AskUserQuestion"

argv="$(cli_headless "$WD" "$UUID" sonnet high)"
assert_ok "a headless lane runs the same lean flags" \
  has "--flags=--dangerously-skip-permissions --model sonnet --effort high --setting-sources project,local --strict-mcp-config --disallowedTools=" "$argv"
assert_ok "…and the engine's hook plugin" has " --plugin-dir=$RALPH" "$argv"

# --- when a lane launches with the full config instead -----------------------------------------------
full="$(HARNESS_CLAUDE_LEAN=0 cli_launch "$WD" "$UUID" "" "")"
assert_no "HARNESS_CLAUDE_LEAN=0 turns it off" has ' --setting-sources' "$full"
assert_ok "a full-config launch loads the engine's hook too (every lane launch does)" has " --plugin-dir=$RALPH" "$full"
assert_ok "…and switches the user's ralph-loop off, or its hook would re-send the task beside ours" \
  has '--settings=\{\"enabledPlugins\":\{\"ralph-loop@mk\":false\}\}' "$full"
assert_eq "$(HARNESS_CLAUDE_LEAN=0 CLAUDE_CONFIG_DIR="$RUN_DIR/empty" HARNESS_CLAUDE_CONFIG_DIRS= HOME="$RUN_DIR/nohome" cli_launch "$WD" "$UUID" "" "" | grep -c -- '--settings')" 0 \
  "no ralph-loop installed: nothing to switch off"
assert_eq "$(CLAUDE_FLAGS='--dangerously-skip-permissions --setting-sources user' cli_launch "$WD" "$UUID" "" "" | grep -o -- '--setting-sources [a-z,]*')" \
  "--setting-sources user" "an operator's own --setting-sources is not doubled"
assert_ok "…and that launch still loads the engine's hook" has " --plugin-dir=$RALPH" \
  "$(CLAUDE_FLAGS='--dangerously-skip-permissions --setting-sources user' cli_launch "$WD" "$UUID" "" "")"
assert_ok "a host with no ralph-loop plugin still launches lean: the hook is the engine's" \
  has ' --setting-sources' "$(CLAUDE_CONFIG_DIR="$RUN_DIR/empty" HOME="$RUN_DIR/nohome" cli_launch "$WD" "$UUID" "" "")"
assert_ok "…a ralph-loop under HARNESS_CLAUDE_CONFIG_DIRS is switched off on a full launch" \
  has 'ralph-loop@mk' "$(HARNESS_CLAUDE_LEAN=0 CLAUDE_CONFIG_DIR="$RUN_DIR/empty" HARNESS_CLAUDE_CONFIG_DIRS="x:$CFG" cli_launch "$WD" "$UUID" "" "")"
assert_ok "…and one under \$HOME/.claude" has 'ralph-loop@mk' \
  "$(mkdir -p "$HOME/.claude" && cp -r "$CFG/plugins" "$HOME/.claude/" && HARNESS_CLAUDE_LEAN=0 CLAUDE_CONFIG_DIR="$RUN_DIR/empty" cli_launch "$WD" "$UUID" "" "")"
# An engine path with a space rides the launch line quoted, and the headless runner's shlex split reads it back.
SPE="$RUN_DIR/with space/engine"; mkdir -p "$SPE/plugins/claude/harness-ralph" "$SPE/skill"
assert_ok "an engine path with a space is quoted on the launch line" \
  has "--plugin-dir=$(printf '%q' "$SPE/plugins/claude/harness-ralph")" "$(claude_ralph_plugin_dir() { echo "$SPE/plugins/claude/harness-ralph"; }; cli_launch "$WD" "$UUID" "" "")"
assert_eq "$(claude_ralph_plugin_dir() { echo "$SPE/plugins/claude/harness-ralph"; }; cli_headless "$WD" "$UUID" "" "" | grep '^--flags=' | sed 's/^--flags=//' |
  python3 -c 'import shlex, sys; print([w for w in shlex.split(sys.stdin.read()) if w.startswith("--plugin-dir=")][0])')" \
  "--plugin-dir=$SPE/plugins/claude/harness-ralph" "…and a headless lane's flags split back to the same path"

# --- the skills a lean lane finds in its worktree ----------------------------------------------------
USK="$RUN_DIR/user-skills"; export HARNESS_USER_SKILLS="$USK"; mkdir -p "$USK/rtdd"; echo rtdd > "$USK/rtdd/SKILL.md"
wanted="$(cli_prompt_skills)"
assert_ok "the prompts name skills" test -n "$wanted"
cli_lean_setup "$WD"
for n in $wanted; do
  assert_ok "skill $n resolves in the worktree's .claude/skills" test -f "$WD/.claude/skills/$n/SKILL.md"
done
assert_eq "$(readlink "$WD/.claude/skills/handoff" | sed 's#.*/skill/#skill/#')" "skill/handoff" "an engine skill is a link into the engine's skill/"
assert_eq "$(readlink "$WD/.claude/skills/rtdd")" "$USK/rtdd" "rtdd's own skill is linked from the user skills dir"
assert_eq "$(git -C "$WD" status --porcelain | grep -v harness-task)" "" "git add -A would commit none of them (excluded)"
cli_lean_setup "$WD"
assert_eq "$(ls "$WD/.claude/skills" | wc -l)" "$(wc -l <<<"$wanted")" "setting up again changes nothing"

WP="$RUN_DIR/wp"; git init -q "$WP"; mkdir -p "$WP/.claude/skills/handoff"; echo mine > "$WP/.claude/skills/handoff/SKILL.md"
cli_lean_setup "$WP"
assert_eq "$(cat "$WP/.claude/skills/handoff/SKILL.md")" mine "a skill the project ships itself is left alone"

WF="$RUN_DIR/wf"; git init -q "$WF"; HARNESS_CLAUDE_LEAN=0 cli_lean_setup "$WF"
assert_no "nothing is linked for a lane that launches with the full config" test -e "$WF/.claude/skills"

# --- every skill a prompt names is supplied by the engine ----------------------------------------------
# The engine supplies skill/<name>, or the skill is rtdd's own (`rtdd skill install`, linked from the user
# skills dir above). A prompt naming any other skill leaves a lean lane without it.
for n in $wanted; do
  [[ $n == rtdd ]] && continue
  assert_ok "prompt skill $n is shipped as skill/$n" test -f "$HERE/../skill/$n/SKILL.md"
done
assert_ok "this check sees a skill the engine lacks" bash -c '! test -f "$1/../skill/no-such-skill/SKILL.md"' _ "$HERE"

# --- …and so is every skill THOSE skills require (#669) ----------------------------------------------
# A lean lane (--setting-sources project,local) has the engine's skill/<name> and rtdd, no plugin: a skill that
# says "REQUIRED SUB-SKILL: superpowers:executing-plans" leaves the lane with a name it cannot invoke.
# skill_refs <dir> — the skills a skill's files name, one per line: `plugin:name` on a line that speaks of a
# skill (-> name), the skill after `REQUIRED SUB-SKILL:` / `REQUIRED BACKGROUND:`, and a backticked `name` skill.
skill_refs(){ local t; t="$(cat "$1"/*.md 2>/dev/null | sed -E '/^<!--/d')"
  { grep -i 'skill' <<<"$t" | grep -ohE '\b[a-z][a-z0-9]+:[a-z][a-z0-9-]*[a-z0-9]\b' | grep -vE '^(https?|file|path|docs?):' | sed 's/^[^:]*://'
    grep -ohE 'REQUIRED (SUB-SKILL|BACKGROUND):\*{0,2} Use [a-z][a-z0-9:-]*' <<<"$t" | sed -E 's/.* Use //' | grep -v :
    grep -ohE '`[a-z][a-z0-9-]*` skill' <<<"$t" | sed -E 's/^`//; s/` skill$//'
    grep -ohE '(^|[ `(])/[a-z][a-z0-9-]*[a-z0-9]\b' <<<"$t" | grep -vE '/(home|tmp|usr|etc|dev|bin|var|opt|mnt|c|d)$' | sed -E 's/^[ `(]?\///'; } | sort -u; }
# lean_walk <skill>… — every skill reachable from those, each one the engine's
# skill/<name> and rtdd resolve (a `/skill-name` slash reference counts, #722), anything else is printed as UNRESOLVED.
lean_walk(){ local todo=("$@") seen=" " n r
  while ((${#todo[@]})); do n="${todo[0]}"; todo=("${todo[@]:1}")
    [[ $seen == *" $n "* ]] && continue; seen+="$n "
    [[ $n == rtdd ]] && continue
    [[ -f "$LEAN_SKILLS/$n/SKILL.md" ]] || { echo "UNRESOLVED $n"; continue; }
    for r in $(skill_refs "$LEAN_SKILLS/$n"); do
      [[ $r == "$n" ]] && continue
      [[ -f "$LEAN_SKILLS/$r/SKILL.md" || $r == rtdd ]] && { todo+=("$r"); continue; }
      echo "UNRESOLVED $r (required by $n)"; done
  done; }
LEAN_SKILLS="$HERE/../skill"
unresolved="$(lean_walk $wanted | grep '^UNRESOLVED' || true)"
assert_eq "$unresolved" "" "every skill the prompts name, and every skill those require, resolves in a lean lane"
# The walk itself: a skill requiring an absent plugin skill is caught, a present one and rtdd are not.
LEAN_SKILLS="$RUN_DIR/walk"; mkdir -p "$LEAN_SKILLS"/{a,b}
printf -- '---\nname: a\n---\n> REQUIRED SUB-SKILL: Use superpowers:executing-plans\n' > "$LEAN_SKILLS/a/SKILL.md"
assert_eq "$(lean_walk a)" "UNRESOLVED executing-plans (required by a)" "a plugin skill a lean lane lacks is reported"
printf -- '---\nname: a\n---\nsee superpowers:b, harness-x:rtdd and `b` skill\n' > "$LEAN_SKILLS/a/SKILL.md"
printf -- '---\nname: b\n---\nplain\n' > "$LEAN_SKILLS/b/SKILL.md"
assert_eq "$(lean_walk a)" "" "an engine skill, and rtdd, resolve"
printf -- '---\nname: b\n---\n**REQUIRED SUB-SKILL:** Use using-git-worktrees\n' > "$LEAN_SKILLS/b/SKILL.md"
assert_eq "$(lean_walk a)" "UNRESOLVED using-git-worktrees (required by b)" "a skill reached through another skill is walked too"
LEAN_SKILLS="$HERE/../skill"
# #722: a slash-command reference to a skill the lane lacks is caught.
LEAN_SKILLS="$RUN_DIR/walk"
printf -- '---\nname: a\n---\nrun `/setup-matt-pocock-skills` if not.\n' > "$LEAN_SKILLS/a/SKILL.md"
assert_eq "$(lean_walk a)" "UNRESOLVED setup-matt-pocock-skills (required by a)" "a /slash-command skill a lean lane lacks is reported"
printf -- '---\nname: a\n---\nrun `/b` and see /tmp and /home/x\n' > "$LEAN_SKILLS/a/SKILL.md"
assert_eq "$(lean_walk a)" "" "a /slash reference to an engine skill resolves; plain paths are not skills"
LEAN_SKILLS="$HERE/../skill"

# --- #722: a skill a lane needs but cannot find is warned about, not skipped silently
WW="$RUN_DIR/ww"; git init -q "$WW"
warned="$(HARNESS_USER_SKILLS="$RUN_DIR/no-user-skills" cli_lean_setup "$WW" 2>&1 >/dev/null)"
assert_ok "a missing rtdd skill is logged as a warning naming it" has "WARN lean lane: skill rtdd not found" "$warned"
assert_no "an engine skill that is present is not warned about" has "skill handoff" "$warned"
assert_eq "$(cli_lean_setup "$WD" 2>&1 >/dev/null)" "" "no warning when every skill resolves"

# --- the other backends: listed with the reason in the docs ----------------------------------------------
DOC="$HERE/../docs/cli-capabilities.md"
sect="$(awk '/^## Lean lane/{on=1;next} /^## /{on=0} on' "$DOC")"
assert_ok "docs/cli-capabilities.md has a Lean lane section" test -n "$sect"
for c in $(cli_list); do
  [[ $c == claude ]] && continue
  assert_ok "$c: listed in the Lean lane section with a reason" grep -qE "^\| \`$c\` \| [^|]{20,}" <<<"$sect"
  assert_no "$c: its launch line carries no claude lean flag" has '--setting-sources' "$(cli_with "$c" cli_launch "$WD" "$UUID" "" "" 2>/dev/null)"
done
finish
