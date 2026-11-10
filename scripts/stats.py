#!/usr/bin/env python3
"""stats.py — the host-wide Harness event log and the `harness stats` report over it (#185).

Every fleet on the host appends one JSON line per event to $HARNESS_HOME/events.jsonl (default
~/.harness/events.jsonl), under an exclusive lock (portable.lock_nb: flock, or msvcrt on Windows). A launch's model and effort are the CLI adapter's
(lib.sh launch_agent: cli_model_effort, #307). A session's token usage comes from Claude Code's own
transcripts (another CLI's adapter folds its own: usage_tsv, #188): every launch passes `--session-id <uuid>`, and Claude Code writes
$CLAUDE_CONFIG_DIR/projects/<slugified cwd>/<uuid>.jsonl plus <uuid>/subagents/agent-*.jsonl, each
assistant line carrying message.model + message.usage. A headless lane's claude (#352) may keep no
transcript there: its session_end usage is then folded from the lane's events.jsonl (each turn's
stream-json `result` usage — model_usage_since_last_result, never the session's running modelUsage
summed — or its assistant messages' usage when it ended without one), found by the session id the
lane's state.json names. A resumed session's session_end (#426: a headless relaunch carries on its
claude session, whose transcript grows across runs) reports only that run, flagged `resumed: true`.

    stats.py emit <event> [--ctx F] [--write-ctx F] [-c k=v]... [k=v]...   append one event
    stats.py parent-prd <slug>        PRD number of the issue body on stdin (## Parent), or nothing
    stats.py report [--prd N|--issue N] [--by-role] [-R owner/repo] [--since 7d] [--fleet P] [--model M] [--json]
    stats.py backfill                 rebuild session_end for past sessions from their transcripts
    stats.py goal-env <goal> [prd]    KIND=/ISSUE=/PRD= lines for a lane's HARNESS_* session env (#186)
    stats.py time-split <transcript>  coding vs testing seconds of a transcript, JSON (#379)
    stats.py transcripts <session>    a claude session's transcript paths, sub-agents included (#188)
    stats.py usage <transcript>...    per-model `<model>\t<in>\t<out>\t<cache_read>\t<cache_write>` (#188)
    stats.py mismatches [--fleet P] [-R owner/repo] [--since 7d]   model_mismatch lines for `harness status` (#376)

A session_end whose dominant-by-OUTPUT model is another family than the launch's intended model (its
logged `model`: .harness-lane, role key or FLAGS) is followed by a `model_mismatch` event (intended,
actual, session, issue) — `sonnet` and `claude-sonnet-5-5` are one family; no intended model, no check.

rtdd activity (#186) lives beside it in $HARNESS_HOME/rtdd-events.jsonl: every lane session is
launched with RTDD_EVENT_LOG pointing there plus HARNESS_SESSION/ISSUE/KIND/PRD/PREFIX/REPO, and rtdd
appends one line per invocation, copying the HARNESS_* vars into its `ctx` (VocanicZ/rtdd#503, v1).
The report joins each line to its session on ctx.HARNESS_SESSION.

`emit` never raises: any failure exits 1 having printed nothing, and the bash caller (lib.sh
harness_event) swallows it — logging must never block or fail dispatch.
"""
import glob, json, math, os, re, sys, time, unicodedata
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import portable  # noqa: E402  #355: flock / msvcrt.locking

USAGE_KEYS = (("input_tokens", "input"), ("output_tokens", "output"),
              ("cache_creation_input_tokens", "cache_create"), ("cache_read_input_tokens", "cache_read"))
# The 1-hour share of `cache_create` (#710), kept apart because a 1h cache write costs 2x input, not the 5m
# write's 1.25x. A SPARSE key: present only when a folded transcript recorded the TTL split
# (usage.cache_creation.ephemeral_1h_input_tokens), absent otherwise. `cache_create` stays the whole of the
# cache writes, so the 5m share is cache_create less this. A usage without the key (an event logged before
# #710, a stream-json `result`'s modelUsage, another CLI's adapter) prices every cache write at the 5m rate.
CACHE_1H = "cache_create_1h"
# The context a session's later events inherit (nudge, watchdog_kill, session_end, …).
CTX_KEYS = ("prefix", "project", "repo", "unit", "issue", "prd", "kind", "session",
            "model", "effort", "worktree", "launched")
LOCK_WAIT_S = 2.0   # the lock is tried non-blocking for this long, then the event is dropped


def home():
    return os.environ.get("HARNESS_HOME") or os.path.expanduser("~/.harness")


def events_path():
    return os.environ.get("HARNESS_EVENTS_FILE") or os.path.join(home(), "events.jsonl")


def rtdd_events_path():
    return os.environ.get("HARNESS_RTDD_EVENTS_FILE") or os.path.join(home(), "rtdd-events.jsonl")


def now_iso(t=None):
    return datetime.fromtimestamp(time.time() if t is None else t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_ts(s):
    """ISO-8601 (Z or offset, optional fraction) → epoch seconds, or None."""
    if not s:
        return None
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _coerce(v):
    return int(v) if re.fullmatch(r"-?\d+", v) else v


def parse_kv(items):
    out = {}
    for it in items:
        k, sep, v = it.partition("=")
        if sep and k and v != "":
            out[k] = _coerce(v)
    return out


def append_event(rec, path=None):
    """Append one JSON line under an exclusive lock (portable.lock_nb). True on success; False (never an exception) otherwise."""
    path = path or events_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as fh:
            deadline = time.monotonic() + LOCK_WAIT_S
            while True:
                try:
                    portable.lock_nb(fh)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        return False
                    time.sleep(0.05)
            try:
                fh.write(json.dumps(rec) + "\n")
                fh.flush()
            finally:
                portable.unlock(fh)
        return True
    except Exception:
        return False


# --- launch context ----------------------------------------------------------
def goal_fields(goal):
    """kind/issue/prd implied by a session's GOAL string (drive.sh spawn_* / inject.sh)."""
    name, _, rest = (goal or "").partition(":")
    q = rest.split(":")
    if name == "ISSUE" and q[0].isdigit():
        return {"kind": "impl", "issue": int(q[0])}
    if name == "BUG" and q[0].isdigit():
        return {"kind": "bug-fix" if q[1:] == ["fix"] else "bug-triage", "issue": int(q[0])}
    if name == "REVIEW":
        return {"kind": "review", **({"prd": int(q[0])} if q[0].isdigit() else {})}
    if name in ("PLAN", "PRD", "DECOMPOSE"):
        return {"kind": "orch", **({"prd": int(q[0])} if q[0].isdigit() else {})}
    if name == "INJECT":
        return {"kind": "inject"}
    return {}


def goal_env(goal, prd=""):
    """The HARNESS_* suffixes (KIND, ISSUE, PRD) launch_agent exports into a lane session, from the
    same GOAL parse the launch event uses — so an rtdd event's ctx and the session agree."""
    f = goal_fields(goal)
    if str(prd).isdigit():
        f["prd"] = int(prd)
    return [f"{k.upper()}={f[k]}" for k in ("kind", "issue", "prd") if k in f]


def ralph_iter(worktree):
    try:
        with open(os.path.join(worktree, ".claude", "ralph-loop.local.md")) as fh:
            m = re.search(r"^iteration:\s*(\d+)", fh.read(), re.MULTILINE)
        return int(m.group(1)) if m else None
    except Exception:
        return None


# --- transcripts -------------------------------------------------------------
def config_dirs():
    """Every Claude config dir a session's transcript can land in. The pane picks its account from
    .bashrc AFTER the worker launched it (see lib.sh ensure_trusted), so search them all."""
    seen, out = set(), []
    cands = [os.environ.get("CLAUDE_CONFIG_DIR"), os.path.expanduser("~/.claude")]
    cands += sorted(glob.glob(os.path.expanduser("~/.claude-switch/accounts/*")))
    extra = os.environ.get("HARNESS_CLAUDE_CONFIG_DIRS")
    if extra is not None:   # test seam: replaces the search list outright
        cands = extra.split(os.pathsep)
    for c in cands:
        if c and c not in seen and os.path.isdir(c):
            seen.add(c)
            out.append(c)
    return out


def lanes_root():
    """Where headless lanes live (scripts/session/headless.sh _hl_root)."""
    return os.environ.get("HARNESS_HEADLESS_DIR") or os.path.join(home(), "lanes")


def lane_events(session):
    """A headless lane's events.jsonl (#352) for claude session <session>: the stream-json claude printed
    for every turn, whose `result` events carry each turn's usage per model. The lane whose state.json
    names that session; None when there is none. Another CLI's lane (state.json's `adapter`) has none of
    that in its events: its own adapter folds its usage (usage_tsv, #188), and a lane that keeps its id as
    its session (openclaw, #485) must not be read as a claude one."""
    for f in sorted(glob.glob(os.path.join(lanes_root(), "*", "state.json"))):
        try:
            with open(f, encoding="utf-8") as fh:
                st = json.load(fh)
        except (OSError, ValueError):
            continue
        ev = os.path.join(os.path.dirname(f), "events.jsonl")
        if (isinstance(st, dict) and st.get("session_id") == session and os.path.isfile(ev)
                and st.get("adapter") in (None, "claude")):
            return ev
    return None


def find_transcript(session, dirs=None):
    for d in dirs if dirs is not None else config_dirs():
        hits = glob.glob(os.path.join(d, "projects", "*", f"{session}.jsonl"))
        if hits:
            return hits[0]
    return None


# A stream-json `result` event's modelUsage (claude -p, #352): each turn's whole usage per model, the
# turn's sub-agents and side calls included, which its `assistant` events alone do not carry.
MODEL_USAGE_KEYS = (("inputTokens", "input"), ("outputTokens", "output"),
                    ("cacheCreationInputTokens", "cache_create"), ("cacheReadInputTokens", "cache_read"))


def model_turn_usage(result, prev=None):
    """What one stream-json `result` event's turn used, per model, in modelUsage's keys (#426). A
    `--resume`d turn's modelUsage is the SESSION's running total, not the turn's (claude 2.1.316: cache
    writes 25,024, then 46,383 = 25,024 + 21,359), so it is never summed over turns. The turn's own
    figure is model_usage_since_last_result when claude prints it; else modelUsage less <prev> (the
    previous result's modelUsage in the same stream) when that reads as a running total — no figure
    below <prev>'s — and modelUsage as it stands when there is no <prev> or it does not."""
    since = result.get("model_usage_since_last_result")
    if isinstance(since, dict):
        return since
    mu = result.get("modelUsage") or {}
    if not isinstance(prev, dict) or not prev:
        return mu
    def n(u, k):
        return int((u or {}).get(k) or 0) if isinstance(u, dict) else 0
    if any(n(mu.get(m), k) < n(u, k) for m, u in prev.items() for k, _ in MODEL_USAGE_KEYS):
        return mu   # not a running total: a per-turn figure
    return {m: {k: n(u, k) - n(prev.get(m), k) for k, _ in MODEL_USAGE_KEYS} for m, u in mu.items()}


def _file_usage(path, acc, span):
    """Fold one transcript into acc {model: {input,output,cache_create,cache_read}}. A streamed
    message is written once per content block with the SAME message id and usage, so usage is
    taken once per id (the last line wins), never summed per line. A headless lane's events.jsonl
    (stream-json, its turns split by the runner's `turn_start` markers) is folded per turn: a turn's
    `result` usage when it has one (the turn's total, model_turn_usage), else — a turn interrupted, killed
    or cut off before its result — the usage its assistant messages carry."""
    segs = [({}, [])]   # (per_id, result usages) per turn; a transcript is one segment
    prev_mu = None      # the last result's modelUsage: the session's running total so far (#426)
    try:
        with open(path) as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                t = parse_ts(r.get("timestamp"))
                if t is not None:
                    span[0] = t if span[0] is None else min(span[0], t)
                    span[1] = t if span[1] is None else max(span[1], t)
                if r.get("type") == "harness" and r.get("subtype") == "turn_start":
                    segs.append(({}, []))
                    continue
                if r.get("type") == "result" and isinstance(r.get("modelUsage"), dict):
                    segs[-1][1].append(model_turn_usage(r, prev_mu))
                    prev_mu = r["modelUsage"]
                    continue
                if r.get("type") != "assistant":
                    continue
                m = r.get("message") or {}
                u, model = m.get("usage"), m.get("model")
                if not u or not model or model == "<synthetic>":
                    continue
                per_id = segs[-1][0]
                per_id[m.get("id") or r.get("uuid") or len(per_id)] = (model, u)
    except OSError:
        return
    for per_id, results in segs:
        for mu in results:
            for model, u in mu.items():
                if not isinstance(u, dict) or model == "<synthetic>":
                    continue
                tot = acc.setdefault(model, {k: 0 for _, k in USAGE_KEYS})
                for src, dst in MODEL_USAGE_KEYS:
                    tot[dst] += int(u.get(src) or 0)
        for model, u in per_id.values() if not results else ():
            tot = acc.setdefault(model, {k: 0 for _, k in USAGE_KEYS})
            for src, dst in USAGE_KEYS:
                tot[dst] += int(u.get(src) or 0)
            w1 = int((u.get("cache_creation") or {}).get("ephemeral_1h_input_tokens") or 0)
            if w1:
                tot[CACHE_1H] = tot.get(CACHE_1H, 0) + w1


def transcript_files(transcript):
    """The main transcript and every subagent transcript beside it."""
    return [transcript] + sorted(glob.glob(os.path.join(transcript[:-len(".jsonl")], "subagents", "*.jsonl")))


def usage_tsv(acc):
    """{model: usage} as the CLI adapter's `<model>\t<input>\t<output>\t<cache_read>\t<cache_write>` lines."""
    return "".join(f"{m}\t{u['input']}\t{u['output']}\t{u['cache_read']}\t{u['cache_create']}\n" for m, u in sorted(acc.items()))


def parse_usage_tsv(text):
    """The inverse of usage_tsv: a CLI adapter's usage lines (#188) as {model: usage}."""
    acc = {}
    for line in str(text).splitlines():
        p = line.split("\t")
        if len(p) != 5:
            continue
        try:
            n = [int(x) for x in p[1:]]
        except ValueError:
            continue
        tot = acc.setdefault(p[0], {k: 0 for _, k in USAGE_KEYS})
        for k, v in zip(("input", "output", "cache_read", "cache_create"), n):
            tot[k] += v
    return acc


def session_usage(transcript):
    """({model: usage}, first_ts, last_ts) over the main transcript AND every subagent transcript."""
    acc, span = {}, [None, None]
    for f in transcript_files(transcript):
        _file_usage(f, acc, span)
    return acc, span[0], span[1]


def main_dominant_model(transcript):
    """The dominant-by-output model of the session's OWN transcript (#461), sub-agents left out: what
    the lane itself ran. None when the main transcript holds no output (a headless lane's
    events.jsonl, whose per-turn usage folds the sub-agents in, is one such)."""
    acc = {}
    _file_usage(transcript, acc, [None, None])
    return dominant_model(acc)


# --- coding vs testing time (#379) ---------------------------------------------------------
# A session's wall time split in two from its transcript: TESTING is the time inside test-command
# tool calls — a Bash tool_use whose command runs a test runner, from the tool_use's timestamp to the
# matching tool_result's — and CODING is everything else between the transcript's first and last line.
# Calls in a sub-agent's transcript count too; calls running at once (parallel tool calls, a
# sub-agent's beside the lane's own) are counted once, as a union of spans.
#
# What counts as a test command is a regex, searched in the Bash command. The default matches a runner
# at COMMAND position (the start of the command or after `;` `&` `|` `(` or a backtick, behind any
# `NAME=value` / `env` / `time` / `sudo` / `bash` / `python3` style prefix), so a runner merely
# mentioned in an `echo` or a `gh issue comment` is not one. HARNESS_TEST_COMMAND_PATTERNS (the
# environment, else <state dir>/config) REPLACES it outright; docs/reference.md documents both.
TEST_RUNNERS = (
    r"pytest|py\.test|unittest|nosetests|tox|nox",
    r"bats",
    r"rtdd",
    r"jest|vitest|mocha|ctest",
    r"(?:[\w.-]+/)*test/(?:run|test_[\w.-]+)\.(?:sh|py)",   # this repo's test/run.sh, test/test_*.sh
    r"(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?test(?::\w+)?",
    r"go\s+test",
    r"cargo\s+(?:test|nextest)",
    r"make\s+(?:test|check|ci)",
    r"dotnet\s+test",
    r"mvn\s+(?:\S+\s+)*test",
    r"(?:\./)?gradlew?\s+(?:\S+\s+)*test",
)
TEST_PREFIX = r"(?:(?:[A-Za-z_]\w*=\S*|env|time|sudo|exec|nohup|command|bash|sh|python3?|uv\s+run)\s+(?:-m\s+)?)*"
DEFAULT_TEST_PATTERN = (r"(?:^|[;&|(`]|\$\()\s*" + TEST_PREFIX + r"(?:\./)?(?:"
                        + "|".join(TEST_RUNNERS) + r")(?![\w-])")


def test_pattern_source():
    """The configured HARNESS_TEST_COMMAND_PATTERNS (environment first, else the state dir's config),
    or None for the default."""
    v = os.environ.get("HARNESS_TEST_COMMAND_PATTERNS")
    if v is None:
        v = read_config(os.environ.get("STATE_DIR"), ("HARNESS_TEST_COMMAND_PATTERNS",)).get(
            "HARNESS_TEST_COMMAND_PATTERNS")
    return v if v else None


def test_command_re(pattern=None):
    """The compiled test-command regex: <pattern> (a regex string) if given, else the configured one,
    else the default. A configured pattern that is not a valid regex falls back to the default."""
    for cand in (pattern, test_pattern_source() if pattern is None else None):
        if cand:
            try:
                return re.compile(cand)
            except re.error:
                pass
    return re.compile(DEFAULT_TEST_PATTERN)


def _call_spans(path, rx, uses, results):
    """Fold one transcript into uses {tool_use id: (ts, is_test)} and results {tool_use id: ts}. A
    streamed message repeats its blocks: the first sighting of an id wins."""
    first_ts = last_ts = None
    try:
        fh = open(path, encoding="utf-8")
    except OSError:
        return None, None
    with fh:
        for line in fh:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if not isinstance(r, dict):
                continue
            t = parse_ts(r.get("timestamp"))
            if t is None:
                continue
            first_ts = t if first_ts is None else min(first_ts, t)
            last_ts = t if last_ts is None else max(last_ts, t)
            content = (r.get("message") or {}).get("content") if isinstance(r.get("message"), dict) else None
            for b in content if isinstance(content, list) else ():
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use" and b.get("id") and b["id"] not in uses:
                    cmd = (b.get("input") or {}).get("command") if isinstance(b.get("input"), dict) else None
                    uses[b["id"]] = (t, b.get("name") == "Bash" and isinstance(cmd, str) and bool(rx.search(cmd)))
                elif b.get("type") == "tool_result" and b.get("tool_use_id") and b["tool_use_id"] not in results:
                    results[b["tool_use_id"]] = t
    return first_ts, last_ts


def time_split(transcript, pattern=None):
    """Coding vs testing time of the session whose main transcript is <transcript> (its sub-agents'
    beside it included): {"total_s", "testing_s", "coding_s", "test_calls"}, seconds, or None when
    there is no readable transcript with a timestamp. Usable on any Claude-format transcript — a
    bench run's as well as a fleet session's (#345). <pattern> overrides the test-command regex."""
    rx = test_command_re(pattern)
    uses, results, lo, hi = {}, {}, None, None
    for f in transcript_files(transcript):
        a, b = _call_spans(f, rx, uses, results)
        if a is not None:
            lo = a if lo is None else min(lo, a)
            hi = b if hi is None else max(hi, b)
    if lo is None:
        return None
    spans = sorted((t0, results[i]) for i, (t0, is_test) in uses.items()
                   if is_test and i in results and results[i] > t0)
    testing, calls, end = 0.0, len(spans), None
    for a, b in spans:
        a, b = max(a, lo), min(b, hi)
        if end is not None and a < end:
            a = end
        if b > a:
            testing += b - a
            end = b if end is None else max(end, b)
    total = hi - lo
    return {"total_s": round(total, 3) if total % 1 else int(total),
            "testing_s": round(testing, 3) if testing % 1 else int(testing),
            "coding_s": round(total - testing, 3) if (total - testing) % 1 else int(total - testing),
            "test_calls": calls}


def session_time_split(session):
    """time_split of claude session <session>'s transcript, or None when the host no longer has it."""
    tr = find_transcript(session)
    return time_split(tr) if tr else None


# --- a resumed session (#426) ---------------------------------------------------
# A headless lane relaunched after a checkpoint, a crash or a usage park carries on its claude session
# (`claude -p --resume <id>`), which appends to the SAME <id>.jsonl transcript. Its session_end then
# reports only what this run added — the transcript's total less what the session's earlier
# session_ends already reported — and says so with `resumed: true`; a session's usage is its first
# session_end's plus every resumed one's. A session_end without the flag replaces what came before
# it: one logged before #426 is the transcript's whole total, earlier runs included.
def fold_session_end(into, end):
    """Fold one session_end's usage into a session's running {model: usage} (sessions(), and what a
    resumed run's session_end subtracts): added when it is `resumed`, else in place of it."""
    usage = end.get("usage") or {}
    return add_usage(into, usage) if end.get("resumed") else add_usage({}, usage)


def clean_usage(usage):
    """A logged event's `usage` as a well-formed {model: {key: int}} (#753). A usage that is not a dict, a model
    whose entry is not a dict, and a count that is not a finite, non-negative number (a string, a bool, null,
    a list, nan, inf) are dropped, so no reader of the log meets a value it cannot add. A model left with no
    count is dropped too."""
    if not isinstance(usage, dict):
        return {}
    out = {}
    for model, u in usage.items():
        if not isinstance(u, dict):
            continue
        d = {}
        for k, v in u.items():
            if isinstance(v, bool) or not isinstance(v, (int, float)):
                continue
            if isinstance(v, float) and not math.isfinite(v):
                continue
            if v >= 0:
                d[k] = int(v)
        if d:
            out[model] = d
    return out


def parse_event_line(line):
    """One events.jsonl line as a dict, or None when it is blank, torn or not a JSON object. The one reader
    both load_events and logged_session_usage share (#752): a UTF-8 BOM (a Windows editor's save) is stripped
    (#672), and the parse is non-strict so a raw control character (form feed, tab, VT) inside a field
    value is accepted (#673). A malformed `usage` is cleaned (clean_usage, #753)."""
    line = line.lstrip("\ufeff")
    if not line.strip():
        return None
    try:
        r = json.loads(line, strict=False)
    except ValueError:
        return None
    if not isinstance(r, dict):
        return None
    if "usage" in r:
        r["usage"] = clean_usage(r["usage"])
    return r


def logged_session_usage(session, path=None):
    """What the event log's session_ends for claude session <session> already report, folded as
    sessions() folds them; None when it has none."""
    acc = None
    try:
        with open(path or events_path(), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if session not in line:
                    continue
                e = parse_event_line(line)
                if e and e.get("event") == "session_end" and e.get("session") == session:
                    acc = fold_session_end(acc or {}, e)
    except OSError:
        pass
    return acc


def usage_minus(usage, prior):
    """{model: usage} less <prior>, per model and key, never below 0; a model left with nothing is dropped."""
    out = {}
    for model, u in (usage or {}).items():
        p = (prior or {}).get(model) or {}
        d = {k: max(0, int(u.get(k) or 0) - int(p.get(k) or 0)) for _, k in USAGE_KEYS}
        w1 = max(0, int(u.get(CACHE_1H) or 0) - int(p.get(CACHE_1H) or 0))
        if w1:
            d[CACHE_1H] = w1
        if any(d.values()):
            out[model] = d
    return out


# --- what ran (#376) -----------------------------------------------------------
# Claude model families: an alias (`sonnet`, `opus[1m]`) and a full id (`claude-sonnet-5-5`,
# `anthropic/claude-sonnet-5-5-20261001`) of one family are the same intended model.
CLAUDE_FAMILIES = ("opus", "sonnet", "haiku", "fable")


def model_family(model):
    """The family a model name belongs to, for the intended-vs-ran check: a Claude family word when the
    name carries one, else the name itself, lowercased, without a provider prefix (`openai/`), a
    `[…]` context suffix or a trailing date stamp. Empty for no model."""
    m = re.sub(r"\[[^\]]*\]$", "", str(model or "").strip().lower())
    m = m.rsplit("/", 1)[-1]
    for fam in CLAUDE_FAMILIES:
        if re.search(rf"(?:^|[^a-z]){fam}(?:[^a-z]|$)", m):
            return fam
    return re.sub(r"[-@]\d{8}$", "", m)


def same_family(a, b):
    """True when two model names are one family: equal families, or — a non-Claude name — one a
    `-`-bounded prefix of the other (`gpt-5.6` intended, `gpt-5.6-codex` ran)."""
    fa, fb = model_family(a), model_family(b)
    if fa == fb:
        return True
    if fa in CLAUDE_FAMILIES or fb in CLAUDE_FAMILIES:
        return False
    short, long_ = sorted((fa, fb), key=len)
    return bool(short) and long_.startswith(short + "-")


def dominant_model(usage):
    """The model with the most OUTPUT tokens in a {model: usage}, or None when none produced any. Fed
    a session's merged usage, a side call is small next to the session's own turns and never wins; a
    lane whose sub-agents out-write it is why model_mismatch decides on the main transcript (#461)."""
    best = None
    for model, u in sorted((usage or {}).items()):
        out = int((u or {}).get("output") or 0) if isinstance(u, dict) else 0
        if out > 0 and (best is None or out > best[1]):
            best = (model, out)
    return best[0] if best else None


MISMATCH_KEYS = ("prefix", "project", "repo", "unit", "issue", "prd", "kind", "session", "effort")


def model_mismatch(end):
    """The `model_mismatch` record for one session_end, or None: the intended model (the launch's
    logged `model` — .harness-lane, role key or FLAGS) against the dominant-by-output model of its
    usage, by family. No intended model (the CLI's own default) or no usage → no check. The model that
    ran is the session_end's `main_model` — the dominant model of the lane's own transcript, so a
    sub-agent on another family never trips the check (#461) — else, for a session_end that has none
    (logged before #461, or a lane with no transcript), the dominant model of its merged usage."""
    intended = end.get("model")
    actual = end.get("main_model") or dominant_model(end.get("usage"))
    if not intended or not actual or same_family(intended, actual):
        return None
    rec = {k: end[k] for k in MISMATCH_KEYS if end.get(k) not in (None, "")}
    rec.update(ts=end.get("ts") or now_iso(), event="model_mismatch", intended=intended, actual=actual)
    return {"ts": rec.pop("ts"), "event": rec.pop("event"), **rec}


# --- emit --------------------------------------------------------------------
def read_ctx(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return {}


def write_ctx(path, ctx):
    try:
        tmp = f"{path}.tmp.{os.getpid()}"
        with open(tmp, "w") as fh:
            json.dump(ctx, fh)
        os.replace(tmp, path)
    except Exception:
        pass


def build_event(event, common, ctx, kv, now=None):
    """The record for one event. Precedence: common fields < the session's ctx < explicit k=v."""
    now = time.time() if now is None else now
    rec = dict(common)
    rec.update(ctx)
    rec.update(goal_fields(kv.pop("goal", "")))
    rec.update(kv)   # a launch's model= and effort= are the CLI adapter's (cli_model_effort, #307)
    if event == "session_end":
        launched = rec.get("launched")
        tr = find_transcript(rec["session"]) if rec.get("session") else None
        whole = bool(tr)   # a claude transcript holds the whole session, every earlier run included
        if not tr and rec.get("session") and "usage" not in rec:
            tr = lane_events(rec["session"])   # #352: a headless lane whose claude kept no transcript
        last = None
        tsv = rec.pop("usage_tsv", None)   # #188: what the CLI adapter folded from its own transcripts
        if tr and "usage" not in rec:
            rec["usage"], _, last = session_usage(tr)
            if whole:
                rec["main_model"] = main_dominant_model(tr)   # #461: what the lane itself ran, not its sub-agents
            # #426: a resumed session reports only this run. A lane's events.jsonl is this run's alone
            # (headless_sess_start starts every launch in a fresh lane dir); a transcript is not.
            prior = logged_session_usage(rec["session"])
            if prior is not None:
                rec["resumed"] = True
                if whole:
                    rec["usage"] = usage_minus(rec["usage"], prior)
            if not rec["usage"] and tsv:
                # #483: a headless lane of a CLI whose stream carries no usage the lane's events.jsonl fold
                # reads (copilot: session.usage_record lives in its own session-state file) is folded by the
                # CLI adapter from that file, as a pane's is. That file holds the whole session, every earlier
                # run of it included, so a resumed run reports only what it added.
                rec["usage"] = parse_usage_tsv(tsv) or None
                if rec["usage"] and prior is not None:
                    rec["usage"] = usage_minus(rec["usage"], prior)
        elif tsv and "usage" not in rec:
            rec["usage"] = parse_usage_tsv(tsv) or None
        if "wall_s" not in rec and isinstance(launched, int):
            rec["wall_s"] = max(0, int((last or now) - launched))
        it = ralph_iter(rec["worktree"]) if rec.get("worktree") else None
        if it is not None:
            rec.setdefault("ralph_iter", it)
    rec.pop("launched", None)
    rec.pop("event", None)
    rec.pop("ts", None)
    rec = {"ts": now_iso(now), "event": event, **rec}   # ts + event lead every line, for grep
    return {k: v for k, v in rec.items() if v is not None and v != ""}


def cmd_emit(argv):
    if not argv:
        return 2
    event, rest = argv[0], argv[1:]
    common, kv, ctx_in, ctx_out, i = {}, [], None, None, 0
    while i < len(rest):
        a = rest[i]
        if a in ("--ctx", "--write-ctx", "-c") and i + 1 < len(rest):
            v = rest[i + 1]
            if a == "--ctx":
                ctx_in = v
            elif a == "--write-ctx":
                ctx_out = v
            else:
                common.update(parse_kv([v]))
            i += 2
            continue
        kv.append(a)
        i += 1
    now = time.time()
    rec = build_event(event, common, read_ctx(ctx_in) if ctx_in else {}, parse_kv(kv), now)
    if ctx_out:   # written BEFORE the append: a dead events log must not lose the session context
        ctx = {k: rec[k] for k in CTX_KEYS if k in rec}
        ctx.setdefault("launched", int(now))
        write_ctx(ctx_out, ctx)
    if not append_event(rec):
        return 1
    mm = model_mismatch(rec) if event == "session_end" else None
    return 0 if mm is None or append_event(mm) else 1


# --- report ------------------------------------------------------------------
def load_events(path=None, skipped=None):
    """Every JSON-object line of the events log. A leading UTF-8 BOM (a Windows editor's save) is stripped, like the
    CRLF / lone CR that universal newlines already fold. A line that still does not parse is dropped, but counted:
    pass a list as `skipped` and its length-1 slot `[0]` is bumped, so the caller can say how much it lost (#672).
    Parsed non-strict, so a raw control character (form feed, tab, VT) inside a field value is accepted (#673)."""
    out = []
    try:
        with open(path or events_path(), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if not line.lstrip("\ufeff").strip():
                    continue
                r = parse_event_line(line)
                if r is not None:
                    out.append(r)
                elif skipped is not None:
                    skipped[0] += 1
    except OSError:
        pass
    return out


def parse_since(s, now=None):
    """'7d' / '24h' / '30m' / an ISO date → epoch seconds."""
    now = time.time() if now is None else now
    m = re.fullmatch(r"([0-9]+)([dhm])", s or "")
    if not m and re.fullmatch(r"\d+[dhm]", s or ""):   # #804: \d also matches full-width / Arabic-Indic digits
        raise ValueError(f"bad --since: {short_repr(s)} (use ASCII digits only)")
    if m:
        too_big = ValueError("bad --since: the count is too large to turn into a date (use a smaller number, e.g. 7d)")   # #879
        digits = m.group(1).lstrip("0")
        if len(digits) > 300:   # before int(): past 4300 digits int() itself raises, in Python's wording
            raise too_big
        try:
            return now - int(digits or "0") * {"d": 86400, "h": 3600, "m": 60}[m.group(2)]
        except OverflowError:   # about 307 digits: int too large to convert to float
            raise too_big from None
    t = parse_ts(s if "T" in (s or "") else f"{s}T00:00:00+00:00")
    if t is None:
        raise ValueError(f"bad --since: {short_repr(s)} (want 7d, 24h, 30m or YYYY-MM-DD)")
    return t


def add_usage(into, usage, model_filter=None):
    for model, u in (usage or {}).items():
        if model_filter and model_filter not in model:
            continue
        tot = into.setdefault(model, {k: 0 for _, k in USAGE_KEYS})
        for _, k in USAGE_KEYS:
            tot[k] += int(u.get(k) or 0)
        if u.get(CACHE_1H):
            tot[CACHE_1H] = tot.get(CACHE_1H, 0) + int(u[CACHE_1H])
    return into


def _has_tokens(usage):
    return any(int(v or 0) for u in (usage or {}).values() for v in (u or {}).values()
               if isinstance(v, (int, float)))


def _reported_usage(events):
    """True when one of `events` is a session_end that reports token usage: the session ran (#720)."""
    return any(e.get("event") == "session_end" and _has_tokens(e.get("usage")) for e in events)


def _live_events(events):
    """The events of `events` that belong to a launch that ran (#679). A session id can be launched again (a
    relaunch, a resume), so its events fall into segments, one per `launch`. A `launch_failed` drops only the
    segment it ends: the launch it follows and anything after it up to the next `launch`. It cannot reach back
    into a segment that already ended (a real run), nor one that never opened with a `launch` (a `start_failed`
    emits no `launch`); that failure is a segment of its own, and so is dropped alone. A failed segment whose
    `session_end` reports usage did run (#720: a lane gone within 30s of its launch, its `launch_failed` logged
    before the sweep's `session_end`): it keeps its events and its spend. The other order (#743: another
    worker's sweep logs the empty `session_end` before the owner's `launch_gone_check` logs `launch_failed`)
    fails the same segment: a `launch_failed` follows an ended segment that reported no usage into it, unless it
    is a `start_failed` (that launch never emitted a `launch`, so it is never the ended segment's)."""
    segs, cur = [], {}   # every segment; session id -> its open segment
    for e in events:
        sid = e.get("session")
        if not sid:
            continue
        ev = e.get("event")
        seg = cur.get(sid)
        if ev == "launch" or seg is None or (
                ev == "launch_failed" and (seg["failed"] or not seg["launched"] or e.get("reason") == "start_failed"
                                           or (seg["ended"] and _reported_usage(seg["evs"])))):
            seg = cur[sid] = {"evs": [], "launched": ev == "launch", "ended": False, "failed": False}
            segs.append(seg)
        if ev == "launch_failed":   # #596: it never ran
            seg["failed"] = True
        elif ev == "session_end":
            seg["ended"] = True
        seg["evs"].append(e)
    dead = {id(e) for seg in segs if seg["failed"] and not _reported_usage(seg["evs"]) for e in seg["evs"]}
    return [e for e in events if e.get("session") and id(e) not in dead]


def sessions(events):
    """One record per session id, merged from its launch + session_end (+ the rest). A launch that failed
    (`launch_failed`, #596) never ran and is left out; an earlier run under the same session id stays (#679)."""
    by = {}
    for e in _live_events(events):
        sid = e.get("session")
        s = by.setdefault(sid, {"session": sid, "usage": {}, "watchdog_kills": 0, "nudges": 0,
                                "turn_interrupts": 0})
        ev = e.get("event")
        for k in ("prefix", "project", "repo", "unit", "issue", "prd", "kind", "model", "effort", "worktree"):
            if e.get(k) is not None and (ev == "launch" or s.get(k) is None):
                s[k] = e[k]
        if ev == "launch":
            s["launched"] = e.get("ts")
        elif ev == "session_end":   # #426: a resumed run's session_end adds to the session's
            s["usage"] = fold_session_end(s["usage"], e)
            s["wall_s"] = ((s.get("wall_s") or 0) + (e.get("wall_s") or 0)) if e.get("resumed") else e.get("wall_s")
            s["ended"] = e.get("ts")
        elif ev == "watchdog_kill":
            s["watchdog_kills"] += 1
        elif ev == "nudge":
            s["nudges"] += 1
        elif ev == "turn_interrupted":
            s["turn_interrupts"] += 1
        elif ev == "model_mismatch":
            s["model_mismatch"] = {"intended": e.get("intended"), "actual": e.get("actual")}
    return list(by.values())


def mismatches(events):
    """Every `model_mismatch` event (#376), oldest first: a session that ran another model family than
    the one it was launched with."""
    return sorted((e for e in events if e.get("event") == "model_mismatch"), key=lambda e: e.get("ts") or "")


def vis(s):
    """A name for human-readable output (#756): a line or paragraph separator (U+2028, U+2029, U+0085), a form
    feed, any C0 or C1 control character and DEL become \\uXXXX, as json.dumps writes them, so a fleet prefix, repo
    or account name never splits one record across two lines in a terminal or log viewer."""
    return "".join(f"\\u{ord(c):04x}" if unicodedata.category(c) in ("Cc", "Zl", "Zp") else c for c in str(s))


def vrepr(v):
    """repr() of `v` for an error message (#899), its control characters spelled as `vis` does: a form feed is
    \\u000c, never repr's \\x0c, so one character reads one way whichever option echoed it. A non-string is repr()'d."""
    if not isinstance(v, str):
        return repr(v)
    body = vis(v)
    q = '"' if "'" in body and '"' not in body else "'"
    return q + body.replace(q, "\\" + q) + q


def choice_type(choices):
    """argparse `type=` for an option with a fixed set of values (#912). argparse's own `choices` error repr()s the
    value, so a form feed reads \\x0c there; this raises the same message with vrepr, so it reads as vis writes it.
    Pair it with `metavar="{a,b}"`, which is what `choices` would have shown in usage."""
    import argparse
    names = tuple(choices)

    def check(v):
        if v not in names:
            raise argparse.ArgumentTypeError(f"invalid choice: {short_repr(v)} (choose from {', '.join(names)})")
        return v
    return check


def arg_parser(*a, **kw):
    """An argparse.ArgumentParser that names a dash-led stray when it reports a missing positional (#956).
    argparse checks the required positionals before it lists the arguments it did not recognise, so `prog -x` with
    one required positional says only "the following arguments are required: issue" and never names `-x`. Here that
    error leads with `unrecognized arguments: -x`; every other error is argparse's own. Exit status stays 2."""
    import argparse

    class Parser(argparse.ArgumentParser):
        _seen = ()

        def parse_known_args(self, args=None, namespace=None):
            self._seen = tuple(sys.argv[1:] if args is None else args)
            return super().parse_known_args(args, namespace)

        def _is_stray(self, tok):
            if len(tok) < 2 or tok[0] != "-" or tok == "--":
                return False
            try:
                float(tok)   # a negative number is a positional value (this parser has no number-like option): its type reports it
                return False
            except ValueError:
                pass
            known = list(self._option_string_actions)
            if tok.startswith("--"):
                name = tok.split("=", 1)[0]
                return not any(k.startswith(name) for k in known if k.startswith("--"))
            return not any(tok.startswith(k) for k in known if len(k) == 2)

        def _check_value(self, action, value):
            # #970: argparse repr()s a subcommand name that is not one of the choices, so a form feed reads \x0c; this
            # words the same error with short_repr, so it reads as vis writes it (the subparsers' choices are the names)
            if action.choices is not None and value not in action.choices:
                names = ", ".join(map(str, action.choices))
                raise argparse.ArgumentError(action, f"invalid choice: {short_repr(value)} (choose from {names})")
            super()._check_value(action, value)

        def error(self, message):
            if message.startswith("the following arguments are required"):
                stray = []
                for tok in self._seen:
                    if tok == "--":
                        break
                    if self._is_stray(tok):
                        stray.append(tok)
                if stray:
                    message = "unrecognized arguments: " + " ".join(short_repr(t) if t != vis(t) else t for t in stray) + "; " + message
            super().error(message)
    return Parser(*a, **kw)


def _mismatch_line(e):
    who = f"#{e['issue']}" if e.get("issue") is not None else (f"PRD #{e['prd']}" if e.get("prd") is not None else "")
    where = " ".join(x for x in (e.get("repo") or "", who) if x)
    return vis(f"MODEL MISMATCH {where + ' ' if where else ''}session {e.get('session') or '?'}: "
               f"intended {e.get('intended')} ran {e.get('actual')} ({e.get('ts') or '?'})")


def _sess_matches(s, model):
    return not model or any(model in m for m in s["usage"]) or model in (s.get("model") or "")


def filter_events(events, since=None, fleet=None, repo=None):
    out = []
    for e in events:
        t = parse_ts(e.get("ts"))
        if since is not None and (t is None or t < since):
            continue
        if fleet and e.get("prefix") != fleet:
            continue
        if repo and (e.get("repo") or "").lower() != repo.lower():
            continue
        out.append(e)
    return out


def _retries(sess):
    """watchdog kills + re-dispatches (every launch of the same (repo, issue, kind) after the first)."""
    seen, redispatch = {}, 0
    for s in sess:
        if s.get("issue") is None or "launched" not in s:
            continue
        key = (s.get("repo"), s.get("issue"), s.get("kind"))
        redispatch += 1 if key in seen else 0
        seen[key] = True
    return redispatch + sum(s["watchdog_kills"] for s in sess)


def lane_claims(events):
    """Lane claims per repo (#472): {repo: {"claims": n, "workers": [worker, …]}}. Both event shapes
    count — the older `claim` (carries `unit` + `worker`) and the new `lane_claim` (`repo` + `worker`).
    An event is attributed to its `repo`, else to its `unit`."""
    out = {}
    for e in events:
        if e.get("event") not in ("claim", "lane_claim"):
            continue
        row = out.setdefault(str(e.get("repo") or e.get("unit") or "?"), {"claims": 0, "workers": set()})
        row["claims"] += 1
        if e.get("worker") not in (None, ""):
            row["workers"].add(str(e["worker"]))
    return {k: {"claims": v["claims"], "workers": sorted(v["workers"])} for k, v in sorted(out.items())}


def fleet_summary(events, model=None, rtdd=()):
    """Per fleet (session prefix): sessions, tokens by model, issues/PRDs closed, retries, HOLD minutes,
    and rtdd: selective vs full-suite `which` calls, plus each `rtdd_missing` start (#186)."""
    fleets = {}
    for e in events:
        f = fleets.setdefault(e.get("prefix") or "?", {"events": [], "rtdd": []})
        f["events"].append(e)
    for r in rtdd:
        fleets.setdefault(r.get("prefix") or "?", {"events": [], "rtdd": []})["rtdd"].append(r)
    out = {}
    for pfx, f in sorted(fleets.items()):
        evs = f["events"]
        sess = [s for s in sessions(evs) if _sess_matches(s, model)]
        tokens = {}
        for s in sess:
            add_usage(tokens, s["usage"], model)
        out[pfx] = {
            "sessions": len(sess),
            "tokens": tokens,
            "issues_closed": len({(e.get("repo"), e.get("issue")) for e in evs if e.get("event") == "merged"}),
            "prds_closed": len({(e.get("repo"), e.get("prd")) for e in evs if e.get("event") == "prd_closed"}),
            "retries": _retries(sess),
            "lanes": lane_claims(evs),
            "hold_minutes": round(sum(int(e.get("secs") or 0) for e in evs if e.get("event") == "hold") / 60, 1),
            "rtdd": rtdd_summary(f["rtdd"]),
            "model_mismatches": [{k: e[k] for k in ("ts", "session", "repo", "issue", "prd", "kind",
                                                    "intended", "actual") if k in e} for e in mismatches(evs)],
        }
        r = out[pfx]["rtdd"]
        if r.get("selective", 0) + r.get("full_suite", 0):
            r["selective_share"] = round(r["selective"] / (r["selective"] + r["full_suite"]), 2)
        missing = sum(1 for e in evs if e.get("event") == "rtdd_missing")
        if missing:
            r["missing"] = missing
    return out


def _split_fields(split):
    return {"coding_s": split["coding_s"] if split else None, "testing_s": split["testing_s"] if split else None}


def _sum_split(rows):
    """coding_s / testing_s summed over rows that have them; 0 when none does (the transcripts are gone)."""
    return {k: sum(r[k] for r in rows if r.get(k) is not None) for k in ("coding_s", "testing_s")}


def _sess_row(s, model=None, rtdd=(), timing=None):
    row = {"session": s["session"], "kind": s.get("kind"), "model": s.get("model"),
           "effort": s.get("effort"), "launched": s.get("launched"), "wall_s": s.get("wall_s"),
           "usage": add_usage({}, s["usage"], model), "watchdog_kills": s["watchdog_kills"],
           "rtdd": rtdd_summary([r for r in rtdd if r.get("session") == s["session"]])}
    if timing:
        row.update(_split_fields(timing(s["session"])))
    if s.get("model_mismatch"):
        row["model_mismatch"] = s["model_mismatch"]
    return row


# --- rtdd events (#186) --------------------------------------------------------
def join_rtdd(rtdd, events):
    """Attribute each rtdd event line to its Harness session. ctx.HARNESS_SESSION names the session;
    the session's own launch record (prefix/repo/issue/prd/kind) wins over the rest of the ctx, which
    only fills in for a session the events log no longer has."""
    by = {s["session"]: s for s in sessions(events)}
    out = []
    for r in rtdd:
        ctx = r.get("ctx") if isinstance(r.get("ctx"), dict) else {}
        rec = {"ts": r.get("ts"), "session": ctx.get("HARNESS_SESSION"), "rtdd": r}
        for k in ("prefix", "repo", "issue", "prd", "kind"):
            v = ctx.get(f"HARNESS_{k.upper()}")
            if v is not None and v != "":
                rec[k] = _coerce(str(v)) if k in ("issue", "prd") else v
        s = by.get(rec["session"]) if rec["session"] else None
        for k in ("prefix", "repo", "issue", "prd", "kind"):
            if s and s.get(k) is not None:
                rec[k] = s[k]
        out.append(rec)
    return out


def _rtdd_full_suite(r):
    """A `which` that left the lane on the full suite: rtdd failed, chose the whole suite itself (a v0.2
    tier-2 pick / fidelity none), or selected nothing — an empty selection sends the lane to the
    full-suite bar."""
    if r.get("exit") not in (None, 0) or r.get("tier") == "T2" or r.get("selection_fidelity") == "none":
        return True
    return int(r.get("round1") or 0) + int(r.get("round2") or 0) == 0


def rtdd_summary(recs):
    """Totals over joined rtdd events; {} when there are none, so the rtdd columns render empty."""
    if not recs:
        return {}
    out = {"calls": {}, "which": 0, "changed_nodes": 0, "round1": 0, "round2": 0, "stale_graph": 0,
           "graph_sources": {}, "wall_ms": 0, "selective": 0, "full_suite": 0, "backfilled": 0}
    for rec in recs:
        r = rec["rtdd"]
        cmd = r.get("cmd") or "?"
        out["calls"][cmd] = out["calls"].get(cmd, 0) + 1
        out["wall_ms"] += int(r.get("duration_ms") or 0)
        g = r.get("graph") if isinstance(r.get("graph"), dict) else {}
        out["stale_graph"] += 1 if int(g.get("stale_files") or 0) > 0 else 0
        if g.get("source"):
            out["graph_sources"][g["source"]] = out["graph_sources"].get(g["source"], 0) + 1
        if r.get("backfill"):   # a transcript count: no selection data to classify
            out["backfilled"] += 1
        if cmd != "which":
            continue
        out["which"] += 1
        for k in ("changed_nodes", "round1", "round2"):
            out[k] += int(r.get(k) or 0)
        if not r.get("backfill"):
            out["full_suite" if _rtdd_full_suite(r) else "selective"] += 1
    return out


def prd_rollup(events, prd, model=None, rtdd=(), timing=None):
    """PRD #prd and every child: each issue's sessions, model/effort, tokens, wall time and retries,
    rolled up to the PRD. A child is any session attributed to the PRD (`prd` field); the PRD's own
    DECOMPOSE/REVIEW sessions carry no issue and roll up under `issue: null`. <timing>(session id) →
    time_split or None, when given, adds each session's, issue's and the PRD's coding_s / testing_s (#379)."""
    sess = [s for s in sessions(events) if s.get("prd") == prd and _sess_matches(s, model)]
    kept = {s["session"] for s in sess}
    rtdd = [r for r in rtdd if r.get("prd") == prd and (not model or r.get("session") in kept)]
    groups = {}
    for s in sess:
        groups.setdefault(s.get("issue"), []).append(s)
    for r in rtdd:
        groups.setdefault(r.get("issue"), [])
    children, total = [], {"sessions": 0, "tokens": {}, "wall_s": 0, "retries": 0, "rtdd": rtdd_summary(rtdd)}
    for issue in sorted(groups, key=lambda i: (i is not None, i or 0)):
        ss = sorted(groups[issue], key=lambda s: s.get("launched") or "")
        rr = [r for r in rtdd if r.get("issue") == issue]
        row = {"issue": issue, "sessions": [_sess_row(s, model, rr, timing) for s in ss], "tokens": {},
               "wall_s": sum(int(s.get("wall_s") or 0) for s in ss), "retries": _retries(ss),
               "rtdd": rtdd_summary(rr)}
        if timing:
            row.update(_sum_split(row["sessions"]))
        for s in ss:
            add_usage(row["tokens"], s["usage"], model)
        children.append(row)
        total["sessions"] += len(ss)
        add_usage(total["tokens"], row["tokens"])
        total["wall_s"] += row["wall_s"]
        total["retries"] += row["retries"]
    if timing:
        total.update(_sum_split(children))
    return {"prd": prd, "children": children, "total": total}


def issue_timeline(events, issue, rtdd=(), timing=None):
    tl = sorted((e for e in events if e.get("issue") == issue), key=lambda e: e.get("ts") or "")
    rr = [r for r in rtdd if r.get("issue") == issue]
    out = {"issue": issue, "events": tl, "rtdd": rtdd_summary(rr),
           "sessions": [_sess_row(s, rtdd=rr, timing=timing) for s in sessions(tl)]}
    if timing:
        out.update(_sum_split(out["sessions"]))
    return out


# --- per-role rollup (#378) -----------------------------------------------------
# A session's role, from the kind its launch logged (goal_fields / classify_dir) — the Python side of
# lib.sh sess_role: an issue lane (impl, also when it resumes) and a bug fix implement; orchestration
# (PLAN / PRD / DECOMPOSE: orch), REVIEW and its gauntlet, bug triage and the injector manage.
ROLES = ("manager", "implementer", "other")
ROLE_BY_KIND = {"impl": "implementer", "bug-fix": "implementer",
                "orch": "manager", "review": "manager", "bug-triage": "manager", "inject": "manager"}
# A session with no kind (an event log from before kinds, a hand-written line): its worktree's name,
# the naming lib.sh orch_worktree / triage_worktree / bug_worktree and an issue lane's <unit>-i<n> use
# (classify_dir reads the same scheme off a transcript's project dir).
_ROLE_BY_WORKTREE = ((re.compile(r"(?:orch-.+-p|triage-.+-i)\d+"), "manager"),
                     (re.compile(r".+-i\d+"), "implementer"))   # an issue lane, or bug-<slug>-i<n>: a fix


def session_role(s):
    """'manager' / 'implementer' for a session record (sessions()), 'other' when neither its kind nor its
    worktree's name says — never dropped."""
    kind = s.get("kind")
    if kind:
        return ROLE_BY_KIND.get(kind, "other")
    name = os.path.basename((s.get("worktree") or "").rstrip("/"))
    return next((role for rx, role in _ROLE_BY_WORKTREE if rx.fullmatch(name)), "other")


def _usage_cost(usage):
    """List-price $ for a folded usage (forecast.py's PRICE table — one place for prices). Loaded on
    first use: forecast.py loads this module itself."""
    global _FORECAST
    if _FORECAST is None:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "forecast", os.path.join(os.path.dirname(os.path.abspath(__file__)), "forecast.py"))
        _FORECAST = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_FORECAST)
    return _FORECAST.usage_cost_split(usage)


_FORECAST = None


def _role_row(sess, model=None):
    tokens = {}
    for s in sess:
        add_usage(tokens, s["usage"], model)
    totals = {k: sum(u[k] for u in tokens.values()) for _, k in USAGE_KEYS}
    usd, est, unpriced = _usage_cost(tokens)
    row = {"sessions": len(sess), **totals, "usd": round(usd, 4), "tokens": tokens}
    if unpriced:   # #750: no price row for these models (codex, agy, opencode) → that part is an estimate
        row["usd_estimated"] = round(est, 4)
        row["unpriced_models"] = sorted(unpriced)
    return row


def role_rollup(events, model=None, prd=None, issue=None):
    """Tokens (input / output / cache) and list-price $ per role — manager, implementer, and `other` for
    a session whose kind maps to neither (shown only when there is one) — plus their total. --prd /
    --issue narrow to that PRD's / issue's sessions, like the other levels."""
    sess = [s for s in sessions(events) if _sess_matches(s, model)
            and (prd is None or s.get("prd") == prd) and (issue is None or s.get("issue") == issue)]
    by = {r: [] for r in ROLES}
    for s in sess:
        by[session_role(s)].append(s)
    roles = {r: _role_row(ss, model) for r, ss in by.items() if ss or r != "other"}
    return {"roles": roles, "total": _role_row(sess, model)}


def _tok(usage):
    parts = []
    for model, u in sorted(usage.items()):
        parts.append(f"{model}: out {u['output']:,} in {u['input']:,} "
                     f"cache_create {u['cache_create']:,} cache_read {u['cache_read']:,}")
    return "; ".join(parts) or "-"


def _rtdd(r):
    if not r:
        return "-"
    parts = [f"which {r.get('which', 0)}"] if "which" in r else []
    if "which" in r:
        parts += [f"changed nodes {r['changed_nodes']}", f"round1 {r['round1']}", f"round2 {r['round2']}",
                  f"stale graph {r['stale_graph']}", f"selective {r['selective']}/{r['selective'] + r['full_suite']}"]
        others = {c: n for c, n in r["calls"].items() if c != "which"}
        if others:
            parts.append(" ".join(f"{c} {n}" for c, n in sorted(others.items())))
        if r["backfilled"]:
            parts.append(f"backfilled {r['backfilled']}")
        parts.append(f"{r['wall_ms'] / 1000:.1f}s")
    if "selective_share" in r:
        parts.append(f"{round(r['selective_share'] * 100)}% selective")
    if r.get("missing"):
        parts.append(f"rtdd missing at {r['missing']} start(s)")
    return "  ".join(parts)


def _hms(s):
    s = int(s or 0)
    return f"{s // 3600}h{s % 3600 // 60:02d}m" if s >= 3600 else f"{s // 60}m{s % 60:02d}s"


def _coding_testing(r):
    """`coding 5m00s  testing 1m00s` for a row carrying coding_s / testing_s (#379), else ''."""
    if r.get("coding_s") is None and r.get("testing_s") is None:
        return ""
    return f"coding {_hms(r.get('coding_s'))}  testing {_hms(r.get('testing_s'))}"


def render_text(kind, data):
    out = []
    if kind == "fleet":
        if not data:
            out.append("no events in range")
        for pfx, f in data.items():
            out.append(f"fleet {pfx}: sessions {f['sessions']}  issues closed {f['issues_closed']}  "
                       f"PRDs closed {f['prds_closed']}  retries {f['retries']}  HOLD {f['hold_minutes']}m")
            out.append(f"  tokens  {_tok(f['tokens'])}")
            out.append(f"  rtdd    {_rtdd(f['rtdd'])}")
            if f.get("lanes"):
                out.append("  lanes   " + "  ".join(
                    f"{k} {v['claims']} claim(s) by {len(v['workers'])} worker(s)" for k, v in f["lanes"].items()))
            for e in f.get("model_mismatches") or ():
                out.append(f"  ⚠ {_mismatch_line(e)}")
    elif kind == "prd":
        t = data["total"]
        out.append(f"PRD #{data['prd']}: sessions {t['sessions']}  wall {_hms(t['wall_s'])}  retries {t['retries']}")
        out.append(f"  tokens  {_tok(t['tokens'])}")
        out.append(f"  rtdd    {_rtdd(t['rtdd'])}")
        if _coding_testing(t):
            out.append(f"  time    {_coding_testing(t)}")
        for c in data["children"]:
            label = f"#{c['issue']}" if c["issue"] is not None else "(PRD orchestration)"
            out.append(f"  {label}: sessions {len(c['sessions'])}  wall {_hms(c['wall_s'])}  retries {c['retries']}"
                       f"  rtdd {_rtdd(c['rtdd'])}" + (f"  {_coding_testing(c)}" if _coding_testing(c) else ""))
            for s in c["sessions"]:
                mm = s.get("model_mismatch")
                flag = f"  ⚠ MODEL MISMATCH: ran {mm['actual']}" if mm else ""
                ct = f"  {_coding_testing(s)}" if _coding_testing(s) else ""
                out.append(f"    {s['launched'] or '?'}  {s['kind'] or '?'}  {s['model'] or '?'}/{s['effort'] or '?'}  "
                           f"wall {_hms(s['wall_s'])}{ct}  {_tok(s['usage'])}{flag}")
    elif kind == "role":
        rows = list(data["roles"].items()) + [("total", data["total"])]
        for role, r in rows:
            out.append(f"{role:<12} sessions {r['sessions']}  in {r['input']:,}  out {r['output']:,}  "
                       f"cache_create {r['cache_create']:,}  cache_read {r['cache_read']:,}  ${r['usd']:,.2f}")
            if r.get("unpriced_models"):
                out.append(f"  ≤ estimate: ${r['usd_estimated']:,.2f} of that is "
                           f"{', '.join(r['unpriced_models'])} at the dearest list rate (no price row for the model)")
            if role != "total" and r["tokens"]:
                out.append(f"  tokens  {_tok(r['tokens'])}")
    elif kind == "issue":
        out.append(f"issue #{data['issue']}: {len(data['sessions'])} session(s)")
        for e in data["events"]:
            extra = " ".join(f"{k}={e[k]}" for k in ("kind", "model", "effort", "intended", "actual", "reason", "pr",
                                                         "wall_s", "reset", "turn_s", "queued_nudges")
                             if k in e)
            if e.get("event") == "model_mismatch":
                extra = f"⚠ {extra}"
            line = f"  {e.get('ts')}  {e.get('event')}  {extra}".rstrip()
            if e.get("usage"):
                line += f"  {_tok(e['usage'])}"
            out.append(line)
        out.append(f"  rtdd  {_rtdd(data['rtdd'])}")
        if _coding_testing(data):
            out.append(f"  time  {_coding_testing(data)}")
    return "\n".join(vis(line) for line in out)   # #756: every line is one record, whatever a name holds


# A GitHub owner/name: each half starts with a letter, digit or underscore (a name may also start with a dot,
# as in `.github`), never a dash — `-x/name` and `owner/-x` would be read as a flag by `gh -R`. One check for
# `harness stats` and `forecast.py` (#716).
REPO_RE = re.compile(r"[A-Za-z0-9_][\w.-]*/[\w.][\w.-]*")


INT_RE = re.compile(r"-?[0-9]+")   # ASCII digits only: int() also takes 1_1, +5 and full-width digits (#784)


INT_MAX_DIGITS = 1000   # a whole-number option longer than this is refused before int(), which itself refuses 4300+ digits


def short_repr(v, keep=20):
    """repr() of `v` for a usage error: a long value is cut to `keep` characters and an ellipsis, so one line
    never carries the multi-KB input back (#880)."""
    return vrepr(v) if len(v) <= keep else vrepr(v[:keep]) + "\u2026"


def int_arg(v):
    """argparse type for a whole-number option: ASCII decimal digits with an optional `-` sign. `1_1`, `+5` and
    full-width digits are usage errors (exit 2), never a different number than the one typed (#784). A value of
    more than INT_MAX_DIGITS digits is one too, refused before int() (which raises past 4300) with the option's
    own message and a truncated echo (#880)."""
    import argparse
    if not INT_RE.fullmatch(v):
        raise argparse.ArgumentTypeError(f"invalid int value: {short_repr(v)} (use ASCII digits only)")
    digits = v.lstrip("-")
    if len(digits.lstrip("0")) > INT_MAX_DIGITS:
        raise argparse.ArgumentTypeError(f"{short_repr(v)} is too large (more than {INT_MAX_DIGITS} digits)")
    if len(digits) > INT_MAX_DIGITS:
        raise argparse.ArgumentTypeError(f"{short_repr(v)} is too long (more than {INT_MAX_DIGITS} digits; drop the leading zeros)")
    return int(v)


def repo_arg(v):
    """argparse type for -R / --repo in every form (`-R x`, `--repo x`, `--repo=x`): must be owner/name."""
    import argparse
    if not REPO_RE.fullmatch(v):
        raise argparse.ArgumentTypeError(f"{short_repr(v)} is not a repository — expected owner/name")
    return v


def fleet_arg(v):
    """argparse type for --fleet (session prefix): non-empty and never dash-leading, so `--fleet=-x` is a usage
    error (exit 2) as `--repo=-x` is (#839), not "no events in range"."""
    import argparse
    if not v or v.startswith("-"):
        raise argparse.ArgumentTypeError(f"{short_repr(v)} is not a fleet prefix — it must be non-empty and not start with '-'")
    return v


def nonempty_arg(flag):
    """argparse type factory for a value option that has no meaning when empty (`--since=`, `--model=`): an empty
    value is a usage error (exit 2) as `--fleet=` is (#839), not a silently dropped filter (#862)."""
    import argparse

    def check(v):
        if not v:
            raise argparse.ArgumentTypeError(f"{flag} must not be empty")
        return v
    return check


def _explicit_log_error(path, kind="an events file"):
    """Why an explicitly passed events file (or, with `kind`, another input file) cannot be read, or None (#758, #935). None path = the default file: its
    absence on a fresh install stays "no events". A missing path, a directory or an unreadable file names the path."""
    if path is None:
        return None
    if os.path.isdir(path):
        return f"{vrepr(path)} is a directory, not {kind}"
    try:
        with open(path, "rb"):
            pass
    except FileNotFoundError:
        return f"{vrepr(path)} does not exist"
    except OSError as e:
        return f"{vrepr(path)} is not readable ({e.strerror or e})"
    return None


def cmd_report(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="harness stats", description="Harness event-log report (#185)")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--prd", type=int_arg)
    g.add_argument("--issue", type=int_arg)
    g.add_argument("--backfill", action="store_true", help="rebuild session_end for past sessions")
    ap.add_argument("-R", "--repo", type=repo_arg)
    ap.add_argument("--since", type=nonempty_arg("--since"),
                    help="7d, 24h, 30m or YYYY-MM-DD (default: 7d for the fleet summary)")
    ap.add_argument("--fleet", type=fleet_arg, help="session prefix")
    ap.add_argument("--model", type=nonempty_arg("--model"), help="substring of a model id")
    ap.add_argument("--by-role", action="store_true",
                    help="tokens and list-price $ per role (manager / implementer / other), #378")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--events", help=argparse.SUPPRESS)
    ap.add_argument("--rtdd-events", help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    for flag, num in (("--prd", a.prd), ("--issue", a.issue)):
        if num is not None and num < 1:
            print(f"harness stats: {flag} must be 1 or greater, got {num}", file=sys.stderr)
            return 2
    if a.backfill:
        n, calls = backfill(a.events), backfill_rtdd(a.rtdd_events)
        print(f"backfilled {n} session(s), {calls} rtdd call(s)")
        return 0
    try:
        since = parse_since(a.since) if a.since else (None if (a.prd is not None or a.issue is not None) else parse_since("7d"))
    except ValueError as e:
        print(f"harness stats: {e}", file=sys.stderr)
        return 2
    for flag, path in (("--events", a.events), ("--rtdd-events", a.rtdd_events)):
        err = _explicit_log_error(path)   # #758: a typo'd path is not an empty fleet
        if err:
            print(f"harness stats: {flag} {err}", file=sys.stderr)
            return 2
    bad = [0]
    every = load_events(a.events, bad)
    evs = filter_events(every, since, a.fleet, a.repo)
    # joined against EVERY event: a --since that cuts a session's launch must not orphan its rtdd calls
    rtdd = filter_events(join_rtdd(load_events(a.rtdd_events or rtdd_events_path(), bad), every), since, a.fleet, a.repo)
    if bad[0]:   # #672: spend in an unparseable line is lost from the totals — say so, on stderr (stdout stays the report)
        print(f"harness stats: skipped {bad[0]} event line(s) that could not be parsed; totals exclude them",
              file=sys.stderr)
    if a.by_role:
        kind, data = "role", role_rollup(evs, a.model, a.prd, a.issue)
    elif a.prd is not None:
        kind, data = "prd", prd_rollup(evs, a.prd, a.model, rtdd, session_time_split)
    elif a.issue is not None:
        kind, data = "issue", issue_timeline(evs, a.issue, rtdd, session_time_split)
    else:
        kind, data = "fleet", fleet_summary(evs, a.model, rtdd)
    _print_report(json.dumps(data, indent=2) if a.json else render_text(kind, data))
    return 0


def _print_report(text):
    """print(), but a reader that closed the pipe early (`| head -1`) ends the command quietly (#671), and so
    does a closed stdout (`>&-`, sys.stdout None: print() drops the text, the flush must not raise, #806)."""
    if sys.stdout is None:
        return
    try:
        print(text)
        sys.stdout.flush()
    except BrokenPipeError:
        # the unflushed rest would raise again at interpreter exit: point stdout at devnull first
        try:
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        except (OSError, ValueError):
            pass


def cmd_mismatches(argv):
    """One `MODEL MISMATCH …` line per model_mismatch event in range (default the last 7d), for
    `harness status`. Prints nothing when there are none; never fails the caller."""
    import argparse
    ap = argparse.ArgumentParser(prog="stats.py mismatches")
    ap.add_argument("--fleet")
    ap.add_argument("-R", "--repo")
    ap.add_argument("--since", default="7d")
    ap.add_argument("--events", help=argparse.SUPPRESS)
    try:
        a = ap.parse_args(argv)
        evs = filter_events(load_events(a.events), parse_since(a.since), a.fleet, a.repo)
    except (SystemExit, ValueError):
        return 2
    for e in mismatches(evs):
        print(_mismatch_line(e))
    return 0


# --- backfill ----------------------------------------------------------------
def _slugify(path):
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def _fleets():
    out = []
    for f in sorted(glob.glob(os.path.join(os.environ.get("HARNESS_FLEETS_DIR") or os.path.join(home(), "fleets"), "*.json"))):
        try:
            with open(f) as fh:
                out.append(json.load(fh))
        except Exception:
            continue
    return out


_CFG_KEYS = ("HARNESS_REPO", "HARNESS_OWNER", "HARNESS_UNIT", "HARNESS_CHECKOUT")


def read_config(state_dir, keys=None):
    """{KEY: value} of the fleet's one-repo keys from <state_dir>/config (#466). Reads both the
    `: "${KEY:=val}"` lines `harness init` writes and a plain `KEY=val` (optionally `export`ed,
    optionally quoted) a hand-written config uses. The file only, never the environment: a lane
    session exports its own HARNESS_REPO (#186). The last assignment wins, as when sourced."""
    cfg = {}
    try:
        with open(os.path.join(state_dir, "config"), encoding="utf-8-sig", errors="replace") as fh:   # #859: a BOM is not part of the first key
            text = fh.read()
    except (OSError, TypeError):
        return cfg
    keys = "|".join(keys or _CFG_KEYS)
    # ASCII blanks only, as bash splits words (#933): \s is Unicode-aware, so a form feed or U+2028 in a value ended it early.
    pat = (r'^[ \t]*:[ \t]*"\$\{(' + keys + r'):=([^}"]*)\}"'
           r'|^[ \t]*(?:export[ \t]+)?(' + keys + r')=(?:"([^"]*)"|\'([^\']*)\'|([^ \t\n#]*))')
    for m in re.finditer(pat, text, re.M):
        if m.group(1):
            cfg[m.group(1)] = m.group(2)
        else:
            cfg[m.group(3)] = next((g for g in m.group(4, 5, 6) if g is not None), "")
    return cfg


def _unit_repo(project_state, unit, slugs):
    """The repo a unit drives: HARNESS_UNIT's HARNESS_REPO when the config sets it (#466), else the fleet's only slug."""
    cfg = read_config(project_state)
    if cfg.get("HARNESS_UNIT") and cfg.get("HARNESS_REPO") and cfg["HARNESS_UNIT"] == unit:
        repo = cfg["HARNESS_REPO"]
        if "/" not in repo and cfg.get("HARNESS_OWNER"):
            repo = cfg["HARNESS_OWNER"] + "/" + repo
        name = repo.split("/")[-1].lower()
        return next((s for s in slugs if s.split("/")[-1].lower() == name), repo)
    return slugs[0] if len(slugs) == 1 else None


def classify_dir(name, fleets):
    """Attribution for a transcript project-dir name, from the worktree naming scheme
    (…-harness-worktrees-<unit>-i<N> / bug-<slug>-i<N> / triage-<slug>-i<N> / orch-<slug>-p<N>)."""
    for fl in fleets:
        root = os.path.dirname(fl.get("project") or "")
        lead = _slugify(root) + "--harness-worktrees-"
        if not root or not name.startswith(lead):
            continue
        rest, slugs = name[len(lead):], fl.get("slugs") or []
        rec = {"prefix": fl.get("prefix"), "project": root}
        by_san = {_slugify(s.replace("/", "_")): s for s in slugs}
        for pat, kind, field in ((r"orch-(.+)-p(\d+)", "orch", "prd"), (r"bug-(.+)-i(\d+)", "bug-fix", "issue"),
                                 (r"triage-(.+)-i(\d+)", "bug-triage", "issue")):
            m = re.fullmatch(pat, rest)
            if m:
                rec.update({"kind": kind, field: int(m.group(2))})
                if m.group(1) in by_san:
                    rec["repo"] = by_san[m.group(1)]
                return rec
        m = re.fullmatch(r"(.+)-i(\d+)", rest)
        if m:
            rec.update({"kind": "impl", "unit": m.group(1), "issue": int(m.group(2))})
            repo = _unit_repo(fl.get("project"), m.group(1), slugs)
            if repo:
                rec["repo"] = repo
            return rec
        return rec
    m = re.search(r"-harness-worktrees-(?:(orch)-.+-p(\d+)|(.+)-i(\d+))$", name)
    if m:
        return {"kind": "orch", "prd": int(m.group(2))} if m.group(1) else \
               {"kind": "impl", "unit": m.group(3), "issue": int(m.group(4))}
    return None


RTDD_CALL_RE = re.compile(r"(?:^|[\s;&|(`])rtdd\s+(which|init|run|seed)\b")


def rtdd_calls(transcript):
    """[(ts, cmd)] for every `rtdd which|init` (and the pre-v0.3 run/seed verbs) a session's Bash tool
    calls ran, over the main transcript and its subagents. A streamed message repeats its blocks, so
    each tool_use id counts once."""
    seen, out = set(), []
    for path in [transcript] + sorted(glob.glob(os.path.join(transcript[:-len(".jsonl")], "subagents", "*.jsonl"))):
        try:
            fh = open(path)
        except OSError:
            continue
        with fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                content = (r.get("message") or {}).get("content") if r.get("type") == "assistant" else None
                for b in content if isinstance(content, list) else ():
                    if not isinstance(b, dict) or b.get("type") != "tool_use" or b.get("name") != "Bash":
                        continue
                    if b.get("id") in seen:
                        continue
                    seen.add(b.get("id"))
                    for m in RTDD_CALL_RE.finditer(str((b.get("input") or {}).get("command") or "")):
                        out.append((r.get("timestamp"), m.group(1)))
    return out


def _harness_transcripts():
    """(attribution, session id, transcript) for every Harness-worktree main transcript on the host."""
    fleets = _fleets()
    for d in config_dirs():
        for pdir in sorted(glob.glob(os.path.join(d, "projects", "*"))):
            attr = classify_dir(os.path.basename(pdir), fleets)
            if attr is None:
                continue
            for tr in sorted(glob.glob(os.path.join(pdir, "*.jsonl"))):
                yield attr, os.path.basename(tr)[:-len(".jsonl")], tr


def backfill(path=None):
    """Write a session_end (backfill: true) for every Harness-worktree transcript the log has none for.
    Worker logs carry only HH:MM:SS, no date, so lifecycle events are not reconstructed from them."""
    have = {e.get("session") for e in load_events(path) if e.get("event") == "session_end"}
    n = 0
    for attr, sid, tr in _harness_transcripts():
        if sid in have:
            continue
        usage, first, last = session_usage(tr)
        if not usage:
            continue
        rec = dict(attr, session=sid, usage=usage, backfill=True, event="session_end",
                   ts=now_iso(last or os.path.getmtime(tr)))
        if first is not None and last is not None:
            rec["wall_s"] = int(last - first)
        if append_event(rec, path):
            have.add(sid)
            n += 1
    return n


def backfill_rtdd(path=None):
    """For every Harness session with no rtdd events (one from before RTDD_EVENT_LOG was exported),
    write one backfilled rtdd line per `rtdd` Bash call in its transcripts — counts only, no
    selection data (#186). Returns the number of calls written."""
    path = path or rtdd_events_path()
    have = {e["ctx"].get("HARNESS_SESSION") for e in load_events(path) if isinstance(e.get("ctx"), dict)}
    n = 0
    for attr, sid, tr in _harness_transcripts():
        if sid in have:
            continue
        ctx = {f"HARNESS_{k.upper()}": str(attr[k]) for k in ("prefix", "repo", "issue", "prd", "kind") if k in attr}
        ctx["HARNESS_SESSION"] = sid
        for ts, cmd in rtdd_calls(tr):
            n += 1 if append_event({"v": 1, "ts": ts, "cmd": cmd, "backfill": True, "ctx": ctx}, path) else 0
        have.add(sid)
    return n


def cmd_parent_prd(argv):
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "issuelib", os.path.join(os.path.dirname(os.path.abspath(__file__)), "issuelib.py"))
    il = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(il)
    slug = argv[0] if argv else ""
    p = il.parse_parent(sys.stdin.read(), slug)
    if p and (not slug or p[0].lower() == slug.lower()):
        print(p[1])
    return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    cmd, rest = (argv[0], argv[1:]) if argv else ("report", [])
    if cmd == "emit":
        try:
            return cmd_emit(rest)
        except Exception:
            return 1
    if cmd == "parent-prd":
        return cmd_parent_prd(rest)
    if cmd == "goal-env":
        print("\n".join(goal_env(*rest[:2])))
        return 0
    if cmd == "transcripts":   # the claude adapter's cli_transcripts (#188)
        tr = find_transcript(rest[0]) if rest else None
        print("\n".join(transcript_files(tr)) if tr else "")
        return 0
    if cmd == "usage":         # the claude adapter's cli_usage (#188)
        acc, span = {}, [None, None]
        for f in rest:
            _file_usage(f, acc, span)
        sys.stdout.write(usage_tsv(acc))
        return 0
    if cmd == "time-split":    # a transcript's coding vs testing time as JSON (#379); 1 when it has none
        r = time_split(rest[0]) if rest else None
        if r is None:
            return 1
        print(json.dumps(r))
        return 0
    if cmd == "ran":           # rc 0 when the event log holds usage for session <uuid> (#720)
        return 0 if rest and _has_tokens(logged_session_usage(rest[0])) else 1
    if cmd == "mismatches":    # `harness status`' model-mismatch flags (#376)
        return cmd_mismatches(rest)
    if cmd == "backfill":
        return cmd_report(["--backfill"] + rest)
    if cmd == "report":
        return cmd_report(rest)
    return cmd_report(argv)


if __name__ == "__main__":
    import pipesafe   # #783: `--help` into a closed stdout ends the command quietly
    sys.exit(pipesafe.run(main))
