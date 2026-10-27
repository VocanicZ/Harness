#!/usr/bin/env python3
"""test_web_drawer.py — #228: the issue drawer shows every field from cached data only, a deep link
opens it on first paint, and an issue's PR and live session are two clicks from `/`. With a browser it
also drives the keyboard: Enter on a DAG node opens the drawer, Tab stays inside it, Esc closes it and
puts focus back on the node, all at 400 px with no sideways page scroll."""
import os, re, shutil, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import web_fixture as wf
web_data = wf.load("web_data")
TMUX = "hz-arc-i11\t%d\n" % (wf.NOW - 600)


def test_drawer_shows_every_field():
    with wf.serving(tmux_ls=TMUX, now=wf.NOW) as (base, host):
        code, d = wf.get(base + "/fleet/hz/issue/13?repo=o/arc")
        assert code == 200, code
        assert re.search(r'<aside [^>]*role="dialog"[^>]*data-issue="13"', d), "not a dialog for #13"
        for needle in ('Child in review', 'data-label="ready-for-agent"', 'data-parent="3"',
                       'href="https://github.com/o/arc/pull/60"', 'data-ci="success"',
                       'href="https://github.com/o/arc/issues/13"'):
            assert needle in d, needle
        # the fields in the order #228 lists them, the GitHub link last
        order = [d.index(s) for s in ('data-field="labels"', 'data-field="deps"', 'data-field="pr"',
                                      'data-field="session"', 'data-field="github"')]
        assert order == sorted(order), order
        _, d = wf.get(base + "/fleet/hz/issue/12?repo=o/arc")
        assert re.search(r'data-blocked-by="11"[^>]*data-state="in-progress"', d), "deps lack their state"
        assert 'data-parent="2"' in d
        assert 'data-pr="none"' in d and 'data-ci="unknown"' in d, "an issue with no cached PR must say so"
        _, d = wf.get(base + "/fleet/hz/issue/11?repo=o/arc")
        assert 'data-session="hz-arc-i11"' in d, "the live session is missing"
        ev = re.findall(r'data-event="([a-z_]+)"', d)
        assert ev == ["claim", "launch", "nudge", "session_end"], ev          # o/quiet's #11 is not ours
        _, d = wf.get(base + "/fleet/hz/issue/41?repo=o/arc")
        assert re.findall(r'data-event="([a-z_]+)"', d) == ["launch", "watchdog_kill", "launch"]
        assert 'data-session="none"' in d, "a session that is not in tmux is not live"
        _, d = wf.get(base + "/fleet/hz/issue/31?repo=o/arc")        # wayfinder: on no DAG, still an issue
        assert re.search(r'data-blocked-by="4"[^>]*data-state="waiting"', d), d
        _, d = wf.get(base + "/fleet/hz/issue/13")                    # repo optional: the fleet's own board
        assert 'data-ci="success"' in d
        for bad in ("/fleet/hz/issue/999?repo=o/arc", "/fleet/hz/issue/13?repo=x/nope", "/fleet/nope/issue/13",
                    "/fleet/hz/issue/abc", "/fleet/hz?issue=999"):
            assert wf.get(base + bad)[0] == 404, bad
        assert wf.get(base + "/api/fleet/hz/issue/13")[0] == 200
        assert wf.request("POST", base + "/fleet/hz/issue/13")[0] == 405
        assert not os.path.exists(host.gh_called), "gh was invoked"


def test_uncached_pr_data_reads_as_unknown():
    """A snapshot from a poller that predates PR caching has no `pulls`: the PR is unknown, not "none",
    and nothing goes to GitHub to find out."""
    with wf.serving(tmux_ls=TMUX, now=wf.NOW) as (base, host):
        p = os.path.join(host.snapshots, "o__arc.json")
        snap = wf.json.load(open(p))
        for k in ("pulls", "checks"):
            snap.pop(k)
        host.write_json(p, snap)
        _, d = wf.get(base + "/fleet/hz/issue/13?repo=o/arc")
        assert 'data-pr="unknown"' in d and 'data-ci="unknown"' in d, d
        assert not os.path.exists(host.gh_called), "gh was invoked"


def test_no_event_log_is_an_empty_timeline():
    with wf.serving(tmux_ls=TMUX, now=wf.NOW, events=None) as (base, host):
        code, d = wf.get(base + "/fleet/hz/issue/11?repo=o/arc")
        assert code == 200 and "data-event=" not in d and 'data-timeline="empty"' in d


def test_deep_link_opens_the_drawer_and_overview_reaches_it_in_one_click():
    with wf.serving(tmux_ls=TMUX, now=wf.NOW) as (base, host):
        _, page = wf.get(base + "/fleet/hz?issue=13")
        assert re.search(r'<aside [^>]*role="dialog"[^>]*data-issue="13"', page), "deep link did not open the drawer"
        assert 'href="https://github.com/o/arc/pull/60"' in page        # click 2: the PR
        # the drawer sits outside every live region, so an SSE swap never closes it
        regions = re.findall(r'<section data-region=.*?</section>', page, re.S)
        assert not any("role=\"dialog\"" in r for r in regions), "the drawer is inside a region"
        _, plain = wf.get(base + "/fleet/hz")
        assert 'role="dialog"' not in plain
        _, ov = wf.get(base + "/")
        assert 'href="/fleet/hz?issue=11"' in ov, "the overview's session row does not link into the drawer"
        _, d = wf.get(base + "/fleet/hz?issue=11")                      # click 1 lands on the live session
        assert 'data-session="hz-arc-i11"' in d
        assert not os.path.exists(host.gh_called), "gh was invoked"


def test_issue_view_model():
    with wf.serving(tmux_ls=TMUX, now=wf.NOW):
        v = web_data.issue_view("hz", "o/arc", 13, wf.NOW)
        assert v["pr"]["number"] == 60 and v["ci"] == "success", v
        assert v["parent"] == 3 and v["labels"] == ["ready-for-agent"] and v["state"] == "in-review", v
        assert v["url"] == "https://github.com/o/arc/issues/13"
        v = web_data.issue_view("hz", "o/arc", 12, wf.NOW)
        assert v["blocked_by"] == [{"number": 11, "state": "in-progress"}] and v["pr"] is None, v
        v = web_data.issue_view("hz", "o/arc", 11, wf.NOW)
        assert v["session"]["name"] == "hz-arc-i11" and [e["event"] for e in v["timeline"]][0] == "claim", v
        assert web_data.issue_view("hz", "o/arc", 999, wf.NOW) is None
        assert web_data.issue_view("hz", "x/nope", 13, wf.NOW) is None
        assert web_data.issue_view("nope", "o/arc", 13, wf.NOW) is None


def test_keyboard_and_400px():
    browser = os.environ.get("HARNESS_WEB_BROWSER") or shutil.which("google-chrome") or shutil.which("chromium")
    if not (browser and shutil.which("node")):
        print("  SKIP: keyboard half needs a Chrome and Node >= 22 (HARNESS_WEB_BROWSER)"); return
    node13 = "document.querySelector('.dag [data-issue=\"13\"]')"
    drawer = "document.querySelector('aside[role=\"dialog\"]')"
    with wf.serving(tmux_ls=TMUX, now=wf.NOW, tick=0.2) as (base, host):
        with wf.cdp(browser, base + "/fleet/hz") as page:
            page.viewport(400)
            page.eval("window.__marker = 1")                      # survives only if there is no reload
            page.eval(node13 + ".focus()")
            page.key("Enter")
            page.wait(f"{drawer} && {drawer}.dataset.issue === '13'", 5)
            assert page.eval(f"{drawer}.contains(document.activeElement)"), "focus did not move into the drawer"
            assert page.eval("new URLSearchParams(location.search).get('issue')") == "13", "URL not shareable"
            assert page.eval("window.__marker") == 1, "the drawer opened by reloading the page"
            for shift in (False, False, False, False, False, True, True, True, True, True, True, True):
                page.key("Tab", shift=shift)
                assert page.eval(f"{drawer}.contains(document.activeElement)"), "Tab left the drawer"
            assert page.eval("document.documentElement.scrollWidth <= window.innerWidth"), "page scrolls sideways at 400 px"
            assert page.eval(f"{drawer}.getBoundingClientRect().right <= window.innerWidth + 0.5"), "drawer overflows 400 px"
            page.key("Escape")
            page.wait(f"!{drawer}", 5)
            assert page.eval(f"document.activeElement === {node13}"), "focus did not return to the node"
            assert page.eval("new URLSearchParams(location.search).get('issue')") is None
            # a row in the unparented list opens it too, by click
            page.eval("document.querySelector('.unparented [data-issue=\"20\"]').click()")
            page.wait(f"{drawer} && {drawer}.dataset.issue === '20'", 5)
            # a push that touches the open issue refreshes the drawer in place, and keeps it open
            by = {i["number"]: i for i in wf.json.load(open(os.path.join(host.snapshots, "o__arc.json")))["issues"]}
            by[20]["labels"].append({"name": "agent-blocked"})
            host.write_board("o__arc", list(by.values()), wf.NOW + 60)
            page.wait(f"!!{drawer}.querySelector('[data-label=\"agent-blocked\"]')", 10)
            assert page.eval("window.__marker") == 1, "the page reloaded"
            page.key("Escape")
            page.wait(f"!{drawer}", 5)
        with wf.cdp(browser, base + "/fleet/hz?issue=13") as page:   # deep link: open on first paint
            page.viewport(400)
            page.wait(f"{drawer} && {drawer}.contains(document.activeElement)", 5)
            page.key("Escape")
            page.wait(f"!{drawer}", 5)
            assert page.eval(f"document.activeElement === {node13}"), "focus did not land on the node"
        assert not os.path.exists(host.gh_called), "gh was invoked"


if __name__ == "__main__":
    sys.exit(wf.run_tests(globals()))
