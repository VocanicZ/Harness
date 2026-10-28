#!/usr/bin/env python3
"""issuelib.py — GitHub-issue state machine for the Harness orchestrator (project-agnostic)."""
import base64, hashlib, json, os, re, subprocess, sys, time

# PRD-B: the snapshot read seam. A host poller writes one raw, versioned snapshot per repo into
# ~/.harness/snapshots/<owner__repo>.json; workers read those instead of polling GitHub directly.
# Bumped whenever the snapshot shape changes; a reader rejecting an unknown version holds dispatch.
SNAPSHOT_SCHEMA_VERSION = 1

# Committed, spec-keyed plan-completion marker. Lives in the unit's repo (NOT in the gitignored
# .harness runtime clone) so it survives a fresh runtime checkout. Records the HARNESS_SPEC path +
# a content hash of that spec; the auto-PLAN gate suppresses replanning while the hash still matches.
PLAN_MARKER_PATH = "docs/harness/plan-complete.json"

OWNER = os.environ.get("HARNESS_OWNER", "")
MODE = lambda: os.environ.get("HARNESS_MODE", "issue-only")
AUTONOMOUS = lambda: os.environ.get("HARNESS_AUTONOMOUS", "true").lower() == "true"
L_READY    = lambda: os.environ.get("HARNESS_LABEL_READY", "ready-for-agent")
L_PRD      = lambda: os.environ.get("HARNESS_LABEL_PRD", "prd")
L_WORKING  = lambda: os.environ.get("HARNESS_LABEL_WORKING", "agent-working")
L_BLOCKED  = lambda: os.environ.get("HARNESS_LABEL_BLOCKED", "agent-blocked")
L_REVIEWED = lambda: os.environ.get("HARNESS_LABEL_REVIEWED", "reviewed")
L_PAUSED   = lambda: os.environ.get("HARNESS_LABEL_PAUSED", "agent-paused")
L_BUG         = lambda: os.environ.get("HARNESS_LABEL_BUG", "bug")
L_BUG_TRIAGED = lambda: os.environ.get("HARNESS_LABEL_BUG_TRIAGED", "bug-triaged")
ALLOWLIST  = lambda: os.environ.get("HARNESS_AUTHOR_ALLOWLIST", "")

_BLOCKED_BY_HEADING = re.compile(r"^#{2,3}\s+Blocked by\s*:?\s*$", re.IGNORECASE | re.MULTILINE)
_NEXT_HEADING = re.compile(r"^#{2,3}\s+", re.MULTILINE)
# Two alternatives so a bare `#N` is captured ONLY when not glued to a preceding word/`.`/`-`/`/`
# (so prose like `fixes#88` / `closes#42` is rejected), while a slug-qualified `owner/repo#N`
# still matches. Each match yields (repo_or_empty, num) via group(1)/group(2) (one branch unset).
_ISSUE_REF = re.compile(
    r"(?:(?<![\w./-])([\w.-]+/[\w.-]+)#(\d+))"   # owner/repo#N
    r"|(?:(?<![\w.-])#(\d+))"                    # bare #N (not glued to a word/`.`/`-`)
)
# A `## Blocked by` section whose first non-blank token is the word `None` declares "no blockers";
# any trailing prose (e.g. "None — #214/#215 already merged …") is explanatory, not a dependency.
_NONE_SECTION = re.compile(r"^\s*None\b", re.IGNORECASE)
# `## Parent` — the child→PRD attribution section, same grammar as `## Blocked by`.
_PARENT_HEADING = re.compile(r"^#{2,3}\s+Parent\s*:?\s*$", re.IGNORECASE | re.MULTILINE)
# Legacy fallback: the bare `Part of #N` trailer decompose.md has always emitted. Kept so children
# filed by earlier engine versions keep their attribution across the upgrade, with no migration.
_PART_OF = re.compile(r"(?<![\w.-])Part of\s+(?:([\w.-]+/[\w.-]+)#(\d+)|#(\d+))", re.IGNORECASE)
# #287: the one-line forms lanes write when filing a follow-up — `## Parent #N` (heading and ref on
# one line) and `Parent: #N` anywhere. Same two-alternative ref groups as `_PART_OF`.
_PARENT_INLINE = re.compile(r"^#{2,3}[ \t]+Parent[ \t]*:?[ \t]*(?:([\w.-]+/[\w.-]+)#(\d+)|#(\d+))",
                            re.IGNORECASE | re.MULTILINE)
_PARENT_COLON = re.compile(r"(?<![\w.-])Parent:[ \t]*(?:([\w.-]+/[\w.-]+)#(\d+)|#(\d+))", re.IGNORECASE)
# #221: a PRD's `## Task 1` section (the harness-arc "write the plan first" task). DECOMPOSE owes it a
# child whose title names Task 1 — `Task 1` exactly, never `Task 10`.
_TASK1_HEADING = re.compile(r"^#{2,3}\s+Task\s+1(?!\d)", re.IGNORECASE | re.MULTILINE)
_TASK1_TITLE = re.compile(r"\bTask\s+1(?!\d)", re.IGNORECASE)
# States that satisfy a blocked-by ref. "merged" covers a ref pointing at a merged PR: `gh issue
# view <pr-number>` resolves the PR and returns {"state":"MERGED"}, so a merged PR must NOT block.
_SATISFIED_STATES = {"closed", "merged"}


class GhError(Exception):
    """A gh read FAILED transiently/ambiguously (non-zero exit, timeout, unparseable output) — as
    opposed to succeeding with a legitimately empty/absent result. Callers must NOT fold this into
    "empty repo / no plan": a shared-token rate limit (HTTP 403) or network blip would otherwise
    re-fire PLAN and (in poller mode) clobber a good snapshot. The CLI catches it and HOLDS the tick
    (prints nothing, exits non-zero) so the worker simply tries again next poll."""


def _looks_transient(stderr):
    """True when a gh failure is a TRANSIENT/shared-token condition (rate limit, 5xx, network) that
    must HOLD rather than be read as 'absent/empty'. We detect transience POSITIVELY: a real gh 403
    rate limit / network error always names itself in stderr, whereas a plain HTTP 404 (resource
    genuinely missing) does not. Anything not positively transient is treated as absent — preserving
    the legacy 'a non-zero contents/issue-view read = not there' contract for the missing-file case
    while still holding on the rate-limit case that drove the spurious-PLAN / snapshot-clobber bug."""
    e = (stderr or "").lower()
    sigs = ("rate limit", "rate-limit", "http 403", "403 forbidden", "http 429", "too many requests",
            "http 500", "http 502", "http 503", "http 504", "bad gateway", "service unavailable",
            "gateway timeout", "timeout", "timed out", "connection", "could not connect",
            "could not resolve host", "network", "tls", "ssl", "eof", "temporarily unavailable",
            "i/o timeout", "server error")
    return any(s in e for s in sigs)


# ── GitHub rate-limit awareness (#183) ──────────────────────────────────────────────────────────
# Every fleet on a host — and every agent session in it — spends ONE token's budget, so a rate limit
# used to mean a HOLD every poll: each retry spent more of the budget the agents needed to finish.
# On a 403/429/rate-limit failure we now read the reset time (`gh api rate_limit`, which does not
# count against the budget) and record a per-token HOLD under $HARNESS_HOME/ghrate; until that reset
# every gh read in this module refuses BEFORE calling gh, and the bash dispatchers sleep until it
# (lib.sh gh_rate_wait). The budget guard (rate-low) reads the same probe, cached so N workers
# probing every poll cost one call per TTL. Engaged only when HARNESS_GH_RATE_GUARD=1 (lib.sh's
# default), so a bare import — tests, one-off tooling — never writes host state.
_RATE_RESOURCES = ("core", "graphql")
_RATE_SIGS = ("rate limit", "rate-limit", "http 429", "too many requests")
_SECONDARY_WAIT = 60   # a secondary limit names no reset; GitHub asks for at least a minute


def _rate_guard():
    return os.environ.get("HARNESS_GH_RATE_GUARD") == "1"


def _rate_dir():
    home = os.environ.get("HARNESS_HOME") or os.path.expanduser("~/.harness")
    return os.environ.get("HARNESS_GH_RATE_DIR") or os.path.join(home, "ghrate")


def _token_key():
    """Which budget this process spends: an env token (by hash, never the token itself), else gh's
    own stored login."""
    tok = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    return "token-" + hashlib.sha256(tok.encode()).hexdigest()[:8] if tok else "gh-auth"


def _rate_file(ext, key=None):
    return os.path.join(_rate_dir(), f"{key or _token_key()}.{ext}")


def _read_json(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as fh:
        json.dump(data, fh)
    os.replace(tmp, path)


def rate_hold_until(key=None):
    """The reset epoch of this token's open rate-limit hold, or None (no hold / it has passed)."""
    if not _rate_guard():
        return None
    d = _read_json(_rate_file("hold", key))
    reset = int(d.get("reset") or 0) if isinstance(d, dict) else 0
    return reset if reset > time.time() else None


def _rate_hold_check():
    held = rate_hold_until()
    if held:
        raise GhError(f"rate limit hold until {held} — gh not called (#183)")


def rate_limits():
    """{resource: {limit, remaining, reset}} for core + graphql, from `gh api rate_limit`, and
    refresh the probe cache. Raises GhError when the probe itself fails."""
    try:
        r = subprocess.run(["gh", "api", "rate_limit"], capture_output=True, text=True, timeout=30)
    except Exception as e:
        raise GhError("gh api rate_limit: %s" % e)
    if r.returncode != 0:
        raise GhError("gh api rate_limit exited %d: %s" % (r.returncode, (r.stderr or "").strip()[:200]))
    try:
        res = json.loads(r.stdout)["resources"]
        out = {k: {f: int(res[k][f]) for f in ("limit", "remaining", "reset")}
               for k in _RATE_RESOURCES if isinstance(res.get(k), dict)}
    except (ValueError, KeyError, TypeError):
        raise GhError("gh api rate_limit: unparseable output")
    if _rate_guard():
        _write_json(_rate_file("rate"), {"checked_at": int(time.time()), "resources": out})
    return out


def _cached_rate_limits(ttl):
    d = _read_json(_rate_file("rate"))
    if isinstance(d, dict) and time.time() - int(d.get("checked_at") or 0) < ttl:
        res = d.get("resources") or {}
        # a probe from before a reset describes a budget that has since refilled: re-read it
        if all(isinstance(v, dict) and int(v.get("reset") or 0) > time.time() for v in res.values()):
            return res
    return rate_limits()


def _record_rate_hold(stderr, header_reset=None):
    """After a failed gh call: when it was a rate limit, hold this token's gh calls until the reset.
    The reset is the response's own X-RateLimit-Reset when the read carried headers and its budget
    was spent, else the exhausted resource's from `gh api rate_limit`; a limit that names itself
    with budget left is a secondary limit (a minute's wait). A plain 403 with budget left is a
    permission error, not a limit, and holds nothing."""
    if not _rate_guard():
        return
    if str(header_reset or "").isdigit() and int(header_reset) > time.time():
        _write_json(_rate_file("hold"), {"reset": int(header_reset), "resource": "header", "since": int(time.time())})
        return
    e = (stderr or "").lower()
    named = any(s in e for s in _RATE_SIGS)
    if not (named or "403" in e):
        return
    reset, resource = 0, ""
    try:
        for k, v in rate_limits().items():
            if v["remaining"] <= 0 and v["reset"] > reset:
                reset, resource = v["reset"], k
    except GhError:
        pass
    if not reset:
        if not named:
            return
        reset, resource = int(time.time()) + _SECONDARY_WAIT, "secondary"
    _write_json(_rate_file("hold"), {"reset": reset, "resource": resource, "since": int(time.time())})


def rate_budget_low(pct, ttl):
    """(resource, remaining, limit, reset) of the first resource under pct% of its budget, else
    None. Fail-open: a probe that fails reads as not low."""
    try:
        res = _cached_rate_limits(ttl)
    except GhError:
        return None
    for k in _RATE_RESOURCES:
        v = res.get(k)
        if isinstance(v, dict) and v.get("limit") and v["remaining"] * 100 < pct * v["limit"]:
            return k, v["remaining"], v["limit"], v["reset"]
    return None


def rate_report():
    """One line per token seen on this host: each resource's remaining/limit and reset, plus HOLD.
    Probes this process's token first, so the current one is never stale."""
    try:
        rate_limits()
    except GhError:
        pass
    d = _rate_dir()
    keys = sorted(f[:-5] for f in (os.listdir(d) if os.path.isdir(d) else []) if f.endswith(".rate"))
    lines = []
    for key in keys:
        c = _read_json(_rate_file("rate", key)) or {}
        res = c.get("resources") or {}
        parts = [f"{k} {res[k]['remaining']}/{res[k]['limit']} resets "
                 + time.strftime("%H:%M", time.localtime(res[k]["reset"]))
                 for k in _RATE_RESOURCES if isinstance(res.get(k), dict)]
        held = rate_hold_until(key)
        hold = f"  HOLD until {time.strftime('%H:%M:%S', time.localtime(held))} (no gh calls)" if held else ""
        lines.append(f"{key}: " + (", ".join(parts) or "no data") + hold)
    return lines


def _gh_json(args, allow_absent=False):
    """Run a gh command and parse JSON stdout. Returns the parsed value on success (which may be a
    legitimately empty [] / {} / null). Raises GhError on a transient/ambiguous failure so the caller
    HOLDS instead of treating a gh outage as 'empty'. When allow_absent is set (e.g. a blocked-by
    ref pointing at a deleted issue), a non-zero exit that is NOT positively transient returns None —
    the resource is genuinely missing, which is not an error — while a transient failure still raises.
    `gh issue list` is always allow_absent=False: an empty repo exits 0, so ANY non-zero is a real
    failure and must never be read as an empty issue set."""
    _rate_hold_check()
    try:
        out = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60)
    except Exception as e:
        raise GhError("gh %s: %s" % (" ".join(args), e))
    if out.returncode != 0:
        _record_rate_hold(out.stderr)
        if allow_absent and not _looks_transient(out.stderr):
            return None
        raise GhError("gh %s exited %d: %s" % (" ".join(args), out.returncode, (out.stderr or "").strip()[:200]))
    try:
        return json.loads(out.stdout or "null")
    except json.JSONDecodeError:
        # gh reported success but the output is not JSON — anomalous; do NOT treat as empty.
        raise GhError("gh %s: unparseable JSON output" % " ".join(args))


def _gh_api_read(path, jq):
    """Read a single field from a repo contents API path via `gh api --jq`. Returns the raw stdout
    string when present, None when the resource is genuinely ABSENT (a non-transient non-zero — e.g.
    HTTP 404, the file isn't committed), and raises GhError only on a POSITIVELY transient failure
    (403 rate limit / 5xx / network) so a shared-token throttle is never mistaken for 'no plan'.
    (The --jq output is a raw scalar, not JSON, so this can't go through _gh_json.)"""
    _rate_hold_check()
    try:
        r = subprocess.run(["gh", "api", path, "--jq", jq], capture_output=True, text=True, timeout=60)
    except Exception as e:
        raise GhError("gh api %s: %s" % (path, e))
    if r.returncode == 0:
        return r.stdout
    _record_rate_hold(r.stderr)
    if _looks_transient(r.stderr):
        raise GhError("gh api %s exited %d: %s" % (path, r.returncode, (r.stderr or "").strip()[:200]))
    return None


def _repo_slug(repo):
    return repo if "/" in repo else (f"{OWNER}/{repo}" if OWNER else repo)


# ── snapshot read seam (PRD-B) ────────────────────────────────────────────────────────────────
# When HARNESS_SNAPSHOT_FILE is set the read path serves issues / plan / dep-state from snapshots
# instead of calling gh. HARNESS_SNAPSHOT_DIR holds the sibling per-repo snapshots used to resolve
# cross-repo deps. With neither set, every read below behaves exactly as before (direct gh).
def _snapshot_mode():
    return bool(os.environ.get("HARNESS_SNAPSHOT_FILE", ""))


def _slug_filename(slug):
    """`owner/repo` → `owner__repo.json`, the on-disk snapshot name under HARNESS_SNAPSHOT_DIR."""
    return slug.replace("/", "__") + ".json"


def _load_snapshot(path):
    """Parse a snapshot file; None if missing/unreadable/garbled (treated as not-snapshotted)."""
    if not path:
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _snapshot_fresh(path, refresh):
    """True iff the snapshot at <path> is present, parses, carries a KNOWN schema_version, and is
    younger than 3× its refresh interval (PRD-B slice 3, #72). The worker freshness gate: a False
    here HOLDS new dispatch — there is no direct-gh fallback. Missing/unreadable/garbled, an
    unknown/newer schema (a reader must not interpret a shape it doesn't know), or an aged
    generated_at all read as not-fresh. 3× tolerates one missed poll cycle before a dead poller
    trips it. refresh<=0 (no registrant cadence known) skips only the staleness clause."""
    snap = _load_snapshot(path)
    if not isinstance(snap, dict):
        return False
    if snap.get("schema_version") != SNAPSHOT_SCHEMA_VERSION:
        return False
    gen = snap.get("generated_at")
    if not isinstance(gen, (int, float)):
        return False
    if refresh > 0 and (time.time() - gen) > 3 * refresh:
        return False
    return True


def _snapshot_for_slug(slug):
    """The snapshot dict whose `slug` == slug, or None. Prefers the primary HARNESS_SNAPSHOT_FILE
    (the repo being dispatched), then the sibling <owner__repo>.json in HARNESS_SNAPSHOT_DIR."""
    primary = _load_snapshot(os.environ.get("HARNESS_SNAPSHOT_FILE", ""))
    if primary and primary.get("slug") == slug:
        return primary
    d = os.environ.get("HARNESS_SNAPSHOT_DIR", "")
    if d:
        sib = _load_snapshot(os.path.join(d, _slug_filename(slug)))
        if sib and sib.get("slug") == slug:
            return sib
    return None


def parse_blocked_by(body, self_repo):
    """Return [(repo_slug, issue_number)] from the `## Blocked by` section. Bare `#N`
    resolves against self_repo. Returns [] when the section is absent, or when its first
    non-blank token is the word `None` (case-insensitive) — trailing explanatory prose under a
    `None` section (e.g. "None — #214/#215 already merged …") is NOT harvested as a dependency."""
    if not body:
        return []
    m = _BLOCKED_BY_HEADING.search(body)
    if not m:
        return []
    rest = body[m.end():]
    nxt = _NEXT_HEADING.search(rest)
    section = rest[:nxt.start()] if nxt else rest
    if _NONE_SECTION.match(section):
        return []
    refs = []
    for m in _ISSUE_REF.finditer(section):
        repo_part, qual_num, bare_num = m.group(1), m.group(2), m.group(3)
        num = qual_num if qual_num is not None else bare_num
        refs.append((repo_part or self_repo, int(num)))
    return refs


def parse_parent(body, self_repo):
    """(repo_slug, number) of the PRD this child belongs to, or None when unparented.

    Primary form is a `## Parent` section holding one ref, parsed exactly like `## Blocked by`
    (bare `#N` resolves against self_repo; `owner/repo#N` is honoured; a `None` section means
    deliberately unparented). When no such section exists, the one-line `## Parent #N` and
    `Parent: #N` forms a lane writes on a follow-up (#287) are honoured, then the bare `Part of #N`
    trailer that decompose.md emits today, so pre-upgrade children keep their attribution.
    A `## Blocked by` ref is never harvested — only the forms above."""
    if not body:
        return None
    m = _PARENT_HEADING.search(body)
    if m:
        rest = body[m.end():]
        nxt = _NEXT_HEADING.search(rest)
        section = rest[:nxt.start()] if nxt else rest
        if _NONE_SECTION.match(section):
            return None
        for r in _ISSUE_REF.finditer(section):
            repo_part, qual_num, bare_num = r.group(1), r.group(2), r.group(3)
            num = qual_num if qual_num is not None else bare_num
            return (repo_part or self_repo, int(num))
        return None
    for rx in (_PARENT_INLINE, _PARENT_COLON, _PART_OF):
        m = rx.search(body)
        if m:
            num = m.group(2) if m.group(2) is not None else m.group(3)
            return (m.group(1) or self_repo, int(num))
    return None


# `gh issue list --limit N` caps the TOTAL rows fetched (gh paginates internally only up to N, in one
# process) and returns issues created-DESCENDING. So a small cap silently drops the OLDEST / lowest-
# numbered issues — exactly where the early-created PRD and any long-lived open child live (#104). Set
# it effectively-unbounded so every issue is fetched in a single process: a mid-pagination network/API
# failure still makes gh exit non-zero, so _gh_json raises GhError and the worker HOLDS the tick —
# #103's hold semantics are preserved for free. The cap is a module constant so the hit-detection
# below can warn if a real repo ever approaches it (and so tests can shrink it).
_ISSUE_LIST_CAP = 100000


def _fetch_issues(slug, extra=None):
    """Raw `gh issue list` payload (number,title,state,labels,body,author,updatedAt) — no normalisation,
    no author filtering. The snapshot command emits exactly this; always hits gh."""
    args = ["issue", "list", "-R", slug, "--state", "all", "--limit", str(_ISSUE_LIST_CAP),
            "--json", "number,title,state,labels,body,author,updatedAt"]
    if extra:
        args += extra
    data = _gh_json(args) or []
    if len(data) >= _ISSUE_LIST_CAP:
        # At/above the cap: gh truncated (or is right at the edge), so the OLDEST issues — PRD /
        # long-lived children — may have silently dropped. Never fold this into "fewer issues"; warn
        # loudly so the cap can be raised before state silently corrupts.
        print(f"[issuelib] WARNING: `gh issue list` for {slug} returned {len(data)} issues at/above "
              f"the {_ISSUE_LIST_CAP}-row cap; OLDEST issues (PRD / long-lived children) may be "
              f"silently truncated — raise _ISSUE_LIST_CAP.", file=sys.stderr)
    return data


def _normalize_issues(data):
    """Add the worker-side derived fields: labels → lowercase set, author login lowercased."""
    for it in data:
        it["_labels"] = {str(l.get("name", "")).lower() for l in it.get("labels", [])}
        it["_author"] = str((it.get("author") or {}).get("login", "")).lower()
    return data


def _list_issues(slug, extra=None):
    if _snapshot_mode():
        snap = _snapshot_for_slug(slug)
        data = list(snap.get("issues") or []) if snap else []
    else:
        data = _fetch_issues(slug, extra)
    return _normalize_issues(data)


_self_login_cache = None
def _self_login():
    """Authenticated GitHub login (`gh api user`), cached once per process. This is the
    bot's own login — NOT HARNESS_OWNER, which may be an org while the bot commits as a user.
    Returns "" when gh is unauthenticated/unavailable (secure: self resolves to nothing)."""
    global _self_login_cache
    if _self_login_cache is None:
        if _snapshot_mode():
            # the poller already resolved + recorded the bot login; skip the gh api user round-trip.
            snap = _load_snapshot(os.environ.get("HARNESS_SNAPSHOT_FILE", "")) or {}
            v = str(snap.get("self_login", "") or "")
        else:
            try:
                out = subprocess.run(["gh", "api", "user", "--jq", ".login"],
                                     capture_output=True, text=True, timeout=60)
                v = out.stdout.strip() if out.returncode == 0 else ""
            except Exception:
                v = ""
        _self_login_cache = v.strip('"').lower()
    return _self_login_cache


def _allowed_authors():
    """Returns (allow_any, allowed_set). Allowed = {authenticated self} ∪ HARNESS_AUTHOR_ALLOWLIST
    (comma-separated, lowercased). Empty allowlist = self-only (secure default). A literal `*`
    = allow-any (community opt-in). Self is always allowed."""
    entries = {e.strip().lower() for e in ALLOWLIST().split(",") if e.strip()}
    if "*" in entries:
        return True, set()
    me = _self_login()
    if me:
        entries.add(me)
    return False, entries


def _author_filter(issues):
    """Drop issues from non-allowed authors. Silently skipped — never claimed, commented, or
    labelled — with a local debug-log line to stderr only (no GitHub-visible signal)."""
    allow_any, allowed = _allowed_authors()
    if allow_any:
        return issues
    kept = []
    for it in issues:
        if it.get("_author", "") in allowed:
            kept.append(it)
        else:
            print(f"[issuelib] skip issue #{it.get('number')} from disallowed author "
                  f"{it.get('_author') or '?'!r} (allowlist: self-only unless HARNESS_AUTHOR_ALLOWLIST set)",
                  file=sys.stderr)
    return kept


def _ext_dep_state(slug, number):
    """A cross-repo dep's state as some snapshot's poller recorded it under `ext_deps` (#182): the
    primary snapshot first, then every sibling in HARNESS_SNAPSHOT_DIR. None when nobody did."""
    key = f"{slug}#{number}"
    paths = [os.environ.get("HARNESS_SNAPSHOT_FILE", "")]
    d = os.environ.get("HARNESS_SNAPSHOT_DIR", "")
    if d and os.path.isdir(d):
        paths += sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith(".json"))
    for path in paths:
        snap = _load_snapshot(path)
        ent = (snap.get("ext_deps") or {}).get(key) if isinstance(snap, dict) else None
        if isinstance(ent, dict) and "state" in ent:
            return str(ent.get("state") or "").lower()
    return None


def _issue_state(slug, number):
    if _snapshot_mode():
        # resolve the dep's state from its repo's snapshot — never a gh call. A repo that is not
        # snapshotted (or a dep absent from the snapshot) is conservatively treated as NOT closed
        # (i.e. still blocking) and logged: erring toward not-dispatching is the safe direction.
        snap = _snapshot_for_slug(slug)
        if snap is None:
            # a repo nobody polls: the poller resolved the ref for us (#182) — still no gh call here.
            ext = _ext_dep_state(slug, number)
            if ext is not None:
                return ext
            print(f"[issuelib] dep {slug}#{number} not snapshotted — treating as not-closed (blocked)",
                  file=sys.stderr)
            return ""
        for it in snap.get("issues") or []:
            if it.get("number") == number:
                return str(it.get("state", "")).lower()
        ext = (snap.get("ext_deps") or {}).get(f"{slug}#{number}")
        if isinstance(ext, dict) and "state" in ext:
            return str(ext.get("state") or "").lower()   # a PR on this repo, resolved by the poller
        print(f"[issuelib] dep {slug}#{number} absent from snapshot — treating as not-closed (blocked)",
              file=sys.stderr)
        return ""
    # allow_absent: a blocked-by ref pointing at a deleted/nonexistent issue (HTTP 404) is not an
    # error — treat it as "" (not closed → still blocking), the safe direction. A transient failure
    # still raises GhError so compute_state holds rather than guessing the dep's state.
    d = _gh_json(["issue", "view", str(number), "-R", slug, "--json", "state"], allow_absent=True) or {}
    return str(d.get("state", "")).lower()


def _issue_labels(slug, number):
    """The issue's labels, lowercased — from the snapshot in snapshot mode, else one gh read. An issue
    the read cannot find has none. A transient failure raises GhError, like _issue_state."""
    if _snapshot_mode():
        snap = _snapshot_for_slug(slug) or {}
        it = next((i for i in snap.get("issues") or [] if i.get("number") == number), None)
    else:
        it = _gh_json(["issue", "view", str(number), "-R", slug, "--json", "labels"], allow_absent=True)
    return {str(l.get("name", "")).lower() for l in (it or {}).get("labels", [])}


def _spec_hash():
    """sha256 hex of the current HARNESS_SPEC file's content; "" when unset/unreadable.
    drive.sh writes the same digest into the marker (via `issuelib.py spec-hash`), so both sides
    of the gate's comparison compute it identically."""
    path = os.environ.get("HARNESS_SPEC", "")
    if not path:
        return ""
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return ""


def _has_plan(slug):
    """PLAN.md committed at repo root?"""
    if _snapshot_mode():
        snap = _snapshot_for_slug(slug)
        return bool(snap.get("has_plan")) if snap else False
    sha = _gh_api_read(f"repos/{slug}/contents/PLAN.md", ".sha")  # None=absent(404); raises on transient
    return sha is not None and sha.strip() != ""


def _plan_marker(slug):
    """The committed plan-completion marker as a dict, or None if absent/unreadable.
    Read via the GitHub contents API (base64) so it reflects the repo, not local run state."""
    if _snapshot_mode():
        snap = _snapshot_for_slug(slug)
        return snap.get("plan_marker") if snap else None
    content = _gh_api_read(f"repos/{slug}/contents/{PLAN_MARKER_PATH}", ".content")  # None=absent; raises on transient
    if content is None or not content.strip():
        return None
    try:
        raw = base64.b64decode("".join(content.split())).decode("utf-8")
        return json.loads(raw)
    except (ValueError, json.JSONDecodeError):
        return None


def _unsatisfied_refs(issue, slug, closed_cache, prd_num=None):
    """Yield each (slug, num) in the issue's `## Blocked by` that is not yet satisfied, lazily — so
    _is_unblocked still stops querying states at the first open ref."""
    for ref_repo, ref_num in parse_blocked_by(issue.get("body"), slug):
        ref_slug = _repo_slug(ref_repo)
        # a child "blocked by" its own PRD is not a real block — the PRD stays open until review.
        # (also absorbs the common "Part of #<prd>" trailer that leaks into the Blocked-by section.)
        if prd_num is not None and ref_slug == _repo_slug(slug) and ref_num == prd_num:
            continue
        key = (ref_slug, ref_num)
        if key not in closed_cache:
            closed_cache[key] = _issue_state(ref_slug, ref_num) in _SATISFIED_STATES
        if not closed_cache[key]:
            yield key


def _is_unblocked(issue, slug, closed_cache, prd_num=None):
    return next(_unsatisfied_refs(issue, slug, closed_cache, prd_num), None) is None


def _open_blockers(issue, slug, closed_cache, prd_num=None):
    """Every unsatisfied `## Blocked by` ref of the issue, in body order (#211 `held by:`)."""
    return list(_unsatisfied_refs(issue, slug, closed_cache, prd_num))


# ── parked issues (#271) ──────────────────────────────────────────────────────────────────────
# An agent-blocked issue used to be re-dispatched on an autonomous fleet the moment its reap freed
# it, so a lane that parked on a blocker nothing had fixed was relaunched into the same blocker, in a
# loop. reap_team (drive.sh) now records each issue it frees while agent-blocked — when, and the
# `updatedAt` it read AFTER its own unlock — and the issue stays held until something changes it (a
# comment, a label edit) or HARNESS_BLOCKED_BACKOFF_MIN passes. Record lines are
# `<slug>\t<n>\t<parked epoch>\t<updatedAt>`; the last line for an issue wins.
def _parked_file():
    return os.environ.get("HARNESS_PARKED_FILE") or os.path.join(os.environ.get("STATE_DIR", ""), "run", "parked")


_parked_cache = {}
def _park_records():
    """{(slug, n): (parked_epoch, updatedAt)} from the park file, re-read only when it changes."""
    path = _parked_file()
    try:
        st = os.stat(path); key = (path, st.st_mtime_ns, st.st_size)
    except OSError:
        return {}
    if key not in _parked_cache:
        recs = {}
        try:
            with open(path) as f:
                for line in f:
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) == 4 and parts[1].isdigit() and parts[2].isdigit():
                        recs[(parts[0], int(parts[1]))] = (int(parts[2]), parts[3])
        except OSError:
            return {}
        _parked_cache.clear(); _parked_cache[key] = recs
    return _parked_cache[key]


def _parked(issue, slug):
    """True while an agent-blocked issue's park record stands: nothing touched the issue since the
    engine parked it, and the time back-off (if any) has not run out. GitHub's updatedAt is ISO-8601
    UTC, so the string order is the time order."""
    rec = _park_records().get((_repo_slug(slug), issue["number"]))
    if rec is None or L_BLOCKED() not in issue["_labels"]:
        return False
    at, upd = rec
    if (issue.get("updatedAt") or "") > upd:
        return False
    backoff = int(os.environ.get("HARNESS_BLOCKED_BACKOFF_MIN", "0") or 0)
    return not (backoff > 0 and time.time() - at >= backoff * 60)


def _blocked_hold(issue, slug):
    """The one agent-blocked dispatch filter, shared by the pool (compute_state), stall diagnostics
    (_claimable) and the bug lane: a non-autonomous fleet never takes agent-blocked work; an
    autonomous one holds it only while it is parked (#271)."""
    if L_BLOCKED() not in issue["_labels"]:
        return False
    return not AUTONOMOUS() or _parked(issue, slug)


def _claimable(issue, slug):
    """Could some lane ever take this (open) issue? The pool claims ready work that is not held
    agent-blocked (exactly as compute_state's claim filter), the PRD pipeline closes PRDs, the bug
    lane takes bugs, and an agent-working issue is already held. Anything else — an operator step
    with no ready label, or a parked issue nothing has changed — waits on a human (#221, #271)."""
    labels = issue["_labels"]
    if L_WORKING() in labels:
        return True
    if L_BUG() in labels or L_BUG_TRIAGED() in labels:
        return not _blocked_hold(issue, slug)
    if L_PRD() in labels or issue.get("title", "").startswith("[AFK] PRD:"):
        return True
    return L_READY() in labels and not _blocked_hold(issue, slug)


def _stuck_refs(blockers, slug, by_num, allowed):
    """The open blockers when EVERY one is an issue no lane can claim, else [] — while any blocker
    can still move, the chain is not stuck yet. Only same-repo refs are judged (another repo's labels
    are not in this listing); a blocker from a disallowed author is never claimed either (#221)."""
    stuck = []
    for ref in blockers:
        it = by_num.get(ref[1]) if ref[0] == slug else None
        if it is None or (it["number"] in allowed and _claimable(it, slug)):
            return []
        stuck.append(ref)
    return stuck


def _allowed(mode):
    """Which orchestration actions this mode permits (entry-stage gating)."""
    return {
        "issue-only": dict(plan=False, prd=False, decompose=False, review=False),
        "prd":        dict(plan=False, prd=False, decompose=True,  review=True),
        "planned":    dict(plan=True,  prd=True,  decompose=True,  review=True),
    }.get(mode, dict(plan=False, prd=False, decompose=False, review=False))

# ── incremental board cache (#182) ────────────────────────────────────────────────────────────
# The poller used to re-download the WHOLE board — bodies, closed issues and all — every poll. Now
# the previous snapshot doubles as the cache: a poll asks REST for only the issues updated since the
# last one, conditional on the stored ETag, and GitHub answers an unchanged board with a 304 — which
# does not count against the rate limit. PLAN.md / the plan marker ride one conditional listing of
# the repo root. A full resync (today's `gh issue list`) still runs when there is no usable previous
# snapshot and every HARNESS_FULL_RESYNC seconds, to pick up deletions and transfers that `since`
# never reports. compute_state reads the result exactly as before: the merged `issues` keep the
# `gh issue list` shape and order.
def FULL_RESYNC(): return int(os.environ.get("HARNESS_FULL_RESYNC", "3600") or 3600)
def DEP_TTL(): return int(os.environ.get("HARNESS_DEP_TTL", "600") or 600)


def _parse_http(text):
    """Split `gh api -i` output into (status, headers, body). status is None when the output carries
    no HTTP status line (gh failed before any response — or a stub that only knows other calls)."""
    text = text or ""
    head, body = text, ""
    for sep in ("\r\n\r\n", "\n\n"):
        if sep in text:
            head, body = text.split(sep, 1)
            break
    lines = head.splitlines()
    m = re.match(r"HTTP/\S+\s+(\d{3})", lines[0]) if lines else None
    if not m:
        return None, {}, text
    headers = {}
    for ln in lines[1:]:
        k, sep, v = ln.partition(":")
        if sep:
            headers[k.strip().lower()] = v.strip()
    return int(m.group(1)), headers, body


def _gh_api_cond(path, etag=None):
    """GET <path> through `gh api -i`, conditional on <etag> (If-None-Match). Returns
    (status, headers, body); a 304 comes back as (304, headers, None) — the free answer. Raises
    GhError on a transient failure (rate limit / 5xx / network), like every other read here. A
    non-transient failure is returned as-is, with status None when gh produced no HTTP response."""
    args = ["api", "-i", path]
    if etag:
        args += ["-H", f"If-None-Match: {etag}"]
    _rate_hold_check()
    try:
        r = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60)
    except Exception as e:
        raise GhError("gh api %s: %s" % (path, e))
    status, headers, body = _parse_http(r.stdout)
    if status == 304:
        return 304, headers, None
    if r.returncode == 0 and status is not None and 200 <= status < 300:
        return status, headers, body
    if status in (403, 429) or r.returncode != 0:
        # #183: this read carries the response headers, so a spent budget names its own reset
        _record_rate_hold(r.stderr if status is None else f"HTTP {status} {r.stderr or ''}",
                          headers.get("x-ratelimit-reset") if headers.get("x-ratelimit-remaining") == "0" else None)
    if (status is not None and (status == 429 or status >= 500 or
                                (status == 403 and "0" == headers.get("x-ratelimit-remaining", "")))) \
            or _looks_transient(r.stderr):
        raise GhError("gh api %s exited %d: %s" % (path, r.returncode, (r.stderr or "").strip()[:200]))
    return status, headers, body


def _link_next(headers):
    """The rel="next" page of a paginated REST response, as a path gh api accepts; None at the end."""
    for part in (headers.get("link") or "").split(","):
        m = re.match(r'\s*<([^>]+)>\s*;\s*rel="next"', part)
        if m:
            return re.sub(r"^https://api\.github\.com/", "", m.group(1))
    return None


def _rest_to_gh_issue(it):
    """A REST /issues item in the exact shape `gh issue list --json …` emits, so a merged cache and
    a full fetch are indistinguishable to compute_state. gh names a bot author `app/<name>` where
    REST says `<name>[bot]`; mirror that so the author allowlist matches the same string."""
    u = it.get("user") or {}
    is_bot = u.get("type") == "Bot"
    login = str(u.get("login") or "")
    if is_bot and login.endswith("[bot]"):
        login = "app/" + login[:-len("[bot]")]
    return {"number": it.get("number"),
            "title": it.get("title") or "",
            "state": str(it.get("state") or "").upper(),
            "labels": [{"id": l.get("node_id", ""), "name": l.get("name", ""),
                        "description": l.get("description") or "", "color": l.get("color", "")}
                       for l in (it.get("labels") or [])],
            "body": it.get("body") or "",
            "author": {"id": u.get("node_id", ""), "is_bot": is_bot, "login": login, "name": ""},
            "updatedAt": it.get("updated_at") or ""}


class _Resync(Exception):
    """The incremental path got a non-transient answer it cannot use — fall back to a full resync."""


def _fetch_issue_delta(slug, since, etag):
    """Issues (not PRs) updated at/after <since>, conditional on <etag>. Returns (delta, etag);
    delta is None when GitHub answered 304 — nothing changed, nothing counted. Pages past the first
    are followed unconditionally; the stored ETag is the first page's, the one the next poll sends."""
    status, h, body = _gh_api_cond(f"repos/{slug}/issues?state=all&per_page=100&since={since}", etag)
    if status == 304:
        return None, etag
    new_etag = h.get("etag")
    items = []
    while True:
        if status != 200:
            raise _Resync(f"issues delta for {slug}: HTTP {status}")
        try:
            items += json.loads(body or "[]")
        except ValueError:
            raise GhError(f"gh api issues delta for {slug}: unparseable JSON")
        nxt = _link_next(h)
        if not nxt:
            break
        status, h, body = _gh_api_cond(nxt)
    return [_rest_to_gh_issue(i) for i in items if "pull_request" not in i], new_etag


def _fetch_root(slug, sync, prev):
    """(has_plan, plan_marker, root_etag, marker_dir_sha) from ONE conditional listing of the repo
    root. 304 → reuse the previous snapshot's values for free. A changed root re-reads the marker
    only when the directory holding it changed. A 404 (empty repo) means no plan and no marker."""
    status, h, body = _gh_api_cond(f"repos/{slug}/contents/", sync.get("root_etag"))
    if status == 304:
        return prev.get("has_plan", False), prev.get("plan_marker"), sync.get("root_etag"), sync.get("marker_dir_sha")
    if status == 404:
        return False, None, None, None
    if status != 200:
        raise _Resync(f"root listing for {slug}: HTTP {status}")
    try:
        entries = json.loads(body or "[]")
    except ValueError:
        raise GhError(f"gh api root listing for {slug}: unparseable JSON")
    entries = entries if isinstance(entries, list) else []
    has_plan = any(e.get("name") == "PLAN.md" and e.get("sha") for e in entries)
    top = PLAN_MARKER_PATH.split("/", 1)[0]
    dir_sha = next((e.get("sha") for e in entries if e.get("name") == top), None)
    if dir_sha is None:
        marker = None
    elif dir_sha == sync.get("marker_dir_sha"):
        marker = prev.get("plan_marker")
    else:
        marker = _plan_marker(slug)
    return has_plan, marker, h.get("etag"), dir_sha


_ISSUE_BRANCH_RE = re.compile(r"refs/heads/issue/(\d+)")


def _fetch_issue_branches(slug, etag=None):
    """(numbers, etag): every issue <n> with a remote `issue/<n>` branch — the same signal spawn_impl
    (drive.sh) keys its resume off, and the branch an open PR for <n> comes from (#210). ONE
    conditional listing of the matching refs; a 304 returns (None, etag) for free. Advisory only (it
    orders dispatch, never gates it), so a non-transient failure — an empty repo's 409, a stub that
    knows no such call — reads as "no branches" rather than a resync; a transient one raises GhError
    like every other read here."""
    status, h, body = _gh_api_cond(f"repos/{slug}/git/matching-refs/heads/issue/", etag)
    if status == 304:
        return None, etag
    new_etag, nums = (h.get("etag") if status == 200 else None), set()
    while status == 200:
        try:
            refs = json.loads(body or "[]")
        except ValueError:
            return [], None
        for r in refs if isinstance(refs, list) else []:
            m = _ISSUE_BRANCH_RE.fullmatch(str(r.get("ref", "")) if isinstance(r, dict) else "")
            if m:
                nums.add(int(m.group(1)))
        nxt = _link_next(h)
        if not nxt:
            break
        status, h, body = _gh_api_cond(nxt)
    return sorted(nums), new_etag


_ISSUE_HEAD_RE = re.compile(r"issue/(\d+)")
# a commit's combined status → the drawer's CI word (#228); GitHub's `error` is a failure too
_CI_STATES = {"success": "success", "failure": "failure", "error": "failure", "pending": "pending"}


def _fetch_pulls(slug, etag=None):
    """(pulls, etag): every open PR whose head is this repo's `issue/<n>` branch, as
    [{"number", "url", "draft", "head_ref", "head_sha", "issue"}] — the harness web drawer's PR
    (#228). ONE conditional listing; a 304 returns (None, etag) for free, and so does any answer it
    cannot use (with no ETag), which the caller reads as "keep what you had"."""
    status, h, body = _gh_api_cond(f"repos/{slug}/pulls?state=open&per_page=100", etag)
    if status == 304:
        return None, etag
    new_etag, out = h.get("etag"), []
    while True:
        if status != 200:
            return None, None
        try:
            items = json.loads(body or "[]")
        except ValueError:
            return None, None
        for p in items if isinstance(items, list) else []:
            head = (p.get("head") if isinstance(p, dict) else None) or {}
            m = _ISSUE_HEAD_RE.fullmatch(str(head.get("ref") or ""))
            repo = (head.get("repo") or {}).get("full_name") if isinstance(head.get("repo"), dict) else None
            if m and isinstance(p.get("number"), int) and repo in (None, slug):
                out.append({"number": p["number"], "url": p.get("html_url") or "", "draft": bool(p.get("draft")),
                            "head_ref": head["ref"], "head_sha": head.get("sha") or "", "issue": int(m.group(1))})
        nxt = _link_next(h)
        if not nxt:
            break
        status, h, body = _gh_api_cond(nxt)
    return sorted(out, key=lambda p: p["number"]), new_etag


def _fetch_checks(slug, sha, etag=None):
    """(state, etag): the combined status of commit <sha> — success / failure / pending, or none when
    nothing reports on it. A 304 returns (None, etag); an unusable answer (None, None)."""
    status, h, body = _gh_api_cond(f"repos/{slug}/commits/{sha}/status", etag)
    if status == 304:
        return None, etag
    if status != 200:
        return None, None
    try:
        d = json.loads(body or "{}")
    except ValueError:
        return None, None
    if not isinstance(d, dict):
        return None, None
    return ("none" if not d.get("total_count") else _CI_STATES.get(d.get("state"), "pending")), h.get("etag")


def _pr_cache(slug, branches, prev):
    """({"pulls", "checks"}, pulls ETag) for the snapshot: the open `issue/<n>` PRs and the combined
    status of each head (`checks: {sha: {"state", "etag"}}`), refreshed conditionally against <prev>.
    Advisory, like issue_branches: a failed read — transient or not — keeps the previous value and
    never fails the snapshot, and a value never read at all is left out ({}), which the drawer shows
    as unknown. No `issue/<n>` branch means no such PR, so there is nothing to ask GitHub."""
    prev = prev or {}
    sync = prev.get("sync") if isinstance(prev.get("sync"), dict) else {}
    had = isinstance(prev.get("pulls"), list)
    if not branches:
        return {"pulls": [], "checks": {}}, None
    try:
        pulls, etag = _fetch_pulls(slug, sync.get("pulls_etag") if had else None)
    except GhError:
        pulls, etag = None, sync.get("pulls_etag")
    if pulls is None:
        if not had:
            return {}, None
        pulls = prev["pulls"]
    old = prev.get("checks") if isinstance(prev.get("checks"), dict) else {}
    checks = {}
    for sha in sorted({p["head_sha"] for p in pulls if isinstance(p, dict) and p.get("head_sha")}):
        was = old.get(sha) if isinstance(old.get(sha), dict) else {}
        try:
            state, cetag = _fetch_checks(slug, sha, was.get("etag"))
        except GhError:
            state = None
        if state is not None:
            checks[sha] = {"state": state, "etag": cetag}
        elif was.get("state"):
            checks[sha] = was
    return {"pulls": pulls, "checks": checks}, etag


def _issue_branches(slug):
    """The set of issue numbers with a remote `issue/<n>` branch: from the snapshot when a worker
    reads one (no gh), else one direct listing. A pre-#210 snapshot without the key reads as none."""
    if _snapshot_mode():
        snap = _snapshot_for_slug(slug) or {}
        return set(snap.get("issue_branches") or [])
    return set(_fetch_issue_branches(slug)[0] or [])


def _since_from(issues, fallback):
    """The newest updatedAt on the board (GitHub's own clock), or <fallback> when none carries one."""
    stamps = [i.get("updatedAt") for i in issues if i.get("updatedAt")]
    return max(stamps) if stamps else fallback


def _merge_issues(issues, delta):
    """Overlay <delta> onto <issues> in place of the old copies; issues new to the board go first,
    newest-numbered first — the order `gh issue list` itself returns (created-descending)."""
    fresh = {d["number"]: d for d in delta}
    merged = [fresh.pop(i["number"], i) for i in issues]
    return sorted(fresh.values(), key=lambda d: -d["number"]) + merged


def _resolve_ext_deps(slug, issues, prev_ext, now, snap_dir):
    """State of every `## Blocked by` ref the snapshot itself cannot answer — one into ANOTHER repo
    with no snapshot of its own, or one into this repo that is not an issue on the board (a PR: `gh
    issue view` calls a merged one MERGED, which satisfies the ref) — so workers never have to call
    gh for it. Each is one call, cached for HARNESS_DEP_TTL seconds; a satisfied (closed/merged)
    state holds until the next full resync. Only refs compute_state can act on are resolved: those
    of open issues and of PRDs."""
    out = {}
    on_board = {i.get("number") for i in issues}
    for it in issues:
        is_prd = (L_PRD() in {str(l.get("name", "")).lower() for l in it.get("labels", [])}
                  or str(it.get("title", "")).startswith("[AFK] PRD:"))
        if str(it.get("state", "")).lower() != "open" and not is_prd:
            continue
        for ref_repo, n in parse_blocked_by(it.get("body"), slug):
            rs = _repo_slug(ref_repo)
            key = f"{rs}#{n}"
            if key in out or (rs == slug and n in on_board):
                continue
            if rs != slug and snap_dir and os.path.exists(os.path.join(snap_dir, _slug_filename(rs))):
                continue
            p = prev_ext.get(key)
            if isinstance(p, dict) and (p.get("state") in _SATISFIED_STATES or now - p.get("at", 0) < DEP_TTL()):
                out[key] = p
                continue
            out[key] = {"state": _issue_state(rs, n), "at": now}
    return out


def _usable_prev(prev, slug, now):
    """The previous snapshot when an incremental refresh can build on it, else None (full resync)."""
    if not isinstance(prev, dict) or prev.get("slug") != slug:
        return None
    if prev.get("schema_version") != SNAPSHOT_SCHEMA_VERSION:
        return None
    sync = prev.get("sync")
    if not isinstance(sync, dict) or not sync.get("since") or not isinstance(prev.get("issues"), list):
        return None
    if now - int(sync.get("full_at", 0) or 0) >= FULL_RESYNC():
        return None
    return prev


def snapshot(repo, prev=None, snap_dir=None):
    """The raw, versioned per-repo snapshot the host poller writes (PRD-B). Performs the GitHub
    reads — issue list, PLAN.md presence, plan-completion marker, bot login — and returns them
    unfiltered/uninterpreted: author filtering and label interpretation stay per-project on the
    read side. Run with HARNESS_SNAPSHOT_FILE UNSET (the poller's env) so it reads gh, not itself.
    Given the PREVIOUS snapshot (#182) it refreshes incrementally instead: see the cache notes above."""
    slug = _repo_slug(repo)
    now = int(time.time())
    base = _usable_prev(prev, slug, now)
    if base is not None:
        try:
            return _snapshot_incremental(slug, base, now, snap_dir)
        except _Resync as e:
            print(f"[issuelib] incremental refresh of {slug} unusable ({e}) — full resync", file=sys.stderr)
    issues = _fetch_issues(slug)   # exactly the gh payload — no _labels/_author derived fields
    branches, branches_etag = _fetch_issue_branches(slug)
    started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 300))   # no updatedAt anywhere
    # a full resync still answers PR / CI conditionally against the last snapshot of this repo
    prs, pulls_etag = _pr_cache(slug, branches, prev if isinstance(prev, dict) and prev.get("slug") == slug else None)
    return {
        "schema_version": SNAPSHOT_SCHEMA_VERSION,
        "generated_at": now,
        "slug": slug,
        "issues": issues,
        "has_plan": _has_plan(slug),
        "plan_marker": _plan_marker(slug),
        "self_login": _self_login(),
        "ext_deps": _resolve_ext_deps(slug, issues, {}, now, snap_dir),
        "issue_branches": branches,
        **prs,
        "sync": {"since": _since_from(issues, started), "issues_etag": None, "root_etag": None,
                 "marker_dir_sha": None, "branches_etag": branches_etag, "pulls_etag": pulls_etag,
                 "full_at": now},
    }


def _snapshot_incremental(slug, prev, now, snap_dir):
    sync = prev["sync"]
    delta, etag = _fetch_issue_delta(slug, sync["since"], sync.get("issues_etag"))
    issues = prev["issues"] if delta is None else _merge_issues(prev["issues"], delta)
    has_plan, marker, root_etag, dir_sha = _fetch_root(slug, sync, prev)
    branches, branches_etag = _fetch_issue_branches(slug, sync.get("branches_etag"))
    if branches is None:
        branches = prev.get("issue_branches") or []
    prs, pulls_etag = _pr_cache(slug, branches, prev)
    return {
        "schema_version": SNAPSHOT_SCHEMA_VERSION,
        "generated_at": now,
        "slug": slug,
        "issues": issues,
        "has_plan": has_plan,
        "plan_marker": marker,
        "self_login": prev.get("self_login", ""),
        "ext_deps": _resolve_ext_deps(slug, issues, prev.get("ext_deps") or {}, now, snap_dir),
        "issue_branches": branches,
        **prs,
        "sync": {"since": sync["since"] if delta is None else _since_from(issues, sync["since"]),
                 "issues_etag": etag, "root_etag": root_etag, "marker_dir_sha": dir_sha,
                 "branches_etag": branches_etag, "pulls_etag": pulls_etag, "full_at": sync.get("full_at", now)},
    }


def _prd_list(issues):
    """Every PRD issue, ascending by number. Identified by the prd label or the `[AFK] PRD:`
    title prefix — the same test the old single-PRD selector used, just not short-circuited."""
    return sorted((i for i in issues
                   if L_PRD() in i["_labels"] or i.get("title", "").startswith("[AFK] PRD:")),
                  key=lambda i: i["number"])


def compute_state(repo):
    slug = _repo_slug(repo)
    # secure-by-default: drop issues from non-allowed authors up front, so neither PRD
    # selection nor the IMPL claimable filter below can be hijacked by a foreign author.
    listed = _list_issues(slug)
    issues = _author_filter(listed)
    prd_issues = _prd_list(issues)
    # bug-lane issues live in a separate lane: never claimed by the normal pool and never
    # counted toward unit completion, even when they carry the ready label.
    children = [i for i in issues if L_READY() in i["_labels"] and L_PRD() not in i["_labels"]
                and L_BUG() not in i["_labels"] and L_BUG_TRIAGED() not in i["_labels"]]

    # Partition children by parent PRD. A parent ref that names another repo, or a PRD number
    # that does not exist here, is not attributable — those fall into the unparented bucket
    # rather than vanishing.
    by_parent = {p["number"]: [] for p in prd_issues}
    unparented = []
    for i in children:
        p = parse_parent(i.get("body"), slug)
        if p is not None and _repo_slug(p[0]) == slug and p[1] in by_parent:
            by_parent[p[1]].append(i)
        else:
            unparented.append(i)

    # #287: an OPEN issue that names a PRD as its parent but is in no bucket (a lane filed it with no
    # lane label) never held that PRD's sign-off, so review signed off, the engine closed the PRD, and
    # the child was stranded. Every such issue — whatever its labels — is a stray that holds REVIEW
    # and CLOSE_PRD; dispatch labels an unlabelled one ready so a lane can take it.
    kid_nums = {i["number"] for i in children}
    strays = {p["number"]: [] for p in prd_issues}
    for i in issues:
        if i["state"].lower() != "open" or i["number"] in kid_nums or i["number"] in strays:
            continue
        p = parse_parent(i.get("body"), slug)
        if p is not None and _repo_slug(p[0]) == slug and p[1] in strays:
            strays[p[1]].append(i)

    closed_cache = {}
    # #221: open blockers no lane can claim, for a PRD or ready child they alone hold.
    by_num = {i["number"]: i for i in listed}
    allowed = {i["number"] for i in issues}
    stuck_on = []
    parked = []   # #271: agent-blocked children an autonomous fleet holds until they change
    def _note_stuck(issue, prd_num):
        blockers = _open_blockers(issue, slug, closed_cache, prd_num)
        stuck_on.extend(r for r in _stuck_refs(blockers, slug, by_num, allowed) if r not in stuck_on)

    def _bucket(kids, prd_num):
        all_closed = bool(kids) and all(k["state"].lower() == "closed" for k in kids)
        unblocked = []
        for k in kids:
            if k["state"].lower() != "open" or L_WORKING() in k["_labels"]:
                continue
            if _blocked_hold(k, slug):
                if AUTONOMOUS(): parked.append(k["number"])
                continue
            if _is_unblocked(k, slug, closed_cache, prd_num):
                unblocked.append(k["number"])
            else:
                _note_stuck(k, prd_num)
        return all_closed, unblocked

    lane_labels = {L_READY(), L_BUG(), L_BUG_TRIAGED()}
    prds = []
    held_by = []
    for p in prd_issues:
        kids = by_parent[p["number"]]
        stray = strays[p["number"]]
        # a labelled stray no lane can take holds its PRD for good — name it, like a #221 blocker
        stuck_on.extend(r for r in ((slug, i["number"]) for i in stray
                                    if i["_labels"] and not lane_labels & set(i["_labels"]))
                        if r not in stuck_on)
        all_closed, unblocked = _bucket(kids, p["number"])
        eligible = _is_unblocked(p, slug, closed_cache, p["number"])
        if not eligible and unblocked:
            held_by += [r for r in _open_blockers(p, slug, closed_cache, p["number"]) if r not in held_by]
        is_open = p["state"].lower() == "open"
        if not eligible and is_open:
            _note_stuck(p, p["number"])
        prds.append({"number": p["number"],
                     "open": is_open,
                     "reviewed": L_REVIEWED() in p["_labels"],
                     # a PRD's own `## Blocked by` is what sequences PRDs; no section = eligible now
                     "eligible": eligible,
                     "children_exist": bool(kids),
                     # #221: a `## Task 1` section with no child titled for it — a pre-filed child
                     # must not stop DECOMPOSE filing the plan-first task.
                     "needs_task1": bool(_TASK1_HEADING.search(p.get("body") or ""))
                                    and not any(_TASK1_TITLE.search(k.get("title") or "") for k in kids),
                     "children_all_closed": all_closed,
                     # #287: open issues naming this PRD outside its ready children; `unlabelled` is
                     # the subset dispatch labels ready
                     "stray": [i["number"] for i in stray],
                     "unlabelled": [i["number"] for i in stray if not i["_labels"]],
                     "unblocked": unblocked})
    # The unparented bucket keeps the LEGACY exempt-PRD (the lowest-numbered one): a child with no
    # `## Parent`/`Part of` attribution that names a PRD in its `## Blocked by` is the pre-upgrade
    # shape, and that ref is attribution leakage, not a real block. Passing None here would start
    # querying the PRD's state and wrongly hold such a child blocked until its PRD closed.
    _, unparented_unblocked = _bucket(unparented, prd_issues[0]["number"] if prd_issues else None)

    # Legacy scalar keys, derived from the LOWEST-numbered PRD. Kept so `status`, `check` and every
    # existing consumer/test keeps working; only dispatch() and is_complete() read `prds`.
    # Resumable candidates (#210) — dispatch claims these ahead of fresh work: a force-paused issue,
    # or one whose `issue/<n>` branch (and so any open PR) already exists. The branch read is skipped
    # when at most one candidate exists, since ordering cannot change what gets claimed then.
    candidates = unparented_unblocked + [n for p in prds for n in p["unblocked"]]
    resumable = {i["number"] for i in children
                 if i["state"].lower() == "open" and L_PAUSED() in i["_labels"]}
    if len(candidates) > 1:
        try:
            resumable |= _issue_branches(slug)
        except GhError as e:
            print(f"[issuelib] issue-branch read for {slug} failed ({e}) — dispatching oldest-first",
                  file=sys.stderr)

    first = prds[0] if prds else None
    marker = _plan_marker(slug)
    return {"slug": slug, "has_plan": _has_plan(slug),
            "plan_marker_matches": marker is not None and marker.get("spec_hash") == _spec_hash(),
            "prds": prds,
            "unparented_unblocked": unparented_unblocked,
            "resumable": sorted(n for n in resumable if n in candidates),
            "open_unparented": sum(1 for i in unparented if i["state"].lower() == "open"),
            "prd": first["number"] if first else None,
            "prd_open": bool(first) and first["open"],
            "prd_reviewed": bool(first) and first["reviewed"],
            "children_exist": bool(children),
            "children_all_closed": bool(children) and all(i["state"].lower() == "closed" for i in children),
            "unblocked": unparented_unblocked + [n for p in prds for n in p["unblocked"]],
            # #211: `unblocked` above keeps counting children of PRDs still sequenced behind an open
            # `## Blocked by`, which dispatch() can never claim. `dispatchable` is what it can;
            # `waiting` is the rest, and `held_by` names the upstream refs those PRDs wait on.
            "dispatchable": unparented_unblocked + [n for p in prds if p["eligible"] for n in p["unblocked"]],
            "waiting": [n for p in prds if not p["eligible"] for n in p["unblocked"]],
            "held_by": held_by,
            "stuck_on": stuck_on,
            "parked": sorted(parked),
            "open_children": sum(1 for i in children if i["state"].lower() == "open"),
            "total_children": len(children),
            "paused": sum(1 for i in children if i["state"].lower() == "open" and L_PAUSED() in i["_labels"])}

def bug_lane_candidates(repo):
    """(number, phase) for each open bug-lane issue the priority lane (#26) may claim:
    author-allowed, OPEN, carrying L_BUG or L_BUG_TRIAGED, not already agent-working, and
    (autonomous or not blocked). phase is 'fix' for a bug-triaged (a pending fix) or 'triage'
    for a fresh bug. The lane handles both stages.

    Ordered fix-pending-first (#28): a `bug-triaged` (a pending fix) sorts ahead of a fresh
    `bug`, so the cap-1 lane — which claims head-of-list — drains the triaged one to closed
    before triaging the new one. The sort is stable, so same-phase bugs keep their list order.
    The lane uses the phase to globally re-order candidates across repos (#37)."""
    slug = _repo_slug(repo)
    issues = _author_filter(_list_issues(slug))
    claimable = [i for i in issues
                 if (L_BUG() in i["_labels"] or L_BUG_TRIAGED() in i["_labels"])
                 and i["state"].lower() == "open"
                 and L_WORKING() not in i["_labels"]
                 and not _blocked_hold(i, slug)]
    claimable.sort(key=lambda i: 0 if L_BUG_TRIAGED() in i["_labels"] else 1)
    return [(i["number"], "fix" if L_BUG_TRIAGED() in i["_labels"] else "triage")
            for i in claimable]

def bug_lane_issues(repo):
    """Open bug-lane issue numbers (fix-pending-first), without phase. See bug_lane_candidates."""
    return [n for n, _phase in bug_lane_candidates(repo)]

def bug_lane_working(repo):
    """Numbers of OPEN bug-lane issues currently CARRYING L_WORKING — the COMPLEMENT of
    bug_lane_candidates' working filter (#42). A bug-lane session that crashes after spawn_bug
    stamps agent-working but before the issue closes leaves the bug stuck under agent-working,
    invisible to bug_lane_candidates (which excludes agent-working) — so the cap-1 lane idles
    while an OPEN bug sits there. The lane's per-poll reap walks these and frees the ones whose
    sess_bug session is dead, so a crashed triage/fix self-heals without `harness start --recover`.
    Author-allowed + bug/bug-triaged, same scope as the candidate scan (the lane never touches an
    issue it could not have claimed). Returned in list order; reap order does not matter."""
    slug = _repo_slug(repo)
    issues = _author_filter(_list_issues(slug))
    return [i["number"] for i in issues
            if (L_BUG() in i["_labels"] or L_BUG_TRIAGED() in i["_labels"])
            and i["state"].lower() == "open"
            and L_WORKING() in i["_labels"]]


def working_locks(repo):
    """(number, updatedAt) of every OPEN issue CARRYING L_WORKING, any lane — the stale-lock sweep's
    candidates (#179). A gh outage at reap time leaves the label behind with no session to clear it,
    so the pool worker walks these each poll and frees the ones no live session owns. agent-blocked
    is excluded (a parked issue is a human's, exactly like recover_orphan_working); so are issues the
    fleet could never have claimed (author filter). updatedAt is a conservative lower bound on the
    label's age: the issue was labelled at or before its last update, so "updated more than N minutes
    ago" implies "labelled more than N minutes ago" without a timeline read per candidate."""
    slug = _repo_slug(repo)
    issues = _author_filter(_list_issues(slug, ["--label", L_WORKING()]))
    return [(i["number"], i.get("updatedAt") or "") for i in issues
            if i["state"].lower() == "open"
            and L_WORKING() in i["_labels"] and L_BLOCKED() not in i["_labels"]]


# ── default-branch CI health (#50) ────────────────────────────────────────────────────────────
# The fleet's merge decision used to read mergeable-state only and never the check RESULT, so a
# repo with no REQUIRED status check (private repo on a free plan: branch protection and rulesets
# are both 403) let four PRs land on a red default branch without anything noticing. The durable
# pair is (a) the impl/bug-fix prompts refusing to merge a red PR, and (b) this: the pool refuses
# to CLAIM NEW WORK while the default branch itself is red, which caps the blast radius at one bad
# merge instead of an unbounded run of them.
#
# Deliberately FAIL-OPEN. "unknown" — no Actions at all, no completed run yet, an unrecognised
# conclusion, a gh outage — must never wedge a fleet, so only a positively-identified failure of
# the most recent COMPLETED run of some workflow counts as red. The bug lane is NOT gated on this:
# it is the remedy path, and gating it would make a red default branch unfixable by the fleet.
_CI_FAIL_CONCLUSIONS = {"failure", "timed_out", "startup_failure", "action_required"}


def _default_branch(slug):
    """The repo's default branch name, or "" when it cannot be read (absent repo / no access)."""
    out = _gh_api_read(f"repos/{slug}", ".default_branch")
    return (out or "").strip()


def ci_status(repo, branch=None, limit=20):
    """(verdict, workflow, url) for <repo>'s default branch, verdict ∈ pass|fail|unknown.

    Groups the recent runs by workflow and looks only at each workflow's most recent COMPLETED
    run — an in-flight run never masks the last verdict, and a workflow that has never completed
    is simply not evidence. Any one workflow concluding in _CI_FAIL_CONCLUSIONS makes the branch
    red; the returned workflow/url name that run so the caller can log something actionable.
    Raises GhError on a transient gh failure, which the CLI turns into `unknown` (fail-open)."""
    slug = _repo_slug(repo)
    if branch is None:
        branch = _default_branch(slug)
    if not branch:
        return ("unknown", "", "")
    runs = _gh_json(["run", "list", "-R", slug, "--branch", branch, "--limit", str(limit),
                     "--json", "workflowName,status,conclusion,url"], allow_absent=True)
    if not runs:
        return ("unknown", "", "")   # Actions not configured, or no run on this branch yet
    latest = {}
    for r in runs:
        if (r.get("status") or "").lower() != "completed":
            continue
        latest.setdefault(r.get("workflowName") or "", r)   # gh lists newest-first
    if not latest:
        return ("unknown", "", "")   # everything still in flight
    for name, r in sorted(latest.items()):
        if (r.get("conclusion") or "").lower() in _CI_FAIL_CONCLUSIONS:
            return ("fail", name, r.get("url") or "")
    return ("pass", "", "")


def dispatch(repo, free_slots, allow_orchestration, busy_prds=(), priority_free=None):
    s = compute_state(repo); a = _allowed(MODE()); out = []
    prds = s["prds"]; busy = set(busy_prds); slots = max(0, free_slots)
    if allow_orchestration:
        # Fire a fresh PLAN only with no live PLAN.md AND (no completion marker OR the spec content
        # changed since that marker). A finished plan archives PLAN.md and writes a spec-keyed marker,
        # so without the marker check PLAN would re-fire every poll once the doc is gone.
        if a["plan"] and not prds and not s["has_plan"] and not s["plan_marker_matches"]:
            return [("PLAN", "-", "PLAN DONE")]
        if a["prd"] and s["has_plan"] and not prds:
            return [("PRD", "-", "PRD DONE")]
    # A PRD sequenced behind another via `## Blocked by` contributes nothing — no decompose, no
    # impl, no review — until its blocker closes. No blockers means eligible immediately, which is
    # what makes independent PRDs run in parallel.
    eligible = [p for p in prds if p["eligible"]]
    # DECOMPOSE/REVIEW/CLOSE_PRD are gated PER PRD (via `busy`) rather than by the unit-wide
    # `allow_orchestration`. That unit-wide flag is set only when NO session is live anywhere in
    # the unit, so leaving these under it would mean PRD #2 could never decompose while PRD #1 had
    # a single impl session running — silently re-serializing PRDs authored to run in parallel.
    # PLAN/PRD stay under `allow_orchestration`: they are unit-level and must not race anything.
    if a["decompose"]:
        for p in eligible:
            if p["open"] and (not p["children_exist"] or p.get("needs_task1")) and p["number"] not in busy:
                return [("DECOMPOSE", str(p["number"]), "DECOMPOSE DONE")]
    # Slots: unparented bucket (human injections) first, then eligible PRDs ascending, each
    # spilling into the next only once it has no unblocked work left. WITHIN a bucket (#210):
    # resumable issues first — an open PR / pushed branch / paused lane goes stale while it waits —
    # then oldest first. gh lists newest-first, so without this the latest injection jumped the queue.
    resumable = set(s.get("resumable") or ())
    def _order(nums):
        return sorted(nums, key=lambda n: (n not in resumable, n))
    for num in _order(s["unparented_unblocked"])[:slots]:
        out.append(("IMPL", str(num), f"ISSUE {num} DONE"))
    for p in eligible:
        if len(out) >= slots: break
        for num in _order(p["unblocked"])[:slots - len(out)]:
            out.append(("IMPL", str(num), f"ISSUE {num} DONE"))
    # REVIEW/CLOSE_PRD gate on remaining CAPACITY, not on `not out` as the single-PRD version did:
    # with several PRDs, one PRD's impl work must not suppress another's review indefinitely.
    #   • REVIEW signs off — it applies the reviewed label (and may file gap issues). Gated on
    #     NOT-yet-reviewed so a reviewed-but-still-open PRD doesn't spawn an endless run of fresh
    #     review sessions (each one a live orch session).
    #   • CLOSE_PRD is the mechanical close, done by the ENGINE (drive.sh) via a single idempotent
    #     `gh issue close`, retried every poll — so a signed-off PRD always closes even if the
    #     review agent's own gh call was dropped by a rate limit.
    if a["review"]:
        for p in eligible:
            if len(out) >= slots: break
            if p["number"] in busy or not p["open"] or not p["children_all_closed"] or p.get("stray"):
                continue
            if not p["reviewed"]:
                out.append(("REVIEW", str(p["number"]), "REVIEW DONE"))
            else:
                out.append(("CLOSE_PRD", str(p["number"]), "PRD CLOSED"))
    # #214: a pool slot with nothing else to do helps the bug lane. The lane keeps first pick: the
    # pool spills only while EVERY priority slot is busy — a free one claims the queue head on its
    # next poll, and the pool takes the rest once it has. Oldest bug first, either phase. None means
    # the caller did not say (HARNESS_POOL_TAKES_BUGS=0, or a pre-#214 caller): never spill.
    if not out and slots and priority_free is not None and priority_free <= 0:
        for num in sorted(n for n, _phase in bug_lane_candidates(repo))[:slots]:
            out.append(("BUG", str(num), f"BUG {num} DONE"))
    # #287: an unlabelled open issue naming an open PRD is labelled ready by the engine (drive.sh
    # label_ready, one idempotent gh call), so it joins that PRD's children and is dispatched next
    # poll. Takes no slot: there is no session, and it must never wait behind one.
    if a["review"]:
        for p in prds:
            if p["open"]:
                out += [("LABEL_READY", str(n), "-") for n in p.get("unlabelled", ())]
    return out

def is_complete(s):
    if MODE() == "issue-only":
        return s["children_exist"] and s["open_children"] == 0 and len(s["unblocked"]) == 0
    # A CLOSED PRD means that PRD is done. The reviewed label is the sign-off SIGNAL that lets the
    # engine close the PRD, but completion keys off the close itself: requiring the label here too
    # left a close-OK/label-fail PRD forever-incomplete (and REVIEW could not re-fire — its guard
    # needs the PRD open). Only the review path closes a PRD, so closed ⇒ reviewed-intent.
    # The unit is done when EVERY PRD is closed — a PRD still sequenced behind another keeps the
    # unit incomplete, which is what stops the pool retiring mid-queue — and when no unparented
    # (injected) child is still open, which is what stops a late injection being stranded.
    prds = s["prds"]
    return bool(prds) and all(not p["open"] for p in prds) and s.get("open_unparented", 0) == 0

def main():
    if len(sys.argv) < 2: print(__doc__); sys.exit(2)
    cmd = sys.argv[1]
    # spec-hash keys the plan-completion marker off HARNESS_SPEC; it needs no repo arg.
    if cmd == "spec-hash":
        print(_spec_hash()); return
    # snapshot-fresh <path> <refresh-seconds> — exit 0 iff the snapshot is fresh, 1 otherwise. The
    # worker dispatch gate (lib.sh ensure_snapshot_fresh) shells out to this; it never touches gh.
    if cmd == "snapshot-fresh":
        path = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("HARNESS_SNAPSHOT_FILE", "")
        refresh = int(sys.argv[3]) if len(sys.argv) > 3 else 0
        sys.exit(0 if _snapshot_fresh(path, refresh) else 1)
    # #183 GitHub budget commands; none takes a repo (a budget is per token, not per repo).
    #   rate-held             print the hold's reset epoch, exit 0 while held; exit 1 otherwise
    #   rate-low <pct> [ttl]  print `<resource>\t<remaining>\t<limit>\t<reset>`, exit 0 when under pct%
    #   rate-report           one line per token: remaining budget, reset time, HOLD
    if cmd == "rate-held":
        held = rate_hold_until()
        if held: print(held)
        sys.exit(0 if held else 1)
    if cmd == "rate-low":
        low = rate_budget_low(int(sys.argv[2]) if len(sys.argv) > 2 else 20,
                              int(sys.argv[3]) if len(sys.argv) > 3 else 60)
        if low: print("\t".join(str(x) for x in low))
        sys.exit(0 if low else 1)
    if cmd == "rate-report":
        for line in rate_report(): print(line)
        return
    if len(sys.argv) < 3: print(__doc__); sys.exit(2)
    repo = sys.argv[2]
    # Any gh-touching command HOLDS on a transient gh failure: GhError → print nothing to stdout and
    # exit 3, so the bash callers (dispatch_actions / poller_write_snapshot / unit_complete / check)
    # see empty output and simply retry next poll, instead of acting on a false-empty state (which
    # would spuriously re-fire PLAN or clobber a good snapshot). compute_state/snapshot raise BEFORE
    # any stdout is written, so partial output is never emitted.
    try:
        if cmd == "snapshot":
            # snapshot <repo> [<previous-snapshot>] — with the previous one, refresh incrementally.
            prev_path = sys.argv[3] if len(sys.argv) > 3 else ""
            snap_dir = os.path.dirname(prev_path) if prev_path else os.environ.get("HARNESS_SNAPSHOTS_DIR", "")
            json.dump(snapshot(repo, _load_snapshot(prev_path), snap_dir), sys.stdout, separators=(",", ":")); print()
        elif cmd == "dispatch":
            free = int(sys.argv[3]) if len(sys.argv) > 3 else 1
            allow = sys.argv[sys.argv.index("--allow-orchestration")+1] == "1" if "--allow-orchestration" in sys.argv else True
            # --busy-prds "41,42": PRDs with a live orch session, which must not be re-dispatched.
            # Optional and empty-tolerant so the bare `dispatch <repo> <free>` shape still works.
            busy = ()
            if "--busy-prds" in sys.argv:
                raw = sys.argv[sys.argv.index("--busy-prds")+1]
                busy = tuple(int(x) for x in raw.split(",") if x.strip().isdigit())
            # --priority-free N (#214): idle priority-lane slots. Given, the pool may spill into bugs.
            pfree = None
            if "--priority-free" in sys.argv:
                raw = sys.argv[sys.argv.index("--priority-free")+1]
                pfree = int(raw) if raw.strip().isdigit() else None
            for action, payload, promise in dispatch(repo, free, allow, busy, pfree): print(f"{action}\t{payload}\t{promise}")
        elif cmd == "status":
            s = compute_state(repo); prd = f"PRD#{s['prd']}" if s["prd"] else "no-PRD"
            prd += "(open)" if s["prd_open"] else ("(closed)" if s["prd"] else "")
            # unblocked= counts only what dispatch() could claim (#211); waiting= is ready work behind
            # a blocked PRD, and a unit starved on that names the upstream refs in `held by:`.
            ready, waiting = s.get("dispatchable", s["unblocked"]), s.get("waiting", [])
            done = is_complete(s)
            held = ""
            if not ready and waiting and not done and s.get("held_by"):
                slug = _repo_slug(repo)
                held = " held by: " + ", ".join(f"#{n}" if r == slug else f"{r}#{n}" for r, n in s["held_by"])
            # #221: a chain only an unclaimable issue holds never moves on its own — say which, loudly.
            if s.get("stuck_on") and not done:
                slug = _repo_slug(repo)
                refs = ", ".join(f"#{n}" if r == slug else f"{r}#{n}" for r, n in s["stuck_on"])
                print(f"{repo}: STUCK — chain needs an issue no agent can take: {refs} — label it "
                      f"{L_READY()} (or close it), or drop it from `## Blocked by`")
            # #271: an autonomous fleet holds a parked issue until something about it changes.
            if s.get("parked") and not done:
                refs = ", ".join(f"#{n}" for n in s["parked"])
                print(f"{repo}: PARKED — {L_BLOCKED()} and unchanged since its lane stopped: {refs} — "
                      f"comment on it or edit its labels once the blocker is fixed to re-dispatch it")
            print(f"{repo}: mode={MODE()} {prd} plan={'Y' if s['has_plan'] else 'N'} "
                  f"children={s['total_children']} open={s['open_children']} unblocked={len(ready)} "
                  f"waiting={len(waiting)} paused={s['paused']} reviewed={'Y' if s['prd_reviewed'] else 'N'} "
                  f"complete={'Y' if done else 'N'}{held}")
        elif cmd == "ci-status":
            # `<verdict>\t<workflow>\t<url>` for the default branch (or an explicit branch arg).
            # FAIL-OPEN by construction: on a transient gh failure the shared handler below prints
            # NOTHING and exits 3, and the bash gate (lib.sh ci_gate_ok) blocks only on a literal
            # `fail` — so a rate limit or an outage can never wedge dispatch, it just stops gating.
            branch = sys.argv[3] if len(sys.argv) > 3 else None
            print("\t".join(ci_status(repo, branch)))
        elif cmd == "bugs":
            for n, phase in bug_lane_candidates(repo): print(f"{n}\t{phase}")
        elif cmd == "working-bugs":
            for n in bug_lane_working(repo): print(n)
        elif cmd == "working":
            for n, upd in working_locks(repo): print(f"{n}\t{upd}")
        elif cmd == "complete":
            print("DONE" if is_complete(compute_state(repo)) else "NOTDONE")
        elif cmd == "check":
            goal = sys.argv[3] if len(sys.argv) > 3 else ""; s = compute_state(repo); done = False
            # Orchestration goals are PRD-qualified (`REVIEW:41`) so reap_done_sessions advances the
            # right session when several PRDs are in flight. A BARE goal (written by a pre-upgrade
            # engine, or by the unit-level PLAN/PRD actions) resolves against the lowest-numbered PRD.
            name, _, qual = goal.partition(":")
            prds = s["prds"]
            if qual.isdigit():
                target = next((p for p in prds if p["number"] == int(qual)), None)
            else:
                target = prds[0] if prds else None
            if goal == "PLAN": done = s["has_plan"]
            elif name == "PRD": done = bool(prds)
            elif name == "DECOMPOSE": done = bool(target) and target["children_exist"] and not target.get("needs_task1")
            elif name == "REVIEW": done = bool(target) and (target["reviewed"] or len(target["unblocked"]) > 0)
            elif name == "CLOSE_PRD": done = bool(target) and not target["open"]
            elif goal.startswith("ISSUE:"):
                # #271: an open issue its lane labelled agent-blocked is parked — that session is done
                # too, so the reap frees its slot instead of letting it idle at its prompt.
                n = int(goal.split(":",1)[1]); st = _issue_state(s["slug"], n)
                done = st == "closed" or (st == "open" and L_BLOCKED() in _issue_labels(s["slug"], n))
            print("DONE" if done else "PENDING")
        else: print(f"unknown command: {cmd}", file=sys.stderr); sys.exit(2)
    except GhError as e:
        print(f"issuelib: HOLD — transient gh failure on `{cmd} {repo}`: {e}", file=sys.stderr)
        sys.exit(3)

if __name__ == "__main__": main()
