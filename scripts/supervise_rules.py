#!/usr/bin/env python3
"""supervise_rules.py — #181: the harness-arc watchdog's stall rules, run by `harness supervise`.

One call per fleet per supervisor pass, with that fleet's lib.sh config in the environment:

    supervise_rules.py --counters <json> [--repo-dir <checkout>] [--reconciled <file>] <slug>...
    supervise_rules.py alarms <rules dir>          # the alarms still firing, every fleet
    stdin: one live session per line, `<session>\\t<slug>\\t<issue>\\t<kind>` (kind: impl|bug|orch)

Each rule must hold for N consecutive passes (claim/release races are constant, a one-pass alarm is
noise). The strike counts AND the per-PRD criteria-gate round counters live in --counters, so a
supervisor restart resets neither. Output, one per line, for supervise.sh to act on:

    FIX wedged <session>              STOP_HOOK_BLOCK_CAP in the pane: the loop will not resume
    FIX zombie <session>              live session, its issue already closed
    FIX unlocked <slug> <issue>       live session on an open issue with no agent-working label
    ALARM spend:<session> ...         #1042: a lane spent over $SUPERVISE_SPEND_PER_HOUR in the last hour
                                      and committed nothing in it (a sleep-poll loop rewriting its cache)
    ALARM <key> <message>             needs a human; printed once, when the rule first fires
    RESOLVED <key>                    a fired alarm's condition cleared

A FIX line is printed on every pass its rule holds (each fix is idempotent). A rule whose input
could not be read this pass (gh outage) is skipped, and its strikes are kept as they were.
"""
import argparse, json, os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import issuelib  # noqa: E402
import session_backend  # noqa: E402  #346: the session backend's screen capture

WEDGE = "STOP_HOOK_BLOCK_CAP"
CONTEXT_RE = re.compile(r"\((\d{2,4})%\|\d+%\)")
DEEP_PCT = int(os.environ.get("SUPERVISE_DEEP_PCT", "250"))
REVIEW_LOOP = int(os.environ.get("SUPERVISE_REVIEW_LOOP", "4"))
# A plan can name tasks DECOMPOSE never filed. Authors word it differently: match a family.
UNFILED_RE = (r"no (sibling )?issue (is |was )?(filed|yet)|no issue filed|not yet filed|"
              r"file one (citing|under)")
# #1042: a lane that spends more than this many $ in the last hour with no commit in it is flagged. A lane
# sleep-polling a 10-minute wait writes 150K-300K tokens of cache per wake (about $1 on Sonnet), 6 wakes an hour.
SPEND_PER_HOUR = float(os.environ.get("SUPERVISE_SPEND_PER_HOUR", "10"))
SPEND_WINDOW = int(os.environ.get("SUPERVISE_SPEND_WINDOW_S", "3600"))
PLANS_DIR = os.environ.get("SUPERVISE_PLANS_DIR", "docs/superpowers/plans/")


def sh(argv):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=90).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def capture(session):
    argv = session_backend.capture_argv(session, 40)
    return sh(argv) if argv else ""


def unfiled_plans(repo_dir):
    """Plan docs on the default branch that name tasks with no issue. None = could not read."""
    if not repo_dir or not os.path.isdir(repo_dir):
        return None
    base = sh(["git", "-C", repo_dir, "symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"]).strip()
    base = base or "origin/main"
    sh(["git", "-C", repo_dir, "fetch", "-q", "origin", base.split("/", 1)[-1]])
    out = sh(["git", "-C", repo_dir, "grep", "-lEi", UNFILED_RE, base, "--", PLANS_DIR])
    return [l.split(":", 1)[-1] for l in out.splitlines() if l.strip()]


def lane_worktree(session):
    """The worktree a live lane runs in: the path the pool worker wrote to $RUN_DIR/<session>.wd."""
    run_dir = os.environ.get("RUN_DIR") or os.environ.get("SUPERVISE_RUN_DIR") or ""
    try:
        with open(os.path.join(run_dir, f"{session}.wd")) as f:
            wd = f.read().strip()
    except OSError:
        return ""
    return wd if wd and os.path.isdir(wd) else ""


def lane_transcript(wd):
    """The Claude transcript of the lane running in <wd>: its session id is in .claude/ralph-loop.local.md.
    None for a lane with no claude transcript (another CLI, a headless lane): its spend is not counted."""
    try:
        with open(os.path.join(wd, ".claude", "ralph-loop.local.md")) as f:
            m = re.search(r"^session_id:\s*(\S+)", f.read(), re.M)
    except OSError:
        return None
    if not m:
        return None
    import forecast
    return forecast.st.find_transcript(m.group(1).strip("\"'"))


def lane_spend(transcript, since):
    """$ the lane's transcript (main + sub-agents, each message once) spent after epoch <since>."""
    import forecast
    seen, usd = set(), 0.0
    for f in forecast.st.transcript_files(transcript):
        try:
            if os.path.getmtime(f) <= since:
                continue                                    # nothing in it is newer than the window
        except OSError:
            continue
        for key, model, usage, _, ts in forecast._messages(f):
            t = forecast.st.parse_ts(ts)
            if t is None or t <= since or key in seen:
                continue
            seen.add(key)
            usd += forecast.raw_cost(usage, model)
    return usd


def lane_progress(wd, since):
    """True when the lane's checkout has a commit made after epoch <since> (a push or PR needs one first)."""
    return bool(sh(["git", "-C", wd, "log", "-n1", "--format=%H", f"--since=@{int(since)}", "HEAD"]).strip())


def spend_facts(sessions, now=None):
    """{session: {"usd": $ in the window, "progress": a commit in it}} for the impl / bug lanes whose
    transcript can be read. A lane with no worktree, no claude transcript or no spend is left out."""
    now = time.time() if now is None else now
    since, out = now - SPEND_WINDOW, {}
    for s in sessions:
        if s["kind"] not in ("impl", "bug"):
            continue
        wd = lane_worktree(s["session"])
        tr = lane_transcript(wd) if wd else None
        if not tr:
            continue
        out[s["session"]] = {"usd": lane_spend(tr, since), "progress": lane_progress(wd, since)}
    return out


def gather(slugs, sessions, repo_dir):
    """Everything the rules read. A slug whose state/issues cannot be read maps to None."""
    facts = {"sessions": sessions, "panes": {s["session"]: capture(s["session"]) for s in sessions},
             "repos": {}, "unfiled": unfiled_plans(repo_dir), "mode": issuelib.MODE(),
             "spend": spend_facts(sessions)}
    for slug in slugs:
        try:
            issues = issuelib._list_issues(slug)
            facts["repos"][slug] = {"state": issuelib.compute_state(slug), "issues": issues}
        except Exception as e:  # GhError, or anything else: hold this slug's rules this pass
            print(f"supervise_rules: {slug} unreadable ({type(e).__name__}) — holding", file=sys.stderr)
            facts["repos"][slug] = None
    return facts


def evaluate(facts, counters, exempt=(), reconciled=()):
    """-> (rules, fixes). rules: {key: (holds, n, message)} for every rule evaluated this pass.
    fixes: {key: fix-line} for the auto-fix rules. Advances the persisted round counters."""
    rules, fixes = {}, {}
    sessions, panes = facts["sessions"], facts["panes"]
    rounds, gates = counters.setdefault("rounds", {}), counters.setdefault("gate", {})
    lw, lr = issuelib.L_WORKING(), issuelib.L_READY()

    # --- pane rules: a wedged session is ALIVE and holds its lock, so stale-lock never sees it ---
    for s in sessions:
        name, pane = s["session"], panes.get(s["session"]) or ""
        rules[f"wedged:{name}"] = (WEDGE in pane, 2, "")
        fixes[f"wedged:{name}"] = f"FIX wedged {name}"
        m = CONTEXT_RE.findall(pane)
        pct = int(m[-1]) if m else 0
        rules[f"deep-context:{name}"] = (
            pct >= DEEP_PCT, 2,
            f"DEEP CONTEXT {name} at {pct}% context — expect a wedge or a dropped cleanup step; "
            f"check its merge diff for leftover scaffolding.")

    # --- spend rule (#1042): money going out with nothing to show for it, the signature of a sleep-poll loop ---
    for name, sp in (facts.get("spend") or {}).items():
        rules[f"spend:{name}"] = (
            sp["usd"] > SPEND_PER_HOUR and not sp["progress"], 2,
            f"LANE SPEND {name} spent ${sp['usd']:.2f} in the last hour (over ${SPEND_PER_HOUR:g}/h) with no commit "
            f"in it — likely a foreground sleep-poll rewriting its prompt cache on every wake. Read its pane; "
            f"if it is waiting on a job, make it run_in_background, or park it (#1034).")

    for slug, repo in facts["repos"].items():
        if repo is None:
            continue
        st, issues = repo["state"], repo["issues"]
        byn = {i["number"]: i for i in issues}
        mine = [s for s in sessions if s["slug"] == slug]

        # --- session ↔ issue rules (impl sessions only: orch/bug sessions lock differently) ---
        for s in mine:
            if s["kind"] != "impl" or not str(s["issue"]).isdigit():
                continue
            i = byn.get(int(s["issue"]))
            if i is None:
                continue                                    # not in the listing: unknown, not closed
            closed = i["state"].lower() == "closed"
            rules[f"zombie:{s['session']}"] = (closed, 3, "")
            fixes[f"zombie:{s['session']}"] = f"FIX zombie {s['session']}"
            # a paused/blocked issue dropped its lock on purpose: never re-lock it under the agent
            parked = {issuelib.L_PAUSED(), issuelib.L_BLOCKED()} & i["_labels"]
            rules[f"unlocked:{s['session']}"] = (not closed and not parked and lw not in i["_labels"], 3, "")
            fixes[f"unlocked:{s['session']}"] = f"FIX unlocked {slug} {i['number']}"

        # --- PRD chain rules ---
        for p in st["prds"]:
            n, k = p["number"], f"{slug}#{p['number']}"
            gate = p["open"] and p["eligible"] and p["children_all_closed"] and not p["reviewed"]
            if gate and not gates.get(k):
                rounds[k] = rounds.get(k, 0) + 1            # one more time at the criteria gate
            gates[k] = gate
            r = rounds.get(k, 0)
            rules[f"review-loop:{k}"] = (
                gate and r >= REVIEW_LOOP, 1,
                f"REVIEW LOOP {slug} PRD #{n} reached the criteria gate {r}x without sign-off (no engine "
                f"cap exists on it). Read its gap issues: still finding NEW defects = working; "
                f"re-litigating the same ground = narrow the criteria or make a human call.")
        pending = [p["number"] for p in st["prds"]
                   if p["open"] and p["eligible"] and (not p["children_exist"] or p.get("needs_task1"))]
        rules[f"decompose:{slug}"] = (
            bool(pending) and not sessions, 3,
            f"DECOMPOSE STALLED {slug} PRD(s) {pending} eligible with no children and no live session — "
            f"check `harness status`, then `harness start --recover`.")
        stuck = ", ".join(f"#{n}" if r == slug else f"{r}#{n}" for r, n in st.get("stuck_on") or ())
        rules[f"unclaimable:{slug}"] = (
            bool(stuck), 2,
            f"UNCLAIMABLE BLOCKER {slug} chain needs an issue no agent can take: {stuck} — label it {lr} "
            f"so a lane can do it, or drop it from the '## Blocked by' that names it (#221).")
        rules[f"frontier:{slug}"] = (
            st["open_children"] > 0 and not st["unblocked"] and not sessions, 2,
            f"NO FRONTIER {slug} {st['open_children']} open children, 0 unblocked, no live session — "
            f"likely a mis-pointed '## Blocked by' (or a wayfinder ticket named in one).")

        # --- issue hygiene rules ---
        ready = [i for i in issues if i["state"].lower() == "open" and lr in i["_labels"]]
        if facts.get("mode") != "issue-only" and st["prds"]:   # unparented is normal in issue-only
            noparent = sorted(i["number"] for i in ready
                              if issuelib.L_PRD() not in i["_labels"] and i["number"] not in exempt
                              and issuelib.parse_parent(i.get("body") or "", slug) is None)
            rules[f"no-parent:{slug}"] = (
                bool(noparent), 2,
                f"NO PARENT {slug} {noparent} have no '## Parent' — scored against the lowest-numbered "
                f"PRD, and any #N in their '## Blocked by' becomes a phantom blocker.")
        leak = sorted(i["number"] for i in ready if any(l.startswith("wayfinder:") for l in i["_labels"]))
        rules[f"wf-leak:{slug}"] = (
            bool(leak), 2,
            f"WAYFINDER LEAK {slug} {leak} carry {lr} — the fleet will claim a HITL ticket it can never close.")
        # #360: the engine never claims a HITL issue, but one also labelled ready reads as fleet work
        lh = issuelib.L_HITL()
        hleak = sorted(i["number"] for i in ready if lh in i["_labels"])
        rules[f"hitl-leak:{slug}"] = (
            bool(hleak), 2,
            f"HITL LEAK {slug} {hleak} carry both {lh} and {lr} — the fleet never claims them, but the ready "
            f"label says otherwise; drop {lr} (a human does a {lh} task).")

    if facts["unfiled"] is not None:
        unfiled = [p for p in facts["unfiled"] if p not in reconciled]
        rules["unfiled"] = (
            bool(unfiled), 2,
            f"UNFILED TASKS plan(s) {unfiled} name tasks with no issue — file one per named task "
            f"('## Blocked by' + '## Parent #<prd>' + 'Part of #<prd>'), then add the path to the "
            f"fleet's reconciled-plans file, or REVIEW fires on an incomplete PRD.")
    return rules, fixes


def pane_activity(line, now, nudge_min, kill_min):
    """One pane file `sup_watch_pane` writes (`<body> <bg> <cpu> <t0> <nudged> <lastnudge>`), read the
    way it acts on it: frozen at kill_min quiet minutes, nudged once flagged, quiet at nudge_min, else
    active. A line that does not parse is active — `harness web` never alarms where supervise would not.
    -> {"state": "active" | "quiet" | "nudged" | "frozen", "quiet_s": int}"""
    parts = (line or "").split()
    if len(parts) < 5 or not parts[3].isdigit() or parts[4] not in ("0", "1"):
        return {"state": "active", "quiet_s": 0}
    quiet = max(0, int(now) - int(parts[3]))
    if quiet >= kill_min * 60:
        state = "frozen"
    elif parts[4] == "1":
        state = "nudged"
    elif quiet >= nudge_min * 60:
        state = "quiet"
    else:
        state = "active"
    return {"state": state, "quiet_s": quiet}


SESSION_RULES = ("wedged", "deep-context", "zombie", "unlocked", "spend")


def apply(rules, fixes, counters):
    """Advance the strikes for every evaluated rule; -> output lines. A rule NOT evaluated this pass
    (its repo was unreadable) keeps its strikes and its firing state; a per-session rule whose
    session has ended is forgotten."""
    strikes, out = counters.setdefault("strikes", {}), []
    firing, messages = set(counters.get("firing", [])), counters.get("messages", {})
    ended = lambda k: k.split(":", 1)[0] in SESSION_RULES and "wedged:" + k.split(":", 1)[1] not in rules
    for key in [k for k in set(strikes) | firing if ended(k)]:
        strikes.pop(key, None); firing.discard(key); messages.pop(key, None)
    for key, (holds, n, msg) in rules.items():
        was = strikes.pop(key, 0)
        if holds:
            strikes[key] = was + 1
        if key in fixes:
            if holds and strikes[key] >= n:
                out.append(fixes[key])
            continue
        if holds and strikes[key] >= n:
            if strikes[key] == n:
                out.append(f"ALARM {key} {msg}")
            firing.add(key); messages[key] = msg
        elif key in firing:
            out.append(f"RESOLVED {key}")
            firing.discard(key); messages.pop(key, None)
    counters["firing"], counters["messages"] = sorted(firing), messages
    return out


def load(path):
    try:
        with open(path) as f:
            c = json.load(f)
        return c if isinstance(c, dict) else {}
    except (OSError, ValueError):
        return {}


def save(path, counters):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(counters, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def parse_sessions(lines):
    out = []
    for line in lines:
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 4 and parts[0]:
            out.append({"session": parts[0], "slug": parts[1], "issue": parts[2], "kind": parts[3]})
    return out


def show_alarms(rules_dir):
    """`harness supervise --alarms`: every alarm still firing, one line per fleet + key."""
    names = sorted(n for n in os.listdir(rules_dir) if n.endswith(".json")) if os.path.isdir(rules_dir) else []
    n = 0
    for name in names:
        c = load(os.path.join(rules_dir, name))
        for key in c.get("firing", []):
            print(f"{name[:-5]}\t{key}\t{c.get('messages', {}).get(key, '')}"); n += 1
    if not n:
        print("no arc alarms firing")
    return 0


def main(argv=None, stdin=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["alarms"]:
        return show_alarms(argv[1] if len(argv) > 1 else "")
    ap = argparse.ArgumentParser(prog="supervise_rules.py")
    ap.add_argument("--counters", required=True)
    ap.add_argument("--repo-dir", default="")
    ap.add_argument("--reconciled", default="")
    ap.add_argument("slugs", nargs="*")
    a = ap.parse_args(argv)
    sessions = parse_sessions(stdin if stdin is not None else sys.stdin)
    exempt = {int(x) for x in os.environ.get("UNPARENTED_OK", "").split(",") if x.strip().isdigit()}
    try:
        with open(a.reconciled) as f:
            reconciled = {l.strip() for l in f if l.strip()}
    except OSError:
        reconciled = set()
    counters = load(a.counters)
    rules, fixes = evaluate(gather(a.slugs, sessions, a.repo_dir), counters, exempt, reconciled)
    for line in apply(rules, fixes, counters):
        print(line, flush=True)
    save(a.counters, counters)
    return 0


if __name__ == "__main__":
    sys.exit(main())
