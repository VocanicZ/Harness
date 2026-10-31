#!/usr/bin/env python3
"""test_web_health.py — #225: the overview surfaces what needs a human. On the fixture host, `hz` has
a frozen session (#41), a stale agent-working lock (#42), a dead pid file and a firing arc alarm, and
the token is held on a rate limit; `dp` has nothing wrong and must read as healthy."""
import os, re, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import web_fixture as wf
rules = wf.load("supervise_rules")
web_data = wf.load("web_data")
NOW = wf.NOW
TMUX = "hz-arc-i11\t%d\nhz-arc-i41\t%d\n" % (NOW - 600, NOW - 9000)


def test_pane_activity_follows_the_supervisor_thresholds():
    act = lambda t0, nudged: rules.pane_activity(f"h 0 0 {t0} {nudged} 0", NOW, 45, 120)["state"]
    assert act(NOW - 60, 0) == "active"
    assert act(NOW - 46 * 60, 0) == "quiet"
    assert act(NOW - 50 * 60, 1) == "nudged"
    assert act(NOW - 121 * 60, 1) == "frozen"
    assert rules.pane_activity(f"h 0 0 {NOW - 600} 0 0", NOW, 45, 120)["quiet_s"] == 600
    assert rules.pane_activity("garbage", NOW, 45, 120)["state"] == "active"   # unreadable: never alarm


def test_supervise_thresholds_read_the_conf_without_sourcing_it():
    d = tempfile.mkdtemp(prefix="harness-web-conf-")
    conf = os.path.join(d, "supervise.conf")
    with open(conf, "w") as fh:
        fh.write("# host config\nNUDGE_MIN=10\nKILL_MIN=$(touch pwned)\nINTERVAL=60\n")
    assert web_data.supervise_conf(conf) == {"NUDGE_MIN": 10, "KILL_MIN": 120, "INTERVAL": 60}
    assert web_data.supervise_conf(os.path.join(d, "absent")) == {"NUDGE_MIN": 45, "KILL_MIN": 120, "INTERVAL": 300}
    assert not os.path.exists(os.path.join(d, "pwned"))


def test_cli_and_model_come_from_the_adapter_or_fall_back():
    assert web_data.fleet_cli({}) == ("claude", True)
    assert web_data.fleet_cli({"HARNESS_CLI": "agy"}) == ("agy", True)
    assert web_data.fleet_cli({"HARNESS_CLI": "nocli"}) == ("nocli", False)
    live = {"zz-arc-i7": NOW - 60}
    s = web_data.live_sessions("zz", NOW, live, {"zz-arc-i7": "m-1"}, None, {"HARNESS_CLI": "nocli"}, web_data.SUP_DEFAULTS)
    assert (s[0]["cli"], s[0]["model"]) == ("nocli", None), s
    s = web_data.live_sessions("zz", NOW, live, {"zz-arc-i7": "m-1"}, None, {}, web_data.SUP_DEFAULTS)
    assert (s[0]["cli"], s[0]["model"]) == ("claude", "m-1"), s


def test_overview_flags_hz_and_calls_dp_healthy():
    with wf.serving(tmux_ls=TMUX, now=NOW) as (base, host):
        h = wf.get_json(base + "/api/host")
        f = {x["prefix"]: x for x in h["fleets"]}
        kinds = sorted((a["kind"], str(a["what"])) for a in f["hz"]["attention"])
        assert ("frozen", "hz-arc-i41") in kinds, kinds
        assert ("stale-lock", "#42") in kinds, kinds
        assert ("stale-lock", "#11") not in kinds and ("stale-lock", "#41") not in kinds, kinds
        assert any(k == "stale-pidfile" for k, _ in kinds), kinds
        assert any(k == "alarm" for k, _ in kinds), kinds
        assert f["dp"]["attention"] == [], f["dp"]["attention"]
        s = {x["name"]: x for x in f["hz"]["sessions"]}
        assert s["hz-arc-i11"]["issue"] == "#11" and s["hz-arc-i11"]["activity"] == "active"
        assert s["hz-arc-i11"]["kind"] == "impl" and s["hz-arc-i11"]["age_s"] == 600
        assert s["hz-arc-i11"]["cli"] == "claude" and s["hz-arc-i11"]["model"] == "claude-opus-5-5"
        assert s["hz-arc-i41"]["activity"] == "frozen" and s["hz-arc-i41"]["model"] is None
        assert h["rate"][0]["hold_until"] > NOW and h["rate"][0]["resources"]["core"]["remaining"] == 0
        assert [a["kind"] for a in h["attention"]] == ["rate-hold"], h["attention"]
        acts = f["hz"]["supervisor"]["actions"]
        assert acts and all("hzx-" not in a for a in acts), acts      # a longer prefix is not hz's
        assert f["dp"]["supervisor"]["actions"] == [], f["dp"]["supervisor"]
        _, body = wf.get(base + "/")
        assert re.search(r'data-fleet="hz"[^>]*data-health="attention"', body)
        assert re.search(r'data-fleet="dp"[^>]*data-health="healthy"', body)
        hz = body[body.index('data-fleet="hz"'):]
        hz = hz[:hz.index("</article>")]
        assert "needs attention (" in hz and "hz-arc-i41" in hz and "#42" in hz, hz
        assert "claude-opus-5-5" in hz and "frozen" in hz, "sessions table missing"
        assert "send-keys -t hz-arc-i41" in hz, "supervisor actions missing"
        assert "core" in body and "held until" in body, "no rate budget / hold on the page"
        assert not os.path.exists(host.gh_called), "gh was invoked"


def test_a_stale_supervisor_pane_file_is_unknown_not_frozen():
    """No supervisor pass for a long while (it is not running): its pane files describe the past,
    so the page says `unknown` instead of calling every session frozen."""
    with wf.serving(tmux_ls=TMUX, now=NOW) as (base, host):
        pane = os.path.join(host.home, "supervise", "panes", "hz-arc-i41")
        os.utime(pane, (NOW - 6 * 3600, NOW - 6 * 3600))
        f = {x["prefix"]: x for x in wf.get_json(base + "/api/host")["fleets"]}
        s = {x["name"]: x for x in f["hz"]["sessions"]}
        assert s["hz-arc-i41"]["activity"] is None, s["hz-arc-i41"]
        assert not any(a["kind"] == "frozen" for a in f["hz"]["attention"]), f["hz"]["attention"]


def test_a_dead_claim_is_a_stale_lock_and_a_live_one_is_not():
    with wf.serving(tmux_ls=TMUX, now=NOW) as (base, host):
        claims = os.path.join(host.projects["dp"], "run", "claims")
        os.makedirs(claims, exist_ok=True)
        with open(os.path.join(claims, "quiet.claim"), "w") as fh:
            fh.write(f"w1 {os.getpid()}\n")
        f = {x["prefix"]: x for x in wf.get_json(base + "/api/host")["fleets"]}
        assert f["dp"]["attention"] == [], f["dp"]["attention"]
        with open(os.path.join(claims, "quiet.claim"), "w") as fh:
            fh.write(f"w1 {wf.dead_pid()}\n")
        f = {x["prefix"]: x for x in wf.get_json(base + "/api/host")["fleets"]}
        assert [(a["kind"], a["what"]) for a in f["dp"]["attention"]] == [("stale-claim", "quiet")], f["dp"]
        _, body = wf.get(base + "/")
        assert re.search(r'data-fleet="dp"[^>]*data-health="attention"', body)


def test_a_headless_lane_row_carries_its_state():
    """#352: a live headless lane's own state rides on its session row, the fleet card and the drawer."""
    render = wf.load("web_render")
    live = {"zz-arc-i7": NOW - 60, "zz-arc-i8": NOW - 60}
    s = web_data.live_sessions("zz", NOW, live, {}, None, {}, web_data.SUP_DEFAULTS, {"zz-arc-i7": "limit"})
    assert [(x["name"], x["state"]) for x in s] == [("zz-arc-i7", "limit"), ("zz-arc-i8", None)], s
    html = render._sessions_table(s, NOW, "zz")
    assert re.search(r'data-session="zz-arc-i7"[^>]*data-state="limit"', html), html
    assert not re.search(r'data-session="zz-arc-i8"[^>]*data-state', html), html


if __name__ == "__main__":
    sys.exit(wf.run_tests(globals()))
