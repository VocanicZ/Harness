#!/usr/bin/env python3
# harness-test-timeout-windows: 5400
"""test_bench_fuzz.py — #589, #620 (PRD #345): bench/fuzz.py, the differential fuzz of an arm's pennywise against the
reference implementation. Covered: the generator (bench/fixture/fuzzgen.py, the BLIND one of #620) is deterministic and
FROZEN (a pinned case hash; a change makes the fuzz refuse to run) and says how it was written; it covers the shapes the
brief names; the reference has 0 divergences against itself; a copy of the reference with a bug the brief pins put back
is caught and is ONE root-cause class; the example list, the time cap, the closed-pipe and normalisation rules; and the
command line."""
import contextlib, io, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "bench"))
sys.dont_write_bytecode = True
import fuzz                                         # noqa: E402

REF = fuzz.REFERENCE_DIR
PINNED = "5c7f3fbfa079d0caa1236e37f3fd06f0f45dc75f15b6087d4060c04ab80d5f87"
SELF_CMD = [sys.executable, "-m", "pennywise"]
BOM_CLI = ("cli.py", 'data.decode("utf-8-sig")', 'data.decode("utf-8")')
BOM_LEDGER = ("ledger.py", 'text[1:] if text.startswith("\\ufeff") else text', "text")


def env_for(path):
    return dict(os.environ, PYTHONPATH=path)


def copy_reference(dest):
    shutil.copytree(REF, dest, ignore=shutil.ignore_patterns("__pycache__"))
    return dest


def patched(dest, rel, old, new):
    p = os.path.join(dest, "pennywise", rel)
    text = open(p, encoding="utf-8").read()
    assert old in text, (rel, old)
    open(p, "w", encoding="utf-8").write(text.replace(old, new))


def test_the_generator_is_frozen():
    assert fuzz.FROZEN_HASH == PINNED, "the generator changed: that is a different measurement (see fuzz.py)"
    cases = fuzz.generate()
    assert len(cases) == fuzz.CASES == 1000 and fuzz.SEED == 620
    assert fuzz.case_hash(cases) == fuzz.FROZEN_HASH == PINNED
    assert fuzz.generate() == cases                                   # deterministic
    assert fuzz.generate(40) == cases[:40]                            # a prefix, so a smaller run is the same cases


def test_the_prng_does_not_depend_on_the_python_version():
    assert fuzz.Rng(1).next() == 10451216379200822465 and fuzz.Rng(0).next() == 16294208416658607535


def test_a_changed_generator_is_refused():
    real = fuzz.FROZEN_HASH
    fuzz.FROZEN_HASH = "0" * 64
    try:
        try:
            fuzz.run(SELF_CMD, env_for(REF), cases=1)
        except SystemExit as exc:
            assert "generator changed" in str(exc)
        else:
            raise AssertionError("ran with a generator that no longer matches its frozen hash")
    finally:
        fuzz.FROZEN_HASH = real


def test_the_cases_cover_the_shapes_the_brief_names():
    cases = fuzz.generate()
    led = [bytes.fromhex(c["ledger_hex"]) for c in cases if c["ledger_hex"] is not None]
    led += [bytes.fromhex(c["stdin_hex"]) for c in cases if c["stdin_hex"] is not None]
    argvs = [c["argv"] for c in cases]

    def has(pred):
        return any(pred(x) for x in led)

    def decodes(b):
        try:
            b.decode("utf-8")
            return True
        except UnicodeDecodeError:
            return False
    assert has(lambda b: b.startswith(b"\xef\xbb\xbf")), "BOM"
    assert has(lambda b: not decodes(b)), "invalid UTF-8"
    assert has(lambda b: b"\r\n" in b), "CRLF"
    assert has(lambda b: b"\r" in b.replace(b"\r\n", b"")), "lone CR"
    assert has(lambda b: b"\n" in b.replace(b"\r\n", b"")), "LF"
    assert has(lambda b: b and not b.endswith((b"\n", b"\r"))), "no final newline"
    assert has(lambda b: b == b""), "empty ledger"
    assert has(lambda b: b"\t" in b) and has(lambda b: any(ord(c) > 127 for c in b.decode("utf-8", "replace"))), "tab, non-ASCII"
    assert any(a[:1] == ["add"] and any(x.startswith("-") and x != "--" for x in a[2:]) for a in argvs), "dash-led add"
    assert any(c["stdin_hex"] is not None and c["argv"][-1] == "-" for c in cases), "stdin"
    assert any(c["ledger_hex"] is not None and c["argv"][-1] == fuzz.LEDGER for c in cases), "file"
    assert sum(c["closed_stdout"] for c in cases) >= 10, "closed stdout"
    assert {"balance", "summary", "list", "export", "add"} <= {a[0] for a in argvs if a}
    assert any(a == [] for a in argvs) and any(a[:1] and a[0] not in ("balance", "summary", "list", "export", "add") for a in argvs)
    opts = {x for a in argvs for x in a if x.startswith("--")}
    assert {"--json", "--by", "--category", "--since", "--until", "--format"} <= opts, opts
    assert all(set(c) == {"id", "argv", "ledger_hex", "stdin_hex", "closed_stdout"} for c in cases)


def test_the_generator_is_blind_and_says_so():
    """The blind generator reads nothing but its own tables: no arm output, results, tests or earlier generator."""
    path = os.path.join(ROOT, "bench", "fixture", "fuzzgen.py")
    src = open(path, encoding="utf-8").read()
    imports = {l.split()[1].split(".")[0] for l in src.splitlines() if l.startswith(("import ", "from "))}
    assert imports <= {"datetime"}, imports                                    # no file, process or result is read
    for forbidden in ("bench/results", "results/", "open(", "subprocess", "fuzz.py", "hidden"):
        assert forbidden not in src.replace("fuzzgen.py", ""), forbidden
    head = src[:900]
    assert "brief" in head and "reference implementation" in head and "before looking at any" in head, head
    assert "blind" in fuzz.PROVENANCE and "before any arm" in fuzz.PROVENANCE and "#620" in fuzz.PROVENANCE


def test_the_reference_has_no_divergences_against_itself():
    r = fuzz.run(SELF_CMD, env_for(REF), cases=300)
    assert r["fuzz_cases"] == 300 and r["fuzz_divergences"] == 0 and r["fuzz_examples"] == [], r
    assert (r["fuzz_seed"], r["fuzz_hash"]) == (620, PINNED)
    assert r["fuzz_classes"] == 0 and r["fuzz_class_counts"] == {}, r


def test_each_bug_the_brief_pins_put_back_into_the_reference_is_caught_as_one_class():
    # form feed / U+2028 as a line end (the old fifth bug) is not here: the brief does not pin it, so a generator written
    # from the brief alone rightly does not reach it. These four are rare in 1000 cases (4 to 11 each), hence all of them.
    bugs = {
        "BOM rejected": ([BOM_CLI, BOM_LEDGER], "ledger:byte-order-mark"),
        "lone CR is no line end": ([("ledger.py", 'r"\\r\\n|\\r|\\n"', 'r"\\r\\n|\\n"')], "ledger:lone-cr"),
        "traceback on a closed pipe": ([("cli.py", "except BrokenPipeError:", "except ZeroDivisionError:")],
                                       "output:closed-pipe"),
        "dash-led add arguments are options": ([("cli.py", "args = (_add_args(argv) if argv[:1] == [\"add\"] else None)",
                                                 "args = (None)")], "argv:dash-led-argument"),
    }
    with tempfile.TemporaryDirectory() as tmp:
        clean = copy_reference(os.path.join(tmp, "clean"))
        r = fuzz.run(SELF_CMD, env_for(clean), cases=250)
        assert r["fuzz_divergences"] == 0, r["fuzz_examples"][:2]       # a copy alone is no divergence
        for i, (name, (edits, feature)) in enumerate(bugs.items()):
            d = copy_reference(os.path.join(tmp, "bug%d" % i))
            for edit in edits:
                patched(d, *edit)
            r = fuzz.run(SELF_CMD, env_for(d), cases=1000)
            assert r["fuzz_divergences"] > 0 and r["fuzz_examples"], name
            assert len(r["fuzz_examples"]) <= 10, name
            assert r["fuzz_classes"] == 1 and list(r["fuzz_class_counts"])[0].startswith(feature + " x "), (name, r["fuzz_class_counts"])
            assert sum(r["fuzz_class_counts"].values()) == r["fuzz_divergences"], name


def test_a_divergence_example_names_the_argv_the_ledger_and_both_outputs():
    with tempfile.TemporaryDirectory() as tmp:
        d = copy_reference(os.path.join(tmp, "bug"))
        patched(d, *BOM_CLI)
        patched(d, *BOM_LEDGER)
        r = fuzz.run(SELF_CMD, env_for(d), cases=1000)
    ex = r["fuzz_examples"][0]
    assert {"case", "argv", "ledger", "ledger_from", "closed_stdout", "reference", "arm", "arm_stderr"} <= set(ex), ex
    assert "ufeff" in ex["arm_stderr"], ex
    assert ex["reference"]["exit"] == 0 and ex["arm"]["exit"] == 1, ex
    json.dumps(r)                                                      # all of it is plain JSON


def test_examples_prefer_one_per_kind_then_fill_in_case_order():
    found = [(("a",), {"n": 1}), (("a",), {"n": 2}), (("b",), {"n": 3}), (("a",), {"n": 4}), (("c",), {"n": 5})]
    assert [e["n"] for e in fuzz.pick_examples(found)] == [1, 3, 5, 2, 4]
    many = [((str(i % 3),), {"n": i}) for i in range(40)]
    got = fuzz.pick_examples(many)
    assert len(got) == fuzz.MAX_EXAMPLES == 10 and [e["n"] for e in got[:3]] == [0, 1, 2]


def test_the_time_cap_stops_starting_new_cases():
    r = fuzz.run(SELF_CMD, env_for(REF), cases=200, cap_s=0)
    assert 0 < r["fuzz_cases"] <= fuzz.CHUNK and r["fuzz_divergences"] == 0, r


def test_a_command_that_hangs_or_is_missing_is_a_divergence_not_a_crash():
    old = fuzz.RUN_TIMEOUT
    fuzz.RUN_TIMEOUT = 1
    try:
        hang = fuzz.run([sys.executable, "-c", "import time; time.sleep(30)"], env_for(REF), cases=2)
    finally:
        fuzz.RUN_TIMEOUT = old
    assert hang["fuzz_divergences"] == 2 and hang["fuzz_examples"][0]["arm"]["exit"] == "timeout", hang
    gone = fuzz.run(["/no/such/pennywise"], env_for(REF), cases=3)
    assert gone["fuzz_divergences"] == 3 and gone["fuzz_examples"][0]["arm"]["exit"] == "oserror", gone


def test_what_counts_leaves_room_where_the_brief_does():
    case = {"argv": ["summary", "f"], "closed_stdout": False}
    wide = {"exit": 0, "stdout": "a    1.00\nbb  2.00\n", "stderr_empty": True, "file": None}
    narrow = dict(wide, stdout="a  1.00\nbb 2.00\n")
    assert fuzz.canon(case, wide) == fuzz.canon(case, narrow)
    assert fuzz.canon(case, wide) != fuzz.canon(case, dict(wide, stdout="a  1.00\nbb  3.00\n"))
    ecase = {"argv": ["export", "f"], "closed_stdout": False}
    lf = dict(wide, stdout="date,category,amount,note\n2024-01-01,a,1.00,\n")
    assert fuzz.canon(ecase, lf) == fuzz.canon(ecase, dict(lf, stdout=lf["stdout"].replace("\n", "\r\n")))
    assert fuzz.canon(ecase, lf) != fuzz.canon(ecase, dict(lf, stdout=lf["stdout"].replace("1.00", "1.0")))
    jcase = {"argv": ["list", "--json", "f"], "closed_stdout": False}
    j1 = dict(wide, stdout='[{"a": "é"}]\n')
    j2 = dict(wide, stdout='[{"a":"\\u00e9"}]\n')
    assert fuzz.canon(jcase, j1) == fuzz.canon(jcase, j2)
    assert fuzz.canon(jcase, j1) != fuzz.canon(jcase, dict(j1, stdout='[{"a": "e"}]\n'))
    pipe = dict(case, closed_stdout=True)
    assert fuzz.canon(pipe, dict(wide, exit=141)) == fuzz.canon(pipe, dict(wide, exit=0, stdout=""))
    assert fuzz.canon(pipe, dict(wide, stderr_empty=False)) != fuzz.canon(pipe, wide)
    lines = fuzz.line_list(b"a\r\n\r\nb\rc\n")
    assert lines == ["a", "b", "c"]


def test_a_closed_stdout_pipe_is_a_real_closed_pipe():
    case = {"id": 0, "argv": ["list", "-"], "ledger_hex": None, "stdin_hex": b"2024-01-01 a 1\n".hex(),
            "closed_stdout": True}
    res = fuzz.run_one(SELF_CMD, dict(env_for(REF), PYTHONIOENCODING="utf-8"), case)
    assert res["stderr_empty"] and res["stdout"] == "", res
    with tempfile.TemporaryDirectory() as tmp:
        d = copy_reference(os.path.join(tmp, "bug"))
        patched(d, "cli.py", "except BrokenPipeError:", "except ZeroDivisionError:")
        res = fuzz.run_one(SELF_CMD, dict(env_for(d), PYTHONIOENCODING="utf-8"), case)
    assert not res["stderr_empty"] and "BrokenPipeError" in res["stderr"], res


def test_the_command_line():
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        assert fuzz.main(["--self", "--cases", "20"]) == 0
    r = json.loads(out.getvalue())
    assert (r["fuzz_cases"], r["fuzz_divergences"], r["fuzz_hash"]) == (20, 0, PINNED), r
    with contextlib.redirect_stdout(io.StringIO()) as printed:
        assert fuzz.main(["--print-hash"]) == 0
    assert printed.getvalue().strip() == PINNED
    saved = os.environ.pop("PENNYWISE_CMD", None)
    try:
        with contextlib.redirect_stderr(io.StringIO()) as e2:
            assert fuzz.main([]) == 2 and "--cmd" in e2.getvalue()
            assert fuzz.main(["--cmd", "not json"]) == 2
            assert fuzz.main(["--cmd", "[]"]) == 2
        os.environ["PENNYWISE_CMD"] = json.dumps(SELF_CMD)
        os.environ["PYTHONPATH"] = REF
        with contextlib.redirect_stdout(io.StringIO()) as via_env:
            assert fuzz.main(["--cases", "10"]) == 0
        assert json.loads(via_env.getvalue())["fuzz_divergences"] == 0
    finally:
        os.environ.pop("PYTHONPATH", None)
        os.environ.pop("PENNYWISE_CMD", None)
        if saved is not None:
            os.environ["PENNYWISE_CMD"] = saved


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as ex: print(f"  FAIL: {name} — {ex}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)
