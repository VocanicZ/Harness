import importlib.util, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("issuelib", os.path.join(HERE, "..", "scripts", "issuelib.py"))
il = importlib.util.module_from_spec(spec); spec.loader.exec_module(il)
# #183: the rate-limit guard writes host state ($HARNESS_HOME/ghrate) on a rate-limited gh read, and
# several tests below simulate exactly that. A live fleet exports HARNESS_GH_RATE_GUARD=1 to every
# session, so drop it: only the #183 tests turn it on, against a throwaway dir.
os.environ.pop("HARNESS_GH_RATE_GUARD", None)
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
        sys.argv = argv; il.compute_state = _REAL_COMPUTE_STATE
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

def test_check_qualified_goals_resolve_against_the_named_prd():
    os.environ["HARNESS_MODE"] = "prd"
    s = mk(prd=10, prds=[prd(10, children_exist=True), prd(20, children_exist=False)])
    assert _check("DECOMPOSE:10", s) == "DONE"
    assert _check("DECOMPOSE:20", s) == "PENDING"

def test_check_qualified_review_and_close():
    os.environ["HARNESS_MODE"] = "prd"
    s = mk(prd=10, prds=[prd(10, reviewed=True, open=True), prd(20, reviewed=False, open=False)])
    assert _check("REVIEW:10", s) == "DONE"
    assert _check("REVIEW:20", s) == "PENDING"
    assert _check("CLOSE_PRD:20", s) == "DONE"
    assert _check("CLOSE_PRD:10", s) == "PENDING"

def test_check_unqualified_goals_still_resolve_against_lowest_prd():
    """In-flight sessions launched by the pre-upgrade engine wrote bare goals."""
    os.environ["HARNESS_MODE"] = "prd"
    s = mk(prd=10, prds=[prd(10, children_exist=True, reviewed=True)])
    assert _check("DECOMPOSE", s) == "DONE"
    assert _check("REVIEW", s) == "DONE"

def test_check_unknown_prd_number_is_pending_not_a_crash():
    os.environ["HARNESS_MODE"] = "prd"
    s = mk(prd=10, prds=[prd(10)])
    assert _check("REVIEW:404", s) == "PENDING"

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
    # Multi-PRD names the bucket the follow-up lands in: review files it with no `## Parent`, so it
    # sits in the UNPARENTED bucket and clause 3 of the completion rule is what holds the unit.
    os.environ["HARNESS_MODE"] = "prd"
    stranded = mk(prd=61, prd_open=False, prd_reviewed=True, children_exist=True,
                  children_all_closed=True, open_children=1, total_children=9,
                  prds=[prd(61, open=False, reviewed=True, children_all_closed=True)],
                  unparented_unblocked=[80], open_unparented=1)
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
              children_all_closed=True, open_children=1, total_children=3,
              prds=[prd(7, open=False, reviewed=True, children_all_closed=True)],
              unparented_unblocked=[], open_unparented=1)
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


# ── multi-PRD completion ──────────────────────────────────────────────────────────────────────
# The legacy scalars in these fixtures describe the FIRST PRD only — exactly what an engine that
# knew about one PRD would have recorded — so each one reads as complete to the legacy predicate
# and the assertion pins the multi-PRD clause that must override it.
def test_not_complete_while_a_second_prd_is_open():
    os.environ["HARNESS_MODE"] = "prd"
    s = mk(prd=10, prd_open=False, prd_reviewed=True,
           prds=[prd(10, open=False, reviewed=True, children_all_closed=True),
                 prd(20, open=True)])
    assert il.is_complete(s) is False, s

def test_complete_when_every_prd_is_closed():
    os.environ["HARNESS_MODE"] = "prd"
    s = mk(prd=10, prds=[prd(10, open=False, reviewed=True, children_all_closed=True),
                         prd(20, open=False, reviewed=True, children_all_closed=True)])
    assert il.is_complete(s) is True, s

def test_not_complete_with_an_open_unparented_child():
    """An issue injected after the PRD closed used to be stranded: drive_unit's loop had already
    exited on unit_complete, so the resident worker idled straight past it."""
    os.environ["HARNESS_MODE"] = "prd"
    s = mk(prd=10, prd_open=False, prd_reviewed=True,
           prds=[prd(10, open=False, reviewed=True, children_all_closed=True)],
           unparented_unblocked=[99], open_unparented=1)
    assert il.is_complete(s) is False, s

def test_not_complete_with_no_prd_at_all():
    os.environ["HARNESS_MODE"] = "prd"
    assert il.is_complete(mk(prd=None, prds=[])) is False

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



# ── incremental board cache (#182) ────────────────────────────────────────────────────────────
# A fake GitHub behind subprocess.run: it answers the full-fetch calls (`gh issue list`, `gh issue
# view`, `gh api user`, the contents reads) AND the conditional REST calls (`gh api -i … -H
# If-None-Match`) from ONE in-memory board, so a cache built from deltas can be compared with a full
# fetch of the same board. Every call is recorded with whether it was a free 304.
import json as _json, random as _random, base64 as _b64, hashlib as _hashlib
from urllib.parse import urlsplit as _urlsplit, parse_qs as _parse_qs

class _FakeGitHub:
    LABELS = ["ready-for-agent", "prd", "agent-working", "agent-blocked", "bug", "reviewed", "agent-paused"]

    def __init__(self, rnd, page=4):
        self.rnd, self.page, self.tick = rnd, page, 0
        self.boards = {"acme/widget": {}, "acme/lib": {}}
        self.plan, self.marker = False, None
        self.calls = []                       # (argv-summary, counted?) — counted = not a 304
        for n in range(1, 4):                 # a static upstream repo for cross-repo refs
            self._put("acme/lib", n, state=self.rnd.choice(["OPEN", "CLOSED"]), title=f"lib {n}")
        for n in range(1, rnd.randint(3, 12)):
            self._new_issue()

    def _stamp(self):
        self.tick += 1
        return "2026-10-%02dT%02d:%02d:%02dZ" % (1 + self.tick // 86400, self.tick // 3600 % 24,
                                                  self.tick // 60 % 60, self.tick % 60)

    def _put(self, slug, n, **kw):
        it = self.boards[slug].get(n) or {"number": n, "title": f"issue {n}", "state": "OPEN",
                                          "labels": [], "body": "", "login": "me", "bot": False, "pr": False}
        it.update(kw); it["updated"] = self._stamp()
        self.boards[slug][n] = it

    def _body(self):
        b = self.boards["acme/widget"]
        nums = list(b) or [1]
        lines = []
        if self.rnd.random() < 0.5:
            refs = [f"#{self.rnd.choice(nums)}" for _ in range(self.rnd.randint(1, 2))]
            if self.rnd.random() < 0.3:
                refs.append(f"acme/lib#{self.rnd.randint(1, 3)}")
            lines += ["## Blocked by", *[f"- {r}" for r in refs], ""]
        prds = [n for n, i in b.items() if "prd" in i["labels"]]
        if prds and self.rnd.random() < 0.6:
            lines += ["## Parent", f"#{self.rnd.choice(prds)}", ""]
        return "\n".join(lines)

    def _new_issue(self):
        b = self.boards["acme/widget"]
        n = max(b, default=0) + 1
        self._put("acme/widget", n, state="OPEN", body=self._body(),
                  labels=self.rnd.sample(self.LABELS, self.rnd.randint(0, 2)),
                  login=self.rnd.choice(["me", "me", "me", "stranger", "dependabot"]),
                  bot=False, pr=self.rnd.random() < 0.2,
                  title=("[AFK] PRD: thing %d" % n) if self.rnd.random() < 0.15 else f"issue {n}")
        if b[n]["login"] == "dependabot":
            b[n]["bot"] = True

    def mutate(self):
        b = self.boards["acme/widget"]
        for _ in range(self.rnd.randint(0, 3)):
            r = self.rnd.random()
            n = self.rnd.choice(list(b))
            if r < 0.25:
                self._put("acme/widget", n, state="CLOSED" if b[n]["state"] == "OPEN" else "OPEN")
            elif r < 0.5:
                labs = set(b[n]["labels"]) ^ {self.rnd.choice(self.LABELS)}
                self._put("acme/widget", n, labels=sorted(labs))
            elif r < 0.65:
                self._put("acme/widget", n, body=self._body())
            elif r < 0.85:
                self._new_issue()
            elif r < 0.93:
                self.plan = not self.plan
            else:
                self.marker = None if self.marker else {"spec_hash": ""}

    # ── shapes ──
    def _gh_shape(self, it):
        login = ("app/" + it["login"]) if it["bot"] else it["login"]
        return {"number": it["number"], "title": it["title"], "state": it["state"],
                "labels": [{"id": "L" + l, "name": l, "description": "", "color": "ededed"} for l in it["labels"]],
                "body": it["body"], "author": {"id": "U", "is_bot": it["bot"], "login": login, "name": ""},
                "updatedAt": it["updated"]}

    def _rest_shape(self, it):
        d = {"number": it["number"], "title": it["title"], "state": it["state"].lower(),
             "labels": [{"node_id": "L" + l, "name": l, "description": None, "color": "ededed"} for l in it["labels"]],
             "body": it["body"] or None, "updated_at": it["updated"],
             "user": {"login": it["login"] + ("[bot]" if it["bot"] else ""), "node_id": "U",
                      "type": "Bot" if it["bot"] else "User"}}
        if it["pr"]:
            d["pull_request"] = {"url": "x"}
        return d

    def _root(self):
        ents = [{"name": "README.md", "sha": "r0"}]
        if self.plan: ents.append({"name": "PLAN.md", "sha": "p1"})
        if self.marker: ents.append({"name": "docs", "sha": "d-" + _json.dumps(self.marker)})
        return ents

    # ── the fake gh ──
    def _done(self, argv, rc, out="", err="", counted=True):
        self.calls.append((" ".join(argv[1:4]), counted))
        return il.subprocess.CompletedProcess(argv, rc, out, err)

    def _http(self, argv, status, body, etag=None, link=None, sent=None):
        if etag and sent == etag:
            return self._done(argv, 1, "HTTP/2.0 304 Not Modified\nEtag: %s\n\n" % etag, "gh: HTTP 304", counted=False)
        head = "HTTP/2.0 %d %s\n" % (status, "OK" if status == 200 else "Not Found")
        if etag: head += "Etag: %s\n" % etag
        if link: head += 'Link: <https://api.github.com/%s>; rel="next"\n' % link
        return self._done(argv, 0 if status == 200 else 1, head + "\n" + body, "" if status == 200 else "gh: Not Found (HTTP 404)")

    def run(self, argv, **kw):
        a = list(argv[1:])
        if a[:2] == ["issue", "list"]:
            slug = a[a.index("-R") + 1]
            its = sorted(self.boards[slug].values(), key=lambda i: -i["number"])
            return self._done(argv, 0, _json.dumps([self._gh_shape(i) for i in its if not i["pr"]]))
        if a[:2] == ["issue", "view"]:
            slug, n = a[a.index("-R") + 1], int(a[2])
            it = self.boards.get(slug, {}).get(n)
            if not it: return self._done(argv, 1, "", "gh: Could not resolve to an issue (HTTP 404)")
            st = ("MERGED" if it["state"] == "CLOSED" else "OPEN") if it["pr"] else it["state"]
            return self._done(argv, 0, _json.dumps({"state": st}))
        if a[:2] == ["api", "user"]:
            return self._done(argv, 0, "me\n")
        if a[0] == "api" and a[1] != "-i":
            path = a[1]
            if path.endswith("/contents/PLAN.md"):
                return self._done(argv, 0, "p1\n") if self.plan else self._done(argv, 1, "", "gh: Not Found (HTTP 404)")
            if self.marker:
                return self._done(argv, 0, _b64.b64encode(_json.dumps(self.marker).encode()).decode())
            return self._done(argv, 1, "", "gh: Not Found (HTTP 404)")
        if a[:2] == ["api", "-i"]:
            path = a[2]
            sent = a[a.index("-H") + 1].split(": ", 1)[1] if "-H" in a else None
            if path.endswith("/contents/"):
                body = _json.dumps(self._root())
                return self._http(argv, 200, body, '"%s"' % _hashlib.sha1(body.encode()).hexdigest(), sent=sent)
            u = _urlsplit(path); q = _parse_qs(u.query)
            since = q.get("since", [""])[0]; pg = int(q.get("page", ["1"])[0])
            its = sorted((i for i in self.boards["acme/widget"].values() if i["updated"] >= since),
                         key=lambda i: i["updated"], reverse=True)
            chunk = its[(pg - 1) * self.page: pg * self.page]
            nxt = None
            if len(its) > pg * self.page:
                nxt = "repositories/9/issues?state=all&per_page=100&since=%s&page=%d" % (since, pg + 1)
            body = _json.dumps([self._rest_shape(i) for i in chunk])
            etag = 'W/"%s"' % _hashlib.sha1(_json.dumps([self._rest_shape(i) for i in its]).encode()).hexdigest()
            return self._http(argv, 200, body, etag if pg == 1 else None, nxt, sent)
        return self._done(argv, 1, "", "unknown")

    def counted(self, since_idx=0):
        return [c for c, counted in self.calls[since_idx:] if counted]


def _with_fake_gh(fake, fn):
    """Run fn() with the fake GitHub installed and every read seam the REAL one; restore after."""
    import tempfile
    saved = dict(run=il.subprocess.run, cs=il.compute_state, li=il._list_issues, st=il._issue_state,
                 hp=il._has_plan, pm=il._plan_marker, af=il._author_filter, sl=il._self_login,
                 env={k: os.environ.get(k) for k in ("HARNESS_SNAPSHOT_FILE", "HARNESS_SNAPSHOT_DIR",
                      "HARNESS_MODE", "HARNESS_AUTONOMOUS", "HARNESS_AUTHOR_ALLOWLIST", "HARNESS_SPEC",
                      "HARNESS_DEP_TTL", "HARNESS_FULL_RESYNC", "HARNESS_OWNER")})
    il.subprocess.run = fake.run
    il.compute_state = _REAL_COMPUTE_STATE; il._list_issues = _REAL_LIST_ISSUES
    il._issue_state = _REAL_ISSUE_STATE; il._has_plan = _REAL_HAS_PLAN
    il._plan_marker = _REAL_PLAN_MARKER; il._author_filter = _REAL_AUTHOR_FILTER
    il._self_login = lambda: "me"
    for k in ("HARNESS_SNAPSHOT_FILE", "HARNESS_SNAPSHOT_DIR", "HARNESS_AUTHOR_ALLOWLIST", "HARNESS_SPEC"):
        os.environ.pop(k, None)
    os.environ.update(HARNESS_MODE="prd", HARNESS_AUTONOMOUS="false", HARNESS_OWNER="acme")
    tmp = tempfile.mkdtemp()
    try:
        return fn(tmp)
    finally:
        il.subprocess.run = saved["run"]; il.compute_state = saved["cs"]; il._list_issues = saved["li"]
        il._issue_state = saved["st"]; il._has_plan = saved["hp"]; il._plan_marker = saved["pm"]
        il._author_filter = saved["af"]; il._self_login = saved["sl"]
        for k, v in saved["env"].items():
            if v is None: os.environ.pop(k, None)
            else: os.environ[k] = v


def _state_from(snap, tmp):
    """compute_state served from <snap> the way a worker reads it (snapshot env, no gh)."""
    path = os.path.join(tmp, "acme__widget.json")
    with open(path, "w") as f: _json.dump(snap, f)
    os.environ["HARNESS_SNAPSHOT_FILE"] = path; os.environ["HARNESS_SNAPSHOT_DIR"] = tmp
    try:
        return il.compute_state("acme/widget")
    finally:
        os.environ.pop("HARNESS_SNAPSHOT_FILE", None); os.environ.pop("HARNESS_SNAPSHOT_DIR", None)


def test_board_cache_property_incremental_equals_full_fetch():
    # Acceptance (#182): compute_state returns IDENTICAL results from the incremental cache and from
    # a full fetch, over many recorded random boards and random sequences of edits — state flips,
    # label churn, body rewrites (blocked-by / parent / cross-repo refs), new issues, PRs mixed into
    # the REST feed, bot authors, PLAN.md and plan-marker flips, and deltas spanning several pages.
    def body(tmp):
        os.environ["HARNESS_DEP_TTL"] = "0"     # cross-repo deps re-resolved every poll
        for seed in range(60):
            fake = _FakeGitHub(_random.Random(seed), page=_random.Random(seed).choice([2, 3, 100]))
            il.subprocess.run = fake.run
            snap = il.snapshot("acme/widget", None, tmp)              # first poll: full fetch
            assert snap["sync"]["full_at"] > 0, snap
            for step in range(8):
                fake.mutate()
                snap = il.snapshot("acme/widget", snap, tmp)          # every later poll: incremental
                cached = _state_from(snap, tmp)
                direct = il.compute_state("acme/widget")              # the same board, fetched whole
                assert cached == direct, (seed, step, cached, direct)
    _with_fake_gh(_FakeGitHub(_random.Random(0)), body)


def test_board_cache_unchanged_board_costs_zero_counted_calls():
    # Acceptance (#182): two consecutive polls on an unchanged board make 0 rate-limited calls —
    # only 304s. (The poll right after a full fetch primes the ETags, so steady state starts after.)
    def body(tmp):
        fake = _FakeGitHub(_random.Random(7))
        il.subprocess.run = fake.run
        snap = il.snapshot("acme/widget", None, tmp)
        snap = il.snapshot("acme/widget", snap, tmp)
        mark = len(fake.calls)
        snap = il.snapshot("acme/widget", snap, tmp)
        snap = il.snapshot("acme/widget", snap, tmp)
        assert fake.counted(mark) == [], fake.calls[mark:]
        assert len(fake.calls[mark:]) == 4, fake.calls[mark:]         # 2 polls × (issues + root), all 304
        # …and a change is still seen on the very next poll, at the cost of the delta alone.
        fake._put("acme/widget", 1, state="CLOSED")
        snap = il.snapshot("acme/widget", snap, tmp)
        assert next(i for i in snap["issues"] if i["number"] == 1)["state"] == "CLOSED", snap["issues"]
    _with_fake_gh(_FakeGitHub(_random.Random(7)), body)


def test_board_cache_full_resync_drops_deleted_issues():
    # `since` never reports a deletion or a transfer; the periodic full resync does.
    def body(tmp):
        fake = _FakeGitHub(_random.Random(3))
        il.subprocess.run = fake.run
        snap = il.snapshot("acme/widget", None, tmp)
        gone = max(fake.boards["acme/widget"])
        del fake.boards["acme/widget"][gone]
        snap = il.snapshot("acme/widget", snap, tmp)
        assert any(i["number"] == gone for i in snap["issues"]), "incremental cannot see a deletion"
        os.environ["HARNESS_FULL_RESYNC"] = "0"                      # resync now due
        mark = len(fake.calls)
        snap = il.snapshot("acme/widget", snap, tmp)
        assert not any(i["number"] == gone for i in snap["issues"]), snap["issues"]
        assert any(c.startswith("issue list") for c, _ in fake.calls[mark:]), fake.calls[mark:]
    _with_fake_gh(_FakeGitHub(_random.Random(3)), body)


def test_board_cache_falls_back_to_full_when_rest_unusable():
    # A gh that answers no conditional request at all (an old stub, an odd proxy) is a non-transient
    # failure: refresh with a full fetch instead of holding forever on a stale cache.
    def body(tmp):
        fake = _FakeGitHub(_random.Random(5))
        il.subprocess.run = fake.run
        snap = il.snapshot("acme/widget", None, tmp)
        real = fake.run
        def no_rest(argv, **kw):
            if list(argv[1:3]) == ["api", "-i"]:
                return il.subprocess.CompletedProcess(argv, 1, "", "unknown flag")
            return real(argv, **kw)
        il.subprocess.run = no_rest
        fake._put("acme/widget", 1, title="renamed")
        snap = il.snapshot("acme/widget", snap, tmp)
        assert next(i for i in snap["issues"] if i["number"] == 1)["title"] == "renamed", snap["issues"]
    _with_fake_gh(_FakeGitHub(_random.Random(5)), body)


def test_board_cache_transient_failure_holds():
    # A rate-limited delta must HOLD (GhError → the poller keeps the prior snapshot), never fall
    # back to a full fetch — that would spend more of the very budget that just ran out.
    def body(tmp):
        fake = _FakeGitHub(_random.Random(5))
        il.subprocess.run = fake.run
        snap = il.snapshot("acme/widget", None, tmp)
        il.subprocess.run = lambda argv, **kw: il.subprocess.CompletedProcess(
            argv, 1, "HTTP/2.0 403 Forbidden\nX-Ratelimit-Remaining: 0\n\n{}", "gh: API rate limit exceeded (HTTP 403)")
        try:
            il.snapshot("acme/widget", snap, tmp)
            assert False, "expected GhError"
        except il.GhError:
            pass
    _with_fake_gh(_FakeGitHub(_random.Random(5)), body)


def test_board_cache_cross_repo_dep_resolved_by_poller_with_ttl():
    # A `## Blocked by` ref into a repo nobody snapshots is resolved by the POLLER (one call) and
    # cached for HARNESS_DEP_TTL; the worker reads it from the snapshot without calling gh.
    def body(tmp):
        fake = _FakeGitHub(_random.Random(1))
        fake.boards["acme/widget"] = {}
        fake.boards["acme/lib"][2]["state"] = "OPEN"
        fake._put("acme/widget", 1, body="## Blocked by\n- acme/lib#2\n", labels=["ready-for-agent"])
        il.subprocess.run = fake.run
        os.environ["HARNESS_DEP_TTL"] = "3600"
        snap = il.snapshot("acme/widget", None, tmp)
        assert snap["ext_deps"]["acme/lib#2"]["state"] == "open", snap["ext_deps"]
        fake.boards["acme/lib"][2]["state"] = "CLOSED"                # upstream closes …
        mark = len(fake.calls)
        snap = il.snapshot("acme/widget", snap, tmp)
        assert not any(c.startswith("issue view") for c, _ in fake.calls[mark:]), "TTL not honoured"
        assert 1 not in _state_from(snap, tmp)["unblocked"]            # … still cached as open
        os.environ["HARNESS_DEP_TTL"] = "0"                           # TTL lapses
        snap = il.snapshot("acme/widget", snap, tmp)
        assert snap["ext_deps"]["acme/lib#2"]["state"] == "closed", snap["ext_deps"]
        il.subprocess.run = lambda argv, **kw: (_ for _ in ()).throw(AssertionError("worker called gh"))
        assert 1 in _state_from(snap, tmp)["unblocked"]
    _with_fake_gh(_FakeGitHub(_random.Random(1)), body)


def test_board_cache_edge_answers():
    # The odd answers each read can get, and what the snapshot makes of them.
    def body(tmp):
        fake = _FakeGitHub(_random.Random(9))
        il.subprocess.run = fake.run
        base = il.snapshot("acme/widget", None, tmp)
        def answering(match, out, rc=0, err=""):
            def run(argv, **kw):
                if match(list(argv[1:])):
                    if isinstance(out, Exception): raise out
                    return il.subprocess.CompletedProcess(argv, rc, out, err)
                return fake.run(argv, **kw)
            il.subprocess.run = run
        is_issues = lambda a: a[:2] == ["api", "-i"] and "/issues?" in a[2]
        is_root = lambda a: a[:2] == ["api", "-i"] and a[2].endswith("/contents/")
        def holds(why):
            try:
                il.snapshot("acme/widget", base, tmp); assert False, why
            except il.GhError:
                pass
        answering(is_issues, il.subprocess.TimeoutExpired("gh", 60)); holds("gh timeout must hold")
        answering(is_issues, "HTTP/2.0 200 OK\nEtag: x\n\nnot json"); holds("garbled delta must hold")
        answering(is_root, "HTTP/2.0 200 OK\nEtag: x\n\nnot json"); holds("garbled root must hold")
        answering(is_root, "HTTP/2.0 404 Not Found\n\n{}", 1, "gh: This repository is empty. (HTTP 404)")
        s = il.snapshot("acme/widget", base, tmp)
        assert (s["has_plan"], s["plan_marker"], s["sync"]["root_etag"]) == (False, None, None), s
        answering(is_root, "", 1, "unknown command")                # no HTTP answer at all → full resync
        mark = len(fake.calls)
        s = il.snapshot("acme/widget", base, tmp)
        assert any(c.startswith("issue list") for c, _ in fake.calls[mark:]), fake.calls[mark:]
        il.subprocess.run = fake.run
        # a previous snapshot the incremental path must not build on → full fetch
        for bad in (dict(base, schema_version=999), dict(base, sync=None), dict(base, slug="acme/other")):
            mark = len(fake.calls)
            il.snapshot("acme/widget", bad, tmp)
            assert any(c.startswith("issue list") for c, _ in fake.calls[mark:]), bad.get("sync")
        # a cross-repo ref into a repo that HAS its own snapshot is left to that snapshot
        fake._put("acme/widget", 1, state="OPEN", body="## Blocked by\n- acme/lib#1\n")
        open(os.path.join(tmp, "acme__lib.json"), "w").write("{}")
        try:
            s = il.snapshot("acme/widget", None, tmp)
            assert "acme/lib#1" not in s["ext_deps"], s["ext_deps"]
        finally:
            os.remove(os.path.join(tmp, "acme__lib.json"))
        # a worker asking for a dep nobody snapshotted or resolved: None → blocked, never a gh call
        il.subprocess.run = lambda argv, **kw: (_ for _ in ()).throw(AssertionError("worker called gh"))
        os.environ["HARNESS_SNAPSHOT_DIR"] = tmp
        try:
            assert il._ext_dep_state("other/ghost", 1) is None
        finally:
            os.environ.pop("HARNESS_SNAPSHOT_DIR", None)
    _with_fake_gh(_FakeGitHub(_random.Random(9)), body)

def test_parse_http_and_link_next():
    st, h, b = il._parse_http('HTTP/2.0 200 OK\r\nEtag: W/"x"\r\nLink: <https://api.github.com/repositories/1/issues?page=2>; rel="next", <https://api.github.com/repositories/1/issues?page=5>; rel="last"\r\n\r\n[1]')
    assert (st, h["etag"], b) == (200, 'W/"x"', "[1]"), (st, h, b)
    assert il._link_next(h) == "repositories/1/issues?page=2", il._link_next(h)
    assert il._link_next({}) is None
    assert il._parse_http("")[0] is None and il._parse_http("not http")[0] is None


def test_rest_to_gh_issue_maps_bots_and_nulls():
    g = il._rest_to_gh_issue({"number": 3, "title": "t", "state": "closed", "body": None,
                              "labels": [{"name": "bug", "node_id": "L", "color": "f00", "description": None}],
                              "user": {"login": "dependabot[bot]", "type": "Bot"}, "updated_at": "2026-01-01T00:00:00Z"})
    assert g["state"] == "CLOSED" and g["body"] == "" and g["author"]["login"] == "app/dependabot", g
    assert g["labels"][0]["name"] == "bug" and g["updatedAt"] == "2026-01-01T00:00:00Z", g

# ── #183: rate-limit-aware dispatch ─────────────────────────────────────────────────────────────
import contextlib as _ctx, io as _io, json as _json, tempfile as _tempfile, time as _time

@_ctx.contextmanager
def _rate_env(responses):
    """Guard on, a throwaway rate dir, no env token, and a fake subprocess.run: `gh api rate_limit`
    answers responses["rate"] (a dict → JSON, a string → raw stdout, None → exit 1, an Exception →
    raised); anything else answers responses["err"] (stderr, exit 1) or `[]`. Yields the call log."""
    calls = []
    def run(argv, **k):
        calls.append(list(argv))
        if argv[1:3] == ["api", "rate_limit"]:
            r = responses.get("rate")
            if isinstance(r, Exception): raise r
            if r is None: return il.subprocess.CompletedProcess(argv, 1, "", "boom")
            return il.subprocess.CompletedProcess(argv, 0, r if isinstance(r, str) else _json.dumps(r), "")
        if argv[1:3] == ["api", "-i"] and "cond" in responses:
            out, rc = responses["cond"]
            return il.subprocess.CompletedProcess(argv, rc, out, responses.get("err", ""))
        if responses.get("err"):
            return il.subprocess.CompletedProcess(argv, 1, "", responses["err"])
        return il.subprocess.CompletedProcess(argv, 0, "[]", "")
    saved = {k: os.environ.get(k) for k in ("HARNESS_GH_RATE_GUARD", "HARNESS_GH_RATE_DIR", "GH_TOKEN", "GITHUB_TOKEN")}
    real = il.subprocess.run
    os.environ.update(HARNESS_GH_RATE_GUARD="1", HARNESS_GH_RATE_DIR=_tempfile.mkdtemp())
    os.environ.pop("GH_TOKEN", None); os.environ.pop("GITHUB_TOKEN", None)
    il.subprocess.run = run
    try:
        yield calls
    finally:
        il.subprocess.run = real
        for k, v in saved.items():
            if v is None: os.environ.pop(k, None)
            else: os.environ[k] = v

def _budget(core, graphql, reset):
    return {"resources": {"core": {"limit": 5000, "remaining": core, "reset": reset},
                          "graphql": {"limit": 5000, "remaining": graphql, "reset": reset}}}

def _raises_gh(fn):
    try: fn()
    except il.GhError as e: return str(e)
    raise AssertionError("expected GhError")

def test_rate_limit_holds_until_reset_and_refuses_gh():
    reset = int(_time.time()) + 100
    with _rate_env({"rate": _budget(0, 4000, reset), "err": "gh: API rate limit exceeded (HTTP 403)"}) as calls:
        _raises_gh(lambda: il._gh_json(["issue", "list"]))
        assert il.rate_hold_until() == reset, "the hold carries the exhausted resource's reset"
        n = len(calls)
        assert "gh not called" in _raises_gh(lambda: il._gh_json(["issue", "list"]))
        assert "gh not called" in _raises_gh(lambda: il._gh_api_read("repos/x/contents/PLAN.md", ".sha"))
        assert len(calls) == n, "a held read never calls gh"

def test_conditional_read_holds_on_its_own_reset_header():
    reset = int(_time.time()) + 200
    spent = (f"HTTP/2.0 403 Forbidden\r\nX-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: {reset}\r\n\r\n{{}}", 1)
    with _rate_env({"cond": spent, "rate": _budget(4000, 4000, reset + 999)}) as calls:
        _raises_gh(lambda: il._gh_api_cond("repos/acme/widget/issues"))
        assert il.rate_hold_until() == reset, "the response's X-RateLimit-Reset is the hold"
        assert ["gh", "api", "rate_limit"] not in calls, "a reset header needs no probe"
        n = len(calls)
        assert "gh not called" in _raises_gh(lambda: il._gh_api_cond("repos/acme/widget/issues", "W/x"))
        assert len(calls) == n
    with _rate_env({"cond": ("HTTP/2.0 404 Not Found\r\n\r\n{}", 1)}):
        assert il._gh_api_cond("repos/acme/widget/issues")[0] == 404
        assert il.rate_hold_until() is None, "a 404 holds nothing"
    with _rate_env({"cond": ("", 1), "err": "gh: API rate limit exceeded (HTTP 403)",
                    "rate": _budget(0, 4000, reset)}):
        _raises_gh(lambda: il._gh_api_cond("repos/acme/widget/issues"))
        assert il.rate_hold_until() == reset, "no response headers: the probe's reset"

def test_api_read_rate_limit_records_hold():
    reset = int(_time.time()) + 100
    with _rate_env({"rate": _budget(4000, 0, reset), "err": "HTTP 429: too many requests"}):
        _raises_gh(lambda: il._gh_api_read("repos/x/contents/PLAN.md", ".sha"))
        assert il.rate_hold_until() == reset

def test_secondary_limit_holds_a_minute():
    with _rate_env({"rate": _budget(4000, 4000, int(_time.time()) + 3600),
                    "err": "You have exceeded a secondary rate limit (HTTP 403)"}):
        _raises_gh(lambda: il._gh_json(["issue", "list"]))
        held = il.rate_hold_until(); now = _time.time()
        assert held and now + 55 <= held <= now + 61, held

def test_non_limit_failures_hold_nothing():
    for err, rate in (("HTTP 403: Resource not accessible by integration", _budget(4000, 4000, int(_time.time()) + 3600)),
                      ("HTTP 403: forbidden", None),
                      ("HTTP 403: forbidden", RuntimeError("no gh")),
                      ("HTTP 403: forbidden", "not json"),
                      ("gh: Not Found (HTTP 404)", None)):
        with _rate_env({"rate": rate, "err": err}):
            try: il._gh_json(["issue", "view", "1"], allow_absent=True)
            except il.GhError: pass   # a 403 is transient to the reader either way; only the hold is under test
            assert il.rate_hold_until() is None, (err, rate)

def test_rate_guard_off_records_and_refuses_nothing():
    with _rate_env({"rate": _budget(0, 0, int(_time.time()) + 100), "err": "API rate limit exceeded"}) as calls:
        os.environ["HARNESS_GH_RATE_GUARD"] = "0"
        _raises_gh(lambda: il._gh_json(["issue", "list"]))
        assert not os.listdir(os.environ["HARNESS_GH_RATE_DIR"]), "guard off: no host state written"
        assert il.rate_hold_until() is None
        assert ["gh", "api", "rate_limit"] not in calls, "guard off: no probe on a failure"

def test_expired_or_garbled_hold_is_no_hold():
    with _rate_env({}):
        il._write_json(il._rate_file("hold"), {"reset": int(_time.time()) - 1})
        assert il.rate_hold_until() is None
        with open(il._rate_file("hold"), "w") as fh: fh.write("{garbled")
        assert il.rate_hold_until() is None

def test_rate_budget_low_thresholds_and_cache():
    reset = int(_time.time()) + 3600
    resp = {"rate": _budget(900, 4000, reset)}
    with _rate_env(resp) as calls:
        assert il.rate_budget_low(20, 60) == ("core", 900, 5000, reset)
        resp["rate"] = _budget(4000, 400, reset)
        assert il.rate_budget_low(20, 60)[0] == "core", "a fresh probe is reused within the TTL"
        assert len(calls) == 1
        assert il.rate_budget_low(20, 0)[:2] == ("graphql", 400), "past the TTL it re-probes"
        resp["rate"] = _budget(2000, 2000, reset)
        assert il.rate_budget_low(20, 0) is None, "40% left is not low"
        resp["rate"] = None
        assert il.rate_budget_low(20, 0) is None, "a failed probe is fail-open"

def test_rate_cache_from_before_a_reset_is_reprobed():
    with _rate_env({"rate": _budget(4000, 4000, int(_time.time()) + 3600)}) as calls:
        il._write_json(il._rate_file("rate"), {"checked_at": int(_time.time()),
                                               "resources": _budget(0, 0, int(_time.time()) - 5)["resources"]})
        assert il.rate_budget_low(20, 60) is None, "a budget past its reset has refilled: re-read it"
        assert len(calls) == 1

def test_token_key_hashes_env_token():
    with _rate_env({}):
        assert il._token_key() == "gh-auth"
        os.environ["GH_TOKEN"] = "s3cret"
        k = il._token_key()
        assert k.startswith("token-") and len(k) == 14 and "s3cret" not in k

def test_rate_report_lists_every_token_with_hold():
    reset = int(_time.time()) + 3600
    resp = {"rate": _budget(900, 4500, reset)}
    with _rate_env(resp):
        os.environ["GH_TOKEN"] = "s3cret"; il.rate_report(); os.environ.pop("GH_TOKEN")
        resp["rate"] = _budget(1200, 4800, reset)
        il._write_json(il._rate_file("hold"), {"reset": reset})
        with open(il._rate_file("rate", "empty"), "w") as fh: fh.write("{}")
        lines = il.rate_report()
        hm = _time.strftime("%H:%M", _time.localtime(reset))
        assert f"gh-auth: core 1200/5000 resets {hm}, graphql 4800/5000 resets {hm}  HOLD until" in "\n".join(lines), lines
        assert any(l.startswith("token-") and "core 900/5000" in l for l in lines), lines
        assert "empty: no data" in lines
        assert not any("s3cret" in l for l in lines)
        resp["rate"] = None
        assert il.rate_report() == lines, "a failed probe still reports what the host last saw"

def test_rate_cli_commands():
    reset = int(_time.time()) + 3600
    with _rate_env({"rate": _budget(900, 4000, reset)}):
        real_argv = sys.argv
        def cli(*args):
            sys.argv = ["issuelib.py", *args]; buf = _io.StringIO(); rc = 0
            try:
                with _ctx.redirect_stdout(buf): il.main()
            except SystemExit as e:
                rc = e.code
            finally:
                sys.argv = real_argv
            return rc, buf.getvalue().strip()
        assert cli("rate-held") == (1, "")
        assert cli("rate-low", "20", "60") == (0, f"core\t900\t5000\t{reset}")
        assert cli("rate-low")[0] == 0, "pct and ttl default"
        assert cli("rate-low", "10", "60") == (1, "")
        il._write_json(il._rate_file("hold"), {"reset": reset})
        assert cli("rate-held") == (0, str(reset))
        rc, out = cli("rate-report")
        assert rc == 0 and out.startswith("gh-auth: core 900/5000") and "HOLD" in out, out


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)
