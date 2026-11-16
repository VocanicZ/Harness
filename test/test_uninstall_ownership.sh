#!/usr/bin/env bash
# test_uninstall_ownership.sh — #1111 (PRD #475): `harness uninstall` removes only the skills Harness made. A link
# counts only when it names a Harness engine's skill/ ($HARNESS_HOME/engine, $HARNESS_HOME/releases/*, the engine
# being removed); a copy only when it is what Harness shipped (byte-equal to a release, or carrying CLI_SKILL_MARK).
# The operator's link into their own skill/ dir and their own harness-* skill dir survive. Run on Linux and forced
# onto Windows (HARNESS_PLATFORM=windows, Windows' own tools faked).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"
make_env
T="$(mktemp -d)"; tmp_track "$T"; trap tmp_cleanup EXIT
mkdir -p "$T/bin"
for b in schtasks powershell taskkill systemctl loginctl; do printf '#!/bin/sh\nexit 0\n' >"$T/bin/$b"; done
chmod +x "$T/bin/"*

# mk_home <root> — an install as #439 left it, plus what the operator keeps beside it.
mk_home(){ local root="$1" h="$1/home" s="$1/skills" rs="$1/home/releases/v1/skill" n
  mkdir -p "$h/releases/v1/bin" "$rs/harness-init" "$rs/harness-start" "$rs/harness-stop" "$rs/handoff" "$s" "$root/bin" "$root/proj/.harness"
  : >"$h/releases/v1/bin/harness"; chmod +x "$h/releases/v1/bin/harness"; ln -s releases/v1 "$h/engine"
  printf 'umbrella\n' >"$rs/SKILL.md"
  for n in harness-init harness-start harness-stop; do printf -- '---\nname: %s\n---\nbody of %s\n' "$n" "$n" >"$rs/$n/SKILL.md"; done
  printf '<!-- harness-skill: handoff -->\nhandoff\n' >"$rs/handoff/SKILL.md"
  printf 'HARNESS_POOL=1\n' >"$root/proj/.harness/config"
  # Harness's own
  mkdir -p "$s/harness"; ln -s "$h/engine/skill/SKILL.md" "$s/harness/SKILL.md"          # the umbrella: a SKILL.md link
  ln -s "$h/engine/skill/harness-init" "$s/harness-init"                                  # a link through the engine link
  ln -s "$h/releases/v0.9/skill/harness-stop" "$s/harness-stop"                            # an old release, pruned: dangling
  mkdir -p "$s/harness-start"; cp "$rs/harness-start/SKILL.md" "$s/harness-start/SKILL.md" # a pre-#439 copy, byte-equal to the release
  mkdir -p "$s/handoff"; cp "$rs/handoff/SKILL.md" "$s/handoff/SKILL.md"                   # a marked copy
  # the operator's own
  mkdir -p "$root/myrepo/skill/foo" "$root/myrepo/skill/harness-linked"
  printf 'mine\n' >"$root/myrepo/skill/foo/SKILL.md"; printf 'mine\n' >"$root/myrepo/skill/harness-linked/SKILL.md"
  ln -s "$root/myrepo/skill/foo" "$s/foo"                                                  # a link into another skill/ dir
  ln -s "$root/myrepo/skill/harness-linked" "$s/harness-linked"                            # … with a harness-* name
  mkdir -p "$s/harness-mytool" "$s/harness-edited" "$s/to-prd"
  printf -- '---\nname: harness-mytool\n---\nmy own tool\n' >"$s/harness-mytool/SKILL.md"   # their own harness-* dir
  { cat "$rs/harness-init/SKILL.md"; echo "edited by the operator"; } >"$s/harness-edited/SKILL.md"   # a Harness skill they changed
  : >"$s/to-prd/SKILL.md"
}

for plat in linux windows; do
  echo "=== $plat: uninstall removes Harness's skills and keeps the operator's ==="
  I="$T/$plat"; mkdir -p "$I"; mk_home "$I"
  ( [[ $plat == windows ]] && export HARNESS_PLATFORM=windows PATH="$T/bin:$PATH" HARNESS_SCHTASKS="$T/bin/schtasks" \
      HARNESS_POWERSHELL="$T/bin/powershell" HARNESS_TASKKILL="$T/bin/taskkill" HARNESS_BASH_EXE=bash
    HARNESS_HOME="$I/home" HARNESS_BIN_DIR="$I/bin" HARNESS_USER_SKILLS="$I/skills" STATE_DIR="$I/proj/.harness" \
    ENGINE_DIR="$R" HARNESS_UNINSTALL_WORKER_PIDS="" bash "$R/scripts/uninstall.sh" --force --force-engine </dev/null >"$I/out" 2>&1 ); rc=$?
  assert_eq "$rc" 0 "$plat: uninstall exits 0"
  assert_no "$plat: the engine is gone"                              test -e "$I/home/engine" -o -e "$I/home/releases"
  assert_no "$plat: the umbrella harness/ is gone"                   test -e "$I/skills/harness" -o -L "$I/skills/harness"
  assert_no "$plat: a link into the engine is gone"                  test -e "$I/skills/harness-init" -o -L "$I/skills/harness-init"
  assert_no "$plat: a dangling link into a pruned release is gone"   test -e "$I/skills/harness-stop" -o -L "$I/skills/harness-stop"
  assert_no "$plat: a copy byte-equal to a release is gone"          test -e "$I/skills/harness-start"
  assert_no "$plat: a copy carrying the mark is gone"                test -e "$I/skills/handoff"
  assert_ok "$plat: the operator's link into their own skill/ survives"  test -L "$I/skills/foo" -a -f "$I/skills/foo/SKILL.md"
  assert_ok "$plat: … also under a harness-* name"                   test -L "$I/skills/harness-linked" -a -f "$I/skills/harness-linked/SKILL.md"
  assert_eq "$(cat "$I/skills/harness-mytool/SKILL.md" 2>/dev/null | tail -1)" "my own tool" "$plat: the operator's own harness-mytool survives"
  assert_ok "$plat: a Harness skill the operator edited survives"    grep -q "edited by the operator" "$I/skills/harness-edited/SKILL.md"
  assert_ok "$plat: an unrelated skill survives"                     test -f "$I/skills/to-prd/SKILL.md"
  assert_eq "$(ls -A "$I/skills" | sort | xargs)" "foo harness-edited harness-linked harness-mytool to-prd" "$plat: only the operator's skills are left"
  assert_eq "$(ls -A "$I/bin")" "" "$plat: the bin dir holds nothing of Harness's"
done

echo "=== a link into the engine being removed (a dev clone) is Harness's ==="
D="$T/dev"; mkdir -p "$D/clone/skill/harness-init" "$D/skills" "$D/home" "$D/bin" "$D/proj/.harness"
: >"$D/clone/skill/harness-init/SKILL.md"; printf 'HARNESS_POOL=1\n' >"$D/proj/.harness/config"
ln -s "$D/clone/skill/harness-init" "$D/skills/harness-init"
HARNESS_HOME="$D/home" HARNESS_BIN_DIR="$D/bin" HARNESS_USER_SKILLS="$D/skills" STATE_DIR="$D/proj/.harness" \
  ENGINE_DIR="$D/clone" HARNESS_UNINSTALL_WORKER_PIDS="" bash "$R/scripts/uninstall.sh" --force </dev/null >/dev/null 2>&1
assert_no "the dev clone's link is removed" test -L "$D/skills/harness-init"

finish
