#!/usr/bin/env bash
# run.sh — run every test_*.sh in this dir; non-zero exit if any fails.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE" || exit 1
# Blanket hermeticity guard. lib.sh takes STATE_DIR from the environment, and a pool worker exports
# its project's STATE_DIR to every child — so running this suite from inside a live agent session
# used to point every test's CONFIG / WORKTREES_DIR / CHECKOUTS_DIR at a REAL project's .harness/.
# Hand each test its own throwaway one BEFORE it can source lib.sh. Individual tests re-pin too
# (helpers.sh make_env) so a direct `bash test_foo.sh` is safe as well; test_hermetic.sh guards both.
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
# Same blanket guard, second seam: config lines are `: "${VAR:=…}"`, so an inherited HARNESS_* from
# the live fleet running this suite BEATS the fixture's own value. Pinning paths was not enough —
# drop the config vars too, before any test can read them. (helpers.sh only defines functions at
# top level, so sourcing it here has no other effect. Tests re-drop them via make_env.)
# By its absolute path (#333): release.sh gates with `cd <tree> && bash test/run.sh`, and a
# BASH_SOURCE-relative path, read after the cd above, named test/test/helpers.sh — the guard was
# never defined, so every fleet variable reached every test. A guard that cannot load stops the run.
source "$HERE/helpers.sh" || { echo "run.sh: cannot load $HERE/helpers.sh — not running the suite unguarded" >&2; exit 1; }
unset_inherited_config
# The fleet's own tmux server is no test's (#333): a bare `tmux` in a test must never reach the
# server every co-resident fleet runs on.
unset TMUX TMUX_PANE
# One locale for every run (#333): a fleet worker runs under LANG=C, where grep reads the adapters'
# multibyte pane regexes as bytes. The suite's expectations are UTF-8's; test_cli_locale.sh covers C.
unset LC_ALL; export LANG=C.UTF-8 LC_CTYPE=C.UTF-8
export HARNESS_GH_RATE_GUARD=0   # #183: no test probes the real GitHub budget; test_ghrate.sh opts in
export HARNESS_INIT_SEED=0       # #432: no non-interactive init seeds real labels; test_init.sh opts in against a stub gh
# Default INT/HUP/QUIT for every test (#553): run from a background or nohup context (the auto-release
# gate) this shell has them IGNORED, and an ignored-at-start signal is inherited by every test and cannot
# be trapped by it — test_headless_attach.sh's Ctrl-C detach hung forever on exactly that. DEFSIG restores
# the defaults a foreground run has; test_signal_defaults.sh covers it.
default_signals_prefix
# Real-Windows side effects (#492): on a Windows host a test that registers a supervise/web unit reaches the REAL Task
# Scheduler (schtasks.exe), and an install test the real winget — the first full-suite run on winsma left five
# `Harness\harness-*-<hash>` tasks behind and tripped the before/after guard. Point both at recording stubs for the whole run;
# a test that fakes either itself sets its own, as before. Not on Linux, where neither tool exists and the doctor tests
# rely on an unset HARNESS_SCHTASKS to see a missing one. host_is_windows honours HARNESS_PLATFORM=windows|posix.
if host_is_windows; then
  mkdir -p "$TMPROOT/stubs"
  printf '#!/usr/bin/env bash\necho "schtasks $*" >> "%s/stubs/schtasks.log"\ncase "$1" in /Query|//Query) exit 1;; esac\nexit 0\n' "$TMPROOT" > "$TMPROOT/stubs/schtasks"
  printf '#!/usr/bin/env bash\necho "winget $*" >> "%s/stubs/winget.log"\nexit 0\n' "$TMPROOT" > "$TMPROOT/stubs/winget"
  chmod +x "$TMPROOT/stubs/schtasks" "$TMPROOT/stubs/winget"
  export HARNESS_SCHTASKS="$TMPROOT/stubs/schtasks" HARNESS_WINGET="$TMPROOT/stubs/winget"
fi
# Per-test wall-clock cap (#492): HARNESS_TEST_TIMEOUT=<seconds> ends a test that hangs (rc 124, reported as TIMEOUT)
# instead of blocking the whole run — on a Windows host a hung child can otherwise stall the suite for hours. Unset or 0:
# no cap, as before. The run ends with one summary line per failing test and a count, so a long Windows run reads in
# one place which tests were red (the lane compares that list against the same commit on Linux).
TCAP=(); if [[ "${HARNESS_TEST_TIMEOUT:-0}" =~ ^[1-9][0-9]*$ ]] && command -v timeout >/dev/null 2>&1; then TCAP=(timeout -k 10 "$HARNESS_TEST_TIMEOUT"); fi
rc=0; ran=0; FAILED=()
for t in test_*.sh test_*.py; do
  [[ -e "$t" ]] || continue
  echo "== $t =="
  export STATE_DIR="$TMPROOT/$t/.harness"
  mkdir -p "$STATE_DIR/worktrees" "$STATE_DIR/checkouts" "$STATE_DIR/run/claims"
  # Host root too (lib.sh:86): it is NOT derived from STATE_DIR, and its poller registry is SHARED by
  # every co-resident fleet — a fixture entry left there aborts a real `harness start` on a bogus
  # prefix collision. Give each test its own host root as well.
  # All four: lib.sh:87-88 and :99 prefer an INHERITED HARNESS_POLLER_DIR / HARNESS_SNAPSHOTS_DIR /
  # HARNESS_FLEETS_DIR over the HARNESS_HOME a test sets for itself, and :89/:100 export them from
  # every fleet process — so pinning HARNESS_HOME alone leaves a test's own isolation defeated.
  # HARNESS_FLEETS_DIR is the same hazard one notch worse: the host fleet registry is not merely READ
  # by a co-resident fleet, its entries are DELETED by `doctor --fix` (test_doctor.sh runs exactly
  # that), so an unpinned suite can strip a live sibling fleet's prefix reservation off the real host.
  # One helper, one list (helpers.sh pin_host_home, #541): HARNESS_HOME, the fleet/poller/snapshot dirs,
  # the user-service unit dirs and tools, and the user bus — also what each test's own HARNESS_HOME goes through.
  pin_host_home "$TMPROOT/$t/host"
  mkdir -p "$HARNESS_POLLER_DIR/registry" "$HARNESS_SNAPSHOTS_DIR"
  # Temp root too (#294): every bare mktemp / tempfile.mkdtemp() a test makes lands here rather than
  # in the host's /tmp, and the whole per-test subtree goes as soon as the test ends — so a test that
  # forgets its own cleanup leaks into nothing, and peak use is one test's worth, not the suite's.
  export TMPDIR="$TMPROOT/$t/tmp"; mkdir -p "$TMPDIR"
  export HARNESS_TMP_ROOT="$TMPDIR"   # #610: the lane TMPDIR a launch makes (lane_tmpdir) goes with the test too
  ran=$((ran+1))
  case "$t" in *.py) "${TCAP[@]}" "${DEFSIG[@]}" python3 "$t";; *) "${TCAP[@]}" "${DEFSIG[@]}" bash "$t";; esac
  trc=$?
  if (( trc != 0 )); then rc=1; FAILED+=("$t"); (( trc == 124 )) && echo "TIMEOUT: $t ran past HARNESS_TEST_TIMEOUT=${HARNESS_TEST_TIMEOUT}s"; fi
  rm -rf "${TMPROOT:?}/$t"
done
echo "== run.sh: $((ran-${#FAILED[@]}))/$ran test files passed =="
for t in "${FAILED[@]}"; do echo "FAILED: $t"; done
exit $rc
