#!/usr/bin/env bash
# test_cli_readme.sh — #188 / PRD #189: HARNESS_CLI is read only by the adapter dispatcher, and the
# README's "Supported agent CLIs" table is the feature matrix: it lists exactly the CLIs whose matrix
# column is green, each with its fixtures' version, and exactly the matrix's rows: ✓ where the cell
# is ok, `n/a: <reason>` where the matrix says that row cannot exist for the CLI (n/a:<reason>).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
ROOT="$HERE/.."
hits="$(cd "$ROOT" && grep -l 'HARNESS_CLI' scripts/*.sh scripts/cli/*.sh)"
assert_eq "$hits" "scripts/cli/dispatch.sh" "only the dispatcher reads HARNESS_CLI"
assert_eq "$(cd "$ROOT" && grep -l 'HARNESS_CLI' scripts/*.py)" "" "no python script reads HARNESS_CLI"

cells="$(bash "$HERE/test_cli_matrix.sh" --tsv 2>/dev/null)"
assert_ok "the matrix produced cells" test -n "$cells"
green="$(awk -F'\t' '$3!="ok" && $3!~/^n\/a:/{bad[$1]=1} {all[$1]=1} END{for (c in all) if (!(c in bad)) print c}' <<<"$cells" | sort)"
table="$(sed -n '/^### Supported agent CLIs/,/^## /p' "$ROOT/docs/reference.md" | grep '^|')"
header="$(head -1 <<<"$table")"
listed="$(tr '|' '\n' <<<"$header" | sed -n 's/^ *`\([a-z-]*\)` *$/\1/p' | sort)"
assert_eq "$listed" "$green" "README lists exactly the CLIs whose matrix column is green"

# col <cli> — the table column (1-based, after splitting on |) that holds <cli>.
col(){ tr '|' '\n' <<<"$header" | grep -nxE " *\`$1\` *" | cut -d: -f1; }
for c in $green; do
  # The fixture is the CLI's own --version line; a sentence's full stop there (copilot's) is not
  # part of the version (#316).
  v="$(sed -n 1p "$HERE/fixtures/cli/$c/VERSION")"; v="${v%.}"
  got="$(grep '^| verified on ' <<<"$table" | cut -d'|' -f"$(col "$c")")"
  assert_ok "README: $c verified on its fixture version" test "${got#" $v, "}" != "$got"
done

rows="$(awk -F'\t' '{print $2}' <<<"$cells" | sort -u)"
readme_rows="$(sed -n 's/^| `\([a-z-]*\)` |.*/\1/p' <<<"$table" | sort)"
assert_eq "$readme_rows" "$rows" "README feature rows are exactly the matrix rows"
for c in $green; do
  bad=""
  while IFS=$'\t' read -r cli row res; do
    [[ $cli == "$c" ]] || continue
    cell="$(grep "^| \`$row\` |" <<<"$table" | cut -d'|' -f"$(col "$c")" | xargs)"
    [[ $res == ok && $cell == ✓* ]] || [[ $res == n/a:* && $cell == "n/a: ${res#n/a:}" ]] || bad+=" $row"
  done <<<"$cells"
  assert_eq "${bad# }" "" "README: every $c row is ✓ exactly where its matrix cell is ok, n/a with its reason"
done
# #316: the config table has a row for every setting the adapters read: each HARNESS_* in
# scripts/cli/*.sh, but for the few Harness sets itself, never an operator.
internal="HARNESS_BOOTSTRAP_PROMPT HARNESS_SESSION HARNESS_ENGINE_PLUGINS HARNESS_CLAUDE_CONFIG HARNESS_AGY_TRUST_FILE"
# HARNESS_BOOTSTRAP_PROMPT: lib.sh's fixed launch prompt. HARNESS_SESSION: a lane variable, set per
# session. HARNESS_ENGINE_PLUGINS: install.sh points it at the placed engine. HARNESS_CLAUDE_CONFIG,
# HARNESS_AGY_TRUST_FILE: test seams (helpers.sh).
read_vars="$(cd "$ROOT" && grep -ohE '\bHARNESS_[A-Z0-9_]*[A-Z0-9]\b' scripts/cli/*.sh | sort -u)"
config="$(sed -n '/^## Configuration/,/^### /p' "$ROOT/docs/reference.md" | grep '^| `HARNESS_' | cut -d'|' -f2 | grep -oE 'HARNESS_[A-Z0-9_]+' | sort -u)"
undocumented="$(comm -23 <(echo "$read_vars") <(echo "$config") | grep -vxF -f <(tr ' ' '\n' <<<"$internal"))"
assert_eq "$undocumented" "" "the config table has a row for every HARNESS_* setting the adapters read"
for v in $internal; do
  assert_ok "$v, left out of the config table, is still read by an adapter" grep -qw "$v" <<<"$read_vars"
done

# #321: the usage-limit checkpoints' "Usage source" table has one row per CLI with an adapter
# (cli_list), each naming where its windows come from, or that it has none — one CLI per row, so the
# one-line subset check below never sees it.
all_clis="$(source "$ROOT/scripts/cli/dispatch.sh"; cli_list | sort)"
usage_rows="$(sed -n '/^### Usage-limit checkpoints/,/^### /p' "$ROOT/docs/reference.md" | sed -n 's/^| `\([a-z0-9-]*\)` | .*[^ ].* |$/\1/p' | sort)"
assert_eq "$usage_rows" "$all_clis" "the README usage-source table has one row per CLI in cli_list"

# …and no README line outside the support table lists some of the supported CLIs as if they were all
# of them (`claude` or `agy`): a run of backticked names, each perhaps glossed in parentheses, joined
# by commas, slashes, `or` or `and`, that names two or more supported CLIs names every one.
clis="$(tr '\n' ' ' <<<"$green")"
item='`[a-z0-9-]+`( \([^)]*\))?'
partial=""
while IFS= read -r line; do
  n="${line%%:*}"
  while IFS= read -r run; do
    [[ -n $run ]] || continue
    k=0; for c in $clis; do grep -qF "\`$c\`" <<<"$run" && k=$((k+1)); done
    (( k >= 2 && k < $(wc -w <<<"$clis") )) && partial+="README.md:$n: $run"$'\n'
  done < <(grep -oE "$item( *(,|/| or| and|, or|, and) *$item)+" <<<"${line#*:}")
done < <(awk '/^### Supported agent CLIs/{s=1} s && /^## /{s=0} !(s && /^\|/){print NR":"$0}' "$ROOT/docs/reference.md"; grep -n '' "$ROOT/README.md")
assert_eq "${partial%$'\n'}" "" "no README line outside the support table names a subset of its CLIs as the list"
finish
