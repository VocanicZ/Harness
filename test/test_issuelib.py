import importlib.util, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("issuelib", os.path.join(HERE, "..", "scripts", "issuelib.py"))
il = importlib.util.module_from_spec(spec); spec.loader.exec_module(il)
_REAL_COMPUTE_STATE = il.compute_state   # tests that stub compute_state must restore this

# Other tests monkeypatch il._spec_hash without restoring it; keep a handle to the real one so the
# spec-hash test verifies actual behaviour regardless of run order.
REAL_SPEC_HASH = il._spec_hash

# Other tests monkeypatch these read seams without restoring them; capture the real (snapshot-aware)
# implementations so the snapshot-mode tests can exercise the genuine read path regardless of order.
_REAL_LIST_ISSUES = il._list_issues
_REAL_ISSUE_STATE = il._issue_state
_REAL_HAS_PLAN = il._has_plan
_REAL_PLAN_MARKER = il._plan_marker
_REAL_AUTHOR_FILTER = il._author_filter

def mk(**kw):
    base = dict(slug="acme/widget", has_plan=False, prd=None, prd_open=False, prd_reviewed=False,
                children_exist=False, children_all_closed=False, unblocked=[], open_children=0, total_children=0,
                plan_marker_matches=False, prds=None, unparented_unblocked=None, open_unparented=0)
    base.update(kw)
    # Bridge: when a test supplies only the legacy scalars, synthesise the single-PRD `prds` list
    # they imply, so pre-existing tests exercise the new dispatch path unchanged.
    if base["prds"] is None:
        base["prds"] = ([{"number": base["prd"], "open": base["prd_open"],
                          "reviewed": base["prd_reviewed"], "eligible": True,
                          "children_exist": base["children_exist"],
                          "children_all_closed": base["children_all_closed"],
                          "unblocked": list(base["unblocked"])}]
                        if base["prd"] is not None else [])
        base["unparented_unblocked"] = [] if base["prd"] is not None else list(base["unblocked"])
    elif base["unparented_unblocked"] is None:
        base["unparented_unblocked"] = []
    return base

def prd(number, unblocked=(), eligible=True, open=True, reviewed=False,
        children_exist=True, children_all_closed=False):
    return {"number": number, "open": open, "reviewed": reviewed, "eligible": eligible,
            "children_exist": children_exist, "children_all_closed": children_all_closed,
            "unblocked": list(unblocked)}

def dispatch_with(mode, state, free=3):
    os.environ["HARNESS_MODE"] = mode
    il.compute_state = lambda repo: state           # stub GitHub
    allow = mode in ("planned",) or True            # caller decides; here exercise via dispatch()
    return il.dispatch("acme/widget", free, True)

def test_issue_only_emits_only_impl():
    os.environ["HARNESS_MODE"] = "issue-only"
    il.compute_state = lambda r: mk(prd=None, has_plan=False, children_exist=True, unblocked=[5,6])
    acts = il.dispatch("acme/widget", 3, True)
    assert [a[0] for a in acts] == ["IMPL", "IMPL"], acts
    # never PLAN/PRD/DECOMPOSE even with no plan/prd/children
    il.compute_state = lambda r: mk(prd=None, has_plan=False, children_exist=False, unblocked=[])
    assert il.dispatch("acme/widget", 3, True) == []

def test_prd_mode_decompose_not_plan_or_prd():
    os.environ["HARNESS_MODE"] = "prd"
    # human supplied PRD (prd set), no children yet -> DECOMPOSE, never PLAN/PRD
    il.compute_state = lambda r: mk(prd=10, prd_open=True, has_plan=False, children_exist=False)
    acts = il.dispatch("acme/widget", 3, True)
    assert acts and acts[0][0] == "DECOMPOSE", acts
    # no PRD yet in prd mode -> nothing (human must create it; agent must NOT author PLAN/PRD)
    il.compute_state = lambda r: mk(prd=None, has_plan=False, children_exist=False)
    assert il.dispatch("acme/widget", 3, True) == []

def test_planned_mode_full_pipeline():
    os.environ["HARNESS_MODE"] = "planned"
    il.compute_state = lambda r: mk(prd=None, has_plan=False)
    assert il.dispatch("acme/widget", 3, True)[0][0] == "PLAN"
    il.compute_state = lambda r: mk(prd=None, has_plan=True)
    assert il.dispatch("acme/widget", 3, True)[0][0] == "PRD"
    il.compute_state = lambda r: mk(prd=7, prd_open=True, has_plan=True, children_exist=False)
    assert il.dispatch("acme/widget", 3, True)[0][0] == "DECOMPOSE"
    il.compute_state = lambda r: mk(prd=7, prd_open=True, children_exist=True, children_all_closed=True)
    assert il.dispatch("acme/widget", 3, True)[0][0] == "REVIEW"

def test_planned_replan_suppressed_when_marker_matches():
    # A finished plan archived PLAN.md (has_plan=False) and left a spec-keyed marker whose hash
    # still matches the current spec → auto-PLAN must NOT re-fire.
    os.environ["HARNESS_MODE"] = "planned"
    il.compute_state = lambda r: mk(prd=None, has_plan=False, plan_marker_matches=True)
    assert il.dispatch("acme/widget", 3, True) == [], "marker match must suppress replan"
    # Spec content changed since completion (hash differs) → a fresh PLAN is allowed again.
    il.compute_state = lambda r: mk(prd=None, has_plan=False, plan_marker_matches=False)
    assert il.dispatch("acme/widget", 3, True)[0][0] == "PLAN", "spec drift must allow replan"

def test_plan_marker_matches_compares_marker_hash_to_current_spec():
    # compute_state derives plan_marker_matches from the committed marker (mocked gh) vs the live
    # spec hash. Matching hash → True (suppress); differing/absent → False (allow).
    os.environ["HARNESS_MODE"] = "planned"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    il._self_login = lambda: "me"               # no real `gh api user` round-trip
    il._list_issues = lambda slug, extra=None: []
    il._has_plan = lambda slug: False
    orig_spec_hash = il._spec_hash
    il._spec_hash = lambda: "abc123"
    try:
        il._plan_marker = lambda slug: {"spec": "docs/spec.md", "spec_hash": "abc123"}
        assert _REAL_COMPUTE_STATE("acme/widget")["plan_marker_matches"] is True
        il._plan_marker = lambda slug: {"spec": "docs/spec.md", "spec_hash": "DIFFERENT"}
        assert _REAL_COMPUTE_STATE("acme/widget")["plan_marker_matches"] is False
        il._plan_marker = lambda slug: None
        assert _REAL_COMPUTE_STATE("acme/widget")["plan_marker_matches"] is False
    finally:
        il._spec_hash = orig_spec_hash

def test_complete_predicate_by_mode():
    # issue-only: complete when no open dispatchable issues remain
    os.environ["HARNESS_MODE"] = "issue-only"
    il.compute_state = lambda r: mk(children_exist=True, open_children=0, unblocked=[])
    assert il.is_complete(il.compute_state("x")) is True
    il.compute_state = lambda r: mk(children_exist=True, open_children=2, unblocked=[5,6])
    assert il.is_complete(il.compute_state("x")) is False
    # prd/planned: complete when PRD closed + reviewed
    os.environ["HARNESS_MODE"] = "planned"
    assert il.is_complete(mk(prd=7, prd_open=False, prd_reviewed=True)) is True
    assert il.is_complete(mk(prd=7, prd_open=True, prd_reviewed=True)) is False

def test_parse_blocked_by_cross_repo_and_bare():
    # owner/repo#N is a cross-repo ref; bare #N resolves against self_repo.
    body = "do a thing\n\n## Blocked by\nother/repo#42\n#99\n\nPart of #7\n"
    refs = il.parse_blocked_by(body, "acme/widget")
    assert ("other/repo", 42) in refs, refs
    assert ("acme/widget", 99) in refs, refs   # bare #99 -> self repo
    assert ("acme/widget", 7) in refs, refs    # trailing "Part of #7" also captured (filtered later by prd_num)

def test_parse_blocked_by_colon_heading():
    # `## Blocked by:` (trailing colon) must still be recognised as the section heading.
    assert il.parse_blocked_by("## Blocked by:\n#5\n", "r/r") == [("r/r", 5)], \
        il.parse_blocked_by("## Blocked by:\n#5\n", "r/r")

def test_parse_blocked_by_h3_heading():
    # `### Blocked by` (h3) must also be recognised as the section heading.
    assert il.parse_blocked_by("### Blocked by\n#5\n", "r/r") == [("r/r", 5)], \
        il.parse_blocked_by("### Blocked by\n#5\n", "r/r")

def test_parse_blocked_by_h3_heading_terminates_at_next_heading():
    # An h3 blocked-by section must end at the next heading of same-or-higher level,
    # so refs under a following section are NOT harvested as blockers.
    body = "### Blocked by\n#5\n\n## Notes\n#99\n\n### Other\n#42\n"
    refs = il.parse_blocked_by(body, "r/r")
    assert refs == [("r/r", 5)], refs

def test_parse_blocked_by_ignores_prose_fixes_ref():
    # `fixes#88` (no boundary before `#`) is prose, NOT a blocker -> must not deadlock.
    assert il.parse_blocked_by("## Blocked by\nsee PR (fixes#88)\n", "self/self") == [], \
        il.parse_blocked_by("## Blocked by\nsee PR (fixes#88)\n", "self/self")

def test_parse_blocked_by_ignores_prose_closes_ref():
    # `closes#42` is prose glued to a word -> must not be captured as a blocker.
    assert il.parse_blocked_by("## Blocked by\ncloses#42 in upstream\n", "self/self") == [], \
        il.parse_blocked_by("## Blocked by\ncloses#42 in upstream\n", "self/self")

def test_parse_blocked_by_qualified_ref_still_matches():
    # A slug-qualified owner/repo#N still resolves as a cross-repo blocker.
    assert il.parse_blocked_by("## Blocked by\nowner/repo#5\n", "self/self") == [("owner/repo", 5)], \
        il.parse_blocked_by("## Blocked by\nowner/repo#5\n", "self/self")

def test_parse_blocked_by_bare_ref_still_matches():
    # A standalone bare #N still resolves against self_repo.
    assert il.parse_blocked_by("## Blocked by\n#5\n", "self/self") == [("self/self", 5)], \
        il.parse_blocked_by("## Blocked by\n#5\n", "self/self")

def test_cross_repo_blocked_until_target_issue_closes():
    # A child blocked by a CROSS-REPO issue is excluded while that issue is open,
    # and included once it closes. The state query must hit the cross-repo slug.
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    il._self_login = lambda: "me"
    il.compute_state = _REAL_COMPUTE_STATE   # undo any prior stub
    il._list_issues = lambda slug, extra=None: [
        {"number": 5, "title": "needs upstream", "state": "OPEN", "_author": "me",
         "body": "## Blocked by\nother/repo#42\n", "_labels": {"ready-for-agent"}},
    ]
    il._has_plan = lambda slug: False
    il._plan_marker = lambda slug: None   # hermetic: never read the real repo
    queried = []
    cross_state = {"open"}   # mutable single-element holder
    def fake_state(slug, number):
        queried.append((slug, number))
        return next(iter(cross_state))
    il._issue_state = fake_state

    # cross-repo issue OPEN -> requester blocked
    s = il.compute_state("acme/widget")
    assert 5 not in s["unblocked"], s
    assert ("other/repo", 42) in queried, queried   # resolved to the cross-repo slug, not acme/widget

    # cross-repo issue CLOSED -> requester unblocked
    cross_state.clear(); cross_state.add("closed")
    s = il.compute_state("acme/widget")
    assert 5 in s["unblocked"], s

def test_bare_ref_blocks_same_repo():
    # A bare #N in `## Blocked by` resolves to the SAME repo (not a cross-repo lookup).
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    il._self_login = lambda: "me"
    il.compute_state = _REAL_COMPUTE_STATE   # undo any prior stub
    il._list_issues = lambda slug, extra=None: [
        {"number": 5, "title": "blocked by sibling", "state": "OPEN", "_author": "me",
         "body": "## Blocked by\n#9\n", "_labels": {"ready-for-agent"}},
    ]
    il._has_plan = lambda slug: False
    il._plan_marker = lambda slug: None   # hermetic: never read the real repo
    queried = []
    il._issue_state = lambda slug, number: (queried.append((slug, number)) or "open")
    s = il.compute_state("acme/widget")
    assert 5 not in s["unblocked"], s
    assert ("acme/widget", 9) in queried, queried   # bare ref queried against self repo

def test_spec_hash_is_sha256_of_spec_file_content():
    import hashlib, tempfile
    body = b"engine hardening spec v1\n"
    with tempfile.NamedTemporaryFile("wb", suffix=".md", delete=False) as f:
        f.write(body); path = f.name
    os.environ["HARNESS_SPEC"] = path
    assert REAL_SPEC_HASH() == hashlib.sha256(body).hexdigest(), REAL_SPEC_HASH()
    # unreadable / unset spec hashes to "" on both sides of the comparison
    os.environ["HARNESS_SPEC"] = "/no/such/spec.md"
    assert REAL_SPEC_HASH() == "", REAL_SPEC_HASH()
    os.environ.pop("HARNESS_SPEC", None)
    assert REAL_SPEC_HASH() == ""

def test_agent_paused_issue_is_dispatchable():
    il.compute_state = _REAL_COMPUTE_STATE
    # a force-paused issue: ready label kept, agent-working removed, agent-paused added, OPEN
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    il._self_login = lambda: "me"
    il._list_issues = lambda slug, extra=None: [
        {"number": 5, "title": "a", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"ready-for-agent", "agent-paused"}},
    ]
    il._has_plan = lambda slug: False
    il._plan_marker = lambda slug: None          # no real gh round-trip
    il._spec_hash = lambda: ""
    s = _REAL_COMPUTE_STATE("acme/widget")
    assert 5 in s["unblocked"], s
    assert s["paused"] == 1, s

def test_author_allowlist_self_only_denies_others():
    il.compute_state = _REAL_COMPUTE_STATE
    # default (empty allowlist) = self-only: own issues claimed, others silently dropped
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    il._self_login = lambda: "me"
    il._has_plan = lambda slug: False
    il._plan_marker = lambda slug: None   # hermetic: never read the real repo
    il._list_issues = lambda slug, extra=None: [
        {"number": 5, "title": "mine", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"ready-for-agent"}},
        {"number": 6, "title": "theirs", "state": "OPEN", "body": "", "_author": "attacker",
         "_labels": {"ready-for-agent"}},
    ]
    s = il.compute_state("acme/widget")
    assert s["unblocked"] == [5], s
    assert s["total_children"] == 1, s   # disallowed-author issue dropped entirely

def test_author_allowlist_member_allowed_additive_to_self():
    il.compute_state = _REAL_COMPUTE_STATE
    # HARNESS_AUTHOR_ALLOWLIST is additive to self; both self and listed members claim
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ["HARNESS_AUTHOR_ALLOWLIST"] = "teammate, OtherBot"   # spaces + mixed case tolerated
    il._self_login = lambda: "me"
    il._has_plan = lambda slug: False
    il._plan_marker = lambda slug: None   # hermetic: never read the real repo
    il._list_issues = lambda slug, extra=None: [
        {"number": 5, "title": "mine", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"ready-for-agent"}},
        {"number": 6, "title": "mate", "state": "OPEN", "body": "", "_author": "teammate",
         "_labels": {"ready-for-agent"}},
        {"number": 7, "title": "bot", "state": "OPEN", "body": "", "_author": "otherbot",
         "_labels": {"ready-for-agent"}},
        {"number": 8, "title": "bad", "state": "OPEN", "body": "", "_author": "attacker",
         "_labels": {"ready-for-agent"}},
    ]
    s = il.compute_state("acme/widget")
    assert sorted(s["unblocked"]) == [5, 6, 7], s

def test_author_allowlist_star_allows_any():
    il.compute_state = _REAL_COMPUTE_STATE
    # `*` restores allow-any, even when self login cannot be resolved
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ["HARNESS_AUTHOR_ALLOWLIST"] = "*"
    il._self_login = lambda: ""
    il._has_plan = lambda slug: False
    il._plan_marker = lambda slug: None   # hermetic: never read the real repo
    il._list_issues = lambda slug, extra=None: [
        {"number": 6, "title": "anyone", "state": "OPEN", "body": "", "_author": "anyone",
         "_labels": {"ready-for-agent"}},
    ]
    s = il.compute_state("acme/widget")
    assert s["unblocked"] == [6], s

def test_author_check_applies_to_prd_selection():
    il.compute_state = _REAL_COMPUTE_STATE
    # a PRD authored by a non-allowed user must NOT be selected as the PRD (no hijack)
    os.environ["HARNESS_MODE"] = "prd"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    il._self_login = lambda: "me"
    il._has_plan = lambda slug: False
    il._plan_marker = lambda slug: None   # hermetic: never read the real repo
    il._list_issues = lambda slug, extra=None: [
        {"number": 10, "title": "[AFK] PRD: evil", "state": "OPEN", "body": "", "_author": "attacker",
         "_labels": {"prd"}},
    ]
    s = il.compute_state("acme/widget")
    assert s["prd"] is None, s

def test_bug_lane_issues_excluded_from_children_and_unblocked():
    il.compute_state = _REAL_COMPUTE_STATE
    # bug-lane issues carry the ready label but must never be claimable by the pool:
    # excluded from children (so total_children) and from unblocked.
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    os.environ.pop("HARNESS_LABEL_BUG", None)
    os.environ.pop("HARNESS_LABEL_BUG_TRIAGED", None)
    il._self_login = lambda: "me"
    il._has_plan = lambda slug: False
    il._plan_marker = lambda slug: None
    il._spec_hash = lambda: ""
    il._list_issues = lambda slug, extra=None: [
        {"number": 5, "title": "real work", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"ready-for-agent"}},
        {"number": 6, "title": "a bug", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"ready-for-agent", "bug"}},
        {"number": 7, "title": "triaged bug", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"ready-for-agent", "bug-triaged"}},
    ]
    s = il.compute_state("acme/widget")
    assert s["unblocked"] == [5], s
    assert s["total_children"] == 1, s          # only the non-bug issue counts as a child
    assert 6 not in s["unblocked"] and 7 not in s["unblocked"], s

def test_open_bug_does_not_block_unit_complete():
    il.compute_state = _REAL_COMPUTE_STATE
    # every real child closed; an OPEN bug-lane issue must not keep the unit from completing.
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    os.environ.pop("HARNESS_LABEL_BUG", None)
    os.environ.pop("HARNESS_LABEL_BUG_TRIAGED", None)
    il._self_login = lambda: "me"
    il._has_plan = lambda slug: False
    il._plan_marker = lambda slug: None
    il._spec_hash = lambda: ""
    il._list_issues = lambda slug, extra=None: [
        {"number": 5, "title": "done work", "state": "CLOSED", "body": "", "_author": "me",
         "_labels": {"ready-for-agent"}},
        {"number": 6, "title": "open bug", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"ready-for-agent", "bug"}},
    ]
    s = il.compute_state("acme/widget")
    assert s["open_children"] == 0, s
    assert il.is_complete(s) is True, s

def test_bug_lane_labels_honour_env_overrides():
    il.compute_state = _REAL_COMPUTE_STATE
    # custom lane label names come from HARNESS_LABEL_BUG / HARNESS_LABEL_BUG_TRIAGED.
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    os.environ["HARNESS_LABEL_BUG"] = "defect"
    os.environ["HARNESS_LABEL_BUG_TRIAGED"] = "defect-ready"
    il._self_login = lambda: "me"
    il._has_plan = lambda slug: False
    il._plan_marker = lambda slug: None
    il._spec_hash = lambda: ""
    il._list_issues = lambda slug, extra=None: [
        {"number": 5, "title": "real work", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"ready-for-agent"}},
        {"number": 6, "title": "a defect", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"ready-for-agent", "defect"}},
    ]
    try:
        s = il.compute_state("acme/widget")
        assert s["unblocked"] == [5], s
        assert s["total_children"] == 1, s
    finally:
        os.environ.pop("HARNESS_LABEL_BUG", None)
        os.environ.pop("HARNESS_LABEL_BUG_TRIAGED", None)

def test_self_is_always_allowed_even_with_nonempty_allowlist():
    il.compute_state = _REAL_COMPUTE_STATE
    # self never needs to be in the allowlist — fleet's own PRD/decompose/cross-repo issues survive
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ["HARNESS_AUTHOR_ALLOWLIST"] = "someone-else"
    il._self_login = lambda: "me"
    il._has_plan = lambda slug: False
    il._plan_marker = lambda slug: None   # hermetic: never read the real repo
    il._list_issues = lambda slug, extra=None: [
        {"number": 5, "title": "mine", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"ready-for-agent"}},
    ]
    s = il.compute_state("acme/widget")
    assert s["unblocked"] == [5], s

def test_bug_lane_issues_lists_open_bugs_for_the_priority_lane():
    # the priority lane (#26) claims bug-lane issues: open, carrying L_BUG or L_BUG_TRIAGED,
    # not already agent-working, author-allowed. Closed bugs and the working one are excluded.
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    os.environ.pop("HARNESS_LABEL_BUG", None)
    os.environ.pop("HARNESS_LABEL_BUG_TRIAGED", None)
    il._self_login = lambda: "me"
    il._list_issues = lambda slug, extra=None: [
        {"number": 5, "title": "real work", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"ready-for-agent"}},                       # not a bug -> excluded
        {"number": 6, "title": "a bug", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug"}},                                   # claimable
        {"number": 7, "title": "triaged bug", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug-triaged"}},                           # claimable (fix stage)
        {"number": 8, "title": "bug in flight", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug", "agent-working"}},                  # already owned -> excluded
        {"number": 9, "title": "fixed bug", "state": "CLOSED", "body": "", "_author": "me",
         "_labels": {"bug"}},                                   # closed -> excluded
    ]
    # fix-pending-first (#28): the bug-triaged #7 (a pending fix) sorts ahead of the fresh #6.
    assert il.bug_lane_issues("acme/widget") == [7, 6], il.bug_lane_issues("acme/widget")

def test_bug_lane_issues_drops_disallowed_authors():
    # a bug filed by a non-allowed author must not enter the lane (secure-by-default).
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    os.environ.pop("HARNESS_LABEL_BUG", None)
    il._self_login = lambda: "me"
    il._list_issues = lambda slug, extra=None: [
        {"number": 6, "title": "mine", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug"}},
        {"number": 7, "title": "stranger's", "state": "OPEN", "body": "", "_author": "stranger",
         "_labels": {"bug"}},
    ]
    assert il.bug_lane_issues("acme/widget") == [6], il.bug_lane_issues("acme/widget")

def test_bug_lane_issues_fix_pending_first():
    # fix-pending-first (#28): a bug already triaged (L_BUG_TRIAGED, a pending fix) must come
    # before a fresh untriaged bug, so the cap-1 lane drains the triaged one to closed before
    # triaging the new one — even when the fresh bug has the lower issue number.
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    os.environ.pop("HARNESS_LABEL_BUG", None)
    os.environ.pop("HARNESS_LABEL_BUG_TRIAGED", None)
    il._self_login = lambda: "me"
    il._list_issues = lambda slug, extra=None: [
        {"number": 6, "title": "fresh bug", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug"}},                                   # triage stage, lower number
        {"number": 9, "title": "triaged bug", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug-triaged"}},                           # fix stage, higher number
    ]
    assert il.bug_lane_issues("acme/widget") == [9, 6], il.bug_lane_issues("acme/widget")

def test_bug_lane_issues_stable_within_a_phase():
    # the fix-pending-first sort is stable: among same-phase bugs the input (issue) order holds,
    # so two pending fixes drain oldest-first and two fresh bugs triage in list order.
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    os.environ.pop("HARNESS_LABEL_BUG", None)
    os.environ.pop("HARNESS_LABEL_BUG_TRIAGED", None)
    il._self_login = lambda: "me"
    il._list_issues = lambda slug, extra=None: [
        {"number": 3, "title": "fresh a", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug"}},
        {"number": 5, "title": "triaged a", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug-triaged"}},
        {"number": 4, "title": "fresh b", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug"}},
        {"number": 8, "title": "triaged b", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug-triaged"}},
    ]
    # both triaged (in list order: 5, 8) precede both fresh (in list order: 3, 4)
    assert il.bug_lane_issues("acme/widget") == [5, 8, 3, 4], il.bug_lane_issues("acme/widget")

def test_bug_lane_candidates_pairs_number_with_phase():
    # the priority lane needs each bug's phase to order candidates fix-pending-first ACROSS
    # repos (#37): bug_lane_candidates returns (number, phase) where phase is 'fix' for a
    # bug-triaged (pending fix) and 'triage' for a fresh bug, in the same fix-pending-first order.
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    os.environ.pop("HARNESS_LABEL_BUG", None)
    os.environ.pop("HARNESS_LABEL_BUG_TRIAGED", None)
    il._self_login = lambda: "me"
    il._list_issues = lambda slug, extra=None: [
        {"number": 6, "title": "fresh bug", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug"}},
        {"number": 9, "title": "triaged bug", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug-triaged"}},
    ]
    assert il.bug_lane_candidates("acme/widget") == [(9, "fix"), (6, "triage")], \
        il.bug_lane_candidates("acme/widget")

def test_bug_lane_issues_cli_prints_number_and_phase():
    # the `bugs` CLI feeds the bash lane (#37): each line is "<number>\t<phase>" so the lane can
    # tag the candidate with its repo and globally re-sort fix-pending-first across repos.
    os.environ.pop("HARNESS_LABEL_BUG", None)
    os.environ.pop("HARNESS_LABEL_BUG_TRIAGED", None)
    il._self_login = lambda: "me"
    il._list_issues = lambda slug, extra=None: [
        {"number": 6, "title": "a bug", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug"}},
        {"number": 9, "title": "triaged bug", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug-triaged"}},
    ]
    import io, contextlib
    buf = io.StringIO()
    argv = sys.argv
    sys.argv = ["issuelib.py", "bugs", "acme/widget"]
    try:
        with contextlib.redirect_stdout(buf):
            il.main()
    finally:
        sys.argv = argv
    # fix-pending-first: #9 (fix) before #6 (triage); each line carries the phase.
    assert buf.getvalue().splitlines() == ["9\tfix", "6\ttriage"], buf.getvalue()

def test_bug_lane_working_lists_open_bugs_under_agent_working():
    # the lane's per-poll self-heal (#42) needs the COMPLEMENT of bug_lane_candidates: open
    # bug-lane issues that ARE agent-working (a possibly-crashed in-flight claim). reap_lane walks
    # these and frees the ones whose session is dead. Both phases (fresh bug + bug-triaged) count;
    # closed bugs, bugs without agent-working, and non-bug working issues are all excluded.
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    os.environ.pop("HARNESS_LABEL_BUG", None)
    os.environ.pop("HARNESS_LABEL_BUG_TRIAGED", None)
    il._self_login = lambda: "me"
    il._list_issues = lambda slug, extra=None: [
        {"number": 5, "title": "real work in flight", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"ready-for-agent", "agent-working"}},       # not a bug -> excluded
        {"number": 6, "title": "fresh bug, idle", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug"}},                                    # no agent-working -> excluded
        {"number": 7, "title": "fresh bug in flight", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug", "agent-working"}},                   # working triage -> included
        {"number": 8, "title": "triaged bug in flight", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug-triaged", "agent-working"}},           # working fix -> included
        {"number": 9, "title": "fixed bug", "state": "CLOSED", "body": "", "_author": "me",
         "_labels": {"bug", "agent-working"}},                   # closed -> excluded
    ]
    assert il.bug_lane_working("acme/widget") == [7, 8], il.bug_lane_working("acme/widget")

def test_bug_lane_working_drops_disallowed_authors():
    # a working bug filed by a non-allowed author must not be reconciled by the lane either
    # (secure-by-default: the lane never touches issues it could never have claimed).
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    os.environ.pop("HARNESS_LABEL_BUG", None)
    il._self_login = lambda: "me"
    il._list_issues = lambda slug, extra=None: [
        {"number": 6, "title": "mine in flight", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug", "agent-working"}},
        {"number": 7, "title": "stranger's in flight", "state": "OPEN", "body": "", "_author": "stranger",
         "_labels": {"bug", "agent-working"}},
    ]
    assert il.bug_lane_working("acme/widget") == [6], il.bug_lane_working("acme/widget")

def test_bug_lane_working_cli_prints_one_number_per_line():
    # the `working-bugs` CLI feeds reap_lane (#42): one bare issue number per line.
    os.environ.pop("HARNESS_LABEL_BUG", None)
    os.environ.pop("HARNESS_LABEL_BUG_TRIAGED", None)
    il._self_login = lambda: "me"
    il._list_issues = lambda slug, extra=None: [
        {"number": 7, "title": "working triage", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug", "agent-working"}},
        {"number": 8, "title": "working fix", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"bug-triaged", "agent-working"}},
    ]
    import io, contextlib
    buf = io.StringIO()
    argv = sys.argv
    sys.argv = ["issuelib.py", "working-bugs", "acme/widget"]
    try:
        with contextlib.redirect_stdout(buf):
            il.main()
    finally:
        sys.argv = argv
    assert buf.getvalue().splitlines() == ["7", "8"], buf.getvalue()

def test_parse_blocked_by_none_section_with_prose_harvests_nothing():
    # Regression for the permanent-PRD-deadlock bug (#85): a `## Blocked by` section whose first
    # token is `None` must yield NO refs, even when trailing prose name-drops merged PRs / issues.
    # The docstring already promised []; the code must honor it.
    body = ("client half of the fix\n\n## Blocked by\n\n"
            "None — #214/#215 already merged; this is the missing client half of that fix.\n\n"
            "Ref: PRD #203 (AC-5, AC-1), follow-up to #214/#215.\n")
    assert il.parse_blocked_by(body, "r/r") == [], il.parse_blocked_by(body, "r/r")

def test_merged_pr_blocker_is_satisfied():
    # Regression (#85, defect 2): a blocked-by ref pointing at a MERGED PR must count as satisfied.
    # `gh issue view <pr>` resolves the PR and returns {"state":"MERGED"}; the old `== "closed"`
    # check rejected "merged" → permanent block. A merged-PR blocker must now unblock the child.
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    il._self_login = lambda: "me"
    il.compute_state = _REAL_COMPUTE_STATE
    il._list_issues = lambda slug, extra=None: [
        {"number": 5, "title": "blocked by merged PR", "state": "OPEN", "_author": "me",
         "body": "## Blocked by\n#215\n", "_labels": {"ready-for-agent"}},
    ]
    il._has_plan = lambda slug: False
    il._plan_marker = lambda slug: None   # hermetic: never read the real repo
    il._issue_state = lambda slug, number: "merged"   # #215 is a merged PR
    s = il.compute_state("acme/widget")
    assert 5 in s["unblocked"], s

def test_open_issue_blocker_still_blocks():
    # No regression: a genuine OPEN issue blocker must still block (only closed/merged satisfy).
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    il._self_login = lambda: "me"
    il.compute_state = _REAL_COMPUTE_STATE
    il._list_issues = lambda slug, extra=None: [
        {"number": 5, "title": "blocked by open issue", "state": "OPEN", "_author": "me",
         "body": "## Blocked by\n#9\n", "_labels": {"ready-for-agent"}},
    ]
    il._has_plan = lambda slug: False
    il._plan_marker = lambda slug: None   # hermetic: never read the real repo
    il._issue_state = lambda slug, number: "open"
    s = il.compute_state("acme/widget")
    assert 5 not in s["unblocked"], s

def _write_snapshot(issues):
    # Materialise a real per-repo snapshot file and point HARNESS_SNAPSHOT_FILE at it, so the
    # snapshot read path is exercised end-to-end (no gh). Caller must pop the env in finally.
    import json, tempfile
    snap = {"schema_version": il.SNAPSHOT_SCHEMA_VERSION, "generated_at": 1, "slug": "acme/widget",
            "issues": issues, "has_plan": False, "plan_marker": None, "self_login": "me"}
    f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump(snap, f); f.close()
    os.environ["HARNESS_SNAPSHOT_FILE"] = f.name

def test_snapshot_mode_none_section_unblocks_without_gh():
    # AC2: in SNAPSHOT mode the incident issue (`## Blocked by` = "None — #214/#215 already
    # merged …") is computed unblocked even though #214/#215 are absent from the snapshot — the
    # parser harvests no refs, so there is nothing to resolve. Proven via the real snapshot read
    # path (HARNESS_SNAPSHOT_FILE set); no gh, no _issue_state stubbing.
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    il.compute_state = _REAL_COMPUTE_STATE
    il._list_issues = _REAL_LIST_ISSUES; il._issue_state = _REAL_ISSUE_STATE
    il._has_plan = _REAL_HAS_PLAN; il._plan_marker = _REAL_PLAN_MARKER
    il._self_login = lambda: "me"
    body = ("## Blocked by\n\nNone — #214/#215 already merged; missing client half of that fix.\n\n"
            "Ref: PRD #203, follow-up to #214/#215.\n")
    _write_snapshot([{"number": 216, "title": "client half", "state": "OPEN", "body": body,
                      "labels": [{"name": "ready-for-agent"}], "author": {"login": "me"}}])
    try:
        s = il.compute_state("acme/widget")
        assert 216 in s["unblocked"], s
    finally:
        os.environ.pop("HARNESS_SNAPSHOT_FILE", None)

def test_snapshot_mode_genuine_absent_ref_still_blocks():
    # AC3 (snapshot-mode behavior, defined+tested): the chosen approach records only issues in the
    # snapshot — PRs are absent. A genuine bare blocked-by ref (#215) that is absent from the
    # snapshot resolves to state "" and stays conservatively BLOCKED (err toward not-dispatching).
    # The real incident is a `None` section (covered above), so this conservative edge is moot in
    # practice; it is documented so the snapshot path's behavior is unambiguous.
    os.environ["HARNESS_MODE"] = "issue-only"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    il.compute_state = _REAL_COMPUTE_STATE
    il._list_issues = _REAL_LIST_ISSUES; il._issue_state = _REAL_ISSUE_STATE
    il._has_plan = _REAL_HAS_PLAN; il._plan_marker = _REAL_PLAN_MARKER
    il._self_login = lambda: "me"
    _write_snapshot([{"number": 5, "title": "blocked by absent ref", "state": "OPEN",
                      "body": "## Blocked by\n#215\n",
                      "labels": [{"name": "ready-for-agent"}], "author": {"login": "me"}}])
    try:
        s = il.compute_state("acme/widget")
        assert 5 not in s["unblocked"], s
    finally:
        os.environ.pop("HARNESS_SNAPSHOT_FILE", None)

def test_self_prd_blocker_special_case_unchanged():
    # AC4(d): a child whose `## Blocked by` names its OWN PRD is not really blocked — the PRD stays
    # open until review. The special-case must remain: #5 is unblocked and its PRD ref (#7) is
    # never even queried for state (the merged/closed-states change must not regress this).
    os.environ["HARNESS_MODE"] = "prd"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    il.compute_state = _REAL_COMPUTE_STATE
    il._self_login = lambda: "me"
    il._has_plan = lambda slug: False
    il._plan_marker = lambda slug: None
    il._spec_hash = lambda: ""
    il._list_issues = lambda slug, extra=None: [
        {"number": 7, "title": "[AFK] PRD: x", "state": "OPEN", "body": "", "_author": "me",
         "_labels": {"prd"}},
        {"number": 5, "title": "child blocked by own PRD", "state": "OPEN", "_author": "me",
         "body": "## Blocked by\n#7\n", "_labels": {"ready-for-agent"}},
    ]
    queried = []
    il._issue_state = lambda slug, number: (queried.append((slug, number)) or "open")
    s = il.compute_state("acme/widget")
    assert 5 in s["unblocked"], s
    assert ("acme/widget", 7) not in queried, queried   # own-PRD ref short-circuited, never queried

def test_review_does_not_refire_once_signed_off():
    # REVIEW's job is the sign-off (it applies the reviewed label). Once the PRD already carries
    # that label it must NOT re-fire — otherwise a reviewed-but-still-open PRD (the agent's close
    # didn't stick) spawns an endless series of fresh review sessions, each burning ORCH_MAXITER
    # iterations and (as a live orch session) pinning allow_orchestration so nothing else advances.
    os.environ["HARNESS_MODE"] = "planned"
    il.compute_state = lambda r: mk(prd=7, prd_open=True, children_exist=True,
                                    children_all_closed=True, prd_reviewed=False)
    assert il.dispatch("acme/widget", 3, True)[0][0] == "REVIEW", "unreviewed PRD -> REVIEW"
    il.compute_state = lambda r: mk(prd=7, prd_open=True, children_exist=True,
                                    children_all_closed=True, prd_reviewed=True)
    acts = il.dispatch("acme/widget", 3, True)
    assert all(a[0] != "REVIEW" for a in acts), f"reviewed PRD must NOT re-fire REVIEW: {acts}"

def test_engine_closes_a_reviewed_but_open_prd():
    # The deterministic fix for "PRD won't close, all children closed": once review has SIGNED OFF
    # (reviewed label set) but the PRD is still OPEN (the agent's `gh issue close` failed / was
    # rate-limited), the engine emits CLOSE_PRD and closes it itself — instant + idempotent, retried
    # every poll, no Ralph session and no rate-limit-sensitive multi-step inside an agent.
    os.environ["HARNESS_MODE"] = "planned"
    il.compute_state = lambda r: mk(prd=7, prd_open=True, children_exist=True,
                                    children_all_closed=True, prd_reviewed=True)
    assert il.dispatch("acme/widget", 3, True) == [("CLOSE_PRD", "7", "PRD CLOSED")], \
        il.dispatch("acme/widget", 3, True)
    # CLOSE_PRD is gated PER PRD (--busy-prds), not by the unit-wide allow_orchestration flag:
    # that flag is only ever set when no session is live anywhere in the unit, so gating per-PRD
    # actions on it would let one PRD's impl work block another PRD's decompose/review forever.
    assert il.dispatch("acme/widget", 3, False) == [("CLOSE_PRD", "7", "PRD CLOSED")], \
        "CLOSE_PRD is gated per-PRD, not on allow_orchestration"
    assert il.dispatch("acme/widget", 3, False, busy_prds=(7,)) == [], \
        "a PRD with a live orch session is not re-dispatched"

def test_no_close_prd_until_reviewed():
    # CLOSE_PRD must never close an UNREVIEWED PRD — that would skip the review gate entirely.
    os.environ["HARNESS_MODE"] = "planned"
    il.compute_state = lambda r: mk(prd=7, prd_open=True, children_exist=True,
                                    children_all_closed=True, prd_reviewed=False)
    acts = il.dispatch("acme/widget", 3, True)
    assert all(a[0] != "CLOSE_PRD" for a in acts), f"unreviewed PRD must not be engine-closed: {acts}"

def test_closed_prd_is_complete_even_if_reviewed_label_missing():
    # close-OK / label-fail wedge: a CLOSED PRD whose children are all closed is COMPLETE even when
    # the reviewed label never stuck. Only the review path closes a PRD, so closed ⇒ reviewed-intent;
    # requiring the label too left the unit forever-incomplete (and REVIEW could not re-fire because
    # its guard needs prd_open). The unit must finalize (and sweep its sessions) on a closed PRD.
    os.environ["HARNESS_MODE"] = "planned"
    assert il.is_complete(mk(prd=7, prd_open=False, prd_reviewed=False,
                             children_exist=True, children_all_closed=True)) is True
    # still NOT complete while the PRD is open, regardless of the reviewed label
    assert il.is_complete(mk(prd=7, prd_open=True, prd_reviewed=True,
                             children_all_closed=True)) is False

def _check(goal, state):
    """Drive issuelib's `check` CLI for <goal> against a stubbed compute_state; return DONE/PENDING."""
    import io, contextlib
    il.compute_state = lambda r: state
    argv = sys.argv; sys.argv = ["issuelib.py", "check", "acme/widget", goal]
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            il.main()
    finally:
        sys.argv = argv
    return buf.getvalue().strip()

def test_check_review_done_on_signoff_or_gaps_not_on_close():
    # A REVIEW session's work is done when it has SIGNED OFF (reviewed label) OR filed gap issues
    # (unblocked > 0) — NOT when the PRD is closed (closing is now the engine's CLOSE_PRD job). This
    # lets a review session that added the label be reaped promptly instead of lingering unkilled.
    assert _check("REVIEW", mk(prd=7, prd_open=True, prd_reviewed=True)) == "DONE", "signed off -> done"
    assert _check("REVIEW", mk(prd=7, prd_open=True, prd_reviewed=False, unblocked=[9])) == "DONE", "gaps -> done"
    assert _check("REVIEW", mk(prd=7, prd_open=True, prd_reviewed=False, unblocked=[])) == "PENDING", \
        "neither signed off nor gaps -> still working"

def test_check_close_prd_done_when_prd_closed():
    assert _check("CLOSE_PRD", mk(prd=7, prd_open=False)) == "DONE"
    assert _check("CLOSE_PRD", mk(prd=7, prd_open=True)) == "PENDING"

# ── gh-error vs empty/absent (#1/#2/#3): a transient gh failure (rate-limit/network) must NEVER be
# folded into "empty repo / no plan", which spuriously re-fires PLAN and (in poller mode) clobbers a
# good snapshot. Errors raise GhError -> the worker HOLDS the tick; only genuinely empty/absent
# (exit 0 with [], or HTTP 404) proceeds. Earlier tests stub read seams without restoring, so each
# test below restores the real implementation it exercises.
def _fake_run(returncode=0, stdout="", stderr=""):
    def run(*a, **k):
        return il.subprocess.CompletedProcess(a[0] if a else [], returncode, stdout, stderr)
    return run

def test_list_issues_raises_on_gh_failure_not_empty():
    GhError = getattr(il, "GhError", RuntimeError)
    os.environ.pop("HARNESS_SNAPSHOT_FILE", None)
    il._list_issues = _REAL_LIST_ISSUES
    real = il.subprocess.run
    il.subprocess.run = _fake_run(returncode=1, stderr="gh: API rate limit exceeded (HTTP 403)")
    try:
        try:
            il._list_issues("acme/widget")
            assert False, "rate-limited `gh issue list` must raise GhError, not return []"
        except GhError:
            pass
    finally:
        il.subprocess.run = real

def test_empty_repo_still_reads_as_empty_not_error():
    os.environ.pop("HARNESS_SNAPSHOT_FILE", None)
    il._list_issues = _REAL_LIST_ISSUES
    real = il.subprocess.run
    il.subprocess.run = _fake_run(returncode=0, stdout="[]")
    try:
        assert il._list_issues("acme/widget") == [], "exit 0 + [] is a legitimately empty repo"
    finally:
        il.subprocess.run = real

def test_has_plan_treats_404_as_absent_but_403_as_error():
    GhError = getattr(il, "GhError", RuntimeError)
    os.environ.pop("HARNESS_SNAPSHOT_FILE", None)
    il._has_plan = _REAL_HAS_PLAN
    real = il.subprocess.run
    try:
        il.subprocess.run = _fake_run(returncode=1, stderr="gh: Not Found (HTTP 404)")
        assert il._has_plan("acme/widget") is False, "genuine 404 = PLAN.md absent (legit, not error)"
        il.subprocess.run = _fake_run(returncode=1, stderr="gh: API rate limit exceeded (HTTP 403)")
        try:
            il._has_plan("acme/widget")
            assert False, "rate-limited contents read must raise GhError, not report 'no plan'"
        except GhError:
            pass
    finally:
        il.subprocess.run = real

def test_dispatch_cli_holds_on_gh_error_no_spurious_plan():
    # The bash-facing contract: on a transient gh failure the `dispatch` command must print NO action
    # lines and exit non-zero, so dispatch_actions (lib.sh) gets empty output and the worker holds --
    # instead of emitting a PLAN action computed from a false-empty state. Runs in a clean subprocess
    # (immune to in-process seam pollution) with a fake `gh` that simulates a 403.
    import tempfile, subprocess as _subp
    d = tempfile.mkdtemp()
    gh = os.path.join(d, "gh")
    with open(gh, "w") as f:
        f.write("#!/usr/bin/env bash\necho 'gh: API rate limit exceeded (HTTP 403)' >&2\nexit 1\n")
    os.chmod(gh, 0o755)
    env = dict(os.environ, PATH=d + os.pathsep + os.environ.get("PATH", ""), HARNESS_MODE="planned")
    env.pop("HARNESS_SNAPSHOT_FILE", None); env.pop("HARNESS_SNAPSHOT_DIR", None)
    il_path = os.path.join(HERE, "..", "scripts", "issuelib.py")
    r = _subp.run([sys.executable, il_path, "dispatch", "acme/widget", "3"],
                  capture_output=True, text=True, env=env)
    assert r.returncode != 0, "dispatch must exit non-zero on gh error; got rc=%d out=%r" % (r.returncode, r.stdout)
    assert r.stdout.strip() == "", "dispatch must print NO actions on gh error; got %r" % r.stdout

# ── #104: `gh issue list --limit N` caps the TOTAL rows fetched (created-DESCENDING), so on a repo
# with >N issues the OLDEST/lowest-numbered silently drop off — exactly where the PRD and long-lived
# open children live. The fix fetches the full set; these tests reproduce truncation with a fake `gh`
# that honors --limit like real gh.
def _fake_gh_list(issues_payload):
    """Fake il.subprocess.run mimicking `gh issue list`: exits 0 and returns at most `--limit` issues
    in created-DESCENDING order (highest number = newest first), exactly as real gh, so a too-small
    --limit truncates the OLDEST issues off the tail."""
    def run(*a, **k):
        argv = a[0] if a else []
        limit = None
        for i, tok in enumerate(argv):
            if tok == "--limit" and i + 1 < len(argv):
                limit = int(argv[i + 1])
        ordered = sorted(issues_payload, key=lambda it: it["number"], reverse=True)
        if limit is not None:
            ordered = ordered[:limit]
        return il.subprocess.CompletedProcess(argv, 0, il.json.dumps(ordered), "")
    return run

def test_issues_past_200_survive_pagination_cap():
    # PRD = #1 (oldest), an open ready child = #2; both sit below the newest-200 window of a 250-issue
    # repo. The old --limit 200 dropped them, flipping prd -> None and losing the open child. The fix
    # fetches the whole set, so compute_state still reports the PRD and counts the old open child.
    os.environ["HARNESS_MODE"] = "prd"
    os.environ["HARNESS_AUTONOMOUS"] = "true"
    os.environ.pop("HARNESS_AUTHOR_ALLOWLIST", None)
    os.environ.pop("HARNESS_SNAPSHOT_FILE", None)
    il.compute_state = _REAL_COMPUTE_STATE
    il._list_issues = _REAL_LIST_ISSUES
    il._self_login = lambda: "me"
    il._has_plan = lambda slug: False
    il._plan_marker = lambda slug: None
    il._spec_hash = lambda: ""
    payload = [{"number": 1, "title": "[AFK] PRD: x", "state": "OPEN", "body": "",
                "labels": [{"name": "prd"}], "author": {"login": "me"}},
               {"number": 2, "title": "old open child", "state": "OPEN", "body": "",
                "labels": [{"name": "ready-for-agent"}], "author": {"login": "me"}}]
    payload += [{"number": n, "title": f"noise {n}", "state": "CLOSED", "body": "",
                 "labels": [], "author": {"login": "me"}} for n in range(3, 251)]
    real = il.subprocess.run
    il.subprocess.run = _fake_gh_list(payload)
    try:
        s = il.compute_state("acme/widget")
        assert s["prd"] == 1, f"PRD #1 (oldest) must survive the fetch, got prd={s['prd']!r}"
        assert 2 in s["unblocked"], f"old open child #2 must be in unblocked: {s}"
        assert s["total_children"] == 1, s
    finally:
        il.subprocess.run = real

def test_fetch_warns_when_issue_list_cap_hit():
    # If any finite cap remains, a fetch returning at/above it logs a LOUD stderr warning, so silent
    # truncation can never masquerade as "fewer issues". Monkeypatch the cap small + feed that many rows.
    import io, contextlib
    os.environ.pop("HARNESS_SNAPSHOT_FILE", None)
    real_cap = il._ISSUE_LIST_CAP
    real = il.subprocess.run
    payload = [{"number": n, "title": "x", "state": "OPEN", "body": "",
                "labels": [], "author": {"login": "me"}} for n in range(1, 4)]
    il._ISSUE_LIST_CAP = 3
    il.subprocess.run = _fake_gh_list(payload)
    buf = io.StringIO()
    try:
        with contextlib.redirect_stderr(buf):
            il._fetch_issues("acme/widget")
        assert "cap" in buf.getvalue().lower(), \
            f"expected cap-hit warning on stderr, got {buf.getvalue()!r}"
    finally:
        il.subprocess.run = real; il._ISSUE_LIST_CAP = real_cap


# ── default-branch CI health (#50) ────────────────────────────────────────────────────────────
# ci_status decides whether the pool may claim new work, so its FAIL-OPEN edges matter more than
# its happy path: every ambiguous input must read `unknown`, and only a positively-failed most
# recent COMPLETED run may read `fail`. Stubs both gh seams — no network, no Actions run.
def _with_runs(runs, branch="main"):
    """Install stubs so ci_status sees <runs> on <branch>; returns a restore callable."""
    real_api, real_json = il._gh_api_read, il._gh_json
    il._gh_api_read = lambda path, jq: branch
    il._gh_json = lambda args, allow_absent=False: runs
    def restore():
        il._gh_api_read, il._gh_json = real_api, real_json
    return restore

def _run(wf, status="completed", conclusion="success", url="u"):
    return {"workflowName": wf, "status": status, "conclusion": conclusion, "url": url}

def test_ci_status_green_and_red():
    r = _with_runs([_run("ci")])
    try:
        assert il.ci_status("acme/widget")[0] == "pass"
    finally: r()
    r = _with_runs([_run("ci", conclusion="failure", url="U1")])
    try:
        verdict, wf, url = il.ci_status("acme/widget")
        # The banner is only actionable if the failing workflow and run come back with the verdict.
        assert (verdict, wf, url) == ("fail", "ci", "U1"), (verdict, wf, url)
    finally: r()

def test_ci_status_unknown_is_the_default_everywhere():
    for runs, why in [([], "no runs on the branch"),
                      (None, "Actions not configured (gh absent-read)"),
                      ([_run("ci", status="in_progress", conclusion=None)], "nothing completed yet")]:
        r = _with_runs(runs)
        try: assert il.ci_status("acme/widget")[0] == "unknown", why
        finally: r()
    # No default branch resolvable => unknown, and crucially NO run-list call is attempted.
    real_api, real_json = il._gh_api_read, il._gh_json
    il._gh_api_read = lambda path, jq: ""
    il._gh_json = lambda *a, **k: (_ for _ in ()).throw(AssertionError("must not list runs"))
    try: assert il.ci_status("acme/widget")[0] == "unknown"
    finally: il._gh_api_read, il._gh_json = real_api, real_json

def test_ci_status_reads_only_each_workflows_latest_completed_run():
    # gh lists newest-first. A stale red run behind a fresh green one must NOT make the branch red,
    # or a branch would stay gated forever on a failure that has already been fixed.
    r = _with_runs([_run("ci"), _run("ci", conclusion="failure")])
    try: assert il.ci_status("acme/widget")[0] == "pass"
    finally: r()
    # An in-flight run must not mask the last verdict either — it is not evidence in either direction.
    r = _with_runs([_run("ci", status="in_progress", conclusion=None), _run("ci", conclusion="failure")])
    try: assert il.ci_status("acme/widget")[0] == "fail"
    finally: r()
    # ANY workflow red makes the branch red, even when another is green.
    r = _with_runs([_run("lint"), _run("ci", conclusion="timed_out")])
    try: assert il.ci_status("acme/widget")[:2] == ("fail", "ci")
    finally: r()

def test_ci_status_only_known_failure_conclusions_gate():
    # Conclusions that are not a real failure must never stall a fleet. `cancelled` especially:
    # it is what a human pressing stop looks like, and it is not a statement about the code.
    for c in ("success", "skipped", "neutral", "cancelled", "stale", "some_future_conclusion"):
        r = _with_runs([_run("ci", conclusion=c)])
        try: assert il.ci_status("acme/widget")[0] == "pass", c
        finally: r()
    for c in ("failure", "timed_out", "startup_failure", "action_required"):
        r = _with_runs([_run("ci", conclusion=c)])
        try: assert il.ci_status("acme/widget")[0] == "fail", c
        finally: r()

def test_ci_status_replays_the_incident_that_filed_50():
    # Real `gh run list --branch main` rows from VocanicZ/hardcore-gacha-2, newest-first, captured
    # over the window in #50 where four PRs merged onto a red main and nothing noticed for eleven
    # hours. Replayed as the fleet would have seen it after EACH of those merges: the gate must
    # read `fail` at every point between the first red merge and the fix, so the second merge is
    # the last one that could have happened.
    W = "ci"
    hist = [   # (sha, conclusion) newest-first, as of the moment the fix landed
        ("8914b78", "success"), ("f995560", "failure"), ("5091617", "failure"),
        ("2342a40", "failure"), ("d9929a2", "failure"), ("a92f43b", "success"),
    ]
    def rows(since):   # what gh returned right after `since` merged
        return [_run(W, conclusion=c, url=f"https://github.com/VocanicZ/hardcore-gacha-2/{s}")
                for s, c in hist[hist.index(next(h for h in hist if h[0] == since)):]]
    for sha in ("d9929a2", "2342a40", "5091617", "f995560"):
        r = _with_runs(rows(sha))
        try: assert il.ci_status("VocanicZ/hardcore-gacha-2")[0] == "fail", f"after {sha}"
        finally: r()
    # a92f43b is the last green before the run — the gate must NOT have been holding then, or it
    # would have stalled the fleet for the eleven hours BEFORE the breakage.
    r = _with_runs(rows("a92f43b"))
    try: assert il.ci_status("VocanicZ/hardcore-gacha-2")[0] == "pass"
    finally: r()
    # ...and 8914b78 (the #49 SDK pin) turns it green again with no human touching the gate.
    r = _with_runs(rows("8914b78"))
    try: assert il.ci_status("VocanicZ/hardcore-gacha-2")[0] == "pass"
    finally: r()

def test_ci_status_holds_on_transient_gh_failure():
    # A rate limit must raise, not read as "no runs" (which the CLI turns into empty stdout, which
    # the bash gate reads as "do not gate"). Either way the fleet keeps moving — but the distinction
    # must be visible here rather than silently folded into `unknown`.
    real_api, real_json = il._gh_api_read, il._gh_json
    il._gh_api_read = lambda path, jq: "main"
    def boom(args, allow_absent=False): raise il.GhError("HTTP 403 rate limit")
    il._gh_json = boom
    try:
        try:
            il.ci_status("acme/widget"); assert False, "expected GhError"
        except il.GhError: pass
    finally: il._gh_api_read, il._gh_json = real_api, real_json


# ── completion requires no open ready child ───────────────────────────────────────────────────
def test_a_closed_prd_does_not_complete_a_unit_with_an_open_ready_child():
    # The #80 shape: review signs off, files a non-blocking follow-up, and closes the PRD itself in
    # the same pass. CLOSE_PRD is gated on children_all_closed; an agent-side `gh issue close` is
    # not. If completion keyed on the close alone, claimable_units would drop the unit and
    # drive_unit — the only caller of dispatch_actions — would never run again, stranding the child.
    os.environ["HARNESS_MODE"] = "prd"
    stranded = mk(prd=61, prd_open=False, prd_reviewed=True, children_exist=True,
                  children_all_closed=False, open_children=1, total_children=9, unblocked=[80])
    assert il.is_complete(stranded) is False, "an open ready child must keep the unit claimable"
    # ...and the work is still reachable, which is the whole point of staying incomplete.
    il.compute_state = lambda r: stranded
    assert il.dispatch("acme/widget", 3, True) == [("IMPL", "80", "ISSUE 80 DONE")]

def test_completion_is_unchanged_on_every_path_that_was_already_correct():
    os.environ["HARNESS_MODE"] = "prd"
    # the ordinary end state: PRD closed, every child closed
    assert il.is_complete(mk(prd=7, prd_open=False, prd_reviewed=True, children_exist=True,
                             children_all_closed=True, open_children=0, total_children=4)) is True
    # signed off with no children at all (a PRD that decomposed to nothing)
    assert il.is_complete(mk(prd=7, prd_open=False, prd_reviewed=True)) is True
    # an OPEN PRD is never complete, whatever its children look like
    assert il.is_complete(mk(prd=7, prd_open=True, prd_reviewed=True, children_exist=True,
                             children_all_closed=True, open_children=0)) is False
    # the close-OK/label-fail case this predicate was written for still completes
    assert il.is_complete(mk(prd=7, prd_open=False, prd_reviewed=False, children_exist=True,
                             children_all_closed=True, open_children=0)) is True
    # no PRD at all in prd mode is never complete
    assert il.is_complete(mk(prd=None, open_children=0)) is False

def test_an_unclaimable_open_child_holds_the_unit_rather_than_faking_success():
    # The accepted cost of the guard, pinned deliberately so it is a decision and not a surprise:
    # a child that is open but NOT dispatchable — blocked by an unclosed dep, or agent-blocked on a
    # non-autonomous fleet — leaves the unit incomplete with nothing to dispatch. drive.sh's
    # dispatch_stalled_banner exists to make exactly this state audible.
    os.environ["HARNESS_MODE"] = "prd"
    held = mk(prd=7, prd_open=False, prd_reviewed=True, children_exist=True,
              children_all_closed=False, open_children=1, total_children=3, unblocked=[])
    assert il.is_complete(held) is False
    il.compute_state = lambda r: held
    assert il.dispatch("acme/widget", 3, True) == [], "nothing to dispatch, and it must not fake one"

def test_issue_only_completion_is_untouched():
    # issue-only has always required open_children == 0; this change makes prd/planned agree with
    # it, and must not perturb it.
    os.environ["HARNESS_MODE"] = "issue-only"
    assert il.is_complete(mk(children_exist=True, open_children=0, unblocked=[])) is True
    assert il.is_complete(mk(children_exist=True, open_children=1, unblocked=[5])) is False
    assert il.is_complete(mk(children_exist=False, open_children=0, unblocked=[])) is False

def test_parse_parent_section_form():
    b = "Do the thing.\n\n## Parent\n#41\n\n## Blocked by\nNone\n"
    assert il.parse_parent(b, "acme/widget") == ("acme/widget", 41)

def test_parse_parent_cross_repo_ref():
    b = "## Parent\nother/repo#7\n"
    assert il.parse_parent(b, "acme/widget") == ("other/repo", 7)

def test_parse_parent_none_section_is_unparented():
    b = "## Parent\nNone\n"
    assert il.parse_parent(b, "acme/widget") is None

def test_parse_parent_falls_back_to_part_of_trailer():
    # every child filed by the CURRENT decompose.md looks like this — no ## Parent section
    b = "Body text\n\n## Blocked by\nNone\n\nPart of #12\n"
    assert il.parse_parent(b, "acme/widget") == ("acme/widget", 12)

def test_parse_parent_section_wins_over_trailer():
    b = "## Parent\n#41\n\nPart of #12\n"
    assert il.parse_parent(b, "acme/widget") == ("acme/widget", 41)

def test_parse_parent_absent_and_empty():
    assert il.parse_parent("no refs at all", "acme/widget") is None
    assert il.parse_parent("", "acme/widget") is None
    assert il.parse_parent(None, "acme/widget") is None

def test_parse_parent_does_not_harvest_blocked_by():
    # a `## Blocked by` ref must NEVER be mistaken for a parent
    b = "## Blocked by\n#99\n"
    assert il.parse_parent(b, "acme/widget") is None


def _issue(n, state="OPEN", labels=(), body="", title="", author="bot"):
    return {"number": n, "state": state, "title": title, "body": body,
            "_labels": list(labels), "_author": author,
            "labels": [{"name": l} for l in labels], "author": {"login": author}}

def _stub_repo(issues):
    """Point compute_state at a fixed issue list, bypassing gh entirely."""
    il.compute_state = _REAL_COMPUTE_STATE   # undo any prior stub
    il._list_issues = lambda slug, extra=None: issues
    il._has_plan = lambda slug: False
    il._plan_marker = lambda slug: None
    il._author_filter = lambda xs: xs
    il._issue_state = lambda slug, n: next(
        (i["state"].lower() for i in issues if i["number"] == n), "")

def _restore_repo():
    il._list_issues, il._has_plan = _REAL_LIST_ISSUES, _REAL_HAS_PLAN
    il._plan_marker, il._issue_state = _REAL_PLAN_MARKER, _REAL_ISSUE_STATE
    il._author_filter = _REAL_AUTHOR_FILTER

def test_prds_lists_every_prd_ascending():
    os.environ["HARNESS_MODE"] = "prd"
    _stub_repo([_issue(20, labels=["prd"]), _issue(10, labels=["prd"]),
                _issue(15, title="[AFK] PRD: third")])
    try:
        s = il.compute_state("acme/widget")
        assert [p["number"] for p in s["prds"]] == [10, 15, 20], s["prds"]
    finally: _restore_repo()

def test_legacy_scalars_derive_from_lowest_prd():
    os.environ["HARNESS_MODE"] = "prd"
    _stub_repo([_issue(20, labels=["prd"]), _issue(10, labels=["prd", "reviewed"])])
    try:
        s = il.compute_state("acme/widget")
        assert s["prd"] == 10, s["prd"]
        assert s["prd_open"] is True, s
        assert s["prd_reviewed"] is True, s
    finally: _restore_repo()

def test_prds_empty_when_no_prd_issue():
    os.environ["HARNESS_MODE"] = "prd"
    _stub_repo([_issue(3, labels=["ready-for-agent"])])
    try:
        s = il.compute_state("acme/widget")
        assert s["prds"] == [], s["prds"]
        assert s["prd"] is None, s
    finally: _restore_repo()

def test_children_partition_by_parent():
    os.environ["HARNESS_MODE"] = "prd"
    _stub_repo([
        _issue(10, labels=["prd"]), _issue(20, labels=["prd"]),
        _issue(11, labels=["ready-for-agent"], body="## Parent\n#10\n"),
        _issue(12, labels=["ready-for-agent"], body="## Parent\n#10\n"),
        _issue(21, labels=["ready-for-agent"], body="Part of #20\n"),
    ])
    try:
        s = il.compute_state("acme/widget")
        by_num = {p["number"]: p for p in s["prds"]}
        assert by_num[10]["unblocked"] == [11, 12], by_num[10]
        assert by_num[20]["unblocked"] == [21], by_num[20]
        assert s["unparented_unblocked"] == [], s
    finally: _restore_repo()

def test_unattributed_child_lands_in_unparented_bucket():
    os.environ["HARNESS_MODE"] = "prd"
    _stub_repo([
        _issue(10, labels=["prd"]),
        _issue(11, labels=["ready-for-agent"], body="## Parent\n#10\n"),
        _issue(99, labels=["ready-for-agent"], body="an injected issue, no parent"),
        _issue(98, labels=["ready-for-agent"], body="## Parent\n#404\n"),   # PRD does not exist
        _issue(97, labels=["ready-for-agent"], body="## Parent\nother/repo#1\n"),  # foreign repo
    ])
    try:
        s = il.compute_state("acme/widget")
        assert s["unparented_unblocked"] == [99, 98, 97], s["unparented_unblocked"]
        assert s["open_unparented"] == 3, s
    finally: _restore_repo()

def test_unparented_child_does_not_gate_a_prds_review():
    """The latent bug: an injected issue used to sit in the flat children list and keep
    children_all_closed False, stalling review of an unrelated PRD."""
    os.environ["HARNESS_MODE"] = "prd"
    _stub_repo([
        _issue(10, labels=["prd"]),
        _issue(11, "CLOSED", labels=["ready-for-agent"], body="## Parent\n#10\n"),
        _issue(99, labels=["ready-for-agent"], body="injected, unrelated"),
    ])
    try:
        s = il.compute_state("acme/widget")
        prd10 = s["prds"][0]
        assert prd10["children_all_closed"] is True, prd10
    finally: _restore_repo()

def test_bug_lane_issues_stay_out_of_every_bucket():
    os.environ["HARNESS_MODE"] = "prd"
    _stub_repo([
        _issue(10, labels=["prd"]),
        _issue(11, labels=["ready-for-agent", "bug"], body="## Parent\n#10\n"),
        _issue(12, labels=["ready-for-agent", "bug-triaged"]),
    ])
    try:
        s = il.compute_state("acme/widget")
        assert s["prds"][0]["unblocked"] == [], s["prds"][0]
        assert s["unparented_unblocked"] == [], s
    finally: _restore_repo()

def test_prd_with_no_blocked_by_is_eligible_immediately():
    os.environ["HARNESS_MODE"] = "prd"
    _stub_repo([_issue(10, labels=["prd"], body="scope"),
                _issue(20, labels=["prd"], body="## Blocked by\nNone\n")])
    try:
        s = il.compute_state("acme/widget")
        assert all(p["eligible"] for p in s["prds"]), s["prds"]
    finally: _restore_repo()

def test_prd_blocked_by_open_prd_is_not_eligible():
    os.environ["HARNESS_MODE"] = "prd"
    _stub_repo([_issue(10, labels=["prd"]),
                _issue(20, labels=["prd"], body="## Blocked by\n#10\n")])
    try:
        s = il.compute_state("acme/widget")
        by_num = {p["number"]: p for p in s["prds"]}
        assert by_num[10]["eligible"] is True, by_num[10]
        assert by_num[20]["eligible"] is False, by_num[20]
    finally: _restore_repo()

def test_prd_becomes_eligible_once_its_blocker_closes():
    os.environ["HARNESS_MODE"] = "prd"
    _stub_repo([_issue(10, "CLOSED", labels=["prd"]),
                _issue(20, labels=["prd"], body="## Blocked by\n#10\n")])
    try:
        s = il.compute_state("acme/widget")
        by_num = {p["number"]: p for p in s["prds"]}
        assert by_num[20]["eligible"] is True, by_num[20]
    finally: _restore_repo()

def test_prd_chain_of_three_releases_one_at_a_time():
    os.environ["HARNESS_MODE"] = "prd"
    _stub_repo([_issue(10, labels=["prd"]),
                _issue(20, labels=["prd"], body="## Blocked by\n#10\n"),
                _issue(30, labels=["prd"], body="## Blocked by\n#20\n")])
    try:
        s = il.compute_state("acme/widget")
        assert [p["eligible"] for p in s["prds"]] == [True, False, False], s["prds"]
    finally: _restore_repo()


def test_dispatch_fills_lowest_prd_first():
    os.environ["HARNESS_MODE"] = "prd"
    il.compute_state = lambda r: mk(prd=10, prd_open=True,
                                    prds=[prd(10, [11, 12, 13]), prd(20, [21, 22])])
    try:
        acts = il.dispatch("acme/widget", 2, True)
        assert [a[1] for a in acts] == ["11", "12"], acts
    finally: il.compute_state = _REAL_COMPUTE_STATE

def test_dispatch_spills_into_next_prd_when_first_runs_dry():
    os.environ["HARNESS_MODE"] = "prd"
    il.compute_state = lambda r: mk(prd=10, prd_open=True,
                                    prds=[prd(10, [11]), prd(20, [21, 22])])
    try:
        acts = il.dispatch("acme/widget", 3, True)
        assert [a[1] for a in acts] == ["11", "21", "22"], acts
    finally: il.compute_state = _REAL_COMPUTE_STATE

def test_dispatch_skips_ineligible_prd_entirely():
    os.environ["HARNESS_MODE"] = "prd"
    il.compute_state = lambda r: mk(prd=10, prd_open=True,
                                    prds=[prd(10, [11]), prd(20, [21], eligible=False)])
    try:
        acts = il.dispatch("acme/widget", 5, True)
        assert [a[1] for a in acts] == ["11"], acts
    finally: il.compute_state = _REAL_COMPUTE_STATE

def test_dispatch_serves_unparented_bucket_first():
    os.environ["HARNESS_MODE"] = "prd"
    il.compute_state = lambda r: mk(prd=10, prd_open=True, prds=[prd(10, [11, 12])],
                                    unparented_unblocked=[99])
    try:
        acts = il.dispatch("acme/widget", 2, True)
        assert [a[1] for a in acts] == ["99", "11"], acts
    finally: il.compute_state = _REAL_COMPUTE_STATE

def test_dispatch_decomposes_each_prd_independently():
    os.environ["HARNESS_MODE"] = "prd"
    il.compute_state = lambda r: mk(prd=10, prd_open=True,
                                    prds=[prd(10, [11]), prd(20, children_exist=False)])
    try:
        acts = il.dispatch("acme/widget", 3, True)
        assert acts[0] == ("DECOMPOSE", "20", "DECOMPOSE DONE"), acts
    finally: il.compute_state = _REAL_COMPUTE_STATE

def test_dispatch_reviews_one_prd_while_another_still_implements():
    os.environ["HARNESS_MODE"] = "prd"
    il.compute_state = lambda r: mk(prd=10, prd_open=True,
                                    prds=[prd(10, [], children_all_closed=True), prd(20, [21])])
    try:
        acts = il.dispatch("acme/widget", 3, True)
        assert ("IMPL", "21", "ISSUE 21 DONE") in acts, acts
        assert ("REVIEW", "10", "REVIEW DONE") in acts, acts
    finally: il.compute_state = _REAL_COMPUTE_STATE

def test_single_prd_dispatch_is_byte_identical_to_legacy():
    """The regression guard for the live fleets: one PRD, no unparented children, the full
    PLAN → PRD → DECOMPOSE → IMPL → REVIEW → CLOSE_PRD sequence, exact tuples."""
    os.environ["HARNESS_MODE"] = "planned"
    cases = [
        (mk(prd=None, has_plan=False), [("PLAN", "-", "PLAN DONE")]),
        (mk(prd=None, has_plan=True), [("PRD", "-", "PRD DONE")]),
        (mk(prd=7, prd_open=True, has_plan=True, children_exist=False),
         [("DECOMPOSE", "7", "DECOMPOSE DONE")]),
        (mk(prd=7, prd_open=True, has_plan=True, children_exist=True, unblocked=[8, 9]),
         [("IMPL", "8", "ISSUE 8 DONE"), ("IMPL", "9", "ISSUE 9 DONE")]),
        (mk(prd=7, prd_open=True, has_plan=True, children_exist=True, children_all_closed=True),
         [("REVIEW", "7", "REVIEW DONE")]),
        (mk(prd=7, prd_open=True, prd_reviewed=True, has_plan=True, children_exist=True,
            children_all_closed=True), [("CLOSE_PRD", "7", "PRD CLOSED")]),
    ]
    try:
        for state, want in cases:
            il.compute_state = lambda r, _s=state: _s
            assert il.dispatch("acme/widget", 3, True) == want, (state, want)
    finally: il.compute_state = _REAL_COMPUTE_STATE

def test_busy_prd_is_not_decomposed_again():
    os.environ["HARNESS_MODE"] = "prd"
    il.compute_state = lambda r: mk(prd=10, prd_open=True,
                                    prds=[prd(10, children_exist=False)])
    try:
        assert il.dispatch("acme/widget", 3, True) == [("DECOMPOSE", "10", "DECOMPOSE DONE")]
        assert il.dispatch("acme/widget", 3, True, busy_prds=(10,)) == []
    finally: il.compute_state = _REAL_COMPUTE_STATE

def test_busy_prd_is_not_reviewed_again_but_siblings_still_are():
    os.environ["HARNESS_MODE"] = "prd"
    il.compute_state = lambda r: mk(prd=10, prd_open=True,
                                    prds=[prd(10, children_all_closed=True),
                                          prd(20, children_all_closed=True)])
    try:
        acts = il.dispatch("acme/widget", 3, True, busy_prds=(10,))
        assert acts == [("REVIEW", "20", "REVIEW DONE")], acts
    finally: il.compute_state = _REAL_COMPUTE_STATE

def test_cli_dispatch_parses_busy_prds(capsys=None):
    """The CLI contract drive.sh depends on: --busy-prds is optional and comma-separated."""
    import io, contextlib
    os.environ["HARNESS_MODE"] = "prd"
    il.compute_state = lambda r: mk(prd=10, prd_open=True, prds=[prd(10, children_exist=False)])
    real_argv = sys.argv
    try:
        for argv, want in [
            (["issuelib.py", "dispatch", "acme/widget", "3", "--allow-orchestration", "1"],
             "DECOMPOSE\t10\tDECOMPOSE DONE"),
            (["issuelib.py", "dispatch", "acme/widget", "3", "--allow-orchestration", "1",
              "--busy-prds", "10"], ""),
            (["issuelib.py", "dispatch", "acme/widget", "3", "--allow-orchestration", "1",
              "--busy-prds", ""], "DECOMPOSE\t10\tDECOMPOSE DONE"),
        ]:
            sys.argv = argv
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf): il.main()
            assert buf.getvalue().strip() == want, (argv, buf.getvalue())
    finally:
        sys.argv = real_argv; il.compute_state = _REAL_COMPUTE_STATE


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)
