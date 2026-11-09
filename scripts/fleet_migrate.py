#!/usr/bin/env python3
"""fleet_migrate.py — the config half of scripts/fleet-migrate.sh (#467, PRD #464 §4).

  fleet_migrate.py fleets <fleets-dir>          print the state dir (`project`) of every registered fleet
  fleet_migrate.py config <state-dir> [--date D]  move one fleet's config to the one-repo keys

`config` reads <state-dir>/config as TEXT, never sources it, and understands both line forms a
Harness config has been written in: `: "${KEY:=val}"` and plain `KEY=val`. Exit codes: 0 migrated
(one summary line on stdout), 10 already on the one-repo config (nothing touched), 11 only a leftover
HARNESS_CAP line was dropped (#469: nothing else changed, so there is nothing to roll), 2 unreadable.

A config still needs migrating when it has a HARNESS_TOPOLOGY line, or has no HARNESS_UNIT. Then:
  - multi: the targets.tsv row whose repo is HARNESS_REPO, else the only row, else the first row,
    gives HARNESS_REPO (its repo wins), HARNESS_UNIT (its id) and HARNESS_CHECKOUT (the clone that
    exists under .harness/checkouts). The other rows move to targets.tsv.migrated.
  - single: HARNESS_UNIT=main, HARNESS_CHECKOUT=the project root.
  - HARNESS_POOL = max(POOL, CAP); HARNESS_CAP and HARNESS_TOPOLOGY go (CAP is gone, #469: POOL is the
    number of parallel issues).
A config already on HARNESS_UNIT (migrated by #467) that still has a HARNESS_CAP line only loses that line;
POOL is kept as it is.
The old config is saved as config.bak-<date> first, and a fleet_migrated event is logged.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
COLON = re.compile(r'^(\s*:\s+"\$\{)(HARNESS_[A-Z0-9_]+)(:=)(.*?)(\}")(\s*(?:#.*)?)$')
PLAIN = re.compile(r'^(\s*(?:export\s+)?)(HARNESS_[A-Z0-9_]+)=(.*)$')
DEFAULT_POOL = DEFAULT_CAP = 3


def parse(lines):
    """key -> {idx, kind, value, span}: the line that decides the key. `:=` never overrides a key
    already set above it; a plain assignment always does (shell semantics)."""
    ent = {}
    for i, line in enumerate(lines):
        if line.lstrip().startswith("#"):
            continue
        m = COLON.match(line)
        if m:
            key = m.group(2)
            if key not in ent:
                ent[key] = {"idx": i, "kind": "colon", "value": m.group(4), "span": m.span(4)}
            continue
        m = PLAIN.match(line)
        if m:
            raw, base = m.group(3), m.start(3)
            if raw[:1] in "\"'":
                end = raw.find(raw[0], 1)
                if end < 0:
                    continue
                value, span = raw[1:end], (base, base + end + 1)
            else:
                tok = re.match(r"[^\s#]*", raw)
                value, span = tok.group(0), (base, base + tok.end())
            ent[m.group(2)] = {"idx": i, "kind": "plain", "value": value, "span": span}
    return ent


def _val(ent, key, default=""):
    return ent[key]["value"] if key in ent else default


def _line(kind, key, value, quote=""):
    """A new config line in the same form as its neighbours."""
    if kind == "colon":
        return ': "${%s:=%s}"' % (key, _esc_colon(value))
    return "%s=%s" % (key, _plain(value, quote))


def _esc_colon(v):
    return re.sub(r'([\\"$`])', r"\\\1", v)


def _plain(v, quote):
    if quote == '"':
        return '"%s"' % _esc_colon(v)
    if quote == "'":
        return "'%s'" % v.replace("'", "'\\''")
    return v if re.fullmatch(r"[A-Za-z0-9_./:@+,=-]*", v) else "'%s'" % v.replace("'", "'\\''")


def set_value(lines, e, new):
    """Replace the value of an existing line in place, keeping its quoting and trailing comment."""
    line, (s, t) = lines[e["idx"]], e["span"]
    if e["kind"] == "colon":
        lines[e["idx"]] = line[:s] + _esc_colon(new) + line[t:]
        return
    quote = line[s] if line[s:s + 1] in ("'", '"') else ""
    lines[e["idx"]] = line[:s] + _plain(new, quote) + line[t:]


def read_targets(path):
    rows, comments = [], []
    try:
        with open(path) as fh:
            for raw in fh.read().splitlines():
                if not raw.strip():
                    continue
                if raw.startswith("#"):
                    comments.append(raw)
                    continue
                f = raw.split("\t")
                if len(f) >= 2:
                    rows.append({"id": f[0], "repo": f[1], "raw": raw})
    except OSError:
        pass
    return rows, comments


def unit_safe(unit):
    """#554: a unit goes into tmux session names, where `.` and `:` break lookup. Same rule as lib.sh unit_safe:
    every character outside [A-Za-z0-9_-] becomes `_`; an already safe unit is returned unchanged."""
    return re.sub(r"[^A-Za-z0-9_-]", "_", unit)


def slug(repo, owner):
    return repo if "/" in repo or not owner else "%s/%s" % (owner, repo)


def _norm(url):
    u = url.strip()
    if u.endswith(".git"):
        u = u[:-4]
    u = re.sub(r"^.*[:/]([^/:]+/[^/:]+)$", r"\1", u)
    return u.lower()


def find_checkout(state, repo_slug):
    """The clone that already exists for this repo: .harness/checkouts/<repo short name> (where the
    multi layout puts it), else any clone there whose origin is the repo. Read from disk."""
    cdir = os.path.join(state, "checkouts")
    base = repo_slug.rsplit("/", 1)[-1]
    cand = os.path.join(cdir, base)
    if os.path.exists(os.path.join(cand, ".git")):
        return cand
    try:
        names = sorted(os.listdir(cdir))
    except OSError:
        names = []
    for n in names:
        d = os.path.join(cdir, n)
        if not os.path.exists(os.path.join(d, ".git")):
            continue
        r = subprocess.run(["git", "-C", d, "remote", "get-url", "origin"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True)
        if r.returncode == 0 and _norm(r.stdout) == repo_slug.lower():
            return d
    sys.stderr.write("fleet-migrate: no clone of %s under %s — using %s\n" % (repo_slug, cdir, cand))
    return cand


def _int(v, default, what):
    try:
        return int(v)
    except (TypeError, ValueError):
        if v not in ("", None):
            sys.stderr.write("fleet-migrate: HARNESS_%s=%r is not a number\n" % (what, v))
        return default


def cap_lines(lines):
    """Indexes of every live HARNESS_CAP assignment, in either line form (comments are left alone)."""
    return [i for i, l in enumerate(lines)
            if not l.lstrip().startswith("#") and (
                re.match(r'^\s*:\s+"\$\{HARNESS_CAP:=', l) or re.match(r'^\s*(?:export\s+)?HARNESS_CAP=', l))]


def backup(state, cfg, date):
    bak = os.path.join(state, "config.bak-" + date)
    n = 1
    while os.path.exists(bak):
        n += 1
        bak = os.path.join(state, "config.bak-%s.%d" % (date, n))
    shutil.copy2(cfg, bak)
    return bak


def write_config(state, cfg, out):
    fd, tmp = tempfile.mkstemp(dir=state, prefix=".config.")
    with os.fdopen(fd, "w") as fh:
        fh.write("\n".join(out))
    shutil.copymode(cfg, tmp)
    os.replace(tmp, cfg)


def emit(state, ent, **kv):
    stats = os.path.join(HERE, "stats.py")
    args = ["python3", stats, "emit", "fleet_migrated",
            "-c", "prefix=" + _val(ent, "HARNESS_SESS_PREFIX", "hz"),
            "-c", "project=" + os.path.dirname(state)]
    args += ["%s=%s" % (k, v) for k, v in kv.items() if v not in ("", None)]
    try:
        subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.SubprocessError):
        pass  # logging never blocks a migration


def migrate(state, date):
    state = os.path.abspath(state)
    cfg = os.path.join(state, "config")
    try:
        with open(cfg, encoding="utf-8-sig", errors="replace") as fh:   # #859: a BOM would hide the first key
            text = fh.read()
    except OSError as e:
        sys.stderr.write("fleet-migrate: cannot read %s: %s\n" % (cfg, e))
        return 2
    lines = text.split("\n")
    ent = parse(lines)
    topo_idx = [i for i, l in enumerate(lines) if not l.lstrip().startswith("#")
                and re.match(r'^\s*(?::\s+"\$\{|(?:export\s+)?)HARNESS_TOPOLOGY(?::=|=)', l)]
    cap_idx = cap_lines(lines)
    if not topo_idx and "HARNESS_UNIT" in ent:
        if not cap_idx:
            return 10
        # #469: a config #467 migrated keeps its HARNESS_CAP line; it is read by nothing now. Drop it, nothing else.
        old_pool = _int(_val(ent, "HARNESS_POOL"), DEFAULT_POOL, "POOL")
        bak = backup(state, cfg, date)
        write_config(state, cfg, [l for i, l in enumerate(lines) if i not in cap_idx])
        emit(state, ent, unit=_val(ent, "HARNESS_UNIT"), repo=slug(_val(ent, "HARNESS_REPO"), _val(ent, "HARNESS_OWNER")),
             checkout=_val(ent, "HARNESS_CHECKOUT"), pool=old_pool, old_pool=old_pool,
             cap=_int(_val(ent, "HARNESS_CAP"), DEFAULT_CAP, "CAP"), cap_dropped=1, backup=os.path.basename(bak))
        print("dropped HARNESS_CAP (CAP is gone; POOL=%d is the number of parallel issues) backup=%s" % (
            old_pool, os.path.basename(bak)))
        return 11

    owner = _val(ent, "HARNESS_OWNER")
    topology = _val(ent, "HARNESS_TOPOLOGY", "single")
    repo_cfg = _val(ent, "HARNESS_REPO")
    new_repo, dropped, keep = repo_cfg, [], None
    unit = _val(ent, "HARNESS_UNIT")
    checkout = _val(ent, "HARNESS_CHECKOUT")
    tsv = os.path.join(state, "targets.tsv")
    rows, comments = ([], [])
    if topology == "multi":
        rows, comments = read_targets(tsv)
        want = slug(repo_cfg, owner).lower()
        keep = next((r for r in rows if slug(r["repo"], owner).lower() == want), rows[0] if rows else None)
        if keep:
            new_repo = keep["repo"]
            unit = unit or keep["id"]
            dropped = [r for r in rows if r is not keep]
        checkout = checkout or find_checkout(state, slug(new_repo, owner))
    else:
        checkout = checkout or os.path.dirname(state)
    unit = unit_safe(unit) or "main"

    old_pool = _int(_val(ent, "HARNESS_POOL"), DEFAULT_POOL, "POOL")
    cap = _int(_val(ent, "HARNESS_CAP"), DEFAULT_CAP, "CAP")
    pool = max(old_pool, cap)

    # edit in place
    if new_repo and "HARNESS_REPO" in ent:
        if ent["HARNESS_REPO"]["value"] != new_repo:
            set_value(lines, ent["HARNESS_REPO"], new_repo)
    if "HARNESS_POOL" in ent and pool != old_pool:
        set_value(lines, ent["HARNESS_POOL"], str(pool))
    kind = (ent.get("HARNESS_REPO") or (ent.get(next(iter(ent))) if ent else None) or {}).get("kind")
    if topo_idx and "HARNESS_TOPOLOGY" in ent:
        kind = ent["HARNESS_TOPOLOGY"]["kind"]
    kind = kind or "colon"
    add = []
    if new_repo and "HARNESS_REPO" not in ent:
        add.append(_line(kind, "HARNESS_REPO", new_repo))
    if "HARNESS_UNIT" not in ent:
        add.append(_line(kind, "HARNESS_UNIT", unit))
    if "HARNESS_CHECKOUT" not in ent:
        add.append(_line(kind, "HARNESS_CHECKOUT", checkout))
    if "HARNESS_POOL" not in ent:
        add.append(_line(kind, "HARNESS_POOL", str(pool)))
    block = ["# fleet-migrate (#467): one fleet = one repo — the unit and its checkout replace the old multi-repo topology / targets.tsv."] + add

    if topo_idx:
        out = []
        for i, l in enumerate(lines):
            if i == topo_idx[0]:
                out += block
            elif i not in topo_idx:
                out.append(l)
    else:
        at = ent["HARNESS_REPO"]["idx"] + 1 if "HARNESS_REPO" in ent else None
        out = lines[:at] + block + lines[at:] if at is not None else (
            lines[:-1] + block + [""] if lines and lines[-1] == "" else lines + block)

    # HARNESS_CAP goes (#469); its value already went into POOL above. Looked up by text, not by index:
    # `out` has had its topology lines replaced and its new keys inserted.
    out = [l for l in out if l.lstrip().startswith("#") or l not in {lines[i] for i in cap_idx}]

    # back up, then write (atomically) — nothing above touched disk
    bak = backup(state, cfg, date)
    write_config(state, cfg, out)

    if dropped:
        mig = tsv + ".migrated"
        have = set()
        try:
            with open(mig) as fh:
                have = set(fh.read().splitlines())
        except OSError:
            pass
        with open(mig, "a") as fh:
            if not have:
                fh.write("# rows moved out of targets.tsv by fleet-migrate (#467): one fleet = one repo\n")
            for r in dropped:
                if r["raw"] not in have:
                    fh.write(r["raw"] + "\n")
        with open(tsv, "w") as fh:
            fh.write("\n".join(comments + [keep["raw"]]) + "\n")

    names = ",".join(r["id"] for r in dropped)
    emit(state, ent, unit=unit, repo=slug(new_repo, owner), checkout=checkout, topology=topology,
         pool=pool, cap=cap, old_pool=old_pool, dropped=names, backup=os.path.basename(bak))
    print("unit=%s repo=%s checkout=%s pool=%d->%d cap=%d%s backup=%s" % (
        unit, slug(new_repo, owner), checkout, old_pool, pool, cap,
        " dropped=" + names if names else "", os.path.basename(bak)))
    return 0


def fleets(d):
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return 0
    for n in names:
        if not n.endswith(".json"):
            continue
        try:
            with open(os.path.join(d, n)) as fh:
                p = json.load(fh).get("project")
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(p, str) and p:
            print(p)
    return 0


def main(argv):
    if len(argv) >= 2 and argv[0] == "fleets":
        return fleets(argv[1])
    if len(argv) >= 2 and argv[0] == "config":
        date = argv[argv.index("--date") + 1] if "--date" in argv else __import__("time").strftime("%Y%m%d")
        return migrate(argv[1], date)
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
