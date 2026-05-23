import importlib.util, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("issuelib", os.path.join(HERE, "..", "issuelib.py"))
il = importlib.util.module_from_spec(spec); spec.loader.exec_module(il)

def mk(**kw):
    base = dict(slug="acme/widget", has_plan=False, prd=None, prd_open=False, prd_reviewed=False,
                children_exist=False, children_all_closed=False, unblocked=[], open_children=0, total_children=0)
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

if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as e: print(f"  FAIL: {name} — {e}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)
