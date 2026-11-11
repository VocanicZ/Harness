#!/usr/bin/env bash
# test_prompt_label_lint.sh — #1053: the prompt-skills lint (test_cli_matrix.sh prompt_skills) must know every Harness label,
# trailing `# …` comment or not. An end-anchored regex dropped agent-paused, bug, bug-triaged and hitl, so the first prompt
# to backtick one (prompts/_windows_suite.md) failed prompt-skills-installed for every CLI.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
LIB="$HERE/../scripts/lib.sh"

labels="$(harness_label_defaults "$LIB")"
want="$(grep -cE '^: "\$\{HARNESS_LABEL_[A-Z_]+:=' "$LIB")"
assert_eq "$(wc -l <<<"$labels" | tr -d ' ')" "$want" "label list has one entry per HARNESS_LABEL_* default in lib.sh"
for l in agent-paused bug bug-triaged hitl waiting-winsma ready-for-agent agent-working; do
  assert_ok "label list has $l" grep -qxF "$l" <<<"$labels"
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/lib.sh" <<'LIB'
: "${HARNESS_LABEL_READY:=ready-for-agent}"
: "${HARNESS_LABEL_PAUSED:=agent-paused}"   # trailing comment
: "${HARNESS_LABEL_BUG_TRIAGED:=bug-triaged}"  # another
LIB
printf 'use `agent-paused` and `bug-triaged` and `ready-for-agent`\n' > "$T/ok.md"
printf 'use `subagent-driven-development` and `agent-paused`\n' > "$T/bad.md"
assert_eq "$(prompt_kebab_leaks "$T/lib.sh" "$T/ok.md")" "" "backticked labels (commented lines too) are not leaks"
assert_eq "$(prompt_kebab_leaks "$T/lib.sh" "$T/bad.md")" '`subagent-driven-development`' "a real kebab-case skill name is still a leak"
assert_eq "$(prompt_kebab_leaks "$LIB" "$HERE"/../prompts/*.md)" "" "no prompt backticks a non-label kebab-case word"
finish
