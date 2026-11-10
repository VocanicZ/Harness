#!/usr/bin/env bash
# test_swarm.sh — #202: scripts/swarm-suite.sh offloads PRD review's full suite (the only full-suite run, #449) to swarm, and every path
# that is NOT a swarm verdict (no swarm, HARNESS_SWARM=off, timeout) exits 3 so the lane runs locally.
#
# The fake `swarm` on PATH does what the real coordinator does with a job, minus HTCondor: `submit`
# parses swarm.toml with tomllib (rejecting unknown keys and bad ids exactly as the contract says),
# runs split in the job dir, runs `run` once per shard in a COPY of workdir with {shard}/{out}
# shlex-quoted, then merge with {outs}. `wait` returns the merge's verdict, or FAKE_WAIT_RC.
# Like the real one it packs workdir (honouring its .swarmignore) into
# $SWARM_JOBS_DIR/<name>/workdir.tar.gz at submit, keeping the last run as <name>.prev (#234).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
# Swarm submission is a Linux-only HTCondor service (docs/reference.md parity matrix, row `swarm submission`: n/a on Windows,
# #492), and this file's fake coordinator stands in for it: the one Windows skip it may take.
windows_skip_file "swarm submission" "swarm is a Linux-only HTCondor service; a Windows lane runs rtdd locally"
SUITE="$HERE/../scripts/swarm-suite.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"; tmp_cleanup' EXIT
export RUN_DIR="$T/run"; unset HARNESS_SWARM HARNESS_SWARM_TEST_CMD HARNESS_SWARM_TIMEOUT HARNESS_SWARM_PACK HARNESS_SWARM_SECS_PER_FILE
export HARNESS_SWARM_LOCAL_MAX_SECS=0   # #618: the fixture suites below are tiny; pin the small-suite switch off except where it is tested
export SWARM_JOBS_DIR="$T/swarm jobs"
FAKEBIN="$T/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/swarm" <<'EOF'
#!/usr/bin/env python3
import os, re, shlex, shutil, subprocess, sys, tomllib
state = os.environ["FAKE_SWARM_STATE"]
log = open(os.path.join(state, "calls"), "a"); log.write(" ".join(sys.argv[1:]) + "\n"); log.close()
cmd, arg = sys.argv[1], sys.argv[2]
if cmd == "submit":
    job = os.path.abspath(arg); spec = tomllib.load(open(os.path.join(job, "swarm.toml"), "rb"))
    allowed = {"name", "workdir", "gpu", "vram_mb", "threads", "setup", "check", "split", "run", "merge", "mem_mb", "save_seconds"}
    assert set(spec) <= allowed, set(spec) - allowed
    assert re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", spec["name"]) and not spec["name"].endswith(".prev")
    assert "{out}" in spec["run"] and "{outs}" in spec["merge"]
    ids = subprocess.run(["sh", "-c", spec["split"]], cwd=job, capture_output=True, text=True, check=True).stdout.split()
    assert ids and len(ids) == len(set(ids)) and all(re.fullmatch(r"[A-Za-z0-9._-]+", i) for i in ids), ids
    wd = os.path.join(job, spec.get("workdir", "."))
    jd = os.path.join(os.environ["SWARM_JOBS_DIR"], spec["name"])
    if os.path.exists(jd):
        shutil.rmtree(jd + ".prev", ignore_errors=True); os.rename(jd, jd + ".prev")
    os.makedirs(jd); tb = os.path.join(jd, "workdir.tar.gz")
    ex = [f"--exclude-from={wd}/.swarmignore"] if os.path.exists(os.path.join(wd, ".swarmignore")) else []
    subprocess.run(["tar", "-czf", tb, *ex, "-C", wd, "."], check=True)
    open(os.path.join(state, spec["name"] + ".packed"), "w").write(subprocess.run(["tar", "-tzf", tb], capture_output=True, text=True, check=True).stdout)
    sd = os.path.join(state, spec["name"]); shutil.rmtree(sd, ignore_errors=True)
    work = os.path.join(sd, "work"); os.makedirs(work); subprocess.run(["tar", "-xzf", tb, "-C", work], check=True)
    outs = []
    for i in ids:
        out = os.path.join(sd, "outs", i); os.makedirs(out); outs.append(out)
        r = spec["run"].replace("{shard}", shlex.quote(i)).replace("{out}", shlex.quote(out))
        env = dict(os.environ)
        if env.get("FAKE_SHARD_PATH"): env["PATH"] = env["FAKE_SHARD_PATH"]   # #793: the worker's PATH (no bwrap / a fake one)
        rc = subprocess.run(["sh", "-c", r], cwd=work, env=env).returncode
        assert rc == 0, f"run exited {rc} for {i}"   # a red test file is still a COMPLETE shard
        # resume contract: a restart on a finished out must be a no-op
        assert subprocess.run(["sh", "-c", r], cwd=work, env=env).returncode == 0
    m = spec["merge"].replace("{outs}", " ".join(shlex.quote(o) for o in outs))
    open(os.path.join(state, spec["name"] + ".rc"), "w").write(str(subprocess.run(["sh", "-c", m], cwd=job).returncode))
elif cmd == "wait":
    rc = os.environ.get("FAKE_WAIT_RC") or open(os.path.join(state, arg + ".rc")).read()
    sys.exit(int(rc))
EOF
chmod +x "$FAKEBIN/swarm"
export FAKE_SWARM_STATE="$T/state"; mkdir -p "$FAKE_SWARM_STATE"

# A worktree whose test files have the awkward names the id mapping exists for.
WT="$T/wt"; mkdir -p "$WT/test/sub dir"
printf 'exit 0\n' > "$WT/test/test_ok.sh"
printf 'exit 0\n' > "$WT/test/sub dir/test_spa ce&q\"uote.sh"
printf 'echo boom; exit 1\n' > "$WT/test/test_red.sh"
printf 'import sys\nif __name__ == "__main__":\n    sys.exit(0)\n' > "$WT/test/test_main.py"
printf 'not a test\n' > "$WT/README.md"
printf 'build/\n*.log\n' > "$WT/.gitignore"
mkdir -p "$WT/build"; head -c 65536 /dev/urandom > "$WT/build/big.bin"; printf 'x\n' > "$WT/debug.log"
printf 'gone\n' > "$WT/gone.txt"
git -C "$WT" init -q && git -C "$WT" add -A
rm "$WT/gone.txt"                                  # tracked, deleted in the worktree
printf 'new\n' > "$WT/test/new_helper.sh"         # untracked, not ignored: the lane's new file
WT_STATUS="$(git -C "$WT" status --porcelain --untracked-files=all --ignored)"

run_suite(){ PATH="$FAKEBIN:$PATH" bash "$SUITE" "$@" > "$T/out" 2> "$T/err"; echo $?; }

echo "-- green job: generated swarm.toml + shard-id map"
rc="$(run_suite "$WT" "acme/widgets-7 baseline" test/test_ok.sh "test/sub dir/test_spa ce&q\"uote.sh" test/test_main.py)"
assert_eq "$rc" 0 "all files pass → exit 0"
JOB="$RUN_DIR/swarm/acme-widgets-7-baseline"
assert_ok "job dir lives under \$RUN_DIR/swarm/<sanitized name>" test -f "$JOB/swarm.toml"
assert_eq "$(git -C "$WT" status --porcelain --untracked-files=all --ignored)" "$WT_STATUS" "nothing written into the worktree"
keys="$(python3 -c 'import sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); print(" ".join(sorted(d)), d["name"], d["workdir"], d["split"], d["merge"])' "$JOB/swarm.toml")"
assert_eq "$keys" "merge name run split workdir acme-widgets-7-baseline $JOB/workdir cat shards.ids sh merge.sh {outs}" "swarm.toml: name/workdir=staged snapshot/split/run/merge only"
assert_ok "run carries {shard} and {out}" grep -q '{shard}' "$JOB/swarm.toml"
ids_ok="$(cut -f1 "$JOB/shards.tsv" | grep -cvE '^[A-Za-z0-9._-]+$')"
assert_eq "$ids_ok" 0 "every shard id matches [A-Za-z0-9._-]+ (paths with /, space, &, quote)"
assert_eq "$(cut -f2 "$JOB/shards.tsv")" "test/test_ok.sh
test/sub dir/test_spa ce&q\"uote.sh
test/test_main.py" "map file round-trips each id to its path, in split order"
assert_eq "$(cut -f1 "$JOB/shards.tsv")" "$(cat "$JOB/shards.ids")" "split prints the map's ids"
# The shard itself decoded each id back to the same path (it never sees the map file).
for o in "$FAKE_SWARM_STATE/acme-widgets-7-baseline/outs/"*; do
  id="$(basename "$o")"; assert_eq "$(cat "$o/file")" "$(awk -F'\t' -v i="$id" '$1==i{print $2}' "$JOB/shards.tsv")" "shard $id decodes to its mapped path"
  assert_ok "shard $id wrote JUnit into {out}" grep -q '<testsuite' "$o/junit.xml"
done
assert_eq "$(cat "$T/out")" "3 files, 0 failing" "green prints the merge summary"

echo "-- #234: pack only what git sees, and never leave the tarball behind"
P="$FAKE_SWARM_STATE/acme-widgets-7-baseline.packed"
assert_ok "tracked file packed" grep -qx './test/test_ok.sh' "$P"
assert_ok "tracked file with awkward name packed" grep -qxF './test/sub dir/test_spa ce&q"uote.sh' "$P"
assert_ok "untracked, unignored file packed (a lane's new test)" grep -qx './test/new_helper.sh' "$P"
assert_ok ".gitignore packed" grep -qx './.gitignore' "$P"
assert_no "ignored build output not packed" grep -q 'build' "$P"
assert_no "ignored file not packed" grep -q 'debug.log' "$P"
assert_no "tracked-but-deleted file not packed" grep -q 'gone.txt' "$P"
assert_no "staged snapshot removed once submitted" test -e "$JOB/workdir"
assert_no "green job leaves no workdir.tar.gz" test -e "$SWARM_JOBS_DIR/acme-widgets-7-baseline/workdir.tar.gz"
assert_ok "green job keeps its swarm state dir" test -d "$SWARM_JOBS_DIR/acme-widgets-7-baseline"
rc="$(run_suite "$WT" acme-widgets-7-baseline test/test_ok.sh)"
assert_eq "$rc" 0 "same job name again → runs"
assert_ok "previous run rotated to .prev" test -d "$SWARM_JOBS_DIR/acme-widgets-7-baseline.prev"
assert_no "no workdir.tar.gz in .prev either" test -e "$SWARM_JOBS_DIR/acme-widgets-7-baseline.prev/workdir.tar.gz"
printf 'build/\n' > "$WT/.swarmignore"; printf 'test/new_helper.sh\n' >> "$WT/.swarmignore"
rc="$(HARNESS_SWARM_PACK=all run_suite "$WT" packall test/test_ok.sh)"
assert_eq "$rc" 0 "HARNESS_SWARM_PACK=all → runs"
assert_ok "HARNESS_SWARM_PACK=all packs ignored files too" grep -qx './debug.log' "$FAKE_SWARM_STATE/packall.packed"
assert_no "HARNESS_SWARM_PACK=all still honours the worktree's .swarmignore" grep -q 'new_helper' "$FAKE_SWARM_STATE/packall.packed"
assert_no "HARNESS_SWARM_PACK=all leaves no workdir.tar.gz" test -e "$SWARM_JOBS_DIR/packall/workdir.tar.gz"
rc="$(run_suite "$WT" swignore test/test_ok.sh)"
assert_no "an untracked .swarmignore is packed and honoured" grep -q 'new_helper' "$FAKE_SWARM_STATE/swignore.packed"
rm "$WT/.swarmignore"

rc="$(RUN_DIR= STATE_DIR="$T/state dir" run_suite "$WT" fallback test/test_ok.sh)"
assert_eq "$rc" 0 "no RUN_DIR in the env → still runs"
assert_ok "no RUN_DIR → job dir under \$STATE_DIR/run/swarm" test -f "$T/state dir/run/swarm/fallback/swarm.toml"

echo "-- red job: failing files printed, exit 1"
rc="$(run_suite "$WT" red test/test_ok.sh test/test_red.sh)"
assert_eq "$rc" 1 "a failing file → exit 1"
assert_ok "failing file named" grep -q $'^test/test_red.sh\tfail\t' "$T/out"
assert_no "passing file not listed as failing" grep -q '^test/test_ok.sh' "$T/out"
assert_ok "red shard's output kept for the lane" grep -q boom "$FAKE_SWARM_STATE/red/outs/$(sed -n 2p "$RUN_DIR/swarm/red/shards.ids")/output.log"
assert_no "red job leaves no workdir.tar.gz" test -e "$SWARM_JOBS_DIR/red/workdir.tar.gz"
assert_ok "red shard's JUnit records the failure" grep -q '<failure' "$FAKE_SWARM_STATE/red/outs/$(sed -n 2p "$RUN_DIR/swarm/red/shards.ids")/junit.xml"

echo "-- discovery: no files named → the repo's test files"
rc="$(run_suite "$WT" disc)"
assert_eq "$rc" 1 "discovered suite includes the red file"
assert_eq "$(cut -f2 "$RUN_DIR/swarm/disc/shards.tsv" | sort | tr '\n' '|')" "test/sub dir/test_spa ce&q\"uote.sh|test/test_main.py|test/test_ok.sh|test/test_red.sh|" "only test files are sharded"

echo "-- #601: a project's own tests package imports (bench pennywise shape: tests/ is a package, files run as scripts)"
PW="$T/pw"; mkdir -p "$PW/tests" "$PW/pennywise"
: > "$PW/tests/__init__.py"; : > "$PW/pennywise/__init__.py"
printf 'VALUE = 7\n' > "$PW/pennywise/ledger.py"
printf 'import os, sys\nsys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))\n' > "$PW/tests/_path.py"
printf 'import unittest\nfrom tests import _path  # noqa: F401\nfrom pennywise import ledger\n\nclass T(unittest.TestCase):\n    def test_v(self):\n        self.assertEqual(ledger.VALUE, 7)\n\nif __name__ == "__main__":\n    unittest.main()\n' > "$PW/tests/test_ledger.py"
printf 'import unittest\nfrom tests import _path  # noqa: F401\n\nclass T(unittest.TestCase):\n    def test_bad(self):\n        self.assertEqual(1, 2)\n\nif __name__ == "__main__":\n    unittest.main()\n' > "$PW/tests/test_wrong.py"
git -C "$PW" init -q && git -C "$PW" add -A
rc="$(run_suite "$PW" pw tests/test_ledger.py)"
assert_eq "$rc" 0 "tests/test_ledger.py: 'from tests import _path' resolves under the default command"
assert_no "no 'No module named' in the shard output" grep -rq "No module named" "$FAKE_SWARM_STATE/pw/outs"
rc="$(run_suite "$PW" pwred tests/test_wrong.py)"
assert_eq "$rc" 1 "a genuinely failing assertion in the same shape is still red"
assert_ok "red for the assertion, not the import" grep -rq "AssertionError" "$FAKE_SWARM_STATE/pwred/outs"

echo "-- custom per-file command"
rc="$(HARNESS_SWARM_TEST_CMD='test -f {file}' run_suite "$WT" custom test/test_ok.sh test/test_red.sh)"
assert_eq "$rc" 0 "HARNESS_SWARM_TEST_CMD replaces the default command"

echo "-- #793: every shard runs with a private tmux dir, and cannot reach a server outside it"
UIDN="$(id -u)"
SHARD_OUTS(){ echo "$FAKE_SWARM_STATE/$1/outs"; }
# A shard-side PATH with the tools a shard needs but NO bwrap (the real one may be installed on this host).
NOBWRAP="$T/nobwrap"; mkdir -p "$NOBWRAP"
for c in sh bash env python3 tar cat printf sed grep mv rm mkdir mktemp id dirname basename test head tr sleep true false ls wc cut; do
  p="$(type -P "$c" 2>/dev/null)" && [[ -x "$p" && -f "$p" ]] && ln -sf "$p" "$NOBWRAP/$c"
done
# …and the REAL tmux, not test/guard/tmux: the guard would refuse the shard's `tmux kill-server` at the inherited socket and hide the hazard.
while IFS= read -r d; do
  [[ -x "$d/tmux" && -f "$d/tmux" && "$(cd "$d" && pwd -P)" != "$(cd "$HERE/guard" && pwd -P)" ]] && { ln -sf "$d/tmux" "$NOBWRAP/tmux"; break; }
done < <(tr ':' '\n' <<<"$PATH")
HOSTSOCK="$T/hostsock"; mkdir -p "$HOSTSOCK"
printf 'echo "TMUXDIR=${TMUX_TMPDIR-unset}"; echo "TMUX=${TMUX-unset}"; echo "PANE=${TMUX_PANE-unset}"; test -d "$TMUX_TMPDIR" && echo "DIR_EXISTS=yes"\nexit 0\n' > "$WT/test/test_env.sh"
printf 'import os, sys\nif __name__ == "__main__":\n    print("TMUXDIR=" + os.environ.get("TMUX_TMPDIR", "unset")); print("TMUX=" + os.environ.get("TMUX", "unset"))\n    sys.exit(0)\n' > "$WT/test/test_env_main.py"
printf 'import os\n\ndef test_env():\n    assert os.environ.get("TMUX") is None and os.environ.get("TMUX_PANE") is None\n    d = os.environ.get("TMUX_TMPDIR", "")\n    assert d and os.path.isdir(d) and d != os.environ["HOSTSOCK"]\n' > "$WT/test/test_env_pytest.py"
git -C "$WT" add -A
# inherit_env [VAR=val…] cmd… — run cmd with a shard-side PATH and the host's tmux variables in the environment the shard inherits.
inherit_env(){ ( export HOSTSOCK FAKE_SHARD_PATH="$NOBWRAP" TMUX_TMPDIR="$HOSTSOCK" TMUX="$HOSTSOCK/tmux-$UIDN/default,1,0" TMUX_PANE=%9
    while [[ "${1:-}" == [A-Z_]*=* ]]; do export "$1"; shift; done; "$@" ); }
rc="$(inherit_env run_suite "$WT" iso test/test_env.sh test/test_env_main.py test/test_env_pytest.py)"
assert_eq "$rc" 0 "isolation suite: default command for .sh, .py script and pytest → green"
assert_eq "$(cat "$(SHARD_OUTS iso)/$(grep -F test_env_pytest.py "$RUN_DIR/swarm/iso/shards.tsv" | cut -f1)/status")" pass "pytest run: the test saw a private TMUX_TMPDIR and no TMUX (it asserts that itself)"
for o in "$(SHARD_OUTS iso)"/*; do
  f="$(cat "$o/file")"; [[ "$f" == *_pytest.py ]] && continue; td="$(sed -n 's/^TMUXDIR=//p' "$o/output.log")"
  assert_ok "$f: TMUX_TMPDIR is a path set by the shard" test -n "$td" -a "$td" != unset
  assert_no "$f: TMUX_TMPDIR is not the inherited one" test "$td" = "$HOSTSOCK"
  assert_no "$f: TMUX_TMPDIR is not /tmp" test "$td" = /tmp
  case "$td" in /tmp/tmux-$UIDN|/tmp/tmux-$UIDN/*) bad=1;; *) bad=0;; esac
  assert_eq "$bad" 0 "$f: TMUX_TMPDIR is not under /tmp/tmux-\$UID"
  case "$td" in "$FAKE_SWARM_STATE"/*) bad=1;; *) bad=0;; esac
  assert_eq "$bad" 0 "$f: TMUX_TMPDIR is not under {out}"
  assert_ok "$f: inherited TMUX is unset" grep -qx 'TMUX=unset' "$o/output.log"
  assert_no "$f: private tmux dir removed once the shard ended" test -e "$td"
done
assert_ok "script run: the dir existed while the test ran" grep -qx 'DIR_EXISTS=yes' "$(SHARD_OUTS iso)/$(grep -F test_env.sh "$RUN_DIR/swarm/iso/shards.tsv" | cut -f1)/output.log"
assert_ok "script run: TMUX_PANE unset" grep -qx 'PANE=unset' "$(SHARD_OUTS iso)/$(grep -F test_env.sh "$RUN_DIR/swarm/iso/shards.tsv" | cut -f1)/output.log"
assert_eq "$(ls "$(SHARD_OUTS iso)/$(grep -F test_env.sh "$RUN_DIR/swarm/iso/shards.tsv" | cut -f1)" | tr '\n' ' ')" "file junit.xml output.log status " "{out} holds only file/junit.xml/output.log/status"
rc="$(inherit_env HARNESS_SWARM_TEST_CMD='sh {file}' run_suite "$WT" isocustom test/test_env.sh)"
assert_eq "$rc" 0 "custom HARNESS_SWARM_TEST_CMD → runs"
td="$(sed -n 's/^TMUXDIR=//p' "$(SHARD_OUTS isocustom)"/*/output.log)"
assert_ok "custom command: private TMUX_TMPDIR, not the inherited one" test -n "$td" -a "$td" != unset -a "$td" != "$HOSTSOCK"
assert_ok "custom command: inherited TMUX unset" grep -qx 'TMUX=unset' "$(SHARD_OUTS isocustom)"/*/output.log
assert_no "custom command: private dir removed" test -e "$td"

if command -v tmux >/dev/null 2>&1; then
  printf 'tmux kill-server\ntmux new-session -d -s x "sleep 30"\ntmux kill-server\nexit 0\n' > "$WT/test/test_killer.sh"
  git -C "$WT" add -A
  # The sentinel stands in for the host's default server: it lives on the default socket of $HOSTSOCK, never /tmp/tmux-$UID.
  ( unset TMUX; TMUX_TMPDIR="$HOSTSOCK" tmux new-session -d -s sentinel "sleep 600" )
  assert_ok "sentinel server is up" env -u TMUX TMUX_TMPDIR="$HOSTSOCK" tmux has-session -t sentinel
  rc="$(inherit_env HARNESS_SWARM_SANDBOX=off run_suite "$WT" killer test/test_killer.sh)"
  assert_eq "$rc" 0 "a test that kills its tmux server → green"
  assert_ok "a shard cannot kill the outside tmux server (sentinel survives)" env -u TMUX TMUX_TMPDIR="$HOSTSOCK" tmux has-session -t sentinel
  env -u TMUX TMUX_TMPDIR="$HOSTSOCK" tmux kill-server 2>/dev/null
else
  echo "SKIP: tmux not installed — sentinel-server regression test"
fi

echo "-- #793: bwrap used when it works, clean fallback when it does not"
FAKEBW="$T/fakebw"; mkdir -p "$FAKEBW"
cat > "$FAKEBW/bwrap" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_BWRAP_LOG"
while [ $# -gt 0 ]; do [ "$1" = -- ] && { shift; exec "$@"; }; shift; done
exit 2
EOF
chmod +x "$FAKEBW/bwrap"
BWBAD="$T/badbw"; mkdir -p "$BWBAD"; printf '#!/bin/sh\necho "$*" >> "$FAKE_BWRAP_LOG"\nexit 1\n' > "$BWBAD/bwrap"; chmod +x "$BWBAD/bwrap"
export FAKE_BWRAP_LOG="$T/bwrap.log"
tmux_dir_before=0; [[ -d "/tmp/tmux-$UIDN" ]] && tmux_dir_before=1
: > "$FAKE_BWRAP_LOG"
rc="$(FAKE_SHARD_PATH="$FAKEBW:$NOBWRAP" TMUX_TMPDIR="$HOSTSOCK" run_suite "$WT" bw test/test_ok.sh test/test_red.sh test/test_env.sh)"
assert_eq "$rc" 1 "through bwrap: a red file stays red"
assert_eq "$(cut -f1 "$RUN_DIR/swarm/bw/failures.txt")" "test/test_red.sh" "through bwrap: only the red file fails, green files stay green"
assert_ok "bwrap run with --unshare-pid" grep -q -- '--unshare-pid' "$FAKE_BWRAP_LOG"
assert_ok "bwrap run with a tmpfs over /tmp/tmux-<uid>" grep -q -- "--tmpfs /tmp/tmux-$UIDN" "$FAKE_BWRAP_LOG"
assert_ok "the test command ran through bwrap" grep -qE -- ' -- sh .*/cmd\.sh$' "$FAKE_BWRAP_LOG"
assert_ok "the shard probed bwrap with a trial run first" grep -qE -- ' -- true$' "$FAKE_BWRAP_LOG"
mkdir -p -m 700 "$HOSTSOCK/tmux-$UIDN"   # an inherited TMUX_TMPDIR that has its tmux-<uid> dir
: > "$FAKE_BWRAP_LOG"
rc="$(FAKE_SHARD_PATH="$FAKEBW:$NOBWRAP" TMUX_TMPDIR="$HOSTSOCK" run_suite "$WT" bwh test/test_ok.sh)"
assert_ok "inherited TMUX_TMPDIR's tmux-<uid> gets its own tmpfs" grep -q -- "--tmpfs $HOSTSOCK/tmux-$UIDN" "$FAKE_BWRAP_LOG"
td="$(sed -n 's/^TMUXDIR=//p' "$(SHARD_OUTS bw)"/*/output.log | head -1)"
assert_ok "through bwrap the shard still has its private TMUX_TMPDIR" test -n "$td" -a "$td" != "$HOSTSOCK"
: > "$FAKE_BWRAP_LOG"
rc="$(HARNESS_SWARM_SANDBOX=off FAKE_SHARD_PATH="$FAKEBW:$NOBWRAP" run_suite "$WT" bwoff test/test_ok.sh)"
assert_eq "$rc" 0 "HARNESS_SWARM_SANDBOX=off → green"
assert_eq "$(cat "$FAKE_BWRAP_LOG")" "" "HARNESS_SWARM_SANDBOX=off never calls bwrap"
: > "$FAKE_BWRAP_LOG"
rc="$(FAKE_SHARD_PATH="$BWBAD:$NOBWRAP" run_suite "$WT" bwbad test/test_ok.sh test/test_red.sh test/test_env.sh)"
assert_eq "$rc" 1 "bwrap whose trial run fails → tests still run unwrapped, the red file stays red"
assert_eq "$(cut -f1 "$RUN_DIR/swarm/bwbad/failures.txt")" "test/test_red.sh" "failed trial: only the red file fails"
assert_eq "$(grep -c . "$FAKE_BWRAP_LOG")" 3 "failed trial: bwrap was only probed (once per shard), never used to run a test"
td="$(sed -n 's/^TMUXDIR=//p' "$(SHARD_OUTS bwbad)"/*/output.log | head -1)"
assert_ok "failed trial: private TMUX_TMPDIR still set" test -n "$td" -a "$td" != unset -a "$td" != "$HOSTSOCK"
rc="$(FAKE_SHARD_PATH="$NOBWRAP" run_suite "$WT" nobw test/test_ok.sh test/test_red.sh test/test_env.sh)"
assert_eq "$rc" 1 "no bwrap on PATH → tests run unwrapped, the red file stays red"
assert_eq "$(cut -f1 "$RUN_DIR/swarm/nobw/failures.txt")" "test/test_red.sh" "no bwrap: only the red file fails"
td="$(sed -n 's/^TMUXDIR=//p' "$(SHARD_OUTS nobw)"/*/output.log | head -1)"
assert_ok "no bwrap: private TMUX_TMPDIR set" test -n "$td" -a "$td" != unset
# The helper may have made an empty /tmp/tmux-<uid> (0700) for the mount point; leave the host as found.
[[ $tmux_dir_before -eq 0 ]] && rmdir "/tmp/tmux-$UIDN" 2>/dev/null
rm -f "$WT/test/test_env.sh" "$WT/test/test_env_main.py" "$WT/test/test_env_pytest.py" "$WT/test/test_killer.sh"; git -C "$WT" add -A

echo "-- swarm wait exit mapping"
rc="$(FAKE_WAIT_RC=0 run_suite "$WT" w0 test/test_ok.sh)"; assert_eq "$rc" 0 "wait 0 → 0"
rc="$(FAKE_WAIT_RC=1 run_suite "$WT" w1 test/test_red.sh)"; assert_eq "$rc" 1 "wait 1 with failing files → 1"
rc="$(FAKE_WAIT_RC=1 run_suite "$WT" w1b test/test_ok.sh)"; assert_eq "$rc" 3 "wait 1 with NO failing file (infra failure) → 3"
: > "$FAKE_SWARM_STATE/calls"
rc="$(FAKE_WAIT_RC=124 HARNESS_SWARM_TIMEOUT=7 run_suite "$WT" slow test/test_ok.sh)"; assert_eq "$rc" 3 "wait 124 (timeout) → 3"
assert_ok "budget passed to swarm wait" grep -qx 'wait slow --timeout 7' "$FAKE_SWARM_STATE/calls"
assert_ok "timed-out job is cancelled" grep -qx 'cancel slow' "$FAKE_SWARM_STATE/calls"
assert_no "cancelled job leaves no workdir.tar.gz" test -e "$SWARM_JOBS_DIR/slow/workdir.tar.gz"
rc="$(FAKE_WAIT_RC=2 run_suite "$WT" w2 test/test_ok.sh)"; assert_eq "$rc" 3 "any other swarm wait exit → 3"

echo "-- not run here → 3"
rc="$(PATH="/usr/bin:/bin" bash "$SUITE" "$WT" nos test/test_ok.sh 2>/dev/null)"; assert_eq "$?" 3 "swarm missing from PATH → 3"
: > "$FAKE_SWARM_STATE/calls"
rc="$(HARNESS_SWARM=off run_suite "$WT" off test/test_ok.sh)"; assert_eq "$rc" 3 "HARNESS_SWARM=off → 3"
assert_eq "$(cat "$FAKE_SWARM_STATE/calls")" "" "HARNESS_SWARM=off never touches swarm"
rc="$(run_suite "$WT" unk README.md)"; assert_eq "$rc" 3 "file with no default command → 3"

echo "-- #618: a small suite runs locally (exit 3), a big one still goes to swarm"
: > "$FAKE_SWARM_STATE/calls"
rc="$(HARNESS_SWARM_LOCAL_MAX_SECS=60 run_suite "$WT" small test/test_ok.sh test/test_red.sh)"
assert_eq "$rc" 3 "2 files x 2s = 4s < 60s → 3 (run locally)"
assert_ok "the reason names the small suite" grep -q 'small suite (2 files' "$T/err"
assert_eq "$(cat "$FAKE_SWARM_STATE/calls")" "" "a small suite never touches swarm"
rc="$(HARNESS_SWARM_LOCAL_MAX_SECS=4 run_suite "$WT" edge test/test_ok.sh test/test_red.sh)"
assert_eq "$rc" 1 "estimate == ceiling (4s, 4s) → swarm (red file reported)"
rc="$(HARNESS_SWARM_LOCAL_MAX_SECS=60 HARNESS_SWARM_SECS_PER_FILE=40 run_suite "$WT" slowfiles test/test_ok.sh)"
assert_eq "$rc" 3 "1 file x 40s = 40s < 60s → 3 (the per-file estimate is a knob)"
rc="$(HARNESS_SWARM_LOCAL_MAX_SECS=60 HARNESS_SWARM_SECS_PER_FILE=70 run_suite "$WT" slowfiles2 test/test_ok.sh)"
assert_eq "$rc" 0 "1 file x 70s >= 60s → swarm"
rc="$(HARNESS_SWARM_LOCAL_MAX_SECS=junk run_suite "$WT" junk test/test_ok.sh)"
assert_eq "$rc" 3 "a non-numeric ceiling falls back to 60 → small → 3"
rc="$(HARNESS_SWARM_LOCAL_MAX_SECS=0 run_suite "$WT" always test/test_ok.sh)"
assert_eq "$rc" 0 "ceiling 0 = always swarm"
rc="$(env -u HARNESS_SWARM_LOCAL_MAX_SECS PATH="$FAKEBIN:$PATH" bash "$SUITE" "$WT" dflt test/test_ok.sh 2>/dev/null; echo $?)"
assert_eq "$rc" 3 "default ceiling (60s) sends a 1-file suite local"

echo "-- #801: the two knobs are decimal (a leading zero is not octal); a bad value warns once and falls back"
: > "$FAKE_SWARM_STATE/calls"
rc="$(HARNESS_SWARM_LOCAL_MAX_SECS=08 run_suite "$WT" oct8 test/test_ok.sh test/test_red.sh)"
assert_eq "$rc" 3 "LOCAL_MAX_SECS=08: 4s < 8s -> 3 (not 'value too great for base')"
assert_no "no arithmetic error for 08" grep -q 'too great for base' "$T/err"
rc="$(HARNESS_SWARM_LOCAL_MAX_SECS=09 run_suite "$WT" oct9 test/test_ok.sh test/test_red.sh)"
assert_eq "$rc" 3 "LOCAL_MAX_SECS=09 -> 3"
assert_eq "$(cat "$FAKE_SWARM_STATE/calls")" "" "08/09 never touch swarm"
rc="$(HARNESS_SWARM_LOCAL_MAX_SECS=060 HARNESS_SWARM_SECS_PER_FILE=40 run_suite "$WT" oct60 test/test_ok.sh)"
assert_eq "$rc" 3 "LOCAL_MAX_SECS=060 is 60, not 48: 40s < 60s -> 3"
assert_ok "060 reads as 60 in the reason" grep -q 'under 60s' "$T/err"
rc="$(HARNESS_SWARM_LOCAL_MAX_SECS=60 HARNESS_SWARM_SECS_PER_FILE=09 run_suite "$WT" pf9 test/test_ok.sh)"
assert_eq "$rc" 3 "SECS_PER_FILE=09 -> 9s < 60s -> 3 (no 'est: unbound variable')"
assert_no "no unbound variable for 09" grep -q 'unbound variable' "$T/err"
rc="$(HARNESS_SWARM_LOCAL_MAX_SECS=60 HARNESS_SWARM_SECS_PER_FILE=070 run_suite "$WT" pf70 test/test_ok.sh)"
assert_eq "$rc" 0 "SECS_PER_FILE=070 is 70 (not 56): 70s >= 60s -> swarm"
rm -f "$RUN_DIR"/swarmknob.*
rc="$(HARNESS_SWARM_LOCAL_MAX_SECS=-5 run_suite "$WT" neg test/test_ok.sh)"
assert_eq "$rc" 3 "a negative ceiling falls back to 60 -> 3"
assert_ok "the fallback warns, naming the knob" grep -q "WARN HARNESS_SWARM_LOCAL_MAX_SECS='-5' is not a non-negative integer" "$T/err"
rc="$(HARNESS_SWARM_LOCAL_MAX_SECS=-5 run_suite "$WT" neg2 test/test_ok.sh)"
assert_no "the same bad value warns only once" grep -q WARN "$T/err"
rc="$(HARNESS_SWARM_LOCAL_MAX_SECS=99999999999999999999 run_suite "$WT" huge test/test_ok.sh)"
assert_eq "$rc" 3 "an oversized ceiling falls back to 60 -> 3"

echo "-- #972: messages echo user-supplied values escaped, one line each; an empty test-file argument is a usage error"
: > "$FAKE_SWARM_STATE/calls"
rc="$(run_suite $'re\fpo\xe2\x80\xa8' job test/test_ok.sh)"
assert_eq "$rc" 2 "a worktree with a form feed / U+2028 that does not exist -> exit 2"
assert_eq "$(cat "$T/err")" 'swarm-suite: no such worktree: re\u000cpo\u2028' "…the message spells them \\u000c and \\u2028"
rm -f "$RUN_DIR"/swarmknob.*
rc="$(HARNESS_SWARM_LOCAL_MAX_SECS=$'5\f' run_suite "$WT" ffknob test/test_ok.sh)"
assert_ok "a knob with a form feed warns with it escaped" grep -qxF "swarm-suite: WARN HARNESS_SWARM_LOCAL_MAX_SECS='5\\u000c' is not a non-negative integer — using the default 60" "$T/err"
assert_eq "$(grep -c WARN "$T/err")" 1 "…on one line"
assert_no "…and no raw form feed on stderr" grep -q $'\f' "$T/err"
rc="$(HARNESS_SWARM=$'of\xe2\x80\xa8f\f' run_suite "$WT" ffoff test/test_ok.sh)"
assert_eq "$rc" 3 "HARNESS_SWARM with a U+2028 -> 3"
assert_ok "…its message escapes both" grep -qxF 'swarm-suite: HARNESS_SWARM=of\u2028f\u000c — run the suite locally' "$T/err"
rc="$(run_suite "$WT" nl $'a\nb.sh')"
assert_eq "$rc" 3 "a test path with a newline -> 3"
assert_eq "$(cat "$T/err")" 'swarm-suite: test path with a tab/newline: a\nb.sh — run the suite locally' "…one line, the newline spelled \\n"
rc="$(run_suite "$WT" tb $'a\tb.sh')"
assert_eq "$(cat "$T/err")" 'swarm-suite: test path with a tab/newline: a\tb.sh — run the suite locally' "a tab is spelled \\t"
rc="$(run_suite "$WT" ffpath $'README\f.md')"
assert_eq "$rc" 3 "a test path with no default command -> 3"
assert_eq "$(cat "$T/err")" 'swarm-suite: no default command for README\u000c.md (set HARNESS_SWARM_TEST_CMD) — run the suite locally' "…its form feed is escaped"
rc="$(run_suite "$WT" empty '')"
assert_eq "$rc" 2 "an empty test-file argument -> usage error, exit 2"
assert_ok "…the empty value is shown as ''" grep -qF "empty test-file argument ('')" "$T/err"
rc="$(run_suite "$WT" empty2 test/test_ok.sh '')"
assert_eq "$rc" 2 "…also after a real file"
assert_eq "$(cat "$FAKE_SWARM_STATE/calls")" "" "none of these touched swarm"
rc="$(run_suite '' empty3 test/test_ok.sh)"
assert_eq "$rc" 2 "an empty worktree -> 2"
assert_ok "…shown as ''" grep -qxF "swarm-suite: no such worktree: ''" "$T/err"

echo "-- config + prompts"
( unset_inherited_config; source "$HERE/../scripts/lib.sh" >/dev/null 2>&1; [[ "$HARNESS_SWARM" == auto ]] )
assert_eq "$?" 0 "HARNESS_SWARM defaults to auto"
assert_ok "HARNESS_SWARM is exported" grep -qE '^ +.*\bHARNESS_SWARM\b' "$HERE/../scripts/lib.sh"
assert_ok "README Configuration row" grep -q '^| `HARNESS_SWARM` | `auto` |' "$HERE/../docs/reference.md"
assert_ok "reference section" grep -q '^## Offloading tests to swarm' "$HERE/../docs/reference.md"
# #449: review's suite run is the ONLY full-suite run in the pipeline; lanes never offload one.
P="$HERE/../prompts/review.md"
assert_ok "review.md runs the suite through {{SWARM_SUITE}}" grep -q '{{SWARM_SUITE}}' "$P"
assert_ok "review.md: exit 3 → run the suite locally" grep -q '`3` not run on swarm' "$P"
for p in impl bug-fix resume; do
  assert_no "$p.md runs no suite through {{SWARM_SUITE}}" grep -q '{{SWARM_SUITE}}' "$HERE/../prompts/$p.md"
done

echo "-- drive.sh renders the helper + mode into the lane prompts"
(
  source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; make_env
  HARNESS_SWARM=auto; RUN_DIR="$T/run dir"   # a space: the rendered command must stay one argv
  launch_claude(){ :; }; ensure_checkout(){ :; }; ensure_safe(){ :; }; run_worktree_hook(){ :; }
  remove_worktree(){ :; }; default_branch(){ echo main; }; gh(){ return 1; }
  git(){ local a; case "$*" in *"worktree add"*) for a in "$@"; do [[ "$a" == "$WORKTREES_DIR"/* ]] && { mkdir -p "$a"; : > "$a/.git"; }; done;; esac; return 0; }   # #643: a real add leaves .git
  UNIT=main; SLUG=acme/widget; PROJECT=w; DESC=d; CHECKOUT="$T/checkout"; mkdir -p "$CHECKOUT"
  spawn_impl 7 "ISSUE 7 DONE"
  F="$WORKTREES_DIR/main-i7/.harness-task.md"
  assert_no "impl prompt: no unrendered {{SWARM token" grep -q '{{SWARM' "$F"
  assert_no "impl prompt runs no swarm suite (#449)" grep -q 'swarm-suite.sh' "$F"
  spawn_bug 8 fix
  assert_no "bug-fix prompt: no unrendered {{SWARM token" grep -q '{{SWARM' "$(bug_worktree acme/widget 8)/.harness-task.md"
  assert_no "bug-fix prompt runs no swarm suite (#449)" grep -q 'swarm-suite.sh' "$(bug_worktree acme/widget 8)/.harness-task.md"
  spawn_orch REVIEW 41 "REVIEW DONE"
  F="$(orch_worktree acme/widget 41)/.harness-task.md"
  assert_no "review prompt: no unrendered {{SWARM token" grep -q '{{SWARM' "$F"
  assert_ok "review prompt carries the fleet's mode" grep -q 'HARNESS_SWARM (`auto`)' "$F"
  # The rendered command, run as written, must reach the helper with the fleet's RUN_DIR intact.
  cmd="$(grep -m1 'swarm-suite.sh' "$F" | sed 's/^ *//; s/ "\$PWD".*//')"
  PATH="$FAKEBIN:$PATH" eval "$cmd \"\$WT\" rendered test/test_ok.sh" >/dev/null 2>&1
  assert_eq "$?" 0 "rendered {{SWARM_SUITE}} runs the helper"
  assert_ok "rendered command keeps the fleet's RUN_DIR (with a space)" test -f "$T/run dir/swarm/rendered/swarm.toml"
  finish
) || TESTS_FAIL=$((TESTS_FAIL+1))
finish
