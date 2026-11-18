#!/usr/bin/env python3
"""fuzz.py -- differential fuzz of an arm's `tabula` against the reference implementation (#1257, PRD #345).

The hidden tests (bench/fixture-long/hidden/) are hand-picked; this feeds the arm and the reference
(bench/fixture-long/reference/) the SAME work folders and command lines and counts where they disagree. Same interface as
bench/fuzz.py (which delegates here for `--fixture long`):

    bench/fixture-long/fuzz.py --self                  # the reference against itself: must report 0 divergences
    bench/fixture-long/fuzz.py --cmd '["tabula"]'      # an arm's command line (JSON argv); default $TABULA_CMD
    bench/fixture-long/fuzz.py --cases 100 --cap 60    # the first 100 cases / a shorter time cap (defaults 300 / 300 s)

Prints one JSON object: {"fuzz_cases", "fuzz_divergences", "fuzz_examples" (up to 10), "fuzz_seed", "fuzz_hash"}.

A case is one or two small CSV files (any of LF/CRLF, a byte order mark, blank lines, quoted fields, numbers with signs and
decimals, empty cells, text) and one command line over them: each of the seven new commands with good and bad keys, columns,
conditions, aggregates and options, in either position of the option. Compared: the exit status; standard output exactly
for exit 0; for exit 1 that standard output is empty and standard error is not; nothing for exit 2 but the status and an
empty standard output. Left open by the brief and so never compared: the wording of messages, and which of two mistakes is
reported first (a case holds one mistake only).
"""
import argparse, hashlib, json, os, random, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
REFERENCE_DIR = os.path.join(HERE, "reference")
SEED, CASES, CAP_S = 1257, 300, 300
NAMES = ["id", "name", "qty", "price", "city", "k", "v"]
WORDS = ["ax", "by", "cz", "Bo", "ann", "Leeds", "x", "A", "a b", "é", "10", "9", "1.0", "01"]
NUMS = ["0", "1", "-3", "+5", "2.50", "10.5", "0.125", "1.005", "3.", ".5", "100", "7"]


def cell(r, numeric):
    if r.random() < 0.08:
        return ""
    return r.choice(NUMS) if numeric or r.random() < 0.3 else r.choice(WORDS)


def table(r, cols, rows, numeric_cols):
    lines = [",".join(cols)]
    for _ in range(rows):
        lines.append(",".join(cell(r, c in numeric_cols) for c in cols))
    nl = r.choice(["\n", "\n", "\r\n"])
    text = nl.join(lines) + r.choice([nl, ""])
    return (b"\xef\xbb\xbf" if r.random() < 0.1 else b"") + text.encode("utf-8")


def make_case(r, i):
    cols = r.sample(NAMES, r.randint(2, 4))
    nums = set(r.sample(cols, r.randint(1, len(cols))))
    files = {"a.csv": table(r, cols, r.randint(0, 8), nums)}
    col = lambda: r.choice(cols) if r.random() < 0.95 else "nope"
    kind = r.choice(["sort", "filter", "group", "join", "pivot", "dedupe", "stats"])
    if kind == "sort":
        keys = ["%s%s%s" % (col(), r.choice(["", ":num"]), r.choice(["", ":desc"])) for _ in range(r.randint(1, 2))]
        argv = ["sort", "a.csv"] + keys
    elif kind == "filter":
        conds = [col() + r.choice(["==", "!=", ">=", "<=", ">", "<", "~"]) + r.choice(WORDS + NUMS) for _ in range(r.randint(1, 2))]
        argv = ["filter", "a.csv"] + conds
    elif kind == "group":
        aggs = ["count"] + ["%s:%s" % (r.choice(["sum", "min", "max", "mean"]), col()) for _ in range(r.randint(0, 2))]
        argv = ["group", "a.csv", col()] + r.sample(aggs, len(aggs))
        if len(set(argv[3:])) != len(argv[3:]):
            argv = argv[:4]
    elif kind == "join":
        other = r.sample(NAMES, r.randint(2, 4))
        files["b.csv"] = table(r, other, r.randint(0, 6), set(NAMES))
        key = r.choice(sorted(set(cols) & set(other)) or cols)
        argv = ["join", "a.csv", "b.csv", key]
        if r.random() < 0.6:
            argv += ["--kind", r.choice(["inner", "left"])]
    elif kind == "pivot":
        argv = ["pivot", "a.csv"] + (r.sample(cols, 3) if len(cols) > 2 and r.random() < 0.8 else [col(), col(), col()])
    elif kind == "dedupe":
        argv = ["dedupe", "a.csv"] + [col() for _ in range(r.randint(1, 2))]
        if r.random() < 0.6:
            argv += ["--keep", r.choice(["first", "last"])]
    else:
        argv = ["stats", "a.csv"] + [col() for _ in range(r.randint(1, 2))]
    if r.random() < 0.5:
        argv += ["--format", r.choice(["text", "csv", "json"])]
    return {"id": i, "files": {k: v.hex() for k, v in files.items()}, "argv": argv}


def generate(n=CASES):
    r = random.Random(SEED)
    return [make_case(r, i) for i in range(n)]


def case_hash(cases):
    return hashlib.sha256(json.dumps(cases, sort_keys=True).encode()).hexdigest()


def run_case(cmd, env, case):
    with tempfile.TemporaryDirectory(prefix="tabulafuzz-") as work:
        for name, hx in case["files"].items():
            with open(os.path.join(work, name), "wb") as fh:
                fh.write(bytes.fromhex(hx))
        try:
            p = subprocess.run(cmd + case["argv"], cwd=work, env=env, capture_output=True, timeout=30)
            out, rc, err = p.stdout.decode("utf-8", "replace"), p.returncode, bool(p.stderr.strip())
        except subprocess.TimeoutExpired:
            out, rc, err = "", "timeout", False
        same = all(open(os.path.join(work, n), "rb").read() == bytes.fromhex(h) for n, h in case["files"].items())
        return {"exit": rc, "stdout": out if rc == 0 else "", "stderr": err, "untouched": same}


def differ(ref, arm):
    if ref["exit"] != arm["exit"]:
        return "exit status %s, wanted %s" % (arm["exit"], ref["exit"])
    if arm["stdout"] != ref["stdout"]:
        return "standard output differs"
    if ref["exit"] in (0, 1) and arm["stderr"] != ref["stderr"]:
        return "standard error is %s, wanted %s" % ("not empty" if arm["stderr"] else "empty", "not empty" if ref["stderr"] else "empty")
    if not arm["untouched"]:
        return "an input file was changed"
    return None


def run(cmd, env=None, cases=CASES, cap_s=CAP_S, reference=None):
    planned = generate(CASES)
    env = dict(os.environ if env is None else env, PYTHONIOENCODING="utf-8", PYTHONDONTWRITEBYTECODE="1")
    if reference is None:
        ref_cmd, ref_env = [sys.executable, "-m", "tabula"], dict(env, PYTHONPATH=REFERENCE_DIR)
        ref_env.pop("TABULA_CMD", None)
    else:
        ref_cmd, ref_env = reference
    deadline, found, ran = time.monotonic() + cap_s, [], 0
    for case in planned[:cases]:
        if time.monotonic() > deadline:
            break
        ran += 1
        why = differ(run_case(ref_cmd, ref_env, case), run_case(cmd, env, case))
        if why:
            found.append({"case": case["id"], "command": "tabula " + " ".join(case["argv"]), "why": why})
    return {"fuzz_cases": ran, "fuzz_divergences": len(found), "fuzz_examples": found[:10], "fuzz_seed": SEED,
            "fuzz_hash": case_hash(planned)}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Differential fuzz of a tabula command against the reference.")
    ap.add_argument("--cmd", help="the arm's command line, a JSON argv list (default: $TABULA_CMD)")
    ap.add_argument("--self", action="store_true", help="fuzz the reference against itself (0 divergences expected)")
    ap.add_argument("--cases", type=int, default=CASES)
    ap.add_argument("--cap", type=float, default=CAP_S, help="seconds before it stops starting new cases")
    a = ap.parse_args(argv)
    env = None
    if a.self:
        cmd, env = [sys.executable, "-m", "tabula"], dict(os.environ, PYTHONPATH=REFERENCE_DIR)
    else:
        raw = a.cmd or os.environ.get("TABULA_CMD")
        try:
            cmd = json.loads(raw) if raw else None
        except ValueError:
            cmd = None
        if not (isinstance(cmd, list) and cmd and all(isinstance(x, str) for x in cmd)):
            print("fuzz.py: give --cmd '[\"tabula\"]' (or set TABULA_CMD), or --self", file=sys.stderr)
            return 2
    print(json.dumps(run(cmd, env, a.cases, a.cap), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
