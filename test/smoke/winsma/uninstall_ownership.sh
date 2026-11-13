# uninstall_ownership.sh — #1111: the uninstall lifecycle on winsma, plus the operator's own skills. Sent as: winsma.sh run 1111 install "$(cat uninstall_ownership.sh)" (adapted from #490's uninstall run).
# #1111 on winsma, inside C:\hx-1111 (cwd = $HX_DIR; HARNESS_HOME, HARNESS_BIN_DIR, HARNESS_USER_SKILLS, CLAUDE_CONFIG_DIR are the isolation's).
set -u
fail=0; say(){ echo "[$(date -u +%H:%M:%S)] $*"; }
ok(){ if eval "$2"; then say "PASS $1"; else say "FAIL $1"; fail=1; fi; }
st(){ MSYS2_ARG_CONV_EXCL='*' schtasks "$@"; }
say "== host: $(uname -srm) | bash $BASH_VERSION | python3 $(python3 --version 2>&1)"
say "== 1. clone the branch under test"
git clone -q --branch issue/1111 https://github.com/VocanicZ/Harness.git src || { say "clone failed"; exit 1; }
say "src at $(git -C src rev-parse --short HEAD)"
say "== 2. a local release of THIS tree, served over file://"
tag=v0.0.0-i1111; stg="stage/harness-$tag"; mkdir -p "$stg" "rel/download/$tag"
( cd src && tar -cf - bin scripts prompts skill plugins install.sh update.sh ) | tar -xf - -C "$stg"
printf '%s\n%040d\n' "$tag" 0 > "$stg/VERSION"
printf '#!/usr/bin/env bash\necho %s\n' "$tag" > "$stg/scripts/release-marker.sh"
tar -C stage -czf "rel/download/$tag/harness-$tag.tar.gz" "harness-$tag"
( cd "rel/download/$tag" && sha256sum "harness-$tag.tar.gz" > SHA256SUMS )
mkdir -p stubs
printf '#!/usr/bin/env bash\necho "winget $*" >> "%s/winget.log"\nexit 0\n' "$HX_DIR" > stubs/winget; : > winget.log
# schtasks is real except /Run and /End, so no supervisor or dashboard process is started
cat > stubs/schtasks <<'WRAP'
#!/usr/bin/env bash
case "$1" in /Run|/End) exit 0;; esac
MSYS2_ARG_CONV_EXCL='*' exec schtasks.exe "$@"
WRAP
chmod +x stubs/schtasks
export HARNESS_BASE_URL="file:///$HX_DIR/rel/download" HARNESS_REF="$tag" HARNESS_WINGET="$HX_DIR/stubs/winget" \
  HARNESS_INSTALL_PREREQS=1 HARNESS_INSTALL_NOPROMPT=1 HARNESS_SKIP_RTDD=1 HARNESS_SCHTASKS="$HX_DIR/stubs/schtasks" \
  HARNESS_SUPERVISE_CONF="$HX_DIR/none.conf"
tnames(){ ( source "$HX_DIR/src/scripts/portable.sh"; win_task_name harness-supervise; win_task_name harness-web ); }
SUP=$(tnames | sed -n 1p); WEB=$(tnames | sed -n 2p)
printf '%s\n%s\n' "$SUP" "$WEB" >> "$HX_DIR/tasks"       # recorded for cleanup before anything is registered
say "per-home tasks: $SUP | $WEB"
say "Harness tasks before: $(st /Query /FO CSV /NH 2>/dev/null | grep -i 'Harness\\\\harness-' | cut -d, -f1 | tr '\n' ' ')"
count(){ find "$1" -mindepth 1 2>/dev/null | wc -l; }
run_round(){ # $1 = label, $2 = 1 to put a user's own files beside Harness's
  say "######## round $1"
  say "== install.sh"
  bash src/install.sh </dev/null 2>&1 | sed 's/^/   /'; irc=${PIPESTATUS[0]}
  ok "install.sh exit 0" '(( irc == 0 ))'
  export PATH="$(cygpath -u "$HARNESS_BIN_DIR"):$PATH"
  H="$(command -v harness)"; say "harness resolves to: $H"
  say "== supervise --install, web --install"
  harness supervise --install 2>&1 | sed 's/^/   /'
  harness web --install 2>&1 | sed 's/^/   /'
  for n in "$SUP" "$WEB"; do ok "registered: $n" 'st /Query /TN "$n" >/dev/null 2>&1'; done
  # what a few runs of a fleet leave beside the engine
  mkdir -p "$HARNESS_HOME/poller/registry" "$HARNESS_HOME/fleets" "$HARNESS_HOME/snapshots" "$HARNESS_HOME/supervise"
  echo '{}' > "$HARNESS_HOME/poller/registry/x.json"; echo '{}' > "$HARNESS_HOME/fleets/hz.json"
  echo '{}' > "$HARNESS_HOME/snapshots/a.json"; echo '{}' > "$HARNESS_HOME/events.jsonl"; : > "$HARNESS_HOME/supervise.log"
  if [[ "$2" == 1 ]]; then printf 'mine\n' > "$HARNESS_BIN_DIR/mytool.cmd"; printf 'mine\n' > "$HARNESS_HOME/notes.txt"; mkdir -p "$HARNESS_USER_SKILLS/my-own-skill"; : > "$HARNESS_USER_SKILLS/my-own-skill/SKILL.md"
    # #1111: the operator's own link into another skill/ dir, and their own harness-* skill dir
    mkdir -p "$HX_DIR/myrepo/skill/foo"; printf 'mine\n' > "$HX_DIR/myrepo/skill/foo/SKILL.md"
    MSYS=winsymlinks:nativestrict ln -s "$HX_DIR/myrepo/skill/foo" "$HARNESS_USER_SKILLS/foo" || say "WARN could not plant the operator's link"
    mkdir -p "$HARNESS_USER_SKILLS/harness-mytool"; printf 'mine\n' > "$HARNESS_USER_SKILLS/harness-mytool/SKILL.md"; fi
  say "installed state: HARNESS_HOME=$(count "$HARNESS_HOME") entries, HARNESS_BIN_DIR: $(ls -A "$HARNESS_BIN_DIR" | tr '\n' ' '), HARNESS_USER_SKILLS: $(ls -A "$HARNESS_USER_SKILLS" | tr '\n' ' ')"
  ok "python3 shim present" '[[ -x "$HARNESS_HOME/bin/python3" ]]'
  ok "harness.cmd present" '[[ -f "$HARNESS_BIN_DIR/harness.cmd" ]]'
  ok "task launchers present" 'ls "$HARNESS_HOME"/tasks/*.sh >/dev/null 2>&1'
  say "== harness uninstall --force --force-engine"
  harness uninstall --force --force-engine 2>&1 | sed 's/^/   /'; urc=${PIPESTATUS[0]}
  ok "uninstall exit 0" '(( urc == 0 ))'
  for n in "$SUP" "$WEB"; do ok "task gone: $n" '! st /Query /TN "$n" >/dev/null 2>&1'; done
  say "after: HARNESS_HOME: $(ls -A "$HARNESS_HOME" 2>/dev/null | tr '\n' ' ')| HARNESS_BIN_DIR: $(ls -A "$HARNESS_BIN_DIR" 2>/dev/null | tr '\n' ' ')| HARNESS_USER_SKILLS: $(ls -A "$HARNESS_USER_SKILLS" 2>/dev/null | tr '\n' ' ')"
  if [[ "$2" == 1 ]]; then
    ok "user file in the bin dir survives"   '[[ "$(cat "$HARNESS_BIN_DIR/mytool.cmd" 2>/dev/null)" == mine ]]'
    ok "user file in HARNESS_HOME survives"  '[[ "$(cat "$HARNESS_HOME/notes.txt" 2>/dev/null)" == mine ]]'
    ok "a skill Harness did not install survives"            '[[ -f "$HARNESS_USER_SKILLS/my-own-skill/SKILL.md" ]]'
    ok "the operator's link into their own skill/ survives (#1111)" '[[ -L "$HARNESS_USER_SKILLS/foo" && "$(cat "$HARNESS_USER_SKILLS/foo/SKILL.md" 2>/dev/null)" == mine ]]'
    ok "the operator's own harness-mytool survives (#1111)" '[[ "$(cat "$HARNESS_USER_SKILLS/harness-mytool/SKILL.md" 2>/dev/null)" == mine ]]'
    ok "HARNESS_USER_SKILLS holds only the operator's three" '[[ "$(ls -A "$HARNESS_USER_SKILLS" | sort | tr "\n" " ")" == "foo harness-mytool my-own-skill " ]]'
    ok "bin dir holds only the user's file"  '[[ "$(ls -A "$HARNESS_BIN_DIR")" == mytool.cmd ]]'
    ok "HARNESS_HOME holds only the user's file" '[[ "$(ls -A "$HARNESS_HOME")" == notes.txt ]]'
    rm -rf "$HARNESS_BIN_DIR/mytool.cmd" "$HARNESS_HOME/notes.txt" "$HARNESS_USER_SKILLS/my-own-skill" "$HARNESS_USER_SKILLS/foo" "$HARNESS_USER_SKILLS/harness-mytool"
  else
    ok "HARNESS_HOME empty (or gone)"        '[[ -z "$(ls -A "$HARNESS_HOME" 2>/dev/null)" ]]'
    ok "HARNESS_BIN_DIR empty"               '[[ -z "$(ls -A "$HARNESS_BIN_DIR" 2>/dev/null)" ]]'
    ok "HARNESS_USER_SKILLS empty"           '[[ -z "$(ls -A "$HARNESS_USER_SKILLS" 2>/dev/null)" ]]'
  fi
}
run_round 1 0
run_round 2 1
say "Harness tasks after: $(st /Query /FO CSV /NH 2>/dev/null | grep -i 'Harness\\\\harness-' | cut -d, -f1 | tr '\n' ' ')"
say "result: $([[ $fail == 0 ]] && echo PASS || echo FAIL)"; exit $fail
