#!/usr/bin/env bash
# test_portable.sh — #355: scripts/portable.sh's process and locking helpers, on BOTH branches.
# HARNESS_PLATFORM=windows forces the Windows (Git Bash) branch on Linux: the mkdir lock with its
# owner file and stale-owner steal, lock_holders reading the owner, the /proc-cmdline proc_find, the
# winpid-based proc_ident / proc_kill_tree (taskkill faked), the python3 uuid fallback and cygpath -m
# path export (cygpath faked). The POSIX branch is checked against the flock behaviour it replaced.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/portable.sh"; source "$HERE/helpers.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export HARNESS_LOCK_POLL=0.05

# hold <file> <secs> — a separate process takes <file>'s lock and keeps it for <secs>; echoes its pid
# once the lock is held (its stdout is not the caller's `$(…)` pipe, or that would wait for it).
hold(){ ( lock_acquire "$1" h; : > "$1.held"; sleep "$2"; : > "$1.released"; lock_release "$h" ) >/dev/null 2>&1 & local p=$!
  local i; for (( i = 0; i < 100; i++ )); do [[ -e "$1.held" ]] && break; sleep 0.05; done; echo "$p"; }

for plat in posix windows; do
  export HARNESS_PLATFORM=$plat
  echo "── platform: $plat"
  L="$W/$plat.lock"

  # lock_acquire / lock_release in this shell
  assert_ok "[$plat] lock_free on an untaken lock" lock_free "$L"
  lock_acquire "$L" h1; rc=$?
  assert_eq "$rc" 0 "[$plat] lock_acquire takes a free lock"
  assert_ok "[$plat] the handle is set" test -n "$h1"
  # another process cannot take it while we hold it
  assert_no "[$plat] lock_try from another process fails while held" bash -c "source '$HERE/../scripts/portable.sh'; lock_try '$L' x"
  assert_no "[$plat] lock_free is false while held" lock_free "$L"
  holders="$(lock_holders "$L" | cut -f1 | tr '\n' ' ')"
  assert_ok "[$plat] lock_holders names this shell ($holders)" grep -qw "$$" <<< "$holders"
  lock_release "$h1"
  assert_ok "[$plat] lock_free again after lock_release" lock_free "$L"
  assert_ok "[$plat] lock_try from another process succeeds after release" bash -c "source '$HERE/../scripts/portable.sh'; lock_try '$L' x"

  # contention: a holder in another process blocks lock_try, and lock_acquire waits for it
  rm -f "$L.held" "$L.released"; hp="$(hold "$L" 1)"
  assert_no "[$plat] lock_try fails while another process holds it" lock_try "$L" h2
  lock_acquire "$L" h2
  assert_ok "[$plat] lock_acquire waited for the holder to release it" test -e "$L.released"
  lock_release "$h2"; wait "$hp" 2>/dev/null

  # a holder that dies without releasing frees the lock (fd close / stale owner)
  ( bash -c "source '$HERE/../scripts/portable.sh'; lock_acquire '$L' h; kill -KILL \$\$"; true ) 2>/dev/null; sleep 0.1
  assert_ok "[$plat] a dead holder's lock is free" lock_free "$L"
  assert_ok "[$plat] and can be taken" lock_try "$L" h3
  lock_release "$h3"

  # fixed fd form (start.sh's fd 9)
  lock_try "$L" h4 9; rc=$?
  assert_eq "$rc" 0 "[$plat] lock_try with a fixed fd takes the lock"
  if [[ $plat == posix ]]; then assert_eq "$h4" 9 "[posix] the fixed fd is the handle"
  else assert_eq "$h4" "$L.d" "[windows] the handle is the lock directory"; fi
  lock_release "$h4"
  assert_ok "[$plat] released" lock_free "$L"

  # proc_find: a uniquely named process is found by its command line, and the scan's own subshell is not
  tag="portable-probe-$plat-$$"
  bash -c "exec -a $tag sleep 5" & sp=$!
  sleep 0.2
  found="$(proc_find "^$tag")"
  assert_eq "$found" "$sp" "[$plat] proc_find finds the process by its command line"
  assert_eq "$(proc_find "^$tag-nothing")" "" "[$plat] proc_find finds nothing for a pattern no process has"
  assert_ok "[$plat] proc_alive on a live process" proc_alive "$sp"
  kill "$sp"; wait "$sp" 2>/dev/null
  assert_no "[$plat] proc_alive on a reaped process" proc_alive "$sp"
  assert_no "[$plat] proc_alive on garbage" proc_alive "x1"
done

# ---- Windows specifics -----------------------------------------------------------------------------
export HARNESS_PLATFORM=windows
L="$W/win-specific.lock"
# the owner file: pid, winpid, cmdline (fake /proc winpid via HARNESS_PROC_ROOT)
FP="$W/proc"; mkdir -p "$FP/$$"; echo 4242 > "$FP/$$/winpid"; printf 'bash\0owner-test\0' > "$FP/$$/cmdline"
HARNESS_PROC_ROOT="$FP" lock_acquire "$L" hw
IFS=$'\t' read -r opid owin ocmd < "$L.d/owner"
assert_eq "$opid" "$$" "[windows] the owner file records the holder's pid"
assert_eq "$owin" 4242 "[windows] the owner file records the holder's winpid"
assert_eq "$ocmd" "bash owner-test " "[windows] the owner file records the holder's command line"
assert_eq "$(lock_holders "$L")" "$$	bash owner-test " "[windows] lock_holders reads the owner"
lock_release "$hw"
assert_no "[windows] lock_release removes the lock directory" test -e "$L.d"

# a stale owner (dead pid) is stolen; a live one is not
mkdir -p "$L.d"; printf '999999999\t\tgone\n' > "$L.d/owner"
assert_eq "$(lock_holders "$L")" "" "[windows] lock_holders ignores a dead owner"
assert_ok "[windows] a dead owner's lock is free" lock_free "$L"
assert_ok "[windows] and lock_try steals it" lock_try "$L" hs
assert_eq "$(cut -f1 "$L.d/owner")" "$$" "[windows] the stolen lock is ours"
assert_eq "$(ls -d "$L".d.stale.* 2>/dev/null)" "" "[windows] the stale lock left nothing behind"
lock_release "$hs"
# an owner-less lock (its taker died between mkdir and owner) is stale only after HARNESS_LOCK_STALE_S
mkdir -p "$L.d"
assert_no "[windows] a fresh owner-less lock is held (its taker is still writing the owner)" lock_try "$L" hx
touch -d '@1' "$L.d"
assert_ok "[windows] an old owner-less lock is stolen" lock_try "$L" hx
lock_release "$hx"
# no flock anywhere on the Windows branch: run it with flock unavailable
assert_ok "[windows] the lock works with no flock on PATH" bash -c "
  flock(){ echo FLOCK-CALLED >&2; return 99; }; export -f flock
  source '$HERE/../scripts/portable.sh'; export HARNESS_PLATFORM=windows
  lock_acquire '$W/noflock.lock' h && lock_release \"\$h\" && ! test -e '$W/noflock.lock.d'"

# proc_ident / proc_args / proc_kill_tree use the winpid + /proc cmdline, never procps' ps -o
mkdir -p "$FP/777"; echo 31337 > "$FP/777/winpid"; printf 'python\0runner.py\0' > "$FP/777/cmdline"
assert_eq "$(HARNESS_PROC_ROOT="$FP" proc_ident 777)" "31337|python runner.py " "[windows] proc_ident is winpid|cmdline"
assert_eq "$(HARNESS_PROC_ROOT="$FP" proc_args 777)" "python runner.py" "[windows] proc_args reads /proc cmdline"
cat > "$W/taskkill" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$W/taskkill.log"
EOF
chmod +x "$W/taskkill"
HARNESS_PROC_ROOT="$FP" HARNESS_TASKKILL="$W/taskkill" proc_kill_tree 777
assert_eq "$(cat "$W/taskkill.log" 2>/dev/null)" "//T //F //PID 31337" "[windows] proc_kill_tree runs taskkill /T /F on the winpid"
assert_eq "$(detach_prefix)" "" "[windows] no setsid prefix"

# new_uuid: Git Bash has neither uuidgen nor the kernel's uuid — python3 is the last fallback
mkdir -p "$W/bin"; ln -sf "$(command -v python3)" "$W/bin/python3"
u="$(PATH="$W/bin" HARNESS_PROC_ROOT="$W/no-proc" new_uuid)"
assert_ok "[windows] new_uuid falls back to python3 ($u)" grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$' <<< "$u"

# path export: exported path variables in cygpath -m form; an unexported one is left alone
cat > "$W/bin/cygpath" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -m ]] || exit 2
p="$2"; [[ $p == /c/* ]] && p="C:/${p#/c/}"; echo "$p"
EOF
chmod +x "$W/bin/cygpath"
out="$(PATH="$W/bin:$PATH" bash -c "source '$HERE/../scripts/portable.sh'
  export HARNESS_PLATFORM=windows STATE_DIR=/c/proj/.harness HARNESS_HOME=/c/Users/me/.harness; RUN_DIR=/c/proj/.harness/run
  export_native_paths; printf '%s|%s|%s' \"\$STATE_DIR\" \"\$HARNESS_HOME\" \"\$RUN_DIR\"
  python3 -c 'import os; print(\"|\" + os.environ[\"STATE_DIR\"])'")"
assert_eq "$out" "C:/proj/.harness|C:/Users/me/.harness|/c/proj/.harness/run|C:/proj/.harness" "[windows] export_native_paths puts exported paths in mixed form for native children"

# ---- POSIX: unchanged ------------------------------------------------------------------------------
export HARNESS_PLATFORM=posix
assert_eq "$(STATE_DIR=/c/x bash -c "source '$HERE/../scripts/portable.sh'; export STATE_DIR; export_native_paths; echo \$STATE_DIR")" /c/x "[posix] export_native_paths changes nothing"
assert_eq "$(native_path /c/x)" /c/x "[posix] native_path is the identity"
if command -v setsid >/dev/null 2>&1; then assert_eq "$(detach_prefix)" setsid "[posix] detach_prefix is setsid where the host has it"; fi
assert_ok "[posix] new_uuid gives a uuid" grep -Eq '^[0-9a-f-]{36}$' <<< "$(new_uuid)"
# the POSIX lock is a flock: a raw flock on the file sees it held
lock_acquire "$W/raw.lock" hp
assert_no "[posix] a raw flock sees the helper's lock" flock -n "$W/raw.lock" true
lock_release "$hp"
assert_ok "[posix] and sees it released" flock -n "$W/raw.lock" true
assert_no "[posix] no lock directory on POSIX" test -e "$W/raw.lock.d"

finish
