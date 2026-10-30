#!/usr/bin/env bash
# test_rtdd.sh — the rtdd v0.3 contract in the lane prompts (#187). rtdd is OPTIONAL: every prompt
# that uses it keeps the full-suite path, treats an empty selection as not green, and defers the
# details to the user-level `rtdd` skill. The rtdd text lives in ONE partial, prompts/_rtdd.md.
# Prompts are rendered to files and grepped from files: their bodies contain backticks, which would
# execute if interpolated into a `bash -c` herestring.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
PR="$HERE/../prompts"

echo "-- render expands {{> partial}} from the template's dir, keys included"
T="$(mktemp -d)"
printf 'head\n{{> _p.md}}\ntail {{K}}\n' > "$T/host.md"
printf 'part {{K}}\n' > "$T/_p.md"
render "$T/host.md" K=v > "$T/out"
assert "partial expanded in place, its own line, keys substituted in it" \
  "[[ \"\$(cat '$T/out')\" == \$'head\npart v\ntail v' ]]"
printf 'part {{K}}' > "$T/_p.md"   # no final newline: still its own line
render "$T/host.md" K=v > "$T/out"
assert "partial with no final newline does not swallow the next line" \
  "[[ \"\$(cat '$T/out')\" == \$'head\npart v\ntail v' ]]"
rm "$T/_p.md"; render "$T/host.md" K=v > "$T/out"
assert "missing partial left as its directive, prompt not emptied" \
  "[[ \"\$(cat '$T/out')\" == \$'head\n{{> _p.md}}\ntail v' ]]"
rm -rf "$T"

echo "-- the rtdd text has one copy"
assert "_rtdd.md names the v0.3 command" "grep -q 'rtdd which --base origin/<default-branch>' '$PR/_rtdd.md'"
for p in impl bug-fix resume; do
  assert "$p.md includes the partial"            "grep -qx '{{> _rtdd.md}}' '$PR/$p.md'"
  assert "$p.md keeps no copy of its own"        "! grep -q 'NOT on PATH' '$PR/$p.md'"
done

echo "-- rendered lane prompts"
for p in impl bug-fix resume; do
  R="$RUN_DIR/$p.txt"
  render "$PR/$p.md" ISSUE=42 SLUG=acme/widget PROJECT=w DESC=d OWNER=acme SPEC= BRANCH=issue/42 \
    PROMISE='ISSUE 42 DONE' LABEL_READY=ready LABEL_WORKING=agent-working LABEL_PAUSED=agent-paused \
    LABEL_BUG=bug LABEL_BUG_TRIAGED=bug-triaged HANDOFF= SWARM=auto SWARM_SUITE="$(swarm_suite_cmd)" \
    HANDOFF_SKILL="$(cli_skill handoff)" SUBAGENT="$(cli_subagent "$RUN_DIR" "$RUN_DIR" "$RUN_DIR/NAME.md")" > "$R"
  assert "$p: no unrendered {{ token"            "! grep -q '{{' '$R'"
  assert "$p: runs rtdd which against the base"  "grep -q 'rtdd which --base origin/<default-branch>' '$R'"
  assert "$p: Round 1 then Round 2"              "grep -q 'Round 1' '$R' && grep -q 'Round 2' '$R'"
  assert "$p: full suite once at the end (Round 3)" "grep -q 'Round 3' '$R'"
  assert "$p: rounds run under the project's own test command" "grep -q \"project's OWN test command\" '$R'"
  assert "$p: reads untested"                    "grep -q '\`untested\`' '$R'"
  assert "$p: never blocks on rtdd"              "grep -q 'Never block on' '$R'"
  assert "$p: missing/erroring rtdd → full suite" "grep -qE 'Missing, older than v0.3 .*erroring → FULL-SUITE BAR' '$R'"
  assert "$p: names the FULL-SUITE BAR it points at" "grep -q 'THE FULL-SUITE BAR, referenced above' '$R'"
  assert "$p: empty selection is not green"      "grep -q 'Both EMPTY is NOT' '$R'"
  assert "$p: names the real install command"    "grep -q 'npx -y github:VocanicZ/rtdd' '$R'"
  assert "$p: init only to create .rtdd/config.yaml" "grep -q 'NO \`.rtdd/config.yaml\` → \`rtdd init\` once, only to create it' '$R'"
  assert "$p: never commits rtdd's agent files"  "grep -q 'never \`AGENTS.md\`, \`.claude/\` or \`.cursor/\`' '$R'"
  assert "$p: pre-existing reds re-run on the base" "grep -q 'not automatically YOURS' '$R'"
  # The loophole the audit found: a test that merely reaches the new code proves nothing.
  assert "$p: requires a test that fails without the change" "grep -qiE 'FAILS WITHOUT|FAILS ON THE UNFIXED' '$R'"
  # #245: no GitHub CI — a repo without its own CI entrypoint is gated on the full local suite.
  assert "$p: full suite is the gate when no local CI entrypoint" "grep -qi 'otherwise the FULL suite' '$R'"
  assert "$p: forbids weakening a test to go green" "grep -qi 'never delete, skip, or weaken' '$R'"
  assert "$p: rebase re-selects with rtdd which" "grep -q 'Rounds 1 and 2 (the rebase changed your diff' '$R'"
  # v0.3 removed all of these; a lane told to use them follows broken instructions.
  assert "$p: no removed v0.2 workflow"          "! grep -qE 'rtdd (run|seed)|map\.jsonl|junit\.xml|adapters|T2|meta\.json|UNCOVERED|uncovered report' '$R'"
done
# Acceptance: each rendered prompt shrinks by >= 35 lines from its v0.2 size (impl 171, bug-fix 160).
assert "impl renders in <= 136 lines"    "(( \$(wc -l < '$RUN_DIR/impl.txt') <= 136 ))"
assert "bug-fix renders in <= 125 lines" "(( \$(wc -l < '$RUN_DIR/bug-fix.txt') <= 125 ))"

echo "-- rtdd_skill_install, per CLI"
# A fake rtdd: --help shows (or hides) the v0.3-only --legacy-files; `skill install` logs and exits
# $FAKE_SKILL_RC; `skill prompt` prints upstream's shape — prose, then the skill in a fenced block.
FB="$RUN_DIR/fakebin"; mkdir -p "$FB"
cat > "$FB/rtdd" <<'EOF'
#!/usr/bin/env bash
echo "rtdd $*" >> "$FAKE_LOG"
case "$1 ${2:-}" in
  "--help ") echo "  rtdd uninstall [--dry-run]${FAKE_V03:+ [--legacy-files]}" ;;
  "skill install") exit "${FAKE_SKILL_RC:-0}" ;;
  "skill prompt") printf 'Save the document below.\n\n````markdown\n---\nname: rtdd\n---\nbody\n````\n' ;;
esac
EOF
chmod +x "$FB/rtdd"
export FAKE_LOG="$RUN_DIR/rtdd.log"
for cli in claude agy; do
  export HARNESS_AGY_USER_SKILLS="$RUN_DIR/agy-skills-$cli"
  : > "$FAKE_LOG"
  out="$(PATH="$FB:$PATH" FAKE_V03=1 HARNESS_CLI=$cli rtdd_skill_install)"; rc=$?
  assert "[$cli] v0.3 rtdd: installs the user-level skill" "(( rc == 0 )) && grep -qx 'rtdd skill install' '$FAKE_LOG'"
  assert "[$cli] v0.3 rtdd: reports it"                    "[[ '$out' == *'rtdd skill installed'* ]]"
  if [[ $cli == agy ]]; then
    assert "[agy] skill lands in agy's user skill dir, unfenced" \
      "[[ \"\$(cat '$HARNESS_AGY_USER_SKILLS/rtdd/SKILL.md')\" == \$'---\nname: rtdd\n---\nbody' ]]"
  else
    assert "[claude] nothing written to agy's skill dir" "[[ ! -e '$HARNESS_AGY_USER_SKILLS' ]]"
  fi
  : > "$FAKE_LOG"
  out="$(PATH="$FB:$PATH" HARNESS_CLI=$cli rtdd_skill_install)"; rc=$?
  assert "[$cli] pre-v0.3 rtdd: warns, returns 1"          "(( rc == 1 )) && [[ '$out' == *'predates v0.3'* ]]"
  assert "[$cli] pre-v0.3 rtdd: skill install NOT run"     "! grep -q 'skill install' '$FAKE_LOG'"
  out="$(PATH="$FB:$PATH" FAKE_V03=1 FAKE_SKILL_RC=1 HARNESS_CLI=$cli rtdd_skill_install)"; rc=$?
  assert "[$cli] failed skill install: warns, returns 1"   "(( rc == 1 )) && [[ '$out' == *'skill install failed'* ]]"
done
out="$(PATH="$RUN_DIR/empty" rtdd_skill_install 2>&1)"; rc=$?
assert "no rtdd binary: silent no-op (setup warns itself)" "(( rc == 0 )) && [[ -z '$out' ]]"
assert "setup.sh calls rtdd_skill_install when rtdd is present" "grep -q '^  rtdd_skill_install' '$HERE/../scripts/setup.sh'"

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
RM="$HERE/../docs/reference.md"
assert "reference has a Test selection section" "grep -qE '^### Test selection \(rtdd\)' '$RM'"
assert "README prereq: node row names rtdd the lane test loop, optional" "grep -E '^\| \`node\`' '$HERE/../README.md' | grep -i 'optional' | grep -qi 'lane test loop'"
# The section only: swarm's own per-shard junit.xml is documented elsewhere in the README.
awk '/^### Test selection \(rtdd\)/{f=1;next} /^### /{f=0} f' "$RM" > "$RUN_DIR/readme-rtdd.md"
assert "README teaches the v0.3 rounds" "grep -q 'Round 3' '$RUN_DIR/readme-rtdd.md'"
assert "README teaches no removed v0.2 workflow" "! grep -qE 'rtdd (run|seed)|map\.jsonl|junit\.xml|\.rtdd/adapters' '$RUN_DIR/readme-rtdd.md'"

# ── this repo's own rtdd setup ────────────────────────────────────────────────────────────
# Harness drives itself, so the setup the prompts mandate holds HERE: v0.3's config is committed and
# its graph cache ignored, and the v0.2 footprint (map, adapter + its runner, merge driver, the agent
# files an older `rtdd init` wrote) is gone.
ROOT="$HERE/.."
assert "v0.3 config committed"            "[[ -f '$ROOT/.rtdd/config.yaml' ]] && grep -q '^whole_file_tests:' '$ROOT/.rtdd/config.yaml'"
assert "graph cache ignored"              "grep -qx 'graph.json' '$ROOT/.rtdd/.gitignore'"
for f in .rtdd/map.jsonl .rtdd/adapters scripts/rtdd-bash-runner.py .gitattributes AGENTS.md .cursor/rules/rtdd.mdc; do
  assert "v0.2 footprint gone: $f"        "[[ ! -e '$ROOT/$f' ]]"
done

echo "── rtdd prompt contract ok"
