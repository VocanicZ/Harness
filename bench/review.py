#!/usr/bin/env python3
"""review.py — the scripted blind review of two arms' final repos (PRD #345, #620). Stdlib only.

A review nobody can re-run is an anecdote, so the blind review is a script: a fixed rubric (bench/review/rubric.json),
the brief and two anonymised repos in, scores out, and the scores go into the results JSON.

    bench/review.py --repo harness=DIR --repo plain=DIR                 # review the two repos; JSON on stdout
    bench/review.py --repo harness=DIR --repo plain=DIR --write bench/results/run-ID   # also merge into run-ID/<arm>.json
    options: --fixture NAME (default pennywise; its brief is judged against), --seed N (default 620),
             --judges N (default 3), --judge-cmd CMD (default $BENCH_REVIEW_CMD or `claude`), --model M (claude-opus-5-5)

How it works.
  * Anonymise. Each repo is copied without its git history and without the files that name the tool that wrote it
    (`.git`, `.harness*`, `.claude`, `AGENTS.md`, `CLAUDE.md`, build output); the two copies are labelled A and B.
  * N judges (default 3) each review the pair twice, once with the repos as A and B and once swapped (the order swap
    cancels a judge's preference for whichever repo it reads first), 2N verdicts in all. A judge is one fresh `claude -p`
    session on Opus with only Read, Glob and Grep, in a directory that holds `brief.md`, `A/` and `B/`; it scores each
    rubric criterion 0, 1 or 2 for each repo and answers with one JSON object.
  * A repo's score is the mean over its verdicts of the criteria's sum (out of 10), to one decimal; the per-criterion means
    are kept too.
  * Seeded. The seed (splitmix64, as bench/fuzz.py) fixes which repo is A in the first pass, the order the judges' passes
    run in and each judge's number; a re-run on the same repos builds byte-identical review directories and prompts.
    The model's own sampling is not seeded, which is why the check is a tolerance: a re-run lands within 0.5 of the first
    (test/test_bench_review.py pins the seeding and the arithmetic; a live re-run is the operator's to repeat).

The result, per arm:

    {"review_score": 7.2,
     "review": {"rubric": 1, "rubric_sha": "…", "brief_sha": "…", "model": "…", "seed": 620, "judges": 3, "verdicts": 6,
                "failed": 0, "criteria": {"conformance": 1.5, …}, "scores": [7, 8, …], "versus": "plain", "mean_gap": 1.2}}

`scores` are the arm's verdict totals in run order; `versus` names the other arm. Exit 0 when it ran, 1 when too
few judges answered to score (nothing is written), 2 for bad arguments. Stdlib only.
"""
import hashlib
import importlib.util
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
RUBRIC = os.path.join(HERE, "review", "rubric.json")
SEED = 620
JUDGES = 3
MODEL = "claude-opus-5-5"
TIMEOUT = 1800
RETRIES = 1
LABELS = ("A", "B")
DROP = shutil.ignore_patterns(".git", ".harness*", ".claude", ".cursor", ".github", "AGENTS.md", "CLAUDE.md",
                              "__pycache__", "*.pyc", "*.egg-info", ".pytest_cache", ".mypy_cache", ".venv", "venv",
                              "node_modules", "build", "dist", ".coverage", ".DS_Store")
JUDGE_FLAGS = ["-p", "--output-format", "json", "--disable-slash-commands", "--strict-mcp-config",
               "--setting-sources", "project,local", "--tools", "Read,Glob,Grep", "--no-session-persistence"]


def _load(name, rel):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, rel))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def rng(seed):
    """splitmix64, bench/fuzz.py's: the same stream on every Python."""
    return _load("bench_fuzz_rng", "fuzz.py").Rng(seed)


def load_rubric(path=RUBRIC):
    with open(path, "rb") as fh:
        raw = fh.read()
    doc = json.loads(raw.decode("utf-8"))
    return doc, hashlib.sha256(raw).hexdigest()


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


# --- the plan: who is A, in which order ----------------------------------------------------
def plan(arms, judges, seed):
    """[(judge, swapped, {label: arm})] — 2 passes per judge. The seed picks which arm is A in the very first pass; every
    judge then reviews the pair in both orders, and the passes are shuffled (seeded) so no judge always reads first."""
    if len(arms) != 2:
        raise ValueError("a review compares exactly two repos")
    r = rng(seed)
    first = list(arms)
    if r.below(2):
        first.reverse()
    passes = []
    for j in range(judges):
        for swapped in (False, True):
            order = first[::-1] if swapped else first
            passes.append((j + 1, swapped, dict(zip(LABELS, order))))
    for i in range(len(passes) - 1, 0, -1):               # Fisher-Yates with the seeded stream
        k = r.below(i + 1)
        passes[i], passes[k] = passes[k], passes[i]
    return passes


# --- the review directory ------------------------------------------------------------------
def build_dir(work, brief, mapping, repos):
    """work/brief.md, work/A/, work/B/ (the anonymised copies of repos[mapping["A"]], repos[mapping["B"]])."""
    os.makedirs(work, exist_ok=True)
    shutil.copyfile(brief, os.path.join(work, "brief.md"))
    for label, arm in mapping.items():
        shutil.copytree(repos[arm], os.path.join(work, label), symlinks=False, ignore=DROP)
    return work


def prompt_for(rubric):
    crit = "\n".join("%d. %s (`%s`): %s" % (i + 1, c["title"], c["id"], c["guidance"])
                     for i, c in enumerate(rubric["criteria"]))
    ids = ", ".join('"%s": n' % c["id"] for c in rubric["criteria"])
    return (
        "You are reviewing two implementations of the same project, A and B. The customer's brief is in brief.md; "
        "the two implementations are the folders A/ and B/ here. You do not know who or what wrote either, and it must "
        "not matter.\n\n"
        "Read the brief, then read both implementations (the code, the tests, the packaging and the docs) with the "
        "Read, Glob and Grep tools. You cannot run anything; judge by reading. Be even-handed: give each repo the same "
        "scrutiny, and judge what is there, not how much of it there is.\n\n"
        "Score each repo on every criterion below as 0, 1 or 2, using the guidance given for each:\n\n%s\n\n"
        "When you have read enough, answer with ONLY one JSON object and nothing else, shaped like\n"
        '{"A": {%s}, "B": {%s}, "notes": "one or two sentences on the biggest difference"}\n'
        "where every n is 0, 1 or 2." % (crit, ids, ids))


def parse_verdict(text, rubric):
    """{"A": {id: n}, "B": {id: n}} from a judge's answer (the claude JSON envelope or the bare verdict), or None."""
    try:
        doc = json.loads(text)
    except ValueError:
        doc = None
    if isinstance(doc, dict) and isinstance(doc.get("result"), str):
        text = doc["result"]
    elif isinstance(doc, dict) and "A" in doc:
        text = json.dumps(doc)
    ids = [c["id"] for c in rubric["criteria"]]
    decoder = json.JSONDecoder()
    for m in reversed(list(re.finditer(r"\{", text))):       # the last object that scores both repos
        try:
            obj, _ = decoder.raw_decode(text, m.start())
        except ValueError:
            continue
        if isinstance(obj, dict) and all(isinstance(obj.get(l), dict) for l in LABELS):
            good = {l: {i: obj[l].get(i) for i in ids} for l in LABELS}
            if all(isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 2
                   for l in LABELS for v in good[l].values()):
                return good
    return None


def ask(judge_cmd, model, work, prompt, config_dir=None, runner=subprocess.run):
    """One judge's answer text for the review directory `work`; None when the process failed."""
    env = {k: v for k, v in os.environ.items() if k not in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")}
    env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
    if config_dir:
        env["CLAUDE_CONFIG_DIR"] = config_dir
    argv = shlex.split(judge_cmd) + JUDGE_FLAGS + ["--model", model]
    try:
        p = runner(argv, cwd=work, env=env, input=prompt, capture_output=True, text=True, timeout=TIMEOUT)
    except (subprocess.SubprocessError, OSError):
        return None
    return p.stdout if p.returncode == 0 else None


# --- scoring -------------------------------------------------------------------------------
def mean(xs):
    return sum(xs) / len(xs) if xs else None


def tally(arms, verdicts, rubric):
    """{arm: {"score", "criteria", "scores"}} from [(mapping, verdict)] — the means over the verdicts."""
    ids = [c["id"] for c in rubric["criteria"]]
    out = {a: {"scores": [], "by": {i: [] for i in ids}} for a in arms}
    for mapping, verdict in verdicts:
        for label, arm in mapping.items():
            out[arm]["scores"].append(sum(verdict[label].values()))
            for i in ids:
                out[arm]["by"][i].append(verdict[label][i])
    return {a: {"score": round(mean(v["scores"]), 1), "criteria": {i: round(mean(x), 2) for i, x in v["by"].items()},
                "scores": v["scores"]} for a, v in out.items()}


def review(repos, brief, judge_cmd="claude", model=MODEL, seed=SEED, judges=JUDGES, rubric_path=RUBRIC,
           keep=None, runner=subprocess.run, config_dir=None):
    """{arm: {"review_score", "review"}} for the two repos {arm: dir}. Raises RuntimeError when fewer than half of the
    2 x judges passes gave a readable verdict."""
    rubric, rubric_sha = load_rubric(rubric_path)
    arms = list(repos)
    prompt = prompt_for(rubric)
    verdicts, failed = [], 0
    root = tempfile.mkdtemp(prefix="bench-review-")
    try:
        for n, (judge, swapped, mapping) in enumerate(plan(arms, judges, seed)):
            work = build_dir(os.path.join(root, "pass-%d" % n), brief, mapping, repos)
            verdict = None
            for _ in range(1 + RETRIES):
                verdict = parse_verdict(ask(judge_cmd, model, work, prompt, config_dir, runner) or "", rubric)
                if verdict:
                    break
            if verdict:
                verdicts.append((mapping, verdict))
            else:
                failed += 1
            if keep:
                shutil.copytree(work, os.path.join(keep, "pass-%d" % n))
    finally:
        shutil.rmtree(root, ignore_errors=True)
    if len(verdicts) < judges:
        raise RuntimeError("review did not run: %d of %d passes gave a verdict" % (len(verdicts), judges * 2))
    scored = tally(arms, verdicts, rubric)
    out = {}
    for arm in arms:
        other = [a for a in arms if a != arm][0]
        s = scored[arm]
        out[arm] = {"review_score": s["score"],
                    "review": {"rubric": rubric["version"], "rubric_sha": rubric_sha, "brief_sha": sha(brief),
                               "model": model, "seed": seed, "judges": judges, "verdicts": len(verdicts),
                               "failed": failed, "criteria": s["criteria"], "scores": s["scores"], "versus": other,
                               "mean_gap": round(s["score"] - scored[other]["score"], 1)}}
    return out


def merge(run_dir, results):
    """Put each arm's review_score / review into <run_dir>/<arm>.json (an aggregate keeps its runs' own)."""
    for arm, res in results.items():
        path = os.path.join(run_dir, arm + ".json")
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        doc.update(res)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2, ensure_ascii=False)
            fh.write("\n")


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description="Scripted blind review of two repos against the brief.")
    ap.add_argument("--repo", action="append", default=[], metavar="ARM=DIR")
    ap.add_argument("--fixture", default="pennywise")
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--judges", type=int, default=JUDGES)
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--judge-cmd", default=os.environ.get("BENCH_REVIEW_CMD") or "claude")
    ap.add_argument("--write", metavar="RUN_DIR", help="merge each arm's result into RUN_DIR/<arm>.json")
    a = ap.parse_args(argv)
    repos = {}
    for item in a.repo:
        arm, _, path = item.partition("=")
        if not arm or not os.path.isdir(path) or arm in repos:
            print("review.py: --repo wants ARM=DIR, a directory, once per arm: %r" % item, file=sys.stderr)
            return 2
        repos[arm] = os.path.abspath(path)
    if len(repos) != 2 or a.judges < 1:
        print("review.py: give exactly two --repo ARM=DIR (and --judges of at least 1)", file=sys.stderr)
        return 2
    try:
        brief = _load("bench_fixtures", "fixtures.py").load(a.fixture).brief
    except ValueError as exc:
        print("review.py: %s" % exc, file=sys.stderr)
        return 2
    if a.write and not all(os.path.isfile(os.path.join(a.write, arm + ".json")) for arm in repos):
        print("review.py: --write wants a results folder holding <arm>.json for both arms", file=sys.stderr)
        return 2
    cfg = tempfile.mkdtemp(prefix="bench-review-cfg-")      # the judges get the login and nothing else (bench/armlib.py)
    try:
        _load("bench_armlib", "armlib.py").isolated_config(cfg)
        results = review(repos, brief, a.judge_cmd, a.model, a.seed, a.judges, config_dir=cfg)
    except RuntimeError as exc:
        print("review.py: %s" % exc, file=sys.stderr)
        return 1
    finally:
        shutil.rmtree(cfg, ignore_errors=True)
    if a.write:
        merge(a.write, results)
    print(json.dumps(results, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
