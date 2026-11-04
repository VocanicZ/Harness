#!/usr/bin/env python3
"""run.py — the benchmark runner core (#381, PRD #345). Every arm runs through it.

    bench/run.py <arm> [--dry-run] [--run-id ID] [--results-dir DIR] [--arm-opt k=v]...
                       [--wall-cap-secs 21600] [--cost-cap-usd 80] [--expected-usd N]

One run = one arm, one fresh PRIVATE GitHub repo:

    guard -> create the repo, seed it with the brief only -> clone -> run the arm under the caps
          -> grade a fresh clone of the final default branch -> record results -> delete the repo

The repo is deleted after the results are recorded, also when the arm fails or hits a cap. Nothing
but the brief is ever put in it, and no GitHub Actions run in it.

GUARD (refuses with exit 3, before anything is created or spent; --dry-run prints the decision and
spends nothing):
  * any account usage-HELD (a *.hold file in <run dir>/usage-holds, written by the fleet's usage watch);
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
Stdlib only; reuses scripts/forecast.py and scripts/stats.py.
"""
import argparse, glob, importlib.util, json, os, re, shutil, subprocess, sys, tempfile, threading, time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCRIPTS = os.path.join(ROOT, "scripts")
BRIEF = os.path.join(ROOT, "bench/fixture/brief.md")
GRADER = os.path.join(HERE, "grade.py")
SCHEMA = 1
WALL_CAP_S = 6 * 3600
COST_CAP_USD = 80.0
WEEKLY = re.compile(r"seven|week|7d", re.I)
EXIT_OK, EXIT_ARM_FAILED, EXIT_USAGE, EXIT_REFUSED, EXIT_LEAKED = 0, 1, 2, 3, 4


def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(SCRIPTS, f"{name}.py"))
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


def guard(a, fc, st):
    """{"ok", "reasons", ...the numbers}: whether a run may start. Spends nothing."""
    stop = _num(os.environ.get("HARNESS_ONE_STOP_PCT"), 98.0)
    reserve = _num(os.environ.get("HARNESS_ONE_RESERVE_PCT"), 2.0)
    expected = a.expected_usd if a.expected_usd is not None else a.cost_cap_usd
    d = {"ok": True, "reasons": [], "held": [], "expected_usd": expected, "stop_pct": stop,
         "reserve_pct": reserve, "usd_per_pct": None, "usd_per_pct_source": "none", "windows": []}
    for acct, win, pct in held_accounts(run_dir(a.run_dir)):
        d["held"].append({"account": acct, "window": win, "pct": pct})
        d["reasons"].append(f"account {acct} is usage-HELD ({win or '?'} window at {pct or '?'}%): "
                            "the fleet claims nothing until it resets")
    reads = [r for r in usage_readings() if WEEKLY.search(r[1] or "")]
    if not reads:
        d["reasons"].append("no weekly usage reading: cannot show the run fits the window")
    else:
        events = st.load_events(a.events)
        per, src = usd_per_pct(fc, events, run_account())
        d["usd_per_pct"], d["usd_per_pct_source"] = per, src
        if not per:
            d["reasons"].append("no $ per 1% (no calibration in the event log and HARNESS_ONE_USD_PER_PCT "
                                "unset): cannot turn the expected spend into a % of the window")
        else:
            need = round(expected / per, 2)
            for acct, win, pct, _ in reads:
                total = round(pct + need + reserve, 2)
                d["windows"].append({"account": acct, "window": win, "now_pct": pct, "need_pct": need,
                                     "total_pct": total, "fits": total <= stop})
                if total > stop:
                    d["reasons"].append(f"{acct} {win}: {pct:g}% now + {need:g}% expected (${expected:g}) + "
                                        f"{reserve:g}% reserve = {total:g}% > {stop:g}%")
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

    def seed(self, repo, clone):
        """Commit the brief — and nothing else — to the repo's default branch."""
        shutil.copyfile(BRIEF, os.path.join(clone, "brief.md"))
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
        self.transcripts, self.counts = [], {}
        self._procs, self._lock = [], threading.Lock()

    def add_transcripts(self, *paths):
        """Claude-format session transcripts (main ones: their sub-agents' sit beside them). The cost cap
        is measured on these, and they are copied into the run's logs."""
        with self._lock:
            self.transcripts += [p for p in paths if p not in self.transcripts]

    def count(self, name, n=1):
        with self._lock:
            self.counts[name] = self.counts.get(name, 0) + n

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


def grade(repo, workdir, gh, log, grader):
    """The hidden-tests fragment for a fresh clone of the repo's final default branch, or an error stub."""
    dest = os.path.join(workdir, "graded")
    try:
        gh.clone(repo, dest)
        p = subprocess.run([sys.executable, grader, dest], capture_output=True, text=True, timeout=1500,
                           stdin=subprocess.DEVNULL)
        log(f"grade -> {p.returncode}")
        if p.returncode != 0:
            raise RuntimeError((p.stderr or p.stdout).strip()[:300])
        return json.loads(p.stdout)
    except Exception as e:
        log(f"grade failed: {e}")
        return {"passed": 0, "failed": None, "total": None, "details": {"error": str(e)[:300]}}


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


def validate(d):
    """[problem] — empty when `d` matches the documented results schema (bench/README.md)."""
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
    ap.add_argument("--dry-run", action="store_true", help="print the guard decision; spend and create nothing")
    ap.add_argument("--run-id", default=None, help="default: a UTC timestamp")
    ap.add_argument("--results-dir", default=os.path.join(HERE, "results"))
    ap.add_argument("--owner", default=None, help="GitHub owner for the run repo (default: the gh login)")
    ap.add_argument("--arm-opt", action="append", default=[], metavar="K=V", help="passed to the arm as ctx.opts")
    ap.add_argument("--wall-cap-secs", type=float, default=WALL_CAP_S)
    ap.add_argument("--cost-cap-usd", type=float, default=COST_CAP_USD)
    ap.add_argument("--expected-usd", type=float, default=None, help="expected spend for the guard (default: the cap)")
    ap.add_argument("--run-dir", default=None, help="the fleet run dir holding usage-holds/ (default: $RUN_DIR)")
    ap.add_argument("--poll-secs", type=float, default=5.0)
    ap.add_argument("--grace-secs", type=float, default=30.0, help="how long a stopped arm has to return")
    ap.add_argument("--arms-dir", default=os.path.join(HERE, "arms"), help=argparse.SUPPRESS)
    ap.add_argument("--events", default=None, help=argparse.SUPPRESS)
    ap.add_argument("--grader", default=GRADER, help=argparse.SUPPRESS)
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
    print(render_guard(g), file=sys.stderr if not g["ok"] else sys.stdout)
    if not g["ok"]:
        return EXIT_REFUSED
    if a.dry_run:
        return EXIT_OK
    return execute(a, arm, opts, g, fc, st)


def execute(a, arm, opts, g, fc, st):
    run_id = a.run_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = os.path.join(a.results_dir, run_id)
    logs = os.path.join(out_dir, f"{a.arm}.logs")
    os.makedirs(logs, exist_ok=True)
    runlog = open(os.path.join(logs, "run.log"), "a", encoding="utf-8")

    def log(msg):
        runlog.write(f"{now_iso()} {msg}\n")
        runlog.flush()

    gh, work, repo, leaked = Gh(log), tempfile.mkdtemp(prefix="bench-run-"), None, False
    caps = {"wall_s": a.wall_cap_secs, "cost_usd": a.cost_cap_usd}
    res = {"schema": SCHEMA, "run_id": run_id, "arm": a.arm, "repo": "", "status": "ok", "capped": None,
           "error": None, "started_at": now_iso(), "ended_at": "", "wall_s": 0.0, "coding_s": None,
           "testing_s": None, "test_calls": None, "tokens": dict.fromkeys(("input", "output", "cache_read", "cache_write"), 0),
           "cost_usd": 0.0, "usd_per_pct": g["usd_per_pct"], "usd_per_pct_source": g["usd_per_pct_source"],
           "weekly_window_pct": None, "models": {}, "hidden_tests": {"passed": 0, "failed": None, "total": None},
           "counts": {}, "caps": caps, "repo_deleted": None, "logs": os.path.basename(logs)}
    ctx = None
    try:
        try:
            repo = f"{gh.owner(a.owner)}/bench-{run_id.lower()}-{a.arm}"
            res["repo"] = repo
            log(f"run {run_id} arm {a.arm} repo {repo}")
            gh.create(repo)
            gh.no_actions(repo)
            clone = os.path.join(work, "clone")
            gh.clone(repo, clone)
            gh.seed(repo, clone)
            ctx = Ctx(a.arm, repo, clone, logs, threading.Event(), opts, caps, log)
            t0 = time.time()
            res["capped"] = run_arm(a, arm, ctx, fc, st, t0, log)
            res["wall_s"] = round(time.time() - t0, 3)
            res["status"] = "capped" if res["capped"] else "ok"
        except Exception as e:   # the arm's own failure, or the repo lifecycle's: recorded, never lost
            log(f"failed: {e!r}")
            res["status"], res["error"] = "error", str(e)[:500] or repr(e)
            if ctx is not None:
                ctx.stop.set()
                ctx.terminate(a.grace_secs)
        if ctx is not None:
            res["counts"] = dict(ctx.counts)
            m = measure(fc, st, ctx.transcripts)
            res.update(tokens=m["tokens"], models=m["models"], cost_usd=m["cost_usd"])
            if m["split"]:
                res.update(m["split"])
            copy_transcripts(ctx, logs)
            res["hidden_tests"] = grade(repo, work, gh, log, a.grader)
            write_json(os.path.join(logs, "grade.json"), res["hidden_tests"])
            res["weekly_window_pct"] = (round(m["cost_usd"] / g["usd_per_pct"], 2) if g["usd_per_pct"] else None)
        res["ended_at"] = now_iso()
        write_json(os.path.join(out_dir, f"{a.arm}.json"), res)
    finally:
        if repo and res["repo"]:
            res["repo_deleted"] = gh.delete(repo)
            leaked = not res["repo_deleted"]
            log(f"repo deleted: {res['repo_deleted']}")
            if os.path.isfile(os.path.join(out_dir, f"{a.arm}.json")):
                write_json(os.path.join(out_dir, f"{a.arm}.json"), res)
        shutil.rmtree(work, ignore_errors=True)
        runlog.close()
    if leaked:
        print(f"bench: COULD NOT DELETE {repo} — delete it by hand (gh repo delete {repo})", file=sys.stderr)
        return EXIT_LEAKED
    print(f"bench: {a.arm} {res['status']}{' (' + res['capped'] + ')' if res['capped'] else ''}: "
          f"{os.path.join(out_dir, a.arm + '.json')}")
    return EXIT_ARM_FAILED if res["status"] == "error" else EXIT_OK


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


def copy_transcripts(ctx, logs):
    """The transcripts an arm named, kept beside the results as raw logs."""
    dest = os.path.join(logs, "transcripts")
    for i, tr in enumerate(ctx.transcripts):
        try:
            os.makedirs(dest, exist_ok=True)
            shutil.copyfile(tr, os.path.join(dest, f"{i}-{os.path.basename(tr)}"))
        except OSError:
            ctx.log(f"could not copy transcript {tr}")


if __name__ == "__main__":
    sys.exit(main())
