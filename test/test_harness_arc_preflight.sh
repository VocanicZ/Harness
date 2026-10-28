#!/usr/bin/env bash
# test_harness_arc_preflight.sh — #181: skill/harness-arc/scripts/preflight.sh moved into the repo.
# Runs it against a stub engine (issuelib.py) and a stub gh, on a scratch checkout with an origin.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
PF="$HERE/../skill/harness-arc/scripts/preflight.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"; tmp_cleanup' EXIT
mkdir -p "$T/engine" "$T/bin"
cat >"$T/engine/issuelib.py" <<'EOF'
import sys
print("issuelib", " ".join(sys.argv[1:]))
EOF
printf '#!/bin/sh\necho "  closed #7 still labelled ready-for-agent"\n' >"$T/bin/gh"; chmod +x "$T/bin/gh"
gc(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
git init -q --bare -b main "$T/remote.git"
git init -q -b main "$T/repo"; gc "$T/repo" commit -q --allow-empty -m base
gc "$T/repo" remote add origin "$T/remote.git"; gc "$T/repo" push -q origin main
mkdir -p "$T/repo/.harness"; printf 'HARNESS_POOL=3\nHARNESS_REPO=owner/arc\n' >"$T/repo/.harness/config"
pf(){ PATH="$T/bin:$PATH" HARNESS_ENGINE="$T/engine" bash "$PF" "$@" 2>&1; }

out="$(pf owner/arc "$T/repo")"
assert_ok "reads the unit state through issuelib, by full slug"  grep -q "issuelib status owner/arc" <<<"$out"
assert_ok "dry-runs the dispatcher"                              grep -q "issuelib dispatch owner/arc 3 --allow-orchestration 1" <<<"$out"
assert_ok "pushed design → OK"                                   grep -q "OK: HEAD == origin/main" <<<"$out"
assert_ok "lists closed issues still labelled ready"             grep -q "closed #7 still labelled ready-for-agent" <<<"$out"
assert_ok "reads the pool size from .harness/config"             grep -q "configured pool=3" <<<"$out"
gc "$T/repo" commit -q --allow-empty -m "unpushed spec"
out="$(pf owner/arc "$T/repo")"
assert_ok "unpushed design → warned"                             grep -q "HEAD != origin/main" <<<"$out"
printf 'import sys\nsys.exit(3)\n' >"$T/engine/issuelib.py"
out="$(pf owner/arc "$T/repo")"
assert_ok "an issuelib read failure is reported, not fatal"      grep -q "issuelib read failed" <<<"$out"
out="$(pf 2>&1)"; rc=$?
assert_no "no slug → usage error"                                test "$rc" = 0
assert_ok "…naming the usage"                                    grep -q "usage: preflight.sh <owner/repo>" <<<"$out"
pf owner/arc "$T/nope" >/dev/null; rc=$?
assert_eq "$rc" "1" "a missing checkout exits 1"
finish
