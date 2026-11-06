"""harness arm — the same brief through `/harness <idea>` -> PRD -> decompose -> lanes (#383, PRD #345).
Options (--arm-opt K=V):

    workers=N    the fleet's pool size, HARNESS_POOL: how many issues run in parallel (default 1;
                 the optional 3-worker run is the `harness-3` arm, this module with workers=3)
    harness=CMD  the harness command (default: this checkout's bin/harness, so the engine measured is the
                 one the benchmark ships with); split like a shell line, for tests
    claude=CMD   the claude command for the front door (default `claude`), for tests
    poll=SECS    how often the arm looks at the fleet (default 30)

WHAT RUNS. ONE `claude -p` session in the run repo's clone is handed `/harness <brief>` (the brief file,
the whole input) plus one fixed line saying nobody is there to answer, so every
Confirm is a yes and every grilling question is the session's own to settle. The /harness skill then does
what it does for any user: `harness init`, the PRD, `harness start`. Out-of-the-box defaults everywhere: no
--model/--effort for the front door (the account's), and no HARNESS_MODEL_*/EFFORT_* in the environment, so
the fleet runs its role defaults (#373/#375). The models that actually ran come from the transcripts, like
every arm's: the front door's, and every session the fleet logs in its events.jsonl.
A front door that stops before a fleet is up gets the scripted reply `keep going, decide for yourself` (at
most 5; counts.continue_replies).

ISOLATION. The run fleet shares nothing with the host's fleets: its own HARNESS_HOME (event log, fleet
registry, snapshots), its own state dir inside the run clone (<clone>/.harness), a session prefix made from
the run repo's name, and a scrubbed environment: every HARNESS_* and STATE_DIR/RUN_DIR of the host's
fleets is dropped (only the usage seam and the config-dir search list pass through), and no API key reaches
it. The host poller is off (HARNESS_USE_POLLER=0): a poller is a host-level process nothing here would stop.

STOP. The arm never matches processes by name. It stops the fleet with `harness stop --state-dir
<clone>/.harness`, the engine's own stop for exactly that state dir (its pidfiles, its prefix's sessions),
and terminates the front-door claude it spawned through ctx.spawn. Both happen however the arm ends: done,
error or a cap.

DONE = every PRD issue of the run repo is closed. Counts: issues_closed (closed issues that are not PRDs),
prs_merged, workers, continue_replies, fleet_restarts.

CONFIG AND RESTARTS DISCLOSED (#584). The front door and the fleet's sessions run on the host user's Claude
config (the only isolation is HARNESS_HOME and the state dir), so the arm records what the front door's init
event says was loaded: results `claude_config` = {source, skills, plugins (user plugins, built-ins left out),
mcp_servers}. `counts.fleet_restarts` is the restarts the arm made itself plus the ones the front-door session
made by hand: every `harness start` its Bash calls ran after the first (the engine logs no start/stop events,
so the front door's own transcript in the stream is the record). `bench/figures.py` renders both under the table.
"""
import glob, hashlib, importlib.util, json, os, re, shlex, shutil, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CONTINUE_REPLY = "keep going, decide for yourself"
MAX_REPLIES = 5
MAX_RESTARTS = 3
AUTONOMY_NOTE = ("\n\n(Unattended run: nobody is here to answer. Treat every Confirm in the /harness steps as "
                 "a yes, answer your own grilling questions from the brief above, decide anything ambiguous "
                 "yourself and do not stop to ask. The fleet's settings are already in the environment: "
                 "keep them.)\n")
FRONT_FLAGS = ["-p", "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions"]
SECRET_ENV = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")
# The only HARNESS_* that cross into the run fleet: where usage is read and where transcripts are searched.
PASS_ENV = ("HARNESS_USAGE_CMD", "HARNESS_CLAUDE_CONFIG_DIRS")
WIPE_ENV = ("STATE_DIR", "RUN_DIR", "HARNESS_DIR")


def _stats():
    spec = importlib.util.spec_from_file_location("bench_harness_stats", os.path.join(ROOT, "scripts", "stats.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def session_prefix(repo):
    """A tmux-session prefix no host fleet has: derived from the run repo's name (unique per run)."""
    return "bn" + hashlib.sha1(repo.encode()).hexdigest()[:5]


class Fleet:
    """Where the run fleet lives and how it is driven: everything the arm starts or stops is named here."""

    def __init__(self, ctx, workers, harness):
        self.ctx, self.workers, self.harness = ctx, workers, harness
        work = os.path.dirname(os.path.abspath(ctx.clone))
        self.home = os.path.join(work, "harness-home")
        self.state = os.path.join(os.path.abspath(ctx.clone), ".harness")
        self.prefix = session_prefix(ctx.repo)
        self.owner = ctx.repo.split("/")[0]

    def env(self, base=None):
        """The scrubbed environment of everything the arm launches for the fleet."""
        src = os.environ if base is None else base
        env = {k: v for k, v in src.items()
               if not (k.startswith("HARNESS_") and k not in PASS_ENV) and k not in WIPE_ENV + SECRET_ENV}
        os.makedirs(self.home, exist_ok=True)
        env.update(HARNESS_HOME=self.home, HARNESS_MODE="prd", HARNESS_OWNER=self.owner,
                   HARNESS_REPO=self.ctx.repo, HARNESS_AUTONOMOUS="true", HARNESS_POOL=str(self.workers),
                   HARNESS_SESS_PREFIX=self.prefix, HARNESS_USE_POLLER="0")
        bindir = os.path.dirname(shlex.split(self.harness)[0])
        if bindir and os.path.basename(shlex.split(self.harness)[0]) == "harness":
            env["PATH"] = bindir + os.pathsep + env.get("PATH", "")
        return env

    def cmd(self, *args, timeout=300):
        """Run `harness <args> --state-dir <ours>`, always against this arm's own state dir."""
        argv = shlex.split(self.harness) + list(args) + ["--state-dir", self.state]
        p = subprocess.run(argv, cwd=self.ctx.clone, env=self.env(), capture_output=True, text=True,
                           stdin=subprocess.DEVNULL, timeout=timeout)
        self.ctx.log(f"$ {shlex.join(argv)} -> {p.returncode}")
        return p

    def live_pids(self):
        """Pids in the fleet's own pidfiles that are still alive."""
        out = []
        rundir = os.path.join(self.state, "run")
        for f in sorted(os.listdir(rundir)) if os.path.isdir(rundir) else []:
            if not f.endswith(".pid"):
                continue
            try:
                pid = int(open(os.path.join(rundir, f)).read().split()[0])
                os.kill(pid, 0)
                out.append(pid)
            except (OSError, ValueError, IndexError):
                pass
        return out

    def stop(self):
        """Stop what the arm started: the engine's own stop for this state dir, nothing else."""
        if not os.path.isfile(os.path.join(self.state, "config")):
            return
        try:
            self.cmd("stop")
        except (OSError, subprocess.SubprocessError) as e:
            self.ctx.log(f"harness stop failed: {e!r}")


def _n(v):
    return len(v) if isinstance(v, (list, tuple, dict)) else v if isinstance(v, int) and not isinstance(v, bool) else None


def _events(stream):
    try:
        with open(stream, encoding="utf-8") as fh:
            for line in fh:
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if isinstance(ev, dict):
                    yield ev
    except OSError:
        return


def front_streams(logs):
    return sorted(glob.glob(os.path.join(logs, "front-*.stream.jsonl")))


def claude_config(logs):
    """What the front door's first init event says was loaded, as {source, skills, plugins, mcp_servers}, or
    None when no stream has an init (the arm never started a front door)."""
    for stream in front_streams(logs):
        for ev in _events(stream):
            if ev.get("type") == "system" and ev.get("subtype") == "init":
                plugins = ev.get("plugins")
                if isinstance(plugins, list):   # built-ins ship with the CLI; the rest are the host user's
                    plugins = [p for p in plugins if not (isinstance(p, dict) and p.get("path") == "builtin")]
                cfg = {"source": "front-door init", "skills": _n(ev.get("skills")), "plugins": _n(plugins),
                       "mcp_servers": _n(ev.get("mcp_servers"))}
                return cfg if all(cfg[k] is not None for k in ("skills", "plugins", "mcp_servers")) else None
    return None


START_RE = re.compile(r"(?:^|[\s;&|(/])harness\s+start\b")


def front_restarts(logs):
    """Fleet restarts the front-door session made itself: `harness start` runs in its Bash calls after the first."""
    starts = 0
    for stream in front_streams(logs):
        for ev in _events(stream):
            content = (ev.get("message") or {}).get("content") if ev.get("type") == "assistant" else None
            for b in content if isinstance(content, list) else []:
                if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Bash":
                    starts += len(START_RE.findall(str((b.get("input") or {}).get("command") or "")))
    return max(0, starts - 1)


def logged_restarts(logs):
    """Every restart the committed logs show: the front door's by-hand ones plus the arm's own `start --recover`
    lines in run.log."""
    own = 0
    try:
        with open(os.path.join(logs, "run.log"), encoding="utf-8") as fh:
            own = sum(1 for line in fh if re.search(r"harness\S*\s+start\s+--recover\b", line))
    except OSError:
        pass
    return front_restarts(logs) + own


def gh_json(args):
    p = subprocess.run(["gh"] + args, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)
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


def register_lane_transcripts(ctx, fleet, st, seen):
    """Every session the fleet logged (its own events.jsonl) whose transcript exists: for the $ cap and the
    model, token and time figures."""
    for e in st.load_events(os.path.join(fleet.home, "events.jsonl")):
        sid = e.get("session")
        if not sid or sid in seen:
            continue
        tr = st.find_transcript(sid)
        if tr:
            seen.add(sid)
            ctx.add_transcripts(tr)


def front_turn(ctx, fleet, claude, prompt, session, n, st, registered):
    """One `claude -p` turn of the front door. Returns {"session", "result"}."""
    argv = shlex.split(claude) + FRONT_FLAGS + (["--resume", session] if session else [])
    with open(os.path.join(ctx.logs, "launch.txt"), "a", encoding="utf-8") as fh:
        fh.write(shlex.join(argv) + "\n")
    out = {"session": session, "result": None}
    with open(os.path.join(ctx.logs, f"front-{n:02d}.stream.jsonl"), "w", encoding="utf-8") as stream, \
            open(os.path.join(ctx.logs, f"front-{n:02d}.stderr"), "w", encoding="utf-8") as err:
        p = ctx.spawn(argv, cwd=ctx.clone, env=fleet.env(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                      stderr=err, text=True)
        p.stdin.write(prompt)
        p.stdin.close()
        for line in p.stdout:
            stream.write(line)
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev.get("session_id"):
                out["session"] = ev["session_id"]
            if out["session"] and not registered:
                tr = st.find_transcript(out["session"])
                if tr:
                    ctx.add_transcripts(tr)
                    registered.append(tr)
            if ev.get("type") == "result":
                out["result"] = ev
        p.wait()
    return out


def finish(ctx, fleet, st, seen, front_registered):
    """Always: stop the fleet we started, keep its raw logs, take the last transcripts and the counts."""
    fleet.stop()
    try:
        register_lane_transcripts(ctx, fleet, st, seen)
    except Exception as e:   # best effort: a half-written event log must not hide the run's own error
        ctx.log(f"lane transcripts: {e!r}")
    for name, src in (("events.jsonl", os.path.join(fleet.home, "events.jsonl")),
                      ("fleet.config", os.path.join(fleet.state, "config"))):
        if os.path.isfile(src):
            shutil.copyfile(src, os.path.join(ctx.logs, name))
    try:   # what the sessions loaded, and the restarts the front door made by hand (#584)
        cfg = claude_config(ctx.logs)
        if cfg:
            ctx.extra["claude_config"] = cfg
        ctx.count("fleet_restarts", front_restarts(ctx.logs))
    except Exception as e:
        ctx.log(f"front-door config/restarts: {e!r}")
    try:
        p = fleet.cmd("stats", "--json", timeout=120)
        if p.returncode == 0 and p.stdout.strip():
            with open(os.path.join(ctx.logs, "stats.json"), "w", encoding="utf-8") as fh:
                fh.write(p.stdout)
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        _, _, closed, merged = board(ctx.repo)
        ctx.count("issues_closed", closed)
        ctx.count("prs_merged", merged)
    except Exception as e:   # the counts are missing, the run is still recorded
        ctx.log(f"board counts: {e!r}")


def run(ctx):
    st = _stats()
    claude = ctx.opts.get("claude", "claude")
    harness = ctx.opts.get("harness") or shlex.join([os.path.join(ROOT, "bin", "harness")])
    workers = int(ctx.opts.get("workers", "1"))
    poll = float(ctx.opts.get("poll", "30"))
    if workers < 1:
        raise ValueError("workers must be at least 1")
    fleet = Fleet(ctx, workers, harness)
    with open(os.path.join(ctx.logs, "fleet.json"), "w", encoding="utf-8") as fh:   # how to stop it by hand
        json.dump({"state_dir": fleet.state, "harness_home": fleet.home, "prefix": fleet.prefix,
                   "workers": workers, "repo": ctx.repo, "stop": f"harness stop --state-dir {fleet.state}"}, fh, indent=2)
        fh.write("\n")
    ctx.count("workers", workers)
    ctx.count("continue_replies", 0)
    ctx.count("fleet_restarts", 0)
    seen, front_registered = set(), []
    try:
        with open(ctx.brief, encoding="utf-8") as fh:
            prompt = "/harness " + fh.read().rstrip("\n") + AUTONOMY_NOTE
        session, replies, n = None, 0, 0
        while not ctx.stop.is_set():                     # the front door: /harness <idea> until a fleet is up
            n += 1
            t = front_turn(ctx, fleet, claude, prompt, session, n, st, front_registered)
            session = t["session"]
            if ctx.stop.is_set():
                return
            res = t["result"]
            if res is None or res.get("is_error"):
                raise RuntimeError("front-door claude turn failed: " + str((res or {}).get("result") or "no result")[:300])
            total, open_prds, _, _ = board(ctx.repo)
            if fleet.live_pids() or (total and not open_prds):
                break
            if replies >= MAX_REPLIES:
                raise RuntimeError(f"/harness did not start a fleet after {MAX_REPLIES} continue replies")
            replies += 1
            ctx.count("continue_replies")
            prompt = CONTINUE_REPLY
        down = 0
        while not ctx.stop.is_set():                     # the fleet works; GitHub says when it is done
            register_lane_transcripts(ctx, fleet, st, seen)
            total, open_prds, _, _ = board(ctx.repo)
            if total and not open_prds:
                ctx.log("every PRD is closed: done")
                break
            down = 0 if fleet.live_pids() else down + 1
            if down >= 2:
                if ctx.counts.get("fleet_restarts", 0) >= MAX_RESTARTS:
                    raise RuntimeError("the run fleet died and did not stay up after restarts")
                ctx.count("fleet_restarts")
                fleet.cmd("start", "--recover")
                down = 0
            ctx.stop.wait(poll)
    finally:
        finish(ctx, fleet, st, seen, front_registered)
