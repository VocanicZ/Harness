# lifecycle.sh — the install / update / rollback lifecycle on a real Windows host (#491, PRD #475 Solution 5).
# NOT run by test/run.sh: it is the script `winsma.sh run <issue> install "$(cat lifecycle.sh)"` sends to the host, where it
# runs in Git Bash inside C:\hx-<issue>\ (cwd = $HX_DIR; HARNESS_HOME, HARNESS_BIN_DIR, HARNESS_USER_SKILLS, CLAUDE_CONFIG_DIR,
# TMPDIR, npm_config_cache are the isolation's). See docs/windows-smoke.md. Environment (set by the caller, all optional):
#   HX_BRANCH   the branch under test (default issue/496)
#   HX_STAGES   which stages to run, space separated: entry real tasks v011 gitco gitdef prune (default: all)
# Releases are local: this tree and the previous real tag, tarred and served over file:// with a SHA256SUMS, so a stage never
# reaches the network but for the clone. winget is a logging stub; schtasks is real except /Run and /End, so the supervise and
# web tasks are registered (logon-only, per-home name) but never started.
set -u
fail=0; say(){ echo "[$(date -u +%H:%M:%S)] $*"; }
ok(){ if eval "$2"; then say "PASS $1"; else say "FAIL $1"; fail=1; fi; }
st(){ MSYS2_ARG_CONV_EXCL='*' schtasks "$@"; }
BRANCH="${HX_BRANCH:-issue/496}"; STAGES="${HX_STAGES:-entry real tasks v011 gitco gitdef prune}"
has(){ [[ " $STAGES " == *" $1 "* ]]; }
say "== host: $(uname -srm) | bash $BASH_VERSION | python3 $(python3 --version 2>&1) | MSYS=${MSYS:-}"
say "== clone $BRANCH"
git clone -q --branch "$BRANCH" https://github.com/VocanicZ/Harness.git src || { say "clone failed"; exit 1; }
git -C src branch -q main origin/main 2>/dev/null
say "src at $(git -C src rev-parse --short HEAD)"
PREV=v0.5.0; MAIN=v9.8.0; CUR=v9.9.0
mkdir -p stubs rel/download
printf '#!/usr/bin/env bash\necho "winget $*" >> "%s/winget.log"\nexit 0\n' "$HX_DIR" > stubs/winget; : > winget.log
cat > stubs/schtasks <<'WRAP'
#!/usr/bin/env bash
case "$1" in /Run|/End) exit 0;; esac
MSYS2_ARG_CONV_EXCL='*' exec schtasks.exe "$@"
WRAP
chmod +x stubs/winget stubs/schtasks
export HARNESS_BASE_URL="file:///$HX_DIR/rel/download" HARNESS_API_URL="file:///$HX_DIR/rel/latest.json" \
  HARNESS_WINGET="$HX_DIR/stubs/winget" HARNESS_INSTALL_PREREQS=1 HARNESS_INSTALL_NOPROMPT=1 HARNESS_SKIP_RTDD=1 \
  HARNESS_SCHTASKS="$HX_DIR/stubs/schtasks" HARNESS_SUPERVISE_CONF="$HX_DIR/none.conf"
# publish <tag> <git-ref> — a release tarball of <git-ref>'s engine files, VERSION <tag>, and its SHA256SUMS
publish(){ local tag="$1" ref="$2" stg="stage/harness-$1"; rm -rf "$stg"; mkdir -p "$stg" "rel/download/$tag"
  git -C src archive "$ref" bin scripts prompts skill plugins install.sh update.sh | tar -xf - -C "$stg"
  printf '%s\n%040d\n' "$tag" 0 > "$stg/VERSION"
  printf '#!/usr/bin/env bash\necho %s\n' "$tag" > "$stg/scripts/release-marker.sh"
  tar -C stage -czf "rel/download/$tag/harness-$tag.tar.gz" "harness-$tag"
  ( cd "rel/download/$tag" && sha256sum "harness-$tag.tar.gz" > SHA256SUMS ); }
latest(){ printf '{"tag_name":"%s"}\n' "$1" > rel/latest.json; }
tnames(){ ( source "$HX_DIR/src/scripts/portable.sh"; win_task_name harness-supervise; win_task_name harness-web ); }
newhome(){ export HARNESS_HOME="$HX_DIR/h-$1" HARNESS_BIN_DIR="$HX_DIR/b-$1" HARNESS_USER_SKILLS="$HX_DIR/s-$1"; mkdir -p "$HARNESS_BIN_DIR" "$HARNESS_USER_SKILLS"
  SUP=$(tnames | sed -n 1p); WEB=$(tnames | sed -n 2p); printf '%s\n%s\n' "$SUP" "$WEB" >> "$HX_DIR/tasks"
  export PATH="$(cygpath -u "$HARNESS_BIN_DIR"):$ORIG_PATH"; say "---- home $1: $HARNESS_HOME | tasks $SUP, $WEB"; }
ORIG_PATH="$PATH"
export TMPDIR="$(cygpath -u "$TMPDIR")"   # MSYS form, the way a stock Git Bash has it (a pre-#437 release feeds tar a C:/ path)
hu(){ timeout 300 harness update "$@" </dev/null; }   # a hang is a failure, not a stuck run
ver(){ sed -n 1p "$HARNESS_HOME/engine/VERSION" 2>/dev/null; }
tgt(){ readlink "$HARNESS_HOME/engine" 2>/dev/null; }
rels(){ ls -1 "$HARNESS_HOME/releases" 2>/dev/null | grep -v '^\.' | sort | tr '\n' ' '; }
doc(){ harness doctor 2>&1 | sed -n '/^windows:/,/^locks:/p' | sed 's/^/   | /'; }
docfail(){ harness doctor 2>&1 | sed -n '/^windows:/,/^locks:/p' | grep -E "NOT SUPPORTED|MISSING|cannot|CRLF|engine:.*(—|!)" | grep -v "^  \(rtdd\|gh\|agent CLI\|git identity\)" ; }
sup_task_ok(){ st /Query /TN "$SUP" >/dev/null 2>&1; }
launcher_cmd(){ grep '^# ExecStart=' "$HARNESS_HOME/tasks/harness-supervise.sh" 2>/dev/null; }
publish "$PREV" "$PREV"; publish "$MAIN" origin/main; publish "$CUR" HEAD; latest "$CUR"
say "published $PREV (the real git tag), $MAIN (origin/main: $(git -C src rev-parse --short origin/main)) and $CUR (this branch)"

# release_stage <name> <previous tag> <1 = with the supervise and web tasks>: install the previous release, re-install, update to $CUR,
# roll back, forward, pin, uninstall.
release_stage(){ local name="$1" P="$2" T="$3" irc urc before after
  newhome "$name"
    HARNESS_REF="$P" bash src/install.sh </dev/null 2>&1 | sed 's/^/   /'; irc=${PIPESTATUS[0]}
  ok "install.sh $P exit 0" '(( irc == 0 ))'
  ok "engine is a real symlink to releases/$P" '[[ -L "$HARNESS_HOME/engine" && "$(tgt)" == "releases/$P" ]]'
  ok "harness resolves" 'command -v harness >/dev/null'
  ok "harness version is $P" '[[ "$(harness version 2>&1 | head -1)" == *"$P"* ]]'
  say "-- re-install (idempotent)"
  before="$(cd "$HARNESS_HOME" && ls -lA . releases bin | grep -v ' \.$' | sed 's/[A-Z][a-z][a-z] [ 0-9]* [0-9:]* //' | sort | md5sum)"
  HARNESS_REF="$P" bash src/install.sh </dev/null 2>&1 | sed 's/^/   /'; irc=${PIPESTATUS[0]}
  after="$(cd "$HARNESS_HOME" && ls -lA . releases bin | grep -v ' \.$' | sed 's/[A-Z][a-z][a-z] [ 0-9]* [0-9:]* //' | sort | md5sum)"
  ok "re-install exit 0" '(( irc == 0 ))'
  ok "re-install leaves the layout unchanged" '[[ "$before" == "$after" ]]'
  ok "engine still releases/$P" '[[ "$(tgt)" == "releases/$P" ]]'
  ok "doctor green (installed)" '[[ -z "$(docfail)" ]]'; doc
  if (( T )); then
    say "-- supervise + web tasks on $P"
    harness supervise --install 2>&1 | sed 's/^/   /'; harness web --install 2>&1 | sed 's/^/   /'
    ok "supervise task registered" 'sup_task_ok'; ok "web task registered" 'st /Query /TN "$WEB" >/dev/null 2>&1'
    say "launcher: $(launcher_cmd)"
  fi
  say "-- harness update ($P -> $CUR)"
  hu 2>&1 | sed 's/^/   /'; urc=${PIPESTATUS[0]}
  ok "update exit 0" '(( urc == 0 ))'
  ok "engine flipped to releases/$CUR" '[[ "$(tgt)" == "releases/$CUR" && "$(ver)" == "$CUR" ]]'
  ok "$P kept for rollback" '[[ -d "$HARNESS_HOME/releases/$P" ]]'
  ok "no stray flip link" '! ls "$HARNESS_HOME"/engine.flip.* >/dev/null 2>&1'
  if (( T )); then
    ok "supervise + web tasks still registered after the flip" 'sup_task_ok && st /Query /TN "$WEB" >/dev/null 2>&1'
    say "launcher after: $(launcher_cmd)"
    ok "launcher follows the engine link" 'launcher_cmd | grep -qF "$HARNESS_HOME/engine/bin/harness supervise"'
    ok "task XML is logon-only (no boot trigger)" '! st /Query /TN "$SUP" /XML 2>/dev/null | grep -q BootTrigger'
  fi
  ok "python3 shim present" '[[ -x "$HARNESS_HOME/bin/python3" ]]'; ok "harness.cmd present" '[[ -f "$HARNESS_BIN_DIR/harness.cmd" ]]'
  ok "doctor green (updated)" '[[ -z "$(docfail)" ]]'; doc
  say "-- update again (already current)"
  hu 2>&1 | sed 's/^/   /'; urc=${PIPESTATUS[0]}
  ok "second update exit 0, still $CUR" '(( urc == 0 )) && [[ "$(ver)" == "$CUR" ]]'
  say "-- harness update --rollback"
  hu --rollback 2>&1 | sed 's/^/   /'; urc=${PIPESTATUS[0]}
  ok "rollback exit 0" '(( urc == 0 ))'
  ok "engine back on $P" '[[ "$(tgt)" == "releases/$P" && "$(ver)" == "$P" ]]'
  ok "$CUR kept" '[[ -d "$HARNESS_HOME/releases/$CUR" ]]'
  (( T )) && ok "tasks still registered (rolled back)" 'sup_task_ok'
  ok "doctor green (rolled back)" '[[ -z "$(docfail)" ]]'; doc
  say "-- harness update --rollback (forward again)"
  hu --rollback 2>&1 | sed 's/^/   /'; urc=${PIPESTATUS[0]}
  ok "second rollback exit 0, engine forward on $CUR" '(( urc == 0 )) && [[ "$(tgt)" == "releases/$CUR" && "$(ver)" == "$CUR" ]]'
  ok "doctor green (forward)" '[[ -z "$(docfail)" ]]'
  say "-- HARNESS_REF pin (older tag, never compared)"
  HARNESS_REF="$P" hu 2>&1 | sed 's/^/   /'
  ok "pinned update lands on $P" '[[ "$(tgt)" == "releases/$P" ]]'
  say "-- harness update (unpinned) comes forward to $CUR again; uninstall runs from the current release"
  hu 2>&1 | sed 's/^/   /'; ok "engine on $CUR" '[[ "$(tgt)" == "releases/$CUR" ]]'
  harness uninstall --force --force-engine 2>&1 | sed 's/^/   /'
  ok "uninstall leaves HARNESS_HOME empty (or gone)" '[[ -z "$(ls -A "$HARNESS_HOME" 2>/dev/null)" ]]'
  (( T )) && ok "tasks gone" '! sup_task_ok'
}
if has real; then
  say "######## stage real: the real release $PREV -> this branch, rollback, forward (no tasks: $PREV registers the pre-#489 fixed task names)"
  release_stage real "$PREV" 0
fi
if has tasks; then
  say "######## stage tasks: $MAIN (origin/main) -> this branch with the supervise and web tasks installed"
  release_stage tasks "$MAIN" 1
fi

if has entry; then
  say "######## stage entry: the two install lines from Git Bash, the real network, HARNESS_REF pinned to the real $PREV, then again"
  # the engine installed is the real $PREV release; the entry points run are this branch's (npx: github:...#branch; curl: the branch's raw install.sh)
  real(){ env -u HARNESS_BASE_URL -u HARNESS_API_URL "$@"; }
  newhome npx
  say "-- npx -y github:VocanicZ/Harness#$BRANCH"
  HARNESS_REF="$PREV" real npx -y "github:VocanicZ/Harness#$BRANCH" </dev/null 2>&1 | sed 's/^/   /'; irc=${PIPESTATUS[0]}
  ok "npx line exit 0" '(( irc == 0 ))'
  ok "npx: engine is a real symlink to releases/$PREV" '[[ -L "$HARNESS_HOME/engine" && "$(tgt)" == "releases/$PREV" ]]'
  ok "npx: harness runs ($PREV)" '[[ "$(harness version 2>&1 | head -1)" == *"$PREV"* ]]'
  a="$(cd "$HARNESS_HOME" && ls -lA . releases bin | grep -v " \.$" | sed "s/[A-Z][a-z][a-z] [ 0-9]* [0-9:]* //" | sort | md5sum)"
  HARNESS_REF="$PREV" real npx -y "github:VocanicZ/Harness#$BRANCH" </dev/null 2>&1 | sed 's/^/   /'; irc=${PIPESTATUS[0]}
  b="$(cd "$HARNESS_HOME" && ls -lA . releases bin | grep -v " \.$" | sed "s/[A-Z][a-z][a-z] [ 0-9]* [0-9:]* //" | sort | md5sum)"
  ok "npx re-install exit 0 and nothing changed" '(( irc == 0 )) && [[ "$a" == "$b" ]]'
  ok "doctor green (npx install)" '[[ -z "$(docfail)" ]]'; doc
  harness uninstall --force --force-engine 2>&1 | sed 's/^/   /'
  newhome curl
  say "-- curl -fsSL https://raw.githubusercontent.com/VocanicZ/Harness/$BRANCH/install.sh | bash"
  curl -fsSL "https://raw.githubusercontent.com/VocanicZ/Harness/$BRANCH/install.sh" | HARNESS_REF="$PREV" real bash 2>&1 | sed 's/^/   /'; irc=${PIPESTATUS[1]}
  ok "curl line exit 0" '(( irc == 0 ))'
  ok "curl: engine is a real symlink to releases/$PREV" '[[ -L "$HARNESS_HOME/engine" && "$(tgt)" == "releases/$PREV" ]]'
  a="$(cd "$HARNESS_HOME" && ls -lA . releases bin | grep -v " \.$" | sed "s/[A-Z][a-z][a-z] [ 0-9]* [0-9:]* //" | sort | md5sum)"
  curl -fsSL "https://raw.githubusercontent.com/VocanicZ/Harness/$BRANCH/install.sh" | HARNESS_REF="$PREV" real bash 2>&1 | sed 's/^/   /'; irc=${PIPESTATUS[1]}
  b="$(cd "$HARNESS_HOME" && ls -lA . releases bin | grep -v " \.$" | sed "s/[A-Z][a-z][a-z] [ 0-9]* [0-9:]* //" | sort | md5sum)"
  ok "curl re-install exit 0 and nothing changed" '(( irc == 0 )) && [[ "$a" == "$b" ]]'
  ok "doctor green (curl install)" '[[ -z "$(docfail)" ]]'; doc
  say "-- HARNESS_REF pin to a different release over the same home"
  curl -fsSL "https://raw.githubusercontent.com/VocanicZ/Harness/$BRANCH/install.sh" | HARNESS_REF=v0.4.5 real bash 2>&1 | tail -3 | sed 's/^/   /'
  ok "pinned to v0.4.5 (older, never compared)" '[[ "$(tgt)" == "releases/v0.4.5" ]]'
  harness uninstall --force --force-engine 2>&1 | sed 's/^/   /'
fi

if has v011; then
  say "######## stage v011: upgrade from v0.1.1 (a git checkout engine, rebuilt here)"
  newhome v011
  mkdir -p "$HARNESS_HOME"; git clone -q src "$HARNESS_HOME/engine" && git -C "$HARNESS_HOME/engine" checkout -q -B "$BRANCH" v0.1.1 && git -C "$HARNESS_HOME/engine" branch -q --set-upstream-to="origin/$BRANCH" || { say "v0.1.1 checkout failed"; exit 1; }
  MSYS=winsymlinks:nativestrict ln -sfn "$HARNESS_HOME/engine/bin/harness" "$HARNESS_BIN_DIR/harness"
  say "v0.1.1 engine: $(git -C "$HARNESS_HOME/engine" describe --tags) is a git checkout: $([[ -d "$HARNESS_HOME/engine/.git" ]] && echo yes)"
  ok "v0.1.1 harness runs" 'harness help >/dev/null 2>&1'
  say "-- harness update (from the v0.1.1 engine's own update.sh)"
  hu 2>&1 | grep -vE '^ [^ ]+ +\| |^ create mode|^ delete mode|^ mode change|^ rename ' | sed 's/^/   /'; urc=${PIPESTATUS[0]}
  say "update from v0.1.1 exit $urc; engine now: $(tgt || echo 'not a link') $(ver)"
  if [[ "$(tgt)" != "releases/$CUR" ]]; then
    say "-- the v0.1.1 update.sh could not migrate its own checkout; re-running the install line over it"
    bash src/install.sh </dev/null 2>&1 | sed 's/^/   /'
  fi
  ok "engine migrated onto releases/$CUR" '[[ "$(tgt)" == "releases/$CUR" && "$(ver)" == "$CUR" ]]'
  ok "the v0.1.1 checkout is kept as a release (rollback target)" 'ls -d "$HARNESS_HOME"/releases/git-* >/dev/null 2>&1'
  say "releases: $(rels)"
  ok "doctor green (migrated)" '[[ -z "$(docfail)" ]]'; doc
  hu --rollback 2>&1 | sed 's/^/   /'; urc=${PIPESTATUS[0]}
  ok "rollback onto the migrated v0.1.1 tree" '(( urc == 0 )) && [[ "$(tgt)" == releases/git-* ]]'
  hu --rollback 2>&1 | sed 's/^/   /'
  ok "forward again onto $CUR" '[[ "$(tgt)" == "releases/$CUR" ]]'
  harness uninstall --force --force-engine 2>&1 | sed 's/^/   /'
fi

if has gitco; then
  say "######## stage gitco: a git-checkout engine is migrated onto releases (update.sh runs from the checkout it moves)"
  newhome gitco
  mkdir -p "$HARNESS_HOME"; git clone -q src "$HARNESS_HOME/engine" || { say "clone failed"; exit 1; }   # the branch under test
  MSYS=winsymlinks:nativestrict ln -sfn "$HARNESS_HOME/engine/bin/harness" "$HARNESS_BIN_DIR/harness"
  ok "engine is a git checkout" '[[ -d "$HARNESS_HOME/engine/.git" && ! -L "$HARNESS_HOME/engine" ]]'
  echo "local edit" > "$HARNESS_HOME/engine/LOCAL_NOTE"
  say "-- harness update (the checkout's own update.sh, with the fix)"
  hu 2>&1 | sed 's/^/   /'; urc=${PIPESTATUS[0]}
  ok "update exit 0" '(( urc == 0 ))'
  ok "engine migrated onto releases/$CUR" '[[ "$(tgt)" == "releases/$CUR" && "$(ver)" == "$CUR" ]]'
  ok "the old checkout is kept with its uncommitted edit" 'ls "$HARNESS_HOME"/releases/git-*/LOCAL_NOTE >/dev/null 2>&1'
  ok "no temp copy of update.sh is left" '! ls "$TMPDIR"/harness-update.* >/dev/null 2>&1'
  ok "doctor green (migrated)" '[[ -z "$(docfail)" ]]'; doc
  harness uninstall --force --force-engine 2>&1 | sed 's/^/   /'
  say "-- the same, with a checkout whose update.sh predates the fix ($MAIN's code): it cannot move itself on Windows; the install line can"
  newhome gitold
  mkdir -p "$HARNESS_HOME"; git clone -q src "$HARNESS_HOME/engine" && git -C "$HARNESS_HOME/engine" checkout -q origin/main || { say "clone failed"; exit 1; }
  MSYS=winsymlinks:nativestrict ln -sfn "$HARNESS_HOME/engine/bin/harness" "$HARNESS_BIN_DIR/harness"
  hu 2>&1 | sed 's/^/   /'; urc=${PIPESTATUS[0]}
  ok "the old update.sh fails cleanly (exit 3) with the checkout untouched" '(( urc == 3 )) && [[ -d "$HARNESS_HOME/engine/.git" && ! -L "$HARNESS_HOME/engine" ]]'
  bash src/install.sh </dev/null 2>&1 | tail -4 | sed 's/^/   /'
  ok "the install line migrates it" '[[ "$(tgt)" == "releases/$CUR" ]] && ls -d "$HARNESS_HOME"/releases/git-* >/dev/null 2>&1'
  harness uninstall --force --force-engine 2>&1 | sed 's/^/   /'
fi

if has gitdef; then
  say "######## stage gitdef: the same migration with the DEFAULT home (HARNESS_HOME unset, so HOME-derived /c/ paths while bin/harness exports C:/ ones); HOME is inside C:\\hx-<issue>; no task is registered under the default name"
  OLDHOME="$HOME"; export HOME="$(cygpath -u "$HX_DIR")/hm"; unset HARNESS_HOME; mkdir -p "$HOME"
  export HARNESS_BIN_DIR="$HX_DIR/b-gitdef" HARNESS_USER_SKILLS="$HX_DIR/s-gitdef"; mkdir -p "$HARNESS_BIN_DIR" "$HARNESS_USER_SKILLS"
  export PATH="$(cygpath -u "$HARNESS_BIN_DIR"):$ORIG_PATH"; DH="$HOME/.harness"; say "---- default home $DH"
  mkdir -p "$DH"; git clone -q src "$DH/engine" || { say "clone failed"; exit 1; }
  MSYS=winsymlinks:nativestrict ln -sfn "$DH/engine/bin/harness" "$HARNESS_BIN_DIR/harness"
  echo "local edit" > "$DH/engine/LOCAL_NOTE"
  hu 2>&1 | sed 's/^/   /'; urc=${PIPESTATUS[0]}
  ok "default-home update exit 0" '(( urc == 0 ))'
  ok "engine migrated onto releases/$CUR" '[[ "$(readlink "$DH/engine")" == "releases/$CUR" ]]'
  ok "the old checkout is kept with its edit" 'ls "$DH"/releases/git-*/LOCAL_NOTE >/dev/null 2>&1'
  harness uninstall --force --force-engine 2>&1 | sed 's/^/   /'
  export HOME="$OLDHOME"
fi

if has prune; then
  say "######## stage prune: releases are pruned to the current + the previous 2"
  newhome prune
  for t in v1.0.0 v1.1.0 v1.2.0 v1.3.0 v1.4.0; do publish "$t" HEAD; done
  HARNESS_REF=v1.0.0 bash src/install.sh </dev/null 2>&1 | sed 's/^/   /' | tail -3
  for t in v1.1.0 v1.2.0 v1.3.0 v1.4.0; do HARNESS_REF="$t" hu 2>&1 | tail -1 | sed 's/^/   /'; done
  say "releases after five installs: $(rels)"
  ok "prune keeps exactly 3" '[[ "$(ls -1d "$HARNESS_HOME"/releases/*/ | wc -l)" == 3 ]]'
  ok "current + previous 2 kept" '[[ "$(rels)" == "v1.2.0 v1.3.0 v1.4.0 " ]]'
  ok "engine on v1.4.0" '[[ "$(tgt)" == releases/v1.4.0 ]]'
  say "-- a corrupted archive is refused by SHA256SUMS, engine untouched"
  publish v1.5.0 HEAD; echo corrupt >> rel/download/v1.5.0/harness-v1.5.0.tar.gz
  HARNESS_REF=v1.5.0 hu 2>&1 | sed 's/^/   /'; urc=${PIPESTATUS[0]}
  ok "checksum mismatch exits 3" '(( urc == 3 ))'; ok "engine unchanged" '[[ "$(tgt)" == releases/v1.4.0 ]]'
  ok "no v1.5.0 left behind" '[[ ! -d "$HARNESS_HOME/releases/v1.5.0" ]]'
  harness uninstall --force --force-engine 2>&1 | sed 's/^/   /'
fi
say "Harness tasks left: $(st /Query /FO CSV /NH 2>/dev/null | grep -i 'Harness\\\\harness-' | cut -d, -f1 | tr '\n' ' ')"
say "result: $([[ $fail == 0 ]] && echo PASS || echo FAIL)"; exit $fail
