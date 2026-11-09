#!/usr/bin/env bash
# test_tier.sh — #619: "When to use Harness". `harness tier decide` picks direct / lane / fleet from an
# estimate against the ONE thresholds file (scripts/tier.toml, provisional until #621) and prints the
# reason plus a time+cost for direct and fleet; --prefer is the user's override either way.
# `harness tier overlap` guards the direct path on a live fleet: against a stubbed gh and real git
# worktrees it refuses (exit 1) a fix that touches a file an open agent-working issue (committed in its
# branch, or uncommitted in its worktree) or an open PR owns, and clears (exit 0) one that does not.
# The skills (/harness, /harness-prd, /harness-issue, /harness-arc) run the check first.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
source "$HERE/helpers.sh"
unset_inherited_config; unset HARNESS_REPO HARNESS_DEFAULT_BRANCH
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
H(){ bash "$ROOT/bin/harness" "$@"; }
has(){ grep -qi -- "$1" <<<"$2"; }   # has <pattern> <text>
jq_(){ python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

# ── decide: the three tiers ─────────────────────────────────────────────────────────────────────
d(){ H tier decide --json "$@"; }
assert_eq "$(d --criteria 3 --lines 80 --files 3 --subsystems 1 | jq_ 'd["tier"]')" direct "small, one subsystem, user around -> direct"
assert_eq "$(d --criteria 8 --lines 500 --files 10 --subsystems 1 | jq_ 'd["tier"]')" direct "exactly at every direct limit -> direct"
assert_eq "$(d --criteria 3 --lines 80 --files 3 --subsystems 1 --unattended --minutes 20 | jq_ 'd["tier"]')" direct "unattended but under 45 min -> direct"
assert_eq "$(d --criteria 3 --lines 80 --files 3 --subsystems 1 --unattended --minutes 90 | jq_ 'd["tier"]')" lane "unattended 90 min -> single lane"
assert_eq "$(d --criteria 3 --lines 80 --files 3 --subsystems 1 --wants-review | jq_ 'd["tier"]')" lane "independent review wanted -> single lane"
assert_eq "$(d --criteria 9 --lines 80 --files 3 --subsystems 1 | jq_ 'd["tier"]')" lane "9 criteria: over direct, under fleet -> single lane"
assert_eq "$(d --criteria 4 --lines 501 --files 3 --subsystems 1 | jq_ 'd["tier"]')" lane "501 lines -> single lane"
assert_eq "$(d --criteria 4 --lines 50 --files 11 --subsystems 1 | jq_ 'd["tier"]')" lane "11 files -> single lane"
assert_eq "$(d --criteria 16 --lines 80 --files 3 --subsystems 1 | jq_ 'd["tier"]')" fleet "16 criteria -> fleet"
assert_eq "$(d --criteria 15 --lines 80 --files 3 --subsystems 1 | jq_ 'd["tier"]')" lane "15 criteria -> still one session"
assert_eq "$(d --criteria 5 --lines 80 --files 3 --subsystems 3 | jq_ 'd["tier"]')" fleet "several subsystems -> fleet"
assert_eq "$(d --criteria 5 --lines 80 --files 3 --subsystems 1 --workstreams 2 --pool 3 | jq_ 'd["tier"]')" fleet "2 workstreams with POOL>1 -> fleet"
assert_eq "$(d --criteria 5 --lines 80 --files 3 --subsystems 1 --workstreams 2 --pool 1 | jq_ 'd["tier"]')" direct "2 workstreams but POOL=1 -> not a fleet reason"
assert_eq "$(d --criteria 5 --lines 80 --files 3 --subsystems 1 --multi-step-plan | jq_ 'd["tier"]')" fleet "a multi-step plan -> fleet"
assert_eq "$(d --criteria 5 --lines 80 --files 3 --subsystems 1 --unattended --minutes 240 | jq_ 'd["tier"]')" fleet "hours unattended -> fleet"

# a negative count is a mistake in what was passed, not a small change: usage error, exit 2, no tier (#677)
for opt in criteria lines files subsystems workstreams pool minutes; do
  args=(--criteria 3 --lines 80 --files 3 --subsystems 1); args+=("--$opt" -1)
  out="$(H tier decide "${args[@]}" 2>&1)"; rc=$?
  assert_eq "$rc" 2 "--$opt -1 -> usage error, exit 2"
  assert_ok "--$opt -1 names the negative value" grep -q 'negative' <<<"$out"
  assert_no "--$opt -1 prints no tier" grep -q '^TIER:' <<<"$out"
done
out="$(H tier decide --criteria -1 --lines -5 --files 3 --subsystems 1 2>&1)"; rc=$?
assert_eq "$rc" 2 "--criteria -1 --lines -5 -> exit 2"
assert_no "…and no TIER line" grep -q '^TIER:' <<<"$out"
assert_eq "$(d --criteria 0 --lines 0 --files 0 --subsystems 0 | jq_ 'd["tier"]')" direct "zero counts are still fine"
# --pool is a worker count: 0 (and -0) is not a fleet -> usage error, exit 2, no tier (#719); other counts keep 0
for zero in 0 -0 00; do
  out="$(H tier decide --criteria 3 --lines 80 --files 3 --subsystems 1 --pool "$zero" 2>&1)"; rc=$?
  assert_eq "$rc" 2 "--pool $zero -> usage error, exit 2"
  assert_ok "--pool $zero says it must be 1 or more" grep -q '1 or more' <<<"$out"
  assert_no "--pool $zero prints no tier" grep -q '^TIER:' <<<"$out"
done
assert_eq "$(d --criteria 3 --lines 80 --files 3 --subsystems 1 --pool 1 | jq_ 'd["tier"]')" direct "--pool 1 is accepted"
for opt in criteria lines files subsystems workstreams minutes; do
  args=(--criteria 3 --lines 80 --files 3 --subsystems 1); args+=("--$opt" 0)
  H tier decide "${args[@]}" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" 0 "--$opt 0 is still accepted"
done

# reason + both estimates, in the text and JSON output
out="$(H tier decide --criteria 20 --lines 80 --files 3 --subsystems 1)"
assert_ok "text names the tier"            grep -qx 'TIER: fleet' <<<"$out"
assert_ok "text names the reason"          grep -q '^reason: .*20 acceptance criteria' <<<"$out"
assert_ok "text shows the direct estimate" grep -qE '^direct: ~[0-9]+ min, ~\$[0-9.]+' <<<"$out"
assert_ok "text shows the fleet estimate"  grep -qE '^fleet: +~[0-9]+ min, ~\$[0-9.]+' <<<"$out"
assert_ok "text marks the thresholds provisional (#621)" grep -q 'provisional until #621' <<<"$out"
j="$(d --criteria 20 --lines 80 --files 3 --subsystems 1)"
assert_ok "json: direct and fleet each carry minutes and usd" \
  test "$(jq_ 'all(k in d["estimate"][t] for t in ("direct","fleet") for k in ("minutes","usd"))' <<<"$j")" = True
assert_ok "json: fleet costs more than direct" \
  test "$(jq_ 'd["estimate"]["fleet"]["usd"] > d["estimate"]["direct"]["usd"]' <<<"$j")" = True

# the override, in both directions; the recommendation stays visible
j="$(d --criteria 20 --lines 80 --files 3 --subsystems 1 --prefer direct)"
assert_eq "$(jq_ 'd["tier"]' <<<"$j")" direct "override: 'just do it here' on a fleet-sized job -> direct"
assert_eq "$(jq_ 'd["recommended"]' <<<"$j")" fleet "override keeps the recommendation"
assert_ok "override says it was the user's" grep -q 'user override' <<<"$(H tier decide --criteria 20 --lines 80 --files 3 --subsystems 1 --prefer direct)"
j="$(d --criteria 2 --lines 20 --files 1 --subsystems 1 --prefer fleet)"
assert_eq "$(jq_ 'd["tier"]' <<<"$j")" fleet "override: 'use the fleet anyway' on a tiny job -> fleet"
assert_eq "$(jq_ 'd["recommended"]' <<<"$j")" direct "…while the check had recommended direct"
assert_eq "$(jq_ 'd["override"] is None' <<<"$(d --criteria 2 --lines 20 --files 1 --subsystems 1 --prefer direct)")" True "agreeing with the check is no override"

# thresholds live in one file, marked provisional with the pointer to #621
assert_ok "scripts/tier.toml exists" test -f "$ROOT/scripts/tier.toml"
assert_ok "tier.toml is marked provisional" \
  has 'provisional.*#621\|#621.*provisional\|provisional' "$(cat "$ROOT/scripts/tier.toml")"
assert_ok "tier.toml points at #621" has '#621' "$(cat "$ROOT/scripts/tier.toml")"
sed 's/^max_criteria .*/max_criteria     = 2/' "$ROOT/scripts/tier.toml" > "$T/tier.toml"
assert_eq "$(HARNESS_TIER_TOML="$T/tier.toml" H tier decide --json --criteria 3 --lines 10 --files 1 --subsystems 1 | jq_ 'd["tier"]')" lane \
  "a changed number in the one file changes the verdict"

# a hand-edited tier.toml: a BOM, an empty file, a partial file and a broken file never print a traceback (#715)
dd(){ HARNESS_TIER_TOML="$1" H tier decide --json --criteria 3 --lines 10 --files 1 --subsystems 1; }
printf '\xef\xbb\xbf' > "$T/bom.toml"; cat "$ROOT/scripts/tier.toml" >> "$T/bom.toml"
assert_eq "$(dd "$T/bom.toml" | jq_ 'd["tier"]')" direct "a BOM-prefixed tier.toml loads"
printf '\xef\xbb\xbf' > "$T/bom2.toml"; sed 's/^max_criteria .*/max_criteria     = 2/' "$ROOT/scripts/tier.toml" >> "$T/bom2.toml"
assert_eq "$(dd "$T/bom2.toml" | jq_ 'd["tier"]')" lane "…and its numbers are the ones read"
: > "$T/empty.toml"
assert_eq "$(dd "$T/empty.toml" | jq_ 'd["tier"]')" direct "an empty tier.toml uses the defaults"
printf '[direct]\nmax_criteria = 2\n' > "$T/partial.toml"
out="$(dd "$T/partial.toml" 2>&1)"; rc=$?
assert_eq "$rc" 0 "a partial tier.toml exits 0"
assert_eq "$(jq_ 'd["tier"]' <<<"$out")" lane "…the keys it has are used"
assert_eq "$(HARNESS_TIER_TOML="$T/partial.toml" H tier thresholds | jq_ 'd["fleet"]["min_criteria"]')" 16 "…and the keys it lacks fall back to the defaults"
printf '[direct\nmax_criteria = = 2\n' > "$T/bad.toml"
out="$(dd "$T/bad.toml" 2>&1)"; rc=$?
assert_eq "$rc" 2 "an unparsable tier.toml -> exit 2"
assert_eq "$(wc -l <<<"$out" | tr -d ' ')" 1 "…with a one-line error"
assert_ok "…naming the file" grep -q "$T/bad.toml" <<<"$out"
assert_no "…and no traceback" grep -q 'Traceback' <<<"$out"
printf '\xff\xfe[direct]\n' > "$T/bin.toml"
out="$(dd "$T/bin.toml" 2>&1)"; rc=$?
assert_eq "$rc" 2 "a tier.toml that is not UTF-8 -> exit 2"
assert_no "…and no traceback" grep -q 'Traceback' <<<"$out"
out="$(dd "$T/missing.toml" 2>&1)"; rc=$?
assert_eq "$rc" 2 "a missing tier.toml -> exit 2"
assert_ok "…naming the file" grep -q "$T/missing.toml" <<<"$out"
assert_no "…and no traceback" grep -q 'Traceback' <<<"$out"
assert_no "no prompt repeats a threshold number outside the file" \
  grep -rnE 'max_changed_lines|max_criteria' "$ROOT/skill" "$ROOT/prompts"

# ── overlap: stubbed gh + real worktrees ────────────────────────────────────────────────────────
R="$T/repo"; mkdir -p "$R/src" "$R/docs"; cd "$R"
git init -q -b main . && git config user.email t@t && git config user.name t
for f in src/a.py src/b.py src/z.py docs/c.md; do echo base > "$f"; done
git add -A && git commit -qm base
git worktree add -q -b issue/7 "$T/wt7" main
echo lane > "$T/wt7/src/a.py"; git -C "$T/wt7" commit -qam "lane 7 edits a"
git worktree add -q -b issue/8 "$T/wt8" main
echo wip > "$T/wt8/src/b.py"                       # uncommitted work in lane 8's worktree
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "issue list") echo '[{"number":7},{"number":8}]';;
  "pr list")    echo '[{"number":3,"headRefName":"other"}]';;
  "pr diff")    [[ "$3" == 3 && "$*" == *--name-only* ]] && echo docs/c.md || exit 1;;
  *) exit 1;;
esac
SH
chmod +x "$BIN/gh"; export GH_LOG="$T/gh.log" PATH="$BIN:$PATH"; : > "$GH_LOG"
ov(){ H tier overlap -R acme/widget --base main --repo-dir "$R" --files "$1"; }

out="$(ov src/z.py)"; rc=$?
assert_eq "$rc" 0 "no lane or PR touches src/z.py -> exit 0"
assert_ok "…and says the direct path is clear" grep -q 'direct path is clear' <<<"$out"
out="$(ov src/a.py)"; rc=$?
assert_eq "$rc" 1 "src/a.py is in open issue #7's branch -> refuses (exit 1)"
assert_ok "…names the owner" has 'issue #7' "$out"
assert_ok "…and routes to /harness-issue" has '/harness-issue' "$out"
out="$(ov src/b.py)"; rc=$?
assert_eq "$rc" 1 "src/b.py is uncommitted in open issue #8's worktree -> refuses"
assert_ok "…names issue #8" grep -q 'issue #8' <<<"$out"
out="$(ov docs/c.md)"; rc=$?
assert_eq "$rc" 1 "docs/c.md is in open PR #3 -> refuses"
assert_ok "…names PR #3" grep -q 'PR #3' <<<"$out"
out="$(ov src/z.py,src/a.py,docs/c.md)"; rc=$?
assert_eq "$rc" 1 "one overlapping file among clear ones still refuses"
assert_ok "…lists the lane owner" has 'issue #7' "$out"
assert_ok "…and the PR owner" has 'PR #3' "$out"
assert_ok "json: overlap flag + hits" \
  test "$(H tier overlap -R acme/widget --base main --repo-dir "$R" --files src/a.py --json | jq_ 'd["overlap"] and d["hits"][0]["files"]==["src/a.py"]')" = True
assert_ok "it asked gh for the agent-working issues" grep -q 'issue list.*--label agent-working' "$GH_LOG"
assert_ok "it read each open PR's files with gh pr diff --name-only" grep -q 'pr diff 3.*--name-only' "$GH_LOG"
cd "$HERE"
echo '[]' > /dev/null
# no open work at all -> clear
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
echo '[]'
SH
assert_eq "$(H tier overlap -R acme/widget --base main --repo-dir "$R" --files src/a.py >/dev/null; echo $?)" 0 "no open lane or PR -> clear even for a file a closed lane touched"
assert_eq "$(H tier overlap --files src/a.py >/dev/null 2>&1; echo $?)" 2 "no repo -> exit 2, not a silent clear"

# ── a gh or git call that fails is "could not check" (exit 3), never "clear" (#708) ─────────────
# FAIL names the gh subcommand that fails ("pr list", "issue list", "pr diff", or "all"); the rest answer as before.
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
sub="$1 $2"
if [[ "$FAIL" == all || "$FAIL" == "$sub" ]]; then echo "API rate limit exceeded" >&2; exit 1; fi
case "$sub" in
  "issue list") echo '[{"number":7}]';;
  "pr list")    echo '[{"number":3,"headRefName":"other"}]';;
  "pr diff")    echo docs/c.md;;
  *) exit 1;;
esac
SH
unchecked(){   # unchecked <label> <expected command text> <overlap args…>: text + --json both report "could not check"
  local label="$1" want="$2"; shift 2
  local err rc out
  err="$(H tier overlap "$@" 2>&1 >"$T/out.txt")"; rc=$?; out="$(cat "$T/out.txt")"
  assert_eq "$rc" 3 "$label -> exit 3 (not 0 clear, not 1 overlap)"
  assert_ok "$label: stderr names the failed command" grep -qF -- "$want" <<<"$err"
  assert_no "$label: never says the direct path is clear" grep -qi 'is clear' <<<"$out$err"
  err="$(H tier overlap "$@" --json 2>/dev/null)"; rc=$?
  assert_eq "$rc" 3 "$label --json -> exit 3"
  assert_ok "$label --json: an error field, overlap is not false" \
    test "$(jq_ '("error" in d) and d["overlap"] is not False and d["hits"]==[]' <<<"$err")" = True
}
ovargs=(-R acme/widget --base main --repo-dir "$R" --files src/z.py)
FAIL="pr list"    unchecked "gh pr list fails"    'gh pr list'    "${ovargs[@]}"
FAIL="issue list" unchecked "gh issue list fails" 'gh issue list' "${ovargs[@]}"
FAIL="pr diff"    unchecked "gh pr diff fails"    'gh pr diff'    "${ovargs[@]}"
FAIL=all          unchecked "every gh call fails" 'gh pr list'    "${ovargs[@]}"
FAIL=none         unchecked "git worktree list fails (not a git dir)" 'git worktree list' \
                  -R acme/widget --base main --repo-dir "$T" --files src/z.py
FAIL=none         unchecked "git diff fails (base ref missing)" 'git diff' \
                  -R acme/widget --base nosuchbase --repo-dir "$R" --files src/z.py
FAIL=none assert_eq "$(H tier overlap "${ovargs[@]}" >/dev/null 2>&1; echo $?)" 0 "the same stub, nothing failing -> clear, exit 0"
# a lane whose branch does not exist yet owns no files — that is not a failure
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in "issue list") echo '[{"number":99}]';; *) echo '[]';; esac
SH
assert_eq "$(H tier overlap "${ovargs[@]}" >/dev/null 2>&1; echo $?)" 0 "agent-working issue with no branch yet -> clear, not an error"
# -R must be owner/name in every form
for bad in -x =-x x a/ /b a/-x -a/b 'a b/c' 'a/b/c'; do
  assert_eq "$(H tier overlap --files a -R="$bad" >/dev/null 2>&1; echo $?)" 2 "-R=$bad -> usage error, exit 2"
done
assert_eq "$(H tier overlap --files a -R -x >/dev/null 2>&1; echo $?)" 2 "-R -x -> usage error, exit 2"
assert_eq "$(H tier overlap --files a -R nonsense >/dev/null 2>&1; echo $?)" 2 "-R nonsense -> usage error, exit 2"
assert_eq "$(HARNESS_REPO=nonsense H tier overlap --files a >/dev/null 2>&1; echo $?)" 2 "HARNESS_REPO=nonsense -> exit 2"
# --base must not start with '-': git would read it as an option (#748); git is never run
GBIN="$T/gitbin"; mkdir -p "$GBIN"; REAL_GIT="$(command -v git)"
printf '#!/usr/bin/env bash\necho "$*" >> "$GIT_LOG"\nexec "%s" "$@"\n' "$REAL_GIT" > "$GBIN/git"; chmod +x "$GBIN/git"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in "issue list") echo '[{"number":5}]';; *) echo '[]';; esac
SH
export GIT_LOG="$T/git.log"; : > "$GIT_LOG"; rm -f "$T/x"
for bad in "--output=$T/x" -x -; do
  err="$(PATH="$GBIN:$PATH" H tier overlap --files a -R a/b --repo-dir "$R" --base="$bad" 2>&1 >/dev/null)"; rc=$?
  assert_eq "$rc" 2 "--base=$bad -> usage error, exit 2"
  assert_ok "--base=$bad: names --base" grep -qF -- '--base' <<<"$err"
done
PATH="$GBIN:$PATH" H tier overlap --files a -R a/b --repo-dir "$R" --base - >/dev/null 2>&1; rc=$?
assert_eq "$rc" 2 "--base - -> usage error, exit 2"
assert_eq "$(wc -c < "$GIT_LOG" | tr -d ' ')" 0 "a dash-leading --base never runs git"
assert_no "…and git never wrote the --output path" test -e "$T/x"
PATH="$GBIN:$PATH" H tier overlap --files a -R a/b --repo-dir "$R" --base main >/dev/null 2>&1
assert_ok "a good --base still runs git (the shim is live)" test -s "$GIT_LOG"
# an empty or blank --files list checks nothing -> usage error, never "clear"
for blank in '' ' ' ',' ' , '; do
  err="$(H tier overlap -R acme/widget --base main --repo-dir "$R" --files "$blank" 2>&1 >"$T/out.txt")"; rc=$?
  assert_eq "$rc" 2 "--files '$blank' -> usage error, exit 2"
  assert_ok "--files '$blank': says no files to check, never 'clear'" \
    bash -c '[[ "$1" == *"no files to check"* && "$2" != *clear* ]]' _ "$err" "$(cat "$T/out.txt")"
done

# ── the skills run the check first ──────────────────────────────────────────────────────────────
S="$ROOT/skill/SKILL.md"
SEC="$(awk '/^## When to use Harness/{f=1;next} f&&/^## /{exit} f' "$S")"
assert_ok "/harness has a 'When to use Harness' section"       test -n "$SEC"
assert_ok "/harness has a 'When to use Harness' section" test -n "$SEC"
assert_ok "…names direct"      has 'direct' "$SEC"
assert_ok "…names single lane" has 'single lane' "$SEC"
assert_ok "…names fleet"       has 'fleet' "$SEC"
assert_ok "…it shows the estimate for both direct and fleet" has 'time and cost' "$SEC"
assert_ok "…user can override: use the fleet anyway" has 'use the fleet anyway' "$SEC"
assert_ok "…user can override: just do it here"      has 'just do it here' "$SEC"
assert_ok "…it runs harness tier decide"             has 'harness tier decide' "$SEC"
assert_ok "…direct on a live fleet checks overlap"   has 'harness tier overlap' "$SEC"
assert_ok "…and routes an overlap to /harness-issue" has 'instead' "$SEC"
assert_ok "…direct records 'Direct fix: fits one session' in the PR body" has 'Direct fix: fits one session' "$SEC"
assert_ok "…direct runs rtdd which, not the full suite" has 'rtdd which' "$SEC"
assert_ok "…thresholds point at tier.toml"           has 'tier.toml' "$SEC"
assert_ok "…and at #621, marked provisional"         has '#621' "$SEC"
assert_ok "…direct needs no harness init and no PRD" has 'No `harness init`, no PRD' "$SEC"
IDEA_LN="$(grep -n '^## On `/harness <idea>`' "$S" | cut -d: -f1)"; TIER_LN="$(grep -n '^## When to use Harness' "$S" | cut -d: -f1)"
assert_ok "the tier section comes before the idea flow" test "$TIER_LN" -lt "$IDEA_LN"
IDEA="$(awk '/^## On `\/harness <idea>`/{f=1;next} f&&/^## /{exit} f' "$S")"
assert_ok "idea flow: step 0 is the tier check" has 'Step 0 is the tier check' "$IDEA"
assert_ok "idea flow: …before the install and harness init" has 'before the install and before `harness init`' "$(tr '\n' ' ' <<<"$IDEA")"
NOT="$(awk '/^## When NOT to touch/{f=1;next} f&&/^## /{exit} f' "$S")"
assert_ok "'When NOT to touch' allows a direct fix"          has 'direct fix' "$NOT"
assert_ok "…that overlaps no lane (harness tier overlap)"    has 'harness tier overlap' "$NOT"
assert_no "…and no longer forbids all by-hand unit work"     grep -q "Don't do a unit's work" "$S"
for sk in harness-prd harness-issue harness-arc; do
  F="$ROOT/skill/$sk/SKILL.md"; B="$(cat "$F")"
  assert_ok "$sk: step 0 runs the tier check"        grep -q '^## 0\. Tier check' "$F"
  assert_ok "$sk: runs harness tier decide"          has 'harness tier decide' "$B"
  assert_ok "$sk: offers the direct path"            has 'direct' "$B"
  assert_ok "$sk: overlap routes to /harness-issue"  has 'harness tier overlap' "$B"
  t="$(grep -n '^## 0\. Tier' "$F" | cut -d: -f1)"; g="$(grep -n '^## 1\.' "$F" | head -1 | cut -d: -f1)"
  assert_ok "$sk: step 0 precedes step 1"            test "$t" -lt "$g"
done
finish
