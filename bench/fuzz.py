#!/usr/bin/env python3
"""fuzz.py — differential fuzz of an arm's `pennywise` against the reference implementation (PRD #345, #589, #620).

The hidden tests (bench/fixture/hidden/) are 80 hand-picked cases that two very different arms both pass, so
they cannot tell the arms apart. This feeds the arm and the reference (bench/fixture/reference/) the SAME
random argv and ledger files and counts where they disagree, without tuning anything to a bug already found.

The cases come from bench/fixture/fuzzgen.py, a BLIND generator (#620): written from the brief and the reference
implementation only, before any arm's output was seen, so a fleet tuned to a checklist of known bugs gains nothing on it.
(The first generator, #589, was written after the Harness arm's bugs were known and so was not blind; it is replaced.)
Besides the raw count the run reports root-cause CLASSES (bench/rootcause.py): one class per (input feature, what
differed), so one bug that a hundred cases reach is one class, not a hundred.

    bench/fuzz.py --self                  # the reference against itself: must report 0 divergences
    bench/fuzz.py --cmd '["pennywise"]'   # an arm's command line (JSON argv); default $PENNYWISE_CMD
    bench/fuzz.py --cases 200 --cap 60    # fewer cases / a shorter time cap (the defaults are 1000 / 300 s)
    bench/fuzz.py --fixture large --self  # another fixture's fuzz (#592): bench/fixture-large/fuzz.py, same options

Prints one JSON object (exit 0; 2 for bad arguments or a generator that no longer matches its frozen hash):

    {"fuzz_cases": N, "fuzz_divergences": N, "fuzz_classes": N, "fuzz_class_counts": {"<feature> x <difference>": N, …},
     "fuzz_examples": [up to 10], "fuzz_seed": 620, "fuzz_hash": "…"}

What is compared, per case: standard output, whether standard error is empty, the exit status, and the
ledger file afterwards (for `add`). Normalised where the brief leaves room: `summary` pads names with "some
spaces", JSON is compared as data, and `export` may end its CSV lines in LF or CRLF. A case whose standard output is a closed pipe (`pennywise list | head -1`)
compares only that standard error stays empty and the file: the brief gives no status for it.

The generator is FROZEN: its own PRNG (no `random` module, so Python's version cannot change it), the seed
and the case list's SHA-256 (FROZEN_HASH). Change the generator and `fuzz.py` refuses to run until SEED /
FROZEN_HASH are updated on purpose; that is a different measurement, so re-grade the runs you compare.
Stdlib only.
"""
import argparse
import hashlib
import importlib.util
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

SEED = 620
CASES = 1000
CAP_S = 300
RUN_TIMEOUT = 20
WORKERS = 4
CHUNK = 16
MAX_EXAMPLES = 10
LEDGER = "ledger.txt"
PROVENANCE = ("blind: bench/fixture/fuzzgen.py was written from the brief and the reference implementation only (#620), "
              "before any arm's output on it was seen; it replaced the #589 generator, which was written after the "
              "Harness arm's bugs were known")
FROZEN_HASH = "5c7f3fbfa079d0caa1236e37f3fd06f0f45dc75f15b6087d4060c04ab80d5f87"


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


def _generator():
    """bench/fixture/fuzzgen.py, the blind case generator, loaded by path (it is data next to the brief, not a library)."""
    spec = importlib.util.spec_from_file_location("bench_fuzzgen", os.path.join(HERE, "fixture", "fuzzgen.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def generate(n=CASES, seed=SEED):
    """The first `n` planned cases: fixture/fuzzgen.py's, a prefix of any longer plan with the same seed."""
    return _generator().generate(n, seed)


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
    elif argv[:1] == ["export"]:
        out = out.replace("\r\n", "\n")
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


def rootcause():
    """bench/rootcause.py, loaded by path (the fuzz modules of the other fixtures load it the same way)."""
    spec = importlib.util.spec_from_file_location("bench_rootcause", os.path.join(HERE, "rootcause.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def ledger_of(case):
    """The ledger bytes a case hands the tool (standard input or the file), or None."""
    hexed = case["stdin_hex"] if case["stdin_hex"] is not None else case["ledger_hex"]
    return None if hexed is None else bytes.fromhex(hexed)


def features(case):
    """The input quirks of a case (bench/rootcause.py). Only what is odd about the input: a feature every case
    shares would explain every divergence and hide the real causes. A case with none is labelled by its command."""
    argv, found = case["argv"], set()
    data = ledger_of(case)
    if data is not None:
        if data.startswith(b"\xef\xbb\xbf"):
            found.add("ledger:byte-order-mark")
        if data.startswith((b"\xff\xfe", b"\xfe\xff")):
            found.add("ledger:utf-16")
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            found.add("ledger:invalid-utf8")
            text = data.decode("utf-8", "replace")
        if "\r" in text.replace("\r\n", ""):
            found.add("ledger:lone-cr")
        if "\r\n" in text:
            found.add("ledger:crlf")
        if text and not text.endswith(("\n", "\r")):
            found.add("ledger:no-final-newline")
        if not text.strip():
            found.add("ledger:empty")
        if any(ch in text for ch in "\f\v\x85\u2028\u2029\x1c\x1d\x1e"):
            found.add("ledger:unicode-line-separator")
        if any(ord(ch) > 127 for ch in text.replace("\u2028", "").replace("\u2029", "").replace("\x85", "")):
            found.add("ledger:non-ascii")
        if "\t" in text:
            found.add("ledger:tab")
        if any(x.startswith("#") or x.lstrip().startswith("#") for x in re.split(r"\r\n|\r|\n", text)):
            found.add("ledger:comment")
        if any(x != x.strip() and x.strip() for x in re.split(r"\r\n|\r|\n", text)):
            found.add("ledger:padded-line")
    rest = argv[1:]
    if case["closed_stdout"]:
        found.add("output:closed-pipe")
    if "--" in rest:
        found.add("argv:double-dash")
    if argv[:1] == ["add"]:
        if any(x.startswith("-") and x != "--" for x in rest[1:]):
            found.add("argv:dash-led-argument")
        if len(rest) > 5:
            found.add("argv:extra-argument")
    if "-" in rest and argv[:1] != ["add"]:
        found.add("argv:stdin")
    if not argv:
        found.add("argv:no-command")
    elif argv[0] not in ("balance", "summary", "list", "add", "export"):
        found.add("argv:unknown-command")
    if any(x.startswith("--") and x not in ("--", "--json", "--by", "--category", "--since", "--until", "--format")
           for x in rest):
        found.add("argv:unknown-option")
    if argv[:1] != ["add"] and any(os.sep in x or x in ("missing.txt", ".") for x in rest if not x.startswith("-")):
        found.add("argv:unreadable-file")
    return found or {"command:%s" % (argv[0] if argv else "none")}


def execute(planned, cmd, env, reference, cap_s):
    """Run `planned` cases through the reference and `cmd`: ([(signature, example, (features, difference))] for each case
    where they disagree, how many cases ran, {feature: cases that have it} over all that ran)."""
    deadline = time.monotonic() + cap_s
    found, ran, population = [], 0, {}
    rc = rootcause()
    ref_cmd, ref_env = reference
    with ThreadPoolExecutor(WORKERS) as pool:
        for at in range(0, len(planned), CHUNK):
            if ran and time.monotonic() > deadline:
                break
            chunk = planned[at:at + CHUNK]
            both = list(pool.map(lambda c: (run_one(ref_cmd, ref_env, c), run_one(cmd, env, c)), chunk))
            for case, (ref, arm) in zip(chunk, both):
                ran += 1
                feats = features(case)
                for f in feats:
                    population[f] = population.get(f, 0) + 1
                a, b = canon(case, ref), canon(case, arm)
                if a != b:
                    found.append((signature(case, ref, arm), example(case, ref, arm), (feats, rc.diff_kind(a, b))))
    return found, ran, population


def fragment(found, ran, digest, population=None, seed=None):
    """The fuzz fragment: raw divergences, the root-cause classes (bench/rootcause.py, #620) and up to 10 examples."""
    classes = rootcause().classify([items for _, _, items in found], population)
    return {"fuzz_cases": ran, "fuzz_divergences": len(found), "fuzz_classes": classes["classes"],
            "fuzz_class_counts": classes["class_counts"],
            "fuzz_examples": pick_examples([(sig, ex) for sig, ex, _ in found]),
            "fuzz_seed": SEED if seed is None else seed, "fuzz_hash": digest}


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
        reference = (ref_cmd, ref_env)
    found, ran, population = execute(planned[:cases], cmd, env, reference, cap_s)
    return fragment(found, ran, digest, population)


def other_fixture(argv):
    """`--fixture NAME` (#592): (fuzz module of that fixture, argv without the option); (None, argv) for pennywise."""
    if "--fixture" not in argv:
        return None, argv
    at = argv.index("--fixture")
    name = argv[at + 1] if at + 1 < len(argv) else ""
    rest = argv[:at] + argv[at + 2:]
    spec = importlib.util.spec_from_file_location("bench_fixtures", os.path.join(HERE, "fixtures.py"))
    fixtures = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixtures)
    try:
        fx = fixtures.load(name)
    except ValueError as exc:
        raise SystemExit("fuzz.py: %s" % exc)
    if os.path.abspath(fx.fuzz) == os.path.abspath(__file__):
        return None, rest
    spec = importlib.util.spec_from_file_location("bench_fuzz_%s" % fx.name, fx.fuzz)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod, rest


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        mod, argv = other_fixture(argv)
    except SystemExit as exc:
        print(exc, file=sys.stderr)
        return 2
    if mod is not None:
        return mod.main(argv)
    ap = argparse.ArgumentParser(description="Differential fuzz of a pennywise command against the reference.")
    ap.add_argument("--fixture", help="another fixture's fuzz (bench/fixtures.py): large; default pennywise")
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
