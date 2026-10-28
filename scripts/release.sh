#!/usr/bin/env bash
# release.sh [--dry-run] [--ref <rev>] — `harness release` (#278, PRD #274): cut the next Harness
# release from this checkout, on this host, with this host's `gh`. Harness runs no GitHub Actions
# (#245), so this is the one way a release is made.
#
# In order:
#   1. idempotency — a vX.Y.Z tag already on <rev> with a published release is a no-op; a tag with
#      no release is finished (published), never superseded by a new version
#   2. gate        — test/run.sh on a `git archive` of <rev>, the exact tree that ships, so a dirty
#      working tree can neither pass nor fail it
#   3. version     — the next semver from Conventional Commits since the last vX.Y.Z tag: a breaking
#      change (`type!:` / `BREAKING CHANGE:`) bumps minor while 0.x and major from 1.0, any `feat`
#      bumps minor, anything else patch. No prior tag → v0.1.0
#   4. tag + push  — an annotated tag, pushed to origin
#   5. build       — harness-vX.Y.Z.tar.gz (top dir harness-vX.Y.Z/, plus VERSION: tag, then commit)
#      and SHA256SUMS, reproducibly
#   6. publish     — gh release create … --latest --verify-tag, notes grouped by commit type
#
# Exit codes (Task 7's auto-release trigger reads these):
#   0  released, or already released     2  configuration (not a git checkout, bad --ref, gh not
#   3  environment (git/tar/gh failed;      authenticated, an unparseable last tag)
#      safe to re-run)                   4  the gate failed (log at $HARNESS_AUTORELEASE_DIR/gate-<sha>.log)
set -uo pipefail

REPO="${HARNESS_RELEASE_REPO:-VocanicZ/Harness}"
AUTORELEASE_DIR="${HARNESS_AUTORELEASE_DIR:-${HARNESS_HOME:-$HOME/.harness}/autorelease}"
TAG_GLOB='v[0-9]*.[0-9]*.[0-9]*'

die(){ local rc="$1"; shift; echo "harness release: $*" >&2; exit "$rc"; }

DRY=0; REF=HEAD
while (($#)); do
  case "$1" in
    --dry-run) DRY=1;;
    --ref) [[ $# -ge 2 ]] || die 2 "--ref needs a revision"; REF="$2"; shift;;
    --ref=*) REF="${1#--ref=}";;
    -h|--help) echo "usage: harness release [--dry-run] [--ref <rev>]"; exit 0;;
    *) die 2 "unknown argument: $1";;
  esac
  shift
done

git rev-parse --git-dir >/dev/null 2>&1 || die 2 "not inside a git checkout of $REPO"
# Tags cut on another host must be seen, or the version computed here collides with theirs.
git fetch -q --tags origin 2>/dev/null || true
sha="$(git rev-parse -q --verify "$REF^{commit}" 2>/dev/null)" || die 2 "cannot resolve --ref $REF to a commit"
short="$(git rev-parse --short "$sha")"

# last_tag <rev> — the newest vX.Y.Z tag reachable from <rev>; empty when there is none.
last_tag(){ git describe --tags --abbrev=0 --match "$TAG_GLOB" "$1" 2>/dev/null; }
# tag_at <sha> — the highest vX.Y.Z tag pointing exactly at <sha>; empty when there is none.
tag_at(){ git tag --points-at "$1" -l "$TAG_GLOB" | sort -V | tail -n1; }
released(){ gh release view "$1" --repo "$REPO" >/dev/null 2>&1; }

# next_version <prev tag> <commit records> — the semver after <prev>, bumped by the commit types.
next_version(){
  local prev="$1" recs="$2" level=1 h s b
  [[ -z "$prev" ]] && { echo v0.1.0; return 0; }
  [[ "$prev" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die 2 "last tag $prev is not vMAJOR.MINOR.PATCH"
  local ma="${BASH_REMATCH[1]}" mi="${BASH_REMATCH[2]}" pa="${BASH_REMATCH[3]}"
  while IFS=$'\x1f' read -r -d $'\x1e' h s b; do
    if [[ "$s" =~ ^[a-z]+(\([^\)]*\))?!: ]] || grep -qE '^BREAKING[ -]CHANGE:' <<<"$b"; then level=3
    elif [[ "$s" =~ ^feat(\([^\)]*\))?: ]] && ((level < 2)); then level=2
    fi
  done <<<"$recs"
  if ((level == 3 && ma > 0)); then echo "v$((ma + 1)).0.0"
  elif ((level >= 2)); then echo "v$ma.$((mi + 1)).0"
  else echo "v$ma.$mi.$((pa + 1))"
  fi
}

# commits <prev tag> <sha> — one record per non-merge commit: sha \x1f subject \x1f body \x1e.
commits(){ git log --no-merges --format='%H%x1f%s%x1f%b%x1e' "${1:+$1..}$2"; }

CLOSE_RE='(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+#([0-9]+)'
# link_closing — every `closes #N` (and fix/resolve forms) becomes a link to issue N.
link_closing(){ sed -E "s~((close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+)#([0-9]+)~\1[#\4](https://github.com/$REPO/issues/\4)~Ig"; }

# release_notes <tag> <prev tag> <commit records> — markdown notes grouped by commit type.
release_notes(){
  local tag="$1" prev="$2" recs="$3" h s b line extra n
  local -a brk=() feat=() fix=() other=()
  while IFS=$'\x1f' read -r -d $'\x1e' h s b; do
    h="${h//$'\n'/}"; [[ -n "$h" ]] || continue
    line="${s#*: }"; [[ "$s" =~ ^[a-z]+(\([^\)]*\))?!?:\  ]] || line="$s"
    extra=""
    # A closing ref only in the body (a squash merge's description) is linked after the subject.
    for n in $(grep -oiE "$CLOSE_RE" <<<"$b" | grep -oE '[0-9]+$' | sort -un); do
      grep -qiE "(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+#$n\b" <<<"$s" || extra+="${extra:+, }closes #$n"
    done
    line="- $(link_closing <<<"$line${extra:+ ($extra)}") (${h:0:7})"
    if [[ "$s" =~ ^[a-z]+(\([^\)]*\))?!: ]] || grep -qE '^BREAKING[ -]CHANGE:' <<<"$b"; then brk+=("$line")
    elif [[ "$s" =~ ^feat(\([^\)]*\))?: ]]; then feat+=("$line")
    elif [[ "$s" =~ ^fix(\([^\)]*\))?: ]]; then fix+=("$line")
    else other+=("$line")
    fi
  done <<<"$recs"
  echo "## Harness $tag"
  section(){ local title="$1"; shift; (($#)) || return 0; printf '\n### %s\n\n' "$title"; printf '%s\n' "$@"; }
  section "Breaking changes" "${brk[@]}"
  section "Features" "${feat[@]}"
  section "Fixes" "${fix[@]}"
  section "Other" "${other[@]}"
  [[ -n "$prev" ]] && printf '\n**Full changelog:** https://github.com/%s/compare/%s...%s\n' "$REPO" "$prev" "$tag"
  return 0
}

# ── 1. idempotency: a tag already on this commit is released, or finished ──
tag="$(tag_at "$sha")"
if [[ -n "$tag" ]]; then
  prev="$(git rev-parse -q --verify "$sha^" >/dev/null && last_tag "$sha^")"
  if released "$tag"; then echo "Harness $tag is already released."; exit 0; fi
  finishing=1
else
  prev="$(last_tag "$sha")"
  finishing=0
fi
recs="$(commits "$prev" "$sha")" || die 3 "git log failed"
[[ -n "$tag" ]] || tag="$(next_version "$prev" "$recs")"

tmp="$(mktemp -d)" || die 3 "mktemp failed"
trap 'rm -rf "$tmp"' EXIT
release_notes "$tag" "$prev" "$recs" > "$tmp/notes.md"

if ((DRY)); then
  if ((finishing)); then echo "would publish existing tag $tag ($short)"; else echo "would release $tag ($short)"; fi
  echo; cat "$tmp/notes.md"; exit 0
fi

gh auth status >/dev/null 2>&1 || die 2 "gh is not authenticated (run: gh auth login)"

if ((finishing == 0)); then
  # ── 2. the gate: test/run.sh on the exact tree being tagged ──
  mkdir -p "$tmp/gate"
  git archive --format=tar "$sha" | tar -x -C "$tmp/gate" || die 3 "git archive $short failed"
  log="$tmp/gate.log"
  ( cd "$tmp/gate" && env -u STATE_DIR -u ENGINE_DIR -u HARNESS_HOME bash test/run.sh ) >"$log" 2>&1
  grc=$?
  if ((grc != 0)); then
    mkdir -p "$AUTORELEASE_DIR" && cp "$log" "$AUTORELEASE_DIR/gate-$sha.log"
    tail -n 40 "$log" >&2
    die 4 "gate failed: test/run.sh exited $grc at $short; not releasing $tag (log: $AUTORELEASE_DIR/gate-$sha.log)"
  fi
  # ── 4. tag + push ──
  git tag -a "$tag" "$sha" -m "Harness $tag" || die 3 "git tag $tag failed"
  if ! git push -q origin "refs/tags/$tag"; then
    git tag -d "$tag" >/dev/null 2>&1
    die 3 "git push origin $tag failed; local tag removed"
  fi
elif [[ -z "$(git ls-remote --tags origin "refs/tags/$tag" 2>/dev/null)" ]]; then
  git push -q origin "refs/tags/$tag" || die 3 "git push origin $tag failed"
fi

# ── 5. build: a second, clean extract (the gate's tree grew caches) plus VERSION ──
name="harness-$tag"
mkdir -p "$tmp/pkg" "$tmp/out"
git archive --format=tar --prefix="$name/" "$sha" | tar -x -C "$tmp/pkg" || die 3 "git archive $short failed"
printf '%s\n%s\n' "$tag" "$sha" > "$tmp/pkg/$name/VERSION"
mtime="$(git log -1 --format=%ct "$sha")"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$mtime" -C "$tmp/pkg" -cf - "$name" \
  | gzip -n > "$tmp/out/$name.tar.gz" || die 3 "building $name.tar.gz failed"
( cd "$tmp/out" && sha256sum "$name.tar.gz" > SHA256SUMS ) || die 3 "sha256sum failed"

# ── 6. publish ──
gh release create "$tag" "$tmp/out/$name.tar.gz" "$tmp/out/SHA256SUMS" --repo "$REPO" \
  --title "Harness $tag" --notes-file "$tmp/notes.md" --latest --verify-tag \
  || die 3 "gh release create $tag failed; tag $tag is pushed, re-run to finish publishing it"
echo "released $tag"
