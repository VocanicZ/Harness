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
    # on the board: #3 has `#99` then `#1`; only the last section is an edge
    g = dag.unit_graph(BOARD, LABELS)
    assert g["issues"][3]["deps"] == [1] and [1, 3] in g["edges"] and [99, 3] not in g["edges"], g["edges"]


def test_parallel_prds_share_a_layer_and_join_after_both():
    lay = {p["number"]: p["layer"] for p in dag.unit_graph(BOARD, LABELS)["prds"]}
    assert lay[2] == lay[3] == lay[1] + 1 and lay[4] == lay[2] + 1, lay


def test_children_attributed_by_parent_and_layered_among_siblings():
    g = dag.unit_graph(BOARD, LABELS)
    kids = {p["number"]: [c["number"] for c in p["children"]] for p in g["prds"]}
    assert kids == {1: [], 2: [10, 11, 12], 3: [13, 14, 15], 4: [41, 42]}, kids
    assert {n: g["issues"][n]["layer"] for n in (10, 11, 12)} == {10: 0, 11: 0, 12: 1}
    assert g["issues"][12]["parent"] == 2 and [11, 12] in g["edges"], g["edges"]
    assert all(n not in g["issues"] for n in (30, 31, 32)), "wayfinder issues are not DAG nodes"
    assert g["issues"][13]["url"] == "https://github.com/o/arc/issues/13"


def test_child_states_and_unparented():
    g = dag.unit_graph(BOARD, LABELS, live=frozenset({11, 41}))
    st = {n: g["issues"][n]["state"] for n in (10, 11, 12, 13, 14, 15, 41, 42)}
    assert st == {10: "closed", 11: "in-progress", 12: "blocked", 13: "in-review",
                  14: "agent-blocked", 15: "open", 41: "in-progress", 42: "open"}, st
    assert [i["number"] for i in g["unparented"]] == [20, 40]
    # #11 has no live session → not in progress; #12's dep #11 is still open → still blocked
    g = dag.unit_graph(BOARD, LABELS)
    assert (g["issues"][11]["state"], g["issues"][12]["state"]) == ("open", "blocked")


def test_fleet_page_renders_the_dag_and_404s_unknown_prefixes():
    with wf.serving(tmux_ls="hz-arc-i11\t1800000000\nhz-arc-i41\t1800000000\n") as (base, host):
        code, body = wf.get(base + "/fleet/hz")
        assert code == 200, code
        for n, layer in ((1, 0), (2, 1), (3, 1), (4, 2)):
            assert re.search(rf'data-prd="{n}"[^>]*data-layer="{layer}"', body), (n, layer)
        assert re.search(r'data-issue="11"[^>]*data-state="in-progress"', body)
        assert re.search(r'data-issue="14"[^>]*data-state="agent-blocked"', body)
        assert 'data-region="dag-o/arc"' in body
        assert 'data-region="unparented-o/arc"' in body and 'data-issue="20"' in body
        assert re.search(r'<a [^>]*href="\?issue=13"[^>]*data-issue="13"', body), "DAG nodes are not focusable links"
        assert re.search(r'data-issue="13"[^>]*tabindex="0"[^>]*aria-label="#13 ', body), "node has no accessible name"
        assert re.search(r'data as of <time datetime="\d{4}-\d\d-\d\dT[\d:]+Z"', body), "no as-of stamp"
        assert " style=" not in body and not re.search(r"<script(?![^>]*\ssrc=)", body), "inline style/script"
        assert wf.get(base + "/fleet/nope")[0] == 404
        assert not os.path.exists(host.gh_called), "gh was invoked while rendering the fleet page"


def test_dag_panel_scrolls_inside_itself_and_nodes_show_focus():
    css = open(os.path.join(wf.ROOT, "web", "static", "app.css"), encoding="utf-8").read()
    assert re.search(r"\.dag\s*\{[^}]*overflow-x:\s*auto", css), ".dag does not scroll inside itself"
    assert re.search(r"\.dag a:focus-visible[^{]*\{[^}]*outline", css), "DAG nodes have no visible focus ring"


if __name__ == "__main__":
    sys.exit(wf.run_tests(globals()))
