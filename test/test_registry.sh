#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/helpers.sh"
make_env

# multi topology: registry comes from targets.tsv
HARNESS_TOPOLOGY=multi
write_targets <<'EOF'
# id	repo	deps	desc
a	acme/a	-	root
b	acme/b	a	needs a
c	acme/c	a,b	needs a+b
EOF
assert_eq "$(all_units | tr '\n' ' ')" "a b c " "multi: all_units from targets.tsv"
assert_eq "$(unit_repo b)" "acme/b" "multi: unit_repo"
assert_eq "$(unit_deps c)" "a,b" "multi: unit_deps"
assert_eq "$(unit_slug b)" "acme/b" "multi: slug = repo (already owner/repo)"

# bare repo name gets owner prefix
write_targets <<'EOF'
a	a	-	root
EOF
HARNESS_OWNER=acme
assert_eq "$(unit_slug a)" "acme/a" "multi: bare repo name -> owner/repo"

# single topology: one synthetic unit "main", repo from HARNESS_REPO, no deps
HARNESS_TOPOLOGY=single; HARNESS_REPO="acme/widget"
assert_eq "$(all_units | tr '\n' ' ')" "main " "single: one unit 'main'"
assert_eq "$(unit_repo main)" "acme/widget" "single: unit_repo = HARNESS_REPO"
assert_eq "$(unit_deps main)" "-" "single: no deps"
finish
