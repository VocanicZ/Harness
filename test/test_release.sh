#!/usr/bin/env bash
# test_release.sh — PRD #274 / #278: `harness release` gates on test/run.sh at the exact commit,
# bumps semver from Conventional Commits, publishes archive + SHA256SUMS, and is idempotent.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
RELEASE="$HERE/../scripts/release.sh"
gc(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cd "$T"
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
# fixture <name> <test/run.sh exit> — a Harness-shaped repo whose origin is a local bare repo.
fixture(){ local d="$T/$1"; mkdir -p "$d/test"; git init -q --bare -b main "$d.git"
  printf '#!/usr/bin/env bash\nexit %s\n' "$2" > "$d/test/run.sh"
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
assert_eq "$(git -C "$B" tag -l)" "" "no tag after a red gate"
assert_eq "$(git -C "$B.git" tag -l)" "" "no tag pushed after a red gate"
assert_no "no gh release create after a red gate" grep -q '^release create' "$GH_LOG"
assert_ok "the gate log is kept for the caller" test -f "$HARNESS_HOME/autorelease/gate-$(git -C "$B" rev-parse HEAD).log"
fresh_gh; D="$(fixture dirty 0)"; printf '#!/usr/bin/env bash\nexit 1\n' > "$D/test/run.sh"   # uncommitted
rel "$D" >/dev/null 2>&1
assert_ok "the gate runs the committed tree, not the dirty one" test -f "$GH_PUB/v0.1.0"

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
