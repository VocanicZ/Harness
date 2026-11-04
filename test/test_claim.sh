#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/lib.sh"
source "$HERE/helpers.sh"
make_env
write_targets <<'EOF'
a	acme/a	-	root
b	acme/b	a	needs a
c	acme/c	a,b	needs a+b
EOF
set_complete
assert_no "nothing complete -> !all_complete"     all_complete
set_complete a
assert_no "only a complete -> !all_complete"      all_complete
set_complete a b c
assert_ok "all complete -> all_complete"          all_complete

printf 'W1 %s\n' "$$"     > "$CLAIMS_DIR/a.claim"
printf 'W2 %s\n' "999999" > "$CLAIMS_DIR/b.claim"
assert_ok "live-pid claim is claimed"     is_claimed a
assert_no "dead-pid claim is not claimed" is_claimed b
assert_no "no claim file -> not claimed"  is_claimed c
clear_stale_claims >/dev/null
assert_ok "stale claim removed" bash -c "[[ ! -f '$CLAIMS_DIR/b.claim' ]]"
assert_ok "live claim kept"     bash -c "[[ -f '$CLAIMS_DIR/a.claim' ]]"
rm -f "$CLAIMS_DIR/a.claim"

# release_bug_claim drops the bug's claim file (the only claim a bug lane releases by name)
printf 'P1 %s acme/a#6\n' "$$" > "$CLAIMS_DIR/bug-acme_a-6.claim"
assert_ok "a live bug claim is claimed" is_bug_claimed "acme/a#6"
release_bug_claim "acme/a#6"
assert_ok "release_bug_claim removes the claim file" bash -c "[[ ! -f '$CLAIMS_DIR/bug-acme_a-6.claim' ]]"
assert_no "the released bug is not claimed" is_bug_claimed "acme/a#6"
finish
