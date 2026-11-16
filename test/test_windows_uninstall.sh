#!/usr/bin/env bash
# test_windows_uninstall.sh — #490 (PRD #475, Solution 5): `harness uninstall --force --force-engine` on
# native Windows leaves nothing Harness put there, and removes nothing it did not. Forced on Linux with
# HARNESS_PLATFORM=windows; Windows' own tools are fakes:
#   schtasks   — keeps the set of registered task names ($T/tasks.list): /Create adds, /Delete removes,
#                /Query succeeds for a registered one; /Run and /End are accepted and ignored;
#   powershell, taskkill, systemctl, loginctl — accepted and ignored.
# Covered: a recorded install (python3 shim, harness + harness.cmd, supervise and web tasks and their
# launchers, a live poller, fleets/, snapshots/, event logs, skill links) is gone after uninstall while a
# user file in the bin dir and in HARNESS_HOME survives; --force-engine is refused while another fleet
# still uses the engine; doctor names leftovers once the engine is gone.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$(cd "$HERE/.." && pwd)"
source "$R/scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
T="$(mktemp -d)"; tmp_track "$T"
SLEEPERS=()
trap 'for p in ${SLEEPERS[@]+"${SLEEPERS[@]}"}; do kill "$p" 2>/dev/null; done; tmp_cleanup' EXIT

mkdir -p "$T/bin"
cat >"$T/bin/schtasks" <<EOF
#!/usr/bin/env bash
L="$T/tasks.list"; touch "\$L"
op="\$1"; tn=""
for ((i=1; i<=\$#; i++)); do [[ \${!i} == /TN ]] && { j=\$((i+1)); tn="\${!j}"; }; done
case "\$op" in
  /Create) grep -qxF -- "\$tn" "\$L" || echo "\$tn" >> "\$L" ;;
  /Delete) grep -vxF -- "\$tn" "\$L" > "\$L.new"; mv "\$L.new" "\$L" ;;
  /Query)  grep -qxF -- "\$tn" "\$L" || exit 1 ;;
esac
exit 0
EOF
for b in powershell taskkill systemctl loginctl; do printf '#!/bin/sh\nexit 0\n' >"$T/bin/$b"; done
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" HARNESS_SCHTASKS="$T/bin/schtasks" HARNESS_POWERSHELL="$T/bin/powershell" \
  HARNESS_TASKKILL="$T/bin/taskkill" HARNESS_BASH_EXE=bash HARNESS_PLATFORM=windows \
  HARNESS_SUPERVISE_SYSTEMCTL="$T/bin/systemctl" HARNESS_SUPERVISE_LOGINCTL="$T/bin/loginctl" \
  HARNESS_WEB_SYSTEMCTL="$T/bin/systemctl" HARNESS_WEB_LOGINCTL="$T/bin/loginctl"
export HARNESS_PYTHON="$(command -v python3)" HARNESS_SUPERVISE_CONF="$T/none.conf"
tasks(){ sort "$T/tasks.list" 2>/dev/null; }

# mk_install <root> — what an install and a few runs leave on a Windows host, built with the REAL
# installer functions and the real `supervise --install` / `web --install`.
mk_install(){ local root="$1" h="$1/home" b="$1/bin" s="$1/skills"
  mkdir -p "$h/engine/bin" "$b" "$s" "$h/poller/registry" "$h/fleets" "$h/snapshots" "$root/proj/.harness"
  : >"$h/engine/bin/harness"; chmod +x "$h/engine/bin/harness"
  printf 'HARNESS_POOL=1\n' >"$root/proj/.harness/config"
  ( export HARNESS_HOME="$h" HARNESS_BIN_DIR="$b" HARNESS_INSTALL_NOMAIN=1
    source "$R/install.sh"; install_python_shim >/dev/null; link_path >/dev/null )
  ( export HARNESS_HOME="$h" HARNESS_BIN_DIR="$b" ENGINE_DIR="$R"
    bash "$R/bin/harness" supervise --install >/dev/null 2>&1
    bash "$R/bin/harness" web --install >/dev/null 2>&1 )
  : >"$h/poller/poller.log"; echo '{}' >"$h/poller/registry/x.json"; echo '{}' >"$h/fleets/hz.json"
  echo '{}' >"$h/snapshots/a.json"; echo '{}' >"$h/events.jsonl"; echo '{}' >"$h/rtdd-events.jsonl"
  mkdir -p "$h/supervise/rules"; : >"$h/supervise.log"
  ln -sfn "$h/engine/skill/harness" "$s/harness"
  mkdir -p "$s/harness-init"; : >"$s/harness-init/SKILL.md"
  printf '#!/usr/bin/env bash\nexec sleep 60\n' >"$T/poller.sh"; chmod +x "$T/poller.sh"
  bash -c 'exec -a poller.sh sleep 60' & POLLER_SLEEP=$!; SLEEPERS+=("$!"); echo "$POLLER_SLEEP" >"$h/poller/poller.pid"
}
# snapshot <dir…> — every path under them, relative, sorted: the record of what exists.
snapshot(){ local d; for d in "$@"; do [[ -e $d ]] && ( cd "$d" && find . -mindepth 1 | sort ); done; }

echo "=== an install, then uninstall --force --force-engine, leaves none of it ==="
I="$T/i1"; mkdir -p "$I"; mk_install "$I"
printf 'user tool\n' >"$I/bin/mytool.cmd"                       # not Harness's: must survive
printf 'operator notes\n' >"$I/home/notes.txt"                  # not Harness's: must survive
mkdir -p "$I/skills/to-prd"; : >"$I/skills/to-prd/SKILL.md"     # an unrelated skill: must survive
created_tasks="$(tasks)"
assert_eq "$(wc -l <<<"$created_tasks")" 2 "the install registered the supervise and web tasks"
assert_ok "the install wrote the python3 shim"                 test -x "$I/home/bin/python3"
assert_ok "… and its LF-stdio sitecustomize (#609)"            test -f "$I/home/bin/pylf/sitecustomize.py"
assert_ok "… and harness.cmd"                                  test -f "$I/bin/harness.cmd"
assert_ok "… and the task launchers"                           test -n "$(ls "$I"/home/tasks/*.sh 2>/dev/null)"
# Python compiles the sitecustomize on its first run: the __pycache__ it leaves must not keep the home alive (#496, seen on winsma)
mkdir -p "$I/home/bin/pylf/__pycache__"; : >"$I/home/bin/pylf/__pycache__/sitecustomize.cpython-313.pyc"
before="$(snapshot "$I/home" "$I/bin" "$I/skills")"
out="$(HARNESS_HOME="$I/home" HARNESS_BIN_DIR="$I/bin" HARNESS_USER_SKILLS="$I/skills" STATE_DIR="$I/proj/.harness" \
  ENGINE_DIR="$R" HARNESS_UNINSTALL_WORKER_PIDS="" bash "$R/scripts/uninstall.sh" --force --force-engine </dev/null 2>&1)"; rc=$?
assert_eq "$rc" 0 "uninstall exits 0"
assert_eq "$(tasks)" "" "no Harness task is left registered"
assert_no "the engine is gone"                                 test -e "$I/home/engine"
assert_no "harness is gone from the bin dir"                   test -e "$I/bin/harness" -o -L "$I/bin/harness"
assert_no "harness.cmd is gone"                                test -e "$I/bin/harness.cmd"
assert_no "the python3 shim is gone"                           test -e "$I/home/bin/python3"
assert_no "… and the sitecustomize beside it (#609)"           test -e "$I/home/bin/pylf"
assert_no "the task launchers are gone"                        test -e "$I/home/tasks"
assert_no "the poller dir is gone"                             test -e "$I/home/poller"
assert_no "the poller process is gone"                         kill -0 "$POLLER_SLEEP" 2>/dev/null
assert_no "the fleet registry is gone"                         test -e "$I/home/fleets"
assert_no "the snapshots are gone"                             test -e "$I/home/snapshots"
assert_no "the event logs are gone"                            test -e "$I/home/events.jsonl" -o -e "$I/home/rtdd-events.jsonl"
assert_no "the supervisor state and log are gone"              test -e "$I/home/supervise" -o -e "$I/home/supervise.log"
assert_no "the /harness skills are gone"                       test -e "$I/skills/harness" -o -e "$I/skills/harness-init"
assert_no "the project .harness/ is gone"                      test -e "$I/proj/.harness"
assert_eq "$(cat "$I/bin/mytool.cmd" 2>/dev/null)" "user tool" "a user file in the bin dir survives"
assert_eq "$(cat "$I/home/notes.txt" 2>/dev/null)" "operator notes" "a user file in HARNESS_HOME survives"
assert_ok "an unrelated skill survives"                        test -f "$I/skills/to-prd/SKILL.md"
after="$(snapshot "$I/home" "$I/bin" "$I/skills")"
left="$(comm -12 <(sort <<<"$before") <(sort <<<"$after") | grep -vxF -e ./notes.txt -e ./mytool.cmd -e ./to-prd -e ./to-prd/SKILL.md || true)"
assert_eq "$left" "" "every path the install created is gone (only the three user files remain)"
assert_eq "$(ls -A "$I/bin")" "mytool.cmd" "the bin dir holds only the user's file"

echo "=== a clean home is emptied, not just stripped ==="
I2="$T/i2"; mkdir -p "$I2"; mk_install "$I2"
HARNESS_HOME="$I2/home" HARNESS_BIN_DIR="$I2/bin" HARNESS_USER_SKILLS="$I2/skills" STATE_DIR="$I2/proj/.harness" \
  ENGINE_DIR="$R" HARNESS_UNINSTALL_WORKER_PIDS="" bash "$R/scripts/uninstall.sh" --force --force-engine </dev/null >/dev/null 2>&1
assert_no "HARNESS_HOME itself is removed when nothing of the user's is in it" test -e "$I2/home"
assert_eq "$(ls -A "$I2/bin" 2>/dev/null)" "" "HARNESS_BIN_DIR is empty"
assert_eq "$(ls -A "$I2/skills" 2>/dev/null)" "" "HARNESS_USER_SKILLS holds nothing"
assert_eq "$(tasks)" "" "no task left"

echo "=== a second home's tasks are not touched ==="
I3="$T/i3"; I4="$T/i4"; mkdir -p "$I3" "$I4"; mk_install "$I3"; mk_install "$I4"
assert_eq "$(tasks | wc -l)" 4 "two homes registered four distinct tasks"
HARNESS_HOME="$I3/home" HARNESS_BIN_DIR="$I3/bin" HARNESS_USER_SKILLS="$I3/skills" STATE_DIR="$I3/proj/.harness" \
  ENGINE_DIR="$R" HARNESS_UNINSTALL_WORKER_PIDS="" bash "$R/scripts/uninstall.sh" --force --force-engine </dev/null >/dev/null 2>&1
assert_eq "$(tasks | wc -l)" 2 "uninstalling one home leaves the other's two tasks"
assert_ok "the other home's launchers are intact"              test -n "$(ls "$I4"/home/tasks/*.sh 2>/dev/null)"
assert_ok "the other home's shim is intact"                    test -x "$I4/home/bin/python3"

echo "=== --force-engine is refused while another fleet uses the engine ==="
I5="$T/i5"; mkdir -p "$I5"; mk_install "$I5"
before="$(snapshot "$I5/home" "$I5/bin")"; tasks_before="$(tasks)"
out="$(HARNESS_UNINSTALL_NOMAIN=1 HARNESS_HOME="$I5/home" HARNESS_BIN_DIR="$I5/bin" HARNESS_USER_SKILLS="$I5/skills" \
  STATE_DIR="$I5/proj/.harness" ENGINE_DIR="$R" \
  bash -c 'source "$1"; other_fleets_depend_on_engine(){ return 0; }; shift; main "$@"' _ "$R/scripts/uninstall.sh" --force --force-engine </dev/null 2>&1)"; rc=$?
assert_no "exits non-zero"                                     test "$rc" = 0
assert_ok "names the other fleet and the way out"              grep -qi "another fleet.*still uses\|still uses the engine" <<<"$out"
assert_eq "$(snapshot "$I5/home" "$I5/bin")" "$before" "nothing was removed"
assert_eq "$(tasks)" "$tasks_before" "no task was deleted"
assert_ok "the project's .harness/ is still there"             test -f "$I5/proj/.harness/config"
out="$(HARNESS_UNINSTALL_NOMAIN=1 HARNESS_HOME="$I5/home" HARNESS_BIN_DIR="$I5/bin" HARNESS_USER_SKILLS="$I5/skills" \
  STATE_DIR="$I5/proj/.harness" ENGINE_DIR="$R" \
  bash -c 'source "$1"; other_fleets_depend_on_engine(){ return 1; }; shift; main "$@"' _ "$R/scripts/uninstall.sh" --force --force-engine </dev/null 2>&1)"; rc=$?
assert_eq "$rc" 0 "with no other fleet the same command succeeds"
assert_no "… and the engine is gone"                           test -e "$I5/home/engine"

echo "=== the other-fleets check counts only live fleets on this engine, in any path spelling (#1138) ==="
# A fake cygpath: -u turns C:/x and C:\x into /c/x and leaves anything else alone; -m (what export_native_paths asks for) is a
# pass-through. Only these subshells see it.
mkdir -p "$T/cyg"
cat >"$T/cyg/cygpath" <<'FAKECYG'
#!/usr/bin/env bash
p="$2"; [[ "$1" == -m ]] && { printf '%s\n' "$p"; exit 0; }; [[ "$1" == -u ]] || exit 1
if [[ "$p" =~ ^([A-Za-z]):[/\\](.*)$ ]]; then l="${BASH_REMATCH[1]}"; printf '/%s/%s\n' "${l,,}" "${BASH_REMATCH[2]//\\//}"; else printf '%s\n' "$p"; fi
FAKECYG
chmod +x "$T/cyg/cygpath"
# ofd <home> <state-dir> [pid…] — other_fleets_depend_on_engine in a fresh shell over a fake /proc ($home/proc/<pid>/environ);
# prints its stderr, then `rc=<n>` last.
ofd(){ local h="$1" sd="$2"; shift 2
  ( export PATH="$T/cyg:$PATH" HARNESS_HOME="$h" HARNESS_FLEETS_DIR="$h/fleets" HARNESS_POLLER_DIR="$h/poller" STATE_DIR="$sd" ENGINE_DIR="$R" \
      HARNESS_UNINSTALL_NOMAIN=1 HARNESS_PROC_ROOT="$h/proc" HARNESS_UNINSTALL_WORKER_PIDS="$*"
    source "$R/scripts/uninstall.sh"; other_fleets_depend_on_engine 2>&1; echo "rc=$?" ); }
# fake_worker <home> <pid> <state-dir> <engine-dir> — a /proc entry whose environ names them.
fake_worker(){ mkdir -p "$1/proc/$2"; printf 'STATE_DIR=%s\0ENGINE_DIR=%s\0' "$3" "$4" >"$1/proc/$2/environ"; }
# reg <home> <fleets|poller/registry> <project> [run_dir] — a registry entry (a poller one carries no run_dir).
reg(){ local h="$1" kind="$2" project="$3" rd="${4:-}" f; mkdir -p "$h/$kind"; f="$h/$kind/$(tr -c 'A-Za-z0-9.-' '_' <<<"$project").json"
  if [[ -n "$rd" ]]; then printf '{"prefix":"zz","project":"%s","run_dir":"%s"}\n' "$project" "$rd" >"$f"
  else printf '{"prefix":"zz","project":"%s","slug":"o/r"}\n' "$project" >"$f"; fi; }

I8="$T/i8"; mkdir -p "$I8/home/releases/r1" "$I8/proj/.harness"
SD8="$I8/proj/.harness"
out="$(ofd "$I8/home" "$SD8")"
assert_eq "$out" "rc=1" "no worker and no registry entry: nothing depends on the engine"
# a stale entry: its project folder was deleted — it cannot be stopped, so it must not block
reg "$I8/home" poller/registry "$T/deleted/proj/.harness"
out="$(ofd "$I8/home" "$SD8")"
assert_ok "a registry entry whose project folder is gone does not block"  grep -qx "rc=1" <<<"$out"
assert_ok "… it is named with the fix that prunes it"                     grep -q "stale fleet entry.*deleted.*harness doctor --fix" <<<"$out"
# a stale entry: the folder is there but no pid of its run_dir lives
mkdir -p "$I8/dead/.harness/run"; echo 999999 >"$I8/dead/.harness/run/pool.pid"
reg "$I8/home" fleets "$I8/dead/.harness" "$I8/dead/.harness/run"
rm -rf "$I8/home/poller"
out="$(ofd "$I8/home" "$SD8")"
assert_ok "a fleet entry with no live session and no live pid does not block" grep -qx "rc=1" <<<"$out"
assert_ok "… it is named with the fix"                                    grep -q "dead.*harness doctor --fix" <<<"$out"
# a live fleet: the same entry with a live pid blocks
sleep 60 & LIVE8=$!; SLEEPERS+=("$LIVE8"); echo "$LIVE8" >"$I8/dead/.harness/run/pool.pid"
out="$(ofd "$I8/home" "$SD8")"
assert_ok "a live registered fleet blocks"                                grep -qx "rc=0" <<<"$out"
rm -rf "$I8/home/fleets"
# a worker of a fleet under ANOTHER home runs another engine: it does not count
fake_worker "$I8/home" 4242 "$I8/other/.harness" "$I8/otherhome/releases/r9"
out="$(ofd "$I8/home" "$SD8" 4242)"
assert_eq "$out" "rc=1" "a worker running another home's engine does not block"
# … one that runs a release of this home does, and so does one on the engine link's target, and one with an unreadable engine
fake_worker "$I8/home" 4243 "$I8/other/.harness" "$I8/home/releases/r1"
out="$(ofd "$I8/home" "$SD8" 4242 4243)"
assert_eq "$out" "rc=0" "a worker running a release of this home blocks"
mkdir -p "$I8/home/engine-target"; ln -s "$I8/home/engine-target" "$I8/home/engine"
fake_worker "$I8/home" 4244 "$I8/other/.harness" "$I8/home/engine-target"
out="$(ofd "$I8/home" "$SD8" 4244)"
assert_eq "$out" "rc=0" "a worker running the shared engine's target blocks"
fake_worker "$I8/home" 4245 "$I8/other/.harness" ""
out="$(ofd "$I8/home" "$SD8" 4245)"
assert_eq "$out" "rc=0" "a worker whose engine cannot be read blocks (it might be this one)"
# this fleet itself, spelled the other way (C:/ vs /c/), is not another fleet — in the registry nor as a worker
rm -rf "$I8/home/proc"
SDW="/c/hx1138/proj/.harness"
reg "$I8/home" poller/registry "C:/hx1138/proj/.harness"
out="$(ofd "$I8/home" "$SDW")"
assert_eq "$out" "rc=1" "this project's own registry entry, spelled C:/…, is not another fleet"
fake_worker "$I8/home" 4246 "C:/hx1138/proj/.harness" "$I8/home/releases/r1"
out="$(ofd "$I8/home" "$SDW" 4246)"
assert_eq "$out" "rc=1" "… nor is its own worker"
out="$(ofd "$I8/home" "/c/hx1138/other/.harness" 4246)"
assert_eq "$out" "rc=0" "… while the same worker is another fleet's from a different project"

echo "=== doctor names the leftovers of an uninstalled engine ==="
_DOCTOR_SOURCED=1 source "$R/scripts/doctor.sh"
I6="$T/i6"; mkdir -p "$I6"; mk_install "$I6"; rm -rf "$I6/home/engine"     # the engine went, the rest did not
dl(){ ( export HARNESS_HOME="$I6/home" HARNESS_BIN_DIR="$I6/bin" HARNESS_UNAME=uname-x; doctor_leftovers ); }
out="$(dl)"; rc=$?
assert_no "leftovers without an engine are a problem (non-zero)" test "$rc" = 0
for k in "task Harness" "python3 shim" "harness.cmd" "poller" "fleet registry"; do
  assert_ok "names: $k" grep -qF "$k" <<<"$out"
done
assert_ok "… and the fix"                                      grep -q "uninstall.sh --force --force-engine" <<<"$out"
HARNESS_HOME="$I6/home" HARNESS_BIN_DIR="$I6/bin" HARNESS_USER_SKILLS="$I6/skills" STATE_DIR="$I6/proj/.harness" \
  ENGINE_DIR="$R" HARNESS_UNINSTALL_WORKER_PIDS="" bash "$R/scripts/uninstall.sh" --force --force-engine </dev/null >/dev/null 2>&1
out="$(dl)"; rc=$?
assert_eq "$rc" 0 "after that fix doctor is clean"
out="$(HARNESS_PLATFORM=posix dl)"; rc=$?
assert_eq "$rc" 0 "Linux doctor does not look for Windows leftovers"
I7="$T/i7"; mkdir -p "$I7"; mk_install "$I7"
out="$( export HARNESS_HOME="$I7/home" HARNESS_BIN_DIR="$I7/bin"; doctor_leftovers )"; rc=$?
assert_eq "$rc" 0 "an installed engine is not an uninstalled state"

finish
