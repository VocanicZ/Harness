# hermetic_lib.sh — what the test_hermetic*.sh files share (#608). Sourced after helpers.sh; not a test, run.sh never runs it.
# test_hermetic.sh used to run ~60 other test files in one process; on Windows (a process costs ~10x) it ran past the per-file cap, so
# its loops became one file per seam, and the two big ones (every test that updates, every test that starts a fleet) are cut into
# slices — hermetic_slice <k> <n>. The slices cover exactly the files the scans find: test_hermetic.sh asserts that.
SENTINEL=': "${HARNESS_REPO:=sentinel/live}"'

# make_decoy — a plausible live project state dir, echoed on stdout.
make_decoy(){
  local d; d="$(mktemp -d)/.harness"
  mkdir -p "$d/worktrees" "$d/checkouts" "$d/run/claims"
  printf '%s\n' "$SENTINEL" > "$d/config"
  printf '%s' "$d"
}

# assert_untouched <decoy> <label> — config still the sentinel, no worktrees/checkouts created.
assert_untouched(){
  local d="$1" label="$2"
  assert_eq "$(cat "$d/config")" "$SENTINEL" "$label: live config not overwritten"
  assert_eq "$(find "$d/worktrees" -mindepth 1 | wc -l)" "0" "$label: no worktrees in live state dir"
  assert_eq "$(find "$d/checkouts" -mindepth 1 | wc -l)" "0" "$label: no checkouts in live state dir"
}

make_host_decoy(){ local d; d="$(mktemp -d)/.harness"; mkdir -p "$d/poller/registry" "$d/snapshots"; printf '%s' "$d"; }
make_fleet_decoy(){ local d; d="$(mktemp -d)/.harness"; mkdir -p "$d/fleets"
  printf '%s\n' '{"prefix":"live","project":"/live/proj/.harness","run_dir":"/live/proj/.harness/run","slugs":["live/repo"],"started_at":0}' \
    > "$d/fleets/live.json"; printf '%s' "$d"; }

# The reader drains all input (>/dev/null, not -q): under pipefail an early-exiting `grep -q` SIGPIPEs
# the writer and the pipeline reads false at random (#441).
runs_update(){ grep -v '^[[:space:]]*#' "$1" |
  grep -E '(bash|exec)[^#|]*update\.sh|harness"?[[:space:]]+update([[:space:]]|$|")' >/dev/null; }

# decoy_host — a home whose .harness/engine is a release symlink, echoed on stdout (tracked by the
# caller: a tmp_track inside the $(…) would delete it as that subshell exits). It carries a git
# identity, as a real home does — test_supervise.sh's WIP checkpoints commit with the user's own.
decoy_host(){ local d; d="$(mktemp -d)"; printf '[user]\n\tname = t\n\temail = t@t\n' > "$d/.gitconfig"
  mkdir -p "$d/.harness/releases/v0.0.1/bin"; printf 'v0.0.1\n' > "$d/.harness/releases/v0.0.1/VERSION"
  printf 'v0.0.1\n' > "$d/.harness/releases/.installed"; ln -s releases/v0.0.1 "$d/.harness/engine"
  printf '%s' "$d"; }
# tree_state <dir> — every path under <dir> with its type, link target, size and mtime.
tree_state(){ find "$1" -printf '%P %y %l %s %T@\n' | sort; }

# runs_fleets <file> — the test runs update.sh / `harness update`, supervise.sh / `harness supervise`, or `harness start`.
runs_fleets(){ grep -v '^[[:space:]]*#' "$1" |
  grep -E '(bash|exec|"\$[A-Za-z_]+/?[a-z./]*)[^#|]*(update|supervise|start)\.sh|harness"?[[:space:]]+(update|supervise|start)([[:space:]]|$|")' >/dev/null; }
DECOY_PID=""
make_live_fleet(){   # LIVE_ROOT: a host root holding ONE registered fleet with a live worker (not in $(): a tmp_track there dies with it)
  LIVE_ROOT="$(mktemp -d)"; tmp_track "$LIVE_ROOT"
  local sd="$LIVE_ROOT/decoy/proj/.harness"; mkdir -p "$LIVE_ROOT/fleets" "$LIVE_ROOT/poller/registry" "$LIVE_ROOT/snapshots" "$sd/run"
  printf ': "${HARNESS_MODE:=single}"\n: "${HARNESS_REPO:=o/decoy}"\n: "${HARNESS_SESS_PREFIX:=decoy}"\n: "${HARNESS_POOL:=1}"\n: "${HARNESS_USE_POLLER:=0}"\n' > "$sd/config"
  (cd "$LIVE_ROOT/decoy/proj" && git init -q .)
  ( cd "$LIVE_ROOT/decoy/proj" && exec env ENGINE_DIR=/old/engine sleep 3000 </dev/null >/dev/null 2>&1 ) & DECOY_PID=$!
  echo "$DECOY_PID" > "$sd/run/worker-1.pid"
  printf '{"prefix":"decoy","project":"%s","run_dir":"%s/run","slugs":[],"started_at":1}\n' "$sd" "$sd" > "$LIVE_ROOT/fleets/decoy.json"
}

# hermetic_scan — fill update_tests (tests that run update.sh / `harness update`) and fleet_tests (… supervise / start too) with every
# test_*.sh doing so. Never a test_hermetic*.sh: their lint fixtures spell out `bash update.sh`, so the scan would match them and
# re-run them with the inherited lane env — recursively, killing the lane (#541).
hermetic_scan(){ local f; update_tests=(); fleet_tests=()
  for f in "$HERE"/test_*.sh; do [[ "${f##*/}" == test_hermetic*.sh ]] && continue
    runs_update "$f" && update_tests+=("$(basename "$f")"); runs_fleets "$f" && fleet_tests+=("$(basename "$f")"); done; }
# hermetic_slice <k> <n> <name…> — the names at positions k, k+n, k+2n… (k counts from 1)
hermetic_slice(){ local k="$1" n="$2" i=0; shift 2; for x in "$@"; do (( i % n == k - 1 )) && echo "$x"; i=$((i+1)); done; }
