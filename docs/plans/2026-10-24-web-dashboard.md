# Web Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `harness web` serves a local, live, read-only dashboard on `http://127.0.0.1:4637/`. It shows every Harness fleet on the host and its health, each fleet's PRD → issue map as a layered DAG, what is waiting on a human, and any issue's PR and live session. Open pages update themselves over SSE within one board-cache refresh of an issue opening, closing, being labelled or being claimed. It replaces the `harness-arc` status-page Artifact, which went stale every time someone forgot to re-run `status-page.py`.

**Architecture:** One Python-stdlib process (`scripts/web.py`, a `ThreadingHTTPServer`) holds a `Model`. A collector thread inside the model checks the host's local state every `HARNESS_WEB_TICK` seconds (default 2) with `stat` calls only. That state is the fleet registry (`$HARNESS_FLEETS_DIR`), the poller's board snapshots (`$HARNESS_SNAPSHOTS_DIR`, #182), the event log (`$HARNESS_HOME/events.jsonl`, #185/#186), `tmux ls`, the supervisor's log, pane state and alarm counters (#180/#181), and the rate-limit files (`$HARNESS_HOME/ghrate/`, #183). When any input changes, the collector rebuilds the view models through `scripts/web_data.py` (the adapters) and `scripts/web_dag.py` (the DAG layout ported from `status-page.py`), and wakes every SSE stream whose view changed. HTML is rendered in exactly one place, `scripts/web_render.py`. A first page load gets the whole page. An SSE push carries the re-rendered HTML of each changed `data-region`, and `web/static/app.js` swaps those regions in place, keeping focus and an open drawer. There is no client-side templating and no build step. The look is copied (never linked) from the owner's design-to-print project into `web/static/tokens.css` and `components.css`. `harness web --install` runs the same server as a systemd user unit, modelled on `harness supervise --install`, and `harness update` redeploys it.

**Tech Stack:** Python 3 stdlib (`http.server`, `threading`, `json`, `html`, already a hard dependency of `scripts/lib.sh`), plain HTML/CSS/JS, Bash 5 for the `harness web` entry and the systemd unit, `tmux`, the repo's own test rig (`test/helpers.sh`, `test/run.sh`). Headless browser tests drive the host's Chrome (`google-chrome`, or `HARNESS_WEB_BROWSER`) over the DevTools protocol from Node ≥ 22's built-in `WebSocket`. Both are test-only tools, never a runtime dependency.

**Spec:** PRD #192 (what the page shows, constraints, design and quality bar, acceptance). Data and behaviour reference: `skill/harness-arc/scripts/status-page.py` (moved into the repo by #181): its layered PRD DAG, child counts by `## Parent`, edges from the **last** `## Blocked by`, wayfinder "Awaiting you", and live panes. The text host view `scripts/fleetview.py` (#184) is the reference for fleet state and live sessions.

## Global Constraints

- **Task 1 of PRD #192 is this document (#222).** Tasks 1–9 below are the PRD's remaining children, one task per child issue, and each task's heading names its issue. Nothing starts before this plan merges. Order: Task 1 first. Tasks 2, 3 and 4 need only Task 1. Tasks 5, 6 and 7 need Task 2. Task 8 needs Tasks 2, 4 and 7. Task 9 needs Tasks 3, 5, 6 and 7. This is the `## Blocked by` wiring of #223–#231.
- **Read-only is the safety boundary.** The page has no auth, so no route may change GitHub, tmux, a fleet's files or the host. Every route answers `GET` and `HEAD` only. `POST`, `PUT`, `PATCH`, `DELETE` and `OPTIONS` get `405` with `Allow: GET, HEAD` on every path, known or unknown. The server never runs `tmux send-keys`, `kill`, `harness …` or any write. Its only subprocesses are the read probes `fleetview.run_cmd` already makes (`tmux ls`, `tmux list-panes`, `ps`). A write action in the page, even "just a refresh button that pokes the poller", is a review blocker.
- **No GitHub call per page view, and none from the server at all.** Every page, fragment, JSON and SSE request reads only local snapshots: the board cache, the event log, the rate-limit files and the supervisor state. `fleetview.issue_counts` and `fleetview.gh_budget` call `gh`, so the server must never reach them. It uses the snapshot tally and the `ghrate/*.rate` files instead. Every test runs with a stub `gh` first on `PATH` that writes a marker file and exits 1, and asserts the marker is absent at the end. The only new GitHub reads this PRD adds anywhere are Task 6's two conditional (ETag) reads in the **poller**. A `304` from either costs nothing against the rate limit, and both run once per poller refresh, never per view.
- **Bind and port.** The server binds `HARNESS_WEB_BIND` (default `127.0.0.1`) : `HARNESS_WEB_PORT` (default `4637`), both read in exactly one function, `web.bind_addr(env)`. The claude host's unit sets `HARNESS_WEB_BIND=0.0.0.0` so the owner can open it from the LAN. The README says that, and also says that read-only is the only protection and the port must not be exposed to the Internet.
- **No build step, no new runtime dependency.** The shipped files are plain `.py`, `.html`, `.css` and `.js`, served from `web/static/` as they are in git. No bundler, no npm package, no CDN, no web font fetched at runtime. Fonts are the system stacks `tokens.css` names, or files copied into `web/static/fonts/` if design-to-print ships them. Every response carries `Content-Security-Policy: default-src 'self'`, so a stray external URL fails in the browser at once instead of passing review. Node and Chrome are test tools only (Tech Stack).
- **design-to-print is read-only, always.** Tasks 1 and 9 clone `https://github.com/VocanicZ/design-to-print` to `~/design-to-print` for reference and delete the clone when done. Never edit, commit to, push to or open a PR on `VocanicZ/design-to-print` or `~/design-to-print`. Before deleting the clone, run `git -C ~/design-to-print status --porcelain` and paste its (empty) output into the PR. Copied CSS starts with `/* Source: VocanicZ/design-to-print@<full commit sha> <path> — copied, not linked; edit here. */`.
- **One renderer.** HTML is produced only by `scripts/web_render.py`, from the view models `scripts/web_data.py` builds. An SSE push sends that same HTML for each changed region (`<section data-region="…">`), and `app.js` only swaps regions, toggles the theme and opens and closes the drawer. A second rendering of the same data in JavaScript is a review blocker.
- **Port `status-page.py`'s semantics, not its code paths.** Parent attribution comes from `## Parent`. Dependency edges come from the **last** `## Blocked by` section (a `None` anywhere in it means no edges). Layering is longest-path with a cycle guard. PRD state is `done` / `waiting` / `running` / `ready`, exactly as `status-page.py` derives it. Task 2's golden test pins all of that on one fixture. `issuelib.parse_blocked_by` parses the **first** section, so do not reuse it for the DAG.
- **Every view shows "data as of".** It is the `generated_at` of the oldest board snapshot the view used, shown as `<time datetime="…Z">` with a relative label. It is the board's own clock, never the server's wall clock, so a dead poller reads as stale on the page.
- **CLI-specific fields come from the adapter (#188).** A session's CLI is the fleet's `HARNESS_CLI` from its config (`fleetview.read_config`, default `claude`). Its model is the `--model` flag `fleetview.session_models` finds, else the `model` on the session's `launch` event, which records what `cli_launch`/`cli_lane_settings` chose. The web code never branches on a CLI name.
- **Accessibility and size.** WCAG AA text contrast in both themes. Every interactive element is reachable by keyboard and shows a visible `:focus-visible` ring. No horizontal page scroll at 400 px: the DAG panel scrolls inside itself. Light and dark come from the same tokens through `prefers-color-scheme`, overridable with `data-theme` on `<html>` (`:root:not([data-theme="light"])` inside the media query, plus `:root[data-theme="dark"]`).
- **Test isolation.** Every web test builds its own `HARNESS_HOME` (fleets, snapshots, events, supervise state, ghrate) from `test/fixtures/web/` through `test/web_fixture.py` (Task 1), binds port `0`, and never reads the real `~/.harness`. `test/run.sh` already pins `HARNESS_HOME`, `HARNESS_FLEETS_DIR` and `HARNESS_SNAPSHOTS_DIR` per test, and `web_fixture` re-pins them for a direct `python3 test/test_web*.py`.
- **Never assert through `bash -c`.** `test/helpers.sh`'s `assert_ok`/`assert_no` run their argv directly, so sourced functions and the test's variables are in scope. A `bash -c` child never sourced them and exits 127, and a leading `!` turns that into a permanent pass. Where a here-string is needed, pass `grep -qF -- "$x" <<<"$y"` as argv.
- **Every assertion must be one you have seen go red.** Break the implementation, watch the test fail, restore it, watch it pass. Report that evidence in the PR.
- **Run the suite with** `bash test/run.sh`, or one file with `python3 test/test_<name>.py` / `bash test/test_<name>.sh`. This shell may carry a stale `ENGINE_DIR`/`STATE_DIR`/`HARNESS_HOME` from a live fleet. If tests misbehave, run `env -u ENGINE_DIR -u STATE_DIR -u HARNESS_DIR -u HARNESS_HOME bash test/run.sh`.
- **Commit style:** `feat(web): …` / `test(web): …` / `docs(web): …`, one PR per task, closing that task's child issue.

### The read model

`scripts/web_data.py` is the only module that touches the host. Each adapter is a pure read that returns plain dicts. A missing or garbled source degrades its own field to `None` (rendered "unknown") and never fails the view, which is the same rule `fleetview.py` follows.

| adapter | reads | reuses | task |
|---|---|---|---|
| `registry()` | `$HARNESS_FLEETS_DIR/*.json` | `fleetview.fleets_dir`, `fleetview.load_registry` | 1 |
| `fleet_state(rec)` | `<run_dir>/worker-*.pid`, `priority.pid`, `PAUSED` | `fleetview.fleet_state` (lower-cased; `COMPLETE` from the board tally) | 1 |
| `board(slug)` | `$HARNESS_SNAPSHOTS_DIR/<owner__repo>.json`, `schema_version == 1` | `issuelib._slug_filename`, `issuelib._load_snapshot` | 1 |
| `tally(issues, labels)` | a board's issues | factored out of `fleetview.issue_counts` (162–182), which keeps its `gh` fetch and calls `tally` | 1 |
| `live_sessions(prefix)` | `tmux ls`, `tmux list-panes`, `ps` | `fleetview.host_sessions`, `session_models`, `session_issue`, `session_number` | 3 |
| `pane_activity(line, now, nudge_min, kill_min)` | `$HARNESS_HOME/supervise/panes/<session>` (`<body> <bg> <cpu> <t0> <nudged> <lastnudge>`, written by `sup_watch_pane`, `supervise.sh:95`) | new, in `scripts/supervise_rules.py` beside the rules it mirrors; thresholds from `supervise.conf` | 3 |
| `supervisor(prefix, now)` | `$HARNESS_HOME/supervise.log` tail (`ACT`/`WARN`/`DRY` lines naming the prefix), `supervise/rules/<prefix>.json` `firing` | `fleetview._tail_lines`, `supervise_rules.load` | 3 |
| `stale_locks(rec, boards, live)` | board `agent-working` issues with no live `<prefix>-*-i<N>` session; `<run_dir>/*.pid` whose pid is dead; `<run_dir>/claims/*` whose holder is gone | `fleetview.pid_alive`; the orphan rule of `fleetview.render_fleet` | 3 |
| `rate_state(now)` | `$HARNESS_HOME/ghrate/<key>.rate` / `.hold` (`HARNESS_GH_RATE_DIR` overrides) | `issuelib._read_json`; never `issuelib.rate_limits` or `rate_report`, which probe `gh` | 3 |
| `EventTail` | `events.jsonl` + `rtdd-events.jsonl`, by byte offset (a truncated file restarts at 0) | `stats.events_path`, `stats.rtdd_events_path`, the line parse of `stats.load_events` | 5 |
| `issue_stats(events, repo, n)` / `prd_stats(…)` | the tailed events | `stats.sessions`, `stats.prd_rollup`, `stats.issue_timeline`, `stats._retries` | 6, 7 |
| `signature()` | `stat` of every input above + a hash of `tmux ls` | — | 5 |

---

### Task 1: `harness web` serves the host overview, read-only, with the design tokens (#223)

The tracer bullet. `harness web` starts the server, `/` lists every registered fleet with its state and a link to `/fleet/<prefix>` (a stub page here), every write method is refused, and the design foundation is copied in. Later tasks only add regions to pages this one serves.

**Files:**
- Create: `scripts/web.py` (server, routes, `Model`), `scripts/web_data.py` (`registry`, `fleet_state`, `board`, `tally`, `host_view`), `scripts/web_render.py` (`page`, `overview`, `fleet_stub`), `scripts/web.sh` (the `harness web` entry: no args → `exec python3 scripts/web.py`)
- Create: `web/static/tokens.css`, `web/static/components.css` (copied from design-to-print), `web/static/app.css`, `web/static/app.js` (theme toggle only, for now)
- Modify: `scripts/fleetview.py` (`issue_counts` 162–182 split into the `gh` fetch + `tally(issues, labels)`, behaviour unchanged), `bin/harness` (usage line `web [--install|--uninstall]`, dispatch `web) exec bash "$ENGINE_DIR/scripts/web.sh" "$@";;` beside `supervise` at line 134), `README.md` (`harness web` in the command table, env vars, LAN note)
- Test: `test/test_web.py` (create), `test/web_fixture.py` (create, shared by every later web test)
- Fixtures: `test/fixtures/web/fleets/{hz,dp}.json`, `test/fixtures/web/snapshots/{o__arc,o__quiet}.json` (snapshot schema 1, the shape `issuelib.snapshot` writes at `issuelib.py:880`), `test/fixtures/web/config.hz`, `test/fixtures/web/config.dp`

**Interfaces:**
- Consumes: `fleetview.fleets_dir/load_registry/read_config/fleet_state/fleet_labels` (`fleetview.py:44-262`), `issuelib._slug_filename/_load_snapshot/SNAPSHOT_SCHEMA_VERSION` (`issuelib.py:8, 294-308`), the registry record `{prefix, project, run_dir, slugs, started_at}` (`lib.sh:1427`, `fleet_register`)
- Produces: `web.bind_addr(env) -> (host, port)`; `web.Model()` with `.host(now=None) -> dict`, `.fleet(prefix, now=None) -> dict | None`; `web.make_server(bind, port, model) -> ThreadingHTTPServer`; `web.main(argv) -> int`; routes `GET /`, `/fleet/<prefix>`, `/api/host`, `/api/fleet/<prefix>`, `/static/<name>` (allow-list built from `os.listdir(web/static)` at start, so there is no path traversal); `web_data.host_view(now) -> {"asof": int|None, "fleets": [{"prefix", "root", "state", "repos", "workers", "pool", "asof"}]}`; `web_data.tally(issues, labels) -> {"open", "unblocked", "working": [n], "pending"}`; `web_render.page(title, body, asof) -> str`; `test/web_fixture.py`: `serving(tmux_ls="", now=None, tick=None, events="events.jsonl") -> (base_url, host)` context manager, `get(url) -> (code, body)`, `get_json(url)`, `headers(url)`, `request(method, url) -> (code, body)`, `load(name)` (a `scripts/<name>.py` module), `run_tests(globals()) -> rc`, `host.gh_called` (marker path), `host.snapshots`, `ROOT`, `FIX`, `NOW`

- [ ] **Step 1: Write the failing test**

Create `test/test_web.py`:

```python
#!/usr/bin/env python3
"""test_web.py — #223: `harness web` serves the host overview from local state only, read-only.

web_fixture builds a HARNESS_HOME from test/fixtures/web/ (two registered fleets: `hz` running, with
a live worker pid, and `dp` stopped), puts a `gh` that records being called first on PATH, and serves
web.Model on 127.0.0.1:0 in a thread."""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import web_fixture as wf
web = wf.load("web")


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
                code, _ = wf.request(method, base + path)
                assert code == 405, f"{method} {path} -> {code}"
        assert not os.path.exists(host.gh_called), "gh was invoked"


def test_static_serves_only_the_allow_list():
    with wf.serving() as (base, host):
        assert wf.get(base + "/static/tokens.css")[0] == 200
        for bad in ("/static/../web.py", "/static/%2e%2e/web.py", "/static/nope.css"):
            assert wf.get(base + bad)[0] == 404, bad


def test_bind_and_port_come_from_env():
    assert web.bind_addr({}) == ("127.0.0.1", 4637)
    assert web.bind_addr({"HARNESS_WEB_BIND": "0.0.0.0", "HARNESS_WEB_PORT": "5000"}) == ("0.0.0.0", 5000)


def test_tokens_copied_with_source_commit_and_both_themes():
    css = open(os.path.join(wf.ROOT, "web", "static", "tokens.css"), encoding="utf-8").read()
    assert re.search(r"design-to-print@[0-9a-f]{40}", css.splitlines()[0]), "no source-commit header"
    assert "prefers-color-scheme: dark" in css and ':root[data-theme="dark"]' in css


def test_every_response_forbids_external_loads():
    with wf.serving() as (base, host):
        hdrs = wf.headers(base + "/")
        assert hdrs.get("Content-Security-Policy", "").startswith("default-src 'self'"), hdrs


if __name__ == "__main__":
    sys.exit(wf.run_tests(globals()))
```

`test/web_fixture.py` loads `scripts/<name>.py` by path with `importlib.util` and a normalized filename, exactly as `test/test_fleetview.py:10-11` does, so coverage credits the right file. It copies `test/fixtures/web/` into a temp `HARNESS_HOME`, rewrites each registry record's `project`/`run_dir` to temp project dirs holding the fixture `config`, and writes `worker-1.pid` = `os.getpid()` for `hz` (alive) and nothing for `dp`. It prepends a bin dir whose `gh` is `#!/bin/sh\ntouch "$WEB_GH_CALLED"; exit 1` and whose `tmux` prints `$WEB_TMUX_LS` (default empty), then serves `web.make_server("127.0.0.1", 0, web.Model())` on a daemon thread. `run_tests` is the same loop as `test/test_cli_plan_docs.py`'s `__main__`.

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/test_web.py`
Expected: FAIL — `web_fixture.load("web")` cannot find `scripts/web.py`.

- [ ] **Step 3: Copy the design foundation, read-only**

```bash
git clone --depth 1 https://github.com/VocanicZ/design-to-print ~/design-to-print
git -C ~/design-to-print rev-parse HEAD     # the sha for the headers
```

Read `docs/design/DESIGN.md` (principles: answer first, colour is meaning, no decoration, native elements), `app/styles/tokens.css` and `app/styles/components.css`. Copy the colour, type, space, radius and focus tokens into `web/static/tokens.css`, and the button, table, pill, card and drawer rules the views need into `web/static/components.css`. Each file starts with the source header from the Global Constraints. Add the state tokens the DAG needs (`--s-done`, `--s-running`, `--s-ready`, `--s-waiting`, `--s-blocked`, `--s-review`, `--s-gate`) built from design-to-print's palette, not from `status-page.py`'s hex values. Run `git -C ~/design-to-print status --porcelain` (it must be empty), then `rm -rf ~/design-to-print`.

- [ ] **Step 4: Server, adapters and overview**

`web.bind_addr` reads the two env vars. The handler defines `do_GET` and `do_HEAD`, and maps `do_POST`, `do_PUT`, `do_PATCH`, `do_DELETE` and `do_OPTIONS` to one `_reject` that sends `405` and `Allow: GET, HEAD`. Every response sets `Content-Security-Policy: default-src 'self'; style-src 'self'; script-src 'self'`, `X-Content-Type-Options: nosniff` and `Cache-Control: no-store` (static: `max-age=60`). `web_data.host_view` builds one fleet entry per registry record. Its state is `fleet_state` lower-cased, turned to `complete` when every slug's board `tally` has no `pending`, which is `fleetview.render_fleet`'s rule (`fleetview.py:279-281`) applied to the snapshot instead of to `gh`. A fleet whose project dir is gone is `missing`. `web_render.overview` emits one `<article data-fleet data-state>` per fleet, with its name linking to `/fleet/<prefix>`, inside `<section data-region="fleets">`. `web.main` prints `harness web: serving http://<bind>:<port>/` and runs `serve_forever`.

- [ ] **Step 5: Run the tests**

Run: `python3 test/test_web.py && python3 test/test_fleetview.py`
Expected: all pass; `test_fleetview.py` is unchanged and still green after the `tally` split.

- [ ] **Step 6: Docs and a manual look**

Add `harness web` to the README command table and a short **Dashboard** section with `HARNESS_WEB_BIND`/`HARNESS_WEB_PORT`, the `127.0.0.1:4637` default, the claude host's `HARNESS_WEB_BIND=0.0.0.0`, and the read-only/no-Internet note. Run `harness web` against the real host and open `/` in light and dark. Attach both screenshots to the PR.

- [ ] **Step 7: Full suite and commit**

Run: `bash test/run.sh`
Expected: no new failures against the pre-change baseline.

```bash
git add scripts/web.py scripts/web_data.py scripts/web_render.py scripts/web.sh scripts/fleetview.py \
  web/static bin/harness README.md test/test_web.py test/web_fixture.py test/fixtures/web
git commit -m "feat(web): harness web serves the read-only host overview on :4637 (closes #223)"
```

### Task 2: Fleet page with the layered PRD → issue DAG, golden-tested against `status-page.py` (#224)

`/fleet/<prefix>` renders one section per repo (unit) the fleet serves. Each section holds the PRD DAG, laid out exactly as `status-page.py` lays it out. Under each PRD are its children, layered by their own `## Blocked by` edges among siblings, and after the PRDs comes a list of unparented issues. The golden test proves the port by running `status-page.py`'s own logic on the same board.

**Files:**
- Create: `scripts/web_dag.py`, `test/test_web_dag.py`, `test/fixtures/web/arc-golden.json`
- Modify: `skill/harness-arc/scripts/status-page.py` (extract `arc_model(prds, allis)` from `main` with no output change), `scripts/web_data.py` (`fleet_view`), `scripts/web_render.py` (`fleet`, `dag_svg`), `scripts/web.py` (route `/fleet/<prefix>` to the real page), `web/static/app.css`
- Fixtures: `test/fixtures/web/snapshots/o__arc.json` gains the arc board below

**Interfaces:**
- Consumes: `status-page.py` `blocked_by` (35), `parent_of` (49), `layers` (56), and the attribution and `state_of` logic inside `main` (124–158); `web_data.board`, `tally` (Task 1); `fleetview.session_number` for live sessions
- Produces: `web_dag.blocked_by_last(body) -> [int]`; `web_dag.parent_of(body) -> int | None`; `web_dag.layers(nodes, deps) -> {n: int}`; `web_dag.unit_graph(board, labels, live=frozenset()) -> {"slug", "asof", "prds": [{"number", "title", "url", "state", "layer", "deps", "kids": {"open", "closed"}, "children": [node]}], "edges": [[from, to]], "unparented": [node], "issues": {n: node}}`, where a node is `{"number", "title", "url", "state", "labels", "deps", "layer", "parent"}` and child `state` ∈ `closed | agent-blocked | in-progress | in-review | blocked | open`, checked in that order; `web_dag.arc_projection(graph) -> {"deps", "kids", "layers", "states"}` (the golden shape); `status-page.py` `arc_model(prds, allis) -> {"deps", "kids", "layers", "states"}`; `web_data.fleet_view(prefix, now) -> {"prefix", "asof", "units": [unit_graph]} | None`

The fixture board `o/arc` (one per test file in `test/fixtures/web/`, reused by Tasks 3–9): PRDs #1 *Core* (closed; its prose mentions `## Blocked by` before the real `None` section), #2 *Left* (blocked by #1), #3 *Right* (two `## Blocked by` sections, `#99` then `#1`, so only the last one counts), #4 *Join* (blocked by #2 and #3). Children of #2: #10 closed, #11 `agent-working` with live session `hz-arc-i11`, and #12 blocked by #11. Children of #3: #13 `ready-for-agent` with an `issue/13` branch and no session (in review), #14 `agent-blocked`, and #15 ready. Children of #4: #41 `agent-working` with a live session, and #42 `agent-working` with none (a stale lock, Task 3). Unparented #20. Wayfinder map #30, open ticket #31, resolved ticket #32. Operator issue #40 `[ops] Deploy …` with no labels.

- [ ] **Step 1: Write the failing test**

Create `test/test_web_dag.py`:

```python
#!/usr/bin/env python3
"""test_web_dag.py — #224: the fleet page's DAG is status-page.py's DAG. On the recorded o/arc board,
web_dag's nodes, edges, layers, parent attribution and PRD states equal what status-page.py's own
logic derives (arc_model), and that answer is frozen in arc-golden.json so it survives status-page.py
being removed (#230)."""
import importlib.util, json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import web_fixture as wf
dag = wf.load("web_dag")
BOARD = json.load(open(os.path.join(wf.FIX, "snapshots", "o__arc.json")))
GOLDEN = os.path.join(wf.FIX, "arc-golden.json")
LABELS = {"prd": "prd", "working": "agent-working", "blocked": "agent-blocked", "ready": "ready-for-agent"}
SP = os.path.join(wf.ROOT, "skill", "harness-arc", "scripts", "status-page.py")


def status_page():
    spec = importlib.util.spec_from_file_location("status_page", SP)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m


def labelled(i, name):
    return any(l["name"] == name for l in i["labels"])


def test_matches_status_page_exactly():
    got = dag.arc_projection(dag.unit_graph(BOARD, LABELS))
    golden = json.load(open(GOLDEN))
    assert got == golden, json.dumps({"got": got, "golden": golden}, indent=1)
    if os.path.exists(SP):    # until #230 removes it, the golden must still be status-page.py's answer
        issues = BOARD["issues"]
        prds = sorted((i for i in issues if labelled(i, "prd")), key=lambda i: i["number"])
        want = json.loads(json.dumps(status_page().arc_model(prds, issues)))   # int keys -> str, as on disk
        assert golden == want, "arc-golden.json drifted from status-page.py"


def test_last_blocked_by_section_wins():
    body = "## Blocked by\n#99\n\n## Notes\nx\n\n## Blocked by\n#1, #2\n"
    assert dag.blocked_by_last(body) == [1, 2]
    assert dag.blocked_by_last("Mentions ## Blocked by\n\n## Blocked by\nNone — #5 merged\n") == []


def test_parallel_prds_share_a_layer_and_join_after_both():
    lay = {p["number"]: p["layer"] for p in dag.unit_graph(BOARD, LABELS)["prds"]}
    assert lay[2] == lay[3] == lay[1] + 1 and lay[4] == lay[2] + 1, lay


def test_child_states_and_unparented():
    g = dag.unit_graph(BOARD, LABELS, live=frozenset({11, 41}))
    st = {n: g["issues"][n]["state"] for n in (10, 11, 12, 13, 14, 15)}
    assert st == {10: "closed", 11: "in-progress", 12: "blocked", 13: "in-review",
                  14: "agent-blocked", 15: "open"}, st
    assert [i["number"] for i in g["unparented"]] == [20, 40]


def test_fleet_page_renders_the_dag_and_404s_unknown_prefixes():
    with wf.serving(tmux_ls="hz-arc-i11\t1800000000\nhz-arc-i41\t1800000000\n") as (base, host):
        code, body = wf.get(base + "/fleet/hz")
        assert code == 200, code
        for n, layer in ((1, 0), (2, 1), (3, 1), (4, 2)):
            assert re.search(rf'data-prd="{n}"[^>]*data-layer="{layer}"', body), (n, layer)
        assert re.search(r'data-issue="11"[^>]*data-state="in-progress"', body)
        assert 'data-region="unparented-o/arc"' in body and 'data-issue="20"' in body
        assert re.search(r'<a [^>]*href="\?issue=13"[^>]*data-issue="13"', body), "DAG nodes are not focusable links"
        assert wf.get(base + "/fleet/nope")[0] == 404
        assert not os.path.exists(host.gh_called), "gh was invoked while rendering the fleet page"


if __name__ == "__main__":
    sys.exit(wf.run_tests(globals()))
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/test_web_dag.py`
Expected: FAIL — `web_fixture.load("web_dag")` cannot find `scripts/web_dag.py`, and `status-page.py` has no `arc_model`.

- [ ] **Step 3: Extract `arc_model` from `status-page.py` without changing its output**

Move the `deps` / `closed` / `kids` / `working` / `state_of` block of `main` (lines 136–158) into `arc_model(prds, allis)`, returning `{"deps": {n: [...]}, "kids": {n: {"open", "closed"}}, "layers": layers(set(nums), deps), "states": {n: state_of(p)}}`. `main` calls it and is otherwise unchanged.

Run: `python3 test/test_harness_arc_status_page.py`
Expected: still green. That test runs the real script end to end, so it is the guard that the extraction changed nothing.

- [ ] **Step 4: Generate the golden once, from `status-page.py`**

```bash
python3 - <<'PY'
import importlib.util, json
s = importlib.util.spec_from_file_location("sp", "skill/harness-arc/scripts/status-page.py")
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
b = json.load(open("test/fixtures/web/snapshots/o__arc.json"))
prds = sorted((i for i in b["issues"] if any(l["name"] == "prd" for l in i["labels"])), key=lambda i: i["number"])
json.dump(m.arc_model(prds, b["issues"]), open("test/fixtures/web/arc-golden.json", "w"), indent=1, sort_keys=True)
PY
```

Read the file and check every value by hand against the fixture description above before committing it. The golden is the reference, so a wrong golden makes the test prove a wrong port.

- [ ] **Step 5: `web_dag` and the fleet page**

`blocked_by_last`, `parent_of` and `layers` are ports of `status-page.py`'s functions of the same names. Copy the regexes exactly. `unit_graph` follows `arc_model`'s PRD rules. It then gives each PRD's children their own `layers` over sibling-only edges, gives each child a state in the order listed in Interfaces (in review = open, number in the snapshot's `issue_branches`, no live session), and builds `url` as `https://github.com/<slug>/issues/<n>`, because snapshots carry no URL. Wayfinder-labelled issues are neither children nor unparented: Task 7 shows them. `web_render.dag_svg` keeps `status-page.py`'s geometry (`CW, RH, BW, BH = 250, 96, 186, 54`) and its CSS-variable colours. Each node is an `<a href="?issue=N" data-issue data-state tabindex="0">` with an accessible name, so focus is visible and Task 6 can open the drawer from it. The SVG sits in a `.dag` panel with `overflow-x: auto`, so 400 px scrolls the panel and not the page. Each unit renders as `<section data-region="dag-<slug>">` followed by `<section data-region="unparented-<slug>">`. `fleet_view` returns `None` for an unknown prefix, and the route turns that into `404`.

- [ ] **Step 6: Run the tests**

Run: `python3 test/test_web_dag.py && python3 test/test_web.py && python3 test/test_harness_arc_status_page.py`
Expected: all pass. Break `blocked_by_last` to parse the first section and watch `test_matches_status_page_exactly` and `test_last_blocked_by_section_wins` fail. Restore it.

- [ ] **Step 7: Full suite and commit**

Run: `bash test/run.sh`
Expected: no new failures.

```bash
git add scripts/web_dag.py scripts/web_data.py scripts/web_render.py scripts/web.py web/static \
  skill/harness-arc/scripts/status-page.py test/test_web_dag.py test/fixtures/web
git commit -m "feat(web): fleet page with the layered PRD → issue DAG, golden-tested against status-page.py (closes #224)"
```

### Task 3: Host overview health — live sessions, stale locks, rate-limit budget, supervisor actions (#225)

Makes `/` answer "is anything stuck, and what needs me?" within ten seconds. Each fleet card leads with one verdict, `healthy` or `needs attention (n)`, and the reasons come after it. The data is the supervisor's own state, read rather than recomputed, so the page and `harness supervise` never disagree.

**Files:**
- Modify: `scripts/supervise_rules.py` (add `pane_activity`), `scripts/web_data.py` (`live_sessions`, `supervisor`, `stale_locks`, `rate_state`, `attention`; `host_view` gains them), `scripts/web_render.py` (fleet card health), `web/static/app.css`
- Test: `test/test_web_health.py` (create)
- Fixtures: `test/fixtures/web/supervise/panes/hz-arc-i41` (frozen: `t0` = `NOW - KILL_MIN*60 - 30`, nudged), `…/hz-arc-i11` (active), `test/fixtures/web/supervise/rules/hz.json` (one firing alarm), `test/fixtures/web/supervise.log` (`ACT` lines for `hz`, none for `dp`), `test/fixtures/web/ghrate/gh-auth.rate`, `…/gh-auth.hold`, `test/fixtures/web/supervise.conf` (`NUDGE_MIN=45`, `KILL_MIN=120`), a `dead.pid` for `hz` (written by `web_fixture` from a reaped child's pid, as `test_fleetview.py:dead_pid` does)

**Interfaces:**
- Consumes: the pane-file format `sup_watch_pane` writes (`supervise.sh:95-125`); `SUP_LOG` / `SUP_STATE` paths (`supervise.sh:50-51`, defaults `$HARNESS_HOME/supervise.log`, `$HARNESS_HOME/supervise`, overridden by `HARNESS_SUPERVISE_LOG` / `HARNESS_SUPERVISE_STATE`); `supervise_rules.load` (202); `issuelib._rate_file`/`_read_json` (108–118); `fleetview.host_sessions/session_models/session_issue/session_number/pid_alive`
- Produces: `supervise_rules.pane_activity(line, now, nudge_min, kill_min) -> {"state": "active" | "quiet" | "nudged" | "frozen", "quiet_s": int}`; `web_data.live_sessions(prefix, now) -> [{"name", "issue", "kind", "age_s", "model", "cli", "activity"}]`; `web_data.stale_locks(rec, boards, live) -> [{"kind": "label" | "pidfile" | "claim", "what"}]`; `web_data.rate_state(now) -> [{"key", "resources": {res: {"limit", "remaining", "reset"}}, "checked_at", "hold_until"}]`; `web_data.supervisor(prefix, now, n=8) -> {"actions": [str], "alarms": [{"key", "message"}]}`; `web_data.attention(fleet) -> [{"kind", "what"}]`, kind ∈ `frozen | stale-lock | stale-pidfile | stale-claim | alarm | dead`; `host_view` fleets gain `sessions`, `stale_locks`, `supervisor`, `attention`, and the view gains `rate` and a host-level `attention` (a rate-limit hold is host-wide, since every fleet shares the token, so it never marks one fleet unhealthy)

- [ ] **Step 1: Write the failing test**

Create `test/test_web_health.py`:

```python
#!/usr/bin/env python3
"""test_web_health.py — #225: the overview surfaces what needs a human. On the fixture host, `hz` has
a frozen session (#41), a stale agent-working lock (#42), a dead pid file and a firing arc alarm, and
the token is held on a rate limit; `dp` has nothing wrong and must read as healthy."""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import web_fixture as wf
rules = wf.load("supervise_rules")
NOW = wf.NOW
TMUX = "hz-arc-i11\t%d\nhz-arc-i41\t%d\n" % (NOW - 600, NOW - 9000)


def test_pane_activity_follows_the_supervisor_thresholds():
    act = lambda t0, nudged: rules.pane_activity(f"h 0 0 {t0} {nudged} 0", NOW, 45, 120)["state"]
    assert act(NOW - 60, 0) == "active"
    assert act(NOW - 46 * 60, 0) == "quiet"
    assert act(NOW - 50 * 60, 1) == "nudged"
    assert act(NOW - 121 * 60, 1) == "frozen"
    assert rules.pane_activity("garbage", NOW, 45, 120)["state"] == "active"   # unreadable: never alarm


def test_overview_flags_hz_and_calls_dp_healthy():
    with wf.serving(tmux_ls=TMUX, now=NOW) as (base, host):
        h = wf.get_json(base + "/api/host")
        f = {x["prefix"]: x for x in h["fleets"]}
        kinds = sorted((a["kind"], str(a["what"])) for a in f["hz"]["attention"])
        assert ("frozen", "hz-arc-i41") in kinds, kinds
        assert ("stale-lock", "#42") in kinds, kinds
        assert any(k == "stale-pidfile" for k, _ in kinds), kinds
        assert any(k == "alarm" for k, _ in kinds), kinds
        assert f["dp"]["attention"] == [], f["dp"]["attention"]
        s = {x["name"]: x for x in f["hz"]["sessions"]}
        assert s["hz-arc-i11"]["issue"] == "#11" and s["hz-arc-i11"]["activity"] == "active"
        assert s["hz-arc-i11"]["cli"] == "claude" and s["hz-arc-i11"]["model"] == "claude-opus-5-5"
        assert h["rate"][0]["hold_until"] > NOW and h["rate"][0]["resources"]["core"]["remaining"] == 0
        assert [a["kind"] for a in h["attention"]] == ["rate-hold"], h["attention"]
        assert f["hz"]["supervisor"]["actions"], "no supervisor actions for hz"
        _, body = wf.get(base + "/")
        assert re.search(r'data-fleet="hz"[^>]*data-health="attention"', body)
        assert re.search(r'data-fleet="dp"[^>]*data-health="healthy"', body)
        assert not os.path.exists(host.gh_called), "gh was invoked"


if __name__ == "__main__":
    sys.exit(wf.run_tests(globals()))
```

`web_fixture.serving(now=…)` pins `web_data`'s clock (`web_data.NOW_FN`) so ages and thresholds are deterministic. The model for `hz-arc-i11` comes from the fixture event log's `launch` event, because the stub `tmux list-panes` reports no panes and `session_models` therefore finds nothing.

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/test_web_health.py`
Expected: FAIL — `module 'supervise_rules' has no attribute 'pane_activity'`.

- [ ] **Step 3: `pane_activity` beside the rules it mirrors**

Parse `<body> <bg> <cpu> <t0> <nudged> <lastnudge>`. `quiet_s = now - t0`. The state is `frozen` at `quiet_s ≥ kill_min*60`, else `nudged` if the flag is set, else `quiet` at `≥ nudge_min*60`, else `active`. A line that does not parse is `active`, because the page never raises an alarm the supervisor would not. Add a comment at `sup_watch_pane` (`supervise.sh:95`) naming `pane_activity` as the reader of that format, so a format change updates both. Read `NUDGE_MIN`/`KILL_MIN` from `$HARNESS_SUPERVISE_CONF` (default `$HARNESS_HOME/supervise.conf`) with the regex `^(NUDGE_MIN|KILL_MIN)=(\d+)$`, which never sources it, falling back to `supervise.sh`'s defaults of 45 and 120.

- [ ] **Step 4: The adapters and the card**

`live_sessions` keeps sessions under `<prefix>-`, names the issue with `session_issue`, and takes the kind from the name (`-i` impl, `-p` orchestrator, `-bug-` bug). `stale_locks` implements three rules. **label**: an open board issue labelled with the fleet's working label whose number has no live session, the same orphan rule as `fleetview.render_fleet` but from the board. **pidfile**: a `*.pid` in `run_dir` whose pid is dead, `doctor.sh`'s rule. **claim**: a file in `run_dir/claims/` whose recorded session is not live. `rate_state` lists every `*.rate` in the ghrate dir with its `.hold`. It never probes. `supervisor` takes the last `n` log lines containing `ACT`, `WARN` or `DRY` that name the prefix, plus the `firing` keys and `messages` of `supervise/rules/<prefix>.json`. The card's first line is the verdict (`data-health="healthy"|"attention"`), using colour only for meaning: the attention token for "needs attention", neutral otherwise. The details follow in this order: attention items, sessions table (issue, kind, CLI, model, age, activity), rate budget, last supervisor actions.

- [ ] **Step 5: Run the tests**

Run: `python3 test/test_web_health.py && python3 test/test_web.py && python3 test/test_supervise_rules.py && bash test/test_supervise.sh`
Expected: all pass.

- [ ] **Step 6: Full suite and commit**

Run: `bash test/run.sh`
Expected: no new failures.

```bash
git add scripts/supervise_rules.py scripts/supervise.sh scripts/web_data.py scripts/web_render.py web/static \
  test/test_web_health.py test/web_fixture.py test/fixtures/web
git commit -m "feat(web): overview health — live sessions, stale locks, rate-limit budget, supervisor actions (closes #225)"
```

### Task 4: `harness web --install` systemd user unit, redeployed by `harness update` (#226)

Copies `harness supervise --install` (#180) function for function, so the two units behave the same and an operator learns one pattern.

**Files:**
- Modify: `scripts/web.sh` (`web_install`, `web_uninstall`, `web_installed`; `--install` / `--uninstall` flags; a sourced file defines functions only, like `supervise.sh:419`), `update.sh` (redeploy block after the supervisor's at lines 28–32), `scripts/uninstall.sh` (remove this engine's web unit, beside line 153), `README.md` (install section)
- Test: `test/test_web_install.sh` (create)

**Interfaces:**
- Consumes: the unit shape and seams of `sup_install`/`sup_installed` (`supervise.sh:376-417`), `HARNESS_WEB_BIND`/`HARNESS_WEB_PORT`
- Produces: `web_install`, `web_uninstall`, `web_installed` (true only when the unit's `ExecStart` is **this** engine's `harness web`); unit `harness-web.service` in `HARNESS_WEB_UNIT_DIR` (default `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user`); test seams `HARNESS_WEB_SYSTEMCTL`, `HARNESS_WEB_LOGINCTL`, `HARNESS_WEB_HARNESS`

- [ ] **Step 1: Write the failing test**

Create `test/test_web_install.sh`:

```bash
#!/usr/bin/env bash
# test_web_install.sh — #226: `harness web --install` writes and enables a systemd user unit for the
# dashboard; re-running is idempotent; `harness update` redeploys an installed unit of THIS engine and
# leaves every other host alone; uninstall removes it. systemctl/loginctl are stubs that log argv.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf '#!/bin/sh\necho "$@" >> %s/systemctl.calls\n' "$T" >"$T/systemctl"; chmod +x "$T/systemctl"
printf '#!/bin/sh\necho "$@" >> %s/loginctl.calls\n' "$T" >"$T/loginctl"; chmod +x "$T/loginctl"
export HARNESS_WEB_UNIT_DIR="$T/unit" HARNESS_WEB_SYSTEMCTL="$T/systemctl" HARNESS_WEB_LOGINCTL="$T/loginctl"
export HARNESS_WEB_HARNESS=/eng/bin/harness HARNESS_WEB_BIND=0.0.0.0 HARNESS_WEB_PORT=4637
source "$HERE/../scripts/web.sh"
F="$T/unit/harness-web.service"
has(){ grep -qF -- "$1" "$2"; }
line(){ grep -qx -- "$1" "$2"; }

web_install >/dev/null
assert_ok "--install writes the unit"                 test -f "$F"
assert_ok "unit runs this engine's harness web"       line "ExecStart=/eng/bin/harness web" "$F"
assert_ok "unit restarts always"                      line "Restart=always" "$F"
assert_ok "unit starts with the user manager"         line "WantedBy=default.target" "$F"
assert_ok "unit carries the bind"                     line "Environment=HARNESS_WEB_BIND=0.0.0.0" "$F"
assert_ok "unit carries the port"                     line "Environment=HARNESS_WEB_PORT=4637" "$F"
assert_ok "systemd reloaded"                          has "--user daemon-reload" "$T/systemctl.calls"
assert_ok "unit enabled"                              has "--user enable harness-web.service" "$T/systemctl.calls"
assert_ok "unit (re)started"                          has "--user restart harness-web.service" "$T/systemctl.calls"
assert_ok "linger enabled (survives logout/reboot)"   has "enable-linger" "$T/loginctl.calls"
assert_ok "installed from this engine"                web_installed
before="$(cat "$F")"; web_install >/dev/null
assert_eq "$(cat "$F")" "$before" "re-install is idempotent"
assert_eq "$(ls "$T/unit" | wc -l | tr -d ' ')" 1 "re-install writes one unit"
other(){ local HARNESS_WEB_HARNESS=/other/bin/harness; web_installed; }
assert_no "another engine's checkout does not own the unit" other

echo "=== harness update redeploys only this engine's installed unit ==="
R="$HERE/.."; REMOTE="$T/eng.git"; git init -q --bare -b main "$REMOTE"
EW="$T/ew"; mkdir -p "$EW/scripts" "$EW/bin"
cp "$R/update.sh" "$R/install.sh" "$EW/"; cp "$R/scripts/web.sh" "$R/scripts/supervise.sh" "$EW/scripts/"; cp "$R/bin/harness" "$EW/bin/"
git -C "$EW" init -q -b main; git -C "$EW" add -A
git -C "$EW" -c user.name=t -c user.email=t@t commit -qm init; git -C "$EW" push -q "$REMOTE" main
ENG="$T/engine"; git clone -q "$REMOTE" "$ENG"
U2="$T/unit2"; mkdir -p "$U2"
upd(){ HARNESS_SKIP_RTDD=1 HARNESS_WEB_UNIT_DIR="$U2" HARNESS_WEB_HARNESS= HARNESS_SUPERVISE_UNIT_DIR="$T/none" \
  ENGINE_DIR="$ENG" bash "$R/update.sh" >/dev/null 2>&1; }
printf '[Service]\nExecStart=%s/bin/harness web\nEnvironment=PATH=stale\n' "$ENG" >"$U2/harness-web.service"
: >"$T/systemctl.calls"; upd
assert_no "update rewrites an installed unit"         grep -q "PATH=stale" "$U2/harness-web.service"
assert_ok "update restarts it on the new engine"      has "restart harness-web.service" "$T/systemctl.calls"
printf '[Service]\nExecStart=/other/bin/harness web\nEnvironment=PATH=stale\n' >"$U2/harness-web.service"
: >"$T/systemctl.calls"; upd
assert_ok "update leaves another engine's unit alone" grep -q "PATH=stale" "$U2/harness-web.service"
rm -f "$U2/harness-web.service"; upd
assert_no "update never installs a unit that was not installed" test -f "$U2/harness-web.service"

web_uninstall >/dev/null
assert_no "--uninstall removes the unit"              test -f "$F"
assert_ok "--uninstall disables it"                   has "disable --now harness-web.service" "$T/systemctl.calls"
finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/test_web_install.sh`
Expected: FAIL — `web_install: command not found`.

- [ ] **Step 3: The unit functions**

Mirror `sup_install`: the same `PATH` builder (`sup_unit_path`'s list minus the agent CLIs, since the server needs only `tmux`, `ps` and `python3`), `Restart=always`, `RestartSec=5`, `Environment=HARNESS_HOME=…`, the bind and port, `WantedBy=default.target`, `daemon-reload` + `enable` + `restart`, and `loginctl enable-linger` with a warning on failure. The default `KillMode` is fine here: the server starts no long-lived children. `HARNESS_WEB_HARNESS` defaults to `$ENGINE_DIR/bin/harness`. An empty value means that default too, so the update test can point it at the cloned engine.

- [ ] **Step 4: Redeploy on update, remove on uninstall**

In `update.sh`, after the supervisor block, add `if [[ -f "$ENGINE_DIR/scripts/web.sh" ]] && ( source "$ENGINE_DIR/scripts/web.sh"; web_installed ); then bash "$ENGINE_DIR/scripts/web.sh" --install || echo "WARNING: redeploying harness web failed" >&2; fi`. Add the same guard to `uninstall.sh` with `--uninstall`. The README's install section shows `harness web --install`, and `HARNESS_WEB_BIND=0.0.0.0 harness web --install` for the claude host.

- [ ] **Step 5: Run the tests**

Run: `bash test/test_web_install.sh && bash test/test_supervise.sh && bash test/test_update.sh && bash test/test_uninstall.sh`
Expected: all pass.

- [ ] **Step 6: Prove it on the host, then commit**

Run `harness web --install` on the claude host with `HARNESS_WEB_BIND=0.0.0.0`, then `systemctl --user restart harness-web.service` and `curl -fsS http://127.0.0.1:4637/ >/dev/null`. Paste the `systemctl --user status harness-web.service` output into the PR.

Run: `bash test/run.sh`
Expected: no new failures.

```bash
git add scripts/web.sh update.sh scripts/uninstall.sh README.md test/test_web_install.sh
git commit -m "feat(web): harness web --install systemd user unit, redeployed by harness update (closes #226)"
```

### Task 5: Live updates over SSE — an issue opened, closed, labelled or claimed appears without a reload (#227)

The collector turns "a snapshot file changed" into "these regions changed" and pushes them. The headless-browser test is the acceptance: it rewrites the fixture board under a page that is open and watches the DOM change with no navigation.

**Files:**
- Modify: `scripts/web.py` (collector thread, `Model.version/wait`, route `GET /events`), `scripts/web_data.py` (`signature`, `EventTail`), `scripts/web_render.py` (`regions(view) -> {id: html}`), `web/static/app.js` (EventSource, region swap, as-of update)
- Create: `test/test_web_live.py`, `test/web_cdp.mjs` (≈80 lines: launch the browser headless on a free debugging port, open a page, evaluate expressions, wait for a predicate)

**Interfaces:**
- Consumes: every adapter's inputs (The read model); `web_render` regions from Tasks 1–3
- Produces: `GET /events?view=<path>` (`text/event-stream`; first frame `retry: 3000`; on change `event: patch` with `data: {"asof": <epoch>, "regions": {"<id>": "<html>"}}`; a `: ping` comment every 15 s; at most `HARNESS_WEB_MAX_STREAMS` (default 32) streams, the next answered `503`); `Model.version(view) -> str` (hash of the view's rendered regions); `Model.wait(view, version, timeout) -> str`; `web_data.signature() -> tuple`; `HARNESS_WEB_TICK` (seconds, default 2); in the page `<html data-view="/fleet/hz">` and `<time data-asof>`

- [ ] **Step 1: Write the failing test**

Create `test/test_web_live.py`:

```python
#!/usr/bin/env python3
"""test_web_live.py — #227: open pages update in place. With the fleet page open in headless Chrome,
rewriting the recorded o/arc board — close #15, open #50 under PRD #3, label #13 agent-blocked, claim
#12 (agent-working + a live session) — reaches the DOM through the SSE stream, with no navigation, and
the as-of stamp advances. A dropped stream reconnects. Without a browser or Node it still checks the
stream itself, and says it skipped the DOM half."""
import json, os, re, shutil, sys, time
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
            by = {i["number"]: i for i in json.load(open(os.path.join(host.snapshots, "o__arc.json")))["issues"]}
            by[14]["state"] = "CLOSED"; host.write_board("o__arc", list(by.values()), wf.NOW + 120)
            page.wait("document.querySelector('[data-issue=\"14\"]').dataset.state === 'closed'", 10)


if __name__ == "__main__":
    sys.exit(wf.run_tests(globals()))
```

`web_fixture` gains `sse(url)` (an `http.client` reader of `event:`/`data:`/`retry:` frames), `cdp(browser, url)` (runs `node test/web_cdp.mjs` and talks to it line by line on stdin/stdout), and `host.set_tmux`, `host.write_board` and `host.drop_streams` (calls `Model.close_streams()`, a test-only hook that shuts every open stream the way a server restart would).

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/test_web_live.py`
Expected: FAIL — `GET /events` answers `404`.

- [ ] **Step 3: Collector and stream**

The collector thread wakes every `HARNESS_WEB_TICK` and compares `web_data.signature()` with the last one. It costs one `stat` per input file plus one `tmux ls`. When the signature changes, the collector rebuilds the host view and each fleet view, re-renders their regions, stores a version hash per view, and `notify_all`s a `threading.Condition`. `/events` sends `retry: 3000`, then loops on `Model.wait(view, version, 15)`. On a new version it sends only the regions whose HTML differs from what this stream last sent. On a timeout it sends `: ping`. A client write error ends the loop. The server is a `ThreadingHTTPServer` with `daemon_threads = True`, so a hung client cannot block shutdown.

- [ ] **Step 4: Client**

`app.js` opens `new EventSource('/events?view=' + encodeURIComponent(document.documentElement.dataset.view))`. On `patch` it replaces the `innerHTML` of each `[data-region="<id>"]`. If focus was inside a replaced region, it puts focus back on the element with the same `data-issue`, or else the region. An open drawer is never inside a region, so it stays open. It then updates `time[data-asof]` (`datetime` and its relative label). `EventSource` reconnects by itself after `retry`. The page also shows a quiet "reconnecting…" status in the header while `readyState` is `CONNECTING`, never a modal.

- [ ] **Step 5: Run the tests**

Run: `python3 test/test_web_live.py && python3 test/test_web_dag.py && python3 test/test_web.py`
Expected: all pass, and the DOM half runs (not `SKIP`) on the claude host.

- [ ] **Step 6: Full suite and commit**

Run: `bash test/run.sh`
Expected: no new failures.

```bash
git add scripts/web.py scripts/web_data.py scripts/web_render.py web/static/app.js \
  test/test_web_live.py test/web_cdp.mjs test/web_fixture.py
git commit -m "feat(web): live updates over SSE — issue open/close/label/claim appears without reload (closes #227)"
```

### Task 6: Issue drawer — labels, deps, PR + CI, session timeline, GitHub link (#228)

Clicking a DAG node or a list row opens a drawer. `/fleet/<prefix>?issue=N` opens it on first paint, so the overview links an issue straight into it. That makes an issue's PR and live session two clicks from `/`: the issue link on the overview card, then the PR link.

**Files:**
- Modify: `scripts/issuelib.py` (optional snapshot keys `pulls`, `checks`: `_fetch_pulls(slug, etag)`, `_fetch_checks(slug, sha, etag)`, written by `snapshot` / `_snapshot_incremental`, 880–934), `scripts/web_data.py` (`issue_view`), `scripts/web_render.py` (`drawer`), `scripts/web.py` (route `GET /fleet/<prefix>/issue/<n>`, `?issue=N` on the fleet page), `web/static/app.js` (open/close, focus trap, `Esc`, `history.replaceState`), `web/static/app.css`
- Test: `test/test_web_drawer.py` (create), `test/test_snapshot.sh` (extend: the two new keys, `304` reuse)
- Fixtures: `test/fixtures/web/events.jsonl` (the timeline of #11: `claim`, `launch`, `nudge`, `session_end` with usage; of #41: `launch`, `watchdog_kill`, `launch`), `o__arc.json` gains `pulls` (#13's PR #60, head `issue/13`) and `checks` (`{"<sha>": {"state": "success", "etag": "…"}}`)

**Interfaces:**
- Consumes: `issuelib._gh_api_cond` (671), `_link_next` (700), the `issue_branches` precedent for an optional key (`_issue_branches`, 814: a snapshot without the key reads as none, so there is no schema bump); `stats.issue_timeline` (554), `stats.sessions` (368); `web_dag` nodes (Task 2); `live_sessions` (Task 3)
- Produces: snapshot `pulls: [{"number", "url", "draft", "head_ref", "head_sha", "issue"}]` (open PRs whose head is `issue/<n>`), `checks: {sha: {"state": "success" | "failure" | "pending" | "none", "etag"}}`; `web_data.issue_view(prefix, slug, n, now) -> {"number", "title", "url", "state", "labels", "blocked_by": [{"number", "state"}], "parent", "pr": {...} | None, "ci": str | None, "session": {...} | None, "timeline": [event]} | None`; `GET /fleet/<prefix>/issue/<n>?repo=<slug>` → the drawer fragment (`404` unknown)

- [ ] **Step 1: Write the failing test**

Create `test/test_web_drawer.py`:

```python
#!/usr/bin/env python3
"""test_web_drawer.py — #228: the issue drawer shows every field from cached data only, a deep link
opens it on first paint, and an issue's PR and live session are two clicks from `/`."""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import web_fixture as wf
TMUX = "hz-arc-i11\t%d\n" % (wf.NOW - 600)


def test_drawer_shows_every_field():
    with wf.serving(tmux_ls=TMUX, now=wf.NOW) as (base, host):
        code, d = wf.get(base + "/fleet/hz/issue/13?repo=o/arc")
        assert code == 200, code
        for needle in ('href="https://github.com/o/arc/issues/13"', 'data-label="ready-for-agent"',
                       'data-parent="3"', 'href="https://github.com/o/arc/pull/60"', 'data-ci="success"'):
            assert needle in d, needle
        _, d = wf.get(base + "/fleet/hz/issue/12?repo=o/arc")
        assert re.search(r'data-blocked-by="11"[^>]*data-state="in-progress"', d), "deps lack their state"
        assert 'data-ci="unknown"' in d or 'data-pr="none"' in d, "an uncached PR must read as unknown"
        _, d = wf.get(base + "/fleet/hz/issue/11?repo=o/arc")
        assert 'data-session="hz-arc-i11"' in d
        ev = re.findall(r'data-event="([a-z_]+)"', d)
        assert ev == ["claim", "launch", "nudge", "session_end"], ev
        assert wf.get(base + "/fleet/hz/issue/999?repo=o/arc")[0] == 404
        assert not os.path.exists(host.gh_called), "gh was invoked"


def test_deep_link_opens_the_drawer_and_overview_reaches_it_in_one_click():
    with wf.serving(tmux_ls=TMUX, now=wf.NOW) as (base, host):
        _, page = wf.get(base + "/fleet/hz?issue=13")
        assert re.search(r'<aside [^>]*role="dialog"[^>]*data-issue="13"', page), "deep link did not open the drawer"
        _, ov = wf.get(base + "/")
        assert 'href="/fleet/hz?issue=11"' in ov, "the overview's session row does not link into the drawer"


if __name__ == "__main__":
    sys.exit(wf.run_tests(globals()))
```

The keyboard half (Enter opens, Esc closes, focus returns to the node, 400 px) is asserted in the same file through `wf.cdp` when a browser is present. It uses the skip rule of Task 5.

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/test_web_drawer.py`
Expected: FAIL — `/fleet/hz/issue/13` answers `404`.

- [ ] **Step 3: Cache PR and CI state in the poller, conditionally**

`_fetch_pulls(slug, etag)` sends one `_gh_api_cond("repos/<slug>/pulls?state=open&per_page=100", etag)`, following `_link_next`. On `304` it returns `(None, etag)` and the previous `pulls` is kept. It keeps PRs whose `head.ref` matches `issue/<n>`. `_fetch_checks(slug, sha, etag)` sends `_gh_api_cond("repos/<slug>/commits/<sha>/status", etag)` (the combined status). It runs only for the head shas in `pulls`, and the previous entry is kept on `304`. Both run inside the poller's refresh, never on a page view. A transient failure keeps the previous value and never fails the snapshot, because this is advisory data, as `issue_branches` is. Extend `test/test_snapshot.sh` with a stub `gh api` that returns `304` on a matching ETag, and assert the previous `pulls` survives.

- [ ] **Step 4: The drawer**

`issue_view` joins the board issue, its `web_dag` node (state, deps with their states, parent), the snapshot `pulls`/`checks` (else `pr: None` → "no PR cached"; `ci: None` → "unknown"), the live session, and `stats.issue_timeline(events, n)` filtered to this repo. `web_render.drawer` emits `<aside role="dialog" aria-modal="true" aria-labelledby=… data-issue>` with the fields in the order listed in #228, and a GitHub link last. `app.js` intercepts node clicks and Enter, fetches the fragment, traps Tab inside the drawer, and on Esc or the close button removes it and puts focus back on the node. It mirrors the open issue into `?issue=N` with `history.replaceState`, so the URL is shareable. The drawer lives outside every `data-region`, so SSE swaps never close it, and its own content refreshes when a push changes that issue's node.

- [ ] **Step 5: Run the tests**

Run: `python3 test/test_web_drawer.py && bash test/test_snapshot.sh && bash test/test_board_cache.sh && python3 test/test_issuelib.py`
Expected: all pass.

- [ ] **Step 6: Full suite and commit**

Run: `bash test/run.sh`
Expected: no new failures.

```bash
git add scripts/issuelib.py scripts/web_data.py scripts/web_render.py scripts/web.py web/static \
  test/test_web_drawer.py test/test_snapshot.sh test/fixtures/web
git commit -m "feat(web): issue drawer — labels, deps, PR + CI, session timeline, GitHub link (closes #228)"
```

### Task 7: "Awaiting you" panel and the per-issue / per-PRD stats overlay (#229)

Ports `status-page.py`'s wayfinder section and adds the two other kinds of human-only work, `agent-blocked` questions and operator issues. It also lays `harness stats` numbers over the DAG, and when there is no data it shows nothing at all.

**Files:**
- Modify: `scripts/web_dag.py` (`awaiting(board, labels)`), `scripts/web_data.py` (`issue_stats`, `prd_stats`), `scripts/web_render.py` (`awaiting` region, node and PRD-header stat lines), `skill/harness-arc/scripts/status-page.py` (`arc_model` also returns `tickets`)
- Test: `test/test_web_awaiting.py` (create); `test/fixtures/web/arc-golden.json` (regenerated from `status-page.py` with `tickets`)
- Fixtures: `test/fixtures/web/events.jsonl` (Task 6) is the stats source; `test/fixtures/web/events-empty.jsonl`

**Interfaces:**
- Consumes: `status-page.py`'s `tickets` list (`main`, wayfinder labels, `wayfinder:map` excluded); `stats.sessions`, `stats.prd_rollup` (525), `stats._retries` (414), `stats.add_usage` (358); `EventTail` (Task 5)
- Produces: `web_dag.awaiting(board, labels) -> [{"kind": "wayfinder" | "agent-blocked" | "operator", "number", "title", "url", "resolved", "needs": [n]}]`, where an operator issue is open, has no `prd`/ready/working label, and has a title starting `[ops]` (case-insensitive); `web_dag.arc_projection` gains `"tickets": [[number, resolved]]`; `web_data.issue_stats(events, repo, n) -> {"tokens", "model", "retries"} | None` and `prd_stats(events, repo, prd) -> {...} | None` (`None` when the log has nothing for it)

- [ ] **Step 1: Write the failing test**

Create `test/test_web_awaiting.py`:

```python
#!/usr/bin/env python3
"""test_web_awaiting.py — #229: "Awaiting you" lists the fleet's wayfinder tickets (matching
status-page.py on the same board), agent-blocked questions and operator issues; DAG nodes and PRD
headers carry tokens, model and retries from the event log, and nothing at all when it has none."""
import json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import web_fixture as wf
dag = wf.load("web_dag")
BOARD = json.load(open(os.path.join(wf.FIX, "snapshots", "o__arc.json")))
LABELS = {"prd": "prd", "working": "agent-working", "blocked": "agent-blocked", "ready": "ready-for-agent"}


def test_awaiting_matches_status_page_and_adds_blocked_and_operator():
    a = dag.awaiting(BOARD, LABELS)
    got = sorted((x["kind"], x["number"], x["resolved"]) for x in a)
    assert got == [("agent-blocked", 14, False), ("operator", 40, False),
                   ("wayfinder", 31, False), ("wayfinder", 32, True)], got
    golden = json.load(open(os.path.join(wf.FIX, "arc-golden.json")))
    assert sorted([x["number"], x["resolved"]] for x in a if x["kind"] == "wayfinder") == golden["tickets"]


def test_stats_overlay_present_and_cleanly_absent():
    with wf.serving(now=wf.NOW) as (base, host):
        _, page = wf.get(base + "/fleet/hz")
        assert re.search(r'data-issue="11"[^>]*>.*?data-tokens="\d+"', page, re.S), "no tokens on #11"
        assert re.search(r'data-prd="2"[^>]*>.*?data-retries="\d+"', page, re.S), "no retries on PRD #2"
        assert re.search(r'data-region="awaiting"', page)
    with wf.serving(now=wf.NOW, events="events-empty.jsonl") as (base, host):
        _, page = wf.get(base + "/fleet/hz")
        assert "data-tokens" not in page and "data-retries" not in page
        for empty in ("None tokens", "undefined", "0 tokens", ">—<"):
            assert empty not in page, f"empty stat rendered: {empty!r}"
        assert not os.path.exists(host.gh_called), "gh was invoked"


if __name__ == "__main__":
    sys.exit(wf.run_tests(globals()))
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/test_web_awaiting.py`
Expected: FAIL — `module 'web_dag' has no attribute 'awaiting'`.

- [ ] **Step 3: Golden gains tickets**

Add `"tickets": sorted([t["number"], t["state"] == "CLOSED"] for t in tickets)` to `arc_model`, regenerate `arc-golden.json` with Task 2 Step 4's command, and check the new key by hand. `test_web_dag.py` and `test_harness_arc_status_page.py` must stay green.

- [ ] **Step 4: Panel and overlay**

`awaiting` gives wayfinder tickets in `status-page.py`'s order and resolution, with `needs` = `blocked_by_last`. It adds open `agent-blocked` issues and operator issues. The panel leads the fleet page above the DAGs, because answer-first means human work comes first, and resolved tickets sit collapsed at the end. The panel is `data-region="awaiting"` so SSE keeps it live. Node stat lines show `tokens · model · retries`. A PRD header shows the `prd_rollup` total. A field with no data is omitted, never written as a placeholder.

- [ ] **Step 5: Run the tests**

Run: `python3 test/test_web_awaiting.py && python3 test/test_web_dag.py && python3 test/test_harness_arc_status_page.py && python3 test/test_stats.py`
Expected: all pass.

- [ ] **Step 6: Full suite and commit**

Run: `bash test/run.sh`
Expected: no new failures.

```bash
git add scripts/web_dag.py scripts/web_data.py scripts/web_render.py skill/harness-arc/scripts/status-page.py \
  test/test_web_awaiting.py test/fixtures/web
git commit -m "feat(web): Awaiting you panel and per-issue/PRD stats overlay on the fleet page (closes #229)"
```

### Task 8: `harness-arc` skill links to the dashboard; `status-page.py` and the Artifact path are removed (#230)

The server now holds everything `status-page.py` did, pinned by a golden that no longer needs the script. The skill stops asking an operator to regenerate and republish a page and hands them a URL that is always current.

**Files:**
- Modify: `skill/harness-arc/SKILL.md` (§5 *Status page*: replace the `status-page.py` command and the Artifact publish with `http://<host>:4637/fleet/<prefix>`, `harness web`, `harness web --install`), `skill/harness-arc/REFERENCE.md` (§ *Status page* becomes § *Dashboard*: the same read table, now pointing at `scripts/web_dag.py` / `web_data.py`), `README.md` (line 799: the skill ships `SKILL.md`, `REFERENCE.md`, `scripts/preflight.sh`), `test/test_subskills.sh` (lines 53 and 57 expect `status-page.py`; they become the inverse check)
- Delete: `skill/harness-arc/scripts/status-page.py`, `test/test_harness_arc_status_page.py` (it tests only the deleted script; its DAG semantics live on in `test_web_dag.py`'s golden, and its "no PRDs / gh down" paths have no counterpart in a server that never calls `gh`)
- Test: `test/test_harness_arc_dashboard.sh` (create)

**Interfaces:**
- Consumes: `arc-golden.json` (Tasks 2 and 7), the `harness web` command (Tasks 1 and 4)
- Produces: a `harness-arc` skill with no Artifact step; `test_web_dag.py` running on the frozen golden alone (its `if os.path.exists(SP)` branch is now dead and is removed)

- [ ] **Step 1: Write the failing test**

Create `test/test_harness_arc_dashboard.sh`:

```bash
#!/usr/bin/env bash
# test_harness_arc_dashboard.sh — #230: the harness-arc skill points at the live dashboard and no
# longer publishes an Artifact; status-page.py is gone; the DAG golden still stands without it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
A="$HERE/../skill/harness-arc"
has(){ grep -qE -- "$1" "$2"; }
assert_ok "SKILL.md links the fleet page"            has 'http://<host>:4637/fleet/<prefix>' "$A/SKILL.md"
assert_ok "SKILL.md names harness web"               has '`harness web`' "$A/SKILL.md"
assert_ok "SKILL.md names harness web --install"     has '`harness web --install`' "$A/SKILL.md"
assert_no "status-page.py is removed"                test -e "$A/scripts/status-page.py"
assert_no "no skill file mentions status-page.py"    grep -rqF 'status-page.py' "$A"
assert_no "no publish-an-Artifact instruction left"  grep -rqiE 'artifact (tool|publish)|publish (it|the page) with the artifact|republish' "$A"
assert_ok "the DAG golden still passes"              python3 "$HERE/test_web_dag.py"
assert_ok "the golden fixture is kept"               test -s "$HERE/fixtures/web/arc-golden.json"
finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash test/test_harness_arc_dashboard.sh`
Expected: FAIL — on "SKILL.md links the fleet page", "status-page.py is removed" and the Artifact grep.

- [ ] **Step 3: Rewrite the skill section**

§5 becomes *Dashboard — hand the human a link, not a CLI*. It keeps the paragraph on why a DAG beats a list and the warning to read a whole section. It replaces the command and the Artifact publish with: the fleet page is `http://<host>:4637/fleet/<prefix>`. It is live (no regenerate step). `harness web --install` keeps it running, and on the claude host it binds `0.0.0.0` for LAN access. Point REFERENCE.md's read table at the server modules. Keep the `ready`-sitting-still → *decompose stalled* note, now phrased as "a node that stays `ready` across two cache refreshes". Check that `grep -rni artifact skill/harness-arc` returns only unrelated uses of the word (a PRD's "artifact" in §1 and §2 stays).

- [ ] **Step 4: Remove the script and its test**

```bash
git rm skill/harness-arc/scripts/status-page.py test/test_harness_arc_status_page.py
```

Update `test_subskills.sh` lines 53 and 57 to assert the deploy carries no `status-page.py`. Drop `test_web_dag.py`'s live-comparison branch. Update README line 799.

- [ ] **Step 5: Run the tests**

Run: `bash test/test_harness_arc_dashboard.sh && bash test/test_subskills.sh && python3 test/test_web_dag.py && python3 test/test_web_awaiting.py`
Expected: all pass.

- [ ] **Step 6: Full suite and commit**

Run: `bash test/run.sh`
Expected: no new failures. `test_harness_arc_status_page.py` is gone from the list, by design, and the PR body says so.

```bash
git add -A skill/harness-arc README.md test/test_subskills.sh test/test_web_dag.py test/test_harness_arc_dashboard.sh
git commit -m "feat(harness-arc): link the :4637 dashboard; remove status-page.py and the Artifact path (closes #230)"
```

### Task 9: Design critique rounds — `docs/web/ROUNDS.md`, ≥ 3 rounds, light/dark at 1440/400 (#231)

The same process as design-to-print's `docs/design/ROUNDS.md`: screenshot everything, critique it as a product designer at Stripe or Linear would, fix it, and repeat until a round finds nothing material. The screenshots are produced by a script so every round is comparable and nobody hand-picks a flattering state.

**Files:**
- Create: `docs/web/ROUNDS.md`, `docs/web/screens/r<N>-<view>-<width>-<theme>.png`, `test/web_screens.py` (renders every view × {1440, 400} × {light, dark} from the fixture host through `wf.cdp`, with `data-theme` forced and the drawer open on `#13`)
- Modify: `web/static/*.css`, `scripts/web_render.py` (whatever each round fixes)
- Test: `test/test_web_quality.py` (create); `test/web_fixture.py` gains `browser()` (the Chrome + Node check of Task 5), `resolve_tokens(css, theme)` and `contrast(fg, bg)` (the WCAG 2 relative-luminance ratio)

**Interfaces:**
- Consumes: every view from Tasks 1–7; `wf.serving`, `wf.cdp`
- Produces: `python3 test/web_screens.py --round N` → 12 PNGs (`overview`, `fleet`, `drawer` × 2 widths × 2 themes); `docs/web/ROUNDS.md` with one `## Round N` per round, each holding *Screens*, *Weak*, *Changed* and, on the last round, *Verdict: no material issue*

- [ ] **Step 1: Write the failing test**

Create `test/test_web_quality.py`:

```python
#!/usr/bin/env python3
"""test_web_quality.py — #231: the critique rounds are on record and the measurable half of the bar
holds: AA contrast for every text token pair in both themes, a visible focus ring, no page-level
horizontal scroll at 400 px. Taste is judged in ROUNDS.md; this file only guards what can regress."""
import glob, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import web_fixture as wf
ROUNDS = os.path.join(wf.ROOT, "docs", "web", "ROUNDS.md")
VIEWS, WIDTHS, THEMES = ("overview", "fleet", "drawer"), (1440, 400), ("light", "dark")


def test_rounds_recorded_with_every_screenshot():
    text = open(ROUNDS, encoding="utf-8").read()
    rounds = [int(n) for n in re.findall(r"^## Round (\d+)", text, re.M)]
    assert len(rounds) >= 3 and rounds == list(range(1, len(rounds) + 1)), rounds
    for n in rounds:
        for v in VIEWS:
            for w in WIDTHS:
                for t in THEMES:
                    f = f"screens/r{n}-{v}-{w}-{t}.png"
                    assert f in text, f"ROUNDS.md does not show {f}"
                    assert os.path.getsize(os.path.join(wf.ROOT, "docs", "web", f)) > 0, f
    last = text[text.rindex(f"## Round {rounds[-1]}"):]
    assert re.search(r"Verdict: no material issue", last), "the last round still records a material issue"


def test_text_tokens_meet_wcag_aa_in_both_themes():
    css = open(os.path.join(wf.ROOT, "web", "static", "tokens.css"), encoding="utf-8").read()
    for theme in THEMES:
        tok = wf.resolve_tokens(css, theme)                 # custom properties as hex, per theme
        for fg, bg in (("--ink", "--ground"), ("--ink", "--surface"), ("--muted", "--surface"),
                       ("--accent", "--surface")):
            r = wf.contrast(tok[fg], tok[bg])
            assert r >= 4.5, f"{theme}: {fg} on {bg} is {r:.2f}:1"


def test_no_horizontal_scroll_at_400_and_focus_is_visible():
    browser = wf.browser()
    if not browser:
        print("  SKIP: needs a Chrome and Node >= 22 (HARNESS_WEB_BROWSER)"); return
    with wf.serving(now=wf.NOW) as (base, host):
        for path in ("/", "/fleet/hz", "/fleet/hz?issue=13"):
            with wf.cdp(browser, base + path, width=400) as page:
                assert page.eval("document.documentElement.scrollWidth <= innerWidth"), f"{path} scrolls sideways at 400px"
                page.key("Tab")
                assert page.eval("getComputedStyle(document.activeElement).outlineStyle !== 'none'"), f"{path}: focus invisible"


if __name__ == "__main__":
    sys.exit(wf.run_tests(globals()))
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/test_web_quality.py`
Expected: FAIL — `docs/web/ROUNDS.md` does not exist.

- [ ] **Step 3: Reference, read-only**

Clone design-to-print as in Task 1 Step 3. Read `docs/design/DESIGN.md`, `docs/design/ROUNDS.md` (copy its section shape), the `docs/design/` mockups, `docs/design/screens/` and `app/styles/`. Keep the clone until the last round. Then run `git -C ~/design-to-print status --porcelain` (empty, pasted into the PR) and `rm -rf ~/design-to-print`.

- [ ] **Step 4: Rounds**

For N = 1, 2, 3, …: run `python3 test/web_screens.py --round N`. Put each view's 1440 and 400 screenshots, light and dark, beside the matching design-to-print screen and the Stripe Dashboard / Linear / shadcn dashboard references. Under `## Round N` write *Weak* (hierarchy, alignment, spacing rhythm, type, colour restraint, clutter, contrast, focus, the 10-second "is anything stuck, what needs me?" test on `/`, and two clicks to an issue's PR and live session), then fix every item and list it under *Changed*. Stop at the first round whose *Weak* list has nothing material, and write `Verdict: no material issue` there. Do not stop at round 3 if round 3 still finds something.

- [ ] **Step 5: Run the tests**

Run: `python3 test/test_web_quality.py && python3 test/test_web.py && python3 test/test_web_dag.py && python3 test/test_web_live.py && python3 test/test_web_drawer.py`
Expected: all pass, with the browser half run (not `SKIP`) on the claude host.

- [ ] **Step 6: Full suite and commit**

Run: `bash test/run.sh`
Expected: no new failures. Check that no PR or push to `VocanicZ/design-to-print` exists: `gh pr list -R VocanicZ/design-to-print --author @me --state all` lists nothing from this work.

```bash
git add docs/web web/static scripts/web_render.py test/web_screens.py test/test_web_quality.py test/web_fixture.py
git commit -m "docs(web): design critique rounds, light/dark at 1440/400, last round clean (closes #231)"
```

## What this plan deliberately leaves undone

- **Any write action from the page.** Claim, close, label, kill, nudge, pause, and "refresh now" are all out. The page has no auth, and read-only is its only safety boundary (PRD #192 non-goals). An operator acts through `harness …` or GitHub, and the page shows the result within one refresh.
- **Remote or Internet exposure, and auth.** `0.0.0.0` is for the owner's LAN only. TLS, a reverse proxy, login, and per-user views are not planned. The README says not to forward the port.
- **Fleets on other hosts.** The page shows what `$HARNESS_FLEETS_DIR` on this host knows. A multi-host view would need a transport for each host's local state, and nothing here builds one.
- **History and charts.** The page shows now, plus each issue's own event timeline. Trends over days (tokens per day, throughput, hold minutes) stay in `harness stats`. The event log already holds them, and a chart view is a later PRD.
- **CI detail beyond the combined status.** The drawer shows the head commit's combined status (Task 6) and links to GitHub for the checks. Per-check logs, check-run annotations, and re-run buttons would cost GitHub reads per view or a write, so they are not planned.
- **Making `harness status` read the board cache.** `fleetview.py` keeps its `gh` counts and its `gh api rate_limit` budget line. Task 1 only factors out `tally` so the server can use the snapshot. Moving the CLI view off `gh` as well is a separate change.
- **Push from the poller.** The server polls its inputs with `stat` every `HARNESS_WEB_TICK`. An inotify watch or a poller-to-server notification would cut the delay below a tick, but the PRD's bar is one board-cache refresh, which a 2-second tick already meets.
- **Retiring `harness status --watch`.** The terminal views stay, because they work over SSH where a browser does not.
