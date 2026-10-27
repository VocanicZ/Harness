#!/usr/bin/env python3
"""test_web_live.py — #227: open pages update in place. With the fleet page open in headless Chrome,
rewriting the recorded o/arc board — close #15, open #50 under PRD #3, label #13 agent-blocked, claim
#12 (agent-working + a live session) — reaches the DOM through the SSE stream, with no navigation, and
the as-of stamp advances. A dropped stream reconnects. Without a browser or Node it still checks the
stream itself, and says it skipped the DOM half."""
import json, os, re, shutil, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import web_fixture as wf


def mutate(host, now):
    p = os.path.join(host.snapshots, "o__arc.json")
    b = json.load(open(p))
    by = {i["number"]: i for i in b["issues"]}
    by[15]["state"] = "CLOSED"
    by[13]["labels"].append({"name": "agent-blocked"})
    by[12]["labels"].append({"name": "agent-working"})
    b["issues"].insert(0, {"number": 50, "title": "new child", "state": "OPEN", "labels": [],
                           "body": "## Parent\n#3\n", "author": {"login": "bot"}, "updatedAt": "2026-10-27T00:00:00Z"})
    b["generated_at"] = now
    tmp = p + ".tmp"; json.dump(b, open(tmp, "w")); os.replace(tmp, p)   # atomic, as the poller writes
    host.set_tmux("hz-arc-i11\t%d\nhz-arc-i12\t%d\n" % (now, now))


def test_sse_stream_carries_the_change():
    with wf.serving(tick=0.2) as (base, host):
        with wf.sse(base + "/events?view=/fleet/hz") as stream:
            assert stream.first_retry() == 3000
            mutate(host, wf.NOW + 60)
            ev = stream.next_event("patch", timeout=5)
            html = "".join(ev["regions"].values())
            for pat in (r'data-issue="15"[^>]*data-state="closed"', r'data-issue="50"',
                        r'data-issue="13"[^>]*data-state="agent-blocked"', r'data-issue="12"[^>]*data-state="in-progress"'):
                assert re.search(pat, html), pat
            assert ev["asof"] == wf.NOW + 60
        assert wf.request("POST", base + "/events?view=/fleet/hz")[0] == 405
        assert not os.path.exists(host.gh_called), "gh was invoked"


def test_overview_stream_carries_fleet_state():
    """The overview subscribes too: a board change re-sends the fleets region (tally, sessions)."""
    with wf.serving(tick=0.2) as (base, host):
        _, page = wf.get(base + "/")
        assert re.search(r'<html [^>]*data-view="/"', page), "overview does not name its view"
        with wf.sse(base + "/events?view=/") as stream:
            assert stream.first_retry() == 3000
            mutate(host, wf.NOW + 60)
            ev = stream.next_event("patch", timeout=5)
            # only what changed: the cards; the header's count and oldest as-of (dp's board) stand
            assert sorted(ev["regions"]) == ["fleets"], sorted(ev["regions"])
            assert 'data-session="hz-arc-i12"' in ev["regions"]["fleets"], "claimed session not on the card"
            assert ev["asof"] == wf.NOW - 120                    # dp's board is still the oldest
        assert not os.path.exists(host.gh_called), "gh was invoked"


def test_stream_sends_only_what_changed_and_resumes_by_last_event_id():
    with wf.serving(tick=0.2) as (base, host):
        _, page = wf.get(base + "/fleet/hz")
        version = re.search(r'<html [^>]*data-version="([0-9a-f]+)"', page).group(1)
        # a client already holding this version gets no catch-up push, only later changes
        with wf.sse(base + "/events?view=/fleet/hz", last_event_id=version) as stream:
            assert stream.first_retry() == 3000
            mutate(host, wf.NOW + 60)
            ev = stream.next_event("patch", timeout=5)
            assert "dag-o/arc" in ev["regions"], sorted(ev["regions"])
            assert stream.last_id and stream.last_id != version
            new = stream.last_id
        # a client behind (the page's stale version) gets every region at once
        with wf.sse(base + "/events?view=/fleet/hz", last_event_id=version) as stream:
            stream.first_retry()
            ev = stream.next_event("patch", timeout=5)
            assert {"header", "dag-o/arc", "unparented-o/arc"} <= set(ev["regions"]), sorted(ev["regions"])
            assert stream.last_id == new
        # a client that is current sees nothing until the next change
        with wf.sse(base + "/events?view=/fleet/hz", last_event_id=new) as stream:
            stream.first_retry()
            assert stream.next_event("patch", timeout=1, missing_ok=True) is None


def test_events_route_rules():
    with wf.serving(tick=0.2) as (base, host):
        assert wf.get(base + "/events?view=/fleet/nope")[0] == 404
        assert wf.get(base + "/events?view=/static/app.js")[0] == 404
        assert wf.get(base + "/events")[0] == 404
        hdrs = wf.headers(base + "/events?view=/", method="HEAD")
        assert hdrs["Content-Type"].startswith("text/event-stream"), hdrs
        assert hdrs.get("Content-Security-Policy", "").startswith("default-src 'self'")
        for m in ("POST", "PUT", "DELETE"):
            assert wf.request(m, base + "/events?view=/")[0] == 405, m
    os.environ["HARNESS_WEB_MAX_STREAMS"] = "1"
    try:
        with wf.serving(tick=0.2) as (base, host):
            with wf.sse(base + "/events?view=/") as stream:
                stream.first_retry()
                assert wf.get(base + "/events?view=/")[0] == 503
    finally:
        del os.environ["HARNESS_WEB_MAX_STREAMS"]


def test_dropped_stream_ends_and_a_reconnect_catches_up():
    with wf.serving(tick=0.2) as (base, host):
        _, page = wf.get(base + "/fleet/hz")
        version = re.search(r'<html [^>]*data-version="([0-9a-f]+)"', page).group(1)
        with wf.sse(base + "/events?view=/fleet/hz&since=" + version) as stream:
            stream.first_retry()
            host.drop_streams()
            assert stream.closed(timeout=5), "stream stayed open after close_streams"
            last = stream.last_id or version
        mutate(host, wf.NOW + 60)                       # changes while no stream is open
        with wf.sse(base + "/events?view=/fleet/hz&since=" + version, last_event_id=last) as stream:
            stream.first_retry()
            ev = stream.next_event("patch", timeout=5)
            assert re.search(r'data-issue="15"[^>]*data-state="closed"', "".join(ev["regions"].values()))


def test_dom_updates_without_reload():
    browser = os.environ.get("HARNESS_WEB_BROWSER") or shutil.which("google-chrome") or shutil.which("chromium")
    if not (browser and shutil.which("node")):
        print("  SKIP: DOM half needs a Chrome and Node >= 22 (HARNESS_WEB_BROWSER)"); return
    with wf.serving(tick=0.2) as (base, host):
        with wf.cdp(browser, base + "/fleet/hz") as page:
            page.eval("window.__marker = 1")                      # survives only if there is no reload
            asof = page.eval("document.querySelector('time[data-asof]').dateTime")
            mutate(host, wf.NOW + 60)
            page.wait("document.querySelector('[data-issue=\"15\"]').dataset.state === 'closed'", 5)
            page.wait("!!document.querySelector('[data-issue=\"50\"]')", 5)
            page.wait("document.querySelector('[data-issue=\"13\"]').dataset.state === 'agent-blocked'", 5)
            page.wait("document.querySelector('[data-issue=\"12\"]').dataset.state === 'in-progress'", 5)
            assert page.eval("window.__marker") == 1, "the page reloaded"
            assert page.eval("document.querySelector('time[data-asof]').dateTime") != asof, "as-of did not advance"
            host.drop_streams()                                   # server closes every stream
            page.wait("document.querySelector('[data-live]').dataset.live === 'reconnecting'", 5)
            by = {i["number"]: i for i in json.load(open(os.path.join(host.snapshots, "o__arc.json")))["issues"]}
            by[14]["state"] = "CLOSED"; host.write_board("o__arc", list(by.values()), wf.NOW + 120)
            page.wait("document.querySelector('[data-issue=\"14\"]').dataset.state === 'closed'", 10)
            page.wait("document.querySelector('[data-live]').dataset.live === 'live'", 5)
            assert page.eval("window.__marker") == 1, "the page reloaded"
        assert not os.path.exists(host.gh_called), "gh was invoked"


if __name__ == "__main__":
    sys.exit(wf.run_tests(globals()))
