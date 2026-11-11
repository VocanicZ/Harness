# repair (#496): put the owner's skill links back where the first e2e run's supervisor relinked them (sup_clean_env dropped HARNESS_USER_SKILLS)
S=/c/Users/pc/.claude/skills; E=/c/Users/pc/.harness/engine/skill; n=0
for l in "$S"/* "$S"/harness/SKILL.md; do
  [[ -L $l ]] || continue
  t="$(readlink "$l")"; [[ $t == /c/hx-496/* ]] || continue
  rel="${l#$S/}"
  if [[ $rel == harness-one ]]; then rm -f "$l"; echo "removed $rel (it did not exist before)"; continue; fi
  src="$E/$rel"; [[ $rel == harness/SKILL.md ]] && src="$E/SKILL.md"
  rm -f "$l" && MSYS=winsymlinks:nativestrict ln -s "$src" "$l" && n=$((n+1)) && echo "relinked $rel -> $src"
done
echo "relinked $n"
cd /; sha256sum -c - <<'SHA' 2>&1 | grep -v ': OK$' ; echo "sha check rc=${PIPESTATUS[0]}"
028aecbdd4473e49f5facf726e228b655d1f758116a2ca03183a024470ed5b53  /c/Users/pc/.claude/skills/harness-arc/REFERENCE.md
03d00c6d83a5799ff2a6237641ddd996b9d9c54a47c9c5434c191588af83e588  /c/Users/pc/.claude/skills/harness-arc/scripts/preflight.sh
05a81a5356fbf4bccf81c9d35b1bfe8e5249a5e153033f5b4d25488dbcdd9c74  /c/Users/pc/.claude/skills/harness-pause/SKILL.md
0e7ac423bf2c6e223b7c5b156f8cf72da49d748e56a1641402c31f22ad07dbb5  /c/Users/pc/.claude/skills/to-issues/LICENSE
0e7ac423bf2c6e223b7c5b156f8cf72da49d748e56a1641402c31f22ad07dbb5  /c/Users/pc/.claude/skills/to-prd/LICENSE
107580543854e06d91bb1d874847392f04d85ef0570c5f4135a3701f7f011fdf  /c/Users/pc/.claude/skills/to-prd/SKILL.md
121fc4285b454d258c8afd42e115381db182e03948bf4fd79fddb511e183290c  /c/Users/pc/.claude/skills/harness-resume/SKILL.md
2504578ef679e35caaac40cd3757913804a6cab51abbc5d390da43994f8ebd8c  /c/Users/pc/.claude/skills/harness-plan/SKILL.md
2b45f55dd4e19a09117ee2adb36b9cdf79609fce3b4fb3dfe91cc1cff84634fa  /c/Users/pc/.claude/skills/harness/SKILL.md
4754fe94c00f6c6dcfcc82a095b156b9916cab0fd712a334aee85711253f568a  /c/Users/pc/.claude/skills/harness-start/SKILL.md
6a74dc2f6a5a9fef7ca985119906c8901a13f15d768de8147acb6683961e2aba  /c/Users/pc/.claude/skills/harness-arc/SKILL.md
6c79047572ac12d6e81f912d6cc724a35f6196283ea1e56f4e7a73bf3d48e367  /c/Users/pc/.claude/skills/subagent-task-tree/MANAGER-BRIEF-TEMPLATE.md
6cad1dff33d2e540e27e7d76b8a1ef8ea5c09813916e7065276ebd1752e600f1  /c/Users/pc/.claude/skills/subagent-task-tree/AUDIT-PROMPTS.md
6f01f185b56aa5a1e87b139ef4f59fdeda6403715c6ca56937ed3dccbb539aa2  /c/Users/pc/.claude/skills/harness-stop/SKILL.md
7196def8fc41f6bccb43a97017fa47844f99b41ffdc5f4d870f6f10fe8c7c12a  /c/Users/pc/.claude/skills/harness-status/SKILL.md
8253da17ecf69895ad5ab4907348c597cb5437e47a797717e4a2ee353eeaa3b5  /c/Users/pc/.claude/skills/to-issues/SKILL.md
86a98602710be839379b7f73caf52426c61c64bdc0e0e624a2938adacf9ce37b  /c/Users/pc/.claude/skills/handoff/SKILL.md
905c139df10e00c8262852c8820917b04bc6e254028ee4b15aa1bf1546f086d9  /c/Users/pc/.claude/skills/harness-uninstall/SKILL.md
a37e0e9697144819e1d965176ac4ae5bc3fa02d11e7812036bbcadf6dafe2400  /c/Users/pc/.claude/skills/writing-plans/LICENSE
a7205a64f340f91b16171682f0a1c87f03e485c06228fec962cd717f7e105a0c  /c/Users/pc/.claude/skills/subagent-task-tree/SKILL.md
be99d39e2e8b890c1839e429e9899faaf5f6cd07090ccde101ce6271482c9093  /c/Users/pc/.claude/skills/harness-issue/SKILL.md
ca667677f4cfa71912094704a27c56d290b5fa2fc4f07318ff4e194cc1c35e92  /c/Users/pc/.claude/skills/caveman/SKILL.md
cc75ad111b863506d7a1ca1dcc87abfda7a934e03d94edb6db58121022ea2d79  /c/Users/pc/.claude/skills/harness-prd/SKILL.md
cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30  /c/Users/pc/.claude/skills/caveman/LICENSE
eb265e342a181dee6718f4a632e85e4e5089bf08fca6e275724e3e6e5983c000  /c/Users/pc/.claude/skills/harness-init/SKILL.md
fa1526f2a17b2329d9fd525ac67f8cf9e4974d6ecad391876d9b40f6fbb0b5ca  /c/Users/pc/.claude/skills/writing-plans/SKILL.md
SHA
