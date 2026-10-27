#!/usr/bin/env bash
# test_harness_arc_dashboard.sh — #230: the harness-arc skill points at the live dashboard and no
# longer publishes an Artifact; status-page.py is gone; the DAG golden still stands without it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
A="$HERE/../skill/harness-arc"
has(){ grep -qE -- "$1" "$2"; }
assert_ok "SKILL.md links the fleet page"            has 'http://<host>:4637/fleet/<prefix>' "$A/SKILL.md"
assert_ok "SKILL.md names harness web"               has '`harness web`' "$A/SKILL.md"
assert_ok "SKILL.md names harness web --install"     has '`harness web --install`' "$A/SKILL.md"
assert_no "status-page.py is removed"                test -e "$A/scripts/status-page.py"
assert_no "no skill file mentions status-page.py"    grep -rqIF 'status-page.py' "$A"
assert_no "no publish-an-Artifact instruction left"  grep -rqIiE 'artifact (tool|publish)|publish (it|the page) with the artifact|republish' "$A"
assert_ok "the DAG golden still passes"              python3 "$HERE/test_web_dag.py"
assert_ok "the golden fixture is kept"               test -s "$HERE/fixtures/web/arc-golden.json"
finish
