#!/usr/bin/env bash
# test_rtdd.sh — the rtdd contract in the lane prompts. rtdd is OPTIONAL: every prompt that
# uses it must also keep the full-suite path, must not treat an empty selection as green, and
# must never seed inside a lane (one full instrumented run per lane defeats the point).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }

for p in impl bug-fix resume; do
  P="$HERE/../prompts/$p.md"
  assert "$p.md uses rtdd run"                "grep -q 'rtdd run' '$P'"
  assert "$p.md keys off .rtdd/map.jsonl"     "grep -q '\.rtdd/map\.jsonl' '$P'"
  assert "$p.md keeps the full-suite path"    "grep -qi 'full suite' '$P'"
  assert "$p.md: empty selection not green"   "grep -qi 'EMPTY selection is NOT green' '$P'"
  assert "$p.md handles an unseeded repo"     "grep -q 'rtdd init && rtdd seed' '$P'"
  # Was `grep -qi 'exit'` — three unrelated hits, passed with the whole paragraph deleted.
  assert "$p.md reads exit 2 as the no-adapter refusal, not any error" \
    "grep -q 'EXITS 2' '$P' || grep -q 'exiting 2' '$P'"
  assert "$p.md handles rtdd errors that are NOT the refusal" \
    "grep -qiE 'any other rtdd error|other rtdd error' '$P'"
  assert "$p.md handles a host with no rtdd binary" \
    "grep -qE 'command not found|NOT on PATH' '$P'"
  assert "$p.md names the real install command" "grep -q 'npx -y github:VocanicZ/rtdd' '$P'"
  # The loophole the audit found: coverage is execution, not assertion. Every prompt must demand a
  # test that FAILS without the change, or "uncovered report clear" is satisfiable by an
  # assertion-free test that merely executes the new lines.
  assert "$p.md requires a test that fails without the change" \
    "grep -qiE 'FAILS WITHOUT|FAILS ON THE UNFIXED' '$P'"
  # A repo with no CI has nothing server-side running the whole suite; the lane must run it itself.
  assert "$p.md covers the no-CI-configured case" \
    "grep -q 'NO CHECKS CONFIGURED' '$P'"
  # Seeding must not commit per-run state into someone else's repo.
  assert "$p.md keeps per-run state out of the seed commit" \
    "grep -q 'meta.json' '$P'"
  # rtdd REPLACES the full-suite baseline, but the test obligation survives it: an uncovered
  # changed line is an untested line, and that is what the prompt must say.
  assert "$p.md requires uncovered lines be covered" "grep -qi 'UNCOVERED' '$P'"
  assert "$p.md forbids weakening a test to go green" "grep -qi 'never delete, skip, or weaken' '$P'"
done

# impl/bug-fix measure against the base, not the branch (a lane's branch carries its own edits).
for p in impl bug-fix resume; do
  assert "$p.md passes --base" "grep -q -- '--base origin/<default-branch>' '$HERE/../prompts/$p.md'"
done

# Installer: optional, best-effort, never fatal.
I="$HERE/../install.sh"
# Call site, not just the variable: ensure_rtdd used to live inside ensure_skills, where the test
# suite reached it and performed a real network install.
assert "install.sh defines ensure_rtdd"  "grep -q '^ensure_rtdd()' '$I'"
assert "install.sh calls it from main, NOT from ensure_skills" \
  "awk '/^ensure_skills\\(\\)/{f=1} /^}/{f=0} f&&/ensure_rtdd/{bad=1} END{exit bad}' '$I'"
assert "install.sh npx call cannot hang forever" \
  "grep -q 'timeout .*npx' '$I'"
assert "install.sh npx call cannot block on a git prompt" \
  "grep -q 'GIT_TERMINAL_PROMPT=0' '$I'"
# Never a piped installer: a dropped connection runs a truncated script, and the URL would be an
# overridable input to a shell. Upstream's npx installer verifies the release it downloads.
assert "install.sh does not pipe a fetch into a shell" \
  "! grep -vE '^[[:space:]]*#' '$I' | grep -qE 'curl[^|]*\\|[[:space:]]*(sh|bash)'"
assert "install.sh skips an existing rtdd" "grep -q 'need rtdd' '$I'"
# Every update ff-pulls prompts whose test loop IS rtdd, so a host that predates it must get the
# binary without having to remember --with-skills.
U="$HERE/../update.sh"
assert "update.sh ensures rtdd"           "grep -q 'ensure_rtdd' '$U'"
assert "update.sh ensures it unconditionally" \
  "awk '/^if \\(\\( WITH_SKILLS \\)\\); then/{f=1} /ensure_rtdd/{if(!f) found=1} END{exit !found}' '$U'"

# README: documented section + the prereq row marks it optional.
R="$HERE/../README.md"
assert "README has a Test selection section" "grep -qE '^### Test selection \(rtdd\)' '$R'"
assert "README prereq row names rtdd the lane test loop" "grep -E '^\| \`rtdd\`' '$R' | grep -qi 'lane test loop'"

# ── this repo's own rtdd setup ────────────────────────────────────────────────────────────
# Harness drives itself, so the same selection the prompts mandate has to work HERE. No shipped
# adapter instruments bash, so the repo carries its own: the declaration plus the runner that
# records per-test coverage from bash's xtrace. Guard the pieces that make it execution-derived.
A="$HERE/../.rtdd/adapters/bash.yaml"
RUNNER="$HERE/../scripts/rtdd-bash-runner.py"
M="$HERE/../.rtdd/map.jsonl"
assert "bash adapter declared"            "[[ -f '$A' ]]"
assert "adapter records real coverage"    "grep -q '^coverage: sqlite' '$A'"
# `coverage: sqlite` IS the not-static claim (rtdd rejects coverage:none without selection:static),
# so assert the positive and that doctor-visible fidelity is what the README promises.
assert "adapter declares no static selection" "! grep -qE '^selection:' '$A'"
assert "adapter points at the runner"     "grep -q 'rtdd-bash-runner.py' '$A'"
# Must be in full_escalate specifically — the path also appears in seed/subset/list, so a bare
# grep for it passed even with full_escalate deleted entirely.
assert "runner edit escalates to the full suite" \
  "grep -E '^full_escalate:' '$A' | grep -q 'scripts/rtdd-bash-runner.py'"
assert "adapter edit escalates to the full suite" \
  "grep -E '^full_escalate:' '$A' | grep -q '.rtdd/adapters/bash.yaml'"
assert "runner exists"                    "[[ -f '$RUNNER' ]]"
# Load-bearing version: the trace has to be WIRED, not merely mentioned in a docstring.
assert "runner actually sets BASH_XTRACEFD in the child env" \
  "grep -q 'BASH_XTRACEFD=21 bash' '$RUNNER'"
assert "runner turns on xtrace for every child shell" \
  "grep -q 'SHELLOPTS=xtrace' '$RUNNER'"
# Parity with test/run.sh's hermeticity pins, checked per-variable rather than by one sample.
for v in STATE_DIR HARNESS_HOME HARNESS_POLLER_DIR HARNESS_SNAPSHOTS_DIR HARNESS_FLEETS_DIR; do
  assert "runner pins \$v like run.sh does" "grep -q '$v' '$RUNNER'"
done
# The selfcheck pins numbits, the repo-path filter, the executed-vs-read attribution rule, and
# that trace lines never reach the report. If it passes, those four are not silently broken.
assert "runner self-check passes"         "python3 '$RUNNER' --selfcheck >/dev/null"

# The map is committed — that is what stops every clone and every worktree from re-seeding.
assert "map is committed"                 "[[ -f '$M' ]]"
assert "map has a row per test file"      "[[ \$(wc -l < '$M') -ge \$(ls '$HERE'/test_*.sh '$HERE'/test_*.py | wc -l) ]]"
assert "map rows name this adapter"       "grep -q '\"a\":\"bash\"' '$M'"
assert "map covers a prompt, not just code" "grep -q 'prompts/impl.md' '$M'"
assert "map union-merges across lanes"    "grep -q 'map.jsonl merge=union' '$HERE/../.gitattributes'"

echo "── rtdd prompt contract ok"
