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

def mk(**kw):
    base = dict(slug="acme/widget", has_plan=False, prd=None, prd_open=False, prd_reviewed=False,
                children_exist=False, children_all_closed=False, unblocked=[], open_children=0, total_children=0,
                plan_marker_matches=False)
    base.update(kw); return base

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
    # CLOSE_PRD is an orchestration action: it must NOT fire while impl work is in flight.
    assert il.dispatch("acme/widget", 3, False) == [], "CLOSE_PRD gated on allow_orchestration"

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

if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)
