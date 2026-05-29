#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HARNESS_INSTALL_NOMAIN=1
source "$HERE/../install.sh"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }

# ── prereqs (unchanged) ───────────────────────────────────────────────────────
# PATH stubs to simulate tool presence; check_prereqs uses real `command -v` + `gh auth status`
REAL_PATH="$PATH"
PATHBIN="$(mktemp -d)"; export PATH="$PATHBIN:$PATH"
for t in git tmux python3 gh claude; do printf '#!/bin/sh\nexit 0\n' > "$PATHBIN/$t"; chmod +x "$PATHBIN/$t"; done
printf '#!/bin/sh\ncase "$1" in auth) exit 0;; version) exit 0;; esac\nexit 0\n' > "$PATHBIN/gh"; chmod +x "$PATHBIN/gh"
assert "prereqs pass when all present" "check_prereqs"
# remove claude -> fail
rm -f "$PATHBIN/claude"
assert "prereqs fail without claude"   "! check_prereqs 2>/dev/null"
printf '#!/bin/sh\nexit 0\n' > "$PATHBIN/claude"; chmod +x "$PATHBIN/claude"
# unauthenticated gh -> fail
printf '#!/bin/sh\ncase "$1" in auth) exit 1;; esac\nexit 0\n' > "$PATHBIN/gh"; chmod +x "$PATHBIN/gh"
assert "prereqs fail when gh not authed" "! check_prereqs 2>/dev/null"
# restore a working gh stub for the remainder
printf '#!/bin/sh\ncase "$1" in auth) exit 0;; version) exit 0;; esac\nexit 0\n' > "$PATHBIN/gh"; chmod +x "$PATHBIN/gh"

# ── shared-install: engine goes to ONE host location (#54, PRD #52 slice 2) ────
# Done poking at prereqs; restore the REAL PATH so place_engine clones with real git/ln/realpath.
export PATH="$REAL_PATH"
# Build a throwaway "engine remote" (a real git repo) and clone FROM it into HARNESS_HOME/engine.
SRC="$(mktemp -d)/engine-src"; mkdir -p "$SRC/bin"
printf '#!/usr/bin/env bash\necho stub-engine\n' > "$SRC/bin/harness"; chmod +x "$SRC/bin/harness"
git -C "$SRC" init -q
git -C "$SRC" -c user.email=t@t -c user.name=t add -A
git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm init >/dev/null

HOME_TMP="$(mktemp -d)"; HH="$HOME_TMP/.harness"
HARNESS_HOME="$HH" HARNESS_REPO_URL="$SRC" place_engine >/dev/null 2>&1
assert "engine installed to the single host location ~/.harness/engine" "[[ -x '$HH/engine/bin/harness' ]]"
assert "installed engine is a git checkout (update can ff-pull it)"      "[[ -d '$HH/engine/.git' ]]"

# re-running place_engine is idempotent (ff-pulls, does not re-clone / error)
HARNESS_HOME="$HH" HARNESS_REPO_URL="$SRC" place_engine >/dev/null 2>&1
assert "place_engine is idempotent on an existing install" "[[ -x '$HH/engine/bin/harness' ]]"

# ── place_engine surfaces a FAILED ff-pull as non-zero (consistent with update.sh; not swallowed) ──
# Build a real remote+clone, then DIVERGE the local engine so `pull --ff-only` cannot fast-forward.
DREMOTE="$(mktemp -d)/dremote.git"; git init -q --bare -b main "$DREMOTE"
DWORK="$(mktemp -d)"; : > "$DWORK/f"
git -C "$DWORK" init -q; git -C "$DWORK" branch -M main
git -C "$DWORK" -c user.email=t@t -c user.name=t add -A
git -C "$DWORK" -c user.email=t@t -c user.name=t commit -qm init >/dev/null
git -C "$DWORK" remote add origin "$DREMOTE"; git -C "$DWORK" -c user.email=t@t -c user.name=t push -q -u origin main
DHH="$(mktemp -d)/.harness"; mkdir -p "$DHH"; git clone -q "$DREMOTE" "$DHH/engine"
# local diverging commit on the engine
printf 'local\n' > "$DHH/engine/f"; git -C "$DHH/engine" -c user.email=t@t -c user.name=t commit -qam local >/dev/null
# divergent upstream advance
printf 'upstream\n' > "$DWORK/f"; git -C "$DWORK" -c user.email=t@t -c user.name=t commit -qam up >/dev/null
git -C "$DWORK" -c user.email=t@t -c user.name=t push -q
HARNESS_HOME="$DHH" place_engine >/dev/null 2>&1; pe_rc=$?
assert "place_engine returns non-zero on a diverged ff-pull" "[[ $pe_rc -ne 0 ]]"

# ── PATH symlink: harness -> ~/.harness/engine/bin/harness, resolved via realpath ──
BIN_TMP="$(mktemp -d)/bin"
HARNESS_HOME="$HH" HARNESS_BIN_DIR="$BIN_TMP" link_path >/dev/null 2>&1
assert "PATH entrypoint is a symlink"                  "[[ -L '$BIN_TMP/harness' ]]"
assert "which harness resolves (symlink -> realpath) to ~/.harness/engine/bin/harness" \
  "[[ \"\$(realpath '$BIN_TMP/harness')\" == \"\$(realpath '$HH/engine/bin/harness')\" ]]"

# ── portability mitigation: symlink un-writable -> print explicit PATH instructions ──
RO="$(mktemp -d)"; chmod 555 "$RO"
fail_out="$(HARNESS_HOME="$HH" HARNESS_BIN_DIR="$RO" link_path 2>&1)"
chmod 755 "$RO"
assert "symlink-fail creates no broken link"          "[[ ! -e '$RO/harness' ]]"
assert "symlink-fail prints explicit PATH guidance"   "grep -q 'PATH' <<< \"\$fail_out\""
assert "symlink-fail names the engine bin dir to add" "grep -q 'engine/bin' <<< \"\$fail_out\""

# ── host root: install creates the ~/.harness poller/ + snapshots/ dirs EMPTY (#57) ──
# Install only establishes the layout; the PRD-B host poller (#69) populates these at runtime when
# a fleet opts in via HARNESS_USE_POLLER. So a fresh install leaves both dirs present but empty.
HR="$(mktemp -d)/.harness"
HARNESS_HOME="$HR" create_host_root
assert "host root poller/ exists"    "[[ -d '$HR/poller' ]]"
assert "host root snapshots/ exists" "[[ -d '$HR/snapshots' ]]"
assert "poller/ is empty at install time"    "[[ -z \"\$(ls -A '$HR/poller')\" ]]"
assert "snapshots/ is empty at install time" "[[ -z \"\$(ls -A '$HR/snapshots')\" ]]"
# idempotent: re-running on an existing host root is a clean no-op (still empty, no error)
HARNESS_HOME="$HR" create_host_root
assert "create_host_root is idempotent" "[[ -d '$HR/poller' && -z \"\$(ls -A '$HR/poller')\" ]]"

# ── /harness skills install ONCE to USER scope (~/.claude/skills), not vendored per project (#57) ──
# Source is the engine's skill/ dir; each skill/<name>/SKILL.md → <user-skills>/<name>/SKILL.md.
SK_SRC="$HERE/../skill"
USK="$(mktemp -d)/skills"
HARNESS_SKILL_SRC="$SK_SRC" HARNESS_USER_SKILLS="$USK" install_harness_skills >/dev/null
assert "umbrella /harness skill installed to user scope" "[[ -f '$USK/harness/SKILL.md' ]]"
for n in harness-init harness-start harness-stop harness-pause harness-resume harness-status \
         harness-plan harness-prd harness-issue; do
  assert "/$n deployed to user scope" "[[ -f '$USK/$n/SKILL.md' ]]"
done
# idempotent re-install: still present, no error
HARNESS_SKILL_SRC="$SK_SRC" HARNESS_USER_SKILLS="$USK" install_harness_skills >/dev/null
assert "install_harness_skills is idempotent" "[[ -f '$USK/harness/SKILL.md' ]]"
# missing source: warn (best-effort), never fail the install
miss_out="$(HARNESS_SKILL_SRC="$(mktemp -d)/nope" HARNESS_USER_SKILLS="$(mktemp -d)/sk" install_harness_skills 2>&1)"
assert "missing skill source is non-fatal" "[[ \$? -eq 0 ]]"

# ── ensure_skills installs ONLY to-prd/to-issues, never clobbers a user's same-named skill ──
# The matt-pocock clone can carry extra SKILL.md dirs. ensure_skills must copy ONLY the intended
# skills (the ones its guard checks), not every SKILL.md parent dir — otherwise it overwrites a
# user's pre-existing same-named skill and pulls in skills never requested.
A2="$(mktemp -d)"
A2REPO="$A2/skills-src"; mkdir -p "$A2REPO/to-prd" "$A2REPO/to-issues" "$A2REPO/evil"
printf 'name: to-prd\n'    > "$A2REPO/to-prd/SKILL.md"
printf 'name: to-issues\n' > "$A2REPO/to-issues/SKILL.md"
printf 'name: evil\nPAYLOAD\n' > "$A2REPO/evil/SKILL.md"
git -C "$A2REPO" init -q
git -C "$A2REPO" -c user.email=t@t -c user.name=t add -A
git -C "$A2REPO" -c user.email=t@t -c user.name=t commit -qm init >/dev/null
A2HOME="$A2/home"; mkdir -p "$A2HOME/.claude/skills/evil"
printf 'MY_OWN_SENTINEL\n' > "$A2HOME/.claude/skills/evil/SKILL.md"   # user's own skill — must survive
HOME="$A2HOME" MATTPOCOCK_SKILLS_URL="$A2REPO" ensure_skills >/dev/null 2>&1
assert "ensure_skills installs to-prd"                "[[ -d '$A2HOME/.claude/skills/to-prd' ]]"
assert "ensure_skills installs to-issues"             "[[ -d '$A2HOME/.claude/skills/to-issues' ]]"
assert "ensure_skills does NOT clobber user's evil skill" "grep -q MY_OWN_SENTINEL '$A2HOME/.claude/skills/evil/SKILL.md'"
assert "ensure_skills does NOT pull in unrequested evil skill" "! grep -q PAYLOAD '$A2HOME/.claude/skills/evil/SKILL.md'"

echo "── install ok"
