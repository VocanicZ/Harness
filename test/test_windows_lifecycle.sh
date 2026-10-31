#!/usr/bin/env bash
# test_windows_lifecycle.sh — #356 (ADR 0001 §5, §6): the fleet's lifecycle without systemd on native
# Windows, forced on Linux with HARNESS_PLATFORM=windows. Windows' own tools are fakes that log argv:
#   powershell — runs the Win32_Process.Create command line it is handed, detached, in an EMPTY
#                environment (WMI gives the process the user's default one, not the caller's);
#   schtasks   — records each call and keeps the task definition it is given;
#   systemctl / loginctl — must never be called on Windows.
# Covered: detach_launch on both branches (pool.sh, priority.sh and the poller launch through it),
# start's refusal of a tmux backend, supervise/web --install as scheduled tasks (and their uninstall,
# installed-by-this-engine test, and the boot-trigger fallback), `harness doctor`'s Windows checks,
# install.sh's python3 shim / prerequisites / native symlinks / harness.cmd, and .gitattributes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$(cd "$HERE/.." && pwd)"
source "$R/scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
T="$(mktemp -d)"; tmp_track "$T"
LAUNCHED=()
trap 'for p in ${LAUNCHED[@]+"${LAUNCHED[@]}"}; do kill "$p" 2>/dev/null; done; tmp_cleanup' EXIT

# --- the fakes ------------------------------------------------------------------------------------
mkdir -p "$T/bin"
cat >"$T/bin/powershell" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/powershell.calls"
cmd="\$*"; cl="\${cmd#*CommandLine=\\'}"; cl="\${cl%%\\'\}*}"; cl="\${cl//\\'\\'/\\'}"
eval "set -- \$cl"
env -i PATH=/usr/bin:/bin HOME="\$HOME" setsid "\$@" </dev/null >/dev/null 2>&1 &
exit 0
EOF
cat >"$T/bin/schtasks" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/schtasks.calls"
for ((i=1; i<=\$#; i++)); do
  if [[ \${!i} == /XML ]]; then j=\$((i+1)); x="\${!j}"
    iconv -f UTF-16LE -t UTF-8 "\$x" | sed '1s/^\xEF\xBB\xBF//' > "$T/last-task.xml"
    head -c 2 "\$x" | od -An -tx1 | tr -d ' \n' > "$T/last-task.bom"
    [[ -n \${SCHTASKS_NO_BOOT:-} ]] && grep -q BootTrigger "$T/last-task.xml" && { echo "ERROR: Access is denied." >&2; exit 1; }
  fi
done
exit 0
EOF
for b in systemctl loginctl; do printf '#!/bin/sh\necho "$@" >> %s/%s.calls\n' "$T" "$b" >"$T/bin/$b"; done
for b in claude gh rtdd taskkill; do printf '#!/bin/sh\nexit 0\n' >"$T/bin/$b"; done
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" HARNESS_POWERSHELL="$T/bin/powershell" HARNESS_SCHTASKS="$T/bin/schtasks" \
  HARNESS_BASH_EXE=bash HARNESS_DETACH_WAIT=10
export HARNESS_SUPERVISE_SYSTEMCTL="$T/bin/systemctl" HARNESS_SUPERVISE_LOGINCTL="$T/bin/loginctl" \
  HARNESS_WEB_SYSTEMCTL="$T/bin/systemctl" HARNESS_WEB_LOGINCTL="$T/bin/loginctl"
no_systemd(){ [[ ! -s "$T/systemctl.calls" && ! -s "$T/loginctl.calls" ]]; }
wait_for(){ local i; for (( i = 0; i < 100; i++ )); do eval "$1" && return 0; sleep 0.1; done; return 1; }

echo "=== detach_launch: POSIX keeps nohup + \$! ==="
P="$T/posix"; mkdir -p "$P"
( export HARNESS_PLATFORM=posix; exec 9>"$P/held.lock"
  detach_launch "$P/a.pid" "$P/a.log" bash -c 'echo "fd9:$( [[ -e /proc/self/fd/9 ]] && echo open || echo closed )"; sleep 30' )
LAUNCHED+=("$(cat "$P/a.pid")")
assert_ok "[posix] the pid file names a live process"        kill -0 "$(cat "$P/a.pid")"
assert_ok "[posix] its output goes to the log"                wait_for "grep -q fd9: '$P/a.log'"
assert_ok "[posix] fd 9 (start.sh's lock) is closed for it"   grep -q "fd9:closed" "$P/a.log"
assert_ok "[posix] no powershell"                             test ! -e "$T/powershell.calls"

echo "=== detach_launch: Windows launches through Win32_Process.Create ==="
W="$T/win"; mkdir -p "$W/cwd"
echo old > "$W/b.log"
( export HARNESS_PLATFORM=windows HARNESS_TEST_MARKER="a b'c"; cd "$W/cwd"
  detach_launch -a "$W/b.pid" "$W/b.log" bash -c 'echo "pid:$$ marker:$HARNESS_TEST_MARKER cwd:$PWD"; exec sleep 30' ); rc=$?
assert_eq "$rc" 0 "[windows] detach_launch returns 0 once the pid is recorded"
LAUNCHED+=("$(cat "$W/b.pid" 2>/dev/null)")
assert_ok "[windows] the launch goes through Invoke-CimMethod Win32_Process Create" \
  grep -q "Invoke-CimMethod -ClassName Win32_Process -MethodName Create" "$T/powershell.calls"
assert_ok "[windows] … running Git's bash on the launcher script" grep -q "CommandLine='\"bash\" \"$W/b.pid.launch.sh\"'" "$T/powershell.calls"
assert_ok "[windows] the pid file names the live launched process" kill -0 "$(cat "$W/b.pid")"
assert_ok "[windows] output reaches the log"                  wait_for "grep -q pid: '$W/b.log'"
assert_eq "$(sed -n 's/^pid:\([0-9]*\).*/\1/p' "$W/b.log")" "$(cat "$W/b.pid")" "[windows] the recorded pid is the command's own (\$\$ survives exec)"
assert_ok "[windows] -a appends to the log"                   grep -qx old "$W/b.log"
assert_ok "[windows] the caller's environment is restored (WMI gives a default one)" grep -q "marker:a b'c " "$W/b.log"
assert_ok "[windows] … and its working directory"             grep -q "cwd:$W/cwd$" "$W/b.log"
assert_eq "$(stat -c %a "$W/b.pid.env")" 600 "[windows] the saved environment is private (mode 600)"
( export HARNESS_PLATFORM=windows HARNESS_DETACH_WAIT=1 HARNESS_POWERSHELL=false
  detach_launch "$W/c.pid" "$W/c.log" true ) 2>"$W/c.err"; rc=$?
assert_no "[windows] a failed Win32_Process.Create is a failure" test "$rc" = 0
assert_ok "[windows] … and says so"                           grep -q "Win32_Process.Create failed" "$W/c.err"

echo "=== pool.sh / priority.sh / the poller launch through detach_launch ==="
FE="$T/engine"; mkdir -p "$FE/scripts"
printf '#!/usr/bin/env bash\necho "worker $1 MARK=$HARNESS_TEST_MARKER"; exec sleep 30\n' >"$FE/scripts/pool-worker.sh"
printf '#!/usr/bin/env bash\necho "priority $1"; exec sleep 30\n' >"$FE/scripts/priority-worker.sh"
printf '#!/usr/bin/env bash\necho poller; exec sleep 30\n' >"$FE/scripts/poller.sh"
mkdir -p "$STATE_DIR/run"; printf 'HARNESS_POOL=2\n' >"$STATE_DIR/config"
: >"$T/powershell.calls"
out="$(HARNESS_PLATFORM=windows HARNESS_TEST_MARKER=m1 ENGINE_DIR="$FE" bash "$R/scripts/pool.sh" 2>&1)"
for i in 1 2; do LAUNCHED+=("$(cat "$STATE_DIR/run/worker-$i.pid" 2>/dev/null)"); done
assert_eq "$(grep -c Win32_Process "$T/powershell.calls")" 2 "pool.sh: one Win32_Process.Create per worker"
assert_ok "pool.sh: worker-1 is alive under its pid file"     kill -0 "$(cat "$STATE_DIR/run/worker-1.pid")"
assert_ok "pool.sh: reports the recorded pid"                 grep -q "worker-2: started (pid $(cat "$STATE_DIR/run/worker-2.pid"))" <<<"$out"
assert_ok "pool.sh: the worker got the launching environment" wait_for "grep -q 'worker 1 MARK=m1' '$STATE_DIR/run/worker-1.log'"
out="$(HARNESS_PLATFORM=windows ENGINE_DIR="$FE" bash "$R/scripts/pool.sh" 2>&1)"
assert_ok "pool.sh: re-run skips live workers"                grep -q "worker-1: already running" <<<"$out"
out="$(HARNESS_PLATFORM=windows ENGINE_DIR="$FE" bash "$R/scripts/priority.sh" 2>&1)"
LAUNCHED+=("$(cat "$STATE_DIR/run/priority.pid" 2>/dev/null)")
assert_ok "priority.sh: the lane is alive under its pid file" kill -0 "$(cat "$STATE_DIR/run/priority.pid")"
( export HARNESS_PLATFORM=windows ENGINE_DIR="$FE" HARNESS_POLLER_CMD=; ensure_poller )
LAUNCHED+=("$(cat "$POLLER_PID" 2>/dev/null)")
assert_ok "ensure_poller: the poller is alive under its pid file" poller_running
assert_ok "ensure_poller: it appends to poller.log"           wait_for "grep -q poller '$HARNESS_POLLER_DIR/poller.log'"
assert_eq "$(grep -c Win32_Process "$T/powershell.calls")" 4 "every launch (2 workers, priority, poller) went through WMI"
assert_ok "no systemctl / loginctl on the start path"         no_systemd
for p in "$STATE_DIR"/run/*.pid; do kill "$(cat "$p")" 2>/dev/null; done; kill "$(cat "$POLLER_PID")" 2>/dev/null

echo "=== start refuses a non-headless backend on Windows ==="
assert_no "sess_platform_check: tmux is refused on Windows"   env HARNESS_PLATFORM=windows bash -c "source '$R/scripts/session/dispatch.sh'; sess_platform_check tmux 2>/dev/null"
assert_ok "sess_platform_check: headless runs on Windows"     env HARNESS_PLATFORM=windows bash -c "source '$R/scripts/session/dispatch.sh'; sess_platform_check headless"
assert_ok "sess_platform_check: tmux is fine elsewhere"       env HARNESS_PLATFORM=posix bash -c "source '$R/scripts/session/dispatch.sh'; sess_platform_check tmux"
out="$(HARNESS_PLATFORM=windows HARNESS_SESSION_BACKEND=tmux bash "$R/scripts/start.sh" 2>&1)"; rc=$?
assert_no "start.sh exits non-zero with the tmux backend on Windows" test "$rc" = 0
assert_ok "… naming the fix"                                  grep -q "HARNESS_SESSION_BACKEND=headless" <<<"$out"
assert_no "… before launching anything"                       test -e "$STATE_DIR/run/worker-1.pid.new"

echo "=== harness supervise --install: a scheduled task, not a systemd unit ==="
export HARNESS_SUPERVISE_CONF="$T/none.conf" HARNESS_SUPERVISE_STATE="$T/sup" HARNESS_SUPERVISE_LOG="$T/sup.log"
export HARNESS_PLATFORM=windows
source "$R/scripts/supervise.sh"
assert_eq "$SUP_UNIT_DIR" "$HARNESS_HOME/tasks" "the task's launcher lives under \$HARNESS_HOME/tasks on Windows"
U="$T/tasks"; SUP_UNIT_DIR=$U SUP_HARNESS=/eng/bin/harness
: >"$T/schtasks.calls"
out="$(sup_install 2>&1)"
L="$U/harness-supervise.sh"
assert_ok "--install writes the launcher"                     test -f "$L"
assert_ok "it runs this engine's supervise (the ExecStart line)" grep -qx "# ExecStart=/eng/bin/harness supervise" "$L"
assert_ok "… in a restart loop (Restart=always, RestartSec=60)" bash -c "grep -q '^while :; do' '$L' && grep -q '/eng/bin/harness supervise </dev/null' '$L' && grep -qx '  sleep 60' '$L'"
assert_ok "its PATH holds the claude/gh/rtdd dir"             grep -q "^export PATH=$T/bin:" "$L"
assert_ok "its HARNESS_HOME is this host's"                   grep -qx "export HARNESS_HOME=$HARNESS_HOME" "$L"
assert_ok "the launcher is valid bash"                        bash -n "$L"
assert_ok "registered as Harness\\harness-supervise from an XML definition" grep -q '^/Create /F /TN Harness\\harness-supervise /XML ' "$T/schtasks.calls"
assert_eq "$(cat "$T/last-task.bom")" fffe "the definition is UTF-16LE with its byte-order mark (what schtasks reads)"
assert_ok "the task starts at boot and at logon"              bash -c "grep -q '<BootTrigger>' '$T/last-task.xml' && grep -q '<LogonTrigger>' '$T/last-task.xml'"
assert_ok "… S4U: it runs with nobody logged in"              grep -q "<LogonType>S4U</LogonType>" "$T/last-task.xml"
assert_ok "… with no run-time limit (the default kills it after 72h)" grep -q "<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>" "$T/last-task.xml"
assert_ok "… running Git's bash on the launcher"              grep -q "<Command>bash</Command><Arguments>\"$L\"</Arguments>" "$T/last-task.xml"
assert_ok "the task is (re)started"                           bash -c "grep -q '^/End /TN Harness.harness-supervise' '$T/schtasks.calls' && grep -q '^/Run /TN Harness.harness-supervise' '$T/schtasks.calls'"
assert_ok "no systemctl / loginctl"                           no_systemd
assert_ok "installed from this engine"                        sup_installed
other_engine(){ local SUP_HARNESS=/other/bin/harness; sup_installed; }
assert_no "another engine's checkout does not own the task"   other_engine
before="$(cat "$L")"; sup_install >/dev/null 2>&1
assert_eq "$(cat "$L")" "$before" "re-install is idempotent"
out="$(SCHTASKS_NO_BOOT=1 sup_install 2>&1)"
assert_ok "no administrator: says the task runs at the next logon instead" grep -q "runs at your next logon" <<<"$out"
assert_ok "… and registers the logon-only, interactive task"  bash -c "! grep -q BootTrigger '$T/last-task.xml' && grep -q InteractiveToken '$T/last-task.xml'"
sup_uninstall >/dev/null
assert_no "--uninstall removes the launcher"                  test -f "$L"
assert_ok "--uninstall deletes the task"                      grep -q '^/Delete /F /TN Harness\\harness-supervise' "$T/schtasks.calls"
assert_ok "no systemctl / loginctl through uninstall either"  no_systemd
( export HARNESS_PLATFORM=posix; SUP_UNIT_DIR="$T/unit" SUP_SYSTEMCTL="$T/bin/systemctl" SUP_LOGINCTL="$T/bin/loginctl"; sup_install >/dev/null 2>&1 )
assert_ok "Linux keeps the systemd unit"                      grep -qx "ExecStart=/eng/bin/harness supervise" "$T/unit/harness-supervise.service"
assert_ok "… and systemctl"                                   grep -q "enable harness-supervise.service" "$T/systemctl.calls"
rm -f "$T/systemctl.calls" "$T/loginctl.calls"

echo "=== harness web --install: a scheduled task, keeping its bind/port ==="
WU="$T/webtasks"
( export HARNESS_WEB_UNIT_DIR="$WU" HARNESS_WEB_HARNESS=/eng/bin/harness HARNESS_WEB_BIND=0.0.0.0 HARNESS_WEB_PORT=4700
  source "$R/scripts/web.sh"; web_install >/dev/null 2>&1 )
WL="$WU/harness-web.sh"
assert_ok "--install writes the launcher"                     grep -qx "# ExecStart=/eng/bin/harness web" "$WL"
assert_ok "… carrying the bind"                               grep -qx "export HARNESS_WEB_BIND=0.0.0.0" "$WL"
assert_ok "… restarting 5s after an exit"                     grep -qx "  sleep 5" "$WL"
assert_ok "registered as Harness\\harness-web"                grep -q '^/Create /F /TN Harness\\harness-web /XML ' "$T/schtasks.calls"
kept="$( export HARNESS_WEB_UNIT_DIR="$WU" HARNESS_WEB_HARNESS=/eng/bin/harness HARNESS_WEB_BIND= HARNESS_WEB_PORT=
  source "$R/scripts/web.sh"; web_install >/dev/null 2>&1; web_installed && echo installed )"
assert_eq "$kept" installed "a redeploy with no env is still this engine's"
assert_ok "… and keeps the LAN bind"                          grep -qx "export HARNESS_WEB_BIND=0.0.0.0" "$WL"
assert_ok "… and the port"                                    grep -qx "export HARNESS_WEB_PORT=4700" "$WL"
( export HARNESS_WEB_UNIT_DIR="$WU" HARNESS_WEB_HARNESS=/eng/bin/harness; source "$R/scripts/web.sh"; web_uninstall >/dev/null )
assert_no "--uninstall removes it"                            test -f "$WL"
assert_ok "--uninstall deletes the task"                      grep -q '^/Delete /F /TN Harness\\harness-web' "$T/schtasks.calls"
assert_ok "no systemctl / loginctl"                           no_systemd
unset HARNESS_PLATFORM

echo "=== harness doctor on Windows ==="
_DOCTOR_SOURCED=1 source "$R/scripts/doctor.sh"
printf '#!/bin/sh\necho MINGW64_NT-10.0-19045\n' >"$T/bin/uname-mingw"
printf '#!/bin/sh\necho Linux\n' >"$T/bin/uname-wsl"
printf '#!/bin/sh\n[ "$1" = -c ] && echo MINGW64_NT-10.0-19045\n' >"$T/bin/gitbash"
chmod +x "$T/bin/"*
dw(){ ( export HARNESS_PLATFORM=windows HARNESS_UNAME="$T/bin/uname-mingw" HARNESS_BASH_EXE="$T/bin/gitbash" \
          HARNESS_SESSION_BACKEND=headless HARNESS_TASKKILL="$T/bin/taskkill"; "$@"; doctor_windows ); }
out="$(dw true)"; rc=$?
assert_eq "$rc" 0 "a host with every prerequisite passes"
for k in "session backend: headless ✓" "shell: Git Bash" "task bash: $T/bin/gitbash ✓" "python3: 3." "symlinks: can create ✓" "line endings: LF ✓" "schtasks: ✓" "powershell: ✓" "taskkill: ✓"; do
  assert_ok "reports: $k" grep -qF "$k" <<<"$out"
done
out="$(dw export HARNESS_SESSION_BACKEND=tmux)"; rc=$?
assert_eq "$rc" 1 "the tmux backend is a problem on Windows"
assert_ok "… that names the fix"                              grep -q "NOT SUPPORTED on Windows.*HARNESS_SESSION_BACKEND=headless" <<<"$out"
out="$(dw export HARNESS_UNAME="$T/bin/uname-wsl")"; rc=$?
assert_eq "$rc" 1 "WSL's bash is a problem"
assert_ok "… that says to use Git's bash"                     grep -q "not WSL's bash.exe" <<<"$out"
out="$(dw export HARNESS_BASH_EXE="$T/bin/uname-wsl")"; rc=$?
assert_ok "a task bash that is not Git's is a problem"        grep -q "not Git's bash; set HARNESS_BASH_EXE" <<<"$out"
mkdir -p "$T/stub"; printf '#!/bin/sh\necho "Python was not found; run without arguments to install from the Microsoft Store" >&2\nexit 9009\n' >"$T/stub/python3"
chmod +x "$T/stub/python3"
out="$(dw export PATH="$T/stub:$PATH")"; rc=$?
assert_eq "$rc" 1 "the Microsoft Store python3 stub is a problem"
assert_ok "… naming the shim and HARNESS_PYTHON"              grep -q "python3: does not run.*HARNESS_PYTHON" <<<"$out"
printf '#!/bin/sh\nmkdir "$3"\n' >"$T/stub/ln"; chmod +x "$T/stub/ln"
out="$(dw export PATH="$T/stub:$PATH")"
assert_ok "an ln -s that copies (no Developer Mode) is a problem" grep -q "symlinks: cannot create one — enable Developer Mode" <<<"$out"
rm -f "$T/stub/ln"
CE="$T/crlf"; mkdir -p "$CE/bin" "$CE/scripts"; printf 'echo hi\r\n' >"$CE/bin/harness"; : >"$CE/scripts/lib.sh"
out="$(dw export ENGINE_DIR="$CE")"
assert_ok "a CRLF engine is a problem"                        grep -q "line endings: CRLF in the engine" <<<"$out"
out="$(dw export HARNESS_SCHTASKS="$T/none/schtasks")"
assert_ok "a missing schtasks is a problem"                   grep -q "schtasks: MISSING" <<<"$out"
out="$(HARNESS_PLATFORM=windows HARNESS_UNAME="$T/bin/uname-mingw" HARNESS_BASH_EXE="$T/bin/gitbash" HARNESS_SESSION_BACKEND=tmux doctor_main 2>&1)"; rc=$?
assert_eq "$rc" 1 "doctor_main fails on Windows with the tmux backend"
assert_ok "… in its windows: section"                         grep -q "^windows:" <<<"$out"
out="$(HARNESS_PLATFORM=posix doctor_main 2>&1)"
assert_no "Linux doctor has no windows: section"              grep -q "^windows:" <<<"$out"

echo "=== install.sh on Windows: python3 shim, prerequisites, native symlinks, harness.cmd ==="
IH="$T/ih"; mkdir -p "$IH/py"
printf '#!/bin/sh\necho "Python was not found; run without arguments to install from the Microsoft Store" >&2\nexit 9009\n' >"$IH/py/python3"
printf '#!/bin/sh\n[ "$1" = -c ] && case "$2" in *version_info*) echo 3; exit 0;; esac\necho "realpy $*"\n' >"$IH/py/python"
chmod +x "$IH/py/"*
inst(){ ( export HARNESS_PLATFORM=windows HARNESS_INSTALL_NOMAIN=1 HARNESS_HOME="$IH/home" HARNESS_BIN_DIR="$IH/bin" PATH="$IH/py:/usr/bin:/bin"
          unset HARNESS_PYTHON MSYS; source "$R/install.sh"; "$@" ); }
assert_eq "$(inst python_probe)" "$IH/py/python" "python_probe skips the Microsoft Store stub and takes python"
assert_eq "$(inst bash -c 'echo "$MSYS"')" "winsymlinks:nativestrict" "install.sh makes every ln -s a native symlink (MSYS=winsymlinks:nativestrict)"
assert_eq "$(HARNESS_PLATFORM=posix HARNESS_INSTALL_NOMAIN=1 MSYS= bash -c "source '$R/install.sh'; echo \"\$MSYS\"")" "" "… only on Windows"
inst install_python_shim >/dev/null
S="$IH/home/bin/python3"
assert_ok "install writes \$HARNESS_HOME/bin/python3"        test -x "$S"
assert_eq "$(PATH="$IH/home/bin:$IH/py:/usr/bin:/bin" python3 a b)" "realpy a b" "python3 through the shim runs the probed interpreter"
assert_eq "$(PATH="$IH/home/bin:$IH/py:/usr/bin:/bin" HARNESS_PYTHON=python python3 x)" "realpy x" "HARNESS_PYTHON wins at run time"
# A PATH with the usual tools but no Python on it (the CI host's own python3 would answer otherwise).
NB="$T/nopy"; mkdir -p "$NB"
for b in bash sh env dirname basename sed cat grep tr awk head mkdir chmod ls readlink realpath uname id cut sort; do
  p="$(command -v "$b")" && ln -sf "$p" "$NB/$b"
done
out="$(PATH="$IH/home/bin:$NB" HARNESS_PYTHON=python3 "$S" x 2>&1)"; rc=$?
assert_eq "$rc" 127 "a HARNESS_PYTHON that only the shim answers to fails instead of looping"
assert_ok "… saying to set HARNESS_PYTHON"                    grep -q "set HARNESS_PYTHON" <<<"$out"
assert_eq "$(HARNESS_PLATFORM=windows HARNESS_HOME="$IH/home" PATH="$IH/py:$NB" bash "$R/bin/harness" stats 2>&1)" "realpy $R/scripts/stats.py report" \
  "bin/harness puts the shim first on PATH on Windows (harness stats reaches the real Python, not the Store stub)"
assert_ok "Linux: bin/harness leaves PATH alone (the Store-stub-free host's own python3)" \
  bash -c "HARNESS_PLATFORM=posix HARNESS_HOME='$IH/home' PATH='$IH/py:$NB' bash '$R/bin/harness' stats 2>&1 | grep -q 'Microsoft Store'"
assert_ok "Windows prerequisites do not include tmux"         bash -c "! grep -qw tmux <<<\"\$(HARNESS_PLATFORM=windows HARNESS_INSTALL_NOMAIN=1 bash -c 'source $R/install.sh; echo \$PREREQ_TOOLS')\""
assert_ok "Linux prerequisites still do"                      bash -c "grep -qw tmux <<<\"\$(HARNESS_PLATFORM=posix HARNESS_INSTALL_NOMAIN=1 bash -c 'source $R/install.sh; echo \$PREREQ_TOOLS')\""
out="$( HARNESS_PLATFORM=windows HARNESS_INSTALL_NOMAIN=1 PATH="$T/stub:$NB" bash -c "source '$R/install.sh'; check_prereqs" 2>&1 )"
assert_ok "check_prereqs on Windows needs a Python that runs"  grep -q "MISSING: a Python 3 that runs" <<<"$out"
mkdir -p "$IH/home/engine/bin"; : >"$IH/home/engine/bin/harness"
out="$(HARNESS_BASH_EXE='C:\Program Files\Git\bin\bash.exe' inst link_path 2>&1)"
assert_ok "link_path writes harness.cmd beside the link"      test -f "$IH/bin/harness.cmd"
assert_eq "$(sed -n 2p "$IH/bin/harness.cmd" | tr -d '\r')" '"C:\Program Files\Git\bin\bash.exe" "%~dp0harness" %*' "harness.cmd runs the link through Git's bash.exe by path"
assert_eq "$(HARNESS_BASH_EXE= inst inst_bash_exe)" 'C:\Program Files\Git\bin\bash.exe' "inst_bash_exe defaults to Git's bin\\bash.exe (no cygpath to ask)"

echo "=== .gitattributes keeps the engine LF ==="
assert_eq "$(git -C "$R" check-attr eol -- bin/harness | sed 's/.*: //')" lf "bin/harness is checked out LF"
assert_eq "$(git -C "$R" check-attr eol -- scripts/lib.sh | sed 's/.*: //')" lf "scripts/*.sh are checked out LF"
assert_eq "$(git -C "$R" check-attr eol -- scripts/stats.py | sed 's/.*: //')" lf "scripts/*.py are checked out LF"
finish
