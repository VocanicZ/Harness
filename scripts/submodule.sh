#!/usr/bin/env bash
# submodule.sh — submodule helpers shared by lib.sh (lane worktree init) and gitlink-guard.sh.
# Pure git, no engine state: source it, call the functions. (#470, PRD #464 §3)
# It sources portable.sh (guarded, safe twice) for lock_acquire / lock_release: the shared-store refresh
# below is locked, and a raw `flock` is not allowed outside portable.sh (native Windows has none).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable.sh"

# submodule_name <repo> <path> — the .gitmodules name of the submodule checked out at <path>.
submodule_name(){ local repo="$1" path="$2" k
  [[ -f "$repo/.gitmodules" ]] || return 1
  while read -r k _; do
    [[ "$(git config -f "$repo/.gitmodules" --get "$k")" == "$path" ]] || continue
    k="${k#submodule.}"; printf '%s\n' "${k%.path}"; return 0
  done < <(git config -f "$repo/.gitmodules" --name-only --get-regexp '^submodule\..*\.path$' 2>/dev/null)
  return 1; }

# submodule_gitlink <repo> <ref> <path> — the commit <ref> of <repo> pins <path> to (empty if none).
submodule_gitlink(){ local mode _ sha
  read -r mode _ sha _ < <(git -C "$1" ls-tree "$2" -- "$3" 2>/dev/null)
  [[ "${mode:-}" == 160000 ]] && printf '%s\n' "$sha"; return 0; }

# submodule_default_branch <subdir> — the submodule remote's default branch: origin/HEAD, else main, else master.
submodule_default_branch(){ local d="$1" b
  b="$(git -C "$d" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)" && [[ -n "$b" ]] && { printf '%s\n' "${b#origin/}"; return 0; }
  for b in main master; do git -C "$d" rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null 2>&1 && { printf '%s\n' "$b"; return 0; }; done
  return 1; }

# submodule_base_branch <repo> <path> [ref] — the branch a submodule's changes merge into:
#   1. .gitmodules `submodule.<name>.branch` when set (and not `.`);
#   2. else the origin branch that contains the gitlink <ref> (default HEAD) of <repo> pins — the
#      submodule's default branch when several do, never blindly the default branch (ORGE's fleet works
#      on `rebuild` with no `branch =`). Needs the submodule initialised; fetches origin first, best effort.
submodule_base_branch(){ local repo="$1" path="$2" ref="${3:-HEAD}" name br sha sub b first= default
  name="$(submodule_name "$repo" "$path")" || { echo "submodule_base_branch: $path is not a submodule of $repo" >&2; return 1; }
  br="$(git config -f "$repo/.gitmodules" --get "submodule.$name.branch" 2>/dev/null)"
  if [[ -n "$br" && "$br" != . ]]; then printf '%s\n' "$br"; return 0; fi
  sub="$repo/$path"
  [[ -e "$sub/.git" ]] || { echo "submodule_base_branch: $path is not initialised" >&2; return 1; }
  sha="$(submodule_gitlink "$repo" "$ref" "$path")"
  [[ -n "$sha" ]] || { echo "submodule_base_branch: $ref pins no gitlink at $path" >&2; return 1; }
  git -C "$sub" fetch -q origin 2>/dev/null || true
  default="$(submodule_default_branch "$sub")"
  while read -r b; do
    [[ "$b" == origin/HEAD || "$b" == origin ]] && continue
    b="${b#origin/}"
    [[ "$b" == "$default" ]] && { printf '%s\n' "$b"; return 0; }
    [[ -n "$first" ]] || first="$b"
  done < <(git -C "$sub" for-each-ref --contains "$sha" --format='%(refname:short)' refs/remotes/origin 2>/dev/null | sort)
  [[ -n "$first" ]] && { printf '%s\n' "$first"; return 0; }
  echo "submodule_base_branch: no origin branch of $path contains $sha" >&2; return 1; }

# submodule_init <worktree> — initialise every submodule of a fresh worktree (`git worktree add` never
# does). A repo without .gitmodules is left alone. Returns non-zero when any submodule failed (the rest
# are still done); callers treat that as non-fatal.
# Each submodule BORROWS the main checkout's object store (`--reference`, i.e. objects/info/alternates)
# instead of re-downloading it: a plain `submodule update --init --recursive` in a linked worktree clones
# every submodule in full from its remote (1 GB+ per lane for a big submodule). The main-side copy of a
# submodule lives in `<git-common-dir>/modules/<name>`, and its nested submodules in its own `modules/`,
# so the reference is chosen per submodule and per level — one shared --reference would hand the wrong
# repo to every other submodule. A missing main-side copy (the main checkout never ran `submodule
# update`) falls back to a plain clone: git fails hard on a --reference that does not exist. Objects the
# main-side copy lacks (its submodule sits at another commit) would be fetched into the LANE's own store,
# and git never writes to a reference, so every lane would download them again: the shared store is
# refreshed first (`fetch origin`, once, under a per-store lock), so the lane then borrows everything
# (#1241). A refresh that fails, or leaves the commit missing, falls back to the lane fetching it itself.
# Trade-off: a lane's submodule depends on the main checkout's objects, so a `gc --prune` there that drops
# objects unreachable in it could break a live lane. Lanes are short-lived and `git worktree remove`
# deletes their `modules/`. Never --dissociate (copies the objects back) and never --depth/--filter: the
# base-branch lookup and the lane's own pushes need the full history. (#1207)
submodule_init(){ local wt="$1" common
  [[ -f "$wt/.gitmodules" ]] || return 0
  common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=
  _submodule_init_level "$wt" "${common:+$common/modules}"; }

# _submodule_refresh_ref <dir> <path> <ref> — make the shared store <ref> hold the commit <dir> pins <path>
# to, so `--reference` has everything to borrow. A store that already has it is left alone. Otherwise one
# `fetch origin` runs under <ref>/harness-refresh.lock, re-checked once the lock is held (a parallel lane
# may have fetched meanwhile). Best effort and silent: any failure (no gitlink, lock, fetch, commit still
# missing) returns 0 and the caller clones as before. Prompts are off: the hook's output is discarded, so
# a credential prompt would hang the launch while holding the lock. Only refs/remotes/origin/* of <ref>
# moves; the main checkout's submodule HEAD and work tree are never touched.
_submodule_refresh_ref(){ local dir="$1" p="$2" ref="$3" sha lk=
  sha="$(submodule_gitlink "$dir" HEAD "$p")"
  [[ -n "$sha" ]] || return 0
  git -C "$ref" cat-file -e "$sha^{commit}" 2>/dev/null && return 0
  if declare -F lock_acquire >/dev/null; then lock_acquire "$ref/harness-refresh.lock" lk 2>/dev/null || lk=; fi
  git -C "$ref" cat-file -e "$sha^{commit}" 2>/dev/null \
    || GIT_TERMINAL_PROMPT=0 git -C "$ref" fetch -q origin >/dev/null 2>&1 || true
  [[ -z "$lk" ]] || lock_release "$lk"
  return 0; }

# _submodule_init_level <dir> <main-side modules dir | ""> — one level of submodule_init: <dir>'s own
# submodules, each borrowing from <modroot>/<name>, then recursing with <modroot>/<name>/modules.
_submodule_init_level(){ local dir="$1" modroot="$2" k p name ref rc=0
  while read -r k p; do
    name="${k#submodule.}"; name="${name%.path}"; ref=
    [[ -n "$modroot" && -d "$modroot/$name/objects" ]] && ref="$modroot/$name"
    if [[ -n "$ref" ]]; then _submodule_refresh_ref "$dir" "$p" "$ref"; git -C "$dir" submodule update --init --reference "$ref" -- "$p" || rc=1
    else git -C "$dir" submodule update --init -- "$p" || rc=1; fi
    [[ -f "$dir/$p/.gitmodules" ]] && { _submodule_init_level "$dir/$p" "${modroot:+$modroot/$name/modules}" || rc=1; }
  done < <(git config -f "$dir/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null)
  return $rc; }

# submodule_branch_pushed <worktree> <branch> — succeed when any submodule of <worktree> has <branch> on
# its origin. A lane working submodule code pushes `issue/<unit>-<n>` in the submodule, so a lane that died
# after pushing only that branch leaves nothing on the main repo's `issue/<n>`; resume detection asks this
# as well, so such an issue is resumed, not restarted. Submodules must be initialised (run_worktree_hook
# did it); an uninitialised one is skipped. A repo without .gitmodules never matches. (#471)
submodule_branch_pushed(){ local wt="$1" br="$2" p
  [[ -f "$wt/.gitmodules" ]] || return 1
  while read -r _ p; do
    [[ -e "$wt/$p/.git" ]] || continue
    git -C "$wt/$p" ls-remote --heads origin "$br" 2>/dev/null | grep -q . && return 0
  done < <(git config -f "$wt/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null)
  return 1; }
