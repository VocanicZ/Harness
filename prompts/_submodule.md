SUBMODULE WORK — only when the `## Code location` section (or your code) is inside a git submodule of {{SLUG}} (`.gitmodules`; checked out for you). The issue stays in {{SLUG}}; lanes never claim issues from a submodule's own repo.
  1. Work in the submodule on branch `issue/{{UNIT}}-{{ISSUE}}` (never `issue/{{ISSUE}}`: a former submodule fleet may have left it); run `rtdd which` inside the submodule as well as here.
  2. Rebase, Rounds 1+2, push, squash-merge into the submodule's BASE branch (`submodule_base_branch` in `scripts/submodule.sh`: `branch =` in `.gitmodules`, else the origin branch holding the current gitlink; never assume `main`).
  3. Fetch, then point this repo's gitlink at the MERGED commit on the submodule's `origin/<base>` (a squash merge changes the SHA) — never your pre-merge branch commit.
  4. Commit the bump here, run Rounds 1+2 on the rebased HEAD, merge as below; the gitlink guard on `gh pr merge` checks the bump.
