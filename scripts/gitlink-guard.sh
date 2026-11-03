#!/usr/bin/env bash
# gitlink-guard.sh — refuse a main-repo merge whose changed gitlinks are not safe (#470, PRD #464 §3).
#
#   gitlink-guard.sh [--repo <dir>] [--base <ref>] [--head <ref>]
#
# Compares <head> (default HEAD) with <base> (default origin/<default branch>) in <repo> (default cwd).
# Every submodule gitlink the change touches must point at a commit that is
#   1. reachable from the submodule's origin/<base branch> (merged there, not just pushed to a branch), and
#   2. a descendant of — or equal to — the gitlink <base> pins (no rewinding, no sideways jump).
# A change with no gitlink change passes untouched; a repo with no submodules passes. Exit 0 = allowed,
# 1 = refused (every offender is printed), 2 = the guard could not decide (fails closed).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/submodule.sh"

repo=. base= head=HEAD
while (( $# )); do case "$1" in
  --repo) repo="$2"; shift 2;; --base) base="$2"; shift 2;; --head) head="$2"; shift 2;;
  *) echo "usage: gitlink-guard.sh [--repo DIR] [--base REF] [--head REF]" >&2; exit 2;; esac; done
repo="$(cd "$repo" && pwd)" || exit 2

if [[ -z "$base" ]]; then
  b="$(git -C "$repo" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)"
  [[ -n "$b" ]] || for c in origin/main origin/master; do git -C "$repo" rev-parse -q --verify "$c" >/dev/null 2>&1 && { b="$c"; break; }; done
  base="$b"
fi
[[ -n "$base" ]] || { echo "gitlink-guard: no base ref (no origin/HEAD, origin/main or origin/master)" >&2; exit 2; }
git -C "$repo" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || { echo "gitlink-guard: unknown base $base" >&2; exit 2; }
git -C "$repo" rev-parse -q --verify "$head^{commit}" >/dev/null 2>&1 || { echo "gitlink-guard: unknown head $head" >&2; exit 2; }

fail=0; undecided=0
refuse(){ echo "gitlink-guard: REFUSED $1: $2" >&2; fail=1; }
# changed gitlinks: `:<oldmode> <newmode> <oldsha> <newsha> <status>\t<path>`, either mode 160000
while IFS=$'\t' read -r meta path; do
  read -r omode nmode osha nsha _ <<<"${meta#:}"
  [[ "$omode" == 160000 || "$nmode" == 160000 ]] || continue
  [[ "$nmode" == 160000 ]] || continue           # a removed submodule has no gitlink to check
  sub="$repo/$path"
  if [[ ! -e "$sub/.git" ]]; then echo "gitlink-guard: $path is not initialised — cannot verify" >&2; undecided=1; continue; fi
  git -C "$sub" fetch -q origin 2>/dev/null || true
  # base branch from the base ref's gitlink (the one the change started from)
  br="$(submodule_base_branch "$repo" "$path" "$base" 2>/dev/null)" || br=
  if [[ -z "$br" && "$omode" != 160000 ]]; then br="$(submodule_default_branch "$sub")"; fi
  if [[ -z "$br" ]]; then echo "gitlink-guard: cannot resolve the base branch of $path" >&2; undecided=1; continue; fi
  if ! git -C "$sub" cat-file -e "$nsha^{commit}" 2>/dev/null; then
    refuse "$path" "gitlink $nsha is not a commit the submodule has (not pushed, or not fetched)"; continue; fi
  if ! git -C "$sub" merge-base --is-ancestor "$nsha" "origin/$br" 2>/dev/null; then
    refuse "$path" "gitlink $nsha is not reachable from origin/$br — merge it into the submodule's base branch first"; continue; fi
  if [[ "$omode" == 160000 && "$osha" != "$nsha" ]] && ! git -C "$sub" merge-base --is-ancestor "$osha" "$nsha" 2>/dev/null; then
    refuse "$path" "gitlink $nsha does not descend from the current gitlink $osha"; continue; fi
done < <(git -C "$repo" diff-tree -r --raw --no-renames "$base" "$head" 2>/dev/null)

(( fail )) && exit 1
(( undecided )) && exit 2
exit 0
