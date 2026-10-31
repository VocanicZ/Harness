#!/usr/bin/env bash
# test_install_npx.sh — #342: `npx -y github:VocanicZ/Harness` runs install.sh exactly as the curl
# install does. The package is install.sh + bin/harness-install.js only (so install.sh sees no
# checkout beside it, as under `curl | bash`), needs Node >= 18 and nothing else, and refuses native
# Windows with a pointer to WSL2. The entry runs against a STUB install.sh in a copy — never the real one.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
source "$HERE/helpers.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ── package.json ─────────────────────────────────────────────────────────────────────────────────
pj(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$ROOT/package.json" "$1"; }
assert_ok "package.json parses" python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ROOT/package.json"
assert_ok "one bin, so npx runs it without being told which" test "$(pj 'len(d["bin"])')" = 1
BIN="$(pj 'list(d["bin"].values())[0]')"
assert_ok "the bin is bin/harness-install.js" test "$BIN" = bin/harness-install.js
assert_ok "...which is executable" test -x "$ROOT/$BIN"
assert_ok "...with a node shebang" grep -qx '#!/usr/bin/env node' <(head -1 "$ROOT/$BIN")
assert_ok "engines: node >= 18" test "$(pj 'd["engines"]["node"]')" = '>=18'
assert_ok "no dependencies of any kind" test \
  "$(pj 'sum(len(d.get(k) or {}) for k in ("dependencies","devDependencies","optionalDependencies","peerDependencies"))')" = 0
assert_ok "no install-time scripts (npx must run nothing but the bin)" test "$(pj 'len(d.get("scripts") or {})')" = 0
assert_ok "files: exactly install.sh and the bin" test "$(pj 'sorted(d["files"])')" = "['bin/harness-install.js', 'install.sh']"

# What npm actually packs from a git checkout: no scripts/, plugins/ or skill/ — a checkout beside
# install.sh would make it load THAT tree's adapters instead of the published release's.
if command -v npm >/dev/null; then
  packed="$(cd "$T" && npm_config_cache="$T/npm-cache" npm pack --dry-run --json "$ROOT" 2>/dev/null \
    | python3 -c 'import json,sys; print(" ".join(sorted(f["path"] for f in json.load(sys.stdin)[0]["files"])))')"
  assert_ok "npm packs only install.sh, the bin and npm's own files" test \
    "$packed" = "LICENSE README.md bin/harness-install.js install.sh package.json"
else
  echo "  skip: npm not on PATH — pack listing not checked"
fi

# ── the entry, against a stub install.sh ─────────────────────────────────────────────────────────
if command -v node >/dev/null; then
  P="$T/pkg"; mkdir -p "$P/bin"; cp "$ROOT/$BIN" "$P/bin/"
  cat > "$P/install.sh" <<'EOF'
echo "ran $BASH_SOURCE with [$*]" > "$STUB_LOG"
exit 7
EOF
  export STUB_LOG="$T/stub.log"
  out="$(node "$P/bin/harness-install.js" a 'b c' </dev/null 2>&1)"; rc=$?
  assert_ok "runs the package's install.sh with bash" grep -qF "ran $P/install.sh " "$STUB_LOG"
  assert_ok "...passing its arguments through" grep -qF '[a b c]' "$STUB_LOG"
  assert_ok "...and exits with install.sh's status" test "$rc" = 7
  : > "$STUB_LOG"
  out="$(node -e 'Object.defineProperty(process, "platform", { value: "win32" }); require(process.argv[1])' \
    "$P/bin/harness-install.js" 2>&1)"; rc=$?
  assert_ok "native Windows exits non-zero" test "$rc" -ne 0
  assert_ok "...telling the user to run it inside WSL2" grep -qF 'WSL2' <<<"$out"
  assert_ok "...without running install.sh" test ! -s "$STUB_LOG"
else
  echo "  skip: node not on PATH — the entry is not run"
fi

# ── README: npx first, node >= 18 the only prerequisite ──────────────────────────────────────────
sec="$(sed -n '/^## Install$/,/^## Quick start$/p' "$ROOT/README.md")"
first="$(grep -m1 -E '^(npx|curl) ' <<<"$sec")"
assert_ok "README Install lists the npx line first" test "$first" = 'npx -y github:VocanicZ/Harness'
assert_ok "...and still the curl line" grep -qF 'install.sh | bash' <<<"$sec"
prq="$(sed -n '/^| Prerequisite/,/^$/p' <<<"$sec")"
assert_ok "README names node >= 18 as a prerequisite" grep -qF '`node` ≥ 18' <<<"$prq"
assert_ok "...and it is the only one" test "$(grep -c '^| `' <<<"$prq")" = 1
finish
