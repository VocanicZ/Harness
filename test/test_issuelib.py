import importlib.util, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("issuelib", os.path.join(HERE, "..", "issuelib.py"))
il = importlib.util.module_from_spec(spec); spec.loader.exec_module(il)
_REAL_COMPUTE_STATE = il.compute_state   # tests that stub compute_state must restore this

# Other tests monkeypatch il._spec_hash without restoring it; keep a handle to the real one so the
# spec-hash test verifies actual behaviour regardless of run order.
REAL_SPEC_HASH = il._spec_hash

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

if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)
