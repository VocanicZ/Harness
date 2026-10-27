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
table="$(sed -n '/^### Supported agent CLIs/,/^## /p' "$ROOT/README.md" | grep '^|')"
header="$(head -1 <<<"$table")"
listed="$(tr '|' '\n' <<<"$header" | sed -n 's/^ *`\([a-z-]*\)` *$/\1/p' | sort)"
assert_eq "$listed" "$green" "README lists exactly the CLIs whose matrix column is green"

# col <cli> — the table column (1-based, after splitting on |) that holds <cli>.
col(){ tr '|' '\n' <<<"$header" | grep -nxE " *\`$1\` *" | cut -d: -f1; }
for c in $green; do
  v="$(sed -n 1p "$HERE/fixtures/cli/$c/VERSION")"
  got="$(grep '^| verified on ' <<<"$table" | cut -d'|' -f"$(col "$c")")"
  assert_ok "README: $c verified on its fixture version" grep -qF -- "$v" <<<"$got"
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
finish
