"""hx arm — Hx (MorphEdit/Hx) on the same brief, default config (#386, PRD #345): the optional run.
Options (--arm-opt K=V):

    hx_src=DIR   use this Hx checkout instead of cloning the pinned commit (for tests)
    node=CMD     the node command that runs Hx (default `node`; Hx needs node >= 23.6); split like a shell line
    poll=SECS    how often the arm looks at the board (default 30)

INSTALL. Hx is cloned from github.com/MorphEdit/Hx at the PINNED commit below into a throwaway directory beside
the run clone and run from there (`node bin/hx.mjs`; Hx has no dependencies to install). The pin is recorded in
`<arm>.logs/hx.json` together with the node version. A newer Hx is a different arm: change HX_COMMIT on purpose.

WHAT RUNS. The same brief (bench/fixture/brief.md) as every arm, in the fresh run repo:
`hx init --yes`, then `hx prd brief.md` (Hx's own `hx prd`, how its project benchmark files a brief; `hx start`
and `hx grill` interview a human in an interactive session, which an unattended run has none of, so the
brief is filed as the PRD as written), then `hx run --watch`: the PRD gauntlet, decompose, impl, audit, gate,
review and security pass Hx runs for any user. DEFAULT CONFIG: .hx/config.json is what `hx init` wrote, with
one change, `worktreeRoot` (Hx's default is a directory at the filesystem root, `/hx-wt/...`, which a Linux
user cannot create; the arm points it into the run's own throwaway directory). Worker count, models, effort,
rounds and gates are Hx's out-of-the-box values; the models that ran come from the transcripts, like every arm's.

ISOLATION. A scrubbed environment: every HARNESS_*, STATE_DIR and RUN_DIR of the host's Harness fleets is
dropped and no API key reaches Hx. Claude's own login (CLAUDE_CONFIG_DIR / HOME) is the host's, as for plain.

STOP. Never by pattern. The `hx run --watch` the arm spawned is stopped through its own handle: SIGINT
(Hx's own Ctrl+C: its sessions commit, push and leave a handoff, then it exits), then ctx.terminate if it has
not exited in time. A small forwarder (FORWARDER) turns the runner's SIGTERM at a cap into that same SIGINT. That happens however the arm ends: done, error or a cap.

DONE = the PRD issue is closed on GitHub. `hx run --watch` that exits before that is started again (GitHub is
Hx's only state, so it resumes), at most 3 times (counts.fleet_restarts), then the arm fails.
Counts: issues_closed (closed issues that are not PRDs), prs_merged, workers (Hx's configured ceiling),
fleet_restarts. Beside the results in `<arm>.logs/`: usage.jsonl (Hx's per-turn usage log), config.json, run.out.
"""
import importlib.util, json, os, re, shlex, shutil, signal, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
HX_REPO = "https://github.com/MorphEdit/Hx"
HX_COMMIT = "f5f0be17b9e873fcc9bfec2faa5aa6234c68dc45"
MAX_RESTARTS = 3
STOP_GRACE_S = 120
SECRET_ENV = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")
WIPE_ENV = ("STATE_DIR", "RUN_DIR", "HARNESS_DIR")
NODE_FLAGS = ["--disable-warning=ExperimentalWarning"]


def _resolve(argv):
    """#686: on native Windows a script first on PATH (a fake `gh`) is run under its shebang, not skipped for the real gh.exe."""
    spec = importlib.util.spec_from_file_location("bench_portable", os.path.join(ROOT, "scripts", "portable.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.resolve_argv(list(argv))


def _split(cmd):
    """shlex.split of a command line the operator wrote, safe for a Windows path: posix shlex eats the backslashes of C:\\x\\y (#1108)."""
    return shlex.split(cmd.replace("\\", "/") if os.name == "nt" else cmd)


def _stats():
    spec = importlib.util.spec_from_file_location("bench_hx_stats", os.path.join(ROOT, "scripts", "stats.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# `hx run` has no SIGTERM handler (its Ctrl+C is SIGINT: sessions checkpoint, commit, push, then exit), but the
# runner stops an arm's processes with SIGTERM at a cap. So `hx run` runs under this few-line forwarder, which
# turns the runner's SIGTERM into Hx's own SIGINT (a second SIGINT 7 s later is Hx's force quit, inside the
# runner's 10 s grace) and forwards a SIGINT as it is.
FORWARDER = (
    "import signal, subprocess, sys, threading\n"
    "p = subprocess.Popen(sys.argv[1:])\n"
    "def fwd(*_): p.send_signal(signal.SIGINT)\n"
    "def term(*_):\n"
    "    fwd(); threading.Timer(7.0, fwd).start()\n"
    "signal.signal(signal.SIGINT, fwd); signal.signal(signal.SIGTERM, term)\n"
    "sys.exit(p.wait())\n")


def child_env(base=None):
    src = os.environ if base is None else base
    return {k: v for k, v in src.items()
            if not k.startswith("HARNESS_") and k not in WIPE_ENV + SECRET_ENV}


def _sh(argv, cwd=None, env=None, timeout=600):
    return subprocess.run(_resolve(argv), cwd=cwd, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL,
                          timeout=timeout)


def install(ctx, work):
    """The Hx checkout to run: opts hx_src, else the pinned commit cloned into <work>/hx-src. -> (dir, commit)."""
    src = ctx.opts.get("hx_src")
    if src:
        rc, out = _git_head(src)
        return os.path.abspath(src), out
    dest = os.path.join(work, "hx-src")
    for argv in (["git", "clone", "-q", HX_REPO, dest], ["git", "-C", dest, "checkout", "-q", HX_COMMIT]):
        p = _sh(argv)
        ctx.log(f"$ {' '.join(argv)} -> {p.returncode}")
        if p.returncode != 0:
            raise RuntimeError(f"installing Hx failed: {(p.stderr or p.stdout).strip()[:300]}")
    rc, head = _git_head(dest)
    if head != HX_COMMIT:
        raise RuntimeError(f"Hx checkout is at {head}, not the pinned {HX_COMMIT}")
    return dest, head


def _git_head(d):
    p = _sh(["git", "-C", d, "rev-parse", "HEAD"])
    return p.returncode, p.stdout.strip()


class Hx:
    """The commands an Hx run makes, all in the run clone and the scrubbed environment."""

    def __init__(self, ctx, src, node):
        self.ctx, self.node = ctx, node
        self.bin = os.path.join(src, "bin", "hx.mjs")
        self.state = os.path.join(os.path.abspath(ctx.clone), ".hx")
        self.env = child_env()

    def argv(self, *args):
        return _split(self.node) + NODE_FLAGS + [self.bin] + list(args)

    def cmd(self, *args, timeout=600):
        argv = self.argv(*args)
        p = _sh(argv, cwd=self.ctx.clone, env=self.env, timeout=timeout)
        self.ctx.log(f"$ hx {' '.join(args)} -> {p.returncode}")
        return p

    def start_run(self, out):
        """`hx run --watch`, spawned through ctx so a cap terminates it."""
        argv = self.argv("run", "--watch")
        self.ctx.log("$ " + shlex.join(argv))
        return self.ctx.spawn([sys.executable, "-c", FORWARDER] + argv, cwd=self.ctx.clone, env=self.env, stdin=subprocess.DEVNULL, stdout=out,
                              stderr=subprocess.STDOUT)

    def usage_sessions(self):
        """Session ids of every turn Hx recorded in its usage log."""
        f = os.path.join(self.state, "usage.jsonl")
        out = []
        try:
            with open(f, encoding="utf-8") as fh:
                for line in fh:
                    try:
                        sid = json.loads(line).get("sessionId")
                    except ValueError:
                        continue
                    if sid:
                        out.append(sid)
        except OSError:
            pass
        return out


def gh_json(args):
    p = subprocess.run(_resolve(["gh"] + args), capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)
    if p.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:3])} failed: {(p.stderr or p.stdout).strip()[:200]}")
    return json.loads(p.stdout or "[]")


def board(repo):
    """(prds_total, prds_open, issues_closed, prs_merged) from GitHub, the source of truth."""
    prds = gh_json(["issue", "list", "-R", repo, "--label", "prd", "--state", "all", "--limit", "100",
                    "--json", "number,state"])
    closed = gh_json(["issue", "list", "-R", repo, "--state", "closed", "--limit", "500", "--json", "number,labels"])
    prs = gh_json(["pr", "list", "-R", repo, "--state", "merged", "--limit", "500", "--json", "number"])
    n_closed = sum(1 for i in closed if "prd" not in [l.get("name") for l in i.get("labels") or []])
    return len(prds), sum(1 for p in prds if str(p.get("state", "")).upper() == "OPEN"), n_closed, len(prs)


def register(ctx, hx, st, seen):
    for sid in hx.usage_sessions():
        if sid in seen:
            continue
        tr = st.find_transcript(sid)
        if tr:
            seen.add(sid)
            ctx.add_transcripts(tr)


def stop_run(ctx, proc):
    """SIGINT the `hx run` we spawned (Hx's own graceful stop), then terminate it if it does not exit."""
    if proc is None or proc.poll() is not None:
        return
    try:
        proc.send_signal(signal.SIGINT)
        proc.wait(timeout=STOP_GRACE_S)
    except (OSError, subprocess.TimeoutExpired):
        ctx.log("hx run did not exit on SIGINT: terminating it")
    ctx.terminate(10.0)


def run(ctx):
    st = _stats()
    node = ctx.opts.get("node", "node")
    poll = float(ctx.opts.get("poll", "30"))
    work = os.path.dirname(os.path.abspath(ctx.clone))
    src, commit = install(ctx, work)
    hx = Hx(ctx, src, node)
    nv = _sh(_split(node) + ["--version"]).stdout.strip()
    with open(os.path.join(ctx.logs, "hx.json"), "w", encoding="utf-8") as fh:
        json.dump({"repo": HX_REPO, "commit": commit, "pinned": HX_COMMIT, "node": nv, "state_dir": hx.state,
                   "stop": "SIGINT the `hx run --watch` process, or `hx pause --now` in the run clone"}, fh, indent=2)
        fh.write("\n")
    ctx.count("fleet_restarts", 0)
    seen, proc, out = set(), None, open(os.path.join(ctx.logs, "run.out"), "a", encoding="utf-8")
    try:
        p = hx.cmd("init", "--yes")
        if p.returncode != 0:
            raise RuntimeError(f"hx init failed: {(p.stderr or p.stdout).strip()[:300]}")
        cfg_file = os.path.join(hx.state, "config.json")
        with open(cfg_file, encoding="utf-8") as fh:
            cfg = json.load(fh)
        cfg["worktreeRoot"] = os.path.join(work, "hx-wt")
        with open(cfg_file, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh, indent=2)
        ctx.count("workers", int(cfg.get("workers") or 0))
        with open(ctx.brief, encoding="utf-8") as fh:
            m = re.search(r"^#\s+(.+)$", fh.read(), re.M)
        title = "PRD: " + (m.group(1).strip() if m else "benchmark brief")
        p = hx.cmd("prd", ctx.brief, "--title", title)
        if p.returncode != 0 or not re.search(r"/issues/\d+", p.stdout):
            raise RuntimeError(f"hx prd failed: {(p.stderr or p.stdout).strip()[:300]}")
        ctx.log("filed " + re.search(r"\S*/issues/\d+", p.stdout).group(0))
        proc = hx.start_run(out)
        while not ctx.stop.is_set():
            register(ctx, hx, st, seen)
            total, open_prds, _, _ = board(ctx.repo)
            change = ctx.next_change(done=bool(total and not open_prds))
            if change:   # the mid-run requirement change (#592): filed as a PRD of its own, the way the brief was
                path = os.path.join(work, "change.md")
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(change)
                p = hx.cmd("prd", path, "--title", "PRD: change request")
                if p.returncode != 0 or not re.search(r"/issues/\d+", p.stdout):
                    raise RuntimeError(f"hx prd (the change request) failed: {(p.stderr or p.stdout).strip()[:300]}")
                ctx.log("filed the change request " + re.search(r"\S*/issues/\d+", p.stdout).group(0))
                continue
            if total and not open_prds:
                ctx.log("the PRD is closed: done")
                break
            if proc.poll() is not None:
                if ctx.counts.get("fleet_restarts", 0) >= MAX_RESTARTS:
                    raise RuntimeError(f"hx run exited ({proc.returncode}) before the PRD closed, after restarts")
                ctx.count("fleet_restarts")
                proc = hx.start_run(out)
            ctx.stop.wait(poll)
    finally:
        stop_run(ctx, proc)
        out.close()
        try:
            register(ctx, hx, st, seen)
        except Exception as e:   # best effort: must not hide the run's own error
            ctx.log(f"transcripts: {e!r}")
        for name, src_f in (("usage.jsonl", os.path.join(hx.state, "usage.jsonl")),
                            ("config.json", os.path.join(hx.state, "config.json"))):
            if os.path.isfile(src_f):
                shutil.copyfile(src_f, os.path.join(ctx.logs, name))
        try:
            _, _, closed, merged = board(ctx.repo)
            ctx.count("issues_closed", closed)
            ctx.count("prs_merged", merged)
        except Exception as e:
            ctx.log(f"board counts: {e!r}")
