#!/usr/bin/env python3
"""churn.py — the crash-loop guard (#545).

When every session on one issue dies young, the reaper frees the issue and the next dispatch relaunches
it, forever. The data to see it is already in the host event log: every reaper emits a `session_end`
(issue, kind, repo, unit, session, wall_s) before it unlocks the issue. This module reads that log.

    churn.py check    --repo R --issue N --kind K --session S    JSON of the trip (exit 0) or exit 1
    churn.py evidence --repo R --issue N --kind K --sessions a,b the `<!-- harness-churn issue=N -->` comment body
    churn.py replay   [--events F]                               every issue the guard would have tripped on
    churn.py status   --fleet P [--events F]                     one line per churn-parked issue of fleet P
    churn.py rows     --fleet P [--events F]                     the same, as JSON (the web dashboard)

A trip is HARNESS_CHURN_COUNT (3) session_ends on the same repo + issue + kind, each with wall_s below
HARNESS_CHURN_MAX_WALL_S (900), all within HARNESS_CHURN_WINDOW_MIN (180) of the newest. COUNT=0 turns
the guard off. A session the engine ended on purpose (checkpointed, killed by the watchdog, paused) never
counts. After a trip only sessions launched after its `churn` event count, so a park a human lifts
starts the count again from zero.
"""
import json, os, re, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stats  # noqa: E402

DEFAULT_COUNT, DEFAULT_MAX_WALL_S, DEFAULT_WINDOW_MIN = 3, 900, 180
KINDS = ("impl", "bug-triage", "bug-fix")
# An event of one of these names for a session means the engine ended (or was about to end) it itself.
ON_PURPOSE = ("watchdog_kill", "checkpoint", "paused", "usage_checkpoint")
TOOL_CALLS = 5          # last tool calls shown per session
CALL_CHARS, RESULT_CHARS = 200, 300


def _int_env(name, default):
    try:
        return int(os.environ.get(name, "") or default)
    except ValueError:
        return default


def settings():
    return (_int_env("HARNESS_CHURN_COUNT", DEFAULT_COUNT),
            _int_env("HARNESS_CHURN_MAX_WALL_S", DEFAULT_MAX_WALL_S),
            _int_env("HARNESS_CHURN_WINDOW_MIN", DEFAULT_WINDOW_MIN))


def _ts(e):
    return stats.parse_ts(e.get("ts")) or 0


def _same(e, repo, issue, kind=None):
    return (str(e.get("repo", "")).lower() == str(repo).lower() and e.get("issue") == int(issue)
            and (kind is None or e.get("kind") == kind))


def find_churn(events, repo, issue, kind, session=None, count=None, max_wall=None, window_min=None):
    """The session_end events that make a trip for repo#issue/kind, oldest first, or []. <session>, when
    given, must be one of them (the check runs at ITS reap, so older sessions alone never trip it)."""
    d_count, d_wall, d_win = settings()
    count = d_count if count is None else count
    max_wall = d_wall if max_wall is None else max_wall
    window_min = d_win if window_min is None else window_min
    if count <= 0:
        return []
    since = max([_ts(e) for e in events if e.get("event") == "churn" and _same(e, repo, issue, kind)] or [0])
    purposeful = {e.get("session") for e in events if e.get("event") in ON_PURPOSE and e.get("session")}
    ok = []
    for e in events:
        if e.get("event") != "session_end" or not _same(e, repo, issue, kind):
            continue
        wall = e.get("wall_s")
        if not isinstance(wall, int) or isinstance(wall, bool) or wall >= max_wall:
            continue
        if e.get("checkpointed") or e.get("session") in purposeful:
            continue
        if _ts(e) - wall < since:   # launched before the last trip: not counted after the park lifts
            continue
        ok.append(e)
    if not ok:
        return []
    ok.sort(key=_ts)
    anchor = _ts(ok[-1])
    members = [e for e in ok if _ts(e) >= anchor - window_min * 60]
    if len(members) < count:
        return []
    if session is not None and session not in {e.get("session") for e in members}:
        return []
    return members


def replay(events, count=None, max_wall=None, window_min=None):
    """Walk a log in time order, checking at every session_end as the reaper does; a trip adds the
    `churn` event the engine would have written. Returns [(ts, repo, issue, kind, [session ids])]."""
    evs = sorted((e for e in events if isinstance(e, dict)), key=_ts)
    seen, trips = [], []
    for e in evs:
        seen.append(e)
        if e.get("event") != "session_end" or e.get("kind") not in KINDS or not isinstance(e.get("issue"), int):
            continue
        m = find_churn(seen, e.get("repo", ""), e["issue"], e["kind"], e.get("session"), count, max_wall, window_min)
        if m:
            trips.append((e.get("ts"), e.get("repo"), e["issue"], e["kind"], [x.get("session") for x in m]))
            seen.append({"event": "churn", "ts": e.get("ts"), "repo": e.get("repo"), "issue": e["issue"],
                         "kind": e["kind"]})
    return trips


# --- redaction -------------------------------------------------------------------------------------
_TOKENS = re.compile(r"(gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|sk-[A-Za-z0-9_-]{16,}"
                     r"|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+)")
_BEARER = re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}")
_SECRET_ASSIGN = re.compile(r"(?i)\b([A-Za-z0-9_]*(?:token|secret|passw(?:or)?d|api_?key|credential|private_?key)[A-Za-z0-9_]*)"
                            r"(\s*[=:]\s*)(?:\"[^\"]*\"|'[^']*'|\S+)")
_ENV_LINE = re.compile(r"(?m)^([A-Z][A-Z0-9_]{2,})=.*$")


def redact(text):
    """Strip tokens, secret-named assignments and whole `NAME=value` env lines from <text>."""
    text = _TOKENS.sub("[REDACTED]", str(text))
    text = _BEARER.sub(r"\1[REDACTED]", text)
    text = _SECRET_ASSIGN.sub(r"\1\2[REDACTED]", text)
    return _ENV_LINE.sub(r"\1=[REDACTED]", text)


def _clip(text, n):
    text = " ".join(str(text).split())
    return text if len(text) <= n else text[:n - 1] + "…"


# --- transcripts -----------------------------------------------------------------------------------
def _result_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    return ""


def last_calls(path, n=TOOL_CALLS):
    """The last <n> tool calls of a claude-format transcript or a headless lane's stream-json events:
    [(tool name, input summary, result text | None)], oldest first."""
    calls, order = {}, []
    try:
        fh = open(path, encoding="utf-8")
    except OSError:
        return []
    with fh:
        for line in fh:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            msg = r.get("message") if isinstance(r, dict) else None
            content = msg.get("content") if isinstance(msg, dict) else None
            for b in content if isinstance(content, list) else ():
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use" and b.get("id") and b["id"] not in calls:
                    inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                    summ = inp.get("command") or inp.get("file_path") or inp.get("pattern") or json.dumps(inp)
                    calls[b["id"]] = [b.get("name") or "?", str(summ), None]
                    order.append(b["id"])
                elif b.get("type") == "tool_result" and b.get("tool_use_id") in calls:
                    calls[b["tool_use_id"]][2] = _result_text(b.get("content"))
    return [tuple(calls[i]) for i in order[-n:]]


def session_calls(session):
    """(calls, found): the last tool calls of <session> from its claude transcript or headless lane."""
    path = stats.find_transcript(session) if session else None
    path = path or (stats.lane_events(session) if session else None)
    return (last_calls(path), True) if path else ([], False)


def evidence(events, repo, issue, kind, sessions):
    """The `<!-- harness-churn issue=<n> -->` comment body for the counted <sessions> (ids)."""
    ends = [e for e in events if e.get("event") == "session_end" and e.get("session") in set(sessions)
            and _same(e, repo, issue, kind)]
    ends.sort(key=_ts)
    count, max_wall, window = settings()
    out = [f"<!-- harness-churn issue={issue} -->",
           f"## harness: crash-loop guard parked this issue",
           f"{len(ends)} `{kind}` sessions on this issue each ended within {max_wall}s of launch (inside {window} min), "
           f"and a relaunch would restart the same work. The engine stripped `agent-working`, labelled the issue "
           f"`agent-blocked` and parked it: no lane takes it until someone comments on it or edits its labels.",
           "",
           "**Next lane: find out what killed the previous sessions before repeating their steps.** A command that "
           "ends in `Exit code 137` was SIGKILLed from outside; do not re-run the same suite command blindly.",
           "",
           "| ended (UTC) | wall_s | lane | session |", "|---|---|---|---|"]
    for e in ends:
        out.append(f"| {e.get('ts', '?')} | {e.get('wall_s', '?')} | {e.get('unit', '?')} | `{str(e.get('session', '?'))[:8]}` |")
    killed = False
    for e in ends:
        calls, found = session_calls(e.get("session"))
        out += ["", f"### session `{str(e.get('session', '?'))[:8]}` ({e.get('unit', '?')}, {e.get('wall_s', '?')}s)"]
        if not found or not calls:
            out.append("no transcript")
            continue
        for name, summ, res in calls:
            line = f"- `{name}` `{_clip(redact(summ), CALL_CHARS)}` → " + (
                f"`{_clip(redact(res), RESULT_CHARS)}`" if res is not None else "no result")
            out.append(line)
            killed = killed or bool(res and "Exit code 137" in res)
    if killed:
        out += ["", "**SIGKILL (137): the process was killed from outside, not a test failure.**"]
    return "\n".join(out) + "\n"


# --- status ----------------------------------------------------------------------------------------
def parked_rows(events, fleet):
    """The churn trips of <fleet> (a session prefix) not yet followed by a relaunch of the same issue:
    [{"ts", "repo", "issue", "kind", "count", "window_min", "sessions"}], oldest first."""
    rows = {}
    for e in sorted((e for e in events if isinstance(e, dict)), key=_ts):
        if e.get("prefix") != fleet:
            continue
        key = (e.get("repo"), e.get("issue"))
        if e.get("event") == "churn":
            rows[key] = {k: e.get(k) for k in ("ts", "repo", "issue", "kind", "count", "window_min", "sessions")}
        elif e.get("event") == "launch" and key in rows and e.get("kind") == rows[key]["kind"]:
            del rows[key]
    return sorted(rows.values(), key=lambda r: r.get("ts") or "")


def row_line(r):
    return (f"{r['repo']}#{r['issue']} parked by the crash-loop guard ({r['kind']}: {r.get('count')} sessions "
            f"ended young within {r.get('window_min')} min, since {r['ts']}) — comment on it or edit its labels to release it")


# --- cli -------------------------------------------------------------------------------------------
def _args(argv):
    out, i = {}, 0
    while i < len(argv):
        if argv[i].startswith("--") and i + 1 < len(argv):
            out[argv[i][2:]] = argv[i + 1]
            i += 2
        else:
            i += 1
    return out


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if not argv:
        return 2
    cmd, a = argv[0], _args(argv[1:])
    events = stats.load_events(a.get("events"))
    try:
        if cmd == "check":
            m = find_churn(events, a["repo"], a["issue"], a["kind"], a.get("session"))
            if not m:
                return 1
            count, max_wall, window = settings()
            print(json.dumps({"count": len(m), "window_min": window, "max_wall_s": max_wall,
                              "sessions": [e.get("session") for e in m]}))
            return 0
        if cmd == "evidence":
            sys.stdout.write(evidence(events, a["repo"], a["issue"], a["kind"], [s for s in a["sessions"].split(",") if s]))
            return 0
        if cmd == "replay":
            for ts, repo, issue, kind, ids in replay(events):
                print(f"{ts}\t{repo}#{issue}\t{kind}\t{','.join(map(str, ids))}")
            return 0
        if cmd == "status":
            for r in parked_rows(events, a["fleet"]):
                print(row_line(r))
            return 0
        if cmd == "rows":
            print(json.dumps(parked_rows(events, a["fleet"])))
            return 0
    except (KeyError, ValueError):
        return 2
    return 2


if __name__ == "__main__":
    sys.exit(main())
