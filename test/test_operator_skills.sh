#!/usr/bin/env bash
# test_operator_skills.sh — #439: the engine's skills reach EVERY supported CLI installed on the host,
# in the user-skills dir that CLI reads (cli_user_skills_dir; hermes: ~/.hermes/skills), as symlinks
# into the engine through its stable link ($HARNESS_HOME/engine/skill/<name>), and every
# `harness update` — no flags, already current included — `harness setup` and `harness start` heal
# them: a missing, dangling or old-release link is (re)made from the release engine points at. An
# operator's own same-named skill is never touched; `harness uninstall` removes only Harness's links.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/release_fixture.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cd "$T"
export HOME="$T/home" HARNESS_HOME="$T/home/.harness" HARNESS_SKIP_RTDD=1 \
  HARNESS_SUPERVISE_UNIT_DIR="$T/units" HARNESS_WEB_UNIT_DIR="$T/units" \
  HARNESS_SUPERVISE_SYSTEMCTL=true HARNESS_SUPERVISE_LOGINCTL=true HARNESS_WEB_SYSTEMCTL=true HARNESS_WEB_LOGINCTL=true
mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR COPILOT_HOME HARNESS_USER_SKILLS HARNESS_AGY_USER_SKILLS HARNESS_CODEX_USER_SKILLS \
  HARNESS_COPILOT_USER_SKILLS HARNESS_OPENCLAW_AGENTS_SKILLS HARNESS_HERMES_HOME HARNESS_ENGINE_LINK ENGINE_DIR \
  CLAUDE_BIN AGY_BIN HARNESS_CLAUDE_BIN HARNESS_AGY_BIN HARNESS_CODEX_BIN HARNESS_COPILOT_BIN HARNESS_OPENCODE_BIN \
  HARNESS_HERMES_BIN HARNESS_OPENCLAW_BIN
H="$HARNESS_HOME"; SRV="$T/srv"; rel_server "$SRV"
source "$HERE/../scripts/cli/dispatch.sh"
CLIS="$(cli_list | xargs)"
# Every CLI installed: a stub of each adapter's executable, on a PATH that holds no real agent CLI.
BIN="$T/bin"; mkdir -p "$BIN"
for c in $CLIS; do printf '#!/bin/sh\nexit 0\n' > "$BIN/$(cli_with "$c" cli_exe)"; chmod +x "$BIN/$(cli_with "$c" cli_exe)"; done
export PATH="$BIN:/usr/local/bin:/usr/bin:/bin"
harness(){ env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK -u HARNESS_REF bash "$H/engine/bin/harness" "$@"; }
skdir(){ cli_with "$1" cli_user_skills_dir; }

# links_ok <dir> <tag> — every skill of release <tag> is in <dir> as Harness's link: harness/SKILL.md
# and each <name> name $H/engine/skill/… and resolve into releases/<tag>/skill/.
links_ok(){ local d="$1" rs="$H/releases/$2/skill" n
  [[ -L "$d/harness/SKILL.md" && "$(readlink "$d/harness/SKILL.md")" == "$H/engine/skill/SKILL.md" ]] || return 1
  [[ "$(realpath "$d/harness/SKILL.md")" == "$(realpath "$rs/SKILL.md")" ]] || return 1
  for n in "$rs"/*/; do n="$(basename "$n")"
    [[ -L "$d/$n" && "$(readlink "$d/$n")" == "$H/engine/skill/$n" ]] || return 1
    [[ "$(realpath "$d/$n/SKILL.md")" == "$(realpath "$rs/$n/SKILL.md")" ]] || return 1
  done; }

# ── an old-version install: its skills only in ~/.claude/skills, as copies ───────────────────────
rel_publish "$SRV" v1.0.0; rel_install_at "$SRV" v1.0.0; rel_latest "$SRV" v1.0.0
OLD="$HOME/.claude/skills"; mkdir -p "$OLD/harness"
cp "$H/releases/v1.0.0/skill/SKILL.md" "$OLD/harness/SKILL.md"
for d in "$H/releases/v1.0.0/skill"/*/; do cp -R "$d" "$OLD/"; done
assert_no "before: no hermes skills dir" test -e "$HOME/.hermes/skills"

out="$(harness update 2>&1)"; rc=$?
assert_eq "$rc" 0 "harness update (no flags, already current) exits 0"
assert_ok "it says the release is current" grep -qF 'Harness v1.0.0 is the latest release.' <<<"$out"
for c in $CLIS; do
  assert_ok "$c: after a plain harness update every skill in $(skdir "$c") is a link into the engine" links_ok "$(skdir "$c")" v1.0.0
done
assert_eq "$(skdir hermes)" "$HOME/.hermes/skills" "hermes reads the operator's skills from ~/.hermes/skills"
assert_ok "~/.hermes/skills/harness*/SKILL.md resolve through symlinks into the engine" \
  bash -c 'for f in "$1"/harness*/SKILL.md; do [[ "$(realpath "$f")" == "$2"/* ]] || exit 1; done' _ "$HOME/.hermes/skills" "$H/releases/v1.0.0/skill"
assert_ok "the old ~/.claude/skills copies became links" test -L "$OLD/harness-start"

# ── the operator's own skill is never touched; a removed or dangling link comes back ─────────────
HS="$HOME/.hermes/skills"
rm -rf "$HS/harness"; mkdir -p "$HS/harness"; printf -- '---\nname: harness\n---\nthe operator own\n' > "$HS/harness/SKILL.md"
rm "$HS/harness-start"
AG="$(skdir codex)"; rm "$AG/harness-stop"; ln -s "$H/releases/v0.9.0/skill/harness-stop" "$AG/harness-stop"   # an old release, pruned
out="$(harness update 2>&1)"; rc=$?
assert_eq "$rc" 0 "a second harness update (already current) exits 0"
assert_eq "$(cat "$HS/harness/SKILL.md")" "$(printf -- '---\nname: harness\n---\nthe operator own')" "an operator-owned ~/.hermes/skills/harness (no mark) is left untouched"
assert_no "...not made a link" test -L "$HS/harness/SKILL.md"
assert_ok "...and named as kept" grep -qF "kept your own skill(s) in $HS: harness" <<<"$out"
assert_ok "a removed link is restored by harness update (already current)" \
  bash -c '[[ -L "$1" && "$(readlink "$1")" == "$2" ]]' _ "$HS/harness-start" "$H/engine/skill/harness-start"
assert_ok "a dangling old-release link is repointed at the engine" \
  bash -c '[[ "$(readlink "$1")" == "$2" && -f "$1/SKILL.md" ]]' _ "$AG/harness-stop" "$H/engine/skill/harness-stop"

# ── an update that flips: the heal runs from the NEW release, so a skill it adds reaches every CLI ─
rel_publish "$SRV" v1.1.0
st="$SRV/.build/harness-v1.1.0"; mkdir -p "$st/skill/harness-late"
printf -- '---\nname: harness-late\ndescription: added in v1.1.0\n---\n' > "$st/skill/harness-late/SKILL.md"
tar -C "$SRV/.build" -czf "$SRV/download/v1.1.0/harness-v1.1.0.tar.gz" harness-v1.1.0
( cd "$SRV/download/v1.1.0" && sha256sum harness-v1.1.0.tar.gz > SHA256SUMS )
rel_latest "$SRV" v1.1.0
out="$(harness update 2>&1)"; rc=$?
assert_eq "$rc" 0 "harness update to v1.1.0 exits 0"
assert_eq "$(readlink "$H/engine")" releases/v1.1.0 "engine flipped to v1.1.0"
for c in $CLIS; do
  [[ $c == hermes ]] && continue   # its harness/ is the operator's own (above)
  assert_ok "$c: every skill links into v1.1.0, the one it added included" links_ok "$(skdir "$c")" v1.1.0
done
assert_ok "hermes: the skill v1.1.0 added is linked" test -f "$HS/harness-late/SKILL.md"

# ── harness setup / start heal too (skills_heal), only for the host's own engine ─────────────────
assert_ok "harness setup heals the skill links" grep -q '^skills_heal' "$HERE/../scripts/setup.sh"
assert_ok "harness start heals the skill links" grep -q '^skills_heal' "$HERE/../scripts/start.sh"
rm "$HS/harness-late" "$OLD/harness-arc"
heal(){ ( ENGINE_DIR="$1" HARNESS_ENGINE_LINK="$2"; source "$H/engine/scripts/lib.sh" >/dev/null 2>&1; skills_heal ); }
heal "$HERE/.." "$HERE/.." >/dev/null 2>&1
assert_no "a dev clone's setup/start never relinks the operator's skills" test -e "$HS/harness-late"
out="$(heal "$(realpath "$H/engine")" "$H/engine" 2>&1)"
assert_ok "the host engine's setup/start restores a removed link (hermes)" test -L "$HS/harness-late"
assert_ok "...and in ~/.claude/skills" test -L "$OLD/harness-arc"
assert_ok "...and says what it linked" grep -qF "linked /harness skills into $HS" <<<"$out"
out="$(heal "$(realpath "$H/engine")" "$H/engine" 2>&1)"
assert_eq "$out" "" "a heal with nothing to do says nothing"

# ── the real Hermes lists and loads a skill from a symlinked dir (fixture) ─────────────────────────
FX="$HERE/fixtures/cli/hermes/skills-symlink.txt"
assert_ok "fixture: hermes lists the symlinked harness skills" grep -qE '^│ harness +│' "$FX"
assert_ok "fixture: hermes loads the symlinked harness skill" grep -qF 'harness True harness harness/SKILL.md' "$FX"

# ── harness uninstall removes the links it made, and only those ──────────────────────────────────
( ENGINE_DIR="$(realpath "$H/engine")" HARNESS_UNINSTALL_NOMAIN=1 source "$H/engine/scripts/uninstall.sh" >/dev/null 2>&1
  rm -rf "$H/engine" "$H/releases"   # remove_engine runs first: every link is dangling by now
  remove_skills ) >/dev/null 2>&1
assert_eq "$(find "$HOME" -path "$H" -prune -o -type l -print | wc -l)" 0 "uninstall removes every skill link it made (dangling too)"
assert_eq "$(cat "$HS/harness/SKILL.md")" "$(printf -- '---\nname: harness\n---\nthe operator own')" "uninstall keeps the operator's own ~/.hermes/skills/harness"
finish
