#!/usr/bin/env python3
"""fuzz.py — differential fuzz of an arm's `pennywise` against the reference implementation (PRD #345, #589).

The hidden tests (bench/fixture/hidden/) are 80 hand-picked cases that two very different arms both pass, so
they cannot tell the arms apart. This feeds the arm and the reference (bench/fixture/reference/) the SAME
random argv and ledger files and counts where they disagree, without tuning anything to a bug already found.

    bench/fuzz.py --self                  # the reference against itself: must report 0 divergences
    bench/fuzz.py --cmd '["pennywise"]'   # an arm's command line (JSON argv); default $PENNYWISE_CMD
    bench/fuzz.py --cases 200 --cap 60    # fewer cases / a shorter time cap (the defaults are 1000 / 300 s)

Prints one JSON object (exit 0; 2 for bad arguments or a generator that no longer matches its frozen hash):

    {"fuzz_cases": N, "fuzz_divergences": N, "fuzz_examples": [up to 10], "fuzz_seed": 589, "fuzz_hash": "…"}

What is compared, per case: standard output, whether standard error is empty, the exit status, and the
ledger file afterwards (for `add`). Normalised where the brief leaves room: `summary` pads names with "some
spaces", and JSON is compared as data. A case whose standard output is a closed pipe (`pennywise list | head -1`)
compares only that standard error stays empty and the file: the brief gives no status for it.

The generator is FROZEN: its own PRNG (no `random` module, so Python's version cannot change it), the seed
and the case list's SHA-256 (FROZEN_HASH). Change the generator and `fuzz.py` refuses to run until SEED /
FROZEN_HASH are updated on purpose; that is a different measurement, so re-grade the runs you compare.
Stdlib only.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
REFERENCE_DIR = os.path.join(HERE, "fixture", "reference")

SEED = 589
CASES = 1000
CAP_S = 300
RUN_TIMEOUT = 20
WORKERS = 4
CHUNK = 16
MAX_EXAMPLES = 10
LEDGER = "ledger.txt"
FROZEN_HASH = "015f0f31f7319a85b203a496d1b09127dd9d3e59c08e592563e0bd880181d478"


# --- the frozen generator ----------------------------------------------------------------
class Rng:
    """splitmix64: the same stream on every Python."""

    def __init__(self, seed):
        self.x = seed & 0xFFFFFFFFFFFFFFFF

    def next(self):
        self.x = (self.x + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
        z = self.x
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & 0xFFFFFFFFFFFFFFFF
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & 0xFFFFFFFFFFFFFFFF
        return z ^ (z >> 31)

    def below(self, n):
        return self.next() % n

    def pct(self, p):
        return self.below(100) < p

    def pick(self, seq):
        return seq[self.below(len(seq))]


CATEGORIES = ["food", "Rent", "SALARY", "fun", "gas", "Caf\xe9", "x1", "a_b", "k-n", "Food"]
BAD_DATES = ["2024-02-30", "2023-02-29", "2024-13-01", "2024-00-10", "24-01-01", "2024-1-1", "2024/01/01",
             "20240101", "yesterday", "2024-01-01x", ""]
GOOD_AMOUNTS = ["12", "12.5", "-0.99", "+2500", "2500.00", "-42.50", "007", "0", "0.00", "-0", "+0.5",
                "100000000.99", "-5", "3.1", "-1000"]
BAD_AMOUNTS = ["12.505", "1,000.00", "abc", "1e3", ".5", "5.", "--5", "+-5", "- 5", "1.2.3", "12.", "NaN",
               "inf", "-", "+", "0x10"]
# Every note starts with an ordinary character: a leading form feed would be a separator or note text by taste.
NOTES = ["", "weekly shop", "  spaced  note ", "tab\tinside", "# not a comment", "-refund", "unicode \u2603 \xe9",
         "form\ffeed", "line\u2028sep", "para\u2029sep", "vt\x0bx", "nel\x85x", "a  b", "x", "March pay",
         "-5", "--flag", "(note)"]
DASH_NOTES = ["-refund", "--note", "-", "-5", "- x", "-x y", "-0.5 back"]
DASH_AMOUNTS = ["-5", "-0.99", "-abc", "-", "-5x", "+5", "-.5", "-0", "--5"]
SEPS = [" ", "  ", "\t", " \t ", "   ", "\t\t"]
PAD = ["", "", "", " ", "\t", "  "]
EOLS = ["\n", "\r\n", "\r"]
BAD_BYTES = [b"\xff", b"\xc3\x28", b"\xe2\x82", b"\x80", b"\xfe\xff"]
COMMENTS = ["# household, March", "#", "  # indented", "#2024-01-01 a 5", "#\tx"]
BLANKS = ["", "", "  ", "\t", " \t "]
SHORT_LINES = ["2024-01-01 food", "word", "2024-01-01", "2024-01-01 food  "]
UNKNOWN_COMMANDS = ["frobnicate", "Balance", "ls", "adds"]
BAD_OPTIONS = [["--bogus"], ["--by", "weekly"], ["--format", "json"], ["--since"], ["--category"], ["extra"],
               ["--until", "2024-02-30"], ["--since", "yesterday"]]


def date(r):
    if r.pct(2):
        return r.pick(BAD_DATES)
    return "%d-%02d-%02d" % (2023 + r.below(3), 1 + r.below(12), 1 + r.below(28 if r.pct(90) else 31))


def good_date(r):
    return "%d-%02d-%02d" % (2023 + r.below(3), 1 + r.below(12), 1 + r.below(28))


def amount(r):
    if r.pct(40):
        return r.pick(GOOD_AMOUNTS)
    sign = r.pick(["", "-", "-", "+"])
    frac = r.pick(["", ".%d" % r.below(10), ".%02d" % r.below(100)])
    return "%s%d%s" % (sign, r.below(5000), frac)


def entry_line(r, bad):
    d, c, a, n = date(r), r.pick(CATEGORIES), amount(r), r.pick(NOTES)
    if not bad:
        d = good_date(r) if d in BAD_DATES or not re.fullmatch(r"\d{4}-\d\d-\d\d", d) else d
    if bad:
        which = r.below(3)
        if which == 0:
            d = r.pick(BAD_DATES)
        elif which == 1:
            a = r.pick(BAD_AMOUNTS)
    seps = [r.pick(SEPS) for _ in range(3)]
    fields = d + seps[0] + c + seps[1] + a + ((seps[2] + n) if n else "")
    return r.pick(PAD) + fields + r.pick(PAD if not n else [""])


def ledger_text(r, with_bad):
    lines = []
    for _ in range(r.below(13)):
        k = r.below(100)
        if k < 70:
            lines.append(entry_line(r, False))
        elif k < 80:
            lines.append(r.pick(BLANKS))
        else:
            lines.append(r.pick(COMMENTS))
    if with_bad:
        bad = r.pick([entry_line(r, True), r.pick(SHORT_LINES)])
        lines.insert(r.below(len(lines) + 1), bad)
    mode = r.below(100)
    eol = r.pick(EOLS) if mode < 60 else None            # None: a mix, line by line
    out = ""
    for i, line in enumerate(lines):
        out += line
        if i < len(lines) - 1 or r.pct(80):
            out += eol if eol is not None else r.pick(EOLS)
    return out


def ledger_bytes(r, with_bad):
    data = ledger_text(r, with_bad).encode("utf-8")
    k = r.below(100)
    if k < 12:
        data = b"\xef\xbb\xbf" + data
    elif k < 17:
        at = r.below(len(data) + 1)
        data = data[:at] + r.pick(BAD_BYTES) + data[at:]
    elif k < 18:
        data = data.decode("utf-8").encode("utf-16")
    return data


def read_args(r):
    """argv for balance / summary / list / export on LEDGER, "-" or a path that is not there."""
    cmd = r.pick(["balance", "summary", "list", "export", "list", "summary"])
    opts = []
    if cmd == "summary" and r.pct(60):
        opts += ["--by", r.pick(["category", "month"])]
    if cmd == "list":
        if r.pct(40):
            opts += ["--category", r.pick(CATEGORIES + ["nothing", "FOOD"])]
        if r.pct(30):
            opts += ["--since", good_date(r)]
        if r.pct(30):
            opts += ["--until", good_date(r)]
    if cmd == "export" and r.pct(50):
        opts += ["--format", "csv"]
    if cmd in ("balance", "summary", "list") and r.pct(40):
        opts.append("--json")
    if r.pct(5):
        opts += r.pick(BAD_OPTIONS)
    where = r.below(100)
    src = LEDGER if where < 70 else "-" if where < 90 else r.pick(["missing.txt", "."])
    if where >= 97:
        return [cmd] + opts, src
    sep = ["--"] if r.pct(12) and src != "-" else []
    return [cmd] + opts + sep + [src], src


def add_args(r):
    d = date(r) if r.pct(80) else good_date(r)
    c = r.pick(CATEGORIES + ["-x", "a b", "", "Caf\xe9"]) if r.pct(50) else r.pick(CATEGORIES)
    a = r.pick(DASH_AMOUNTS) if r.pct(30) else (r.pick(BAD_AMOUNTS) if r.pct(15) else amount(r))
    n = r.pick(DASH_NOTES) if r.pct(30) else r.pick(NOTES)
    args = [LEDGER, d, c, a] + ([n] if n or r.pct(10) else [])
    if r.pct(6):
        args.append("extra")
    if r.pct(20):
        args.insert(r.pick([0, 1, 3, 4]) if len(args) > 4 else r.pick([0, 1, 3]), "--")
    return ["add"] + args


def make_case(r, index):
    kind = r.below(100)
    stdin_hex = ledger_hex = None
    if kind < 22:
        argv, src = add_args(r), LEDGER
        if r.pct(70):
            ledger_hex = ledger_bytes(r, False).hex()
    elif kind < 24:
        argv, src = [r.pick(UNKNOWN_COMMANDS), LEDGER], LEDGER
    elif kind < 25:
        argv, src = [], LEDGER
    else:
        argv, src = read_args(r)
        data = ledger_bytes(r, r.pct(35)).hex()
        if src == "-":
            stdin_hex = data
        elif src == LEDGER:
            ledger_hex = data
    closed = argv[:1] != [] and r.pct(8)
    return {"id": index, "argv": argv, "ledger_hex": ledger_hex, "stdin_hex": stdin_hex, "closed_stdout": closed}


def generate(n=CASES, seed=SEED):
    r = Rng(seed)
    return [make_case(r, i) for i in range(n)]


def case_hash(cases):
    blob = json.dumps(cases, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(blob.encode("ascii")).hexdigest()


# --- running a case ----------------------------------------------------------------------
def line_list(data):
    """A ledger file as its non-empty lines, whatever the line endings: what `add` leaves behind."""
    return [x for x in re.split(r"\r\n|\r|\n", data.decode("utf-8", "backslashreplace")) if x]


def run_one(cmd, env, case):
    work = tempfile.mkdtemp(prefix="fuzz-")
    try:
        path = os.path.join(work, LEDGER)
        if case["ledger_hex"] is not None:
            with open(path, "wb") as fh:
                fh.write(bytes.fromhex(case["ledger_hex"]))
        stdin = bytes.fromhex(case["stdin_hex"]) if case["stdin_hex"] is not None else None
        pipe = None
        out = subprocess.PIPE
        if case["closed_stdout"]:
            r, pipe = os.pipe()
            os.close(r)             # nobody reads: the first write fails with a broken pipe
            out = pipe
        try:
            p = subprocess.run(cmd + case["argv"], cwd=work, env=env, input=stdin, stdout=out,
                               stderr=subprocess.PIPE, stdin=None if stdin is not None else subprocess.DEVNULL,
                               timeout=RUN_TIMEOUT)
            res = {"exit": p.returncode, "stdout": (p.stdout or b"").decode("utf-8", "backslashreplace"),
                   "stderr_empty": not p.stderr.strip(), "stderr": p.stderr.decode("utf-8", "backslashreplace")[-300:]}
        except subprocess.TimeoutExpired:
            res = {"exit": "timeout", "stdout": "", "stderr_empty": False, "stderr": "timeout"}
        except OSError as exc:
            res = {"exit": "oserror", "stdout": "", "stderr_empty": False, "stderr": str(exc)[:300]}
        finally:
            if pipe is not None:
                os.close(pipe)
        res["file"] = line_list(open(path, "rb").read()) if os.path.isfile(path) else None
        return res
    finally:
        shutil.rmtree(work, ignore_errors=True)


def canon(case, res):
    """What of a result counts. The brief leaves the padding of `summary` and JSON formatting open."""
    if case["closed_stdout"]:
        return {"stderr_empty": res["stderr_empty"], "file": res["file"]}
    out = res["stdout"]
    argv = case["argv"]
    if "--json" in argv:
        try:
            out = json.dumps(json.loads(out, object_pairs_hook=lambda kv: [list(x) for x in kv]), sort_keys=False)
        except ValueError:
            pass
    elif argv[:1] == ["summary"]:
        out = "\n".join(re.sub(r" +", " ", x) for x in out.split("\n"))
    return {"exit": res["exit"], "stdout": out, "stderr_empty": res["stderr_empty"], "file": res["file"]}


def show(text, limit=200):
    text = text.encode("unicode_escape").decode("ascii") if isinstance(text, str) else text
    return text if len(text) <= limit else text[:limit] + "…"


def example(case, ref, arm):
    ledger = case["stdin_hex"] if case["stdin_hex"] is not None else case["ledger_hex"]
    return {
        "case": case["id"], "argv": case["argv"],
        "ledger": None if ledger is None else show(bytes.fromhex(ledger).decode("utf-8", "backslashreplace")),
        "ledger_from": "stdin" if case["stdin_hex"] is not None else "file" if ledger is not None else None,
        "closed_stdout": case["closed_stdout"],
        "reference": {k: (show(v) if isinstance(v, str) else v) for k, v in ref.items() if k != "stderr"},
        "arm": {k: (show(v) if isinstance(v, str) else v) for k, v in arm.items() if k != "stderr"},
        "arm_stderr": show(arm["stderr"]),
    }


def signature(case, ref, arm):
    return (tuple(case["argv"][:1]), ref["exit"], arm["exit"], ref["stdout"] == arm["stdout"], arm["stderr_empty"])


def pick_examples(found):
    """Up to MAX_EXAMPLES: one per distinct kind of disagreement first, then the rest in case order."""
    seen, first, rest = set(), [], []
    for sig, ex in found:
        (rest if sig in seen else first).append(ex)
        seen.add(sig)
    return (first + rest)[:MAX_EXAMPLES]


def run(cmd, env=None, cases=CASES, cap_s=CAP_S, reference=None):
    """The fragment for `cmd` (an argv list) against the reference. `reference` is (argv, env) of the oracle."""
    planned = generate(CASES)
    digest = case_hash(planned)
    if digest != FROZEN_HASH:
        raise SystemExit("fuzz.py: the generator changed (case hash %s, frozen %s): update SEED / FROZEN_HASH "
                         "on purpose, or revert it" % (digest, FROZEN_HASH))
    env = dict(os.environ if env is None else env, PYTHONIOENCODING="utf-8", PYTHONDONTWRITEBYTECODE="1")
    if reference is None:
        ref_cmd = [sys.executable, "-m", "pennywise"]
        ref_env = dict(env, PYTHONPATH=REFERENCE_DIR)
        ref_env.pop("PENNYWISE_CMD", None)
    else:
        ref_cmd, ref_env = reference
    deadline = time.monotonic() + cap_s
    found, ran = [], 0
    todo = planned[:cases]
    with ThreadPoolExecutor(WORKERS) as pool:
        for at in range(0, len(todo), CHUNK):
            if ran and time.monotonic() > deadline:
                break
            chunk = todo[at:at + CHUNK]
            both = list(pool.map(lambda c: (run_one(ref_cmd, ref_env, c), run_one(cmd, env, c)), chunk))
            for case, (ref, arm) in zip(chunk, both):
                ran += 1
                a, b = canon(case, ref), canon(case, arm)
                if a != b:
                    found.append((signature(case, ref, arm), example(case, ref, arm)))
    return {"fuzz_cases": ran, "fuzz_divergences": len(found), "fuzz_examples": pick_examples(found),
            "fuzz_seed": SEED, "fuzz_hash": digest}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Differential fuzz of a pennywise command against the reference.")
    ap.add_argument("--cmd", help="the arm's command line, a JSON argv list (default: $PENNYWISE_CMD)")
    ap.add_argument("--self", action="store_true", help="fuzz the reference against itself (0 divergences expected)")
    ap.add_argument("--cases", type=int, default=CASES)
    ap.add_argument("--cap", type=float, default=CAP_S, help="seconds before it stops starting new cases")
    ap.add_argument("--print-hash", action="store_true", help="print the generator's case hash and exit")
    a = ap.parse_args(argv)
    if a.print_hash:
        print(case_hash(generate(CASES)))
        return 0
    env = None
    if a.self:
        cmd = [sys.executable, "-m", "pennywise"]
        env = dict(os.environ, PYTHONPATH=REFERENCE_DIR)
    else:
        raw = a.cmd or os.environ.get("PENNYWISE_CMD")
        try:
            cmd = json.loads(raw) if raw else None
        except ValueError:
            cmd = None
        if not (isinstance(cmd, list) and cmd and all(isinstance(x, str) for x in cmd)):
            print("fuzz.py: give --cmd '[\"pennywise\"]' (or set PENNYWISE_CMD), or --self", file=sys.stderr)
            return 2
    print(json.dumps(run(cmd, env, a.cases, a.cap), indent=2, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
