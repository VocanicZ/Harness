#!/usr/bin/env python3
"""forecast.py — `harness forecast <issue>`: per-phase cost forecast for one issue (#363, PRD #362).

Reads the host event log (stats.py, #185) for the past issue lanes (impl / bug-fix sessions) and
splits each lane's spend into phases from its Claude transcripts (main + sub-agents):

    explore  everything before the lane's first edit
    test     Edit/Write/MultiEdit/NotebookEdit on a test path
    impl     any other edit
    gate     a test/gate runner (test/run.sh, ci-local, swarm-suite, rtdd which, pytest, …)
    ship     gh pr / git push / gh issue close|edit|comment

A message's cost goes to the phase its own tool calls leave the lane in; usage is taken once per
message/request id. Tokens are priced at list price per model. A lane with no transcript (another
CLI, whose adapter folded its usage into session_end — usage_tsv, #188) adds its priced total,
spread over the phases by the attributed lanes' mean mix. A lane under MIN_LANE_USD died at turn 1
and is skipped.

The distribution is p50/p80/p95 per phase and in total, scaled by the issue's body length over the
median body of the pool's issues (clamped to SCALE_CLAMP). The pool is the issue's PRD siblings in
its repo, else every lane of the unit (its repo), else every lane on the host — each fallback is
named in the output.

% of each usage window (#364): usage_watch logs every new reading as a `usage_reading` event
(account, window, pct, resets_at). For each account/window, consecutive readings inside one window
(the same resets_at — a pair across a reset is skipped) give a pair: the % it rose by, and the $ the
event log's sessions on that account spent between the two (each message of their transcripts, by
its timestamp; the account is the transcript's config dir, the name the status line reports). The fit
is $ per 1%: central = Σ$ / Σ%, and the conservative bound — the low end, so the % a forecast needs is
over- rather than under-estimated — is the BOUND_Q quantile of the per-pair $/1%, never above the
central fit. An account/window with no usable pair falls back to HARNESS_ONE_USD_PER_PCT (the
environment, else the project config), and the output says so; with neither, % is n/a.

    forecast.py <issue> [-R owner/repo] [--unit U] [--json]
"""
import bisect, importlib.util, json, math, os, re, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import portable  # noqa: E402  #686: resolve_argv — a gh script first on a native Windows PATH is the one that runs

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, f"{name}.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


st = _load("stats")

PHASES = ("explore", "test", "impl", "gate", "ship")
LANE_KINDS = ("impl", "bug-fix")
MIN_LANES = 3            # fewer past lanes than this in a pool → fall back to the next, wider one
MIN_LANE_USD = 0.5       # a lane that spent less died at turn 1
SCALE_CLAMP = (0.6, 2.0)
QUANTILES = (("p50", 0.5), ("p80", 0.8), ("p95", 0.95))
FALLBACK_SETTING = "HARNESS_ONE_USD_PER_PCT"
BOUND_Q = 0.2            # the conservative $-per-1% bound: this quantile of the per-pair fits
RESET_SLACK = 300        # two readings whose resets_at differ by more than this straddle a window reset

# $ per Mtok at list price: input, output, 5-minute cache write (1.25x input), 1-hour cache write (2x input),
# cache read. Source: Anthropic's first-party price list (platform.claude.com/docs/en/about-claude/pricing), #832.
# A price is per model VERSION where the list price differs inside a family (_VERSIONS): Opus 5.0 is $5 / $25 and
# Opus 5.5 $4 / $20; Sonnet 5.5 reads cache at $0.10 (0.05x input), Sonnet 5.0 at $0.20; Haiku 5.5 is $0.10 / $0.50
# against Haiku 4.5's $1 / $5; Fable 5.2 is $8 / $40 (cache read 0.025x input), Fable 5 and 5.1 are $10 / $50.
# Cache writes are 1.25x / 2x input everywhere; cache reads are 0.1x input except where the list says otherwise.
# Which row a version takes: its own row; a version no row names (opus 5.3, a future fable 5.3 or opus 6.0) takes the
# nearest row BELOW it, so a newer version than every known one takes the newest known row; an id with no version
# ("opus", "claude-sonnet", the Claude Code aliases) takes the newest row. Between two rows that is the dearer one.
# Opus / Sonnet 4.x and older (the "-legacy" rows) keep their own, dearer prices.
# Opus 4, Opus 4.1 and Claude 3 Opus were listed at $15 / $75 ("opus-4"): the dearest row.
# Claude 3.5 Haiku ($0.80 / $4) and Claude 3 Haiku ($0.25 / $1.25) keep their own, cheaper rows (#751).
# Haiku 5.5's list price is higher above 100K prompt tokens ($0.50 / $2.50, cache write 5m $0.625, 1h $1, read $0.05):
# "haiku" is the up-to-100K row, "haiku-long" the long-prompt one (#843). The prompt length counts every input token,
# cache reads and writes included, and each request is priced on its own: `raw_cost` (one message) switches rows
# on it. A folded usage (`usage_cost`) has no per-request length, so it is always priced at the up-to-100K row.
# Mythos (priced as Fable) has no row. A model no family matches is priced at the most expensive row in the table
# (see `price`) — the conservative end, for a budget gate.
PRICE = {
    "opus": (4, 20, 5, 8, 0.2), "opus-5": (5, 25, 6.25, 10, 0.5),
    "sonnet": (2, 10, 2.5, 4, 0.1), "sonnet-5": (2, 10, 2.5, 4, 0.2),
    "haiku": (0.1, 0.5, 0.125, 0.2, 0.01), "haiku-long": (0.5, 2.5, 0.625, 1, 0.05), "haiku-4-5": (1, 5, 1.25, 2, 0.1),
    "fable": (8, 40, 10, 16, 0.2), "fable-5-1": (10, 50, 12.5, 20, 0.25), "fable-5": (10, 50, 12.5, 20, 1.0),
    "opus-legacy": (5, 25, 6.25, 10, 0.5), "sonnet-legacy": (3, 15, 3.75, 6, 0.3),
    "opus-4": (15, 75, 18.75, 30, 1.5),
    "haiku-3-5": (0.8, 4, 1.0, 1.6, 0.08), "haiku-3": (0.25, 1.25, 0.3125, 0.5, 0.025),
}
HAIKU_LONG_PROMPT = 100_000   # Haiku 5.5 prompt tokens above which a request is priced at PRICE["haiku-long"]
# family -> ascending (major, minor, PRICE key): the versions whose list price differs
_VERSIONS = {
    "opus": ((5, 0, "opus-5"), (5, 5, "opus")),
    "sonnet": ((5, 0, "sonnet-5"), (5, 5, "sonnet")),
    "haiku": ((4, 5, "haiku-4-5"), (5, 5, "haiku")),
    "fable": ((5, 0, "fable-5"), (5, 1, "fable-5-1"), (5, 2, "fable")),
}
# The version in a family-first Claude model id: "claude-opus-5" (5.0), "claude-sonnet-5-5[1m]", "claude-fable-5.2".
# A dated id ("claude-opus-5-20261001") has no minor: \d{1,2} must not be the front of an 8-digit date.
_VER = re.compile(r"(?:opus|sonnet|haiku|fable)-(\d+)(?:[-.](\d{1,2})(?!\d))?")
# The major version in a Claude model id: "claude-opus-4-1" / "claude-sonnet-5-5" (family first), or the
# older "claude-3-opus-20240229" / "claude-3-5-sonnet" (version first).
_GEN = re.compile(r"(?:opus|sonnet)-(\d+)|claude-(\d+)(?:-\d+)?-(?:opus|sonnet)")
FIRST_CURRENT_GEN = 5
# The Haiku ids with their own row: "claude-3-5-haiku-20241022" / "claude-3.5-haiku" and "claude-3-haiku-20240307".
_HAIKU_OLD = re.compile(r"claude-3([-.]5)?-haiku")
# The Opus ids listed at $15 / $75: "claude-3-opus*", and Opus 4 / 4.1 — "claude-opus-4-0", "claude-opus-4-1",
# the dated "claude-opus-4-20250514" (no minor version). Opus 4.5 and later ("claude-opus-4-5") are not.
_OPUS_DEAR = re.compile(r"claude-3-opus|opus-4(?:[-.]([01]))?(?![\d.])(?!-\d{1,2}(?!\d))")


EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
TEST_PATH = re.compile(r"(^|/)(tests?|spec)/|_test\.|\.test\.|(^|/)test_[^/]*$|\.bats$")
GATE_CMD = re.compile(r"test/run\.sh|ci-local|swarm-suite|\brtdd\s+(run|which)\b|\bpytest\b|\bgo test\b"
                      r"|\bbats\b|\bnpm (run )?test\b|\bvitest\b|\bcargo test\b|(^|[\s/])test_[\w.-]*\.(sh|py)\b"
                      r"|_test\.(sh|py|go)\b")
SHIP_CMD = re.compile(r"\b(gh pr|git push|gh issue (close|edit|comment))\b")


def _versioned(fam, m):
    """The PRICE key of `fam`'s row for the version in model id `m` (see the comment above PRICE)."""
    rows = _VERSIONS[fam]
    v = _VER.search(m)
    if not v:
        return rows[-1][2]
    ver = (int(v.group(1)), int(v.group(2) or 0))
    return next((k for mj, mn, k in reversed(rows) if (mj, mn) <= ver), rows[0][2])


def price(model):
    m = (model or "").lower()
    fam = next((k for k in ("opus", "sonnet", "haiku", "fable") if k in m), None)
    if fam is None:
        return max(PRICE.values(), key=lambda r: (r[1], r[0]))
    if fam == "haiku":
        h = _HAIKU_OLD.search(m)
        return PRICE[_versioned("haiku", m)] if not h else PRICE["haiku-3-5" if h.group(1) else "haiku-3"]
    if fam == "opus" and _OPUS_DEAR.search(m):
        return PRICE["opus-4"]
    if fam != "fable":
        g = _GEN.search(m)
        if g and int(g.group(1) or g.group(2)) < FIRST_CURRENT_GEN:
            return PRICE[fam + "-legacy"]
    return PRICE[_versioned(fam, m)]


def is_fallback_priced(model):
    """True when `price` has no row for this model — no Claude family in its name (codex, agy, opencode
    lanes: "gpt-5-codex"), or none at all — so it takes the dearest row. The budget gate keeps that
    conservative price (#723); a spend report (`harness stats`) marks the figure as an estimate (#750)."""
    m = (model or "").lower()
    return not any(k in m for k in ("opus", "sonnet", "haiku", "fable"))


def raw_cost(u, model):
    """$ for one message's raw Claude usage block (cache writes split 5m / 1h when it says so)."""
    row = price(model)
    cc = u.get("cache_creation") or {}
    w1 = int(cc.get("ephemeral_1h_input_tokens") or 0)
    w5 = cc.get("ephemeral_5m_input_tokens")
    w5 = int(u.get("cache_creation_input_tokens") or 0) - w1 if w5 is None else int(w5)
    if row == PRICE["haiku"]:   # Haiku 5.5: a prompt over 100K tokens (input + cache read + cache write) costs more (#843)
        prompt = int(u.get("input_tokens") or 0) + int(u.get("cache_read_input_tokens") or 0) + w5 + w1
        if prompt > HAIKU_LONG_PROMPT:
            row = PRICE["haiku-long"]
    pi, po, pw5, pw1, pr = row
    return (int(u.get("input_tokens") or 0) * pi + int(u.get("output_tokens") or 0) * po + w5 * pw5
            + w1 * pw1 + int(u.get("cache_read_input_tokens") or 0) * pr) / 1e6


def usage_cost(usage):
    """$ for a folded {model: {input, output, cache_create, cache_read[, cache_create_1h]}} (stats.py /
    usage_tsv). `cache_create_1h` (#710) is the 1-hour share of `cache_create`, priced at the 1h write rate;
    the rest of `cache_create` is priced at the 5m rate. A usage without it (an event logged before #710,
    another CLI's) is priced as all 5m: the documented default, the lower list rate."""
    return usage_cost_split(usage)[0]


def usage_cost_split(usage):
    """(total $, the part of it priced by fallback, [models priced by fallback]) for a folded usage. The
    total is `usage_cost`; the rest says how much of it is the dearest-row estimate for a model the table
    has no row for (#750), so a report can mark it rather than present it as real spend."""
    tot = est = 0.0
    unpriced = []
    for model, u in (usage or {}).items():
        pi, po, pw5, pw1, pr = price(model)
        cc = int(u.get("cache_create") or 0)
        w1 = min(max(int(u.get("cache_create_1h") or 0), 0), cc)
        c = (int(u.get("input") or 0) * pi + int(u.get("output") or 0) * po
             + (cc - w1) * pw5 + w1 * pw1 + int(u.get("cache_read") or 0) * pr) / 1e6
        tot += c
        if is_fallback_priced(model):
            est += c
            unpriced.append(model or "(no model)")
    return tot, est, unpriced


# --- phase attribution -------------------------------------------------------
def phase_of(block, cur, edited):
    name, inp = block.get("name", ""), block.get("input") or {}
    if name in EDIT_TOOLS:
        return "test" if TEST_PATH.search(str(inp.get("file_path") or inp.get("notebook_path") or "")) else "impl"
    if name == "Bash":
        cmd = str(inp.get("command") or "")
        if SHIP_CMD.search(cmd):
            return "ship"
        if GATE_CMD.search(cmd):
            return "gate"
    return cur if edited else "explore"


def _messages(path):
    """[(key, model, usage, tool_use blocks, timestamp)] in first-seen order. A streamed message is
    written once per content block under one id: its blocks are gathered and its (last) usage taken
    once; its timestamp is its first line's."""
    order, by = [], {}
    try:
        fh = open(path, errors="replace")
    except OSError:
        return []
    with fh:
        for line in fh:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if not isinstance(r, dict) or r.get("type") != "assistant":
                continue
            m = r.get("message") or {}
            if not m.get("usage") or not m.get("model") or m.get("model") == "<synthetic>":
                continue
            key = m.get("id") or r.get("requestId") or r.get("uuid") or f"{path}:{len(order)}"
            if key not in by:
                by[key] = [key, m["model"], None, [], r.get("timestamp")]
                order.append(key)
            by[key][2] = m["usage"]
            content = m.get("content")
            by[key][3] += [b for b in content if isinstance(b, dict) and b.get("type") == "tool_use"] \
                if isinstance(content, list) else []
    return [tuple(by[k]) for k in order]


def transcript_phases(files):
    """{phase: $} over a lane's transcript files (main + sub-agents), each message once across all of
    them. Every file starts in explore: a sub-agent explores before it edits, too."""
    out, seen = {p: 0.0 for p in PHASES}, set()
    for f in files:
        cur, edited = "explore", False
        for key, model, usage, tools, _ in _messages(f):
            for b in tools:
                cur = phase_of(b, cur, edited)
                edited = edited or cur in ("test", "impl")
            if key in seen:
                continue
            seen.add(key)
            out[cur] += raw_cost(usage, model)
    return out


# --- lanes -------------------------------------------------------------------
def lanes(events, find=None):
    """One lane per (repo, issue) over its impl / bug-fix sessions: {repo, issue, unit, prd, sessions,
    phases {phase: $} or None (no transcript for any session), total $}."""
    find = find or st.find_transcript
    by = {}
    for s in st.sessions(events):
        if s.get("kind") not in LANE_KINDS or s.get("issue") is None:
            continue
        key = ((s.get("repo") or "").lower(), s["issue"])
        ln = by.setdefault(key, {"repo": s.get("repo"), "issue": s["issue"], "unit": s.get("unit"),
                                 "prd": s.get("prd"), "sessions": 0, "phases": None, "unattributed": 0.0,
                                 "accounts": set()})
        ln["sessions"] += 1
        for k in ("repo", "unit", "prd"):
            ln[k] = ln[k] if ln[k] is not None else s.get(k)
        tr = find(s["session"])
        if tr:
            ln["accounts"].add(transcript_account(tr))
            ph = transcript_phases(st.transcript_files(tr))
            ln["phases"] = {p: (ln["phases"] or {}).get(p, 0.0) + ph[p] for p in PHASES}
        else:
            ln["unattributed"] += usage_cost(s.get("usage"))
    for ln in by.values():
        ln["total"] = sum((ln["phases"] or {}).values()) + ln["unattributed"]
    return list(by.values())


def spread(pool):
    """Each lane's {phase: $}: its attributed phases plus its unattributed $ (no transcript) spread by
    the pool's mean phase mix — evenly when no lane in the pool has a transcript."""
    mix = {p: 0.0 for p in PHASES}
    attributed = [ln for ln in pool if ln["phases"] and sum(ln["phases"].values()) > 0]
    for ln in attributed:
        t = sum(ln["phases"].values())
        for p in PHASES:
            mix[p] += ln["phases"][p] / t / len(attributed)
    if not attributed:
        mix = {p: 1 / len(PHASES) for p in PHASES}
    return [{p: (ln["phases"] or {}).get(p, 0.0) + ln["unattributed"] * mix[p] for p in PHASES} for ln in pool]


def quantile(vals, q):
    """Nearest-rank: the value at index floor(q·n) of the sorted list, capped at the last."""
    v = sorted(vals)
    return v[min(len(v) - 1, int(q * len(v)))] if v else 0.0


def median_len(lens):
    v = sorted(x for x in lens if x)
    if not v:
        return None
    n = len(v)
    return v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2


def body_len_of(text):
    """An issue body's size in characters, CRLF and lone CR counted as one line break (#838)."""
    return len(text.replace("\r\n", "\n").replace("\r", "\n"))


def size_scale(body_len, pool_lens):
    """(scale, median): body length over the pool's median body, clamped; 1.0 when either is unknown."""
    med = median_len(pool_lens)
    if not body_len or not med:
        return 1.0, med
    return max(SCALE_CLAMP[0], min(SCALE_CLAMP[1], body_len / med)), med


def choose_pool(all_lanes, repo, issue, prd):
    """(tier, pool, notes): the narrowest pool with MIN_LANES lanes — the issue's PRD siblings, then its
    unit (repo), then the host. The issue's own lanes are never in its pool. notes say why each
    narrower tier was passed over."""
    rl = (repo or "").lower()
    others = [ln for ln in all_lanes if ln["total"] >= MIN_LANE_USD
              and not ((ln["repo"] or "").lower() == rl and ln["issue"] == issue)]
    unit = [ln for ln in others if rl and (ln["repo"] or "").lower() == rl]
    notes = []
    if prd is not None:
        sib = [ln for ln in unit if ln["prd"] == prd]
        if len(sib) >= MIN_LANES:
            return "prd", sib, notes
        notes.append(f"PRD #{prd} has {len(sib)} past lane(s), need {MIN_LANES}")
    else:
        notes.append(f"#{issue} names no parent PRD")
    if len(unit) >= MIN_LANES:
        return "unit", unit, notes
    notes.append(f"unit {repo or '?'} has {len(unit)} past lane(s), need {MIN_LANES}")
    if others:
        return "host", others, notes
    return "none", [], notes


# --- usage calibration (#364) --------------------------------------------------
def norm_account(a):
    """usage-statusline.sh names an account after its config dir, "default" when none is set."""
    a = str(a or "")
    return "default" if a in ("", ".claude") else a


def transcript_account(path):
    """The account of a claude transcript (<config dir>/projects/<slug>/<session>.jsonl)."""
    return norm_account(os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(path)))))


def readings(events):
    """{(account, window): [(t, pct, resets_at)]} from the usage_reading events, in time order; a
    reading that repeats the one before it (same pct and resets_at — several fleets poll one
    account) is folded into its first sighting."""
    by = {}
    for e in events:
        if e.get("event") != "usage_reading" or not e.get("window"):
            continue
        t = st.parse_ts(e.get("ts"))
        try:
            pct, reset = float(e.get("pct")), int(e.get("resets_at") or 0)
        except (TypeError, ValueError):
            continue
        if t is not None:
            by.setdefault((norm_account(e.get("account")), str(e["window"])), []).append((t, pct, reset))
    out = {}
    for k, rs in by.items():
        out[k] = []
        for r in sorted(rs):
            if not out[k] or out[k][-1][1:] != r[1:]:
                out[k].append(r)
    return out


def account_spend(events, start, end, find=None):
    """{account: sorted [(t, $)]}: every message of every session's transcripts (main + sub-agents,
    each message once) — for the sessions that can overlap [start, end]. A session with no claude
    transcript has no account and no timeline, so it is left out."""
    find = find or st.find_transcript
    out = {}
    for s in st.sessions(events):
        launched, ended = st.parse_ts(s.get("launched")), st.parse_ts(s.get("ended"))
        if (launched is not None and launched > end) or (ended is not None and ended < start):
            continue
        tr = find(s["session"])
        if not tr:
            continue
        acc, seen = out.setdefault(transcript_account(tr), []), set()
        for f in st.transcript_files(tr):
            for key, model, usage, _, ts in _messages(f):
                t = st.parse_ts(ts)
                if key in seen or t is None:
                    continue
                seen.add(key)
                acc.append((t, raw_cost(usage, model)))
    for v in out.values():
        v.sort()
    return out


def _spent_between(timeline, t0, t1):
    """$ of the messages in (t0, t1]."""
    ts = [t for t, _ in timeline]
    return sum(c for _, c in timeline[bisect.bisect_right(ts, t0):bisect.bisect_right(ts, t1)])


def calibrate(events, accounts=(), find=None):
    """[{account, window, pairs, skipped_reset, central, bound}], one per account/window with readings
    (central / bound $ per 1%, None without a usable pair), plus {account, window: None, pairs: 0}
    for each of `accounts` (the lanes' accounts) that has no reading at all."""
    rd = readings(events)
    times = [r[0] for rs in rd.values() for r in rs]
    spend = account_spend(events, min(times), max(times), find) if times else {}
    out = []
    for (acct, win), rs in sorted(rd.items()):
        ratios, usd_sum, pct_sum, skipped = [], 0.0, 0.0, 0
        for a, b in zip(rs, rs[1:]):
            if abs(b[2] - a[2]) > RESET_SLACK or b[1] < a[1]:
                skipped += 1   # the window reset between the two: no pair
                continue
            usd, d = _spent_between(spend.get(acct, []), a[0], b[0]), b[1] - a[1]
            if d <= 0 or usd <= 0:
                continue       # no % moved, or none of the event log's sessions spent: nothing to fit
            ratios.append(usd / d)
            usd_sum, pct_sum = usd_sum + usd, pct_sum + d
        central = usd_sum / pct_sum if ratios else None
        bound = min(central, quantile(ratios, BOUND_Q)) if ratios else None
        out.append({"account": acct, "window": win, "pairs": len(ratios), "skipped_reset": skipped,
                    "central": None if central is None else round(central, 2),
                    "bound": None if bound is None else round(bound, 2)})
    have = {c["account"] for c in out}
    out += [{"account": a, "window": None, "pairs": 0, "skipped_reset": 0, "central": None, "bound": None}
            for a in sorted({norm_account(a) for a in accounts} - have)]
    return out


def window_pct(cal, phases, total, fallback):
    """The forecast as % of each window: [{...calibration, source, usd_per_pct, phases, total}] —
    source "fit" (the bound), "fallback" (HARNESS_ONE_USD_PER_PCT) or "none" (n/a). With no
    calibration at all, one account-less entry for the fallback."""
    rows = cal or ([{"account": None, "window": None, "pairs": 0, "skipped_reset": 0, "central": None,
                     "bound": None}] if fallback else [])
    out = []
    for c in rows:
        usd, src = (c["bound"], "fit") if c["bound"] else (fallback, "fallback") if fallback else (None, "none")
        pct = (lambda r: {q: round(v / usd, 2) for q, v in r.items()}) if usd else (lambda r: None)
        out.append(dict(c, source=src, usd_per_pct=usd, phases={p: pct(phases[p]) for p in PHASES},
                        total=pct(total)))
    return out


def forecast(events, repo, issue, body=None, bodies=None, unit=None, find=None, fallback=None, invalid=None):
    """The forecast dict for `issue` of `repo`. body: the issue's body text (None = unknown); bodies:
    {issue number: body} for `repo`, used for the pool's median body length and the issue's PRD;
    fallback: the operator's $ per 1% (HARNESS_ONE_USD_PER_PCT) for a window with no calibration;
    invalid: that setting's text when it is set but unusable (#746), named in the render."""
    bodies = bodies or {}
    all_lanes = lanes(events, find)
    rl = (repo or "").lower()
    own = [ln for ln in all_lanes if (ln["repo"] or "").lower() == rl and ln["issue"] == issue]
    prd = next((ln["prd"] for ln in own if ln["prd"] is not None), None)
    if prd is None and body:
        p = _load("issuelib").parse_parent(body, repo or "")
        if p and (not repo or p[0].lower() == rl):
            prd = p[1]
    unit = unit or next((ln["unit"] for ln in own if ln["unit"]), None) \
        or next((ln["unit"] for ln in all_lanes if (ln["repo"] or "").lower() == rl and ln["unit"]), None)
    tier, pool, notes = choose_pool(all_lanes, repo, issue, prd)
    if not own:
        notes.insert(0, f"#{issue} has no history")
    pool_lens = [body_len_of(bodies[ln["issue"]]) for ln in pool
                 if ln["issue"] in bodies and (ln["repo"] or "").lower() == rl]
    if not pool_lens:   # a host-wide pool, or no body known for its issues: the repo's issues at large
        pool_lens = [body_len_of(b) for n, b in bodies.items() if n != issue]
    body_len = body_len_of(body) if body is not None else None
    scale, med = size_scale(body_len, pool_lens)
    per = spread(pool)
    phases = {p: {q: round(quantile([x[p] for x in per], v) * scale, 2) for q, v in QUANTILES} for p in PHASES}
    totals = [ln["total"] for ln in pool]
    total = {q: round(quantile(totals, v) * scale, 2) for q, v in QUANTILES}
    cal = calibrate(events, set().union(*(ln["accounts"] for ln in all_lanes)), find)
    windows = window_pct(cal, phases, total, fallback)
    return {
        "issue": issue, "repo": repo, "unit": unit, "prd": prd,
        "basis": {"tier": tier, "lanes": len(pool), "fallback": tier != "prd", "notes": notes,
                  "no_transcript": sum(1 for ln in pool if not ln["phases"])},
        "size": {"body": body_len, "median_body": med, "scale": round(scale, 2), "clamp": list(SCALE_CLAMP)},
        "phases": phases, "total": total,
        # % of each usage window (#364); None when no window has a $-per-% (no fit, no fallback)
        "pct": [{k: w[k] for k in ("account", "window", "source", "usd_per_pct", "phases", "total")}
                for w in windows] if any(w["usd_per_pct"] for w in windows) else None,
        "calibration": {"windows": [{k: v for k, v in w.items() if k not in ("phases", "total")} for w in windows],
                        "fallback": fallback, "setting": FALLBACK_SETTING, "invalid": invalid, "bound_q": BOUND_Q},
        "spent": {"sessions": sum(ln["sessions"] for ln in own), "usd": round(sum(ln["total"] for ln in own), 2)},
    }


def render(f):
    tier = {"prd": f"PRD #{f['prd']} siblings", "unit": f"unit {f['unit'] or f['repo']}",
            "host": "host-wide", "none": "none"}[f["basis"]["tier"]]
    b = f["basis"]
    out = [f"forecast #{f['issue']} {f['repo'] or '?'}" + (f" (unit {f['unit']})" if f["unit"] else "")]
    line = f"  basis: {tier} — {b['lanes']} past lane(s)"
    if b["no_transcript"]:
        line += f", {b['no_transcript']} without a transcript (spread by the phase mix)"
    out.append(line)
    if b["fallback"]:
        out.append(f"  FALLBACK to {tier}: " + "; ".join(b["notes"]))
    s = f["size"]
    if s["body"] is None or s["median_body"] is None:
        out.append(f"  size: scale x{s['scale']:.2f} (body length unknown)")
    else:
        out.append(f"  size: body {s['body']} chars vs median {s['median_body']:.0f} → scale x{s['scale']:.2f} "
                   f"(clamped {s['clamp'][0]}–{s['clamp'][1]})")
    na = "   n/a" if f["pct"] is None else ""
    out.append(f"  {'phase':8} {'p50 $':>8} {'p80 $':>8} {'p95 $':>8}" + ("   % of window" if na else ""))
    for p in PHASES:
        r = f["phases"][p]
        out.append(f"  {p:8} {r['p50']:8.2f} {r['p80']:8.2f} {r['p95']:8.2f}" + na)
    t = f["total"]
    out.append(f"  {'TOTAL':8} {t['p50']:8.2f} {t['p80']:8.2f} {t['p95']:8.2f}" + na)
    out += render_pct(f)
    if f["spent"]["sessions"]:
        out.append(f"  already spent on #{f['issue']}: ${f['spent']['usd']:.2f} over {f['spent']['sessions']} session(s)")
    return "\n".join(st.vis(x) for x in out)   # #833: a unit / account name never splits a line


def _window_name(w):
    return st.vis(" ".join(x for x in (w["account"], w["window"]) if x) or "any account")


def _setting_state(cal):
    """`HARNESS_ONE_USD_PER_PCT unset`, or `HARNESS_ONE_USD_PER_PCT=inf invalid (...)` for a set but unusable value (#746)."""
    if cal.get("invalid") is None:
        return f"{cal['setting']} unset"
    return f"{cal['setting']}={clip_setting(cal['invalid'])} invalid (need a finite number >= {MIN_USD_PER_PCT:g})"


def render_pct(f):
    """The % of each window table (p50/p80/p95 per phase and in total), then one line per window
    naming the fit it used or the fallback."""
    cal, out = f["calibration"], []
    if f["pct"]:
        cols = [(_window_name(w), w) for w in f["pct"]]
        cell = lambda r: "n/a" if r is None else f"{r['p50']:.2f}/{r['p80']:.2f}/{r['p95']:.2f}"
        width = [max(len(n), *(len(cell(w["phases"][p])) for p in PHASES), len(cell(w["total"]))) for n, w in cols]
        out.append("  % of window, p50/p80/p95 at the conservative $-per-1% bound:")
        out.append(f"  {'phase':8} " + "  ".join(f"{n:>{wd}}" for (n, _), wd in zip(cols, width)))
        for p in PHASES:
            out.append(f"  {p:8} " + "  ".join(f"{cell(w['phases'][p]):>{wd}}" for (_, w), wd in zip(cols, width)))
        out.append(f"  {'TOTAL':8} " + "  ".join(f"{cell(w['total']):>{wd}}" for (_, w), wd in zip(cols, width)))
    for w in cal["windows"]:
        name = _window_name(w)
        skipped = f" ({w['skipped_reset']} pair(s) skipped: window reset)" if w["skipped_reset"] else ""
        why = "no usable reading pair" if w["window"] else "no usage readings"
        if w["source"] == "fit":
            out.append(f"  calibration {name}: {w['pairs']} pair(s), fit ${w['central']:.2f}/1%, "
                       f"bound ${w['bound']:.2f}/1%{skipped}")
        elif w["source"] == "fallback":
            out.append(f"  calibration {name}: {why}{skipped} — FALLBACK {cal['setting']}=${w['usd_per_pct']:.2f}/1%")
        else:
            out.append(f"  calibration {name}: {why}{skipped} and {_setting_state(cal)} — n/a")
    if not f["pct"]:
        out.append(f"  % of each usage window: n/a until a $-per-% calibration exists or {cal['setting']} is set"
                   if cal.get("invalid") is None else
                   f"  % of each usage window: n/a until a $-per-% calibration exists or {_setting_state(cal)}")
    return out


def config_value(state_dir, name):
    """A `NAME=value`, `export NAME=value` or `: "${NAME:=value}"` setting from the project's .harness/config
    (quoted or not; the last assignment wins, as when bash sources it), or None (#877). Same reader as
    stats.read_config (#466, #859)."""
    return st.read_config(state_dir, (re.escape(name),)).get(name)


USD_PER_PCT_RE = re.compile(r"(?:[0-9]+\.?[0-9]*|\.[0-9]+)")   # ASCII digits, an optional single dot (#834)
MIN_USD_PER_PCT = 0.01   # $ per 1% of a window: 100% of a window is then $1, below any real plan (#746)


def usd_per_pct_raw(state_dir):
    """The HARNESS_ONE_USD_PER_PCT text as set (environment, else the project config); None when unset or empty."""
    return os.environ.get(FALLBACK_SETTING) or config_value(state_dir, FALLBACK_SETTING) or None


def usd_per_pct_parse(raw):
    """(value, None) for a usable $ per 1%: a finite number of at least MIN_USD_PER_PCT; else (None, why)
    (#746). inf, nan, 0, a negative, a tiny value (1e-300) and non-numeric text are all "not usable".
    Only an ASCII decimal number counts: not 1_0, +5 or full-width digits, which float() takes (#834)."""
    if not isinstance(raw, str) or not USD_PER_PCT_RE.fullmatch(raw):
        return None, "not a number"
    try:
        v = float(raw)
    except ValueError:
        return None, "not a number"
    if not math.isfinite(v):
        return None, "not finite"
    if v < MIN_USD_PER_PCT:
        return None, f"below the minimum {MIN_USD_PER_PCT:g}"
    return v, None


def usd_per_pct_setting(state_dir):
    """HARNESS_ONE_USD_PER_PCT from the environment, else the project config; None unless a finite number of
    at least MIN_USD_PER_PCT. A set but unusable value is named by usd_per_pct_invalid."""
    raw = usd_per_pct_raw(state_dir)
    return usd_per_pct_parse(raw)[0] if raw is not None else None


def clip_setting(v, keep=20):
    """A setting's text for a message: a long value is cut to `keep` characters and an ellipsis, as an oversized
    argument is (#880), so one line never carries a multi-KB environment or config value back (#893)."""
    return v if len(v) <= keep else v[:keep] + "\u2026"


def usd_per_pct_invalid(state_dir):
    """The setting's text when it is set but not usable (#746), else None (unset, or fine)."""
    raw = usd_per_pct_raw(state_dir)
    return raw if raw is not None and usd_per_pct_parse(raw)[0] is None else None


# --- project / GitHub --------------------------------------------------------
def project_units(state_dir):
    """[(unit, repo)] of the project at state_dir: its one HARNESS_UNIT (`main` by default) on HARNESS_REPO."""
    if not state_dir:
        return []
    # The config file only, never the environment: a lane session exports its own HARNESS_REPO (#186).
    cfg = st.read_config(state_dir)
    owner = cfg.get("HARNESS_OWNER")
    own = lambda r: r if "/" in r or not owner else f"{owner}/{r}"
    # One repo (#466): HARNESS_UNIT names the unit; without one it is `main`.
    return [(cfg.get("HARNESS_UNIT") or "main", own(cfg["HARNESS_REPO"]))] if cfg.get("HARNESS_REPO") else []


def resolve_repo(issue, repo, unit, events, state_dir):
    """(repo, unit) or raise ValueError: -R wins; else the issue's own lanes; else the project's unit."""
    units = project_units(state_dir)
    if unit and not repo:
        repo = next((r for u, r in units if u == unit), None)
        if not repo:
            raise ValueError(f"no unit {st.vrepr(unit)} in this project")
    if not repo:
        mine = {s.get("repo") for s in st.sessions(events)
                if s.get("issue") == issue and s.get("kind") in LANE_KINDS and s.get("repo")}
        if len(mine) == 1:
            repo = mine.pop()
        elif len(units) == 1:
            repo, unit = units[0][1], unit or units[0][0]
        else:
            raise ValueError(f"cannot tell which repo #{issue} is in — pass -R owner/repo or --unit")
    unit = unit or next((u for u, r in units if r.lower() == repo.lower()), None)
    return repo, unit


def gh_bodies(repo, issue):
    """(body of `issue` or None, {number: body} of the repo's issues) from gh; ({} / None) on failure."""
    def gh(args):
        try:
            return subprocess.run(portable.resolve_argv(["gh"] + args), capture_output=True, text=True, timeout=60).stdout
        except Exception:
            return ""
    bodies = {}
    try:
        for it in json.loads(gh(["issue", "list", "-R", repo, "--state", "all", "--limit", "1000",
                                 "--json", "number,body"]) or "[]"):
            bodies[it["number"]] = it.get("body") or ""
    except (ValueError, KeyError, TypeError):
        pass
    body = bodies.get(issue)
    if body is None:
        try:
            body = json.loads(gh(["issue", "view", str(issue), "-R", repo, "--json", "body"]) or "{}").get("body")
        except ValueError:
            body = None
    return body, bodies


def unit_arg(v):
    """argparse type for --unit: a name that does not start with `-` (a usage error, exit 2, with or without -R)."""
    import argparse
    if not v or v.startswith("-"):   # #862: an empty --unit is no unit name, not "no --unit"
        raise argparse.ArgumentTypeError(f"{st.vrepr(v)} is not a unit name — it must be non-empty and not start with '-'")
    return v


def issue_arg(v):
    """argparse type for the issue positional: an integer of 1 or greater (a usage error, exit 2, below that)."""
    import argparse
    n = st.int_arg(v)   # ASCII digits only (#784)
    if n < 1:
        raise argparse.ArgumentTypeError(f"issue number must be 1 or greater, got {n}")
    return n


class _HugeInt:
    """Stands in for a JSON integer past int()'s digit limit, so reading the file never reaches int()'s own message (#895)."""
    def __init__(self, text):
        self.text = text


def _json_int(text):
    try:
        return int(text)
    except ValueError:   # more than sys.get_int_max_str_digits() digits
        return _HugeInt(text)


def read_bodies(path):
    """{issue number: body} from a `gh issue list --json number,body` file (#754). A leading UTF-8 BOM is
    dropped; a file that cannot be read or is not that shape is a ValueError naming it, never a traceback."""
    try:
        with open(path, encoding="utf-8-sig") as fh:
            data = json.load(fh, parse_int=_json_int)
    except OSError as e:
        raise ValueError(f"{path}: cannot read it: {e.strerror or e}")
    except UnicodeDecodeError as e:
        raise ValueError(f"{path}: not valid UTF-8: {e.reason} at byte {e.start}")
    except ValueError as e:   # json.JSONDecodeError
        raise ValueError(f"{path}: not valid JSON: {e}")
    if not isinstance(data, list):
        raise ValueError(f"{path}: expected a JSON list of {{number, body}} objects")
    bodies = {}
    for it in data:
        if isinstance(it, dict) and isinstance(it.get("number"), _HugeInt):
            t = it["number"].text
            shown = t if len(t) <= 20 else t[:20] + "\u2026"   # the ellipsis only when the echo was cut
            raise ValueError(f"{path}: \"number\" {shown} is too large \u2014 it must be an issue number")
        if not isinstance(it, dict) or isinstance(it.get("number"), bool) or not isinstance(it.get("number"), int):
            raise ValueError(f"{path}: every item needs an integer \"number\"")
        body = it.get("body") or ""
        if not isinstance(body, str):
            raise ValueError(f"{path}: issue {it['number']}: \"body\" must be a string")
        bodies[it["number"]] = body
    return bodies


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(prog="harness forecast",
                                 description="per-phase p50/p80/p95 cost forecast for one issue (#363)")
    ap.add_argument("issue", type=issue_arg)
    ap.add_argument("-R", "--repo", type=st.repo_arg, help="owner/repo (default: the issue's own lanes, else the project's unit)")
    ap.add_argument("--unit", type=unit_arg, help="unit of the current project (multi-unit projects)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--events", help=argparse.SUPPRESS)
    ap.add_argument("--bodies", type=st.nonempty_arg("--bodies"), help=argparse.SUPPRESS)   # test seam: gh `issue list --json number,body` output
    a = ap.parse_args(sys.argv[1:] if argv is None else argv)
    err = st._explicit_log_error(a.events)   # #785: a typo'd path is not an empty fleet (as `harness stats`, #758)
    if err:
        print(f"harness forecast: --events {err}", file=sys.stderr)
        return 2
    bad = [0]
    events = st.load_events(a.events, bad)
    if bad[0]:   # #785: spend in an unparseable line is missing from the forecast's basis — say so, on stderr
        print(f"harness forecast: skipped {bad[0]} event line(s) that could not be parsed; the forecast excludes them",
              file=sys.stderr)
    try:
        repo, unit = resolve_repo(a.issue, a.repo, a.unit, events, os.environ.get("STATE_DIR"))
    except ValueError as e:
        print(f"harness forecast: {st.vis(str(e))}", file=sys.stderr)
        return 2
    if a.bodies:
        try:
            bodies = read_bodies(a.bodies)
        except ValueError as e:   # #863: the message names --bodies' path, which can hold U+2028 or a form feed
            print(f"harness forecast: {st.vis(str(e))}", file=sys.stderr)
            return 2
        body = bodies.get(a.issue)
    else:
        body, bodies = gh_bodies(repo, a.issue)
    sd = os.environ.get("STATE_DIR")
    bad = usd_per_pct_invalid(sd)
    if bad is not None:
        print(f"harness forecast: {FALLBACK_SETTING}={st.vis(clip_setting(bad))} is invalid "   # #854: no raw U+2028 / form feed on stderr
              f"(need a finite number >= {MIN_USD_PER_PCT:g}): ignored", file=sys.stderr)
    f = forecast(events, repo, a.issue, body, bodies, unit, fallback=usd_per_pct_setting(sd), invalid=bad)
    print(json.dumps(f, indent=2) if a.json else render(f))
    if f["basis"]["tier"] == "none":
        print("harness forecast: no past lanes on this host to forecast from", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(_load("pipesafe").run(main))   # #713: a closed stdout ends the command quietly
