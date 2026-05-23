#!/usr/bin/env python3
"""issuelib.py — GitHub-issue state machine for the Harness orchestrator (project-agnostic)."""
import json, os, re, subprocess, sys

OWNER = os.environ.get("HARNESS_OWNER", "")
MODE = lambda: os.environ.get("HARNESS_MODE", "issue-only")
AUTONOMOUS = lambda: os.environ.get("HARNESS_AUTONOMOUS", "true").lower() == "true"
L_READY    = lambda: os.environ.get("HARNESS_LABEL_READY", "ready-for-agent")
L_PRD      = lambda: os.environ.get("HARNESS_LABEL_PRD", "prd")
L_WORKING  = lambda: os.environ.get("HARNESS_LABEL_WORKING", "agent-working")
L_BLOCKED  = lambda: os.environ.get("HARNESS_LABEL_BLOCKED", "agent-blocked")
L_REVIEWED = lambda: os.environ.get("HARNESS_LABEL_REVIEWED", "reviewed")
L_PAUSED   = lambda: os.environ.get("HARNESS_LABEL_PAUSED", "agent-paused")

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
            "--json", "number,title,state,labels,body"]
    if extra:
        args += extra
    data = _gh_json(args) or []
    # normalise labels to a lowercase set per issue
    for it in data:
        it["_labels"] = {str(l.get("name", "")).lower() for l in it.get("labels", [])}
    return data


def _issue_state(slug, number):
    d = _gh_json(["issue", "view", str(number), "-R", slug, "--json", "state"]) or {}
    return str(d.get("state", "")).lower()


def _has_plan(slug):
    """PLAN.md committed at repo root?"""
    r = subprocess.run(["gh", "api", f"repos/{slug}/contents/PLAN.md", "--jq", ".sha"],
                       capture_output=True, text=True)
    return r.returncode == 0 and r.stdout.strip() != ""


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
    issues = _list_issues(slug)
    prd = next((i for i in issues if L_PRD() in i["_labels"]
                or i.get("title", "").startswith("[AFK] PRD:")), None)
    prd_num = prd["number"] if prd else None
    children = [i for i in issues if L_READY() in i["_labels"] and L_PRD() not in i["_labels"]]
    children_exist = len(children) > 0
    children_all_closed = children_exist and all(i["state"].lower() == "closed" for i in children)
    closed_cache = {}
    unblocked = [i["number"] for i in children
                 if i["state"].lower() == "open"
                 and L_WORKING() not in i["_labels"]
                 and (AUTONOMOUS() or L_BLOCKED() not in i["_labels"])
                 and _is_unblocked(i, slug, closed_cache, prd_num)]
    return {"slug": slug, "has_plan": _has_plan(slug),
            "prd": prd_num, "prd_open": bool(prd) and prd["state"].lower() == "open",
            "prd_reviewed": bool(prd) and L_REVIEWED() in prd["_labels"],
            "children_exist": children_exist, "children_all_closed": children_all_closed,
            "unblocked": unblocked,
            "open_children": sum(1 for i in children if i["state"].lower() == "open"),
            "total_children": len(children),
            "paused": sum(1 for i in children if i["state"].lower() == "open" and L_PAUSED() in i["_labels"])}

def dispatch(repo, free_slots, allow_orchestration):
    s = compute_state(repo); a = _allowed(MODE()); out = []
    if allow_orchestration:
        if a["plan"] and s["prd"] is None and not s["has_plan"]:
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
    if len(sys.argv) < 3: print(__doc__); sys.exit(2)
    cmd, repo = sys.argv[1], sys.argv[2]
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
