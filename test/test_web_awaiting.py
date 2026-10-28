#!/usr/bin/env python3
"""test_web_awaiting.py — #229: "Awaiting you" lists the fleet's wayfinder tickets (matching
status-page.py on the same board), agent-blocked questions and operator issues; DAG nodes and PRD
headers carry tokens, model and retries from the event log, and nothing at all when it has none."""
import json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import web_fixture as wf
dag = wf.load("web_dag")
web_data = wf.load("web_data")
BOARD = json.load(open(os.path.join(wf.FIX, "snapshots", "o__arc.json")))
LABELS = {"prd": "prd", "working": "agent-working", "blocked": "agent-blocked", "ready": "ready-for-agent"}
EVENTS = [json.loads(l) for l in open(os.path.join(wf.FIX, "events.jsonl")) if l.startswith("{")]


def test_awaiting_matches_status_page_and_adds_blocked_and_operator():
    a = dag.awaiting(BOARD, LABELS)
    got = sorted((x["kind"], x["number"], x["resolved"]) for x in a)
    assert got == [("agent-blocked", 14, False), ("operator", 40, False),
                   ("wayfinder", 31, False), ("wayfinder", 32, True)], got
    golden = json.load(open(os.path.join(wf.FIX, "arc-golden.json")))
    assert sorted([x["number"], x["resolved"]] for x in a if x["kind"] == "wayfinder") == golden["tickets"]
    w31 = next(x for x in a if x["number"] == 31)
    assert w31["needs"] == [4] and w31["url"] == "https://github.com/o/arc/issues/31", w31
    assert [x["number"] for x in a][-1] == 32, "resolved tickets sit at the end"


def test_operator_issue_rule():
    def issue(n, title, labels=(), state="OPEN"):
        return {"number": n, "title": title, "state": state, "body": "", "labels": [{"name": l} for l in labels]}
    board = {"slug": "o/x", "issues": [
        issue(1, "[OPS] restart the host"), issue(2, "[ops] closed one", state="CLOSED"),
        issue(3, "[ops] but agent-ready", ["ready-for-agent"]), issue(4, "[ops] a PRD", ["prd"]),
        issue(5, "[ops] being worked", ["agent-working"]), issue(6, "plain issue"),
        issue(7, "[ops] stuck", ["agent-blocked"])]}
    got = [(x["kind"], x["number"]) for x in dag.awaiting(board, LABELS)]
    assert got == [("agent-blocked", 7), ("operator", 1)], got


def test_needs_drops_closed_blockers_keeps_open_and_off_board():
    """#273: a CLOSED blocker blocks nothing — it must not show under "needs first". A blocker that is
    not on the board has unknown state and stays listed."""
    r = wf.load("web_render")
    def issue(n, title, state="OPEN", body=""):
        return {"number": n, "title": title, "state": state, "labels": [], "body": body}
    board = {"slug": "o/x", "issues": [
        issue(10, "[ops] mixed", body="## Blocked by\n\n- #11\n- #12\n"),
        issue(20, "[ops] all closed", body="## Blocked by\n\n- #11\n- #13\n"),
        issue(30, "[ops] off board", body="## Blocked by\n\n- #11\n- #99\n"),
        issue(11, "a", "CLOSED"), issue(12, "b"), issue(13, "c", "CLOSED")]}
    a = {x["number"]: x for x in dag.awaiting(board, LABELS)}
    assert a[10]["needs"] == [12], a[10]
    assert a[20]["needs"] == [], a[20]
    assert a[30]["needs"] == [99], a[30]
    assert "needs first" not in r._awaiting_item("o/x", a[20], False)
    li = r._awaiting_item("o/x", a[10], False)
    m = re.search(r'<span class="awaiting__needs[^"]*">.*?</span></span>', li)
    assert m and "#12" in m.group(0), li
    assert "#11" not in li, li


def test_issue_and_prd_stats_from_the_event_log():
    s11 = web_data.issue_stats(EVENTS, "o/arc", 11)
    assert s11 == {"tokens": 8700, "model": "claude-opus-5-5", "retries": 0, "sessions": 1}, s11
    s41 = web_data.issue_stats(EVENTS, "o/arc", 41)     # relaunched after a watchdog kill, no usage yet
    assert s41 == {"model": "claude-opus-5-5", "retries": 2, "sessions": 2}, s41
    assert web_data.issue_stats(EVENTS, "o/arc", 15) is None
    assert web_data.issue_stats(EVENTS, "o/other", 11) is None, "another repo's #11 leaked in"
    p4 = web_data.prd_stats(EVENTS, "o/arc", 4)
    assert p4 == {"model": "claude-opus-5-5", "retries": 2, "sessions": 2}, p4
    assert web_data.prd_stats(EVENTS, "o/arc", 2)["tokens"] == 8700
    assert web_data.prd_stats(EVENTS, "o/arc", 3) is None


def test_stats_overlay_present_and_cleanly_absent():
    with wf.serving(now=wf.NOW) as (base, host):
        _, page = wf.get(base + "/fleet/hz")
        assert re.search(r'data-issue="11"[^>]*>(?:(?!</a>).)*data-tokens="8700"', page, re.S), "no tokens on #11"
        assert re.search(r'data-issue="41"[^>]*>(?:(?!</a>).)*data-retries="2"', page, re.S), "no retries on #41"
        assert re.search(r'data-prd="2"[^>]*>(?:(?!</a>).)*data-retries="0"', page, re.S), "no retries on PRD #2"
        assert re.search(r'data-prd-children="4"[^>]*>(?:(?!</h3>).)*data-retries="2"', page, re.S), \
            "PRD #4's header has no rollup"
        assert not re.search(r'data-issue="15"[^>]*>(?:(?!</a>).)*data-tokens', page, re.S), "#15 has no stats"
        m = re.search(r'<section data-region="awaiting".*?</section>', page, re.S)
        assert m, "no awaiting region"
        aw = m.group(0)
        assert page.index('data-region="awaiting"') < page.index('data-region="dag-o/arc"'), "panel does not lead"
        for n in (14, 31, 40, 32):
            assert f'data-awaiting="{n}"' in aw, n
        assert aw.index('data-awaiting="31"') < aw.index("<details") < aw.index('data-awaiting="32"'), \
            "resolved ticket is not collapsed at the end"
        assert re.search(r'data-awaiting="31"[^>]*data-kind="wayfinder"', aw)
        assert re.search(r'data-awaiting="40"[^>]*data-kind="operator"', aw)
        assert re.search(r'data-awaiting="14"[^>]*data-kind="agent-blocked"', aw)
        assert " style=" not in page, "inline style"
        assert not os.path.exists(host.gh_called), "gh was invoked"
    with wf.serving(now=wf.NOW, events="events-empty.jsonl") as (base, host):
        _, page = wf.get(base + "/fleet/hz")
        assert "data-tokens" not in page and "data-retries" not in page and "dag__stat" not in page
        for empty in ("None", "undefined", "0 tokens", ">—<", "unknown model"):
            assert empty not in page, f"empty stat rendered: {empty!r}"
        assert not os.path.exists(host.gh_called), "gh was invoked"
    with wf.serving(now=wf.NOW, events=None) as (base, host):
        code, page = wf.get(base + "/fleet/hz")
        assert code == 200 and "data-tokens" not in page and 'data-region="awaiting"' in page


def test_awaiting_region_is_pushed_live():
    with wf.serving(now=wf.NOW) as (base, host):
        regs = host.model.render("/fleet/hz")["regions"]
        assert list(regs)[:2] == ["header", "awaiting"], list(regs)


if __name__ == "__main__":
    sys.exit(wf.run_tests(globals()))
