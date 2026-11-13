#!/usr/bin/env bash
# test_release.sh — PRD #274 / #278: `harness release` gates on rtdd's Rounds 1+2 plus test/guards.sh, run through test/run.sh
# at the exact commit (#1148: never the whole suite; test_release_gate_scope.sh pins the rounds), bumps semver from Conventional Commits, publishes archive + SHA256SUMS, and is idempotent.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
# #325: a live auto-release environment (HARNESS_AUTORELEASE_DIR, …) must not steer the fixtures.
unset_inherited_config
RELEASE="$HERE/../scripts/release.sh"
gc(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cd "$T"
pin_host_home "$T/host"   # + the fleet/poller/snapshot pins, unit dirs and user bus (#541)
export HARNESS_HOME="$T/host" HARNESS_RELEASE_REPO=acme/harness
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# Stub gh: `release view` succeeds only for a tag it has published; `release create` records its
# argv, keeps the assets and the notes it was handed, then publishes the tag.
STUB="$T/bin"; mkdir -p "$STUB"; export GH_LOG="$T/gh.log" GH_PUB="$T/pub" PATH="$STUB:$PATH"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "auth status")    exit 0;;
  "release view")   [[ -f "$GH_PUB/$3" ]];;
  "release create") tag="$3"; mkdir -p "$GH_PUB/$tag.assets"
                    for a in "${@:4}"; do [[ -f "$a" ]] && cp "$a" "$GH_PUB/$tag.assets/"; done
                    set -- "${@:4}"; while (($#)); do [[ "$1" == --notes-file ]] && cp "$2" "$GH_PUB/$tag.notes"; shift; done
                    touch "$GH_PUB/$tag";;
  *) exit 0;;
esac
EOF
chmod +x "$STUB/gh"
fresh_gh(){ rm -rf "$GH_PUB"; mkdir -p "$GH_PUB"; : > "$GH_LOG"; }
# Stub rtdd (#1148): the gate selects its tests with `rtdd which --json --base <x>`. It answers from the checkout it runs in: each line
# of rtdd.files is "<round> <file>". A Round 3 (the full suite) is always reported, and the gate must never read it.
cat > "$STUB/rtdd" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/rtdd.log"
python3 -I - <<'PY'
import json
rounds = {}
for line in open("rtdd.files"):
    r, f = line.split()
    rounds.setdefault(int(r), []).append(f)
print(json.dumps({"schema": 3, "rounds": [{"round": n, "files": rounds.get(n, [])} for n in (1, 2)] + [{"round": 3, "full_suite": True}]}))
PY
EOF
chmod +x "$STUB/rtdd"
# fixture <name> <test/run.sh exit> — a Harness-shaped repo whose origin is a local bare repo: test_a.sh and test_x.sh, a guard set
# stub, and an rtdd.files that selects both tests (Round 1) plus a helper and a smoke the gate must not run.
fixture(){ local d="$T/$1"; mkdir -p "$d/test"; git init -q --bare -b main "$d.git"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/run.calls"\nexit %s\n' "$T" "$2" > "$d/test/run.sh"
  printf '#!/usr/bin/env bash\necho guards >> "%s/guards.calls"\nexit 0\n' "$T" > "$d/test/guards.sh"
  : > "$d/test/test_a.sh"; : > "$d/test/test_x.sh"; : > "$d/test/helpers.sh"
  printf '1 test/test_a.sh\n1 test/test_x.sh\n2 test/helpers.sh\n2 test/smoke/fleet_smoke.sh\n' > "$d/rtdd.files"
  gc "$d" init -q -b main; gc "$d" add -A; gc "$d" commit -qm "chore: init"
  gc "$d" remote add origin "$d.git"; gc "$d" push -q -u origin main; echo "$d"; }
commit(){ printf '%s\n' "$2" >> "$1/log"; gc "$1" add -A; gc "$1" commit -qm "$2" ${3:+-m "$3"}; gc "$1" push -q; }
rel(){ ( cd "$1" && bash "$RELEASE" "${@:2}" ); }
sums_ok(){ ( cd "$1" && sha256sum -c --status SHA256SUMS ); }

# ── version from Conventional Commits ──
next_of(){ local R; R="$(fixture "n$RANDOM$RANDOM" 0)"
  gc "$R" tag -a "$1" -m "$1"; gc "$R" push -q origin "$1"; commit "$R" "$2" "${3:-}"
  rel "$R" --dry-run | sed -n 's/^would release \(v[0-9.]*\) .*/\1/p'; }
assert_eq "$(next_of v0.1.0 'fix: a')"                       v0.1.1 "fix only → patch"
assert_eq "$(next_of v0.1.0 'docs: a')"                      v0.1.1 "any other type → patch"
assert_eq "$(next_of v0.1.0 'feat: a')"                      v0.2.0 "feat → minor"
assert_eq "$(next_of v0.1.0 'feat!: a')"                     v0.2.0 "feat! while 0.x → minor"
assert_eq "$(next_of v0.1.0 'fix: a' 'BREAKING CHANGE: b')"  v0.2.0 "BREAKING CHANGE while 0.x → minor"
assert_eq "$(next_of v1.2.3 'fix(cli)!: a')"                 v2.0.0 "breaking from 1.0 → major"
fresh_gh; F="$(fixture first 0)"
assert_eq "$(rel "$F" --dry-run | sed -n 's/^would release \(v[0-9.]*\) .*/\1/p')" v0.1.0 "no prior tag → v0.1.0"
assert_eq "$(cat "$GH_LOG" | grep -c '^release create')" 0 "--dry-run creates nothing"

# ── the gate ──
fresh_gh; B="$(fixture red 1)"
rel "$B" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 4 "a red test/run.sh refuses with the gate exit code"
assert_eq "$(head -n1 "$T/run.calls")" "test_a.sh test_x.sh" "the gate runs the rtdd selection by name, never a bare run.sh"
assert_eq "$(git -C "$B" tag -l)" "" "no tag after a red gate"
assert_eq "$(git -C "$B.git" tag -l)" "" "no tag pushed after a red gate"
assert_no "no gh release create after a red gate" grep -q '^release create' "$GH_LOG"
assert_ok "the gate log is kept for the caller" test -f "$HARNESS_HOME/autorelease/gate-$(git -C "$B" rev-parse HEAD).log"
fresh_gh; D="$(fixture dirty 0)"; printf '#!/usr/bin/env bash\nexit 1\n' > "$D/test/run.sh"   # uncommitted
rel "$D" >/dev/null 2>&1
assert_ok "the gate runs the committed tree, not the dirty one" test -f "$GH_PUB/v0.1.0"

# ── #1060: the gate runs under a scrubbed environment ──
# A gate started from a live worker's shell (HARNESS_ENGINE_STAMP, CLAUDE_*, STATE_DIR…) shows none of it in test/run.sh or any child.
fresh_gh; E="$(fixture scrub 0)"
cat > "$E/test/run.sh" <<EOF
#!/usr/bin/env bash
env > "$T/gate-env.txt"
bash -c 'env' > "$T/gate-child-env.txt"
exit 0
EOF
gc "$E" add -A; gc "$E" commit -qm "chore: env probe"; gc "$E" push -q
( cd "$E" && HARNESS_ENGINE_STAMP=stamp-1060 HARNESS_CLAUDE_BIN=/x CLAUDE_CODE_SSE_PORT=1 CLAUDE_SESSION=s STATE_DIR=/live/.harness \
    ENGINE_DIR=/live/engine HARNESS_TEST_FILE=t TMUX=/tmp/tmux-0/default,1,0 TMUX_PANE=%3 FLEET_SECRET=x bash "$RELEASE" ) >/dev/null 2>&1
assert_ok "the scrubbed gate ran and the release was cut" test -f "$GH_PUB/v0.1.0"
assert_no "no HARNESS_ variable in test/run.sh" grep -q '^HARNESS_' "$T/gate-env.txt"
assert_no "no HARNESS_ variable in a child of it" grep -q '^HARNESS_' "$T/gate-child-env.txt"
assert_no "no CLAUDE_ variable reaches the gate" grep -q '^CLAUDE' "$T/gate-child-env.txt"
assert_no "no worker or fleet variable reaches the gate" grep -qE '^(STATE_DIR|ENGINE_DIR|TMUX|TMUX_PANE|FLEET_SECRET)=' "$T/gate-child-env.txt"
assert_ok "PATH, HOME, LANG and TMPDIR are the allowlist" bash -c "grep -q '^PATH=' '$T/gate-child-env.txt' && grep -q '^HOME=' '$T/gate-child-env.txt' && grep -q '^LANG=' '$T/gate-child-env.txt' && grep -q '^TMPDIR=' '$T/gate-child-env.txt'"
assert_ok "the gate gets a private TMUX_TMPDIR" grep -q '^TMUX_TMPDIR=' "$T/gate-child-env.txt"
assert_no "which is not the fleet's /tmp" grep -qE '^TMUX_TMPDIR=/tmp/?$' "$T/gate-child-env.txt"

# ── #1060: a red file is re-run once, alone; one that passes alone is a flake and the release goes ahead ──
# flaky_fixture <name> <what a re-run of test_x.sh alone does> — red on the gate's run, <2nd arg> when re-run by file name.
flaky_fixture(){ local d; d="$(fixture "$1" 0)"
  cat > "$d/test/run.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/$1.calls"
if [[ "\$*" == test_x.sh ]]; then $2; fi
echo "== test_x.sh =="; echo "FAIL: x lost the race"; echo "FAILED: test_x.sh"; exit 1
EOF
  gc "$d" add -A; gc "$d" commit -qm "chore: flaky gate"; gc "$d" push -q; echo "$d"; }
fresh_gh; K="$(flaky_fixture flaky 'exit 0')"
out="$(rel "$K" 2>&1)"; rc=$?
assert_eq "$rc" 0 "a file red once and green alone does not fail the gate"
assert_ok "the release is cut" test -f "$GH_PUB/v0.1.0"
assert_ok "the file was re-run alone, by name" grep -qx 'test_x.sh' "$T/flaky.calls"
assert_eq "$(wc -l < "$T/flaky.calls" | tr -d " ")" 2 "re-run exactly once"
assert_eq "$(cat "$HARNESS_HOME/autorelease/gate-flake-$(git -C "$K" rev-parse HEAD)")" test_x.sh "the flake is recorded for the tracking issue"
assert_ok "the flake is said on stderr" grep -qF 'gate flaked' <<<"$out"
fresh_gh; K="$(flaky_fixture stuck 'echo "FAILED: test_x.sh"; exit 1')"
rel "$K" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 4 "a file that fails again alone fails the gate"
assert_eq "$(wc -l < "$T/stuck.calls" | tr -d " ")" 2 "and was re-run once only"
assert_eq "$(git -C "$K.git" tag -l)" "" "no tag"
assert_no "no flake recorded for a real failure" test -e "$HARNESS_HOME/autorelease/gate-flake-$(git -C "$K" rev-parse HEAD)"
fresh_gh; K="$(fixture big 0)"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/big.calls"\nfor i in 1 2 3 4 5 6; do echo "FAILED: test_$i.sh"; done; exit 1\n' "$T" > "$K/test/run.sh"
gc "$K" add -A; gc "$K" commit -qm "chore: broken gate"; gc "$K" push -q
rel "$K" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 4 "more red files than the cap is a broken tree: failed, not re-run"
assert_eq "$(wc -l < "$T/big.calls" | tr -d " ")" 1 "no re-run"

# ── publish: assets, --latest, grouped notes ──
fresh_gh; N="$(fixture notes 0)"; commit "$N" "feat: add x (closes #7)"; commit "$N" "fix: mend y (closes #9)"
out="$(rel "$N" 2>&1)"; rc=$?
assert_eq "$rc" 0 "a release exits 0"
assert_ok "stdout names the release" grep -qx 'released v0.1.0' <<<"$out"
assert_ok "the annotated tag is pushed" git -C "$N.git" rev-parse -q --verify 'refs/tags/v0.1.0^{tag}'
A="$GH_PUB/v0.1.0.assets"
assert_ok "SHA256SUMS verifies the archive with sha256sum -c" sums_ok "$A"
assert_eq "$(tar -xzOf "$A/harness-v0.1.0.tar.gz" harness-v0.1.0/VERSION | sed -n 1p)" v0.1.0 "the archive carries VERSION"
assert_eq "$(tar -xzOf "$A/harness-v0.1.0.tar.gz" harness-v0.1.0/VERSION | sed -n 2p)" \
  "$(git -C "$N" rev-parse HEAD)" "VERSION records the tagged commit"
assert_ok "published as latest" grep -qE '^release create v0\.1\.0 .*--latest' "$GH_LOG"
assert_no "never a draft" grep -qF -- '--draft' "$GH_LOG"
assert_ok "notes group features" grep -qx '### Features' "$GH_PUB/v0.1.0.notes"
assert_ok "notes group fixes"    grep -qx '### Fixes' "$GH_PUB/v0.1.0.notes"
assert_ok "notes link the closing issue" grep -qF '[#7](https://github.com/acme/harness/issues/7)' "$GH_PUB/v0.1.0.notes"

# ── idempotent ──
: > "$GH_LOG"; out="$(rel "$N" 2>&1)"; rc=$?
assert_eq "$rc" 0 "re-running on a released commit exits 0"
assert_ok "and says it is already released" grep -qF 'Harness v0.1.0 is already released.' <<<"$out"
assert_no "re-run calls no gh release create" grep -q '^release create' "$GH_LOG"
rm -f "$GH_PUB/v0.1.0"; : > "$GH_LOG"
rel "$N" >/dev/null 2>&1
assert_ok "a tag without a release is published" grep -q '^release create v0.1.0 ' "$GH_LOG"
assert_eq "$(git -C "$N" tag -l | xargs)" v0.1.0 "an unpublished tag is finished, not superseded"

hr(){ ( cd "$1" && env -u STATE_DIR -u ENGINE_DIR bash "$HERE/../bin/harness" release "${@:2}" ); }
assert_ok "harness release dispatches to release.sh" grep -q '^would release v0.1.1 ' <<<"$(commit "$N" "fix: z"; hr "$N" --dry-run)"
assert_ok "usage documents release" grep -qE '^  release \[--dry-run\]' <<<"$(bash "$HERE/../bin/harness" --help)"

assert_no "release.sh runs no destructive git op" grep -qE 'git +clean|reset +--hard|checkout +-f|branch +-D' "$RELEASE"
finish
