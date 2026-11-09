#!/usr/bin/env python3
"""tier.py — `harness tier`: the "When to use Harness" check (#619, PRD #587).

    tier.py decide  --criteria N --lines N --files N --subsystems N [--workstreams N] [--pool N]
                    [--minutes N] [--user-around|--unattended] [--wants-review] [--multi-step-plan]
                    [--prefer direct|lane|fleet] [--json]
    tier.py overlap --files a,b,c [-R owner/repo] [--base main] [--repo-dir DIR] [--json]
    tier.py thresholds

`decide` picks the tier for a piece of work from an ESTIMATE the asking session made, against the
thresholds in tier.toml (the one file they live in; provisional until #621):

    direct   fits one session: one subsystem, few criteria, a small diff, and the user around (or a
             quick job) -> do it in the session, on a branch with a PR
    lane     fits one session, but the user wants it unattended or independently reviewed -> a PRD,
             one engine-filed child, then review
    fleet    will not fit one session, or has parallel workstreams, or hours unattended -> the full flow

It names the reason and a rough time and cost for the direct and the fleet path. `--prefer` is the
user's override in either direction; the recommendation stays in the output.

`overlap` is the direct path's guard on a LIVE fleet: it lists the files the open `agent-working`
issues' branches and worktrees, and the open PRs, touch, and exits 1 (route through /harness-issue)
if the direct fix would touch any of them, 0 if none (go ahead). gh and git are the only inputs; if any
call it needs fails, it exits 3 with the failed command on stderr (`--json`: an `error` field, `overlap`
null) — "could not check" is never reported as clear.
"""
import argparse, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOML = os.environ.get("HARNESS_TIER_TOML") or os.path.join(HERE, "tier.toml")
TIERS = ("direct", "lane", "fleet")


def _parse(text):
    """tomllib where there is one (3.11+); else the flat [section] / key = number subset tier.toml uses."""
    try:
        import tomllib
        return tomllib.loads(text)
    except ImportError:
        out, sec = {}, None
        for raw in text.splitlines():
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            m = re.fullmatch(r"\[(\w+)\]", line)
            if m:
                sec = out.setdefault(m.group(1), {})
                continue
            k, _, v = line.partition("=")
            if sec is not None and v.strip():
                v = v.strip()
                sec[k.strip()] = float(v) if "." in v else int(v)
        return out


DEFAULT_TOML = os.path.join(HERE, "tier.toml")   # the shipped thresholds: what a missing key falls back to


class TierConfigError(Exception):
    """tier.toml could not be read or parsed — one line, naming the file (#715), never a traceback."""


def _read(path):
    """The parsed file; a leading UTF-8 BOM is dropped, and any failure is a TierConfigError naming `path`."""
    try:
        with open(path, encoding="utf-8-sig") as f:
            text = f.read()
        return _parse(text)
    except OSError as e:
        raise TierConfigError(f"{path}: cannot read it: {e.strerror or e}")
    except UnicodeDecodeError as e:
        raise TierConfigError(f"{path}: not valid UTF-8: {e.reason} at byte {e.start}")
    except ValueError as e:   # tomllib.TOMLDecodeError, or the flat fallback parser's bad number
        raise TierConfigError(f"{path}: cannot parse it: {e}")


def load(path=None):
    """The thresholds in `path` (default tier.toml), each missing section or key filled from the shipped file."""
    path = path or TOML
    cfg = _read(path)
    if os.path.abspath(path) == DEFAULT_TOML:
        return cfg
    out = _read(DEFAULT_TOML)
    for sec, vals in cfg.items():
        if isinstance(vals, dict) and isinstance(out.get(sec), dict):
            out[sec].update(vals)
        else:
            out[sec] = vals
    return out


def estimate(cfg, criteria):
    e = cfg["estimate"]
    return {
        "direct": {"minutes": round(e["direct_minutes_base"] + e["direct_minutes_per_criterion"] * criteria),
                   "usd": round(e["direct_usd_base"] + e["direct_usd_per_criterion"] * criteria, 2)},
        "fleet": {"minutes": round(e["fleet_minutes_base"] + e["fleet_minutes_per_criterion"] * criteria),
                  "usd": round(e["fleet_usd_base"] + e["fleet_usd_per_criterion"] * criteria, 2)},
    }


def decide(cfg, criteria, lines, files, subsystems, workstreams=1, pool=1, minutes=None,
           user_around=True, wants_review=False, multi_step_plan=False, prefer=None):
    d, f = cfg["direct"], cfg["fleet"]
    fleet_why = []
    if criteria >= f["min_criteria"]:
        fleet_why.append(f"{criteria} acceptance criteria (>= {f['min_criteria']})")
    if subsystems >= f["min_subsystems"]:
        fleet_why.append(f"{subsystems} subsystems (>= {f['min_subsystems']})")
    if workstreams >= f["min_workstreams"] and pool >= f["min_pool"]:
        fleet_why.append(f"{workstreams} independent workstreams with POOL={pool}")
    if minutes is not None and not user_around and minutes >= f["min_unattended_minutes"]:
        fleet_why.append(f"~{minutes} min unattended (>= {f['min_unattended_minutes']})")
    if multi_step_plan:
        fleet_why.append("a multi-step plan")
    over = []   # the direct limits crossed
    if criteria > d["max_criteria"]:
        over.append(f"{criteria} criteria (> {d['max_criteria']})")
    if lines > d["max_changed_lines"]:
        over.append(f"~{lines} changed lines (> {d['max_changed_lines']})")
    if files > d["max_files"]:
        over.append(f"~{files} files (> {d['max_files']})")
    if subsystems > d["max_subsystems"]:
        over.append(f"{subsystems} subsystems (> {d['max_subsystems']})")
    quick = user_around or (minutes is not None and minutes < d["max_unattended_minutes"])
    if fleet_why:
        tier, why = "fleet", "will not fit one session: " + "; ".join(fleet_why)
    elif over:
        tier, why = "lane", "fits one session but is over the direct limits: " + "; ".join(over)
    elif wants_review:
        tier, why = "lane", "fits one session, but an independent review was asked for"
    elif not quick:
        tier, why = "lane", "fits one session, but runs unattended" + (
            f" (~{minutes} min, direct is for the user around or under {d['max_unattended_minutes']} min)"
            if minutes is not None else " and its length is unknown")
    else:
        tier, why = "direct", (f"fits one session: {criteria} criteria, ~{lines} lines, ~{files} files, "
                               f"{subsystems} subsystem, " + ("user around" if user_around else f"~{minutes} min"))
    out = {"tier": tier, "recommended": tier, "reason": why, "override": None,
           "estimate": estimate(cfg, criteria), "provisional": "thresholds are provisional until #621 recalibrates them"}
    if prefer and prefer != tier:
        out["tier"], out["override"] = prefer, f"user chose {prefer}; the check recommended {tier}"
    return out


def render(r):
    e = r["estimate"]
    lines = [f"TIER: {r['tier']}" + ("  (user override)" if r["override"] else ""),
             f"reason: {r['reason']}"]
    if r["override"]:
        lines.append(f"override: {r['override']}")
    lines += [f"direct: ~{e['direct']['minutes']} min, ~${e['direct']['usd']:.2f}",
              f"fleet:  ~{e['fleet']['minutes']} min, ~${e['fleet']['usd']:.2f}",
              "(" + r["provisional"] + ")"]
    return "\n".join(lines)


# ── overlap ──────────────────────────────────────────────────────────────────────────────────────
EXIT_UNCHECKED = 3   # overlap could not be answered: distinct from 0 (clear), 1 (overlap) and 2 (usage)
REPO_RE = re.compile(r"[A-Za-z0-9_][\w.-]*/[\w.][\w.-]*")   # same rule as stats.REPO_RE (#716)


class CheckFailed(Exception):
    """A gh or git call the overlap answer needs failed — the answer is unknown, never "clear"."""


def _call(argv, cwd=None):
    """(returncode, stdout, stderr); an unrunnable command raises CheckFailed."""
    try:
        p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError) as e:
        raise CheckFailed(f"`{' '.join(argv)}` could not run: {e}")
    return p.returncode, p.stdout, p.stderr


def _run(argv, cwd=None):
    rc, out, err = _call(argv, cwd)
    if rc != 0:
        why = (err.strip().splitlines() or [f"exit {rc}"])[0]
        raise CheckFailed(f"`{' '.join(argv)}` failed (exit {rc}): {why}")
    return out


def _json_list(text, argv):
    try:
        v = json.loads(text)
    except ValueError:
        v = None
    if not isinstance(v, list):
        raise CheckFailed(f"`{' '.join(argv)}` printed something other than a JSON list")
    return v


def _names(text):
    return [l.strip() for l in (text or "").splitlines() if l.strip()]


def _worktrees(repo_dir):
    """{branch: path} for every checked-out worktree of the repo."""
    out, cur = {}, {}
    for line in _run(["git", "worktree", "list", "--porcelain"], repo_dir).splitlines() + [""]:
        if not line:
            if cur.get("branch"):
                out[cur["branch"]] = cur["path"]
            cur = {}
        elif line.startswith("worktree "):
            cur["path"] = line[9:]
        elif line.startswith("branch "):
            cur["branch"] = re.sub(r"^refs/heads/", "", line[7:])
    return out


def open_work(slug, base, repo_dir, label):
    """[(who, [files])] — every open agent-working issue (its branch and worktree) and open PR."""
    work = []
    pr_cmd = ["gh", "pr", "list", "-R", slug, "--state", "open", "--json", "number,headRefName"]
    is_cmd = ["gh", "issue", "list", "-R", slug, "--state", "open", "--label", label, "--json", "number"]
    prs = _json_list(_run(pr_cmd), pr_cmd)
    issues = _json_list(_run(is_cmd), is_cmd)
    trees = _worktrees(repo_dir)
    for pr in prs:
        files = _names(_run(["gh", "pr", "diff", str(pr["number"]), "-R", slug, "--name-only"]))
        work.append((f"PR #{pr['number']}", files))
    for it in issues:
        n = it["number"]; br = f"issue/{n}"; files = []
        for ref in (f"origin/{br}", br):
            # a branch that does not exist yet (rev-parse exit 1) owns no files; any other failure is unknown
            rc, _, err = _call(["git", "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"], repo_dir)
            if rc == 1:
                continue
            if rc != 0:
                raise CheckFailed(f"`git rev-parse --verify {ref}` failed (exit {rc}): "
                                  f"{(err.strip().splitlines() or ['no output'])[0]}")
            files += _names(_run(["git", "diff", "--name-only", f"{base}...{ref}", "--"], repo_dir)); break
        wt = trees.get(br)
        if wt:   # uncommitted work in the lane's own worktree counts too
            for l in _run(["git", "status", "--porcelain"], wt).splitlines():   # not _names: the XY column's leading space is data
                files.append(l[3:].split(" -> ")[-1].strip('"'))
        work.append((f"issue #{n} ({label})", sorted(set(files))))
    return work


def overlap(files, slug, base, repo_dir, label):
    mine = {f.strip().lstrip("./") for f in files if f.strip()}
    hits = []
    for who, theirs in open_work(slug, base, repo_dir, label):
        both = sorted(mine & {t.lstrip("./") for t in theirs})
        if both:
            hits.append({"owner": who, "files": both})
    return hits


def count(v):
    """argparse type for a count option (--criteria, --lines, --pool, …): an integer >= 0."""
    try:
        n = int(v)
    except ValueError:
        raise argparse.ArgumentTypeError(f"invalid int value: {v!r}")
    if n < 0:
        raise argparse.ArgumentTypeError(f"{n} is negative — a count must be 0 or more")
    return n


def pool_size(v):
    """argparse type for --pool: an integer >= 1. A fleet of zero workers is not a real configuration."""
    n = count(v)
    if n < 1:
        raise argparse.ArgumentTypeError(f"{n} workers is not a fleet — --pool must be 1 or more")
    return n


def main(argv=None):
    ap = argparse.ArgumentParser(prog="harness tier", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("decide")
    for k in ("criteria", "lines", "files", "subsystems"):
        d.add_argument(f"--{k}", type=count, required=True)
    d.add_argument("--workstreams", type=count, default=1)
    d.add_argument("--pool", type=pool_size, default=1)
    d.add_argument("--minutes", type=count)
    g = d.add_mutually_exclusive_group()
    g.add_argument("--user-around", action="store_true", default=True)
    g.add_argument("--unattended", action="store_true")
    d.add_argument("--wants-review", action="store_true")
    d.add_argument("--multi-step-plan", action="store_true")
    d.add_argument("--prefer", choices=TIERS)
    d.add_argument("--json", action="store_true")
    o = sub.add_parser("overlap")
    o.add_argument("--files", required=True, help="comma-separated paths the direct fix would touch")
    o.add_argument("-R", dest="repo", default=os.environ.get("HARNESS_REPO", ""))
    o.add_argument("--base", default=os.environ.get("HARNESS_DEFAULT_BRANCH", "main"))
    o.add_argument("--repo-dir", default=".")
    o.add_argument("--json", action="store_true")
    sub.add_parser("thresholds")
    a = ap.parse_args(argv)
    try:
        cfg = load()
    except TierConfigError as e:
        print(f"harness tier: {e}", file=sys.stderr); return 2
    if a.cmd == "thresholds":
        print(json.dumps(cfg, indent=2)); return 0
    if a.cmd == "decide":
        r = decide(cfg, a.criteria, a.lines, a.files, a.subsystems, a.workstreams, a.pool, a.minutes,
                   user_around=not a.unattended, wants_review=a.wants_review,
                   multi_step_plan=a.multi_step_plan, prefer=a.prefer)
        print(json.dumps(r) if a.json else render(r)); return 0
    if a.base.startswith("-"):   # #748: a revision git could read as an option (--output=…) never reaches git
        ap.error(f"argument --base: {a.base!r} is not a branch — it must not start with '-'")
    if not a.repo:
        print("harness tier overlap: no repo — pass -R owner/repo (or set HARNESS_REPO)", file=sys.stderr); return 2
    label = os.environ.get("HARNESS_LABEL_WORKING", "agent-working")
    if not REPO_RE.fullmatch(a.repo):
        ap.error(f"argument -R: {a.repo!r} is not a repository — expected owner/name")
    files = [f for f in a.files.split(",") if f.strip()]
    if not files:
        print("harness tier overlap: no files to check — pass --files a,b,c", file=sys.stderr); return 2
    try:
        hits = overlap(files, a.repo, a.base, a.repo_dir, label)
    except CheckFailed as e:
        msg = f"could not check for overlap: {e}"
        print(f"harness tier overlap: {msg}", file=sys.stderr)
        if a.json:
            print(json.dumps({"overlap": None, "hits": [], "error": msg}))
        return EXIT_UNCHECKED
    if a.json:
        print(json.dumps({"overlap": bool(hits), "hits": hits}))
    elif hits:
        print("OVERLAP: the direct fix touches files an open lane or PR owns:")
        for h in hits:
            print(f"  {h['owner']}: " + ", ".join(h["files"]))
        print("route it through /harness-issue instead of fixing it here")
    else:
        print("no overlap: no open agent-working issue or PR touches these files — the direct path is clear")
    return 1 if hits else 0


if __name__ == "__main__":
    import pipesafe   # #713: a closed stdout ends the command quietly
    sys.exit(pipesafe.run(main))
