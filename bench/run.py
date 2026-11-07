#!/usr/bin/env python3
"""run.py — the benchmark runner core (#381, PRD #345). Every arm runs through it.

    bench/run.py <arm> [--runs N] [--dry-run] [--run-id ID] [--results-dir DIR] [--arm-opt k=v]... [--workers N]
                       [--wall-cap-secs 21600] [--cost-cap-usd 80] [--expected-usd N]

One run = one arm, one fresh PRIVATE GitHub repo:

    guard -> create the repo, seed it with the brief only -> clone -> run the arm under the caps
          -> grade a fresh clone of the final default branch -> record results -> delete the repo

The repo is deleted after the results are recorded, also when the arm fails or hits a cap. Nothing
but the brief is ever put in it, and no GitHub Actions run in it.

GUARD (refuses with exit 3, before anything is created or spent; --dry-run prints the decision and
spends nothing):
  * any account usage-HELD (a *.hold file in <run dir>/usage-holds, written by the fleet's usage watch);
  * host disk short: under BENCH_MIN_FREE_GB (default 4) free on the temp dir's or the checkout's filesystem;
  * forecast-style headroom short: for every weekly window read, now% + expected% + reserve must be
    <= HARNESS_ONE_STOP_PCT, where expected% = the expected spend over the account's $ per 1% (the
    calibration forecast.py fits from the host event log, else HARNESS_ONE_USD_PER_PCT). The expected
    spend defaults to the $ cap: the most an arm can spend. No weekly reading, or no $ per 1%, refuses
    too: the guard cannot show the run fits.

CAPS (per arm, enforced while it runs): wall clock and list-price $ of its transcripts. At a cap the
arm's stop event is set, the processes it started are terminated, and the run is recorded as
`capped: wall|cost`, not dropped.

ARMS are modules `bench/arms/<arm>.py` defining run(ctx); see bench/README.md for the interface and the
results schema. Exit status: 0 recorded (ok or capped), 1 the arm failed (recorded), 2 bad arguments,
3 guard refused, 4 recorded but the repo could not be deleted (it is named on stderr — delete it).
RUNS (#591): `--runs N` (default 5) repeats the run N times, each in its own repo, because one run cannot support a
claim (agent wall time and cost vary 20-40% between runs). Every run goes through the guard and the caps again.
Run i is `<results>/<run-id>/<arm>.runs/run-NN.json` (+ `run-NN.logs/`) and `<arm>.json` is the aggregate over the
runs so far (bench/aggregate.py: median and min-max per metric). The batch stops early, recording how many runs
completed and why, when the guard refuses a later run (the budget ran out, a hold, the disk), a run's arm fails, or a
repo could not be deleted. `--runs 1` writes the single-run layout `<arm>.json` + `<arm>.logs/`, shown as `n=1`.
Optional code quality (bench/quality.py, #387) runs on the graded clone and never fails a run: Docker
absent or the scan failing is recorded as `quality: skipped (<reason>)`, and a run with any arm so skipped is
INVALID: bench/figures.py marks it "invalid: rerun" and run.py says so on stderr (#588). The arm's own tests'
line and branch coverage, subprocesses counted (bench/testcov.py), is recorded as `coverage`.
Stdlib only; reuses scripts/forecast.py and scripts/stats.py.
"""
import argparse, glob, importlib.util, json, os, re, shutil, subprocess, sys, tempfile, threading, time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCRIPTS = os.path.join(ROOT, "scripts")
BRIEF = os.path.join(ROOT, "bench/fixture/brief.md")   # the default fixture's; a run uses its fixture's (bench/fixtures.py)
GRADER = os.path.join(HERE, "grade.py")
QUALITY = os.path.join(HERE, "quality.py")
TESTCOV = os.path.join(HERE, "testcov.py")
SCHEMA = 1
RUNS_DEFAULT = 5
WALL_CAP_S = 6 * 3600
COST_CAP_USD = 80.0
WEEKLY = re.compile(r"seven|week|7d", re.I)
EXIT_OK, EXIT_ARM_FAILED, EXIT_USAGE, EXIT_REFUSED, EXIT_LEAKED = 0, 1, 2, 3, 4


def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(SCRIPTS, f"{name}.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def armlib():
    """bench/armlib.py: what the arms share (isolated config, provenance, effort), loaded by path."""
    spec = importlib.util.spec_from_file_location("bench_armlib", os.path.join(HERE, "armlib.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _bylib(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def fixtures():
    """bench/fixtures.py: which fixture a run uses (#592)."""
    return _bylib("bench_fixtures", "fixtures.py")


def progresslib():
    """bench/progress.py: milestones, regressions and the mid-run change (#592)."""
    return _bylib("bench_progress", "progress.py")


def agglib():
    """bench/aggregate.py: median and range over an arm's runs, loaded by path."""
    spec = importlib.util.spec_from_file_location("bench_aggregate", os.path.join(HERE, "aggregate.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def now_iso(t=None):
    return datetime.fromtimestamp(time.time() if t is None else t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _num(v, default=None):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


# --- guard ---------------------------------------------------------------------
def run_dir(override=None):
    if override:
        return override
    if os.environ.get("RUN_DIR"):
        return os.environ["RUN_DIR"]
    return os.path.join(os.environ.get("STATE_DIR") or os.path.join(os.getcwd(), ".harness"), "run")


def held_accounts(rdir):
    """[(account, window, pct)] of every usage hold open in <run dir>/usage-holds."""
    out = []
    for f in sorted(glob.glob(os.path.join(rdir, "usage-holds", "*.hold"))):
        try:
            with open(f, encoding="utf-8") as fh:
                parts = fh.read().rstrip("\n").split("\t")
        except OSError:
            parts = []
        parts += [""] * (3 - len(parts))
        out.append((parts[0] or os.path.basename(f)[:-5], parts[1], parts[2]))
    return out


def usage_readings():
    """[(account, window, pct, resets_at)] from the fleet's usage seam: HARNESS_USAGE_CMD if set, else
    the CLI adapter's cli_limit_usage. [] when usage is unavailable."""
    cmd = os.environ.get("HARNESS_USAGE_CMD")
    argv = ["bash", "-c", cmd] if cmd else [
        "bash", "-c", 'source "$1/lib.sh" >/dev/null 2>&1 && cli_limit_usage', "bench-usage", SCRIPTS]
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return []
    if p.returncode != 0:
        return []
    out = []
    for line in p.stdout.splitlines():
        f = line.split("\t")
        if len(f) >= 3 and f[0] and _num(f[2]) is not None:
            out.append((f[0], f[1], _num(f[2]), f[3] if len(f) > 3 else ""))
    return out


def run_account():
    """This run's account, named as the status line names it: the basename of CLAUDE_CONFIG_DIR."""
    d = os.environ.get("CLAUDE_CONFIG_DIR") or ""
    return os.path.basename(d.rstrip("/")) if d else "default"


def usd_per_pct(fc, events, account):
    """($ per 1% of the account's weekly window, source): the calibration's conservative bound, else
    HARNESS_ONE_USD_PER_PCT, else (None, "none")."""
    try:
        cal = fc.calibrate(events, accounts=(account,))
    except Exception:   # a calibration that cannot be read must not stop a run: fall back below
        cal = []
    acct = fc.norm_account(account)
    rows = [c for c in cal if c["account"] == acct and c["window"] and WEEKLY.search(c["window"]) and c["bound"]]
    if rows:
        return rows[0]["bound"], "fit"
    fb = fc.usd_per_pct_setting(os.environ.get("STATE_DIR"))
    return (fb, "fallback") if fb else (None, "none")


# why a guard refuses; a skipped optional arm records exactly the causes it was refused on (#577)
CAUSES = ("disk", "held", "no-usage-reading", "no-calibration", "budget", "no-delete-repo")


def disk_free(paths=None):
    """[{"path", "free_gb"}] for each distinct filesystem a run writes to. That is the temp dir alone: the run
    clone, Hx's and the fleet's state dir and worktrees all live under it. The checkout is only read (scripts,
    brief) and the results JSON written into it is a few KB, so its filesystem is not measured (#577). A path
    that cannot be read is left out."""
    seen, out = set(), []
    for path in paths or [tempfile.gettempdir()]:
        try:
            dev, free = os.stat(path).st_dev, shutil.disk_usage(path).free
        except OSError:
            continue
        if dev not in seen:
            seen.add(dev)
            out.append({"path": path, "free_gb": round(free / 1e9, 2)})
    return out


def gh_scopes():
    """The gh token's OAuth scopes (a list), or None when they cannot be known: gh is missing or fails, or the
    token is fine-grained and the API sends no `X-OAuth-Scopes` header. Only a KNOWN list can refuse a run (#578)."""
    try:
        p = subprocess.run(["gh", "api", "-i", "user"], capture_output=True, text=True, stdin=subprocess.DEVNULL,
                           timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if p.returncode != 0:
        return None
    for line in p.stdout.splitlines():
        name, sep, value = line.partition(":")
        if sep and name.strip().lower() == "x-oauth-scopes":
            return [x.strip() for x in value.split(",") if x.strip()]
        if not line.strip():
            break                      # end of the headers
    return None


def guard(a, fc, st):
    """{"ok", "reasons", ...the numbers}: whether a run may start. Spends nothing."""
    stop = _num(os.environ.get("HARNESS_ONE_STOP_PCT"), 98.0)
    reserve = _num(os.environ.get("HARNESS_ONE_RESERVE_PCT"), 2.0)
    expected = a.expected_usd if a.expected_usd is not None else a.cost_cap_usd
    min_gb = _num(os.environ.get("BENCH_MIN_FREE_GB"), 4.0)
    d = {"ok": True, "reasons": [], "causes": [], "held": [], "expected_usd": expected, "stop_pct": stop,
         "reserve_pct": reserve, "usd_per_pct": None, "usd_per_pct_source": "none", "windows": [],
         "min_free_gb": min_gb, "disk": disk_free(), "gh_scopes": gh_scopes()}
    if d["gh_scopes"] is not None and "delete_repo" not in d["gh_scopes"]:
        d["reasons"].append("the gh token lacks the delete_repo scope (scopes: " + (", ".join(d["gh_scopes"]) or "none")
                            + "): a run could not delete its repo afterwards. Run: gh auth refresh -s delete_repo")
        d["causes"].append("no-delete-repo")
    for fs in d["disk"]:
        fs["fits"] = fs["free_gb"] >= min_gb
        if not fs["fits"]:
            d["reasons"].append(f"host disk: {fs['path']} has {fs['free_gb']:g} GB free < {min_gb:g} GB "
                                "(a run clones repos and builds worktrees there)")
            d["causes"].append("disk")
    for acct, win, pct in held_accounts(run_dir(a.run_dir)):
        d["held"].append({"account": acct, "window": win, "pct": pct})
        d["reasons"].append(f"account {acct} is usage-HELD ({win or '?'} window at {pct or '?'}%): "
                            "the fleet claims nothing until it resets")
        d["causes"].append("held")
    reads = [r for r in usage_readings() if WEEKLY.search(r[1] or "")]
    if not reads:
        d["reasons"].append("no weekly usage reading: cannot show the run fits the window")
        d["causes"].append("no-usage-reading")
    else:
        events = st.load_events(a.events)
        per, src = usd_per_pct(fc, events, run_account())
        d["usd_per_pct"], d["usd_per_pct_source"] = per, src
        if not per:
            d["reasons"].append("no $ per 1% (no calibration in the event log and HARNESS_ONE_USD_PER_PCT "
                                "unset): cannot turn the expected spend into a % of the window")
            d["causes"].append("no-calibration")
        else:
            need = round(expected / per, 2)
            for acct, win, pct, _ in reads:
                total = round(pct + need + reserve, 2)
                d["windows"].append({"account": acct, "window": win, "now_pct": pct, "need_pct": need,
                                     "total_pct": total, "fits": total <= stop})
                if total > stop:
                    d["reasons"].append(f"{acct} {win}: {pct:g}% now + {need:g}% expected (${expected:g}) + "
                                        f"{reserve:g}% reserve = {total:g}% > {stop:g}%")
                    d["causes"].append("budget")
    d["causes"] = [c for c in CAUSES if c in d["causes"]]   # each cause once, in a fixed order
    d["ok"] = not d["reasons"]
    return d


def render_guard(d):
    if d["ok"]:
        return "bench guard: OK — " + (", ".join(
            f"{w['account']} {w['window']} {w['now_pct']:g}% + {w['need_pct']:g}% + {d['reserve_pct']:g}% = "
            f"{w['total_pct']:g}% <= {d['stop_pct']:g}%" for w in d["windows"]) or "no windows")
    return "bench guard: REFUSED\n" + "\n".join("  - " + r for r in d["reasons"])


# --- GitHub / git ----------------------------------------------------------------
class Gh:
    """The few gh and git calls a run makes — all through PATH, so tests fake them."""

    def __init__(self, log):
        self.log = log

    def _run(self, argv, cwd=None, check=True):
        p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=300)
        self.log(f"$ {' '.join(argv)} -> {p.returncode}")
        if check and p.returncode != 0:
            raise RuntimeError(f"{' '.join(argv[:3])} failed: {(p.stderr or p.stdout).strip()[:300]}")
        return p

    def owner(self, override=None):
        return override or self._run(["gh", "api", "user", "-q", ".login"]).stdout.strip()

    def create(self, repo):
        self._run(["gh", "repo", "create", repo, "--private", "--description", "benchmark run: deleted after"])

    def no_actions(self, repo):
        self._run(["gh", "api", "-X", "PUT", f"repos/{repo}/actions/permissions", "-F", "enabled=false"],
                  check=False)

    def clone(self, repo, dest):
        self._run(["gh", "repo", "clone", repo, dest])

    def seed(self, repo, clone, brief=BRIEF):
        """Commit the brief — and nothing else — to the repo's default branch."""
        shutil.copyfile(brief, os.path.join(clone, "brief.md"))
        git = ["git", "-c", "user.name=bench", "-c", "user.email=bench@localhost"]
        self._run(git + ["checkout", "-B", "main"], cwd=clone)
        self._run(["git", "add", "brief.md"], cwd=clone)
        self._run(git + ["commit", "-m", "brief"], cwd=clone)
        self._run(["git", "push", "-u", "origin", "main"], cwd=clone)

    def delete(self, repo):
        return self._run(["gh", "repo", "delete", repo, "--yes"], check=False).returncode == 0


# --- arm interface ------------------------------------------------------------------
class Ctx:
    """What an arm is handed. It runs the arm in clone, on repo, and must stop when `stop` is set."""

    def __init__(self, arm, repo, clone, logs, stop, opts, caps, log):
        self.arm, self.repo, self.clone, self.logs, self.stop = arm, repo, clone, logs, stop
        self.opts, self.caps, self.log = opts, caps, log
        self.brief = os.path.join(clone, "brief.md")
        self.run = None   # 1-based index of this run in a `--runs N` batch (#591); None for `--runs 1`
        self.transcripts, self.counts = [], {}
        self.extra = {}   # more top-level fields for the results JSON (never one the runner owns)
        self.fixture = None   # bench/fixtures.py's Fixture of this run (#592)
        self.change = None    # bench/progress.py's Change: the mid-run requirement change, or None
        self._procs, self._lock = [], threading.Lock()

    def add_transcripts(self, *paths):
        """Claude-format session transcripts (main ones: their sub-agents' sit beside them). The cost cap
        is measured on these, and they are copied into the run's logs."""
        with self._lock:
            self.transcripts += [p for p in paths if p not in self.transcripts]

    def count(self, name, n=1):
        with self._lock:
            self.counts[name] = self.counts.get(name, 0) + n

    def next_change(self, done=False):
        """The mid-run requirement change (#592), once, when it is due: the text to hand to the agent exactly as given,
        else None (no change in this fixture, not yet fired, or already taken). `done=True`: the arm is about to
        stop; a change that has not fired yet fires now, so no arm finishes without it."""
        return self.change.take(done) if self.change is not None else None

    def change_due(self):
        """True when the change has fired and the arm has not taken it (an arm may interrupt a long turn for it)."""
        return self.change is not None and self.change.due()

    def spawn(self, argv, **kw):
        """subprocess.Popen, tracked: the runner terminates it (by its own handle) at a cap."""
        p = subprocess.Popen(argv, **kw)
        with self._lock:
            self._procs.append(p)
        return p

    def terminate(self, grace=10.0):
        with self._lock:
            procs = list(self._procs)
        for p in procs:
            if p.poll() is None:
                p.terminate()
        end = time.time() + grace
        for p in procs:
            try:
                p.wait(timeout=max(0.0, end - time.time()))
            except subprocess.TimeoutExpired:
                p.kill()


def load_arm(name, arms_dir):
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", name or ""):
        raise ValueError(f"bad arm name {name!r}")
    path = os.path.join(arms_dir, f"{name}.py")
    if not os.path.isfile(path):
        have = sorted(os.path.basename(f)[:-3] for f in glob.glob(os.path.join(arms_dir, "*.py")))
        raise ValueError(f"no arm {name!r} in {arms_dir} (have: {', '.join(have) or 'none'})")
    spec = importlib.util.spec_from_file_location(f"bench_arm_{name}", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    if not callable(getattr(mod, "run", None)):
        raise ValueError(f"arm {name!r} defines no run(ctx)")
    return mod


# --- measuring ----------------------------------------------------------------------
def measure(fc, st, transcripts):
    """Tokens, list-price $ and models of the transcripts (each also counting its sub-agents' files, every
    message once), and the coding / testing split of their main sessions (#379)."""
    seen, models = set(), {}
    for tr in transcripts:
        for f in st.transcript_files(tr):
            for key, model, u, _, _ in fc._messages(f):
                if key in seen:
                    continue
                seen.add(key)
                cc = u.get("cache_creation_input_tokens")
                if cc is None:
                    cc = sum(int(v or 0) for v in (u.get("cache_creation") or {}).values())
                m = models.setdefault(model, {"messages": 0, "input": 0, "output": 0, "cache_read": 0,
                                              "cache_write": 0, "cost_usd": 0.0})
                m["messages"] += 1
                m["input"] += int(u.get("input_tokens") or 0)
                m["output"] += int(u.get("output_tokens") or 0)
                m["cache_read"] += int(u.get("cache_read_input_tokens") or 0)
                m["cache_write"] += int(cc or 0)
                m["cost_usd"] += fc.raw_cost(u, model)
    for m in models.values():
        m["cost_usd"] = round(m["cost_usd"], 4)
    tokens = {k: sum(m[k] for m in models.values()) for k in ("input", "output", "cache_read", "cache_write")}
    splits = [s for s in (st.time_split(t) for t in transcripts) if s]
    split = None if not splits else {k: sum(s[k] for s in splits) for k in ("coding_s", "testing_s", "test_calls")}
    return {"tokens": tokens, "models": models, "cost_usd": round(sum(m["cost_usd"] for m in models.values()), 4),
            "split": split}


def cost_now(fc, st, transcripts):
    try:
        return measure(fc, st, transcripts)["cost_usd"]
    except Exception:   # a transcript being written mid-read: look again at the next poll
        return 0.0


GRADED = "graded"


def grade(repo, workdir, gh, log, grader, fixture=None):
    """The hidden-tests fragment for a fresh clone of the repo's final default branch, or an error stub."""
    dest = os.path.join(workdir, GRADED)
    try:
        gh.clone(repo, dest)
        extra = ["--fixture", fixture] if fixture and fixture != fixtures().DEFAULT else []
        p = subprocess.run([sys.executable, grader, dest] + extra, capture_output=True, text=True, timeout=3600,
                           stdin=subprocess.DEVNULL)
        log(f"grade -> {p.returncode}")
        if p.returncode != 0:
            raise RuntimeError((p.stderr or p.stdout).strip()[:300])
        return json.loads(p.stdout)
    except Exception as e:
        log(f"grade failed: {e}")
        return {"passed": 0, "failed": None, "total": None, "details": {"error": str(e)[:300]}}


def derived_fields(res, fx, watcher, ctx, st, logs, wall_s):
    """The measures of #592 that come from more than the end-of-run grade: $ per passed hidden test, compactions,
    and, for a fixture with milestones, the change request, the milestones, the regressions and the wall time of the
    first full pass. The raw milestones, per test, are kept in <logs>/milestones.json."""
    out = {}
    passed = (res.get("hidden_tests") or {}).get("passed")
    if isinstance(passed, int) and passed > 0:
        out["usd_per_passed_test"] = round(res["cost_usd"] / passed, 4)
    try:
        out["compactions"] = armlib().compactions(st, ctx.transcripts)
    except Exception:
        pass
    if watcher is not None:
        watcher.add_final({"details": res["hidden_tests"].get("details")}, wall_s)
        out.update(progresslib().summarize(watcher.milestones, ctx.change))
        watcher.dump(os.path.join(logs, "milestones.json"))
    return out


def fuzz_fields(fuzz):
    """The `fuzz_*` results keys from the grader's `fuzz` fragment (bench/fuzz.py, #589); `fuzz_error` when it
    could not run, nothing when the grader is an older one that has no fuzz."""
    if not isinstance(fuzz, dict):
        return {}
    if "fuzz_cases" in fuzz:
        return {k: fuzz[k] for k in ("fuzz_cases", "fuzz_divergences", "fuzz_classes", "fuzz_class_counts",
                                     "fuzz_examples", "fuzz_seed", "fuzz_hash") if k in fuzz}
    return {"fuzz_error": str(fuzz.get("error") or "fuzz did not run")[:300]}


def quality(workdir, script, log, timeout=2700):
    """The code-quality fragment ({"quality": ..., ["sonarqube": {...}]}) for the graded clone. Optional and
    never blocking: whatever goes wrong is `quality: skipped (<reason>)` (bench/quality.py, #387)."""
    def skipped(why):
        log(f"quality skipped: {why}")
        return {"quality": f"skipped ({' '.join(str(why).split())[:300]})"}
    dest = os.path.join(workdir, GRADED)
    if not os.path.isdir(dest):
        return skipped("no clone of the final default branch to scan")
    try:
        p = subprocess.run([sys.executable, script, dest], capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL)
        why = f"exit {p.returncode}: {(p.stderr or p.stdout).strip()[:200]}"
        if p.returncode != 0:
            raise ValueError(why)
        frag = json.loads(p.stdout)
        if not isinstance(frag, dict) or not isinstance(frag.get("quality"), str):
            raise ValueError(why)
        if frag["quality"] == "ok" and not isinstance(frag.get("sonarqube"), dict):
            raise ValueError("ok without measures")
        log(f"quality -> {frag['quality']}")
        return {k: frag[k] for k in ("quality", "sonarqube") if k in frag}
    except Exception as e:   # includes a timeout and an unreadable fragment
        return skipped(f"quality scan failed: {e}")


def coverage(workdir, script, log, timeout=1800):
    """The coverage fragment ({"coverage": {"line_pct", "branch_pct", "total_pct", "tests"} | "skipped (<reason>)"})
    for the graded clone's own tests, subprocesses counted (bench/testcov.py, #588). Never blocking."""
    def skipped(why):
        log(f"coverage skipped: {why}")
        return {"coverage": f"skipped ({' '.join(str(why).split())[:300]})"}
    dest = os.path.join(workdir, GRADED)
    if not os.path.isdir(dest):
        return skipped("no clone of the final default branch to measure")
    try:
        p = subprocess.run([sys.executable, script, dest], capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL)
        why = f"exit {p.returncode}: {(p.stderr or p.stdout).strip()[:200]}"
        if p.returncode != 0:
            raise ValueError(why)
        c = json.loads(p.stdout).get("coverage")
        if not valid_coverage(c):
            raise ValueError(why)
        log(f"coverage -> {c}")
        return {"coverage": c}
    except Exception as e:   # includes a timeout and an unreadable fragment
        return skipped(f"coverage run failed: {e}")


def valid_coverage(c):
    """A `coverage` value: {line_pct, branch_pct} numbers, or `skipped (<reason>)`."""
    if isinstance(c, str):
        return c.startswith("skipped (") and c.endswith(")")
    return isinstance(c, dict) and all(isinstance(c.get(k), (int, float)) and not isinstance(c.get(k), bool)
                                       for k in ("line_pct", "branch_pct"))


# --- results ---------------------------------------------------------------------------
REQUIRED = {
    "schema": int, "run_id": str, "arm": str, "repo": str, "status": str, "capped": (str, type(None)),
    "error": (str, type(None)), "started_at": str, "ended_at": str, "wall_s": (int, float),
    "coding_s": (int, float, type(None)), "testing_s": (int, float, type(None)),
    "test_calls": (int, type(None)), "tokens": dict, "cost_usd": (int, float),
    "usd_per_pct": (int, float, type(None)), "usd_per_pct_source": str,
    "weekly_window_pct": (int, float, type(None)), "models": dict, "hidden_tests": dict,
    "counts": dict, "caps": dict, "repo_deleted": (bool, type(None)), "logs": str,
}


# Optional (results written before #589 have none): bench/fuzz.py's differential fuzz of the graded build.
# Optional (results written before #590 have none): the effort the transcripts show, what the arm configured, and
# the engine commit / skill version / CLI version the arm ran with.
PROVENANCE_KEYS = ("engine_commit", "skill_version", "cli_version")
FUZZ_FIELDS = {"fuzz_cases": int, "fuzz_divergences": int, "fuzz_examples": list, "fuzz_seed": int,
               "fuzz_hash": str, "fuzz_error": str, "fuzz_classes": int, "fuzz_class_counts": dict}
# Optional (#620): the scripted blind review (bench/review.py): `review_score` is its mean (0..10), `review` the detail.
REVIEW_FIELDS = {"review_score": (int, float), "review": dict}


def valid_reason(reason):
    """A skipped record's `reason`: the guard's causes, comma-joined, each a known one."""
    parts = reason.split(",")
    return all(p in CAUSES for p in parts) and len(set(parts)) == len(parts)


def validate_skipped(d):
    """[problem] for a `status: skipped` record (an optional arm the guard refused, #386)."""
    want = {"schema": int, "run_id": str, "arm": str, "status": str, "reason": str, "skipped_at": str, "guard": dict}
    bad = [f"missing {k}" if k not in d else f"{k}: {type(d[k]).__name__}"
           for k, t in want.items() if k not in d or not isinstance(d[k], t)]
    if not bad and (d["schema"] != SCHEMA or d["status"] != "skipped" or not valid_reason(d["reason"])):
        bad.append("skipped record must be schema 1, status skipped, reason one or more of " + ",".join(CAUSES))
    return bad


def validate(d):
    """[problem] — empty when `d` matches the documented results schema (bench/README.md)."""
    if d.get("status") == "skipped":
        return validate_skipped(d)
    if d.get("status") == "aggregate":
        return agglib().validate_aggregate(d)
    bad = [f"missing {k}" if k not in d else f"{k}: {type(d[k]).__name__}"
           for k, t in REQUIRED.items() if k not in d or not isinstance(d[k], t) or
           (isinstance(d[k], bool) and bool not in (t if isinstance(t, tuple) else (t,)))]
    if bad:
        return bad
    if d["schema"] != SCHEMA:
        bad.append(f"schema {d['schema']} != {SCHEMA}")
    if d["status"] not in ("ok", "capped", "error"):
        bad.append(f"status {d['status']!r}")
    if (d["status"] == "capped") != (d["capped"] is not None) or d["capped"] not in (None, "wall", "cost"):
        bad.append(f"capped {d['capped']!r} does not match status {d['status']!r}")
    if sorted(d["tokens"]) != ["cache_read", "cache_write", "input", "output"]:
        bad.append("tokens keys")
    if sorted(d["caps"]) != ["cost_usd", "wall_s"]:
        bad.append("caps keys")
    if not all(k in d["hidden_tests"] for k in ("passed", "failed", "total")):
        bad.append("hidden_tests needs passed/failed/total")
    if "run" in d and (not isinstance(d["run"], int) or isinstance(d["run"], bool) or d["run"] < 1):
        bad.append(f"run: {d['run']!r}")
    for k, t in FUZZ_FIELDS.items():
        if k in d and (not isinstance(d[k], t) or isinstance(d[k], bool)):
            bad.append(f"{k}: {type(d[k]).__name__}")
    prov = d.get("provenance")
    if "provenance" in d and not (isinstance(prov, dict) and sorted(prov) == sorted(PROVENANCE_KEYS)
                                  and all(v is None or isinstance(v, str) for v in prov.values())):
        bad.append(f"provenance: want {', '.join(PROVENANCE_KEYS)} (strings or null)")
    eff = d.get("effort")
    if "effort" in d and not (isinstance(eff, dict) and all(isinstance(k, str) and isinstance(v, int)
                                                            and not isinstance(v, bool) for k, v in eff.items())):
        bad.append("effort: want {effort: messages}")
    conf = d.get("configured")
    if "configured" in d and not (isinstance(conf, dict) and sorted(conf) == ["effort", "model"]
                                  and all(v is None or isinstance(v, str) for v in conf.values())):
        bad.append("configured: want {model, effort} (strings or null)")
    for k, t in REVIEW_FIELDS.items():
        if k in d and (not isinstance(d[k], t) or isinstance(d[k], bool)):
            bad.append(f"{k}: {type(d[k]).__name__}")
    if isinstance(d.get("review_score"), (int, float)) and not isinstance(d.get("review_score"), bool) \
            and not 0 <= d["review_score"] <= 10:
        bad.append("review_score: not within 0..10")
    counts = d.get("fuzz_class_counts")
    if isinstance(counts, dict):
        if not all(isinstance(k, str) and isinstance(v, int) and not isinstance(v, bool) and v > 0
                   for k, v in counts.items()):
            bad.append("fuzz_class_counts: want {class: raw divergences (a positive int)}")
        elif "fuzz_classes" in d and d["fuzz_classes"] != len(counts):
            bad.append("fuzz_classes does not match fuzz_class_counts")
        elif isinstance(d.get("fuzz_divergences"), int) and sum(counts.values()) != d["fuzz_divergences"]:
            bad.append("fuzz_class_counts do not add up to fuzz_divergences")
    if isinstance(d.get("fuzz_examples"), list) and len(d["fuzz_examples"]) > 10:
        bad.append("fuzz_examples: more than 10")
    if isinstance(d.get("fuzz_divergences"), int) and isinstance(d.get("fuzz_cases"), int) \
            and d["fuzz_divergences"] > d["fuzz_cases"]:
        bad.append("fuzz_divergences > fuzz_cases")
    q = d.get("quality")
    if "quality" in d and not (q == "ok" and isinstance(d.get("sonarqube"), dict)
                               or isinstance(q, str) and q.startswith("skipped (") and "sonarqube" not in d):
        bad.append(f"quality {q!r} does not match sonarqube")
    if "coverage" in d and not valid_coverage(d["coverage"]):
        bad.append(f"coverage {d['coverage']!r} is neither line_pct / branch_pct nor skipped (<reason>)")
    return bad


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)


def parse_args(argv):
    ap = argparse.ArgumentParser(prog="bench/run.py", description="run one benchmark arm (#381)")
    ap.add_argument("arm")
    ap.add_argument("--runs", type=int, default=RUNS_DEFAULT, metavar="N",
                    help=f"runs per arm, each in its own repo (default {RUNS_DEFAULT}); the batch records an aggregate "
                         "(median, min-max) and stops early, recording why, when the budget runs out. --runs 1 is n=1")
    ap.add_argument("--dry-run", action="store_true", help="print the guard decision; spend and create nothing")
    ap.add_argument("--run-id", default=None, help="default: a UTC timestamp")
    ap.add_argument("--results-dir", default=os.path.join(HERE, "results"))
    ap.add_argument("--owner", default=None, help="GitHub owner for the run repo (default: the gh login)")
    ap.add_argument("--arm-opt", action="append", default=[], metavar="K=V", help="passed to the arm as ctx.opts")
    ap.add_argument("--optional", action="store_true",
                    help="an optional arm: when the guard refuses, record `skipped: <cause>` (the cause(s) the guard "
                         "refused on: disk, held, no-usage-reading, no-calibration, budget; with its numbers) as <arm>.json and exit 0, instead of refusing")
    ap.add_argument("--workers", type=int, default=None, metavar="N",
                    help="the fleet's worker count for an arm that runs one (same as --arm-opt workers=N)")
    ap.add_argument("--fixture", default=fixtures().DEFAULT, choices=fixtures().names(),
                    help="which fixture the arms build (default pennywise, a 4.7 KB brief; large is the 20-page brief "
                         "with a mid-run requirement change, graded at milestones; bench/fixtures.py)")
    ap.add_argument("--progress-poll-secs", type=float, default=progresslib().POLL_S,
                    help="a fixture with milestones: how often the repo is graded while the arm works (default 300)")
    ap.add_argument("--wall-cap-secs", type=float, default=WALL_CAP_S)
    ap.add_argument("--cost-cap-usd", type=float, default=COST_CAP_USD)
    ap.add_argument("--expected-usd", type=float, default=None, help="expected spend for the guard (default: the cap)")
    ap.add_argument("--run-dir", default=None, help="the fleet run dir holding usage-holds/ (default: $RUN_DIR)")
    ap.add_argument("--poll-secs", type=float, default=5.0)
    ap.add_argument("--grace-secs", type=float, default=30.0, help="how long a stopped arm has to return")
    ap.add_argument("--arms-dir", default=os.path.join(HERE, "arms"), help=argparse.SUPPRESS)
    ap.add_argument("--events", default=None, help=argparse.SUPPRESS)
    ap.add_argument("--grader", default=GRADER, help=argparse.SUPPRESS)
    ap.add_argument("--quality", default=QUALITY, help=argparse.SUPPRESS)
    ap.add_argument("--testcov", default=TESTCOV, help=argparse.SUPPRESS)
    return ap.parse_args(argv)


def main(argv=None):
    a = parse_args(sys.argv[1:] if argv is None else argv)
    opts = {}
    for kv in a.arm_opt:
        k, sep, v = kv.partition("=")
        if not sep or not k:
            print(f"bench: bad --arm-opt {kv!r} (want K=V)", file=sys.stderr)
            return EXIT_USAGE
        opts[k] = v
    if a.workers is not None:
        if a.workers < 1:
            print("bench: --workers must be at least 1", file=sys.stderr)
            return EXIT_USAGE
        opts["workers"] = str(a.workers)
    if a.runs < 1:
        print("bench: --runs must be at least 1", file=sys.stderr)
        return EXIT_USAGE
    if a.wall_cap_secs <= 0 or a.cost_cap_usd <= 0:
        print("bench: the caps must be positive", file=sys.stderr)
        return EXIT_USAGE
    try:
        arm = load_arm(a.arm, a.arms_dir)
    except ValueError as e:
        print(f"bench: {e}", file=sys.stderr)
        return EXIT_USAGE
    fc, st = _load("forecast"), _load("stats")

    g = guard(a, fc, st)
    print(render_guard(g), file=sys.stderr if not g["ok"] and not a.optional else sys.stdout)
    if not g["ok"]:
        if a.optional and not a.dry_run:
            return record_skipped(a, g)
        return EXIT_REFUSED
    if a.dry_run:
        if a.runs > 1:
            print(f"bench: would run {a.runs} runs of {a.arm}, each guarded again before it starts")
        return EXIT_OK
    return execute(a, arm, opts, g, fc, st)


def record_skipped(a, g):
    """An optional arm the guard refused: nothing is created or spent; the refusal is the recorded outcome
    (`status: skipped`, `reason`: the guard's cause(s), comma-joined, the guard's numbers) in <results>/<run-id>/<arm>.json (#386)."""
    run_id = a.run_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = os.path.join(a.results_dir, run_id)
    os.makedirs(out_dir, exist_ok=True)
    doc = {"schema": SCHEMA, "run_id": run_id, "arm": a.arm, "status": "skipped",
           "reason": ",".join(g["causes"]),
           "skipped_at": now_iso(), "guard": {k: g[k] for k in (
               "reasons", "causes", "held", "expected_usd", "stop_pct", "reserve_pct", "usd_per_pct", "usd_per_pct_source",
               "windows", "min_free_gb", "disk", "gh_scopes")}}
    path = os.path.join(out_dir, f"{a.arm}.json")
    write_json(path, doc)
    print(f"bench: {a.arm} skipped: {doc['reason']}: {path}")
    return EXIT_OK


def link_speedup(results_dir, run_id):
    """When a run holds both `harness.json` and `harness-3.json`, put the 1 -> 3 worker speed-up (#592) into
    `harness-3.json` as `speedup_1_to_3`. Either arm may have been run first; the field is recomputed each time."""
    base = os.path.join(results_dir, run_id)
    docs = {}
    for arm in ("harness", "harness-3"):
        try:
            with open(os.path.join(base, arm + ".json"), encoding="utf-8") as fh:
                docs[arm] = json.load(fh)
        except (OSError, ValueError):
            return None
    sp = agglib().speedup(docs["harness"], docs["harness-3"])
    if sp is not None:
        docs["harness-3"]["speedup_1_to_3"] = sp
        write_json(os.path.join(base, "harness-3.json"), docs["harness-3"])
    return sp


def new_run_id(a):
    """--run-id, else a UTC timestamp; a run of the large fixture ends in `-large`, so its results never share a
    directory (and an arm's file name) with a pennywise run's (#592)."""
    suffix = "" if a.fixture == fixtures().DEFAULT else "-" + a.fixture
    return a.run_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + suffix


def run_slot(a, run_id, index=None):
    """Where one run's files go. `index` None is the single-run layout (`--runs 1`): <arm>.json and <arm>.logs/
    in the run dir. Otherwise run `index` of a batch: <arm>.runs/run-NN.json and run-NN.logs/, repo ...-rNN."""
    base = os.path.join(a.results_dir, run_id)
    if index is None:
        return {"run_id": run_id, "out_dir": base, "json": f"{a.arm}.json", "logs": f"{a.arm}.logs",
                "repo": f"bench-{run_id.lower()}-{a.arm}", "index": None, "file": f"{a.arm}.json"}
    name = f"run-{index:02d}"
    return {"run_id": run_id, "out_dir": os.path.join(base, f"{a.arm}.runs"), "json": f"{name}.json",
            "logs": f"{name}.logs", "repo": f"bench-{run_id.lower()}-{a.arm}-r{index:02d}", "index": index,
            "file": f"{a.arm}.runs/{name}.json"}


def execute(a, arm, opts, g, fc, st):
    """The runs of `--runs N`, each guarded, run and recorded on its own; `g` is the guard decision for the first.
    Returns the exit status (see the module docstring): 4 beats 1 beats 0."""
    run_id = new_run_id(a)
    code = execute_batch(a, arm, opts, g, fc, st, run_id)
    if a.arm in ("harness", "harness-3"):
        link_speedup(a.results_dir, run_id)
    return code


def execute_batch(a, arm, opts, g, fc, st, run_id):
    if a.runs == 1:
        return execute_one(a, arm, opts, g, fc, st, run_slot(a, run_id))[0]
    agg_path = os.path.join(a.results_dir, run_id, f"{a.arm}.json")
    runs, docs, stopped, exit_code = [], [], None, EXIT_OK
    for i in range(1, a.runs + 1):
        if i > 1:   # the first run was guarded by main(); every later one is guarded again, on the usage the earlier ones left
            g = guard(a, fc, st)
            if not g["ok"]:
                print(render_guard(g), file=sys.stderr)
                stopped = {"reason": "guard", "causes": g["causes"], "detail": "; ".join(g["reasons"])}
                break
        slot = run_slot(a, run_id, i)
        code, res = execute_one(a, arm, opts, g, fc, st, slot)
        runs.append({"run": i, "file": slot["file"], "status": res["status"], "capped": res["capped"]})
        docs.append(res)
        write_aggregate(a, run_id, agg_path, runs, docs, stopped)   # also after each run: a killed batch keeps its record
        if code == EXIT_LEAKED:
            stopped = {"reason": "repo-not-deleted", "detail": f"{res['repo']} could not be deleted; no further repo is created"}
            exit_code = code
            break
        if res["status"] == "error":
            stopped = {"reason": "arm-error", "detail": res["error"] or "the arm failed"}
            exit_code = code
            break
    doc = write_aggregate(a, run_id, agg_path, runs, docs, stopped)
    why = f"; stopped early: {stopped['reason']}: {stopped['detail']}" if stopped else ""
    print(f"bench: {a.arm}: {doc['runs_completed']} of {a.runs} runs completed{why}: {agg_path}")
    return exit_code


def write_aggregate(a, run_id, path, runs, docs, stopped):
    """<arm>.json for a batch: the runs so far, how many completed of how many were asked for, why it stopped
    (null when it did not), and the median and range of every metric (bench/aggregate.py)."""
    lib = agglib()
    agg = lib.aggregate(docs)
    doc = {"schema": SCHEMA, "run_id": run_id, "arm": a.arm, "status": "aggregate", "runs_requested": a.runs,
           "runs_completed": agg["n"], "stopped": stopped, "runs": runs, "aggregate": agg}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write_json(path, doc)
    return doc


def execute_one(a, arm, opts, g, fc, st, slot):
    """One run, in its own repo, recorded under `slot` (see run_slot). Returns (exit status, results doc)."""
    run_id, out_dir = slot["run_id"], slot["out_dir"]
    logs = os.path.join(out_dir, slot["logs"])
    os.makedirs(logs, exist_ok=True)
    runlog = open(os.path.join(logs, "run.log"), "a", encoding="utf-8")

    def log(msg):
        runlog.write(f"{now_iso()} {msg}\n")
        runlog.flush()

    gh, work, repo, leaked = Gh(log), tempfile.mkdtemp(prefix="bench-run-"), None, False
    caps = {"wall_s": a.wall_cap_secs, "cost_usd": a.cost_cap_usd}
    fx, watcher = fixtures().load(a.fixture), None
    res = {"schema": SCHEMA, "run_id": run_id, "arm": a.arm, "fixture": fx.name, "repo": "", "status": "ok", "capped": None,
           "error": None, "started_at": now_iso(), "ended_at": "", "wall_s": 0.0, "coding_s": None,
           "testing_s": None, "test_calls": None, "tokens": dict.fromkeys(("input", "output", "cache_read", "cache_write"), 0),
           "cost_usd": 0.0, "usd_per_pct": g["usd_per_pct"], "usd_per_pct_source": g["usd_per_pct_source"],
           "weekly_window_pct": None, "models": {}, "hidden_tests": {"passed": 0, "failed": None, "total": None},
           "counts": {}, "caps": caps, "repo_deleted": None, "logs": os.path.basename(logs),
           "quality": "skipped (not run)", "coverage": "skipped (not run)"}
    if slot["index"] is not None:
        res["run"] = slot["index"]
    ctx = None
    try:
        try:
            repo = f"{gh.owner(a.owner)}/{slot['repo']}"
            res["repo"] = repo
            log(f"run {run_id} arm {a.arm} repo {repo}")
            gh.create(repo)
            gh.no_actions(repo)
            clone = os.path.join(work, "clone")
            gh.clone(repo, clone)
            gh.seed(repo, clone, fx.brief)
            ctx = Ctx(a.arm, repo, clone, logs, threading.Event(), opts, caps, log)
            ctx.run, ctx.fixture = slot["index"], fx
            t0 = time.time()
            if fx.milestones:   # graded while it works; the mid-run change fires on progress (bench/progress.py)
                pl = progresslib()
                ctx.change = pl.Change(fx.change, fx.change_at, t0) if fx.change else None
                watcher = pl.Watcher(fx, repo, work, gh, log, a.grader, ctx.change, t0, a.progress_poll_secs).start()
            try:
                res["capped"] = run_arm(a, arm, ctx, fc, st, t0, log)
            finally:
                if watcher is not None:
                    watcher.finish()
            res["wall_s"] = round(time.time() - t0, 3)
            res["status"] = "capped" if res["capped"] else "ok"
        except Exception as e:   # the arm's own failure, or the repo lifecycle's: recorded, never lost
            log(f"failed: {e!r}")
            res["status"], res["error"] = "error", str(e)[:500] or repr(e)
            if ctx is not None:
                ctx.stop.set()
                ctx.terminate(a.grace_secs)
            if watcher is not None:
                watcher.finish()
        if ctx is not None:
            res["counts"] = dict(ctx.counts)
            res.update({k: v for k, v in ctx.extra.items() if k not in res})
            m = measure(fc, st, ctx.transcripts)
            res.update(tokens=m["tokens"], models=m["models"], cost_usd=m["cost_usd"])
            if m["split"]:
                res.update(m["split"])
            copy_transcripts(ctx, logs)
            try:   # what ran and what it ran on (#590); never fails a run
                lib = armlib()
                res["effort"] = lib.efforts(st, ctx.transcripts)
                res["provenance"] = lib.provenance(opts.get("claude", "claude"))
            except Exception as e:
                log(f"provenance/effort: {e!r}")
            graded = grade(repo, work, gh, log, a.grader, fx.name)
            write_json(os.path.join(logs, "grade.json"), graded)
            res["hidden_tests"] = {k: v for k, v in graded.items() if k != "fuzz"}
            res.update(fuzz_fields(graded.get("fuzz")))
            res.update(derived_fields(res, fx, watcher, ctx, st, logs, time.time() - t0))
            res.update(quality(work, a.quality, log))
            res.update(coverage(work, a.testcov, log))
            if not str(res.get("quality")).startswith("ok"):
                print(f"bench: INVALID RUN: the {a.arm} arm's quality scan was skipped ({res['quality']}); a host "
                      "problem must not count against an arm: fix it and rerun the whole run", file=sys.stderr)
            res["weekly_window_pct"] = (round(m["cost_usd"] / g["usd_per_pct"], 2) if g["usd_per_pct"] else None)
        res["ended_at"] = now_iso()
        write_json(os.path.join(out_dir, slot["json"]), res)
    finally:
        if repo and res["repo"]:
            res["repo_deleted"] = gh.delete(repo)
            leaked = not res["repo_deleted"]
            log(f"repo deleted: {res['repo_deleted']}")
            if os.path.isfile(os.path.join(out_dir, slot["json"])):
                write_json(os.path.join(out_dir, slot["json"]), res)
        shutil.rmtree(work, ignore_errors=True)
        runlog.close()
    if leaked:
        print(f"bench: COULD NOT DELETE {repo} — delete it by hand (gh repo delete {repo})", file=sys.stderr)
        return EXIT_LEAKED, res
    print(f"bench: {a.arm}{' run ' + str(slot['index']) if slot['index'] else ''} {res['status']}"
          f"{' (' + res['capped'] + ')' if res['capped'] else ''}: {os.path.join(out_dir, slot['json'])}")
    return (EXIT_ARM_FAILED if res["status"] == "error" else EXIT_OK), res


def run_arm(a, arm, ctx, fc, st, t0, log):
    """Run the arm in a thread and watch the caps. Returns "wall", "cost" or None; re-raises the arm's error."""
    box = {}

    def target():
        try:
            box["ret"] = arm.run(ctx)
        except BaseException as e:   # recorded by the caller as the run's error
            box["err"] = e

    th = threading.Thread(target=target, daemon=True)
    th.start()
    capped = None
    while th.is_alive():
        th.join(a.poll_secs)
        if not th.is_alive():
            break
        if time.time() - t0 >= a.wall_cap_secs:
            capped = "wall"
        elif cost_now(fc, st, ctx.transcripts) >= a.cost_cap_usd:
            capped = "cost"
        if capped:
            log(f"cap hit: {capped}; stopping the arm")
            ctx.stop.set()
            ctx.terminate(a.grace_secs)
            th.join(a.grace_secs)
            break
    if "err" in box and not capped:
        raise box["err"]
    ret = box.get("ret")
    if isinstance(ret, dict):
        for k, v in (ret.get("counts") or {}).items():
            ctx.counts[k] = v
        ctx.add_transcripts(*(ret.get("transcripts") or []))
    return capped


def subagent_files(transcript):
    """The sub-agent transcripts beside a session transcript: <transcript minus .jsonl>/subagents/*.jsonl,
    where scripts/stats.py (transcript_files) reads them."""
    return sorted(glob.glob(os.path.join(transcript[:-len(".jsonl")], "subagents", "*.jsonl")))


def copy_transcripts(ctx, logs):
    """The transcripts an arm named, kept beside the results as raw logs (#579): each main transcript as
    `transcripts/<i>-<name>.jsonl` with its sub-agent transcripts in `transcripts/<i>-<name>/subagents/`,
    the layout stats.transcript_files resolves, so measuring the copies gives the numbers measured live."""
    dest = os.path.join(logs, "transcripts")
    for i, tr in enumerate(ctx.transcripts):
        try:
            os.makedirs(dest, exist_ok=True)
            name = f"{i}-{os.path.basename(tr)}"
            shutil.copyfile(tr, os.path.join(dest, name))
        except OSError:
            ctx.log(f"could not copy transcript {tr}")
            continue
        for sub in subagent_files(tr):
            try:
                sdir = os.path.join(dest, name[:-len(".jsonl")], "subagents")
                os.makedirs(sdir, exist_ok=True)
                shutil.copyfile(sub, os.path.join(sdir, os.path.basename(sub)))
            except OSError:
                ctx.log(f"could not copy sub-agent transcript {sub}")


def remeasure(fc, st, logs):
    """measure() over the transcripts kept in an arm's `<arm>.logs/` (main transcripts only: their
    sub-agents are found beside them). None when the logs hold no transcript."""
    trs = sorted(glob.glob(os.path.join(logs, "transcripts", "*.jsonl")))
    return measure(fc, st, trs) if trs else None


def verify_logs(fc, st, doc, logs):
    """What re-measuring an arm's committed logs gets different from its results JSON, as messages
    (tokens, $, coding / testing split, test calls — #579). [] when they reproduce it, or when the arm
    recorded no measurement (it failed before it had a transcript)."""
    tokens = doc.get("tokens") if isinstance(doc.get("tokens"), dict) else None
    if tokens is None and doc.get("cost_usd") is None:
        return []
    m = remeasure(fc, st, logs)
    if m is None:
        return [f"{logs}: results JSON records a measurement but the logs hold no transcripts"]
    bad = []
    for k in ("input", "output", "cache_read", "cache_write"):
        if (tokens or {}).get(k) != m["tokens"][k]:
            bad.append(f"tokens.{k}: results JSON {(tokens or {}).get(k)}, logs {m['tokens'][k]}")
    if not isinstance(doc.get("cost_usd"), (int, float)) or abs(doc["cost_usd"] - m["cost_usd"]) > 1e-4:
        bad.append(f"cost_usd: results JSON {doc.get('cost_usd')}, logs {m['cost_usd']}")
    for k in ("coding_s", "testing_s", "test_calls"):
        want = (m["split"] or {}).get(k)
        got = doc.get(k)
        if (got is None) != (want is None) or (got is not None and abs(got - want) > 1e-3):
            bad.append(f"{k}: results JSON {got}, logs {want}")
    if isinstance(doc.get("effort"), dict):   # the effort the transcripts show (#590)
        lib = armlib()
        trs = sorted(glob.glob(os.path.join(logs, "transcripts", "*.jsonl")))
        got = lib.efforts(st, trs)
        if got != doc["effort"]:
            bad.append(f"effort: results JSON {doc['effort']}, logs {got}")
    if isinstance(doc.get("claude_config"), dict):   # a Harness arm: the disclosed config and restarts (#584)
        spec = importlib.util.spec_from_file_location("bench_arm_harness", os.path.join(HERE, "arms", "harness.py"))
        arm = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(arm)
        if arm.claude_config(logs) != doc["claude_config"]:
            bad.append(f"claude_config: results JSON {doc['claude_config']}, logs {arm.claude_config(logs)}")
        want = arm.logged_restarts(logs)
        if (doc.get("counts") or {}).get("fleet_restarts") != want:
            bad.append(f"counts.fleet_restarts: results JSON {(doc.get('counts') or {}).get('fleet_restarts')}, logs {want}")
    return bad


if __name__ == "__main__":
    sys.exit(main())
