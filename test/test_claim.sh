#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/helpers.sh"
make_env
HARNESS_TOPOLOGY=multi
write_targets <<'EOF'
a	acme/a	-	root
b	acme/b	a	needs a
c	acme/c	a,b	needs a+b
EOF
set_complete
assert_ok "a no deps -> deps_complete"            deps_complete a
assert_no "b dep a incomplete -> !deps_complete"  deps_complete b
assert_no "nothing complete -> !all_complete"     all_complete
set_complete a
assert_ok "a complete -> b deps_complete"         deps_complete b
assert_no "c needs a+b, b incomplete"             deps_complete c
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

set_complete
assert_eq "$(claimable_units | tr '\n' ' ')" "a " "only a claimable"
set_complete a
assert_eq "$(claimable_units | tr '\n' ' ')" "b " "a done -> b claimable"
printf 'W1 %s\n' "$$" > "$CLAIMS_DIR/b.claim"
assert_eq "$(claimable_units | tr '\n' ' ')" "" "b claimed -> nothing claimable"
rm -f "$CLAIMS_DIR/b.claim"
set_complete a b
assert_eq "$(claimable_units | tr '\n' ' ')" "c " "a+b done -> c claimable"

set_complete a
got="$(claim_next W1)"; assert_eq "$got" "b" "claim_next returns first claimable"
assert_eq "$(awk '{print $1}' "$CLAIMS_DIR/b.claim")" "W1" "claim records worker id"
assert_eq "$(claim_next W2)" "" "no claimable left -> empty"
assert_eq "$(worker_unit W1)" "b" "worker_unit finds the claim"
release_claim b
assert_ok "release removes claim file" bash -c "[[ ! -f '$CLAIMS_DIR/b.claim' ]]"

# race: two siblings simultaneously claimable -> claimers get DIFFERENT units
write_targets <<'EOF'
a	acme/a	-	r1
d	acme/d	-	r2
EOF
set_complete
( claim_next A > "$RUN_DIR/a.out" ) &
( claim_next B > "$RUN_DIR/b.out" ) &
wait
ra="$(cat "$RUN_DIR/a.out")"; rb="$(cat "$RUN_DIR/b.out")"
assert_ok "both claimers got a unit"        bash -c "[[ -n '$ra' && -n '$rb' ]]"
assert_ok "claimers got DIFFERENT units"    bash -c "[[ '$ra' != '$rb' ]]"
rm -f "$CLAIMS_DIR"/*.claim
finish
