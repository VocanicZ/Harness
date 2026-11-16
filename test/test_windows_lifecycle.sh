#!/usr/bin/env bash
# harness-test-timeout-windows: 1800
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
mkdir -p "$T/bin" "$T/wmi-cwd"
cat >"$T/bin/powershell" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/powershell.calls"
cmd="\$*"; cl="\${cmd#*CommandLine=\\'}"; cl="\${cl%%\\'\}*}"; cl="\${cl//\\'\\'/\\'}"
eval "set -- \$cl"
cd "$T/wmi-cwd"   # WMI starts a process in C:\\Windows\\system32, not the caller's directory
# setsid is not shipped with Git for Windows (#608): there the process is a child of this fake anyway, started with no controlling shell
env -i PATH="$(sys_path)" HOME="\$HOME" \${SYSTEMROOT:+SYSTEMROOT="\$SYSTEMROOT"} \$(command -v setsid) "\$@" </dev/null >/dev/null 2>&1 &
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
assert_ok "[windows] … running Git's bash on the launcher script" grep -q "CommandLine='\"bash\" \"$(native_path "$W/b.pid.launch.sh")\"'" "$T/powershell.calls"
assert_ok "[windows] the pid file names the live launched process" kill -0 "$(cat "$W/b.pid")"
assert_ok "[windows] output reaches the log"                  wait_for "grep -q pid: '$W/b.log'"
assert_eq "$(sed -n 's/^pid:\([0-9]*\).*/\1/p' "$W/b.log")" "$(cat "$W/b.pid")" "[windows] the recorded pid is the command's own (\$\$ survives exec)"
assert_ok "[windows] -a appends to the log"                   grep -qx old "$W/b.log"
assert_ok "[windows] the caller's environment is restored (WMI gives a default one)" grep -q "marker:a b'c " "$W/b.log"
assert_ok "[windows] … and its working directory"             grep -q "cwd:$W/cwd$" "$W/b.log"
assert_ok "[windows] the saved environment is deleted once the launcher has restored it (no token left on disk, #510)" wait_for "test ! -e '$W/b.pid.env'"
printf '#!/bin/sh\nstat -c %%a "%s/d.pid.env" > "%s/d.mode"\nexit 1\n' "$W" "$W" >"$W/ps-mode"; chmod +x "$W/ps-mode"
( export HARNESS_PLATFORM=windows HARNESS_DETACH_WAIT=1 HARNESS_POWERSHELL="$W/ps-mode"
  detach_launch "$W/d.pid" "$W/d.log" true ) 2>/dev/null
# Mode 600 is a POSIX file mode: Git for Windows keeps none (stat says 644 whatever the umask), so there the assertion is made only
# where this filesystem can hold the mode at all (#608). The env file's lifetime — deleted once restored, never left behind — is
# asserted either way, and is what keeps a token off the disk there.
printf x > "$W/mode.probe"; chmod 600 "$W/mode.probe"
if [[ "$(stat -c %a "$W/mode.probe")" == 600 ]]; then
  assert_eq "$(cat "$W/d.mode" 2>/dev/null)" 600 "[windows] while it waits to be restored, the saved environment is private (mode 600)"
else echo "  note: this filesystem keeps no POSIX file modes; the 600 of the saved environment is not checked here"; fi
assert_no "[windows] a failed launch leaves no saved environment behind" test -e "$W/d.pid.env"
# A relative pidfile/log (the winsma failure): WMI starts the launcher in another directory, so every
# path the launch hands it — and every path the launcher reads or writes — must be absolute.
mkdir -p "$W/run"
( export HARNESS_PLATFORM=windows; cd "$W"
  detach_launch run/r.pid run/r.log bash -c 'echo "rel:$$"; exec sleep 30' ) 2>"$W/r.err"; rc=$?
LAUNCHED+=("$(cat "$W/run/r.pid" 2>/dev/null)")
assert_eq "$rc" 0 "[windows] a relative pidfile still records the pid (WMI starts in another directory)"
assert_ok "[windows] … the launcher is handed by absolute path" grep -q "CommandLine='\"bash\" \"$(native_path "$W/run/r.pid.launch.sh")\"'" "$T/powershell.calls"
assert_ok "[windows] … and the relative log is the caller's"  wait_for "grep -q rel: '$W/run/r.log'"
assert_ok "[windows] … nothing landed in WMI's directory"     test -z "$(ls -A "$T/wmi-cwd")"
( export HARNESS_PLATFORM=windows HARNESS_DETACH_WAIT=1 HARNESS_POWERSHELL=false
  detach_launch "$W/c.pid" "$W/c.log" true ) 2>"$W/c.err"; rc=$?
assert_no "[windows] a failed Win32_Process.Create is a failure" test "$rc" = 0
assert_ok "[windows] … and says so"                           grep -q "Win32_Process.Create failed" "$W/c.err"
printf '#!/usr/bin/env bash\necho "CimException: access denied" >&2; exit 3\n' >"$W/ps-says-why"; chmod +x "$W/ps-says-why"
( export HARNESS_PLATFORM=windows HARNESS_DETACH_WAIT=1 HARNESS_POWERSHELL="$W/ps-says-why"
  detach_launch "$W/e.pid" "$W/e.log" true ) 2>"$W/e.err"
assert_ok "[windows] … with powershell's exit status and its own words (#496)" grep -q "powershell exit 3: CimException: access denied" "$W/e.err"
assert_no "[windows] … and no output file left beside the pidfile"       test -e "$W/e.pid.ps.out"

echo "=== pool.sh / priority.sh / the poller launch through detach_launch ==="
FE="$T/engine"; mkdir -p "$FE/scripts"
printf '#!/usr/bin/env bash\necho "worker $1 MARK=$HARNESS_TEST_MARKER"; exec sleep 600\n' >"$FE/scripts/pool-worker.sh"
printf '#!/usr/bin/env bash\necho "priority $1"; exec sleep 600\n' >"$FE/scripts/priority-worker.sh"
printf '#!/usr/bin/env bash\necho poller; exec sleep 600\n' >"$FE/scripts/poller.sh"
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

echo "=== start refuses a python3 that runs no Python 3 on Windows (#405) ==="
mkdir -p "$T/storepy" "$T/startbin"
printf '#!/bin/sh\necho "Python was not found; run without arguments to install from the Microsoft Store" >&2\nexit 9009\n' >"$T/storepy/python3"
chmod +x "$T/storepy/python3"
# gh / claude stubs that record any call: start must stop before it reaches either. ENGINE_DIR is the
# fake engine (no pool.sh) and the poller is off, so even a start that wrongly carries on launches nothing.
for b in gh claude; do printf '#!/bin/sh\necho "%s $*" >> "%s/start.calls"\nexit 1\n' "$b" "$T" >"$T/startbin/$b"; done
chmod +x "$T/startbin/"*
: >"$T/start.calls"; rm -f "$STATE_DIR"/run/*.pid   # the pool.sh section's (killed) workers
assert_no "win_python3_check: the Store stub is refused on Windows" \
  env HARNESS_PLATFORM=windows PATH="$T/storepy:$PATH" bash -c "source '$R/scripts/portable.sh'; win_python3_check 2>/dev/null"
assert_ok "win_python3_check: a working python3 passes on Windows" \
  env HARNESS_PLATFORM=windows bash -c "source '$R/scripts/portable.sh'; win_python3_check"
assert_ok "win_python3_check: never refuses off Windows" \
  env HARNESS_PLATFORM=posix PATH="$T/storepy:$PATH" bash -c "source '$R/scripts/portable.sh'; win_python3_check"
out="$(HARNESS_PLATFORM=windows HARNESS_SESSION_BACKEND=headless PATH="$T/storepy:$T/startbin:$PATH" ENGINE_DIR="$FE" HARNESS_USE_POLLER=0 HARNESS_PREFIX_COLLISION=warn bash "$R/scripts/start.sh" 2>&1)"; rc=$?
assert_no "start.sh exits non-zero on Windows when python3 is the Store stub" test "$rc" = 0
assert_ok "… naming the fix"                                  grep -q "install Python 3.*HARNESS_PYTHON" <<<"$out"
assert_eq "$(cat "$T/start.calls")" "" "… before calling gh or the CLI (no worker launched)"
assert_no "… and no worker pidfile"                           test -e "$STATE_DIR/run/worker-1.pid"
# Past the python3 preflight start carries on as before to its next check: a tmux-only CLI on the
# headless backend stops it there, deterministically and before anything launches. (A made-up CLI with no headless
# adapter: every real one has one.)
TO="$T/tmux-only"; tmux_only_tree "$TO"
out="$(HARNESS_PLATFORM=windows HARNESS_SESSION_BACKEND=headless HARNESS_CLI=fakecli PATH="$T/startbin:$PATH" ENGINE_DIR="$FE" HARNESS_USE_POLLER=0 bash "$TO/scripts/start.sh" 2>&1)"
assert_ok "start.sh with a working python3 on Windows passes the python3 preflight" grep -q "is tmux-only" <<<"$out"
assert_no "… without the python3 refusal"                     grep -q "install Python 3" <<<"$out"
out="$(HARNESS_PLATFORM=posix HARNESS_SESSION_BACKEND=headless HARNESS_CLI=fakecli PATH="$T/storepy:$T/startbin:$PATH" ENGINE_DIR="$FE" HARNESS_USE_POLLER=0 bash "$TO/scripts/start.sh" 2>&1)"
assert_ok "start.sh off Windows skips the python3 preflight (POSIX unchanged)" grep -q "is tmux-only" <<<"$out"
assert_no "… even with the Store stub first on PATH"          grep -q "install Python 3" <<<"$out"
assert_eq "$(cat "$T/start.calls")" "" "no gh / CLI call on any refused start"

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
SUP_TN="$(win_task_name harness-supervise)"; WEB_TN="$(win_task_name harness-web)"
assert_ok "this (non-default) home's task name carries a hash of the home" grep -qE '^Harness\\harness-supervise-[0-9a-f]{8}$' <<<"$SUP_TN"
assert_ok "registered under that name from an XML definition" grep -qxF "/Create /F /TN $SUP_TN /XML $(native_path "$U/harness-supervise.xml")" "$T/schtasks.calls"
assert_eq "$(cat "$T/last-task.bom")" fffe "the definition is UTF-16LE with its byte-order mark (what schtasks reads)"
assert_ok "the task starts at logon"                          grep -q '<LogonTrigger>' "$T/last-task.xml"
assert_no "… and never at boot"                               grep -q 'BootTrigger' "$T/last-task.xml"
assert_ok "… in the user's interactive session"               grep -q "<LogonType>InteractiveToken</LogonType>" "$T/last-task.xml"
assert_ok "… with no run-time limit (the default kills it after 72h)" grep -q "<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>" "$T/last-task.xml"
assert_ok "… running Git's bash on the launcher"              grep -q "<Command>bash</Command><Arguments>\"$(native_path "$L")\"</Arguments>" "$T/last-task.xml"
assert_ok "the task is (re)started"                           bash -c "grep -qxF '/End /TN $SUP_TN' '$T/schtasks.calls' && grep -qxF '/Run /TN $SUP_TN' '$T/schtasks.calls'"
assert_ok "no systemctl / loginctl"                           no_systemd
assert_ok "installed from this engine"                        sup_installed
other_engine(){ local SUP_HARNESS=/other/bin/harness; sup_installed; }
assert_no "another engine's checkout does not own the task"   other_engine
before="$(cat "$L")"; sup_install >/dev/null 2>&1
assert_eq "$(cat "$L")" "$before" "re-install is idempotent"
out="$(SCHTASKS_NO_BOOT=1 sup_install 2>&1)"
assert_no "registration never asks for a boot trigger (an admin-less schtasks that refuses one changes nothing)" grep -q "WARNING" <<<"$out"
assert_ok "… the task is registered and logon-only"           bash -c "! grep -q BootTrigger '$T/last-task.xml' && grep -q '<LogonTrigger>' '$T/last-task.xml'"
sup_uninstall >/dev/null
assert_no "--uninstall removes the launcher"                  test -f "$L"
assert_ok "--uninstall deletes the task"                      grep -qxF "/Delete /F /TN $SUP_TN" "$T/schtasks.calls"
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
assert_ok "registered as the per-home web task"               grep -qF "/Create /F /TN $WEB_TN /XML " "$T/schtasks.calls"
kept="$( export HARNESS_WEB_UNIT_DIR="$WU" HARNESS_WEB_HARNESS=/eng/bin/harness HARNESS_WEB_BIND= HARNESS_WEB_PORT=
  source "$R/scripts/web.sh"; web_install >/dev/null 2>&1; web_installed && echo installed )"
assert_eq "$kept" installed "a redeploy with no env is still this engine's"
assert_ok "… and keeps the LAN bind"                          grep -qx "export HARNESS_WEB_BIND=0.0.0.0" "$WL"
assert_ok "… and the port"                                    grep -qx "export HARNESS_WEB_PORT=4700" "$WL"
( export HARNESS_WEB_UNIT_DIR="$WU" HARNESS_WEB_HARNESS=/eng/bin/harness; source "$R/scripts/web.sh"; web_uninstall >/dev/null )
assert_no "--uninstall removes it"                            test -f "$WL"
assert_ok "--uninstall deletes the task"                      grep -qxF "/Delete /F /TN $WEB_TN" "$T/schtasks.calls"
assert_ok "no systemctl / loginctl"                           no_systemd

echo "=== task names: unique per HARNESS_HOME, default home unchanged (#489) ==="
tn(){ ( HARNESS_HOME="$1" win_task_name "$2" ); }
DEF="$(HOME=/h/u HARNESS_HOME=/h/u/.harness win_task_name harness-supervise)"
assert_eq "$DEF" 'Harness\harness-supervise' "the default ~/.harness keeps Harness\\harness-supervise"
assert_eq "$(HOME=/h/u HARNESS_HOME=/h/u/.harness/ win_task_name harness-web)" 'Harness\harness-web' "… and Harness\\harness-web, trailing slash or not"
assert_eq "$(unset HARNESS_HOME; HOME=/h/u win_task_name harness-web)" 'Harness\harness-web' "… and with HARNESS_HOME unset"
# #1112: HOME is /c/Users/me (MSYS) but export_native_paths hands HARNESS_HOME over as C:/Users/me/.harness: one directory,
# several spellings, and the default home must keep Harness\harness-supervise in all of them (a hashed name made uninstall
# delete a task that was never registered). A cygpath fake maps C:/ C:\ c:/ to /c/ like the real -u does.
mkdir -p "$T/cyg"
cat >"$T/cyg/cygpath" <<'CYG'
#!/usr/bin/env bash
[[ $1 == -u ]] || exit 2
p="${2//\\//}"; [[ $p =~ ^([A-Za-z]):/(.*)$ ]] && p="/${BASH_REMATCH[1],,}/${BASH_REMATCH[2]}"; echo "$p"
CYG
chmod +x "$T/cyg/cygpath"
wtn(){ ( export PATH="$T/cyg:$PATH" HARNESS_PLATFORM=windows HOME=/c/Users/me; HARNESS_HOME="$1" win_task_name "$2" ); }
for sp in /c/Users/me/.harness C:/Users/me/.harness 'C:\Users\me\.harness' c:/Users/me/.harness /c/Users/me/.harness/ 'C:/Users/me/.harness//' 'C:\Users\me\.harness\'; do
  assert_eq "$(wtn "$sp" harness-supervise)" 'Harness\harness-supervise' "default home spelled $sp -> Harness\\harness-supervise"
  assert_eq "$(wtn "$sp" harness-web)" 'Harness\harness-web' "default home spelled $sp -> Harness\\harness-web"
done
assert_eq "$( (export PATH="$T/cyg:$PATH" HARNESS_PLATFORM=windows HOME=/c/Users/me; unset HARNESS_HOME; win_task_name harness-web) )" 'Harness\harness-web' "HARNESS_HOME unset, windows HOME -> default name"
NDH="$(wtn /d/work/home harness-supervise)"
assert_ok "a non-default home is hashed" grep -qE '^Harness\\harness-supervise-[0-9a-f]{8}$' <<<"$NDH"
for sp in D:/work/home 'D:\work\home' d:/work/home /d/work/home/ 'D:/work/home//'; do
  assert_eq "$(wtn "$sp" harness-supervise)" "$NDH" "non-default home spelled $sp -> the same hash"
done
A="$(tn /c/hx-1/home harness-supervise)"; A2="$(tn /c/hx-1/home harness-supervise)"; B="$(tn /c/hx-2/home harness-supervise)"
assert_ok "another home appends a short hash of its path"      grep -qE '^Harness\\harness-supervise-[0-9a-f]{8}$' <<<"$A"
assert_eq "$A2" "$A" "the hashed name is stable for one home"
assert_ok "two homes get distinct names"                       test "$A" != "$B"
assert_ok "… and the supervise and web names differ within a home" test "$A" != "$(tn /c/hx-1/home harness-web)"
assert_ok "… and never collide with the default's"            test "$A" != "$(tn /h/u/.harness harness-supervise)"

echo "=== two homes side by side: uninstalling one leaves the other's tasks alone ==="
H1="$T/homeA"; H2="$T/homeB"; : >"$T/schtasks.calls"
for h in "$H1" "$H2"; do ( export HARNESS_HOME="$h" HARNESS_WEB_UNIT_DIR="$h/tasks" HARNESS_WEB_HARNESS=/eng/bin/harness HARNESS_WEB_BIND= HARNESS_WEB_PORT=
  source "$R/scripts/web.sh"; web_install >/dev/null 2>&1
  SUP_UNIT_DIR="$h/tasks" SUP_HARNESS=/eng/bin/harness sup_install >/dev/null 2>&1 ); done
N1S="$(tn "$H1" harness-supervise)"; N1W="$(tn "$H1" harness-web)"; N2S="$(tn "$H2" harness-supervise)"; N2W="$(tn "$H2" harness-web)"
for n in "$N1S" "$N1W" "$N2S" "$N2W"; do assert_ok "registered: $n" grep -qF "/Create /F /TN $n /XML " "$T/schtasks.calls"; done
assert_eq "$(printf '%s\n' "$N1S" "$N1W" "$N2S" "$N2W" | sort -u | wc -l | tr -d ' ')" 4 "four distinct task names for two homes"
assert_ok "each home's launcher is its own"                    bash -c "test -f '$H1/tasks/harness-supervise.sh' && test -f '$H2/tasks/harness-supervise.sh'"
: >"$T/schtasks.calls"
( export HARNESS_HOME="$H1" HARNESS_WEB_UNIT_DIR="$H1/tasks" HARNESS_WEB_HARNESS=/eng/bin/harness
  source "$R/scripts/web.sh"; web_uninstall >/dev/null
  SUP_UNIT_DIR="$H1/tasks" sup_uninstall >/dev/null )
assert_ok "uninstalling home A deletes A's supervise task"     grep -qxF "/Delete /F /TN $N1S" "$T/schtasks.calls"
assert_ok "… and A's web task"                                 grep -qxF "/Delete /F /TN $N1W" "$T/schtasks.calls"
assert_no "… and touches nothing of home B's"                  grep -qF -e "$N2S" -e "$N2W" "$T/schtasks.calls"
assert_ok "home B's launchers are still there"                 bash -c "test -f '$H2/tasks/harness-supervise.sh' && test -f '$H2/tasks/harness-web.sh'"
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
printf '#!/bin/sh\necho "utf8=${PYTHONUTF8:-unset}"\n' >"$IH/envpy"; chmod +x "$IH/envpy"
assert_eq "$(env -u PYTHONUTF8 PATH="$IH/home/bin:$IH/py:/usr/bin:/bin" HARNESS_PYTHON="$IH/envpy" python3)" "utf8=1" \
  "the shim runs Python in UTF-8 mode (PYTHONUTF8=1): stdio and open() are not cp1252 (#406)"
assert_eq "$(env -u PYTHONUTF8 PATH="$IH/home/bin:$IH:/usr/bin:/bin" HARNESS_PYTHON=envpy python3)" "utf8=1" "… a HARNESS_PYTHON found on PATH too"
# A PATH with the usual tools but no Python on it (the CI host's own python3 would answer otherwise).
NB="$T/nopy"; mkdir -p "$NB"
for b in bash sh env dirname basename sed cat grep tr awk head mkdir chmod ls readlink realpath uname id cut sort; do
  link_tool "$b" "$NB"
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
# Read through gitattr_eol (#404), not `git -C "$R" check-attr`: the release gate runs this suite on a
# `git archive` extract, which is no git repository.
assert_eq "$(gitattr_eol "$R" bin/harness)" lf "bin/harness is checked out LF"
assert_eq "$(gitattr_eol "$R" scripts/lib.sh)" lf "scripts/*.sh are checked out LF"
assert_eq "$(gitattr_eol "$R" scripts/stats.py)" lf "scripts/*.py are checked out LF"

echo "=== gitattr_eol reads a tree that is not a git repository (#404) ==="
GA="$(mktemp -d)"; tmp_track "$GA"; mkdir -p "$GA/tree"
ga_out(){ GIT_CEILING_DIRECTORIES="$GA" gitattr_eol "$GA/tree" "$@" 2>&1; }
cp "$R/.gitattributes" "$GA/tree/"
assert_eq "$(ga_out bin/harness scripts/lib.sh scripts/stats.py test/smoke/fleet_smoke.cmd | xargs)" "lf lf lf crlf" \
  "a copy of the tree's .gitattributes outside any repo: LF engine, CRLF .cmd"
assert_no "...with no 'not a git repository'" grep -q 'not a git repository' <<<"$(ga_out bin/harness)"
# Each check still fails when its attribute regresses: nothing is skipped outside a repo.
grep -v 'eol=crlf' "$R/.gitattributes" > "$GA/tree/.gitattributes"
assert_no "a .gitattributes without the *.cmd line no longer checks .cmd out CRLF" \
  test "$(ga_out test/smoke/fleet_smoke.cmd)" = crlf
sed 's/^\* text=auto eol=lf$/* text=auto/' "$R/.gitattributes" > "$GA/tree/.gitattributes"
assert_no "a .gitattributes without eol=lf no longer checks scripts out LF" test "$(ga_out scripts/lib.sh)" = lf
rm -f "$GA/tree/.gitattributes"
assert_no "a tree with no .gitattributes is a failure, not a pass" gitattr_eol "$GA/tree" bin/harness
finish
