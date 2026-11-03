#!/usr/bin/env bash
# submodule.sh — submodule helpers shared by lib.sh (lane worktree init) and gitlink-guard.sh.
# Pure git, no engine state: source it, call the functions. (#470, PRD #464 §3)

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
# does). A repo without .gitmodules is left alone. Returns git's status; callers treat it as non-fatal.
submodule_init(){ [[ -f "$1/.gitmodules" ]] || return 0
  git -C "$1" submodule update --init --recursive; }

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
