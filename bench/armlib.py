"""armlib.py — what the benchmark arms share (#590, PRD #345): the isolated Claude config both arms run on, the
engine's own skills and plugins installed into it, the check that a session's init lists nothing else, and the
provenance and effort every results JSON records.

ISOLATED CONFIG. Each arm gets a throwaway CLAUDE_CONFIG_DIR instead of the host user's: no user-scope skills,
plugins, MCP servers, hooks or settings. The only thing that reaches it is the login (`.credentials.json`,
symlinked, never a copied directory; a token from the environment passes as it always did) and a minimal
`.claude.json` that marks onboarding done. The plain arm runs on exactly that. The Harness arms run on it
too, plus what the Harness engine itself installs there for any user: its own skills (`skill/`, the `/harness`
front door among them) and the two plugins its lanes need (ralph-loop, superpowers), nothing else.

THE CHECK. `isolation_problems` reads a session's init event: an MCP server, or a plugin that is not one of the
engine's, is a problem; the arm then stops before it does any work. (Skills are not checked by name: the CLI
bundles some of its own, and the host user's cannot load from a config dir that does not hold them.)

Loaded by the arms and the runner with importlib (this directory is not a package)."""
import glob, hashlib, json, os, re, shlex, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LOGIN_FILES = (".credentials.json",)
ENGINE_PLUGINS = ("ralph-loop", "superpowers")
MARKETPLACE = "anthropics/claude-plugins-official"
MARKETPLACE_NAME = "claude-plugins-official"


class IsolationError(RuntimeError):
    pass


def host_config_dir(env=None):
    """The config dir the host user's claude reads: CLAUDE_CONFIG_DIR when set, else ~/.claude."""
    env = os.environ if env is None else env
    return env.get("CLAUDE_CONFIG_DIR") or os.path.join(env.get("HOME") or os.path.expanduser("~"), ".claude")


def isolated_config(path, host_env=None):
    """Create the isolated config dir at `path`: the login linked from the first host dir that has one, and a
    `.claude.json` that marks onboarding done. Returns {"path", "login"} (login: the linked file or None)."""
    os.makedirs(path, exist_ok=True)
    login = None
    d = host_config_dir(host_env)
    for f in LOGIN_FILES:
        src, dst = os.path.join(d, f), os.path.join(path, f)
        if os.path.isfile(src):
            if not os.path.lexists(dst):
                os.symlink(src, dst)
            login = login or src
    with open(os.path.join(path, ".claude.json"), "w", encoding="utf-8") as fh:
        json.dump({"hasCompletedOnboarding": True}, fh)
    return {"path": path, "login": login}


def engine_skills(root=ROOT):
    """{name: source path} of the skills the engine installs for a user (install.sh install_harness_skills): the
    umbrella skill/SKILL.md as `harness`, and each skill/<name>/ that has a SKILL.md."""
    src, out = os.path.join(root, "skill"), {}
    if os.path.isfile(os.path.join(src, "SKILL.md")):
        out["harness"] = os.path.join(src, "SKILL.md")
    for d in sorted(glob.glob(os.path.join(src, "*", ""))):
        if os.path.isfile(os.path.join(d, "SKILL.md")):
            out[os.path.basename(d.rstrip("/"))] = d.rstrip("/")
    return out


def install_engine_skills(cfg, root=ROOT):
    """Link the engine's own skills into <cfg>/skills, the way the engine links them into a user's. Returns the names."""
    dst = os.path.join(cfg, "skills")
    os.makedirs(dst, exist_ok=True)
    for name, src in engine_skills(root).items():
        link = os.path.join(dst, name)
        if os.path.isfile(src):   # the umbrella skill is one file: a dir of its own holds the link
            os.makedirs(link, exist_ok=True)
            link = os.path.join(link, "SKILL.md")
        if not os.path.lexists(link):
            os.symlink(src, link)
    return sorted(engine_skills(root))


def install_engine_plugins(cfg, claude, env, log):
    """Install the plugins the engine's lanes need into <cfg>, as the engine's prerequisite check does for a
    user (`claude plugin install <p>@<marketplace> --scope user`). A failure is an error: a fleet without them
    would be a different measurement."""
    env = dict(env, CLAUDE_CONFIG_DIR=cfg)
    steps = [["plugin", "marketplace", "add", MARKETPLACE]] + \
            [["plugin", "install", f"{p}@{MARKETPLACE_NAME}", "--scope", "user"] for p in ENGINE_PLUGINS]
    for i, step in enumerate(steps):
        argv = shlex.split(claude) + step
        p = subprocess.run(argv, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=300)
        log(f"$ {shlex.join(argv)} -> {p.returncode}")
        if p.returncode != 0 and i > 0:   # an already-added marketplace is fine; a plugin that will not install is not
            raise RuntimeError(f"installing the engine's plugin failed: {shlex.join(step)}: "
                               f"{(p.stderr or p.stdout).strip()[:200]}")
    return list(ENGINE_PLUGINS)


def _name(x):
    return x.get("name") if isinstance(x, dict) else x if isinstance(x, str) else None


def _is_builtin(p):
    return isinstance(p, dict) and (p.get("path") == "builtin" or str(p.get("source", "")).endswith("@builtin"))


def init_view(init):
    """{"skills", "plugins", "mcp_servers"} name lists of a system/init event (plugins without the CLI's built-ins).
    A field that is only a count (older streams, test doubles) has no names: its list is None."""
    def names(v, keep=lambda x: True):
        return [n for n in (_name(x) for x in v if keep(x)) if n] if isinstance(v, list) else None
    return {"skills": names(init.get("skills")), "plugins": names(init.get("plugins"), lambda p: not _is_builtin(p)),
            "mcp_servers": names(init.get("mcp_servers"))}


def isolation_problems(init, allowed_plugins=()):
    """[problem] for an init event measured against the isolated config: any MCP server, any plugin that is not
    in `allowed_plugins` (names, with or without @marketplace)."""
    v, bad = init_view(init), []
    if v["mcp_servers"]:
        bad.append(f"{len(v['mcp_servers'])} mcp servers ({', '.join(v['mcp_servers'][:3])})")
    ok = {p.split("@")[0] for p in allowed_plugins}
    extra = [p for p in v["plugins"] or [] if p.split("@")[0] not in ok]
    if extra:
        bad.append(f"{len(extra)} plugins not installed by the engine ({', '.join(extra[:3])})")
    return bad


def write_init_proof(logs, init, view_extra=None):
    """Keep the first init event of an arm's sessions in <logs>/init.json (once)."""
    proof = os.path.join(logs, "init.json")
    if not os.path.exists(proof):
        with open(proof, "w", encoding="utf-8") as fh:
            json.dump(dict({"view": init_view(init)}, **(view_extra or {}), init=init), fh, indent=2)
            fh.write("\n")


# --- provenance and effort -----------------------------------------------------------------------
def _run(argv, cwd=None):
    try:
        p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    return p.stdout.strip() if p.returncode == 0 else None


def engine_commit(root=ROOT):
    """The engine checkout's git commit (`-dirty` when the tree has uncommitted changes), or None. A tree with no
    git (the release gate's `git archive` extraction, #653) reads bench/ENGINE_COMMIT, which `git archive` fills
    with the commit (export-subst); an unexpanded stamp (`$Format:%H$`, a plain checkout) is no commit."""
    sha = _run(["git", "-C", root, "rev-parse", "HEAD"])
    if not sha:
        try:
            with open(os.path.join(root, "bench", "ENGINE_COMMIT"), encoding="utf-8") as fh:
                stamp = fh.read().strip()
        except OSError:
            return None
        return stamp if re.fullmatch(r"[0-9a-f]{40,64}", stamp) else None
    dirty = _run(["git", "-C", root, "status", "--porcelain", "--untracked-files=no"])
    return sha + ("-dirty" if dirty else "")


def skill_version(root=ROOT):
    """A version for the `/harness` skill the arms install: the engine's skill/ files hashed (path and bytes, in
    order), `sha256:<16 hex>`, or None without them."""
    h, n = hashlib.sha256(), 0
    for name, src in sorted(engine_skills(root).items()):
        files = [src] if os.path.isfile(src) else sorted(
            os.path.join(d, f) for d, _, fs in os.walk(src) for f in fs)
        for f in files:
            try:
                with open(f, "rb") as fh:
                    h.update(os.path.relpath(f, root).encode() + b"\0" + fh.read() + b"\0")
                    n += 1
            except OSError:
                pass
    return "sha256:" + h.hexdigest()[:16] if n else None


def cli_version(claude):
    """`claude --version` as printed (e.g. `2.1.319 (Claude Code)`), or None."""
    out = _run(shlex.split(claude or "claude") + ["--version"])
    return out.splitlines()[0].strip() if out else None


def provenance(claude="claude", root=ROOT):
    """{"engine_commit", "skill_version", "cli_version"} for a results JSON; a part that cannot be read is None."""
    return {"engine_commit": engine_commit(root), "skill_version": skill_version(root), "cli_version": cli_version(claude)}


def efforts(st, transcripts):
    """{effort: messages} as the transcripts record it: each entry's top-level `effort` field, the main
    transcripts and their sub-agents'. {} when none carries one."""
    out = {}
    for tr in transcripts:
        for f in st.transcript_files(tr):
            try:
                with open(f, encoding="utf-8") as fh:
                    for line in fh:
                        try:
                            ev = json.loads(line)
                        except ValueError:
                            continue
                        e = ev.get("effort") if isinstance(ev, dict) else None
                        if isinstance(e, str) and e:
                            out[e] = out.get(e, 0) + 1
            except OSError:
                continue
    return dict(sorted(out.items()))


def compactions(st, transcripts):
    """How many times a session's context was compacted, as the transcripts record it: an entry marked
    `isCompactSummary`, or a `system` entry with subtype `compact_boundary` (one compaction writes both: a
    boundary is counted once, a summary without a boundary counts). The main transcripts and their sub-agents'.
    A compaction is the sign of work that outgrew one context window (#592)."""
    total = 0
    for tr in transcripts:
        for f in st.transcript_files(tr):
            try:
                with open(f, encoding="utf-8") as fh:
                    for line in fh:
                        if "ompact" not in line:
                            continue
                        try:
                            ev = json.loads(line)
                        except ValueError:
                            continue
                        if isinstance(ev, dict) and (ev.get("subtype") == "compact_boundary"
                                                     or (ev.get("isCompactSummary") and ev.get("type") == "user")):
                            total += 1
            except OSError:
                continue
    return total


REFEED_PREFIX = "Stop hook feedback:"


def refeeds(st, transcripts):
    """The Stop hook's re-feeds, as the transcripts record them (#616): a meta `user` entry whose text starts
    `Stop hook feedback:` is one nudge sent back to a session that ended a turn without its promise. Returns
    {"count": entries, "tokens": their text's size in tokens, estimated as characters over 4}: the cost of the goal
    loop's re-feeds, the whole task each time before the engine-owned hook sent a short reminder. run-20261106
    (the user-scope ralph-loop plugin): 15 re-feeds, about 39.6k tokens."""
    count = chars = 0
    for tr in transcripts:
        for f in st.transcript_files(tr):
            try:
                with open(f, encoding="utf-8") as fh:
                    for line in fh:
                        if REFEED_PREFIX not in line:
                            continue
                        try:
                            ev = json.loads(line)
                        except ValueError:
                            continue
                        if not (isinstance(ev, dict) and ev.get("type") == "user" and ev.get("isMeta")):
                            continue
                        c = (ev.get("message") or {}).get("content")
                        if isinstance(c, list):
                            c = " ".join(b.get("text", "") for b in c if isinstance(b, dict))
                        if isinstance(c, str) and c.startswith(REFEED_PREFIX):
                            count += 1
                            chars += len(c)
            except OSError:
                continue
    return {"count": count, "tokens": round(chars / 4)}
