#!/usr/bin/env bash
# test_swarm.sh — #202: scripts/swarm-suite.sh offloads a lane's full suite to swarm, and every path
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
SUITE="$HERE/../scripts/swarm-suite.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"; tmp_cleanup' EXIT
export RUN_DIR="$T/run"; unset HARNESS_SWARM HARNESS_SWARM_TEST_CMD HARNESS_SWARM_TIMEOUT HARNESS_SWARM_PACK
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
        rc = subprocess.run(["sh", "-c", r], cwd=work).returncode
        assert rc == 0, f"run exited {rc} for {i}"   # a red test file is still a COMPLETE shard
        # resume contract: a restart on a finished out must be a no-op
        assert subprocess.run(["sh", "-c", r], cwd=work).returncode == 0
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

echo "-- custom per-file command"
rc="$(HARNESS_SWARM_TEST_CMD='test -f {file}' run_suite "$WT" custom test/test_ok.sh test/test_red.sh)"
assert_eq "$rc" 0 "HARNESS_SWARM_TEST_CMD replaces the default command"

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

echo "-- config + prompts"
( unset_inherited_config; source "$HERE/../scripts/lib.sh" >/dev/null 2>&1; [[ "$HARNESS_SWARM" == auto ]] )
assert_eq "$?" 0 "HARNESS_SWARM defaults to auto"
assert_ok "HARNESS_SWARM is exported" grep -qE '^ +.*\bHARNESS_SWARM\b' "$HERE/../scripts/lib.sh"
assert_ok "README Configuration row" grep -q '^| `HARNESS_SWARM` | `auto` |' "$HERE/../docs/reference.md"
assert_ok "reference section" grep -q '^## Offloading tests to swarm' "$HERE/../docs/reference.md"
for p in impl bug-fix resume review; do
  P="$HERE/../prompts/$p.md"
  assert_ok "$p.md runs the suite through {{SWARM_SUITE}}" grep -q '{{SWARM_SUITE}}' "$P"
  assert_ok "$p.md: exit 3 → run the suite locally" grep -q '`3` not run on swarm' "$P"
done
for p in impl bug-fix; do
  assert_ok "$p.md keeps the local FULL-SUITE BAR" grep -q 'THE FULL-SUITE BAR, referenced above: run the full suite BEFORE your first edit' "$HERE/../prompts/$p.md"
  assert_ok "$p.md keeps NO NEW FAILURES vs baseline" grep -q 'NO NEW' "$HERE/../prompts/$p.md"
done
assert_ok "resume.md keeps the local baseline worktree" grep -q 'git worktree add /tmp/hz-baseline-{{ISSUE}}' "$HERE/../prompts/resume.md"

echo "-- drive.sh renders the helper + mode into the lane prompts"
(
  source "$HERE/../scripts/lib.sh"; source "$HERE/../scripts/drive.sh"; make_env
  HARNESS_SWARM=auto; RUN_DIR="$T/run dir"   # a space: the rendered command must stay one argv
  launch_claude(){ :; }; ensure_checkout(){ :; }; ensure_safe(){ :; }; run_worktree_hook(){ :; }
  remove_worktree(){ :; }; default_branch(){ echo main; }; gh(){ return 1; }
  git(){ local a; case "$*" in *"worktree add"*) for a in "$@"; do [[ "$a" == "$WORKTREES_DIR"/* ]] && mkdir -p "$a"; done;; esac; return 0; }
  UNIT=main; SLUG=acme/widget; PROJECT=w; DESC=d; CHECKOUT="$T/checkout"; mkdir -p "$CHECKOUT"
  spawn_impl 7 "ISSUE 7 DONE"
  F="$WORKTREES_DIR/main-i7/.harness-task.md"
  assert_no "impl prompt: no unrendered {{SWARM token" grep -q '{{SWARM' "$F"
  assert_ok "impl prompt carries the fleet's mode" grep -q 'HARNESS_SWARM=`auto`' "$F"
  # The rendered command, run as written, must reach the helper with the fleet's RUN_DIR intact.
  cmd="$(grep -m1 'swarm-suite.sh' "$F" | sed 's/^ *//; s/ <worktree>.*//')"
  PATH="$FAKEBIN:$PATH" eval "$cmd \"\$WT\" rendered test/test_ok.sh" >/dev/null 2>&1
  assert_eq "$?" 0 "rendered {{SWARM_SUITE}} runs the helper"
  assert_ok "rendered command keeps the fleet's RUN_DIR (with a space)" test -f "$T/run dir/swarm/rendered/swarm.toml"
  spawn_bug 8 fix
  assert_no "bug-fix prompt: no unrendered {{SWARM token" grep -q '{{SWARM' "$(bug_worktree acme/widget 8)/.harness-task.md"
  spawn_orch REVIEW 41 "REVIEW DONE"
  assert_no "review prompt: no unrendered {{SWARM token" grep -q '{{SWARM' "$(orch_worktree acme/widget 41)/.harness-task.md"
  finish
) || TESTS_FAIL=$((TESTS_FAIL+1))
finish
