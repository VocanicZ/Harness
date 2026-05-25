#!/usr/bin/env bash
# test_snapshot.sh — PRD-B slice 1 (#70): the snapshot read seam in issuelib.
# Proves: `issuelib snapshot <repo>` emits a raw, versioned JSON snapshot; reading it back via
# HARNESS_SNAPSHOT_FILE yields dispatch/complete/bugs/working-bugs IDENTICAL to the direct-gh path,
# with ZERO gh calls (a sibling snapshot resolves a cross-repo dep; an unsnapshotted dep blocks).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
IL="$HERE/../scripts/issuelib.py"

WORK="$(mktemp -d)"
FIX="$WORK/fixtures"; SNAPS="$WORK/snapshots"; GHBIN="$WORK/ghbin"; NOGHBIN="$WORK/noghbin"
mkdir -p "$FIX" "$SNAPS" "$GHBIN" "$NOGHBIN"
GH_CALLS="$WORK/gh.calls"; NOGH_CALLS="$WORK/nogh.calls"; : > "$GH_CALLS"; : > "$NOGH_CALLS"

# ── fixtures: exactly what `gh issue list --json …` returns, plus per-issue state for `issue view`.
cat > "$FIX/issues_acme__widget.json" <<'JSON'
[
  {"number":5,"title":"blocked cross-repo","state":"OPEN","body":"## Blocked by\nacme/lib#42\n","labels":[{"name":"ready-for-agent"}],"author":{"login":"me"}},
  {"number":8,"title":"free work","state":"OPEN","body":"","labels":[{"name":"ready-for-agent"}],"author":{"login":"me"}},
  {"number":9,"title":"blocked unresolvable","state":"OPEN","body":"## Blocked by\nother/ghost#1\n","labels":[{"name":"ready-for-agent"}],"author":{"login":"me"}},
  {"number":6,"title":"a bug","state":"OPEN","body":"","labels":[{"name":"bug"}],"author":{"login":"me"}},
  {"number":7,"title":"triaged bug","state":"OPEN","body":"","labels":[{"name":"bug-triaged"}],"author":{"login":"me"}},
  {"number":11,"title":"working bug","state":"OPEN","body":"","labels":[{"name":"bug"},{"name":"agent-working"}],"author":{"login":"me"}},
  {"number":99,"title":"stranger work","state":"OPEN","body":"","labels":[{"name":"ready-for-agent"}],"author":{"login":"stranger"}}
]
JSON
cat > "$FIX/issues_acme__lib.json" <<'JSON'
[
  {"number":42,"title":"upstream dep","state":"CLOSED","body":"","labels":[],"author":{"login":"me"}}
]
JSON
# per-issue state for the direct-gh dep resolution (`gh issue view`): the cross-repo dep is closed.
printf 'closed' > "$FIX/state_acme__lib_42"
# (no state fixture for other/ghost#1 → `gh issue view` fails → treated as not-closed → blocked)

# ── fixture-driven gh stub: serves the fixtures above and records every call.
cat > "$GHBIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
sub="${1:-}"; shift || true
case "$sub" in
  issue)
    action="${1:-}"; shift || true
    slug=""; first=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -R) slug="$2"; shift 2;;
        --json|--state|--limit|--jq) shift 2;;
        --*) shift;;
        *) [[ -z "$first" ]] && first="$1"; shift;;
      esac
    done
    key="${slug//\//__}"
    if [[ "$action" == "list" ]]; then
      f="$GH_FIXTURE_DIR/issues_${key}.json"; [[ -f "$f" ]] && cat "$f" || echo "[]"
    elif [[ "$action" == "view" ]]; then
      sf="$GH_FIXTURE_DIR/state_${key}_${first}"
      [[ -f "$sf" ]] && printf '{"state":"%s"}' "$(cat "$sf")" || exit 1
    fi
    ;;
  api)
    path="${1:-}"; shift || true
    case "$path" in
      user) printf '%s' "${GH_SELF_LOGIN:-me}";;
      repos/*/contents/*)
        rest="${path#repos/}"; slug="${rest%%/contents/*}"; cpath="${rest#*/contents/}"
        key="${slug//\//__}"
        if [[ "$cpath" == "PLAN.md" ]]; then
          pf="$GH_FIXTURE_DIR/plan_${key}";   [[ -f "$pf" ]] && cat "$pf" || exit 1
        else
          mf="$GH_FIXTURE_DIR/marker_${key}"; [[ -f "$mf" ]] && cat "$mf" || exit 1
        fi
        ;;
      *) exit 1;;
    esac
    ;;
  *) exit 1;;
esac
STUB
chmod +x "$GHBIN/gh"

# ── forbidden gh stub: snapshot-mode reads must NEVER shell out to gh. Records + fails loudly.
cat > "$NOGHBIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NOGH_CALLS"
echo "FORBIDDEN gh call in snapshot mode: $*" >&2
exit 99
STUB
chmod +x "$NOGHBIN/gh"

# common project env (issue-only, autonomous, self-only allowlist with self=me)
COMMON=(HARNESS_MODE=issue-only HARNESS_AUTONOMOUS=true HARNESS_OWNER=acme GH_SELF_LOGIN=me)
unset HARNESS_AUTHOR_ALLOWLIST HARNESS_SNAPSHOT_FILE HARNESS_SNAPSHOT_DIR HARNESS_LABEL_BUG HARNESS_LABEL_BUG_TRIAGED

# direct-gh run: real fixtures on PATH, no snapshot env.
direct(){ PATH="$GHBIN:$PATH" GH_FIXTURE_DIR="$FIX" GH_CALLS="$GH_CALLS" env "${COMMON[@]}" \
          HARNESS_AUTHOR_ALLOWLIST= python3 "$IL" "$@"; }
# snapshot-mode run: forbidden-gh on PATH (proves no gh), snapshot env pointed at the temp host root.
snap(){ PATH="$NOGHBIN:$PATH" NOGH_CALLS="$NOGH_CALLS" env "${COMMON[@]}" HARNESS_AUTHOR_ALLOWLIST= \
        HARNESS_SNAPSHOT_FILE="$SNAPS/acme__widget.json" HARNESS_SNAPSHOT_DIR="$SNAPS" python3 "$IL" "$@"; }

# ── 1) generate the snapshots (this DOES hit the fixture gh — it is the poller's job).
direct snapshot acme/widget > "$SNAPS/acme__widget.json"
direct snapshot acme/lib    > "$SNAPS/acme__lib.json"

# schema / staleness fields present and well-formed.
assert_ok "snapshot is valid JSON with required fields" python3 - "$SNAPS/acme__widget.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert isinstance(d["schema_version"],int), d.get("schema_version")
assert isinstance(d["generated_at"],int) and d["generated_at"]>0, d.get("generated_at")
assert d["slug"]=="acme/widget", d["slug"]
assert isinstance(d["issues"],list) and len(d["issues"])==7, d["issues"]
assert d["has_plan"] is False and d["plan_marker"] is None, (d["has_plan"],d["plan_marker"])
assert d["self_login"]=="me", d["self_login"]
# raw payload: no worker-side derived fields baked in
assert "_labels" not in d["issues"][0] and "_author" not in d["issues"][0], d["issues"][0]
PY

# ── 2) every read command: snapshot output must equal direct-gh output, byte for byte.
for cmd in "dispatch acme/widget 3" "complete acme/widget" "bugs acme/widget" "working-bugs acme/widget"; do
  d="$(direct $cmd)"; s="$(snap $cmd)"
  assert_eq "$s" "$d" "snapshot == direct for: $cmd"
done

# ── 3) zero gh calls were made in snapshot mode (the whole point of the seam).
assert_eq "$(wc -l < "$NOGH_CALLS" | tr -d ' ')" "0" "snapshot mode made ZERO gh calls"

# ── 4) cross-repo dep resolved from the sibling snapshot; unresolvable dep stays blocked.
disp="$(snap dispatch acme/widget 3)"
assert_ok "cross-repo dep (lib#42 closed) → #5 dispatched"   bash -c "grep -q $'^IMPL\t5\t' <<< \"\$1\"" _ "$disp"
assert_ok "free issue #8 dispatched"                          bash -c "grep -q $'^IMPL\t8\t' <<< \"\$1\"" _ "$disp"
assert_no "unsnapshotted dep (other/ghost#1) → #9 blocked"    bash -c "grep -q $'^IMPL\t9\t' <<< \"\$1\"" _ "$disp"

rm -rf "$WORK"
finish
