#!/usr/bin/env bash
# test_one_repo.sh — #466 (PRD #464 §1, "one fleet = one repo"): HARNESS_UNIT and HARNESS_CHECKOUT.
# Every reader takes the fleet's repo, unit name and checkout from config — no targets.tsv — and
# session / worktree names come out as <prefix>-<HARNESS_UNIT>-i<N>. Defaults are today's `main` and
# $PROJECT_ROOT. An un-migrated `multi` config (no HARNESS_UNIT) still resolves through targets.tsv.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
unset_inherited_config
ROOT="$(mktemp -d)"; tmp_track "$ROOT"

# probe <config-body> [targets.tsv body] — a fresh fleet dir; prints one `key=value` line per reader.
probe(){
  local d; d="$(mktemp -d -p "$ROOT")"; mkdir -p "$d/.harness"
  printf '%s\n' "$1" > "$d/.harness/config"
  [[ -n "${2:-}" ]] && printf '%b' "$2" > "$d/.harness/targets.tsv"
  ( unset_inherited_config; export STATE_DIR="$d/.harness" RUN_DIR="$d/run" HARNESS_HOME="$d/host" HARNESS_GH_RATE_GUARD=0
    unset TARGETS_TSV
    source "$HERE/../scripts/lib.sh"
    u="$(all_units | head -n1)"
    echo "units=$(all_units | tr '\n' ,)"
    echo "repo=$(unit_repo "$u")"; echo "slug=$(unit_slug "$u")"; echo "desc=$(unit_desc "$u")"
    echo "checkout=$(unit_checkout "$u")"; echo "bugco=$(bug_checkout "$(unit_slug "$u")")"
    echo "bugrepos=$(_bug_repos | tr '\n' ,)"; echo "snap=$(snapshot_slugs | tr '\n' ,)"
    echo "impl=$(sess_impl "$u" 7)"; echo "root=$PROJECT_ROOT"; echo "fleet_unit=$(fleet_unit)"
    echo "bugrepo=$(bug_repo 3)" ) 2>&1
}
get(){ sed -n "s/^$1=//p" <<<"$2" | head -n1; }

# ── a config with REPO + UNIT + CHECKOUT and no targets.tsv ──────────────────
out="$(probe ': "${HARNESS_TOPOLOGY:=single}"
: "${HARNESS_OWNER:=acme}"
: "${HARNESS_REPO:=widget}"
: "${HARNESS_UNIT:=core}"
: "${HARNESS_CHECKOUT:=/srv/clones/widget}"
: "${HARNESS_SESS_PREFIX:=hzw}"')"
assert_eq "$(get units "$out")"    "core,"                  "HARNESS_UNIT is the one unit (all_units)"
assert_eq "$(get fleet_unit "$out")" "core"                 "fleet_unit is HARNESS_UNIT"
assert_eq "$(get repo "$out")"     "widget"                 "unit_repo is HARNESS_REPO"
assert_eq "$(get slug "$out")"     "acme/widget"            "unit_slug is the owner-qualified HARNESS_REPO"
assert_eq "$(get desc "$out")"     "widget"                 "unit_desc is the repo's name"
assert_eq "$(get checkout "$out")" "/srv/clones/widget"     "unit_checkout is HARNESS_CHECKOUT"
assert_eq "$(get bugco "$out")"    "/srv/clones/widget"     "bug_checkout is HARNESS_CHECKOUT"
assert_eq "$(get bugrepos "$out")" "widget,"                "_bug_repos is the one repo"
assert_eq "$(get snap "$out")"     "acme/widget,"           "snapshot_slugs is the one repo"
assert_eq "$(get bugrepo "$out")"  "widget"                 "bug_repo is the one repo"
assert_eq "$(get impl "$out")"     "hzw-core-i7"            "session / worktree names are <prefix>-<HARNESS_UNIT>-i<N>"

# ── the same, with HARNESS_TOPOLOGY=multi but HARNESS_UNIT set (a migrated config) ──
out="$(probe ': "${HARNESS_TOPOLOGY:=multi}"
: "${HARNESS_REPO:=acme/widget}"
: "${HARNESS_UNIT:=core}"')"
assert_eq "$(get units "$out")" "core," "HARNESS_UNIT wins over the topology: no targets.tsv needed"
assert_eq "$(get slug "$out")"  "acme/widget" "...and its repo is HARNESS_REPO"

# ── defaults: bangwa's plain KEY=val config, no UNIT / CHECKOUT ───────────────
out="$(probe 'HARNESS_TOPOLOGY=single
HARNESS_OWNER=VocanicZ
HARNESS_REPO=bangwa
HARNESS_SESS_PREFIX=hzbw')"
assert_eq "$(get units "$out")"    "main,"                  "no HARNESS_UNIT: the unit is main"
assert_eq "$(get fleet_unit "$out")" "main"                 "fleet_unit defaults to main"
assert_eq "$(get checkout "$out")" "$(get root "$out")"     "no HARNESS_CHECKOUT: the checkout is \$PROJECT_ROOT"
assert_eq "$(get bugco "$out")"    "$(get root "$out")"     "...and bug_checkout too"
assert_eq "$(get impl "$out")"     "hzbw-main-i7"           "bangwa session names stay hzbw-main-i<N>"
assert_eq "$(get slug "$out")"     "VocanicZ/bangwa"        "slug as today"

# ── an un-migrated multi config + targets.tsv behaves exactly as before ──────
out="$(probe ': "${HARNESS_TOPOLOGY:=multi}"
: "${HARNESS_OWNER:=acme}"
: "${HARNESS_SESS_PREFIX:=hzm}"' '# id\trepo\tdeps\tdesc\napi\tacme/api\t-\tthe api\nweb\tweb\tapi\tthe web\n')"
assert_eq "$(get units "$out")"    "api,web,"                       "multi: units come from targets.tsv"
assert_eq "$(get repo "$out")"     "acme/api"                       "multi: unit_repo is the row's repo"
assert_eq "$(get desc "$out")"     "the api"                        "multi: unit_desc is the row's desc"
assert_ok "multi: unit_checkout is checkouts/<repo name>" bash -c "[[ '$(get checkout "$out")' == */.harness/checkouts/api ]]"
assert_eq "$(get bugrepos "$out")" "acme/api,web,"                  "multi: _bug_repos spans the rows"
assert_eq "$(get impl "$out")"     "hzm-api-i7"                     "multi: session names use the row id"

# ── harness inject / harness one: --unit is optional, HARNESS_UNIT is the default ──
d="$(mktemp -d -p "$ROOT")"; mkdir -p "$d/.harness"
cat > "$d/.harness/config" <<'CFG'
: "${HARNESS_TOPOLOGY:=single}"
: "${HARNESS_OWNER:=acme}"
: "${HARNESS_REPO:=widget}"
: "${HARNESS_UNIT:=core}"
: "${HARNESS_SESS_PREFIX:=hzw}"
CFG
(
  unset_inherited_config; export STATE_DIR="$d/.harness" RUN_DIR="$d/run" HARNESS_HOME="$d/host" HARNESS_GH_RATE_GUARD=0
  source "$HERE/../scripts/lib.sh"
  HARNESS_SPEC=docs/spec.md; PROMPTS_DIR="$HERE/../prompts"
  TMPCO="$(mktemp -d -p "$ROOT")"; unit_checkout(){ echo "$TMPCO"; }
  LAUNCH="$d/launch.log"; : > "$LAUNCH"; launch_claude(){ echo "$1" >> "$LAUNCH"; }
  ( session_live(){ return 1; }; source "$HERE/../scripts/inject.sh" issue "do a thing" >/dev/null 2>&1 )
  assert_eq "$(cat "$LAUNCH")" "hzw-inject-core" "inject without --unit launches hz*-inject-<HARNESS_UNIT>"
  : > "$LAUNCH"
  ( session_live(){ return 1; }; source "$HERE/../scripts/inject.sh" issue --unit other "do a thing" >/dev/null 2>&1 )
  assert_eq "$(cat "$LAUNCH")" "hzw-inject-other" "--unit still overrides"
  source "$HERE/../scripts/one.sh" >/dev/null 2>&1
  UNIT="" REPO="" SLUG="" PROJECT="" DESC="" CHECKOUT=""
  _one_target
  assert_eq "$UNIT|$SLUG|$REPO" "core|acme/widget|widget" "harness one: no --unit resolves to HARNESS_UNIT"
  _one_target -R acme/widget
  assert_eq "$UNIT" "core" "harness one: -R of the fleet's repo resolves to HARNESS_UNIT"
  finish
) || FAIL=1

# ── stats.py _unit_repo + forecast.py project_units read the same keys ───────
python3 - "$HERE" "$ROOT" <<'PY' || FAIL=1
import importlib.util, os, sys
here, root = sys.argv[1:3]
def load(n):
    sp = importlib.util.spec_from_file_location(n, os.path.join(here, "..", "scripts", n + ".py"))
    m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m); return m
st, fc = load("stats"), load("forecast")
ok = True
def check(got, want, msg):
    global ok
    if got != want:
        ok = False; print(f"  FAIL: {msg} — want {want!r} got {got!r}")
    else:
        print(f"  ok: {msg}")
def fleet(name, config, targets=None):
    d = os.path.join(root, name); os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "config"), "w").write(config)
    if targets: open(os.path.join(d, "targets.tsv"), "w").write(targets)
    return d
colon = fleet("py-colon", ': "${HARNESS_TOPOLOGY:=single}"\n: "${HARNESS_OWNER:=acme}"\n: "${HARNESS_REPO:=widget}"\n: "${HARNESS_UNIT:=core}"\n')
plain = fleet("py-plain", 'HARNESS_TOPOLOGY=single\nexport HARNESS_OWNER="acme"\nHARNESS_REPO=widget # the repo\nHARNESS_UNIT=core\n')
bangwa = fleet("py-bangwa", 'HARNESS_TOPOLOGY=single\nHARNESS_OWNER=VocanicZ\nHARNESS_REPO=bangwa\n')
multi = fleet("py-multi", ': "${HARNESS_TOPOLOGY:=multi}"\n: "${HARNESS_OWNER:=acme}"\n', "# id\trepo\tdeps\tdesc\napi\tacme/api\t-\tx\nweb\tweb\tapi\ty\n")
check(fc.project_units(colon), [("core", "acme/widget")], 'forecast: ": ${KEY:=val}" config, HARNESS_UNIT')
check(fc.project_units(plain), [("core", "acme/widget")], "forecast: plain KEY=val config gives the same")
check(fc.project_units(bangwa), [("main", "VocanicZ/bangwa")], "forecast: plain bangwa config, no HARNESS_UNIT -> main")
check(fc.project_units(multi), [("api", "acme/api"), ("web", "acme/web")], "forecast: un-migrated multi still reads targets.tsv")
slugs = ["acme/widget"]
check(st._unit_repo(colon, "core", slugs), "acme/widget", "stats: _unit_repo from HARNESS_UNIT, no targets.tsv")
check(st._unit_repo(plain, "core", slugs), "acme/widget", "stats: _unit_repo from a plain KEY=val config")
check(st._unit_repo(multi, "web", ["acme/api", "acme/web"]), "acme/web", "stats: multi still reads targets.tsv")
check(fc.resolve_repo(5, None, None, [], plain), ("acme/widget", "core"), "forecast: resolve_repo needs no --unit")
sys.exit(0 if ok else 1)
PY

[[ "${FAIL:-0}" == 0 ]] && echo "── test_one_repo: python checks ok"
finish && [[ "${FAIL:-0}" == 0 ]]
