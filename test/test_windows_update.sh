#!/usr/bin/env bash
# test_windows_update.sh — #491 (PRD #475, Solution 5): install, update and rollback on native Windows, forced on
# Linux with HARNESS_PLATFORM=windows. Windows' own tools are fakes:
#   schtasks  — records each call and keeps the task definition it is given (the tasks are registered, never started);
#   powershell, taskkill, systemctl, loginctl — accepted and ignored (systemctl must never be called);
#   mv        — Windows' rule that a DIRECTORY cannot be renamed while any file in it is open: it refuses to move a
#               directory some process holds a file of (an fd under /proc), exactly what stopped a git-checkout
#               engine's update, whose own update.sh is such a file.
# Covered: the supervise and web tasks re-registered after the engine flip (logon-only, still running the engine
# through its link), prune to the current release plus the previous 2, migrating a git-checkout engine (update.sh runs
# from a copy of itself, so nothing in the checkout is open), rollback and forward again (and the note when the
# target predates Windows support), re-running the installer over an install, and `harness doctor`'s engine checks
# for the installed, rolled-back and broken states.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"; source "$HERE/release_fixture.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cd "$T"
export HOME="$T/home"; mkdir -p "$HOME"
# On a real Windows host the symlinks are the real thing (what install.sh and update.sh export for themselves), the directory
# rule below is Windows' own, and the engine spells its paths C:/x, so the home is handed over in that spelling (native_path).
real_windows_host && export MSYS="${MSYS:+$MSYS }winsymlinks:nativestrict"
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"

# --- the fakes ------------------------------------------------------------------------------------
mkdir -p "$T/bin"
cat >"$T/bin/schtasks" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/schtasks.calls"
for ((i=1; i<=\$#; i++)); do
  if [[ \${!i} == /XML ]]; then j=\$((i+1)); x="\${!j}"
    iconv -f UTF-16LE -t UTF-8 "\$x" | sed '1s/^\xEF\xBB\xBF//' > "$T/last-task.xml"
  fi
  if [[ \${!i} == /TN ]]; then j=\$((i+1)); tn="\${!j}"; fi
done
[[ \$1 == /Create ]] && { grep -qxF -- "\$tn" "$T/tasks.list" 2>/dev/null || echo "\$tn" >> "$T/tasks.list"; cp "$T/last-task.xml" "$T/task-\${tn##*\\\\}.xml"; }
exit 0
EOF
for b in powershell taskkill systemctl loginctl; do printf '#!/bin/sh\necho "%s $*" >> %s/%s.calls\nexit 0\n' "$b" "$T" "$b" >"$T/bin/$b"; done
for b in claude gh rtdd; do printf '#!/bin/sh\nexit 0\n' >"$T/bin/$b"; done
# mv with Windows' directory rule (only `mv -T <dir> <dst>`, the engine moves): refuse while any process has a file open under <dir>.
real_windows_host || cat >"$T/bin/mv" <<'EOF'
#!/bin/bash
args=("$@"); n=${#args[@]}
if [[ ${HARNESS_PLATFORM:-} == windows && ${args[0]} == -T && $n -eq 3 && -d ${args[1]} && ! -L ${args[1]} ]]; then
  src="$(realpath "${args[1]}")"
  for fd in /proc/[0-9]*/fd/*; do
    t="$(readlink "$fd" 2>/dev/null)" || continue
    if [[ $t == "$src"/* ]]; then echo "mv: cannot move '${args[1]}' to '${args[2]}': Permission denied" >&2; exit 1; fi
  done
fi
exec /bin/mv "$@"
EOF
chmod +x "$T/bin/"* 2>/dev/null
export PATH="$T/bin:$PATH" HARNESS_PLATFORM=windows HARNESS_SCHTASKS="$T/bin/schtasks" HARNESS_POWERSHELL="$T/bin/powershell" \
  HARNESS_TASKKILL="$T/bin/taskkill" HARNESS_BASH_EXE=bash HARNESS_PYTHON="$(command -v python3)" HARNESS_SKIP_RTDD=1 \
  HARNESS_SUPERVISE_CONF="$T/none.conf" \
  HARNESS_SUPERVISE_SYSTEMCTL="$T/bin/systemctl" HARNESS_SUPERVISE_LOGINCTL="$T/bin/loginctl" \
  HARNESS_WEB_SYSTEMCTL="$T/bin/systemctl" HARNESS_WEB_LOGINCTL="$T/bin/loginctl"
pin_host_home "$T/host"   # + the fleet/poller/snapshot pins, unit dirs and user bus (#541)
export HARNESS_HOME="$(native_path "$T/host")" HARNESS_BIN_DIR="$(native_path "$T/bin-host")" HARNESS_USER_SKILLS="$(native_path "$T/skills")"
H="$HARNESS_HOME"; SRV="$T/srv"; rel_server "$SRV"
for t in v0.1.0 v0.2.0 v0.3.0 v0.4.0 v0.5.0; do rel_publish "$SRV" "$t"; done; rel_latest "$SRV" v0.2.0
hv(){ env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK -u HARNESS_REF bash "$H/engine/bin/harness" "$@"; }
hr(){ local t="$1"; shift; env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK HARNESS_REF="$t" bash "$H/engine/bin/harness" "$@"; }
rels(){ ls -1 "$H/releases" | grep -v '^\.' | sort | xargs; }
fresh(){ rm -rf "$H" "$HARNESS_BIN_DIR" "$T/tasks.list" "$T"/task-*.xml; : > "$T/schtasks.calls"; }

echo "=== the supervise and web tasks follow the engine across the flip ==="
fresh; rel_install_at "$SRV" v0.1.0
hv supervise --install >/dev/null 2>&1; hv web --install >/dev/null 2>&1
assert_eq "$(wc -l < "$T/tasks.list")" 2 "both tasks are registered before the update"
L="$H/tasks/harness-supervise.sh"; W="$H/tasks/harness-web.sh"
assert_ok "the supervise launcher runs the engine through its link" grep -qxF "# ExecStart=$H/engine/bin/harness supervise" "$L"
: > "$T/schtasks.calls"; rm -f "$T"/task-*.xml
out="$(hv update 2>&1)"; rc=$?
assert_eq "$rc" 0 "update exits 0"
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "engine flipped to v0.2.0"
assert_eq "$(grep -c '^/Create .*harness-supervise' "$T/schtasks.calls")" 1 "the supervise task is re-registered after the flip"
assert_eq "$(grep -c '^/Create .*harness-web' "$T/schtasks.calls")" 1 "the web task is re-registered after the flip"
assert_ok "both launchers still run the engine through its link" bash -c "grep -qxF '# ExecStart=$H/engine/bin/harness supervise' '$L' && grep -q '^# ExecStart=$H/engine/bin/harness web' '$W'"
assert_no "no task has a boot trigger" grep -l BootTrigger "$T"/task-*.xml
assert_ok "they start at logon" grep -q LogonTrigger "$T/task-harness-supervise-"*.xml
assert_no "systemctl was never called" test -s "$T/systemctl.calls"

echo "=== a task an older install pinned to one release's path is re-pointed at the engine link by the next update ==="
fresh; rel_install_at "$SRV" v0.1.0
hv supervise --install >/dev/null 2>&1; hv web --install >/dev/null 2>&1
L="$H/tasks/harness-supervise.sh"; W="$H/tasks/harness-web.sh"
sed -i "s|^# ExecStart=.*/bin/harness supervise|# ExecStart=$H/releases/v0.1.0/bin/harness supervise|" "$L"
sed -i "s|^# ExecStart=.*/bin/harness web|# ExecStart=$H/releases/v0.1.0/bin/harness web|" "$W"
cp "$W" "$T/web.other"; sed -i "s|^# ExecStart=.*/bin/harness web|# ExecStart=$T/elsewhere/releases/v0.1.0/bin/harness web|" "$T/web.other"
assert_ok "(setup) the supervise launcher is pinned to the release" grep -qxF "# ExecStart=$H/releases/v0.1.0/bin/harness supervise" "$L"
hv update >/dev/null 2>&1
assert_ok "the supervise launcher follows the engine link after the update" grep -qxF "# ExecStart=$H/engine/bin/harness supervise" "$L"
assert_ok "… and so does the web launcher" grep -qxF "# ExecStart=$H/engine/bin/harness web" "$W"
cp "$T/web.other" "$W"; hv update --rollback >/dev/null 2>&1; hv update >/dev/null 2>&1
assert_ok "a launcher pinned to ANOTHER home's release is left alone" grep -qxF "# ExecStart=$T/elsewhere/releases/v0.1.0/bin/harness web" "$W"

echo "=== rollback and forward again, on Windows ==="
out="$(hv update --rollback 2>&1)"; rc=$?
assert_eq "$rc" 0 "--rollback exits 0"
assert_eq "$(readlink "$H/engine")" releases/v0.1.0 "--rollback returns engine to v0.1.0 (a real link)"
assert_ok "names from and to" grep -qF 'rolled back Harness v0.2.0 -> v0.1.0' <<<"$out"
assert_ok "v0.2.0 is kept" test -d "$H/releases/v0.2.0"
assert_ok "the tasks still follow the engine after the rollback" grep -qxF "# ExecStart=$H/engine/bin/harness supervise" "$L"
assert_no "a release that has Windows support gets no warning" grep -q 'predates native Windows' <<<"$out"
out="$(hv update --rollback 2>&1)"; rc=$?
assert_eq "$rc" 0 "a second --rollback exits 0"
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "a second --rollback goes forward again"
assert_no "no flip link is left over" compgen -G "$H/engine.flip.*"

echo "=== rolling back onto a release that predates Windows support says how to come forward ==="
# (the old release is faked by renaming the token its update.sh exports: an unknown MSYS option is ignored, so on a real
# Windows host the links stay real nativestrict ones, where `winsymlinks:lnk` would turn them into .lnk shortcuts)
fresh; rel_install_at "$SRV" v0.1.0
sed -i 's/winsymlinks:nativestrict/winsymlinks:old/g' "$H/releases/v0.1.0/update.sh"
hv update >/dev/null 2>&1
out="$(hv update --rollback 2>&1)"; rc=$?
assert_eq "$rc" 0 "the rollback itself works"
assert_ok "it warns that v0.1.0 predates native Windows support" grep -qF 'v0.1.0 predates native Windows support' <<<"$out"
assert_ok "… and names the command that goes forward" grep -qF 'MSYS=winsymlinks:nativestrict harness update --rollback' <<<"$out"
fresh; rel_install_at "$SRV" v0.1.0; sed -i 's/winsymlinks:nativestrict/winsymlinks:old/g' "$H/releases/v0.1.0/update.sh"
out="$(HARNESS_PLATFORM=posix hv update --rollback 2>&1)"
assert_no "Linux never prints it" grep -q 'predates native Windows' <<<"$out"

echo "=== a handoff to an older release names the Python interpreter, so its (older) shim probe cannot loop ==="
fresh; rel_install_at "$SRV" v0.1.0
hv update >/dev/null 2>&1
printf '#!/usr/bin/env bash\n# --post-flip stub\necho "PY=${HARNESS_PYTHON:-unset}" > "%s/handoff.py"\n' "$T" > "$H/releases/v0.1.0/update.sh"
unset HARNESS_PYTHON
hv update --rollback >/dev/null 2>&1
assert_eq "$(cat "$T/handoff.py" 2>/dev/null)" "PY=$(command -v python3)" "rolling back hands the older release HARNESS_PYTHON (what python_probe finds)"
export HARNESS_PYTHON="$(command -v python3)"

echo "=== prune keeps the current release and the previous 2 ==="
fresh; rel_install_at "$SRV" v0.1.0
for t in v0.2.0 v0.3.0 v0.4.0 v0.5.0; do hr "$t" update >/dev/null 2>&1; done
assert_eq "$(rels)" "v0.3.0 v0.4.0 v0.5.0" "five releases installed in turn leave exactly three"
assert_eq "$(readlink "$H/engine")" releases/v0.5.0 "engine is on the newest"
out="$(hv update --rollback 2>&1)"
assert_eq "$(readlink "$H/engine")" releases/v0.4.0 "rolling back one lands on the previous"
assert_eq "$(rels)" "v0.3.0 v0.4.0 v0.5.0" "a rollback prunes nothing"

echo "=== a git-checkout engine is migrated; update.sh must not be an open file of the checkout it moves ==="
fresh; mkdir -p "$H/releases"
cp -a "$FIXTURE_ENGINE_SRC/." "$H/engine.src" 2>/dev/null; rm -rf "$H/engine.src"
mkdir -p "$H/engine"; ( cd "$FIXTURE_ENGINE_SRC" && tar -cf - bin scripts prompts skill plugins install.sh update.sh ) | tar -xf - -C "$H/engine"
( cd "$H/engine" && git init -q . && git -c user.name=t -c user.email=t@t add -A >/dev/null 2>&1 && git -c user.name=t -c user.email=t@t commit -q -m engine >/dev/null 2>&1 )
echo "local edit" > "$H/engine/LOCAL_NOTE"
sha="$(git -C "$H/engine" rev-parse --short=12 HEAD)"
rel_latest "$SRV" v0.2.0
out="$(env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK -u HARNESS_REF bash "$H/engine/bin/harness" update 2>&1)"; rc=$?
assert_eq "$rc" 0 "the update exits 0"
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "engine is now a link to the release"
assert_ok "the checkout was moved aside as a release, uncommitted edit and all" test -f "$H/releases/git-$sha/LOCAL_NOTE"
assert_ok "it counts as a release for --rollback" grep -qx "git-$sha" "$H/releases/.installed"
assert_ok "the update says it migrated" grep -qF "migrated the git-checkout engine to $H/releases/git-$sha" <<<"$out"
assert_no "the copy of update.sh it ran from is gone" compgen -G "$TMPDIR/harness-update.*"
# …and the copy is only for Windows: elsewhere update.sh runs in place (nothing to rename around).
fresh; mkdir -p "$H/engine"; ( cd "$FIXTURE_ENGINE_SRC" && tar -cf - bin scripts prompts skill plugins install.sh update.sh ) | tar -xf - -C "$H/engine"
( cd "$H/engine" && git init -q . && git -c user.name=t -c user.email=t@t add -A >/dev/null 2>&1 && git -c user.name=t -c user.email=t@t commit -q -m engine >/dev/null 2>&1 )
# (a real Windows host cannot run update.sh in place from the checkout it moves: that is the rule the section above is about)
if ! skip_posix_branch "update.sh run in place from the git checkout it migrates"; then
out="$(HARNESS_PLATFORM=posix env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK -u HARNESS_REF bash "$H/engine/bin/harness" update 2>&1)"; rc=$?
assert_eq "$rc" 0 "Linux: the same update exits 0"
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "Linux: engine is a link too"
fi
echo "=== the Windows rule itself, so the test above can fail: a directory with an open file does not move ==="
mkdir -p "$T/d1"; echo x > "$T/d1/f"; exec 7<"$T/d1/f"     # held open by this very shell: no timing to race
assert_no "the fake mv refuses a directory with an open file" env HARNESS_PLATFORM=windows mv -T "$T/d1" "$T/d2"
exec 7<&-
assert_ok "… and moves it once the file is closed" env HARNESS_PLATFORM=windows mv -T "$T/d1" "$T/d2"

echo "=== re-running the installer over an install is idempotent ==="
fresh
inst(){ ( HARNESS_INSTALL_NOMAIN=1 source "$R/install.sh" 2>/dev/null && place_engine && link_path ); }
HARNESS_REF=v0.1.0 inst >/dev/null 2>&1
snap(){ ( cd "$T" && { readlink "$H/engine"; cat "$H/releases/.installed"; ls -A "$H/releases" "$HARNESS_BIN_DIR"; readlink "$HARNESS_BIN_DIR/harness"; } ); }
a="$(snap)"; HARNESS_REF=v0.1.0 inst >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 "the second install exits 0"
assert_eq "$(snap)" "$a" "… and changes nothing: same engine link, same releases, same bin dir, nothing recorded twice"
assert_eq "$(readlink "$H/engine")" releases/v0.1.0 "engine is still the pinned release"
HARNESS_REF=v0.3.0 inst >/dev/null 2>&1
assert_eq "$(readlink "$H/engine")" releases/v0.3.0 "HARNESS_REF=<tag> pins the install to that release on Windows"

echo "=== the python3 shim never points at itself (HARNESS_HOME spelled differently from PATH, as C:/x vs /c/x) ==="
fresh; mkdir -p "$H/bin"
shimrun(){ ( unset HARNESS_PYTHON; export HARNESS_HOME="$T/host/../host" PATH="$H/bin:$PATH"; HARNESS_INSTALL_NOMAIN=1 source "$R/install.sh" 2>/dev/null; install_python_shim ) >/dev/null 2>&1; }
shimrun; shimrun    # the second run is the one that finds the first run's shim on PATH, as `harness update` does
out="$(timeout 10 "$H/bin/python3" -c 'print(6*7)' 2>&1)"; rc=$?
assert_eq "$out" 42 "the shim runs Python (it did not recurse into itself)"
assert_no "… and is not a loop waiting on a timeout" test "$rc" = 124
assert_no "its baked interpreter is not the shim" grep -qF "p=\"\${HARNESS_PYTHON:-$H/bin/python3}\"" "$H/bin/python3"

echo "=== bin/harness takes the engine link when HARNESS_HOME is spelled C:/x and ENGINE_DIR is /c/x ==="
skip_posix_branch "C:-spelled fakes of realpath/cygpath (a real Windows host has the real spellings)" || {
# Windows' realpath keeps the spelling it is given; the fakes do the same (realpath of C:<abs> is C:<resolved>, cygpath -u drops the drive).
fresh; rel_install_at "$SRV" v0.1.0; mkdir -p "$T/winfake"
cat >"$T/winfake/realpath" <<'EOF'
#!/usr/bin/env bash
a=(); for x in "$@"; do [[ $x == -* ]] || a+=("$x"); done; p="${a[0]}"
if [[ $p == C:* ]]; then echo "C:$(/usr/bin/realpath -m "${p#C:}")"; else /usr/bin/realpath -m "$p"; fi
EOF
printf '#!/usr/bin/env bash\n[[ $1 == -u ]] || exit 2\np="$2"; echo "${p#C:}"\n' >"$T/winfake/cygpath"; chmod +x "$T/winfake/"*
sed -n '/^_self=/,/^export HARNESS_ENGINE_LINK/p' "$R/bin/harness" > "$H/engine/bin/linkprobe.sh"; echo 'echo "$HARNESS_ENGINE_LINK"' >> "$H/engine/bin/linkprobe.sh"
out="$(PATH="$T/winfake:$PATH" HARNESS_HOME="C:$H" bash "$H/engine/bin/linkprobe.sh")"
assert_eq "$out" "C:$H/engine" "the stable engine link is taken (not the release path)"
out="$(PATH="$T/winfake:$PATH" HARNESS_HOME="$T/elsewhere" bash "$H/engine/bin/linkprobe.sh")"
assert_eq "$out" "$(realpath "$H/engine")" "another home's link is never taken (the release path stays)"
}

echo "=== a git-checkout engine migrates when bin/harness hands update.sh a C:/ ENGINE_DIR and HOME-derived paths are /c/ ==="
skip_posix_branch "C:-spelled fakes of realpath/cygpath" || {
fresh; mkdir -p "$H/engine" "$T/cwd"; ( cd "$FIXTURE_ENGINE_SRC" && tar -cf - bin scripts prompts skill plugins install.sh update.sh ) | tar -xf - -C "$H/engine"
( cd "$H/engine" && git init -q . && git -c user.name=t -c user.email=t@t add -A >/dev/null 2>&1 && git -c user.name=t -c user.email=t@t commit -q -m engine >/dev/null 2>&1 )
rel_latest "$SRV" v0.2.0
ln -sfn / "$T/cwd/C:"     # "C:/tmp/x" opens as ./C:/tmp/x = /tmp/x, so the C:-spelled paths below exist
out="$(cd "$T/cwd" && env -u STATE_DIR -u HARNESS_REF PATH="$T/winfake:$PATH" ENGINE_DIR="C:$H/engine" HARNESS_ENGINE_LINK="$H/engine" bash "C:$H/engine/update.sh" 2>&1)"; rc=$?
assert_eq "$rc" 0 "the update exits 0"
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "the checkout was recognised as this engine and migrated onto the release"
rm -f "$T/cwd/C:"
}

echo "=== a v0.1.1 git checkout: its own update.sh only pulls (#1116); it says to run harness update again, and that one migrates ==="
# test/fixtures/update-v0.1.1.sh is v0.1.1's update.sh verbatim. On Windows it never recognises its own checkout (realpath spells
# C:/x and /c/x differently), so it takes the `git pull --ff-only` path, sources the install.sh the pull brought, and ends with the
# engine still a git checkout. The fake realpath below spells things the way that host does (verbatim), so ENGINE_DIR=<engine>/.
# is never "the same" engine. The pull is a real one, from a local origin whose second commit is this tree's update.sh.
skip_posix_branch "a fake realpath standing in for Windows' spellings" || {
mkdir -p "$T/vrp"; printf '#!/usr/bin/env bash\na=(); for x in "$@"; do [[ $x == -* ]] || a+=("$x"); done; echo "${a[0]}"\n' > "$T/vrp/realpath"; chmod +x "$T/vrp/realpath"
git_t(){ git -c user.name=t -c user.email=t@t "$@"; }
oldco(){   # a checkout of an origin at "v0.1.1's update.sh", one commit behind this tree's
  rm -rf "$T/orig.v011" "$H/engine"; mkdir -p "$T/orig.v011" "$H"
  ( cd "$FIXTURE_ENGINE_SRC" && tar -cf - bin scripts prompts skill plugins install.sh update.sh ) | tar -xf - -C "$T/orig.v011"
  cp "$FIXTURE_ENGINE_SRC/update.sh" "$T/update.now"; cp "$FIXTURE_ENGINE_SRC/test/fixtures/update-v0.1.1.sh" "$T/orig.v011/update.sh"
  git -C "$T/orig.v011" init -q . && git_t -C "$T/orig.v011" add -A >/dev/null 2>&1 && git_t -C "$T/orig.v011" commit -q -m v0.1.1 >/dev/null 2>&1
  git clone -q "$T/orig.v011" "$H/engine" 2>/dev/null
  cp "$T/update.now" "$T/orig.v011/update.sh"; git_t -C "$T/orig.v011" commit -q -am "the update.sh of this tree" >/dev/null 2>&1; }
oldupd(){ env -u STATE_DIR -u HARNESS_ENGINE_LINK -u HARNESS_REF ${PIN:+HARNESS_REF=$PIN} PATH="$T/vrp:$PATH" ENGINE_DIR="$H/engine/." HARNESS_HOME="$H" bash "$H/engine/update.sh" 2>&1; }
oldco; rel_latest "$SRV" v0.2.0
out="$(oldupd)"; rc=$?
assert_eq "$rc" 0 "v0.1.1's own update exits 0"
assert_ok "(setup) it pulled the new update.sh" grep -q HARNESS_UPDATE_MIGRATES "$H/engine/update.sh"
assert_ok "(setup) … and ran its own, old one to the end" grep -qx 'Update complete.' <<<"$out"
assert_no "the engine is still a git checkout, not a link" test -L "$H/engine"
assert_ok "it says to run harness update once more, and what that does" grep -qF "Run 'harness update' once more" <<<"$out"
assert_ok "… naming the release the engine moves onto" grep -qF 'engine -> releases/v0.2.0' <<<"$out"
assert_eq "$(tail -n 2 <<<"$out" | head -n 1 | cut -c1-5)" NOTE: "… after 'Update complete.', as the last thing it prints"
out="$(env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK -u HARNESS_REF bash "$H/engine/bin/harness" update 2>&1)"; rc=$?
assert_eq "$rc" 0 "the second harness update exits 0"
assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "… and leaves engine -> releases/v0.2.0 (a real link)"
assert_ok "the v0.1.1 checkout is kept as a release" bash -c "compgen -G \"$H/releases/git-*\" >/dev/null"
assert_no "the second update does not tell it to run again" grep -qF "once more" <<<"$out"
oldco; rel_latest "$SRV" ""
out="$(oldupd)"; rc=$?
assert_eq "$rc" 0 "nothing published: v0.1.1's update exits 0"
assert_no "nothing published: there is no release to move onto, so no 'run it again'" grep -qF "once more" <<<"$out"
oldco; rel_latest "$SRV" v0.2.0
out="$(PIN=v0.3.0 oldupd)"
assert_ok "a pinned HARNESS_REF names the pinned release" grep -qF 'engine -> releases/v0.3.0' <<<"$out"
rel_latest "$SRV" v0.2.0
# the current update.sh moves a checkout itself and never says it (its pull path, with nothing published, neither)
oldco; cp "$T/update.now" "$H/engine/update.sh"; git_t -C "$H/engine" commit -q -am now >/dev/null 2>&1
out="$(env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK -u HARNESS_REF bash "$H/engine/bin/harness" update 2>&1)"
assert_no "this tree's update.sh migrates in one go and prints no second-run note" grep -qF "once more" <<<"$out"
oldco; cp "$T/update.now" "$H/engine/update.sh"; git_t -C "$H/engine" commit -q -am now >/dev/null 2>&1; rel_latest "$SRV" ""
out="$(env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK -u HARNESS_REF bash "$H/engine/bin/harness" update 2>&1)"
assert_no "… and with nothing published, neither" grep -qF "once more" <<<"$out"
rel_latest "$SRV" v0.2.0
}

echo "=== harness doctor: the installed, rolled-back and broken engine states ==="
. "$R/scripts/lib.sh"; export HARNESS_PLATFORM=windows
de(){ ( export HARNESS_HOME="$H" HARNESS_BIN_DIR="$HARNESS_BIN_DIR"; source "$R/scripts/doctor.sh"; doctor_engine_windows ) 2>&1; }
fresh; rel_install_at "$SRV" v0.1.0; mkdir -p "$HARNESS_BIN_DIR"; ln -s "$H/engine/bin/harness" "$HARNESS_BIN_DIR/harness"
hv supervise --install >/dev/null 2>&1
out="$(de)"; rc=$?
assert_eq "$rc" 0 "installed: no problem"
assert_ok "installed: names the engine release" grep -qF 'engine: releases/v0.1.0 (v0.1.0) ✓' <<<"$out"
assert_ok "installed: the harness on PATH is a link" grep -qF 'harness on PATH: link to' <<<"$out"
assert_ok "installed: the task follows the engine link" grep -qF 'follows the engine link ✓' <<<"$out"
assert_no "installed: not reported as rolled back" grep -q 'rolled back' <<<"$out"
hv update >/dev/null 2>&1; hv update --rollback >/dev/null 2>&1
out="$(de)"; rc=$?
assert_eq "$rc" 0 "rolled back: no problem"
assert_ok "rolled back: says v0.2.0 is kept and how to go forward" grep -qF 'rolled back: engine is on v0.1.0, v0.2.0 is kept beside it' <<<"$out"
assert_ok "… naming the command" grep -qF 'harness update --rollback' <<<"$out"
ln -sfn releases/v0.9.9 "$H/engine"
out="$(de)"; rc=$?
assert_eq "$rc" 1 "dangling engine link: one problem"
assert_ok "… DANGLING, with the fix" grep -qF 'DANGLING' <<<"$out"
rm -f "$H/engine"; cp -a "$H/releases/v0.1.0" "$H/engine"
out="$(de)"; rc=$?
assert_ok "an engine that is a plain folder (a copy) is a problem" test "$rc" -ge 1
assert_ok "… naming Developer Mode" grep -qF 'enable Developer Mode or run as an administrator' <<<"$out"
rm -rf "$H/engine"; ln -s releases/v0.1.0 "$H/engine"; ln -s releases/v0.2.0 "$H/engine.flip.123"
out="$(de)"; assert_ok "a leftover engine.flip link is named, with rm" grep -qF "engine.flip.123 is left over from an interrupted update" <<<"$out"
rm -f "$H/engine.flip.123"
sed -i "s|^# ExecStart=.*|# ExecStart=$H/releases/v0.1.0/bin/harness supervise|" "$H/tasks/harness-supervise.sh"
out="$(de)"; rc=$?
assert_ok "a launcher pinned to one release is a problem" test "$rc" -ge 1
assert_ok "… naming the re-install" grep -qF 'harness supervise --install' <<<"$out"
out="$(HARNESS_PLATFORM=posix bash -c "export HARNESS_HOME='$H'; source '$R/scripts/doctor.sh'; doctor_engine_windows" 2>&1)"
assert_eq "$out" "" "Linux: silent"
finish
