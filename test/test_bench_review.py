#!/usr/bin/env python3
"""test_bench_review.py — #620 (PRD #345): bench/review.py, the scripted blind review. A stub judge stands in for
`claude -p` (same stdin / cwd / stdout contract), so this checks everything but the model: the repos are anonymised
(no git history, no tool-naming files) and labelled A / B; every judge reviews the pair in both orders; the seed fixes
who is A first and the order of the passes (a re-run builds the same directories); verdict parsing; the arithmetic
(means over the verdicts, per-criterion means, the gap); a judge that fails once is retried, one that never answers
fails the review without writing anything; the scores land in the run JSON (and the run JSON still validates); and
a noisy judge re-run on the same repos stays within 0.5."""
import contextlib, io, json, os, shutil, stat, sys, tempfile, textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "bench"))
sys.dont_write_bytecode = True
import review                                       # noqa: E402

BRIEF = os.path.join(ROOT, "bench", "fixture", "brief.md")
RUBRIC, _ = review.load_rubric()
IDS = [c["id"] for c in RUBRIC["criteria"]]

# The stub judge: scores a repo by the marker files in its folder (GOOD: 2 everywhere, OK: 1), optionally with noise
# from $STUB_NOISE (a seed that changes per call), failing the first $STUB_FAIL calls, logging what it saw.
STUB = textwrap.dedent('''\
    import json, os, sys
    prompt = sys.stdin.read()
    log = os.environ["STUB_LOG"]
    n = len(open(log).read().splitlines()) if os.path.exists(log) else 0
    seen = {l: sorted(os.listdir(l)) for l in "AB"}
    seen["root"] = sorted(os.listdir("."))
    seen["args"] = sys.argv[1:]
    seen["prompt_has_rubric"] = all(c in prompt for c in %r)
    open(log, "a").write(json.dumps(seen) + "\\n")
    if n < int(os.environ.get("STUB_FAIL", "0")):
        sys.exit(3)
    def score(label):
        base = 2 if "GOOD" in seen[label] else 1
        wobble = int(os.environ.get("STUB_NOISE", "0"))
        return {i: max(0, min(2, base - (1 if wobble and (n + k + wobble) %% 7 == 0 else 0))) for k, i in enumerate(%r)}
    verdict = {"A": score("A"), "B": score("B"), "notes": "x"}
    print(json.dumps({"type": "result", "result": "Here is my verdict.\\n" + json.dumps(verdict)}))
''' % (IDS, IDS))


def make_repo(root, name, good, extra=()):
    d = os.path.join(root, name)
    os.makedirs(os.path.join(d, ".git"))
    os.makedirs(os.path.join(d, ".harness"))
    os.makedirs(os.path.join(d, "src"))
    for f in ("CLAUDE.md", "AGENTS.md", "README.md", os.path.join("src", "code.py"), ".harness-task.md") + tuple(extra):
        open(os.path.join(d, f), "w").write("x")
    if good:
        open(os.path.join(d, "GOOD"), "w").write("x")
    return d


def stub_cmd(tmp, **env):
    path = os.path.join(tmp, "judge.py")
    open(path, "w").write(STUB)
    for k, v in env.items():
        os.environ[k] = str(v)
    return "%s %s" % (sys.executable, path)


def run_review(tmp, repos, judges=3, seed=620, **env):
    log = os.path.join(tmp, "stub.log")
    if os.path.exists(log):
        os.remove(log)
    os.environ["STUB_LOG"] = log
    for k in ("STUB_FAIL", "STUB_NOISE"):
        os.environ.pop(k, None)
    cmd = stub_cmd(tmp, **env)
    out = review.review(repos, BRIEF, cmd, "claude-test", seed, judges)
    calls = [json.loads(x) for x in open(log).read().splitlines()] if os.path.exists(log) else []
    return out, calls


def test_each_judge_reviews_the_pair_in_both_orders_and_the_labels_are_anonymous():
    with tempfile.TemporaryDirectory() as tmp:
        repos = {"harness": make_repo(tmp, "h", True), "plain": make_repo(tmp, "p", False)}
        out, calls = run_review(tmp, repos)
    assert len(calls) == 6, len(calls)                                          # 3 judges x 2 orders
    for c in calls:
        assert c["root"] == ["A", "B", "brief.md"], c["root"]
        for label in "AB":                                                      # nothing that names the tool or keeps its history
            assert not {".git", ".harness", "CLAUDE.md", "AGENTS.md", ".harness-task.md"} & set(c[label]), c[label]
            assert {"README.md", "src"} <= set(c[label])
        assert c["prompt_has_rubric"]
        for flag in ("--tools", "Read,Glob,Grep", "--model", "claude-test", "--disable-slash-commands"):
            assert flag in c["args"], flag
    good_first = [("GOOD" in c["A"]) for c in calls]
    assert 3 == sum(good_first), good_first                                     # the good repo was A in half the passes
    assert out["harness"]["review_score"] == 10.0 and out["plain"]["review_score"] == 5.0
    r = out["harness"]["review"]
    assert (r["verdicts"], r["failed"], r["judges"], r["seed"], r["versus"], r["mean_gap"]) == (6, 0, 3, 620, "plain", 5.0)
    assert r["scores"] == [10] * 6 and out["plain"]["review"]["scores"] == [5] * 6
    assert r["criteria"] == {i: 2.0 for i in IDS} and out["plain"]["review"]["criteria"] == {i: 1.0 for i in IDS}
    assert len(r["rubric_sha"]) == 64 and len(r["brief_sha"]) == 64 and r["rubric"] == RUBRIC["version"]
    json.dumps(out)


def test_the_seed_fixes_who_is_a_first_and_the_order_of_the_passes():
    arms = ["harness", "plain"]
    assert review.plan(arms, 3, 620) == review.plan(arms, 3, 620)
    plans = [review.plan(arms, 3, s) for s in range(40)]
    assert len({str(p) for p in plans}) > 1, "the seed changes nothing"
    for p in plans:
        assert len(p) == 6
        for arm in arms:                                                         # each arm is A exactly as often as B
            assert sum(1 for _, _, m in p if m["A"] == arm) == 3
        for j in (1, 2, 3):                                                      # each judge sees both orders
            assert sorted(m["A"] for jj, _, m in p if jj == j) == arms
    firsts = {p[0][2]["A"] for p in plans}
    assert firsts == set(arms), "the first pass should not always put the same arm first"
    try:
        review.plan(["a"], 3, 1)
    except ValueError:
        pass
    else:
        raise AssertionError("a review needs two repos")


def test_the_same_seed_builds_the_same_review_directories():
    with tempfile.TemporaryDirectory() as tmp:
        repos = {"harness": make_repo(tmp, "h", True), "plain": make_repo(tmp, "p", False)}
        a, b = os.path.join(tmp, "keep-a"), os.path.join(tmp, "keep-b")
        os.makedirs(a), os.makedirs(b)
        for keep in (a, b):
            log = os.path.join(tmp, "x.log")
            os.environ["STUB_LOG"] = log
            review.review(repos, BRIEF, stub_cmd(tmp), "m", 620, 2, keep=keep)

        def tree(root):
            return sorted((os.path.relpath(os.path.join(d, f), root), os.path.getsize(os.path.join(d, f)))
                          for d, _, fs in os.walk(root) for f in fs)
        assert tree(a) == tree(b) and tree(a)


def test_verdict_parsing_is_strict_about_scores_and_tolerant_about_prose():
    ok = {l: {i: 1 for i in IDS} for l in "AB"}
    envelope = json.dumps({"result": "Thoughts {not json}\n" + json.dumps(ok) + "\nbye"})
    assert review.parse_verdict(envelope, RUBRIC) == ok
    assert review.parse_verdict(json.dumps(ok), RUBRIC) == ok
    assert review.parse_verdict("```json\n" + json.dumps(ok) + "\n```", RUBRIC) == ok
    for bad in ({**ok, "A": {**ok["A"], IDS[0]: 3}}, {**ok, "A": {**ok["A"], IDS[0]: True}},
                {**ok, "B": {i: 1 for i in IDS[1:]}}, {"A": ok["A"]}, {**ok, "A": {**ok["A"], IDS[0]: "2"}}):
        assert review.parse_verdict(json.dumps(bad), RUBRIC) is None, bad
    assert review.parse_verdict("no json at all", RUBRIC) is None and review.parse_verdict("", RUBRIC) is None


def test_a_judge_that_fails_once_is_retried_and_one_that_never_answers_fails_the_review():
    with tempfile.TemporaryDirectory() as tmp:
        repos = {"harness": make_repo(tmp, "h", True), "plain": make_repo(tmp, "p", False)}
        out, calls = run_review(tmp, repos, judges=1, STUB_FAIL=1)
        assert len(calls) == 3 and out["harness"]["review"]["verdicts"] == 2        # 1st call failed, retried; 2 passes
        assert out["harness"]["review"]["failed"] == 0
        try:
            run_review(tmp, repos, judges=1, STUB_FAIL=99)
        except RuntimeError as exc:
            assert "review did not run" in str(exc)
        else:
            raise AssertionError("scored with no verdict")


def test_a_noisy_judge_re_run_on_the_same_repos_stays_within_half_a_point():
    with tempfile.TemporaryDirectory() as tmp:
        repos = {"harness": make_repo(tmp, "h", True), "plain": make_repo(tmp, "p", False)}
        clean, _ = run_review(tmp, repos)
        first, _ = run_review(tmp, repos, STUB_NOISE=1)
        second, _ = run_review(tmp, repos, STUB_NOISE=3)
    assert first != clean and second != clean and first != second, "the stub judge is not noisy"
    for arm in repos:
        assert abs(first[arm]["review_score"] - second[arm]["review_score"]) <= 0.5, (first[arm], second[arm])


def test_scores_are_merged_into_the_run_json_and_it_still_validates():
    sys.path.insert(0, os.path.join(ROOT, "bench"))
    import importlib.util
    spec = importlib.util.spec_from_file_location("bench_run", os.path.join(ROOT, "bench", "run.py"))
    run = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(run)
    base = json.load(open(os.path.join(ROOT, "bench", "results", "run-20261106", "plain.json")))
    assert run.validate(base) == []
    with tempfile.TemporaryDirectory() as tmp:
        repos = {"harness": make_repo(tmp, "h", True), "plain": make_repo(tmp, "p", False)}
        rd = os.path.join(tmp, "run-x")
        os.makedirs(rd)
        for arm in repos:
            json.dump(dict(base, arm=arm), open(os.path.join(rd, arm + ".json"), "w"))
        out, _ = run_review(tmp, repos)
        review.merge(rd, out)
        doc = json.load(open(os.path.join(rd, "plain.json")))
        assert doc["review_score"] == 5.0 and doc["review"]["versus"] == "harness" and doc["arm"] == "plain"
        assert run.validate(doc) == [], run.validate(doc)
        assert run.validate(dict(doc, review_score=11)) != [] and run.validate(dict(doc, review=[])) != []


def test_the_command_line():
    with tempfile.TemporaryDirectory() as tmp:
        repos = {"harness": make_repo(tmp, "h", True), "plain": make_repo(tmp, "p", False)}
        rd = os.path.join(tmp, "run-x")
        os.makedirs(rd)
        for arm in repos:
            json.dump({"arm": arm}, open(os.path.join(rd, arm + ".json"), "w"))
        os.environ["STUB_LOG"] = os.path.join(tmp, "cli.log")
        os.environ.pop("STUB_FAIL", None)
        argv = ["--repo", "harness=" + repos["harness"], "--repo", "plain=" + repos["plain"], "--judge-cmd",
                stub_cmd(tmp), "--judges", "1", "--write", rd]
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            assert review.main(argv) == 0
        printed = json.loads(out.getvalue())
        assert printed["harness"]["review_score"] == 10.0
        assert json.load(open(os.path.join(rd, "harness.json")))["review_score"] == 10.0
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            assert review.main(["--repo", "harness=" + repos["harness"]]) == 2
            assert review.main(argv[:-2] + ["--fixture", "nope"]) == 2
            assert review.main(argv[:-1] + [os.path.join(tmp, "no-such-run")]) == 2
            os.environ["STUB_FAIL"] = "99"
            assert review.main(argv[:-2]) == 1
        os.environ.pop("STUB_FAIL", None)
        assert "review did not run" in err.getvalue()


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as ex: print(f"  FAIL: {name} — {ex}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)
