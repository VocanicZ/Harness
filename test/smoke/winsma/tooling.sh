# tooling.sh — lane tooling and skills on a real Windows host (#495, PRD #475 Solution 7).
# NOT run by test/run.sh: it is the script `winsma.sh run <issue> install "$(cat tooling.sh)"` sends to the host, where it runs in
# Git Bash inside C:\hx-<issue>\ (cwd = $HX_DIR; HARNESS_HOME, HARNESS_BIN_DIR, HARNESS_USER_SKILLS, CLAUDE_CONFIG_DIR, TMPDIR,
# npm_config_cache are the isolation's). See docs/windows-smoke.md. Environment (set by the caller, all optional):
#   HX_BRANCH   the branch under test (default issue/495)
#   HX_STAGES   which stages to run, space separated: install skills lane (default: all)
# Stages:
#   install  this branch as a local release, installed into the sandbox; rtdd resolves to the host's real rtdd.exe
#   skills   `harness update --with-skills` installs the plugins into the sandbox CLAUDE_CONFIG_DIR and the skills into
#            HARNESS_USER_SKILLS (never the real ~/.claude), and every skill a lane prompt names ({{skill:…}}) is there
#   lane     a lane-shaped shell (the lane's env: the shim first on PATH, a short TMPDIR) in a worktree whose path has a space
#            runs git, gh, rtdd.exe, python3, grep and sed
# winget is a logging stub (never a real install); rtdd is NOT installed here — the host's own rtdd.exe is found, never run
# through its installer (which writes skills machine-wide).
set -u
fail=0; say(){ echo "[$(date -u +%H:%M:%S)] $*"; }
ok(){ if eval "$2"; then say "PASS $1"; else say "FAIL $1"; fail=1; fi; }
BRANCH="${HX_BRANCH:-issue/495}"; STAGES="${HX_STAGES:-install skills lane}"
has(){ [[ " $STAGES " == *" $1 "* ]]; }
say "== host: $(uname -srm) | bash $BASH_VERSION | python3 $(python3 --version 2>&1) | MSYS=${MSYS:-}"
say "== clone $BRANCH"
git clone -q --branch "$BRANCH" https://github.com/VocanicZ/Harness.git src || { say "clone failed"; exit 1; }
say "src at $(git -C src rev-parse --short HEAD)"
CUR=v9.9.9
mkdir -p stubs rel/download
printf '#!/usr/bin/env bash\necho "winget $*" >> "%s/winget.log"\nexit 0\n' "$HX_DIR" > stubs/winget; : > winget.log
printf '#!/usr/bin/env bash\ncase "$1" in /Run|/End) exit 0;; esac\nMSYS2_ARG_CONV_EXCL="*" exec schtasks.exe "$@"\n' > stubs/schtasks
chmod +x stubs/winget stubs/schtasks
export HARNESS_BASE_URL="file:///$HX_DIR/rel/download" HARNESS_API_URL="file:///$HX_DIR/rel/latest.json" \
  HARNESS_WINGET="$HX_DIR/stubs/winget" HARNESS_INSTALL_PREREQS=1 HARNESS_INSTALL_NOPROMPT=1 \
  HARNESS_SCHTASKS="$HX_DIR/stubs/schtasks" HARNESS_SUPERVISE_CONF="$HX_DIR/none.conf"
export TMPDIR="$(cygpath -u "$TMPDIR")"
HOST_PATH="$PATH"
mkdir -p "stage/harness-$CUR" "rel/download/$CUR"
git -C src archive HEAD bin scripts prompts skill plugins install.sh update.sh | tar -xf - -C "stage/harness-$CUR"
printf '%s\n%040d\n' "$CUR" 0 > "stage/harness-$CUR/VERSION"
tar -C stage -czf "rel/download/$CUR/harness-$CUR.tar.gz" "harness-$CUR"
( cd "rel/download/$CUR" && sha256sum "harness-$CUR.tar.gz" > SHA256SUMS )
printf '{"tag_name":"%s"}\n' "$CUR" > rel/latest.json
say "published $CUR from this branch"
mkdir -p "$HARNESS_BIN_DIR" "$HARNESS_USER_SKILLS"
export PATH="$(cygpath -u "$HARNESS_BIN_DIR"):$HOST_PATH"
E="$HARNESS_HOME/engine"
hv(){ timeout 600 harness "$@" </dev/null; }

if has install; then
  say "######## stage install: this branch into the sandbox"
  HARNESS_REF="$CUR" bash src/install.sh </dev/null 2>&1 | sed 's/^/   /'; irc=${PIPESTATUS[0]}
  ok "install.sh exit 0" '(( irc == 0 ))'
  ok "engine is releases/$CUR" '[[ "$(readlink "$HARNESS_HOME/engine")" == "releases/$CUR" ]]'
  RT="$( ( source "$E/scripts/portable.sh"; rtdd_exe ) 2>&1 )"; say "rtdd_exe: $RT"
  ok "rtdd resolves to an rtdd.exe" '[[ "$RT" == *rtdd.exe ]]'
  ok "…which runs" '"$RT" --version >/dev/null 2>&1'
fi

if has skills; then
  say "######## stage skills: harness update --with-skills into the sandbox (CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR, skills $HARNESS_USER_SKILLS)"
  [[ -e "$E/bin/harness" ]] || HARNESS_REF="$CUR" bash src/install.sh </dev/null >/dev/null 2>&1
  rm -rf "$HARNESS_USER_SKILLS"; mkdir -p "$HARNESS_USER_SKILLS"
  hv update --with-skills 2>&1 | sed 's/^/   /'; urc=${PIPESTATUS[0]}
  ok "update --with-skills exit 0" '(( urc == 0 ))'
  say "skills dir: $(ls -1 "$HARNESS_USER_SKILLS" | tr '\n' ' ')"
  for s in to-prd to-issues subagent-task-tree harness handoff; do ok "skill $s is in HARNESS_USER_SKILLS" '[[ -e "$HARNESS_USER_SKILLS/$s/SKILL.md" ]]'; done
  names="$(grep -ohE '\{\{skill:[A-Za-z0-9_.-]+\}\}' "$E"/prompts/*.md | sed -E 's/^\{\{skill:(.*)\}\}$/\1/' | sort -u | grep -vx rtdd)"
  say "prompt-named skills: $(echo $names)"
  for s in $names; do ok "{{skill:$s}} is where the CLI loads skills from" '[[ -e "$HARNESS_USER_SKILLS/$s/SKILL.md" ]]'; done
  for p in ralph-loop; do ok "claude plugin $p is registered in the sandbox config" 'grep -q "\"$p@" "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json" 2>/dev/null'; done
  ok "the sandbox has no CRLF-converted skill (autocrlf off)" '! grep -rlI $'"'"'\r'"'"' "$HARNESS_USER_SKILLS/to-prd/" 2>/dev/null | grep -q .'
fi

if has lane; then
  say "######## stage lane: a lane-shaped shell in a worktree path with a space, a short TMPDIR"
  [[ -e "$E/bin/harness" ]] || HARNESS_REF="$CUR" bash src/install.sh </dev/null >/dev/null 2>&1
  PRJ="$(cygpath -u "$HX_DIR")/my project"; WT="$PRJ/.harness/worktrees/main i495"; LT="$(cygpath -u "$HX_DIR")/t"
  rm -rf "$PRJ"; mkdir -p "$PRJ" "$LT"
  git -C "$PRJ" init -q -b main && git -C "$PRJ" -c user.name=hx -c user.email=hx@example.invalid commit -q --allow-empty -m init
  git -C "$PRJ" worktree add -q -b issue/495 "$WT"
  printf 'one\ntwo\n' > "$WT/notes.txt"; printf 'echo hi\n' > "$WT/a.sh"
  say "worktree: $WT | TMPDIR: $LT (${#LT} chars)"
  # the lane's env: bin/harness puts the python3 shim's dir first on PATH; the host tools after
  out="$(cd "$WT" && PATH="$(cygpath -u "$HARNESS_HOME")/bin:$HOST_PATH" TMPDIR="$LT" RTDD_EVENT_LOG="$HX_DIR/rtdd-events.jsonl" bash -c '
    echo "pwd=$PWD"
    echo "git=$(git rev-parse --abbrev-ref HEAD)"
    echo "gh=$(gh --version 2>&1 | head -1)"
    echo "rtdd=$(rtdd.exe --version 2>&1 | head -1)"
    rtdd.exe which --base main >rtdd.which 2>&1; echo "rtdd_which_rc=$?"
    echo "py=$(python3 -c "import sys; print(sys.version_info[0])" 2>&1)"
    echo "grep=$(grep -c two notes.txt)"
    echo "sed=$(sed -n 2p notes.txt)"
    f="$(mktemp)"; echo "tmp=$f"; [[ $f == "$TMPDIR"/* ]] && echo tmpdir_ok' 2>&1)"
  echo "$out" | sed 's/^/   | /'
  ok "cwd is the worktree" 'grep -qxF "pwd=$WT" <<<"$out" || grep -q "^pwd=.*main i495$" <<<"$out"'
  ok "git: issue/495" 'grep -qx "git=issue/495" <<<"$out"'
  ok "gh runs" 'grep -q "^gh=gh version" <<<"$out"'
  ok "rtdd.exe runs" 'grep -q "^rtdd=rtdd " <<<"$out"'
  ok "rtdd which exits 0 in the worktree" 'grep -qx "rtdd_which_rc=0" <<<"$out"'
  ok "python3 (the shim) is a Python 3" 'grep -qx "py=3" <<<"$out"'
  ok "grep" 'grep -qx "grep=1" <<<"$out"'
  ok "sed" 'grep -qx "sed=two" <<<"$out"'
  ok "mktemp lands in the short TMPDIR" 'grep -qx tmpdir_ok <<<"$out"'
  git -C "$PRJ" worktree remove --force "$WT" 2>/dev/null
fi
say "result: $([[ $fail == 0 ]] && echo PASS || echo FAIL)"; exit $fail
