#!/usr/bin/env bash
# guards.sh — #1059: the always-run guard set. A guard test reads the whole repo statically (every HARNESS_* has a docs row, every
# prompt label is a known label, every tmux call goes through the session seam…), so rtdd's coverage-based Rounds 1 and 2 never
# select it for a change that merely ADDS a variable, a script or a prompt label — and the release gate, the only full-suite run,
# was first to see the red (#682 #687 #827 #841 #1025 #1053 #1055 …), holding the release 30 minutes to 3 hours each time.
#
# A test joins the set by carrying the header line `# rtdd: always` in its first 15 lines (a .sh or .py test file): the only input
# of such a test is the repo tree, and it must stay fast (the whole set under 60s; test_guard_set.sh asserts the cap). Nothing
# else to register.
#
#   bash test/guards.sh          run the set (run.sh's isolation and guards), print the wall time; exit non-zero on a red
#   bash test/guards.sh list     print the test files in the set, one per line
#
# A lane runs it with Round 1, whatever rtdd selects, before it opens a PR (prompts/_rtdd.md). It is not the full suite: the
# owner rule "full suite once, at PRD review" stands.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# guard_set_files — the marked test files in this directory, sorted, one basename per line.
guard_set_files(){ local f
  for f in "$HERE"/test_*.sh "$HERE"/test_*.py; do [[ -f $f ]] || continue
    head -n 15 "$f" | grep -qE '^#[[:space:]]*rtdd:[[:space:]]*always[[:space:]]*$' && basename "$f"
  done | sort; return 0; }

case "${1:-run}" in
  list) guard_set_files;;
  run)
    mapfile -t files < <(guard_set_files)
    (( ${#files[@]} )) || { echo "guards.sh: no test carries '# rtdd: always' — nothing to run" >&2; exit 1; }
    # Same rule as any host test run (#649): a private tmux home, and no inherited server.
    if [[ -z ${TMUX_TMPDIR:-} || ! -d ${TMUX_TMPDIR:-/nonexistent} ]]; then
      TMUX_TMPDIR="$(mktemp -d)"; export TMUX_TMPDIR; trap 'rm -rf "$TMUX_TMPDIR"' EXIT
    fi
    unset TMUX TMUX_PANE
    start=$SECONDS
    bash "$HERE/run.sh" "${files[@]}"; rc=$?
    echo "guard set: ${#files[@]} files, $((SECONDS-start))s, $( ((rc==0)) && echo green || echo RED )"
    exit $rc;;
  *) echo "usage: guards.sh [run|list]" >&2; exit 2;;
esac
