#!/usr/bin/env bash
# test_hermetic_agy.sh — the fourth seam of test_hermetic.sh (#236, #240; #608: split out of it): the host's agy binary.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/hermetic_lib.sh"
# #610: every bare mktemp below lands in one private dir that goes with the test, so a run from a plain
# shell (not run.sh, which gives each test its own TMPDIR) leaves /tmp as it found it.
PRIVATE_TMP="$(mktemp -d)"; tmp_track "$PRIVATE_TMP"; export TMPDIR="$PRIVATE_TMP"
unset_inherited_config   # a direct run from inside a live lane (#541): its HARNESS_* config must not reach the probes below

# ── the host's agy binary is a FOURTH seam (#236) ──────────────────────────────────────────────
# uninstall.sh's remove_skills ends with `agy plugin uninstall harness-ralph` — agy's goal loop. Run
# by test_uninstall.sh against the host's real agy, the suite stripped that plugin off a live fleet
# host and every agy lane after it lost its loop. Both seams leak: agy found on PATH, and an
# inherited HARNESS_AGY_BIN (lib.sh:85 exports it from every fleet process) naming the real binary.
# Plant a tripwire on BOTH; it must never be called at all.
# The install side leaks the same way (#240): install.sh's check_prereqs / ensure_skills run
# `agy --version`, `agy plugin list` and `agy plugin install`, reached by test_install.sh directly and
# by test_update.sh / test_supervise.sh through update.sh (which sources install.sh). Each suite pins
# its own stub, so the tripwire log must come back EMPTY — not merely free of `plugin uninstall`.
for t in test_install.sh test_update.sh test_supervise.sh test_uninstall.sh; do
  [[ -f "$HERE/$t" ]] || continue
  TRIP="$(mktemp -d)"; : > "$TRIP/agy.log"
  printf '#!/usr/bin/env bash\necho "$*" >> %q\n' "$TRIP/agy.log" > "$TRIP/agy"; chmod +x "$TRIP/agy"
  PATH="$TRIP:$PATH" HARNESS_AGY_BIN="$TRIP/agy" bash "$HERE/$t" >/dev/null 2>&1
  assert_eq "$(cat "$TRIP/agy.log")" "" \
    "$t: the host's agy is never called (PATH or inherited HARNESS_AGY_BIN)"
done

finish
