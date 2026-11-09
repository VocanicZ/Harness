"""plain arm — plain Claude Code, what a new user gets (#382, PRD #345). Options (--arm-opt K=V):

    claude=CMD   the claude command (default `claude`); split like a shell line, for tests

ONE `claude` session in the fresh run repo (no CLAUDE.md), on the CLI login already on the host: never
`--bare` (API-key only), no API key, no copied credentials dir. Launched with
`--disable-slash-commands --strict-mcp-config --setting-sources project,local` so no user skills, plugins,
hooks or MCP servers load, and CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 so no auto-memory does. Model and effort
are the account's out-of-the-box defaults (nothing is passed); the models that ran come from the transcript.

ISOLATED CONFIG (#590). The session runs on a throwaway CLAUDE_CONFIG_DIR (bench/armlib.py), the same one the
Harness arms start from, not the host user's: the login linked in, nothing else. Results `claude_config` records
what the init listed.

ISOLATION PROOF. Every turn's `system/init` event is written to `init.json` (the first) and checked: it must
list 0 skills, 0 plugins and 0 MCP servers, else the session is killed before it does any work and the arm
fails (`status: error`, no continue-reply recorded). Plugins that ship inside the claude binary
(`path: "builtin"`, source `…@builtin`, e.g. cc-plugin-telemetry) are not installed plugins and do not
count; the proof file names them.

THE LOOP. The brief (the file bench/fixture/brief.md then one fixed delivery line saying where to commit) is the
first message. `claude -p` ends a turn when the session stops; if the work is not DONE the scripted reply
`keep going, decide for yourself` goes in (`--resume` the same session), at most 20 times. DONE = the final
message does not end in a question AND the work is delivered: the clone is clean, HEAD is on origin/main and
there is at least one commit past the brief. The reply count lands in the results as counts.continue_replies,
the commits on the default branch (past the seed) as counts.commits.
"""
import importlib.util, json, os, shlex, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
_spec = importlib.util.spec_from_file_location("bench_armlib", os.path.join(os.path.dirname(HERE), "armlib.py"))
armlib = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(armlib)
CONTINUE_REPLY = "keep going, decide for yourself"
MAX_REPLIES = 20      # the default fixture's; a fixture sets its own (bench/fixtures.py: the large one raises it to 50, #592)
CHANGE_INTRO = "I have changed my mind about some of what I asked for. Here is the change, in writing:\n\n"
CHANGE_OUTRO = "\nPlease bring the project in line with it, and carry on with what is still to do."
DELIVERY_NOTE = ("\n\n(This folder is a git clone of my private GitHub repo. Commit your work to the main "
                 "branch and push it there.)\n")
FLAGS = ["-p", "--output-format", "stream-json", "--verbose", "--disable-slash-commands",
         "--strict-mcp-config", "--setting-sources", "project,local", "--dangerously-skip-permissions"]
SECRET_ENV = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")


IsolationError = armlib.IsolationError


def launch_argv(claude, session=None):
    """The whole claude command line of a turn. No --bare, no key, no config dir: the CLI login as it is."""
    return armlib.split_cmd(claude) + FLAGS + (["--resume", session] if session else [])


def child_env(base=None, config_dir=None):
    """The session's environment: no API key, no auto-memory, and (#590) the isolated config dir when given."""
    env = dict(os.environ if base is None else base)
    for k in SECRET_ENV:
        env.pop(k, None)
    env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
    if config_dir:
        env["CLAUDE_CONFIG_DIR"] = config_dir
    return env


def _is_builtin(p):
    return isinstance(p, dict) and (p.get("path") == "builtin" or str(p.get("source", "")).endswith("@builtin"))


def isolation(init):
    """({"skills", "plugins", "plugins_builtin", "mcp_servers"} counts, [problem]) for a system/init event."""
    skills, mcp = init.get("skills") or [], init.get("mcp_servers") or []
    plugins = init.get("plugins") or []
    user_plugins = [p for p in plugins if not _is_builtin(p)]
    counts = {"skills": len(skills), "plugins": len(user_plugins),
              "plugins_builtin": len(plugins) - len(user_plugins), "mcp_servers": len(mcp)}
    bad = [f"{counts[k]} {k.replace('_', ' ')}" for k in ("skills", "plugins", "mcp_servers") if counts[k]]
    return counts, bad


def _stats():
    spec = importlib.util.spec_from_file_location("bench_plain_stats", os.path.join(ROOT, "scripts", "stats.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _git(clone, *args):
    p = subprocess.run(armlib.resolve(["git", "-C", clone] + list(args)), capture_output=True, text=True, stdin=subprocess.DEVNULL,
                       timeout=120)
    return p.returncode, p.stdout.strip()


def commits_past_seed(clone):
    """Commits on origin/main after the seed commit (the brief)."""
    _git(clone, "fetch", "origin", "main")
    rc, out = _git(clone, "rev-list", "--count", "origin/main")
    return max(int(out) - 1, 0) if rc == 0 and out.isdigit() else 0


def delivered(clone):
    """The work is handed over: clean tree, HEAD == origin/main, a commit past the seed."""
    if _git(clone, "status", "--porcelain")[1]:
        return False
    _git(clone, "fetch", "origin", "main")
    (r1, head), (r2, remote) = _git(clone, "rev-parse", "HEAD"), _git(clone, "rev-parse", "origin/main")
    return r1 == 0 and r2 == 0 and head == remote and commits_past_seed(clone) > 0


def is_done(clone, text):
    last = (text or "").strip().splitlines()[-1:] or [""]
    return not last[0].rstrip().endswith("?") and delivered(clone)


def turn(ctx, claude, prompt, session, n, st, registered, config_dir=None):
    """One claude -p turn. Returns {"session", "result", "text"}; raises IsolationError on a bad init."""
    argv = launch_argv(claude, session)
    with open(os.path.join(ctx.logs, "launch.txt"), "a", encoding="utf-8") as fh:
        fh.write(shlex.join(argv) + "\n")
    out = {"session": session, "result": None, "text": ""}
    with open(os.path.join(ctx.logs, f"turn-{n:02d}.stream.jsonl"), "w", encoding="utf-8") as stream, \
            open(os.path.join(ctx.logs, f"turn-{n:02d}.stderr"), "w", encoding="utf-8") as err:
        p = ctx.spawn(argv, cwd=ctx.clone, env=child_env(config_dir=config_dir), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                      stderr=err, text=True)
        p.stdin.write(prompt)
        p.stdin.close()
        for line in p.stdout:
            stream.write(line)
            if ctx.change_due() and out["session"]:   # the user types the change into the running session (#592)
                out["interrupted"] = True
                p.terminate()
                break
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            kind = ev.get("type")
            if kind == "system" and ev.get("subtype") == "init":
                counts, bad = isolation(ev)
                proof = os.path.join(ctx.logs, "init.json")
                if not os.path.exists(proof):
                    with open(proof, "w", encoding="utf-8") as fh:
                        json.dump({"isolation": counts, "view": armlib.init_view(ev), "init": ev}, fh, indent=2)
                        fh.write("\n")
                ctx.extra.setdefault("claude_config", {"source": "isolated config dir, session init", "skills": counts["skills"],
                                                       "plugins": counts["plugins"], "mcp_servers": counts["mcp_servers"]})
                if bad:
                    p.terminate()
                    raise IsolationError("isolation check failed: the session's init lists " + ", ".join(bad))
                out["session"] = ev.get("session_id") or out["session"]
            if out["session"] and not registered:
                tr = st.find_transcript(out["session"], [config_dir] + st.config_dirs() if config_dir else None)
                if tr:
                    ctx.add_transcripts(tr)
                    registered.append(tr)
            if kind == "result":
                out["result"], out["text"] = ev, str(ev.get("result") or "")
        p.wait()
    return out


def change_prompt(text):
    return CHANGE_INTRO + text.rstrip("\n") + "\n" + CHANGE_OUTRO


def run(ctx):
    claude = ctx.opts.get("claude", "claude")
    st = _stats()
    max_replies = int(ctx.opts.get("max_replies") or (ctx.fixture.plain_max_replies if ctx.fixture else MAX_REPLIES))
    with open(ctx.brief, encoding="utf-8") as fh:
        prompt = fh.read().rstrip("\n") + DELIVERY_NOTE
    session, registered, replies, n = None, [], 0, 0
    # #590: the isolated config both arms run on (a Harness arm adds only what the engine installs)
    cfg = armlib.isolated_config(os.path.join(os.path.dirname(os.path.abspath(ctx.clone)), "claude-config"))
    ctx.log(f"isolated claude config {cfg['path']} (login: {cfg['login'] or 'none found; the environment must carry it'})")
    ctx.extra["configured"] = {"model": None, "effort": None}   # the account's out-of-the-box model and effort
    ctx.count("continue_replies", 0)
    try:
        while True:
            n += 1
            t = turn(ctx, claude, prompt, session, n, st, registered, cfg["path"])
            session = t["session"]
            if ctx.stop.is_set():
                break
            interrupted, res = bool(t.get("interrupted")), t["result"]
            if not interrupted:
                if res is None or res.get("is_error"):
                    raise RuntimeError("claude turn failed: " + (str((res or {}).get("result") or "no result")[:300]))
                ctx.log(f"turn {n}: {t['text'][:80]!r}")
            done = not interrupted and is_done(ctx.clone, t["text"])
            change = ctx.next_change(done=done)   # the mid-run requirement change (#592): a turn interrupted for it, or work that would stop
            if change:
                ctx.log(f"turn {n}: the change request is handed over ({'interrupting the turn' if interrupted else 'at the end of the turn'})")
                prompt = change_prompt(change)
                continue
            if done:
                ctx.log(f"done after {replies} continue replies")
                break
            if replies >= max_replies:
                ctx.log(f"not done at the {max_replies}-reply cap")
                break
            replies += 1
            ctx.count("continue_replies")
            prompt = CONTINUE_REPLY
    finally:
        ctx.count("commits", commits_past_seed(ctx.clone))
