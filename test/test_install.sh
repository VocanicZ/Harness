#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HARNESS_INSTALL_NOMAIN=1
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }

# The host's agy is host state (#240, install-side twin of #236): ensure_skills runs
# `agy plugin install`, which re-registers agy's harness-ralph plugin on the real host. Pin BOTH
# seams at a logging stub BEFORE install.sh is sourced — export HARNESS_AGY_BIN (overriding any value
# a live fleet exported, which would bypass PATH) and put the stub first on PATH as a fallback.
AGY_STUB_DIR="$(mktemp -d)"; AGY_LOG="$AGY_STUB_DIR/agy.log"; : > "$AGY_LOG"
printf '#!/usr/bin/env bash\necho "$*" >> %q\n' "$AGY_LOG" > "$AGY_STUB_DIR/agy"; chmod +x "$AGY_STUB_DIR/agy"
export HARNESS_AGY_BIN="$AGY_STUB_DIR/agy" PATH="$AGY_STUB_DIR:$PATH"
source "$HERE/../install.sh"

# ── prereqs (unchanged) ───────────────────────────────────────────────────────
# PATH stubs to simulate tool presence; check_prereqs uses real `command -v` + `gh auth status`
REAL_PATH="$PATH"
PATHBIN="$(mktemp -d)"; export PATH="$PATHBIN:$PATH"
for t in git tmux python3 gh claude; do printf '#!/bin/sh\nexit 0\n' > "$PATHBIN/$t"; chmod +x "$PATHBIN/$t"; done
printf '#!/bin/sh\ncase "$1" in auth) exit 0;; version) exit 0;; esac\nexit 0\n' > "$PATHBIN/gh"; chmod +x "$PATHBIN/gh"
assert "prereqs pass when all present" "check_prereqs"
# remove claude -> fail. agy is absent too: HARNESS_AGY_BIN names a binary that does not exist, which
# must read as "agy absent" (#240) rather than satisfying the claude-or-agy check.
# Both run on a PATH of only the stubs + the system bin dirs (no host claude/agy) with a fresh hash
# table — the deleted claude stub is still hashed from the run above.
rm -f "$PATHBIN/claude"
noclaude(){ ( hash -r; PATH="$PATHBIN:/usr/bin:/bin"; check_prereqs ); }
assert "prereqs fail without claude"   "! HARNESS_AGY_BIN='$AGY_STUB_DIR/nope' noclaude 2>/dev/null"
# ...while a present HARNESS_AGY_BIN satisfies it, and is the binary probed (not PATH's agy).
: > "$AGY_LOG"
assert "prereqs pass with only agy (via HARNESS_AGY_BIN)" "noclaude"
assert "check_prereqs probes HARNESS_AGY_BIN --version" "grep -qx -- '--version' '$AGY_LOG'"
printf '#!/bin/sh\nexit 0\n' > "$PATHBIN/claude"; chmod +x "$PATHBIN/claude"
# unauthenticated gh -> fail
printf '#!/bin/sh\ncase "$1" in auth) exit 1;; esac\nexit 0\n' > "$PATHBIN/gh"; chmod +x "$PATHBIN/gh"
assert "prereqs fail when gh not authed" "! check_prereqs 2>/dev/null"
# restore a working gh stub for the remainder
printf '#!/bin/sh\ncase "$1" in auth) exit 0;; version) exit 0;; esac\nexit 0\n' > "$PATHBIN/gh"; chmod +x "$PATHBIN/gh"

# ── shared-install: engine goes to ONE host location (#54, PRD #52 slice 2) ────
# Done poking at prereqs; restore the REAL PATH so place_engine runs real curl/tar/ln/realpath.
export PATH="$REAL_PATH"
# The engine is a published release now (#282), not a clone: serve a fake one over file:// and
# install FROM it into HARNESS_HOME/releases/<tag>, behind the HARNESS_HOME/engine symlink.
source "$HERE/release_fixture.sh"
SRV="$(mktemp -d)/srv"; rel_server "$SRV"; rel_publish "$SRV" v0.1.0; rel_latest "$SRV" v0.1.0

HOME_TMP="$(mktemp -d)"; HH="$HOME_TMP/.harness"
HARNESS_HOME="$HH" place_engine >/dev/null 2>&1
assert "engine installed to the single host location ~/.harness/engine" "[[ -x '$HH/engine/bin/harness' ]]"
assert "installed engine is a release behind the engine symlink (update can flip it)" \
  "[[ -L '$HH/engine' && \"\$(readlink '$HH/engine')\" == releases/v0.1.0 ]]"

# re-running place_engine is idempotent (an installed same tag is a no-op flip, not a re-download)
HARNESS_HOME="$HH" place_engine >/dev/null 2>&1; pe_rc=$?
assert "place_engine is idempotent on an existing install" "[[ $pe_rc -eq 0 && -x '$HH/engine/bin/harness' ]]"

# ── place_engine over a git-checkout engine: migrated aside, local edits kept (not ff-pulled) ──
# Before releases, a diverged ff-pull made place_engine fail non-zero. Now install moves the checkout,
# local commit and all, to releases/git-<sha> and flips engine to the release — never git-resets it.
DREMOTE="$(mktemp -d)/dremote.git"; git init -q --bare -b main "$DREMOTE"
DWORK="$(mktemp -d)"; : > "$DWORK/f"
git -C "$DWORK" init -q; git -C "$DWORK" branch -M main
git -C "$DWORK" -c user.email=t@t -c user.name=t add -A
git -C "$DWORK" -c user.email=t@t -c user.name=t commit -qm init >/dev/null
git -C "$DWORK" remote add origin "$DREMOTE"; git -C "$DWORK" -c user.email=t@t -c user.name=t push -q -u origin main
DHH="$(mktemp -d)/.harness"; mkdir -p "$DHH"; git clone -q "$DREMOTE" "$DHH/engine"
# local diverging commit on the engine
printf 'local\n' > "$DHH/engine/f"; git -C "$DHH/engine" -c user.email=t@t -c user.name=t commit -qam local >/dev/null
DSHA="$(git -C "$DHH/engine" rev-parse --short=12 HEAD)"
HARNESS_HOME="$DHH" place_engine >/dev/null 2>&1; pe_rc=$?
assert "place_engine over a git-checkout engine succeeds" "[[ $pe_rc -eq 0 ]]"
assert "the git checkout's engine now points at the release" "[[ \"\$(readlink '$DHH/engine')\" == releases/v0.1.0 ]]"
assert "the git checkout is kept, local commit and all" "[[ \"\$(cat '$DHH/releases/git-$DSHA/f')\" == local ]]"

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
         harness-plan harness-prd harness-issue harness-one; do
  assert "/$n deployed to user scope" "[[ -f '$USK/$n/SKILL.md' ]]"
done
# idempotent re-install: still present, no error
HARNESS_SKILL_SRC="$SK_SRC" HARNESS_USER_SKILLS="$USK" install_harness_skills >/dev/null
assert "install_harness_skills is idempotent" "[[ -f '$USK/harness/SKILL.md' ]]"
# #303: the handoff skill every checkpoint names ships with them; an operator's own same-named skill
# is never overwritten.
assert "handoff skill deployed to user scope (#303)" "cmp -s '$SK_SRC/handoff/SKILL.md' '$USK/handoff/SKILL.md'"
USK2="$(mktemp -d)/skills"; mkdir -p "$USK2/handoff"; echo "operator own" > "$USK2/handoff/SKILL.md"
HARNESS_SKILL_SRC="$SK_SRC" HARNESS_USER_SKILLS="$USK2" install_harness_skills >/dev/null
assert "an operator's own handoff skill is kept (#303)" "[[ \"\$(cat '$USK2/handoff/SKILL.md')\" == 'operator own' ]]"
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

# ── ensure_skills drives agy through HARNESS_AGY_BIN, never the host's agy (#240) ──
# Sandbox HOME *and* HARNESS_HOME (install.sh computed HARNESS_HOME from the real $HOME at source
# time), so the plugin dir handed to `plugin install` is inside the sandbox, never ~/.harness.
A3="$(mktemp -d)"; A3HOME="$A3/home"; A3HH="$A3/.harness"
mkdir -p "$A3HOME/.claude/skills/to-prd" "$A3HOME/.claude/skills/to-issues" "$A3HH/engine/plugins/ralph-loop"
: > "$AGY_LOG"
HOME="$A3HOME" HARNESS_HOME="$A3HH" ensure_skills >/dev/null 2>&1; es_rc=$?
assert "ensure_skills logs exactly plugin list then plugin install <sandbox dir>" \
  "[[ \"\$(cat '$AGY_LOG')\" == \"plugin list
plugin install $A3HH/engine/plugins/ralph-loop\" ]]"
assert "ensure_skills exits 0 with the agy stub" "[[ $es_rc -eq 0 ]]"
# already registered: `plugin list` names harness-ralph -> no install
printf '#!/usr/bin/env bash\necho "$*" >> %q\n[[ "$1" == plugin && "$2" == list ]] && echo \x27{"name": "harness-ralph"}\x27\nexit 0\n' \
  "$AGY_LOG" > "$AGY_STUB_DIR/agy-listed"; chmod +x "$AGY_STUB_DIR/agy-listed"
: > "$AGY_LOG"
HOME="$A3HOME" HARNESS_HOME="$A3HH" HARNESS_AGY_BIN="$AGY_STUB_DIR/agy-listed" ensure_skills >/dev/null 2>&1
assert "a registered harness-ralph is not re-installed" "[[ \"\$(cat '$AGY_LOG')\" == 'plugin list' ]]"
# a failing agy keeps ensure_skills best-effort
printf '#!/usr/bin/env bash\necho "$*" >> %q\nexit 1\n' "$AGY_LOG" > "$AGY_STUB_DIR/agy-fail"; chmod +x "$AGY_STUB_DIR/agy-fail"
: > "$AGY_LOG"
HOME="$A3HOME" HARNESS_HOME="$A3HH" HARNESS_AGY_BIN="$AGY_STUB_DIR/agy-fail" ensure_skills >/dev/null 2>&1; es_rc=$?
assert "a failing agy is non-fatal for ensure_skills" "[[ $es_rc -eq 0 ]]"
assert "the failing agy was still the one called" "grep -qx 'plugin install $A3HH/engine/plugins/ralph-loop' '$AGY_LOG'"
# a nonexistent HARNESS_AGY_BIN reads as agy absent: the agy block is skipped, no call at all
: > "$AGY_LOG"
HOME="$A3HOME" HARNESS_HOME="$A3HH" HARNESS_AGY_BIN="$AGY_STUB_DIR/nope" ensure_skills >/dev/null 2>&1; es_rc=$?
assert "a missing HARNESS_AGY_BIN skips the agy block, exit 0" "[[ $es_rc -eq 0 && ! -s '$AGY_LOG' ]]"

echo "── install ok"
