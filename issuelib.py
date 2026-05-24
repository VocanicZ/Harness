#!/usr/bin/env python3
"""issuelib.py — GitHub-issue state machine for the Harness orchestrator (project-agnostic)."""
import base64, hashlib, json, os, re, subprocess, sys

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


def _list_issues(slug, extra=None):
    args = ["issue", "list", "-R", slug, "--state", "all", "--limit", "200",
            "--json", "number,title,state,labels,body,author"]
    if extra:
        args += extra
    data = _gh_json(args) or []
    # normalise labels to a lowercase set + author login (lowercased) per issue
    for it in data:
        it["_labels"] = {str(l.get("name", "")).lower() for l in it.get("labels", [])}
        it["_author"] = str((it.get("author") or {}).get("login", "")).lower()
    return data


_self_login_cache = None
def _self_login():
    """Authenticated GitHub login (`gh api user`), cached once per process. This is the
    bot's own login — NOT HARNESS_OWNER, which may be an org while the bot commits as a user.
    Returns "" when gh is unauthenticated/unavailable (secure: self resolves to nothing)."""
    global _self_login_cache
    if _self_login_cache is None:
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
    r = subprocess.run(["gh", "api", f"repos/{slug}/contents/PLAN.md", "--jq", ".sha"],
                       capture_output=True, text=True)
    return r.returncode == 0 and r.stdout.strip() != ""


def _plan_marker(slug):
    """The committed plan-completion marker as a dict, or None if absent/unreadable.
    Read via the GitHub contents API (base64) so it reflects the repo, not local run state."""
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

def bug_lane_issues(repo):
    """Open bug-lane issue numbers the priority lane (#26) may claim: author-allowed, OPEN,
    carrying L_BUG or L_BUG_TRIAGED, not already agent-working, and (autonomous or not blocked).
    The lane handles both stages — an untriaged `bug` and a `bug-triaged` awaiting its fix."""
    slug = _repo_slug(repo)
    issues = _author_filter(_list_issues(slug))
    return [i["number"] for i in issues
            if (L_BUG() in i["_labels"] or L_BUG_TRIAGED() in i["_labels"])
            and i["state"].lower() == "open"
            and L_WORKING() not in i["_labels"]
            and (AUTONOMOUS() or L_BLOCKED() not in i["_labels"])]

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
    if len(sys.argv) < 3: print(__doc__); sys.exit(2)
    repo = sys.argv[2]
    if cmd == "dispatch":
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
        for n in bug_lane_issues(repo): print(n)
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
