#!/usr/bin/env bash
# test_status_host.sh — `harness status` outside any project shows EVERY fleet on the host (#184),
# read from the $HARNESS_FLEETS_DIR registry, instead of dying with "not inside a Harness project".
# `--all` forces the host view from inside a project; without it, a project's status is unchanged.
# tmux / gh / ps are PATH stubs, so nothing here reaches a real tmux server or GitHub.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
CLI="$HERE/../bin/harness"

T="$(mktemp -d)"; trap 'rm -rf "$T"; tmp_cleanup' EXIT
export HARNESS_HOME="$T/host" HARNESS_FLEETS_DIR="$T/host/fleets"
mkdir -p "$HARNESS_FLEETS_DIR" "$T/bin" "$T/alpha/.harness/run" "$T/elsewhere"
unset STATE_DIR HARNESS_STATE_DIR_OK

cat > "$T/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in ls) printf 'al-web-i7\t%s\n' "$(date +%s)";; *) exit 1;; esac
EOF
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") echo '[{"number":7,"labels":[{"name":"agent-working"}]}]';;
  *) exit 1;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/ps"
chmod +x "$T/bin/"*
# fleetview runs these as native programs, which cannot start an extensionless shell script: on Windows each stub also gets a
# .cmd shim that hands it to Git's bash (run_cmd resolves the program through PATH and PATHEXT, #607).
if real_windows_host; then
  BASH_W="$(cygpath -w "$(command -v bash)")"
  for s in tmux gh ps; do printf '@"%s" "%%~dp0%s" %%*\r\n' "$BASH_W" "$s" > "$T/bin/$s.cmd"; done
fi
export PATH="$T/bin:$PATH"

printf ': "${HARNESS_MODE:=issue-only}"\n: "${HARNESS_SESS_PREFIX:=al}"\n' > "$T/alpha/.harness/config"
echo "$$" > "$T/alpha/.harness/run/worker-1.pid"
# (the registry holds native paths on Windows, which a native Python can open: C:/x, not /c/x)
printf '{"prefix":"al","project":"%s","run_dir":"%s","slugs":["acme/web"]}\n' \
  "$(native_path "$T/alpha/.harness")" "$(native_path "$T/alpha/.harness/run")" > "$HARNESS_FLEETS_DIR/alpha.json"
printf '{"prefix":"be","project":"%s","run_dir":"%s","slugs":["acme/api"]}\n' \
  "$(native_path "$T/gone/.harness")" "$(native_path "$T/gone/.harness/run")" > "$HARNESS_FLEETS_DIR/beta.json"

echo "== outside any project: every registered fleet, exit 0 =="
OUT="$(cd "$T/elsewhere" && "$CLI" status 2>&1)"; rc=$?
assert_eq "$rc" "0" "host view exits 0"
assert_ok "names the host view"           grep -q "every fleet on this host" <<<"$OUT"
assert_ok "fleet alpha rendered"          grep -q "■ al .*RUNNING" <<<"$OUT"
assert_ok "alpha's live session + issue"  grep -q "al-web-i7 .*#7" <<<"$OUT"
assert_ok "fleet beta rendered as missing" grep -q "■ be .*missing" <<<"$OUT"
assert_no "no not-inside-a-project error" grep -q "not inside a Harness project" <<<"$OUT"

echo "== --all forces the host view from inside a project =="
OUT="$(cd "$T/alpha" && "$CLI" status --all 2>&1)"; rc=$?
assert_eq "$rc" "0" "status --all exits 0"
assert_ok "--all shows every fleet" grep -q "■ be .*missing" <<<"$OUT"

echo "== inside a project without --all: the project dashboard, unchanged =="
OUT="$(cd "$T/alpha" && "$CLI" status 2>&1)"
assert_ok "project dashboard"        grep -q "Harness fleet" <<<"$OUT"
assert_no "not the host view"        grep -q "every fleet on this host" <<<"$OUT"

finish
