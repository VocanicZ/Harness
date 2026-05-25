#!/usr/bin/env python3
"""issuelib.py — GitHub-issue state machine for the Harness orchestrator (project-agnostic)."""
import base64, hashlib, json, os, re, subprocess, sys, time

# PRD-B: the snapshot read seam. A host poller writes one raw, versioned snapshot per repo into
# ~/.harness/snapshots/<owner__repo>.json; workers read those instead of polling GitHub directly.
# Bumped whenever the snapshot shape changes; a reader rejecting an unknown version holds dispatch.
SNAPSHOT_SCHEMA_VERSION = 1

# Committed, spec-keyed plan-completion marker. Lives in the unit's repo (NOT in the gitignored
# .harness runtime clone) so it survives a fresh runtime checkout. Records the HARNESS_SPEC path +
# a content hash of that spec; the auto-PLAN gate suppresses replanning while the hash still matches.
PLAN_MARKER_PATH = "docs/harness/plan-complete.json"

OWNER = os.environ.get("HARNESS_OWNER", "")
MODE = lambda: os.environ.get("HARNESS_MODE", "issue-only")
AUTONOMOUS = lambda: os.environ.get("HARNESS_AUTONOMOUS", "true").lower() == "true"
L_READY    = lambda: os.environ.get("HARNESS_LABEL_READY", "ready-for-agent")
L_PRD      = lambda: os.environ.get("HARNESS_LABEL_PRD", "prd")
L_WORKING  = lambda: os.environ.get("HARNESS_LABEL_WORKING", "agent-working")
L_BLOCKED  = lambda: os.environ.get("HARNESS_LABEL_BLOCKED", "agent-blocked")
L_REVIEWED = lambda: os.environ.get("HARNESS_LABEL_REVIEWED", "reviewed")
L_PAUSED   = lambda: os.environ.get("HARNESS_LABEL_PAUSED", "agent-paused")
L_BUG         = lambda: os.environ.get("HARNESS_LABEL_BUG", "bug")
L_BUG_TRIAGED = lambda: os.environ.get("HARNESS_LABEL_BUG_TRIAGED", "bug-triaged")
ALLOWLIST  = lambda: os.environ.get("HARNESS_AUTHOR_ALLOWLIST", "")

_BLOCKED_BY_HEADING = re.compile(r"^##\s+Blocked by\s*$", re.IGNORECASE | re.MULTILINE)
_NEXT_HEADING = re.compile(r"^##\s+", re.MULTILINE)
_ISSUE_REF = re.compile(r"(?:([\w.-]+/[\w.-]+))?#(\d+)")


def _gh_json(args):
    """Run a gh command and parse JSON stdout. Returns [] / {} on failure (repo may be empty)."""
    try:
        out = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60)
    except Exception:
        return None
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout or "null")
    except json.JSONDecodeError:
        return None


def _repo_slug(repo):
    return repo if "/" in repo else (f"{OWNER}/{repo}" if OWNER else repo)


# ── snapshot read seam (PRD-B) ────────────────────────────────────────────────────────────────
# When HARNESS_SNAPSHOT_FILE is set the read path serves issues / plan / dep-state from snapshots
# instead of calling gh. HARNESS_SNAPSHOT_DIR holds the sibling per-repo snapshots used to resolve
# cross-repo deps. With neither set, every read below behaves exactly as before (direct gh).
def _snapshot_mode():
    return bool(os.environ.get("HARNESS_SNAPSHOT_FILE", ""))


def _slug_filename(slug):
    """`owner/repo` → `owner__repo.json`, the on-disk snapshot name under HARNESS_SNAPSHOT_DIR."""
    return slug.replace("/", "__") + ".json"


def _load_snapshot(path):
    """Parse a snapshot file; None if missing/unreadable/garbled (treated as not-snapshotted)."""
    if not path:
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _snapshot_fresh(path, refresh):
    """True iff the snapshot at <path> is present, parses, carries a KNOWN schema_version, and is
    younger than 3× its refresh interval (PRD-B slice 3, #72). The worker freshness gate: a False
    here HOLDS new dispatch — there is no direct-gh fallback. Missing/unreadable/garbled, an
    unknown/newer schema (a reader must not interpret a shape it doesn't know), or an aged
    generated_at all read as not-fresh. 3× tolerates one missed poll cycle before a dead poller
    trips it. refresh<=0 (no registrant cadence known) skips only the staleness clause."""
    snap = _load_snapshot(path)
    if not isinstance(snap, dict):
        return False
    if snap.get("schema_version") != SNAPSHOT_SCHEMA_VERSION:
        return False
    gen = snap.get("generated_at")
    if not isinstance(gen, (int, float)):
        return False
    if refresh > 0 and (time.time() - gen) > 3 * refresh:
        return False
    return True


def _snapshot_for_slug(slug):
    """The snapshot dict whose `slug` == slug, or None. Prefers the primary HARNESS_SNAPSHOT_FILE
    (the repo being dispatched), then the sibling <owner__repo>.json in HARNESS_SNAPSHOT_DIR."""
    primary = _load_snapshot(os.environ.get("HARNESS_SNAPSHOT_FILE", ""))
    if primary and primary.get("slug") == slug:
        return primary
    d = os.environ.get("HARNESS_SNAPSHOT_DIR", "")
    if d:
        sib = _load_snapshot(os.path.join(d, _slug_filename(slug)))
        if sib and sib.get("slug") == slug:
            return sib
    return None


def parse_blocked_by(body, self_repo):
    """Return [(repo_slug, issue_number)] from the `## Blocked by` section. Bare `#N`
    resolves against self_repo. Empty when the section is absent or says 'None'."""
    if not body:
        return []
    m = _BLOCKED_BY_HEADING.search(body)
    if not m:
        return []
    rest = body[m.end():]
    nxt = _NEXT_HEADING.search(rest)
    section = rest[:nxt.start()] if nxt else rest
    refs = []
    for repo_part, num in _ISSUE_REF.findall(section):
        refs.append((repo_part or self_repo, int(num)))
    return refs


def _fetch_issues(slug, extra=None):
    """Raw `gh issue list` payload (number,title,state,labels,body,author) — no normalisation,
    no author filtering. The snapshot command emits exactly this; always hits gh."""
    args = ["issue", "list", "-R", slug, "--state", "all", "--limit", "200",
            "--json", "number,title,state,labels,body,author"]
    if extra:
        args += extra
    return _gh_json(args) or []


def _normalize_issues(data):
    """Add the worker-side derived fields: labels → lowercase set, author login lowercased."""
    for it in data:
        it["_labels"] = {str(l.get("name", "")).lower() for l in it.get("labels", [])}
        it["_author"] = str((it.get("author") or {}).get("login", "")).lower()
    return data


def _list_issues(slug, extra=None):
    if _snapshot_mode():
        snap = _snapshot_for_slug(slug)
        data = list(snap.get("issues") or []) if snap else []
    else:
        data = _fetch_issues(slug, extra)
    return _normalize_issues(data)


_self_login_cache = None
def _self_login():
    """Authenticated GitHub login (`gh api user`), cached once per process. This is the
    bot's own login — NOT HARNESS_OWNER, which may be an org while the bot commits as a user.
    Returns "" when gh is unauthenticated/unavailable (secure: self resolves to nothing)."""
    global _self_login_cache
    if _self_login_cache is None:
        if _snapshot_mode():
            # the poller already resolved + recorded the bot login; skip the gh api user round-trip.
            snap = _load_snapshot(os.environ.get("HARNESS_SNAPSHOT_FILE", "")) or {}
            v = str(snap.get("self_login", "") or "")
        else:
            try:
                out = subprocess.run(["gh", "api", "user", "--jq", ".login"],
                                     capture_output=True, text=True, timeout=60)
                v = out.stdout.strip() if out.returncode == 0 else ""
            except Exception:
                v = ""
        _self_login_cache = v.strip('"').lower()
    return _self_login_cache


def _allowed_authors():
    """Returns (allow_any, allowed_set). Allowed = {authenticated self} ∪ HARNESS_AUTHOR_ALLOWLIST
    (comma-separated, lowercased). Empty allowlist = self-only (secure default). A literal `*`
    = allow-any (community opt-in). Self is always allowed."""
    entries = {e.strip().lower() for e in ALLOWLIST().split(",") if e.strip()}
    if "*" in entries:
        return True, set()
    me = _self_login()
    if me:
        entries.add(me)
    return False, entries


def _author_filter(issues):
    """Drop issues from non-allowed authors. Silently skipped — never claimed, commented, or
    labelled — with a local debug-log line to stderr only (no GitHub-visible signal)."""
    allow_any, allowed = _allowed_authors()
    if allow_any:
        return issues
    kept = []
    for it in issues:
        if it.get("_author", "") in allowed:
            kept.append(it)
        else:
            print(f"[issuelib] skip issue #{it.get('number')} from disallowed author "
                  f"{it.get('_author') or '?'!r} (allowlist: self-only unless HARNESS_AUTHOR_ALLOWLIST set)",
                  file=sys.stderr)
    return kept


def _issue_state(slug, number):
    if _snapshot_mode():
        # resolve the dep's state from its repo's snapshot — never a gh call. A repo that is not
        # snapshotted (or a dep absent from the snapshot) is conservatively treated as NOT closed
        # (i.e. still blocking) and logged: erring toward not-dispatching is the safe direction.
        snap = _snapshot_for_slug(slug)
        if snap is None:
            print(f"[issuelib] dep {slug}#{number} not snapshotted — treating as not-closed (blocked)",
                  file=sys.stderr)
            return ""
        for it in snap.get("issues") or []:
            if it.get("number") == number:
                return str(it.get("state", "")).lower()
        print(f"[issuelib] dep {slug}#{number} absent from snapshot — treating as not-closed (blocked)",
              file=sys.stderr)
        return ""
    d = _gh_json(["issue", "view", str(number), "-R", slug, "--json", "state"]) or {}
    return str(d.get("state", "")).lower()


def _spec_hash():
    """sha256 hex of the current HARNESS_SPEC file's content; "" when unset/unreadable.
    drive.sh writes the same digest into the marker (via `issuelib.py spec-hash`), so both sides
    of the gate's comparison compute it identically."""
    path = os.environ.get("HARNESS_SPEC", "")
    if not path:
        return ""
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return ""


def _has_plan(slug):
    """PLAN.md committed at repo root?"""
    if _snapshot_mode():
        snap = _snapshot_for_slug(slug)
        return bool(snap.get("has_plan")) if snap else False
    r = subprocess.run(["gh", "api", f"repos/{slug}/contents/PLAN.md", "--jq", ".sha"],
                       capture_output=True, text=True)
    return r.returncode == 0 and r.stdout.strip() != ""


def _plan_marker(slug):
    """The committed plan-completion marker as a dict, or None if absent/unreadable.
    Read via the GitHub contents API (base64) so it reflects the repo, not local run state."""
    if _snapshot_mode():
        snap = _snapshot_for_slug(slug)
        return snap.get("plan_marker") if snap else None
    r = subprocess.run(["gh", "api", f"repos/{slug}/contents/{PLAN_MARKER_PATH}", "--jq", ".content"],
                       capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        raw = base64.b64decode("".join(r.stdout.split())).decode("utf-8")
        return json.loads(raw)
    except (ValueError, json.JSONDecodeError):
        return None


def _is_unblocked(issue, slug, closed_cache, prd_num=None):
    for ref_repo, ref_num in parse_blocked_by(issue.get("body"), slug):
        ref_slug = _repo_slug(ref_repo)
        # a child "blocked by" its own PRD is not a real block — the PRD stays open until review.
        # (also absorbs the common "Part of #<prd>" trailer that leaks into the Blocked-by section.)
        if prd_num is not None and ref_slug == _repo_slug(slug) and ref_num == prd_num:
            continue
        key = (ref_slug, ref_num)
        if key not in closed_cache:
            closed_cache[key] = _issue_state(ref_slug, ref_num) == "closed"
        if not closed_cache[key]:
            return False
    return True


def _allowed(mode):
    """Which orchestration actions this mode permits (entry-stage gating)."""
    return {
        "issue-only": dict(plan=False, prd=False, decompose=False, review=False),
        "prd":        dict(plan=False, prd=False, decompose=True,  review=True),
        "planned":    dict(plan=True,  prd=True,  decompose=True,  review=True),
    }.get(mode, dict(plan=False, prd=False, decompose=False, review=False))

def snapshot(repo):
    """The raw, versioned per-repo snapshot the host poller writes (PRD-B). Performs the GitHub
    reads — issue list, PLAN.md presence, plan-completion marker, bot login — and returns them
    unfiltered/uninterpreted: author filtering and label interpretation stay per-project on the
    read side. Run with HARNESS_SNAPSHOT_FILE UNSET (the poller's env) so it reads gh, not itself."""
    slug = _repo_slug(repo)
    return {
        "schema_version": SNAPSHOT_SCHEMA_VERSION,
        "generated_at": int(time.time()),
        "slug": slug,
        "issues": _fetch_issues(slug),   # exactly the gh payload — no _labels/_author derived fields
        "has_plan": _has_plan(slug),
        "plan_marker": _plan_marker(slug),
        "self_login": _self_login(),
    }


def compute_state(repo):
    slug = _repo_slug(repo)
    # secure-by-default: drop issues from non-allowed authors up front, so neither PRD
    # selection nor the IMPL claimable filter below can be hijacked by a foreign author.
    issues = _author_filter(_list_issues(slug))
    prd = next((i for i in issues if L_PRD() in i["_labels"]
                or i.get("title", "").startswith("[AFK] PRD:")), None)
    prd_num = prd["number"] if prd else None
    # bug-lane issues live in a separate lane: never claimed by the normal pool and never
    # counted toward unit completion, even when they carry the ready label.
    children = [i for i in issues if L_READY() in i["_labels"] and L_PRD() not in i["_labels"]
                and L_BUG() not in i["_labels"] and L_BUG_TRIAGED() not in i["_labels"]]
    children_exist = len(children) > 0
    children_all_closed = children_exist and all(i["state"].lower() == "closed" for i in children)
    closed_cache = {}
    unblocked = [i["number"] for i in children
                 if i["state"].lower() == "open"
                 and L_WORKING() not in i["_labels"]
                 and (AUTONOMOUS() or L_BLOCKED() not in i["_labels"])
                 and _is_unblocked(i, slug, closed_cache, prd_num)]
    marker = _plan_marker(slug)
    return {"slug": slug, "has_plan": _has_plan(slug),
            "plan_marker_matches": marker is not None and marker.get("spec_hash") == _spec_hash(),
            "prd": prd_num, "prd_open": bool(prd) and prd["state"].lower() == "open",
            "prd_reviewed": bool(prd) and L_REVIEWED() in prd["_labels"],
            "children_exist": children_exist, "children_all_closed": children_all_closed,
            "unblocked": unblocked,
            "open_children": sum(1 for i in children if i["state"].lower() == "open"),
            "total_children": len(children),
            "paused": sum(1 for i in children if i["state"].lower() == "open" and L_PAUSED() in i["_labels"])}

def bug_lane_candidates(repo):
    """(number, phase) for each open bug-lane issue the priority lane (#26) may claim:
    author-allowed, OPEN, carrying L_BUG or L_BUG_TRIAGED, not already agent-working, and
    (autonomous or not blocked). phase is 'fix' for a bug-triaged (a pending fix) or 'triage'
    for a fresh bug. The lane handles both stages.

    Ordered fix-pending-first (#28): a `bug-triaged` (a pending fix) sorts ahead of a fresh
    `bug`, so the cap-1 lane — which claims head-of-list — drains the triaged one to closed
    before triaging the new one. The sort is stable, so same-phase bugs keep their list order.
    The lane uses the phase to globally re-order candidates across repos (#37)."""
    slug = _repo_slug(repo)
    issues = _author_filter(_list_issues(slug))
    claimable = [i for i in issues
                 if (L_BUG() in i["_labels"] or L_BUG_TRIAGED() in i["_labels"])
                 and i["state"].lower() == "open"
                 and L_WORKING() not in i["_labels"]
                 and (AUTONOMOUS() or L_BLOCKED() not in i["_labels"])]
    claimable.sort(key=lambda i: 0 if L_BUG_TRIAGED() in i["_labels"] else 1)
    return [(i["number"], "fix" if L_BUG_TRIAGED() in i["_labels"] else "triage")
            for i in claimable]

def bug_lane_issues(repo):
    """Open bug-lane issue numbers (fix-pending-first), without phase. See bug_lane_candidates."""
    return [n for n, _phase in bug_lane_candidates(repo)]

def bug_lane_working(repo):
    """Numbers of OPEN bug-lane issues currently CARRYING L_WORKING — the COMPLEMENT of
    bug_lane_candidates' working filter (#42). A bug-lane session that crashes after spawn_bug
    stamps agent-working but before the issue closes leaves the bug stuck under agent-working,
    invisible to bug_lane_candidates (which excludes agent-working) — so the cap-1 lane idles
    while an OPEN bug sits there. The lane's per-poll reap walks these and frees the ones whose
    sess_bug session is dead, so a crashed triage/fix self-heals without `harness start --recover`.
    Author-allowed + bug/bug-triaged, same scope as the candidate scan (the lane never touches an
    issue it could not have claimed). Returned in list order; reap order does not matter."""
    slug = _repo_slug(repo)
    issues = _author_filter(_list_issues(slug))
    return [i["number"] for i in issues
            if (L_BUG() in i["_labels"] or L_BUG_TRIAGED() in i["_labels"])
            and i["state"].lower() == "open"
            and L_WORKING() in i["_labels"]]

def dispatch(repo, free_slots, allow_orchestration):
    s = compute_state(repo); a = _allowed(MODE()); out = []
    if allow_orchestration:
        # Fire a fresh PLAN only with no live PLAN.md AND (no completion marker OR the spec content
        # changed since that marker). A finished plan archives PLAN.md and writes a spec-keyed marker,
        # so without the marker check PLAN would re-fire every poll once the doc is gone.
        if a["plan"] and s["prd"] is None and not s["has_plan"] and not s["plan_marker_matches"]:
            return [("PLAN", "-", "PLAN DONE")]
        if a["prd"] and s["has_plan"] and s["prd"] is None:
            return [("PRD", "-", "PRD DONE")]
        if a["decompose"] and s["prd"] is not None and not s["children_exist"]:
            return [("DECOMPOSE", str(s["prd"]), "DECOMPOSE DONE")]
    for num in s["unblocked"][:max(0, free_slots)]:
        out.append(("IMPL", str(num), f"ISSUE {num} DONE"))
    if not out and allow_orchestration and a["review"] and s["children_all_closed"] and s["prd_open"]:
        out.append(("REVIEW", str(s["prd"]), "REVIEW DONE"))
    return out

def is_complete(s):
    if MODE() == "issue-only":
        return s["children_exist"] and s["open_children"] == 0 and len(s["unblocked"]) == 0
    return s["prd"] is not None and not s["prd_open"] and s["prd_reviewed"]

def main():
    if len(sys.argv) < 2: print(__doc__); sys.exit(2)
    cmd = sys.argv[1]
    # spec-hash keys the plan-completion marker off HARNESS_SPEC; it needs no repo arg.
    if cmd == "spec-hash":
        print(_spec_hash()); return
    # snapshot-fresh <path> <refresh-seconds> — exit 0 iff the snapshot is fresh, 1 otherwise. The
    # worker dispatch gate (lib.sh ensure_snapshot_fresh) shells out to this; it never touches gh.
    if cmd == "snapshot-fresh":
        path = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("HARNESS_SNAPSHOT_FILE", "")
        refresh = int(sys.argv[3]) if len(sys.argv) > 3 else 0
        sys.exit(0 if _snapshot_fresh(path, refresh) else 1)
    if len(sys.argv) < 3: print(__doc__); sys.exit(2)
    repo = sys.argv[2]
    if cmd == "snapshot":
        json.dump(snapshot(repo), sys.stdout, separators=(",", ":")); print()
    elif cmd == "dispatch":
        free = int(sys.argv[3]) if len(sys.argv) > 3 else 1
        allow = sys.argv[sys.argv.index("--allow-orchestration")+1] == "1" if "--allow-orchestration" in sys.argv else True
        for action, payload, promise in dispatch(repo, free, allow): print(f"{action}\t{payload}\t{promise}")
    elif cmd == "status":
        s = compute_state(repo); prd = f"PRD#{s['prd']}" if s["prd"] else "no-PRD"
        prd += "(open)" if s["prd_open"] else ("(closed)" if s["prd"] else "")
        print(f"{repo}: mode={MODE()} {prd} plan={'Y' if s['has_plan'] else 'N'} "
              f"children={s['total_children']} open={s['open_children']} unblocked={len(s['unblocked'])} "
              f"paused={s['paused']} reviewed={'Y' if s['prd_reviewed'] else 'N'} complete={'Y' if is_complete(s) else 'N'}")
    elif cmd == "bugs":
        for n, phase in bug_lane_candidates(repo): print(f"{n}\t{phase}")
    elif cmd == "working-bugs":
        for n in bug_lane_working(repo): print(n)
    elif cmd == "complete":
        print("DONE" if is_complete(compute_state(repo)) else "NOTDONE")
    elif cmd == "check":
        goal = sys.argv[3] if len(sys.argv) > 3 else ""; s = compute_state(repo); done = False
        if goal == "PLAN": done = s["has_plan"]
        elif goal == "PRD": done = s["prd"] is not None
        elif goal == "DECOMPOSE": done = s["children_exist"]
        elif goal == "REVIEW": done = (not s["prd_open"]) or len(s["unblocked"]) > 0
        elif goal.startswith("ISSUE:"): done = _issue_state(s["slug"], int(goal.split(":",1)[1])) == "closed"
        print("DONE" if done else "PENDING")
    else: print(f"unknown command: {cmd}", file=sys.stderr); sys.exit(2)

if __name__ == "__main__": main()
