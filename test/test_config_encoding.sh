#!/usr/bin/env bash
# #1002: the engine (lib.sh sourcing .harness/config) and stats/forecast (stats.read_config) must read a config
# with a leading UTF-8 BOM, CRLF or lone-CR line endings the same way, key by key.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
rc=0

KEYS=(HARNESS_REPO HARNESS_OWNER HARNESS_UNIT HARNESS_CHECKOUT)
BODY=(': "${HARNESS_REPO:=o/r}"' 'HARNESS_OWNER=own' "export HARNESS_UNIT='u1'" 'HARNESS_CHECKOUT="/srv/co"')

# write_cfg <state-dir> <bom 0|1> <eol-bytes>
write_cfg(){ local d="$1" bom="$2" eol="$3" l
  mkdir -p "$d"; : > "$d/config"
  [[ $bom == 1 ]] && printf '\xef\xbb\xbf' >> "$d/config"
  for l in "${BODY[@]}"; do printf '%s' "$l" >> "$d/config"; printf "$eol" >> "$d/config"; done; }

engine_val(){ # <state-dir> <key>
  ( unset "${KEYS[@]}"; RUN_DIR="$T/run" STATE_DIR="$1" bash -c 'source "$0/../scripts/lib.sh" 2>&1 >/dev/null; eval "printf %s \"\$$1\""' "$HERE" "$2" ); }
stats_val(){ # <state-dir> <key>
  python3 -I -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("stats", sys.argv[1] + "/../scripts/stats.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.stdout.write(m.read_config(sys.argv[2]).get(sys.argv[3], ""))' "$HERE" "$1" "$2"; }
engine_err(){ ( unset "${KEYS[@]}"; RUN_DIR="$T/run" STATE_DIR="$1" bash -c 'source "$0/../scripts/lib.sh" >/dev/null' "$HERE" 2>&1 ); }

want(){ case $1 in HARNESS_REPO) echo o/r;; HARNESS_OWNER) echo own;; HARNESS_UNIT) echo u1;; HARNESS_CHECKOUT) echo /srv/co;; esac; }

n=0
for variant in "lf:0:\\n" "bom:1:\\n" "crlf:0:\\r\\n" "bom-crlf:1:\\r\\n" "lone-cr:0:\\r" "bom-lone-cr:1:\\r"; do
  IFS=: read -r name bom eol <<<"$variant"
  d="$T/p$((n++))/.harness"; write_cfg "$d" "$bom" "$eol"
  for k in "${KEYS[@]}"; do
    w="$(want "$k")"
    assert_eq "$(engine_val "$d" "$k")" "$w" "engine reads $k from a $name config"
    assert_eq "$(stats_val "$d" "$k")"  "$w" "stats reads $k from a $name config"
  done
  assert_eq "$(engine_err "$d")" "" "engine prints nothing sourcing a $name config"
done
finish || rc=1
exit $rc
