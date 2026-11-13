#!/usr/bin/env bash
# test_release_gate_scope.sh — #1148: the full suite runs once per PRD, at PRD review, and nowhere else. `harness release` used to run a bare
# `test/run.sh` (the whole suite, about an hour under fleet load) on every release; its gate is now one of
#   - a PRD close at the sha its review already ran the full suite on: that result, no test runs again;
#   - rtdd Rounds 1+2 for `rtdd which --base <reviewed sha>` (main moved after the review) plus test/guards.sh;
#   - rtdd Rounds 1+2 for `rtdd which --base <last vX.Y.Z tag>` plus test/guards.sh (a patch release, or no reviewed-sha record).
# Each case runs against a stubbed test/run.sh that records its arguments: on main it is called with none.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
unset_inherited_config
RELEASE="$HERE/../scripts/release.sh"
gc(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cd "$T"
pin_host_home "$T/host"
export HARNESS_HOME="$T/host" HARNESS_RELEASE_REPO=acme/harness
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
STUB="$T/bin"; RBIN="$T/rbin"; mkdir -p "$STUB" "$RBIN"; export GH_LOG="$T/gh.log" PATH="$STUB:$RBIN:$PATH"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "release view") exit 1;;
esac
exit 0
EOF
chmod +x "$STUB/gh"
# rtdd stub: records its arguments, answers from rtdd.files of the checkout it runs in ("<round> <file>" per line) and always adds the
# Round 3 "full suite" entry the gate must never act on.
cat > "$RBIN/rtdd" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/rtdd.log"
[[ -f rtdd.files ]] || exit 2
python3 -I - <<'PY'
import json
rounds = {}
for line in open("rtdd.files"):
    r, f = line.split()
    rounds.setdefault(int(r), []).append(f)
print(json.dumps({"schema": 3, "rounds": [{"round": n, "files": rounds.get(n, [])} for n in (1, 2)] + [{"round": 3, "full_suite": True}]}))
PY
EOF
chmod +x "$RBIN/rtdd"

# repo <name> — a Harness-shaped repo: one commit, a stub test/run.sh and test/guards.sh that record their calls, an rtdd.files selecting
# Round 1 test_a.sh and Round 2 test_b.sh plus a helper and a smoke that are no tests.
repo(){ local d="$T/$1"; mkdir -p "$d/test"; git init -q --bare -b main "$d.git"
  printf '#!/usr/bin/env bash\necho "[$*]" >> "%s/run.calls"\nexit 0\n' "$T" > "$d/test/run.sh"
  printf '#!/usr/bin/env bash\necho guards >> "%s/guards.calls"\nexit "${GUARDS_RC:-0}"\n' "$T" > "$d/test/guards.sh"
  : > "$d/test/test_a.sh"; : > "$d/test/test_b.sh"; : > "$d/test/helpers.sh"
  printf '1 test/test_a.sh\n2 test/test_b.sh\n2 test/helpers.sh\n2 test/smoke/fleet_smoke.sh\n' > "$d/rtdd.files"
  gc "$d" init -q -b main; gc "$d" add -A; gc "$d" commit -qm "chore: init"
  gc "$d" remote add origin "$d.git"; gc "$d" push -q -u origin main; echo "$d"; }
commit(){ printf '%s\n' "$2" >> "$1/log"; gc "$1" add -A; gc "$1" commit -qm "$2"; gc "$1" push -q; }
rel(){ ( cd "$1" && bash "$RELEASE" "${@:2}" ); }
fresh(){ rm -f "$T"/run.calls "$T"/guards.calls "$T"/rtdd.log "$T"/rel.err; : > "$GH_LOG"; }
calls(){ cat "$T/run.calls" 2>/dev/null; }
nrun(){ if [[ -f "$T/run.calls" ]]; then grep -c . "$T/run.calls"; else echo 0; fi; }
no_bare_run(){ ! grep -qx '\[\]' "$T/run.calls" 2>/dev/null; }

# ── a patch release: rtdd Rounds 1+2 for last-tag..head plus the guard set, one run.sh call naming its files ──
fresh; R="$(repo patch)"; gc "$R" tag -a v0.1.0 -m v0.1.0; gc "$R" push -q origin v0.1.0
commit "$R" "fix: mend y"
rel "$R" 2>"$T/rel.err" >/dev/null; rc=$?
assert_eq "$rc" 0 "a patch release is cut"
assert_ok "released as v0.1.1" grep -q '^release create v0.1.1 ' "$GH_LOG"
assert_eq "$(cat "$T/rtdd.log")" "which --json --base v0.1.0" "rtdd selects from the last vX.Y.Z tag"
assert_eq "$(calls)" "[test_a.sh test_b.sh]" "run.sh gets the Round 1+2 test files by name: no helper, no smoke, no Round 3"
assert_ok "run.sh was never called bare (the whole suite)" no_bare_run
assert_eq "$(cat "$T/guards.calls")" guards "the guard set runs once"
assert_ok "the gate says what it ran" grep -qF 'rtdd Rounds 1+2 for' "$T/rel.err"

# ── a PRD close at the reviewed sha: that review's full-suite result is the gate; no test runs, no rtdd ──
fresh; R="$(repo atsha)"; gc "$R" tag -a v0.1.0 -m v0.1.0; gc "$R" push -q origin v0.1.0
commit "$R" "feat: prd work"; head="$(git -C "$R" rev-parse HEAD)"
rel "$R" --reviewed-sha "$head" --reviewed-prd 77 2>"$T/rel.err" >/dev/null; rc=$?
assert_eq "$rc" 0 "a release at the reviewed sha is cut"
assert_ok "and published" grep -q '^release create v0.2.0 ' "$GH_LOG"
assert_eq "$(nrun)" 0 "no test/run.sh call at all"
assert_no "no guard run" test -e "$T/guards.calls"
assert_no "no rtdd run" test -e "$T/rtdd.log"
assert_ok "it reports which review result it reused" grep -qF "gate reused the PRD #77 review full-suite result" "$T/rel.err"

# ── a PRD close after main moved: rtdd Rounds 1+2 for reviewed-sha..head, not last-tag..head ──
fresh; R="$(repo moved)"; gc "$R" tag -a v0.1.0 -m v0.1.0; gc "$R" push -q origin v0.1.0
commit "$R" "feat: prd work"; reviewed="$(git -C "$R" rev-parse HEAD)"; commit "$R" "fix: merged after the review"
rel "$R" --reviewed-sha "$reviewed" --reviewed-prd 78 2>"$T/rel.err" >/dev/null; rc=$?
assert_eq "$rc" 0 "a release after main moved is cut"
assert_eq "$(cat "$T/rtdd.log")" "which --json --base $reviewed" "rtdd selects from the reviewed sha"
assert_eq "$(calls)" "[test_a.sh test_b.sh]" "only the rtdd selection runs"
assert_ok "run.sh was never called bare" no_bare_run
assert_eq "$(cat "$T/guards.calls")" guards "plus the guard set"
assert_no "the reused-result line is not printed" grep -qF 'gate reused' "$T/rel.err"

# ── no reviewed-sha record (an old PRD): rtdd rounds from the last tag ──
fresh; R="$(repo norecord)"; gc "$R" tag -a v0.3.0 -m v0.3.0; gc "$R" push -q origin v0.3.0; commit "$R" "feat: old prd work"
rel "$R" 2>/dev/null >/dev/null; rc=$?
assert_eq "$rc" 0 "a PRD close with no review record is released"
assert_eq "$(cat "$T/rtdd.log")" "which --json --base v0.3.0" "its rtdd selection is from the last tag"
assert_ok "never a bare run.sh" no_bare_run

# ── a recorded sha that is not an ancestor of the release (or not a commit at all): the last tag, never the full suite ──
fresh; R="$(repo stale)"; gc "$R" tag -a v0.1.0 -m v0.1.0; gc "$R" push -q origin v0.1.0; commit "$R" "fix: a"
rel "$R" --reviewed-sha 0123456789abcdef0123456789abcdef01234567 2>/dev/null >/dev/null; rc=$?
assert_eq "$rc" 0 "an unknown reviewed sha does not stop the release"
assert_eq "$(cat "$T/rtdd.log")" "which --json --base v0.1.0" "it falls back to the last tag"
assert_ok "never a bare run.sh" no_bare_run

# ── the bootstrap release (no tag yet) selects from the root commit, still by rounds ──
fresh; R="$(repo boot)"; root="$(git -C "$R" rev-list --max-parents=0 HEAD)"
rel "$R" 2>/dev/null >/dev/null; rc=$?
assert_eq "$rc" 0 "the first release is cut"
assert_eq "$(cat "$T/rtdd.log")" "which --json --base $root" "rtdd selects from the root commit"
assert_ok "never a bare run.sh" no_bare_run

# ── an empty selection runs the guard set alone: never run.sh with no argument ──
fresh; R="$(repo empty)"; gc "$R" tag -a v0.1.0 -m v0.1.0; gc "$R" push -q origin v0.1.0
printf '2 test/helpers.sh\n' > "$R/rtdd.files"; commit "$R" "docs: a"
rel "$R" 2>/dev/null >/dev/null; rc=$?
assert_eq "$rc" 0 "an empty selection still releases"
assert_eq "$(nrun)" 0 "run.sh is not called (an argument-less run.sh is the whole suite)"
assert_eq "$(cat "$T/guards.calls")" guards "the guard set still runs"

# ── red: a failing guard set fails the gate (rc 4) and nothing is tagged ──
fresh; R="$(repo redguard)"; gc "$R" tag -a v0.1.0 -m v0.1.0; gc "$R" push -q origin v0.1.0; commit "$R" "fix: a"
printf '#!/usr/bin/env bash\necho guards >> "%s/guards.calls"\necho "guard runner broke"; exit 1\n' "$T" > "$R/test/guards.sh"; commit "$R" "chore: red guard"
rel "$R" 2>/dev/null >/dev/null; rc=$?
assert_eq "$rc" 4 "a red guard set fails the gate"
assert_eq "$(git -C "$R.git" tag -l 'v0.1.[1-9]')" "" "no tag pushed"
assert_no "nothing published" grep -q '^release create' "$GH_LOG"

# ── rtdd absent or erroring: an environment error (3, safe to re-run); the suite is not the fallback ──
fresh; R="$(repo nortdd)"; gc "$R" tag -a v0.1.0 -m v0.1.0; gc "$R" push -q origin v0.1.0; commit "$R" "fix: a"
rm -f "$R/rtdd.files"; commit "$R" "chore: no rtdd answer"
rel "$R" 2>"$T/rel.err" >/dev/null; rc=$?
assert_eq "$rc" 3 "rtdd erroring is an environment failure"
assert_eq "$(nrun)" 0 "and run.sh is not called as a fallback"
assert_no "nothing published" grep -q '^release create' "$GH_LOG"
fresh; R="$(repo nobin)"; gc "$R" tag -a v0.1.0 -m v0.1.0; gc "$R" push -q origin v0.1.0; commit "$R" "fix: a"
# a PATH with every directory that holds an rtdd removed (the stub's, and the host's real one)
NORTDD_PATH="$(IFS=:; out=(); for d in $PATH; do [[ -x "$d/rtdd" ]] || out+=("$d"); done; echo "${out[*]}")"
NORTDD_PATH="${NORTDD_PATH// /:}"
( cd "$R" && PATH="$NORTDD_PATH" bash "$RELEASE" ) 2>"$T/rel.err" >/dev/null; rc=$?
assert_eq "$rc" 3 "rtdd not on PATH is an environment failure"
assert_eq "$(nrun)" 0 "and run.sh is not called as a fallback"
assert_ok "it says rtdd is missing" grep -qF 'rtdd is not on PATH' "$T/rel.err"

# ── the script itself never runs the suite bare ──
assert_no "release.sh has no argument-less test/run.sh call" grep -qE 'bash test/run\.sh *\)' "$RELEASE"
finish
