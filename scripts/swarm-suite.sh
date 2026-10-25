#!/usr/bin/env bash
# swarm-suite.sh <worktree> <job-name> [test files...] — #202: run a lane's FULL suite as a swarm job.
#
# The lane prompts call this instead of describing the steps. One shard per test file: swarm runs
# them on the coordinator and spare workers, the merge lists the failing files, and the caller keeps
# its "NO NEW FAILURES vs baseline" bar exactly as before — only where the suite runs changes.
#
# Exit codes (the whole contract the prompts read):
#   0  green — every file passed
#   1  red   — the failing files are printed (file, status, the shard's out dir holding output.log)
#   3  not run here — swarm missing, HARNESS_SWARM != auto, a timeout, or nothing to shard. The
#      caller runs the suite LOCALLY, exactly as it would on a host without swarm.
#
# The job dir lives under $RUN_DIR/swarm/<name>, never in the worktree: the worktree IS the swarm
# `workdir` (tarred at submit), and the lane's diff must not grow files it did not write.
#
# Knobs (env): HARNESS_SWARM (auto|off), HARNESS_SWARM_TIMEOUT (seconds `swarm wait` gets, default
# 1800), HARNESS_SWARM_TEST_CMD (per-file command with {file} and optional {junit}; default: bash for
# .sh, python3 for a .py with a __main__ block, pytest for any other .py).
# The swarm.toml contract: https://github.com/VocanicZ/swarm/blob/main/skill/SKILL.md
set -uo pipefail

SWARM_BIN="${SWARM_BIN:-swarm}"
unavailable(){ echo "swarm-suite: $* — run the suite locally" >&2; exit 3; }

[[ $# -ge 2 ]] || { echo "usage: swarm-suite.sh <worktree> <job-name> [test files...]" >&2; exit 2; }
WT="$1"; NAME="$2"; shift 2
[[ "${HARNESS_SWARM:-auto}" == auto ]] || unavailable "HARNESS_SWARM=${HARNESS_SWARM}"
command -v "$SWARM_BIN" >/dev/null 2>&1 || unavailable "swarm not on PATH"
[[ -d "$WT" ]] || { echo "swarm-suite: no such worktree: $WT" >&2; exit 2; }
WT="$(cd "$WT" && pwd)"

# swarm job names must match [A-Za-z0-9][A-Za-z0-9._-]* and must not end in .prev.
NAME="$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^[^A-Za-z0-9]*//; s/\.prev$/-prev/')"
[[ -n "$NAME" ]] || { echo "swarm-suite: job name has no usable characters" >&2; exit 2; }

TEST_CMD="${HARNESS_SWARM_TEST_CMD:-}"
[[ "$TEST_CMD" != *"'''"* ]] || unavailable "HARNESS_SWARM_TEST_CMD contains ''' (cannot embed in swarm.toml)"

# No files named → discover the repo's test files. Without a custom command only the kinds the
# default command knows how to run are picked up.
if [[ $# -eq 0 ]]; then
  pat='(^|/)(test_[^/]*|[^/]*_test)\.(sh|py)$'
  [[ -n "$TEST_CMD" ]] && pat='(^|/)(test_[^/]*|[^/]*_test)\.[^/.]+$|(^|/)[^/]*\.(test|spec)\.[^/]+$'
  # -z: plain ls-files C-quotes any path with a space or quote in it.
  mapfile -d '' -t FILES < <(git -C "$WT" ls-files -z 2>/dev/null | grep -zE "$pat")
else
  FILES=("$@")
fi
[[ ${#FILES[@]} -gt 0 ]] || unavailable "no test files to shard"
if [[ -z "$TEST_CMD" ]]; then
  for f in "${FILES[@]}"; do
    case "$f" in *.sh|*.bash|*.py) ;; *) unavailable "no default command for $f (set HARNESS_SWARM_TEST_CMD)";; esac
  done
fi

# shard_id <path> — a reversible id in swarm's [A-Za-z0-9._-]+: [A-Za-z0-9.-] stay, every other
# byte (including `_` itself) becomes `_` + 3 octal digits. Octal, not hex, because the shard
# decodes it with POSIX `printf %b` (`\0NNN`), which dash's printf has and `\xHH` is not.
shard_id(){ local s="$1" out="" c i LC_ALL=C
  for ((i = 0; i < ${#s}; i++)); do c="${s:i:1}"
    if [[ "$c" == [A-Za-z0-9.-] ]]; then out+="$c"; else out+="$(printf '_%03o' "'$c")"; fi
  done
  printf '%s' "$out"; }

if [[ -z "${RUN_DIR:-}" ]]; then
  RUN_DIR="${STATE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/run"
fi
JOB="$RUN_DIR/swarm/$NAME"
rm -rf "$JOB"; mkdir -p "$JOB" || unavailable "cannot create job dir $JOB"

# The id→path map (one `id<TAB>path` line per shard, in split order) and the id list split prints.
declare -A seen=()
: > "$JOB/shards.tsv"; : > "$JOB/shards.ids"
for f in "${FILES[@]}"; do
  [[ "$f" == *$'\n'* || "$f" == *$'\t'* ]] && unavailable "test path with a tab/newline: $f"
  f="${f#./}"; [[ -n "${seen[$f]:-}" ]] && continue; seen[$f]=1
  id="$(shard_id "$f")"
  printf '%s\t%s\n' "$id" "$f" >> "$JOB/shards.tsv"; printf '%s\n' "$id" >> "$JOB/shards.ids"
done

# toml_str — a TOML basic string (the workdir is the only value that comes from outside).
toml_str(){ local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }

# The test command one shard runs, as POSIX sh with the file in "$f" and the JUnit target in a temp
# name the shard moves into place.
if [[ -n "$TEST_CMD" ]]; then
  cmd="${TEST_CMD//\{file\}/\"\$f\"}"; cmd="${cmd//\{junit\}/\"\$o/.junit.tmp\"}"
else
  cmd='case "$f" in
  *.py) if grep -q __main__ "$f"; then python3 "$f"; else python3 -m pytest -q "$f" --junitxml="$o/.junit.tmp"; fi ;;
  *) bash "$f" ;;
esac'
fi

# run — swarm's resumable-shard contract: the ONLY state is {out}, every file is written temp-then-mv,
# `status` is written last (so a shard stopped mid-test simply reruns that file), and it exits 0
# whether the tests passed or not — a red test file is a COMPLETE shard; non-zero would be retried.
# Runs with cwd = the unpacked worktree, as the `swarm` user on a worker, so it touches nothing
# outside it and {out}.
cat > "$JOB/swarm.toml" <<EOF
name    = $(toml_str "$NAME")
workdir = $(toml_str "$WT")
split   = "cat shards.ids"
merge   = "sh merge.sh {outs}"
run     = '''
set -u
o={out}
[ -f "\$o/status" ] && exit 0
mkdir -p "\$o"
f=\$(printf %b "\$(printf %s {shard} | sed 's/_/\\\\0/g')")
printf '%s\\n' "\$f" > "\$o/.file.tmp" && mv "\$o/.file.tmp" "\$o/file"
rm -f "\$o/.junit.tmp"
rc=0
( $cmd
) > "\$o/.output.tmp" 2>&1 < /dev/null || rc=\$?
mv "\$o/.output.tmp" "\$o/output.log"
if [ -s "\$o/.junit.tmp" ]; then mv "\$o/.junit.tmp" "\$o/junit.xml"; else
  n=\$(printf %s "\$f" | sed 's/&/\\&amp;/g; s/</\\&lt;/g; s/>/\\&gt;/g; s/"/\\&quot;/g')
  fl=0; fx=''; [ \$rc -eq 0 ] || { fl=1; fx="<failure message=\\"exit \$rc\\"/>"; }
  printf '<?xml version="1.0"?>\\n<testsuite name="%s" tests="1" failures="%s"><testcase classname="swarm" name="%s">%s</testcase></testsuite>\\n' "\$n" \$fl "\$n" "\$fx" > "\$o/.junit.tmp"
  mv "\$o/.junit.tmp" "\$o/junit.xml"
fi
s=pass; [ \$rc -eq 0 ] || s=fail
printf '%s\\n' \$s > "\$o/.status.tmp" && mv "\$o/.status.tmp" "\$o/status"
exit 0
'''
EOF

# merge — on the coordinator, in the job dir: failures.txt is one `file<TAB>status<TAB>out` line per
# failing (or never-reported) file; exit 1 when it is non-empty, which `swarm wait` reports as 1.
cat > "$JOB/merge.sh" <<'EOF'
#!/bin/sh
: > failures.txt.tmp; n=0
for o in "$@"; do
  n=$((n + 1))
  st=$(cat "$o/status" 2>/dev/null || echo missing)
  f=$(cat "$o/file" 2>/dev/null || echo "$o")
  [ "$st" = pass ] || printf '%s\t%s\t%s\n' "$f" "$st" "$o" >> failures.txt.tmp
done
mv failures.txt.tmp failures.txt
nf=$(wc -l < failures.txt | tr -d ' ')
printf '%s files, %s failing\n' "$n" "$nf" > summary.txt.tmp && mv summary.txt.tmp summary.txt
[ "$nf" -eq 0 ]
EOF

"$SWARM_BIN" submit "$JOB" >&2 || unavailable "swarm submit $JOB failed"
"$SWARM_BIN" wait "$NAME" --timeout "${HARNESS_SWARM_TIMEOUT:-1800}" >&2; rc=$?
case $rc in
  0) cat "$JOB/summary.txt" 2>/dev/null || echo "swarm job $NAME merged green"; exit 0 ;;
  1) if [[ -s "$JOB/failures.txt" ]]; then
       cat "$JOB/summary.txt" 2>/dev/null; echo "failing files (file, status, shard out dir with output.log):"
       cat "$JOB/failures.txt"; exit 1
     fi
     # Failed with no failing file listed: a shard ran out of retries or the merge never ran —
     # an infrastructure failure, not a test verdict.
     unavailable "swarm job $NAME failed without a failing-file list (see: swarm status $NAME)" ;;
  124) "$SWARM_BIN" cancel "$NAME" >&2 || true
       unavailable "swarm job $NAME timed out after ${HARNESS_SWARM_TIMEOUT:-1800}s (cancelled)" ;;
  *) unavailable "swarm wait $NAME exited $rc" ;;
esac
