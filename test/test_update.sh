#!/usr/bin/env bash
# test_update.sh — `harness update` ff-pulls ONLY the shared engine install (#54, PRD #52 slice 2).
# It must advance ~/.harness/engine to upstream and touch NO project .harness/ (config + state live
# in the project now, not in the engine), and never run a destructive git op.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
assert(){ if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; exit 1; fi; }
gc(){ git -C "$1" -c user.email=t@t -c user.name=t "${@:2}"; }

# 1) a real "engine remote" with one commit, then the shared install cloned from it.
REMOTE="$(mktemp -d)/remote.git"; git init -q --bare -b main "$REMOTE"
WORK="$(mktemp -d)"; cp "$HERE/../update.sh" "$HERE/../lib.sh" "$WORK/"
gc "$WORK" init -q; gc "$WORK" branch -M main
gc "$WORK" add -A; gc "$WORK" commit -qm init >/dev/null
gc "$WORK" remote add origin "$REMOTE"; gc "$WORK" push -q -u origin main
ENG="$(mktemp -d)/engine"; git clone -q "$REMOTE" "$ENG"

# 2) advance the engine upstream with a marker file.
printf 'engine-moved\n' > "$WORK/UPSTREAM_MARKER"
gc "$WORK" add -A; gc "$WORK" commit -qm advance >/dev/null; gc "$WORK" push -q

# 3) a project with its own .harness/ state that MUST survive untouched.
PROJ="$(mktemp -d)"; mkdir -p "$PROJ/.harness"
printf 'HARNESS_MODE=prd\nHARNESS_REPO=acme/widget\n' > "$PROJ/.harness/config"
printf 'a\tacme/a\t-\troot\n' > "$PROJ/.harness/targets.tsv"
cp -r "$PROJ/.harness" "$PROJ/.harness.before"

# 4) run update from inside the project, targeting the shared engine.
( cd "$PROJ" && ENGINE_DIR="$ENG" bash "$ENG/update.sh" >/dev/null 2>&1 )

assert "engine ff-pulled to upstream (shared install advanced)" "[[ -f '$ENG/UPSTREAM_MARKER' ]]"
assert "project .harness/config byte-identical after update"    "cmp -s '$PROJ/.harness/config' '$PROJ/.harness.before/config'"
assert "project .harness/targets.tsv byte-identical after update" "cmp -s '$PROJ/.harness/targets.tsv' '$PROJ/.harness.before/targets.tsv'"
assert "no new files written into the project .harness/" \
  "[[ \"\$(ls -A '$PROJ/.harness' | sort)\" == \"\$(ls -A '$PROJ/.harness.before' | sort)\" ]]"
# the old per-project skill redeploy is gone: update must not write .claude/ beside the engine.
assert "update does not deploy into the engine's parent" "[[ ! -d '$(dirname "$ENG")/.claude' ]]"

# safety: update.sh never runs a command that can discard untracked/ignored files.
assert "update.sh has no git clean"        "! grep -qE 'git +clean' '$HERE/../update.sh'"
assert "update.sh has no git reset --hard" "! grep -qE 'reset +--hard' '$HERE/../update.sh'"
assert "update.sh has no git checkout -f"  "! grep -qE 'checkout +-f' '$HERE/../update.sh'"
echo "── update ok"
