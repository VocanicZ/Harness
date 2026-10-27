#!/usr/bin/env python3
"""test_web.py — #223: `harness web` serves the host overview from local state only, read-only.

web_fixture builds a HARNESS_HOME from test/fixtures/web/ (two registered fleets: `hz` running, with
a live worker pid, and `dp` stopped), puts a `gh` that records being called first on PATH, and serves
web.Model on 127.0.0.1:0 in a thread."""
import json, os, re, shutil, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import web_fixture as wf
web = wf.load("web")
web_data = wf.load("web_data")
fleetview = wf.load("fleetview")


def test_overview_lists_every_fleet_with_state_and_link():
    with wf.serving() as (base, host):
        code, body = wf.get(base + "/")
        assert code == 200, code
        for pfx, state in (("hz", "running"), ("dp", "stopped")):
            assert f'href="/fleet/{pfx}"' in body, f"no link to /fleet/{pfx}"
            assert re.search(rf'data-fleet="{pfx}"[^>]*data-state="{state}"', body), (pfx, state)
        assert re.search(r'data as of <time datetime="\d{4}-\d\d-\d\dT[\d:]+Z"', body), "no as-of stamp"
        code, _ = wf.get(base + "/fleet/hz")
        assert code == 200, f"fleet stub: {code}"
        assert wf.get(base + "/fleet/nope")[0] == 404
        assert not os.path.exists(host.gh_called), "gh was invoked while serving pages"


def test_every_write_method_is_405_on_every_route():
    with wf.serving() as (base, host):
        for path in ("/", "/fleet/hz", "/api/host", "/api/fleet/hz", "/static/tokens.css", "/nope"):
            for method in ("POST", "PUT", "PATCH", "DELETE", "OPTIONS"):
                code, _ = wf.request(method, base + path, body=b"x=1")
                assert code == 405, f"{method} {path} -> {code}"
            assert wf.headers(base + path, "DELETE").get("Allow") == "GET, HEAD", path
        assert not os.path.exists(host.gh_called), "gh was invoked"


def test_static_serves_only_the_allow_list():
    with wf.serving() as (base, host):
        for name in ("tokens.css", "components.css", "app.css", "app.js"):
            assert wf.get(base + "/static/" + name)[0] == 200, name
        assert wf.headers(base + "/static/app.js")["Content-Type"].startswith("text/javascript")
        for bad in ("/static/../web.py", "/static/%2e%2e/web.py", "/static/nope.css", "/static/"):
            assert wf.get(base + bad)[0] == 404, bad


def test_bind_and_port_come_from_env():
    assert web.bind_addr({}) == ("127.0.0.1", 4637)
    assert web.bind_addr({"HARNESS_WEB_BIND": "0.0.0.0", "HARNESS_WEB_PORT": "5000"}) == ("0.0.0.0", 5000)
    assert web.bind_addr({"HARNESS_WEB_BIND": "", "HARNESS_WEB_PORT": ""}) == ("127.0.0.1", 4637)


def test_tokens_copied_with_source_commit_and_both_themes():
    for name in ("tokens.css", "components.css"):
        css = open(os.path.join(wf.ROOT, "web", "static", name), encoding="utf-8").read()
        assert re.search(r"design-to-print@[0-9a-f]{40} app/styles/" + re.escape(name), css.splitlines()[0]), \
            f"{name}: no source-commit header"
    css = open(os.path.join(wf.ROOT, "web", "static", "tokens.css"), encoding="utf-8").read()
    assert "prefers-color-scheme: dark" in css and ':root[data-theme="dark"]' in css
    assert ':root:not([data-theme="light"])' in css


def test_every_response_forbids_external_loads():
    with wf.serving() as (base, host):
        for path in ("/", "/api/host", "/static/app.js", "/nope"):
            hdrs = wf.headers(base + path)
            assert hdrs.get("Content-Security-Policy", "").startswith("default-src 'self'"), (path, hdrs)
            assert hdrs.get("X-Content-Type-Options") == "nosniff", path
        code, body = wf.get(base + "/")
        # no external URL and nothing inline the CSP would refuse (style="" / inline <script>)
        assert not re.search(r'(src|href)="(https?:)?//', body), "page references an external URL"
        assert " style=" not in body and not re.search(r"<script(?![^>]*\ssrc=)", body), "inline style/script"


def test_api_host_reports_state_tally_and_asof_from_snapshots():
    with wf.serving() as (base, host):
        view = wf.get_json(base + "/api/host")
        fleets = {f["prefix"]: f for f in view["fleets"]}
        assert set(fleets) == {"hz", "dp"}, fleets
        hz, dp = fleets["hz"], fleets["dp"]
        assert (hz["state"], hz["workers"], hz["pool"]) == ("running", 1, 2), hz
        assert (dp["state"], dp["workers"], dp["pool"]) == ("stopped", 0, 3), dp
        # o/arc: open #2 (prd), #11 (working), #12 (ready), #14 (ready+blocked); closed #1, #10 are not counted
        assert hz["repos"][0]["tally"] == {"open": 4, "unblocked": 3, "working": [11], "pending": 4}, hz["repos"]
        # dp's ready label is `go` (its config), so its one open issue is pending
        assert dp["repos"][0]["tally"] == {"open": 1, "unblocked": 1, "working": [], "pending": 1}, dp["repos"]
        # as-of is the board's own generated_at — the oldest one — never the server clock
        assert (hz["asof"], dp["asof"], view["asof"]) == (wf.NOW - 60, wf.NOW - 120, wf.NOW - 120), view
        assert wf.get_json(base + "/api/fleet/hz")["prefix"] == "hz"
        assert wf.get(base + "/api/fleet/nope")[0] == 404
        assert not os.path.exists(host.gh_called)


def test_complete_missing_and_unreadable_boards():
    with wf.serving() as (base, host):
        # every issue closed and the fleet stopped → complete (fleetview's rule, applied to the snapshot)
        host.add_fleet("zz", ["o/done"])
        host.write_snapshot("o/done", {"schema_version": 1, "generated_at": wf.NOW - 10, "slug": "o/done",
                                       "issues": [{"number": 1, "state": "CLOSED", "labels": []}]})
        # an unknown snapshot schema is not read: unknown counts, so never complete
        host.add_fleet("yy", ["o/future"])
        host.write_snapshot("o/future", {"schema_version": 99, "generated_at": wf.NOW, "issues": []})
        # a registry record whose project dir is gone
        gone = host.add_fleet("xx", ["o/arc"])
        shutil.rmtree(os.path.dirname(gone))
        fleets = {f["prefix"]: f for f in wf.get_json(base + "/api/host")["fleets"]}
        assert fleets["zz"]["state"] == "complete", fleets["zz"]
        assert fleets["yy"]["state"] == "stopped" and fleets["yy"]["repos"][0]["tally"] is None, fleets["yy"]
        assert fleets["yy"]["asof"] is None, fleets["yy"]
        assert fleets["xx"]["state"] == "missing", fleets["xx"]
        code, body = wf.get(base + "/")
        assert code == 200 and re.search(r'data-fleet="xx"[^>]*data-state="missing"', body)
        assert re.search(r'data-fleet="zz"[^>]*data-state="complete"', body)


def test_head_has_headers_and_no_body():
    with wf.serving() as (base, host):
        code, body = wf.request("HEAD", base + "/")
        assert code == 200 and body == "", (code, body)
        assert wf.headers(base + "/", "HEAD").get("Content-Type", "").startswith("text/html")


def test_empty_registry_renders_an_empty_state():
    with wf.serving() as (base, host):
        for name in os.listdir(host.fleets):
            os.unlink(os.path.join(host.fleets, name))
        code, body = wf.get(base + "/")
        assert code == 200 and "No fleets registered" in body, body[-400:]
        assert "data as of" in body


def test_fleetview_issue_counts_still_uses_tally():
    """The `tally` split: fleetview's gh-backed counts are unchanged (gh's open list carries no state)."""
    labels = fleetview.fleet_labels({})
    issues = [{"number": 5, "labels": [{"name": "agent-working"}]}, {"number": 6, "labels": [{"name": "agent-blocked"}]}]
    real = fleetview.run_cmd
    fleetview.run_cmd = lambda argv, timeout=20: (0, json.dumps(issues))
    try:
        assert fleetview.issue_counts("o/x", labels) == {"open": 2, "unblocked": 1, "working": [5], "pending": 1}
    finally:
        fleetview.run_cmd = real
    assert web_data.tally is fleetview.tally


def test_harness_web_entry_runs_the_server():
    """`harness web` dispatches to scripts/web.sh, which serves on HARNESS_WEB_BIND:HARNESS_WEB_PORT."""
    env = dict(os.environ, HARNESS_WEB_BIND="127.0.0.1", HARNESS_WEB_PORT="0")
    p = subprocess.Popen(["bash", os.path.join(wf.ROOT, "bin", "harness"), "web"], env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        line = p.stdout.readline()
        assert re.match(r"harness web: serving http://127\.0\.0\.1:\d+/", line), line
    finally:
        p.terminate(); p.wait(timeout=10)
    out = subprocess.run(["bash", os.path.join(wf.ROOT, "bin", "harness", ), "web", "--bogus"], env=env,
                         capture_output=True, text=True)
    assert out.returncode == 2 and "usage" in out.stderr, (out.returncode, out.stderr)


def test_readme_documents_harness_web():
    readme = open(os.path.join(wf.ROOT, "README.md"), encoding="utf-8").read()
    assert re.search(r"^\| `web` \|", readme, re.M), "no `web` row in the command table"
    assert "## Dashboard" in readme
    for needle in ("HARNESS_WEB_BIND", "HARNESS_WEB_PORT", "127.0.0.1:4637", "HARNESS_WEB_BIND=0.0.0.0", "Internet"):
        assert needle in readme, needle


if __name__ == "__main__":
    sys.exit(wf.run_tests(globals()))
