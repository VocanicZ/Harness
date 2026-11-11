#!/usr/bin/env python3
"""test_bench_medium_fuzz.py — #621 (PRD #345): bench/fixture-medium/fuzz.py, the blind differential fuzz of an arm's
`stockroom` against the reference implementation. Covered: the generator is deterministic and FROZEN (a pinned case hash; a
change makes the fuzz refuse to run), a smaller --cases is a prefix of the full plan; it is blind (stdlib only, reads no
results or arm file, says how it was written); the plan has the shapes the brief names (every command and option, each kind of
mistake, the file shapes, the rounding edges) and keeps clear of what the brief leaves open; the reference has 0 divergences
against itself; copies of the reference with bugs put in (half-up rounding, the 500.00 threshold, `fulfil` ignoring later
movements, exit statuses, ...) are caught and grouped into root-cause classes; what is and is not compared; a hanging or
missing command; the time cap; and the command line (also through bench/fuzz.py --fixture medium)."""
import contextlib, importlib.util, io, json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("medium_fuzz", os.path.join(ROOT, "bench", "fixture-medium", "fuzz.py"))
fuzz = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fuzz)

REF = fuzz.REFERENCE_DIR
PINNED = "dadc646bc2e0c241c8dde733be0f4c09da016eba2e7319c0e5d24dcf3537a0f1"
SELF_CMD = [sys.executable, "-m", "stockroom"]
BUG_CASES = 60                        # the broad bugs show up in a prefix; the narrow ones are tried on cases picked for them

NARROW = {          # a bug, and a way to pick the planned cases that can show it
    "the order discount starts a penny late": ("pricing.py", "ORDER_DISCOUNT_FROM = 50000", "ORDER_DISCOUNT_FROM = 50001"),
    "fulfil ignores later movements": ("movements.py", "return max(0, balance if low is None else low)", "return max(0, balance)"),
    "a leftover penny goes to the later line": ("pricing.py", "key=lambda i: (-remainders[i], i)", "key=lambda i: (-remainders[i], -i)"),
}
BUGS = {
    "a half penny rounds down": [("money.py", "(pennies * rate + 50) // 100", "(pennies * rate + 49) // 100")],
    "the volume discount starts a unit late": [("pricing.py", "5 if quantity >= 10", "5 if quantity >= 11")],
    "a refused request exits 2": [("cli.py", "    except Refused as exc:\n        print(\"%s: %s\" % (PROG, exc), file=sys.stderr)\n        return 1",
                                   "    except Refused as exc:\n        print(\"%s: %s\" % (PROG, exc), file=sys.stderr)\n        return 2")],
}


def env_for(path):
    return dict(os.environ, PYTHONPATH=path)


def copy_reference(dest):
    shutil.copytree(REF, dest, ignore=shutil.ignore_patterns("__pycache__"))
    return dest


def patched(dest, rel, old, new):
    p = os.path.join(dest, "stockroom", rel)
    text = open(p, encoding="utf-8").read()
    assert old in text, (rel, old)
    open(p, "w", encoding="utf-8").write(text.replace(old, new))


def case(steps, files=None, **kw):
    base = {"id": 0, "kind": "t", "files": {k: v.encode().hex() for k, v in (files or {}).items()}, "sub": None, "steps": steps,
            "closed_stdout": False, "locate": None, "tags": []}
    base.update(kw)
    return base


def rec(**kw):
    base = {"exit": 0, "stdout": "", "stderr_empty": True, "stderr": "", "file": None, "untouched": True, "what": "stockroom x"}
    base.update(kw)
    return base


def test_the_generator_is_frozen():
    assert fuzz.FROZEN_HASH == PINNED, "the generator changed: that is a different measurement (see fuzz.py)"
    cases = fuzz.generate()
    assert len(cases) == fuzz.CASES == 1000 and fuzz.SEED == 621 and fuzz.CAP_S == 600
    assert fuzz.case_hash(cases) == fuzz.FROZEN_HASH == PINNED
    assert fuzz.generate() == cases                                   # deterministic
    assert fuzz.generate(200) == cases[:200]                          # a prefix, so --cases 200 runs the first 200 planned cases
    assert fuzz.generate(7) == cases[:7]
    assert [c["id"] for c in cases] == list(range(1000))
    json.dumps(cases)                                                 # plain data


def test_the_prng_is_the_pennywise_one():
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


def test_the_generator_is_blind_and_says_so():
    """#620: written from the brief and the reference before any arm ran on the fixture, reads nothing but its own tables."""
    path = os.path.join(ROOT, "bench", "fixture-medium", "fuzz.py")
    src = open(path, encoding="utf-8").read()
    assert "blind" in fuzz.PROVENANCE and "before any arm" in fuzz.PROVENANCE and "brief" in fuzz.PROVENANCE
    assert "PROVENANCE (#621): this is a BLIND generator" in src
    imports = {l.split()[1].split(".")[0] for l in src.splitlines() if l.startswith(("import ", "from "))}
    assert imports <= {"argparse", "csv", "datetime", "hashlib", "importlib", "io", "json", "os", "re", "shutil", "subprocess", "sys",
                       "tempfile", "time", "concurrent"}, imports                          # stdlib only; no `random`
    assert "random" not in imports
    for forbidden in ("results", "hidden", "fuzzgen", "fixture-large"):
        assert forbidden not in src, forbidden                                            # reads no arm output, test or other generator
    opened = re.findall(r"open\(([^)]*)\)", src)
    assert all("REFERENCE" not in x and "results" not in x for x in opened), opened
    assert 'os.path.join(HERE, "reference")' in src                                       # the reference is the only fixture file it runs


def cases_of_kind(kind):
    return [c for c in fuzz.generate() if c["kind"] == kind]


def test_the_plan_has_the_mix_and_the_shapes_the_brief_names():
    cases = fuzz.generate()
    kinds = {}
    for c in cases:
        kinds[c["kind"]] = kinds.get(c["kind"], 0) + 1
    assert set(kinds) >= {"shelves", "quote", "receive_ship", "fulfil", "invoice_report", "mistake", "format", "usage",
                          "unreadable", "closed_pipe", "dash_args", "checks_order"}, kinds
    first = [c["kind"] for c in cases[:100]]
    assert first.count("quote") + first.count("fulfil") + first.count("receive_ship") > 30            # every prefix has the same mix
    steps = [s for c in cases for s in c["steps"]]
    assert 1500 < len(steps) < 4000, len(steps)                                                       # the wall time is mostly this
    assert all(len(c["steps"]) <= 8 for c in cases) and any(len(c["steps"]) > 1 for c in cases)
    commands = {fuzz.split_command(s)[0] for s in steps}
    assert {"stock", "low", "history", "receive", "ship", "quote", "fulfil", "invoice", "report"} <= commands, commands
    assert {None, "bogus"} <= commands, "no command and an unknown one"
    flat = [" ".join(s) for s in steps]
    for want in ("--json", "--format csv", "--format json", "--format text", "--dir box", "--dir nowhere", "--bogus", "--format xml",
                 "2024-02-30", "order SO-", "so-", "ZZ-999".replace("ZZ", "QQ")):
        assert any(want in f for f in flat), want
    for a, b in (("receive", "-5"), ("ship", "-5")):
        assert any(s[0] == a and b in s for s in steps if s), (a, b)                 # a dash-led quantity is a bad quantity
    assert any(s[:1] == ["receive"] and len(s) > 4 and s[4].startswith("-") for s in steps), "a dash-led note"
    assert any(s[:1] == ["fulfil"] and len(s) == 4 for s in steps) or any(s[:1] == ["fulfil"] and "x" in s for s in steps)
    # the files
    blobs = [(n, bytes.fromhex(h)) for c in cases for n, h in c["files"].items()]
    assert any(b.startswith(b"\xef\xbb\xbf") for _, b in blobs), "BOM"
    assert any(b"\r\n" in b for _, b in blobs) and any(b"\r\n" not in b and b"\n" in b for _, b in blobs), "CRLF and LF"
    assert any(b and not b.endswith(b"\n") for _, b in blobs), "no final newline"
    assert any(b"\t" in b for _, b in blobs), "tabs"
    assert any("日本".encode() in b for _, b in blobs) and any("é".encode() in b for _, b in blobs), "non-ASCII"
    assert any(b"\n#" in b or b.startswith(b"#") for _, b in blobs), "comment lines"
    assert any(b"\n\n" in b or b"\n  \n" in b for _, b in blobs), "blank lines"

    def invalid(b):
        try:
            b.decode("utf-8")
            return False
        except UnicodeDecodeError:
            return True
    assert {n for n, b in blobs if invalid(b)} == {"catalog.txt", "movements.txt", "orders.txt"}, "invalid UTF-8 in each file"
    assert any("catalog.txt" not in c["files"] for c in cases) and any("movements.txt" not in c["files"] for c in cases)
    assert any("orders.txt" not in c["files"] for c in cases), "missing files"
    assert any(c["sub"] == "box" for c in cases) and any(c["closed_stdout"] for c in cases), "--dir and a closed pipe"
    assert any(b"" == b for _, b in blobs), "an empty file"
    located = {c["locate"] for c in cases}
    assert {"catalog.txt", "movements.txt", "orders.txt"} <= located, located
    tags = {t for c in cases for t in c["tags"]}
    for want in ("mistake:catalog-price", "mistake:catalog-duplicate", "mistake:movements-stock-over", "mistake:movements-stock-same-day",
                 "mistake:movements-stock-early", "mistake:orders-duplicate", "mistake:orders-lines-space", "pricing:threshold",
                 "pricing:tie", "pricing:three-tax-classes", "fulfil:before-order-date", "fulfil:later-movements",
                 "fulfil:earlier-shipments", "fulfil:shortfall", "orders:report-order", "order-of-checks", "argv:dash-led-argument"):
        assert want in tags, want


def test_the_cases_reach_every_rounding_the_brief_names():
    """Counted on the plan itself, from the brief's rules (fuzz.price_features), so a change to the generator cannot drop one."""
    seen = {}
    for c in fuzz.generate():
        for f in fuzz.price_features(c["files"]):
            seen[f] = seen.get(f, 0) + 1
    for want, least in (("pricing:volume-discount-5", 100), ("pricing:volume-discount-10", 50), ("pricing:half-penny-volume", 50),
                        ("pricing:order-discount", 100), ("pricing:subtotal-at-threshold", 15), ("pricing:half-penny-order-discount", 8),
                        ("pricing:shared-leftover-penny", 80), ("pricing:shared-tie", 15), ("pricing:half-penny-tax", 20),
                        ("pricing:tax-standard", 100), ("pricing:tax-reduced", 100), ("pricing:tax-zero", 50)):
        assert seen.get(want, 0) >= least, (want, seen.get(want))


def test_the_cases_keep_clear_of_what_the_brief_leaves_open():
    """No line end but LF and CRLF, no form feed or U+2028, no lone CR, no year 0000, no price like `.5` or `12.`."""
    for c in fuzz.generate():
        for name, hx in c["files"].items():
            data = bytes.fromhex(hx)
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                continue
            assert not re.search("\r(?!\n)", text), (c["id"], name)
            assert not any(ch in text for ch in "\f\v\x85  \x1c\x1d\x1e\xa0"), (c["id"], name)
            if name == "catalog.txt" and "mistake:catalog-price" not in c["tags"]:
                for line in text.splitlines():
                    f = [x.strip() for x in line.split("|")]
                    if len(f) in (4, 5) and not line.strip().startswith("#") and re.fullmatch(r"[0-9.]+", f[2]):
                        assert re.fullmatch(r"[0-9]+(\.[0-9]{1,2})?", f[2]), (c["id"], f[2])
        for argv in c["steps"]:
            assert not any(a.startswith("0000-") or "--format=" in a or a in ("--help", "-h", "--") for a in argv), (c["id"], argv)
            for a in argv:
                assert "\r" not in a.replace("\r\n", ""), (c["id"], argv)


def test_the_reference_has_no_divergences_against_itself():
    r = fuzz.run(SELF_CMD, env_for(REF), cases=50)
    assert r["fuzz_cases"] == 50 and r["fuzz_divergences"] == 0 and r["fuzz_examples"] == [], r
    assert (r["fuzz_seed"], r["fuzz_hash"]) == (621, PINNED)
    assert r["fuzz_classes"] == 0 and r["fuzz_class_counts"] == {}, r


def test_the_cases_that_pin_a_line_name_it_in_the_reference():
    """`locate` cases (one mistake in the whole case) are ones where the reference's message really carries file and line."""
    located = [c for c in fuzz.generate(220) if c["locate"]][:20]
    assert located
    for c in located:
        recs = fuzz.run_case(SELF_CMD, env_for(REF), c)
        loc = fuzz.location(c, recs[-1]) if recs[-1]["exit"] == 1 else None
        for rec_ in recs:
            if rec_["exit"] == 1:
                assert fuzz.location(c, rec_) is not None or "no such" in rec_["stderr"], (c["id"], rec_["stderr"])


def test_each_injected_bug_is_caught():
    with tempfile.TemporaryDirectory() as tmp:
        clean = copy_reference(os.path.join(tmp, "clean"))
        r = fuzz.run(SELF_CMD, env_for(clean), cases=20)
        assert r["fuzz_divergences"] == 0, r["fuzz_examples"][:2]       # a copy alone is no divergence
        for i, (name, edits) in enumerate(BUGS.items()):
            d = copy_reference(os.path.join(tmp, "bug%d" % i))
            for edit in edits:
                patched(d, *edit)
            r = fuzz.run(SELF_CMD, env_for(d), cases=BUG_CASES)
            assert r["fuzz_cases"] == BUG_CASES, (name, r["fuzz_cases"])
            assert r["fuzz_divergences"] > 0 and r["fuzz_examples"], name
            assert len(r["fuzz_examples"]) <= 10, name
            assert 1 <= r["fuzz_classes"] <= r["fuzz_divergences"], (name, r["fuzz_classes"])         # root-cause classes (#620)
            assert r["fuzz_classes"] == len(r["fuzz_class_counts"]), name
            assert sum(r["fuzz_class_counts"].values()) == r["fuzz_divergences"], (name, r["fuzz_class_counts"])
            print("    %-42s %3d divergences, %d classes in %d cases, e.g. %s" % (
                name, r["fuzz_divergences"], r["fuzz_classes"], BUG_CASES, " ".join(r["fuzz_examples"][0]["what"].split()[:6])))


def test_the_narrow_bugs_are_caught_on_the_cases_that_can_show_them():
    """The 500.00 threshold, a tie in the sharing of the order discount and a later movement that limits `fulfil` are exact
    spots: a prefix of the plan may not reach them, so these are tried on planned cases that do (picked by what they contain)."""
    plan = fuzz.generate()
    picks = {
        "the order discount starts a penny late": [c for c in plan if "pricing:subtotal-at-threshold" in fuzz.price_features(c["files"])
                                                   and any(fuzz.split_command(s)[0] == "quote" for s in c["steps"])][:14],
        "fulfil ignores later movements": [c for c in plan if "fulfil:later-movements" in c["tags"]][:20],
        "a leftover penny goes to the later line": [c for c in plan if "pricing:shared-tie" in fuzz.price_features(c["files"])
                                                    and any(fuzz.split_command(s)[0] == "quote" for s in c["steps"])][:30],
    }
    from concurrent.futures import ThreadPoolExecutor
    with tempfile.TemporaryDirectory() as tmp, ThreadPoolExecutor(4) as pool:
        for i, (name, edit) in enumerate(NARROW.items()):
            d = copy_reference(os.path.join(tmp, "bug%d" % i))
            patched(d, *edit)
            assert len(picks[name]) >= 10, (name, len(picks[name]))
            both = pool.map(lambda c: (c, fuzz.run_case(SELF_CMD, env_for(REF), c), fuzz.run_case(SELF_CMD, env_for(d), c)), picks[name])
            hit = sum(fuzz.compare(c, ref, arm)[0] is not None for c, ref, arm in both)
            assert hit > 0, name
            print("    %-42s %3d of %d picked cases diverge" % (name, hit, len(picks[name])))


def test_a_divergence_example_names_the_case_the_input_and_both_answers():
    with tempfile.TemporaryDirectory() as tmp:
        d = copy_reference(os.path.join(tmp, "bug"))
        patched(d, *BUGS["a half penny rounds down"][0])
        r = fuzz.run(SELF_CMD, env_for(d), cases=BUG_CASES)
    ex = r["fuzz_examples"][0]
    assert {"case", "kind", "step", "what", "steps", "files", "reference", "arm", "arm_stderr"} <= set(ex), ex
    assert ex["reference"] != ex["arm"] and ex["what"].startswith("stockroom "), ex
    json.dumps(r)                                                       # all of it is plain JSON
    # the classes are named by what the brief says (a rounding), not by what every case shares
    assert any(k.startswith("pricing:") for k in r["fuzz_class_counts"]), r["fuzz_class_counts"]


def test_examples_prefer_one_per_kind_then_fill_in_case_order():
    found = [(("a",), {"n": 1}), (("a",), {"n": 2}), (("b",), {"n": 3}), (("a",), {"n": 4}), (("c",), {"n": 5})]
    assert [e["n"] for e in fuzz.pick_examples(found)] == [1, 3, 5, 2, 4]


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
    gone = fuzz.run(["/no/such/stockroom"], env_for(REF), cases=3)
    assert gone["fuzz_divergences"] == 3 and gone["fuzz_examples"][0]["arm"]["exit"] == "oserror", gone


def test_what_counts_leaves_room_where_the_brief_does():
    c = case([["stock"]])
    canon = lambda argv, r, loc=None, cs=c: fuzz.canon(cs, argv, r, loc)
    # JSON as data: key order and layout do not matter, a number is not a string
    a = rec(stdout='[{"sku": "A", "onhand": 1}]\n')
    assert canon(["stock", "--json"], a) == canon(["stock", "--json"], rec(stdout='[\n {"onhand":1,"sku":"A"}\n]'))
    assert canon(["stock", "--json"], a) != canon(["stock", "--json"], rec(stdout='[{"sku": "A", "onhand": "1"}]'))
    assert canon(["stock", "--json"], a) != canon(["stock", "--json"], rec(stdout="not json"))
    assert canon(["stock"], a) != canon(["stock"], rec(stdout='[{"sku": "A", "onhand": 2}]\n'))        # text is exact ...
    assert canon(["stock"], a) == canon(["stock"], rec(stdout=a["stdout"].rstrip("\n")))              # ... but for a final newline
    assert canon(["stock"], rec(stdout="")) != canon(["stock"], rec(stdout="\n"))
    # the brief does not say whether a history delta is -3 or "-3"
    h = rec(stdout='[{"date": "2024-01-01", "delta": "-3", "balance": 4, "note": ""}]')
    assert canon(["history", "A", "--json"], h) == canon(["history", "A", "--json"], rec(stdout=h["stdout"].replace('"-3"', "-3")))
    assert canon(["history", "A", "--json"], h) != canon(["history", "A", "--json"], rec(stdout=h["stdout"].replace('"-3"', "-4")))
    assert canon(["history", "A", "--json"], h) != canon(["history", "A", "--json"], rec(stdout=h["stdout"].replace("4,", '"4",')))
    # `--json` after receive is a note, not an option
    assert canon(["receive", "d", "s", "1", "--json"], rec(stdout="x")) != canon(["receive", "d", "s", "1", "--json"], rec(stdout="y"))
    # CSV as rows: LF or CRLF, and quoting as a CSV reader sees it
    csv_a = rec(stdout='order,date\nSO-1,"a,b"\n')
    assert canon(["report", "--format", "csv"], csv_a) == canon(["report", "--format", "csv"], rec(stdout='order,date\r\nSO-1,"a,b"\r\n'))
    assert canon(["report", "--format", "csv"], csv_a) != canon(["report", "--format", "csv"], rec(stdout="order,date\nSO-1,a,b\n"))
    assert canon(["report", "--format", "json"], rec(stdout='[{"a":1}]')) == canon(["report", "--format", "json"], rec(stdout='[{"a": 1}]'))
    assert canon(["report"], rec(stdout="x\n")) != canon(["report"], rec(stdout="x\ny\n"))
    # exit 2: the brief says nothing about its output
    assert canon(["stock"], rec(exit=2, stdout="usage")) == canon(["stock"], rec(exit=2, stdout=""))
    assert canon(["stock"], rec(exit=1, stdout="usage")) != canon(["stock"], rec(exit=1, stdout=""))
    assert canon(["stock"], rec(exit=1)) != canon(["stock"], rec(exit=2))
    assert canon(["stock"], rec(stderr_empty=False)) != canon(["stock"], rec())
    # the file movements.txt: absent is not empty, lines in order, nothing else in the folder changed
    assert canon(["ship"], rec(file=None)) != canon(["ship"], rec(file=[]))
    assert canon(["ship"], rec(file=["a"])) != canon(["ship"], rec(file=["b"]))
    assert canon(["ship"], rec(untouched=False)) != canon(["ship"], rec())
    assert canon(["ship"], rec(exit=1, kept=False)) != canon(["ship"], rec(exit=1, kept=True))                  # a refusal changes nothing
    assert fuzz.lines_of(b"a\r\n\r\nb\nc") == ["a", "b", "c"] and fuzz.lines_of(b"") == []
    # a closed pipe: only the status and a silent standard error count
    pipe = case([["stock"]], closed_stdout=True)
    assert canon(["stock"], rec(stdout="x"), cs=pipe) == canon(["stock"], rec(stdout=""), cs=pipe)
    assert canon(["stock"], rec(exit=141), cs=pipe) != canon(["stock"], rec(), cs=pipe)
    assert canon(["stock"], rec(stderr_empty=False), cs=pipe) != canon(["stock"], rec(), cs=pipe)
    # where a mistake is named: the file and the line, wherever the arm puts them
    located = case([["stock"]], locate="movements.txt")
    ref = rec(exit=1, stderr="stockroom: movements.txt line 12: unknown SKU 'X'")
    loc = fuzz.location(located, ref)
    assert loc == ("movements.txt", "12")
    good = rec(exit=1, stderr="movements.txt:12: bad")
    assert canon(["stock"], good, loc, located) == canon(["stock"], ref, loc, located)
    for bad in ("movements.txt line 2: x", "line 12: x", "catalog.txt line 12: x", "mistake on line 120 of movements.txt", "bad"):
        assert canon(["stock"], rec(exit=1, stderr=bad), loc, located) != canon(["stock"], ref, loc, located), bad
    assert fuzz.location(case([["stock"]]), ref) is None and fuzz.location(located, rec(exit=2, stderr="x")) is None
    assert fuzz.mode_of(["--dir", "box", "stock", "--json"]) == "json" and fuzz.mode_of(["receive", "d", "s", "1", "--json"]) == "text"
    assert fuzz.mode_of(["report", "--format", "csv", "--dir", "b"]) == "csv" and fuzz.mode_of(["report", "--format"]) == "text"
    assert fuzz.split_command(["--dir", "x", "stock", "--json"]) == ("stock", ["--json"]) and fuzz.split_command(["--dir"]) == (None, [])


def test_features_name_what_is_odd_about_a_case():
    cases = fuzz.generate()
    allf = {}
    for c in cases:
        for f in fuzz.features(c):
            allf[f] = allf.get(f, 0) + 1
    for want in ("catalog:byte-order-mark", "movements:crlf", "orders:no-final-newline", "movements:invalid-utf8", "catalog:missing",
                 "movements:missing", "output:closed-pipe", "argv:dash-led-argument", "argv:signed-quantity", "argv:unknown-option",
                 "argv:no-command", "argv:unknown-command", "argv:bad-date", "argv:dir-option", "argv:format-csv", "argv:format-bad",
                 "catalog:non-ascii", "movements:tab", "orders:comment", "pricing:half-penny-volume", "mistake:movements-stock-over"):
        assert allf.get(want), want
    total = len(cases)
    assert not [f for f, n in allf.items() if n > total * 0.75], "a feature nearly every case has explains nothing"
    c = case([["stock"]], {"catalog.txt": "﻿AB-100|x|1|1\r\n"})
    f = fuzz.features(c, 0)
    assert "catalog:byte-order-mark" in f and "catalog:crlf" in f and "movements:missing" in f and "orders:missing" in f, f
    plain = {"catalog.txt": "AB-100|x|1|1\n", "movements.txt": "2024-01-01 AB-100 5\n", "orders.txt": "SO-1 2024-01-01 a AB-100*1\n"}
    assert fuzz.features(case([["stock"]], plain), 0) == {"command:stock"}


def test_a_bug_in_one_place_is_one_class_and_two_bugs_are_two():
    with tempfile.TemporaryDirectory() as tmp:
        d = copy_reference(os.path.join(tmp, "two"))
        patched(d, *BUGS["a refused request exits 2"][0])
        patched(d, *BUGS["a half penny rounds down"][0])
        r = fuzz.run(SELF_CMD, env_for(d), cases=BUG_CASES)
    assert r["fuzz_divergences"] >= 5 and 2 <= r["fuzz_classes"] <= r["fuzz_divergences"], r["fuzz_class_counts"]
    assert sum(r["fuzz_class_counts"].values()) == r["fuzz_divergences"]


def test_the_run_is_deterministic():
    one = fuzz.run(SELF_CMD, env_for(REF), cases=12)
    two = fuzz.run(SELF_CMD, env_for(REF), cases=12)
    assert one == two
    a = fuzz.run_case(SELF_CMD, env_for(REF), fuzz.generate(30)[27])
    b = fuzz.run_case(SELF_CMD, env_for(REF), fuzz.generate(30)[27])
    assert a == b


def test_the_command_line():
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        assert fuzz.main(["--self", "--cases", "12"]) == 0
    r = json.loads(out.getvalue())
    assert (r["fuzz_cases"], r["fuzz_divergences"], r["fuzz_hash"], r["fuzz_seed"]) == (12, 0, PINNED, 621), r
    assert {"fuzz_classes", "fuzz_class_counts", "fuzz_examples"} <= set(r)
    with contextlib.redirect_stdout(io.StringIO()) as printed:
        assert fuzz.main(["--print-hash"]) == 0
    assert printed.getvalue().strip() == PINNED
    saved = os.environ.pop("STOCKROOM_CMD", None)
    try:
        with contextlib.redirect_stderr(io.StringIO()) as e2:
            assert fuzz.main([]) == 2 and "--cmd" in e2.getvalue()
            assert fuzz.main(["--cmd", "not json"]) == 2
            assert fuzz.main(["--cmd", "[]"]) == 2
        os.environ["STOCKROOM_CMD"] = json.dumps(SELF_CMD)
        os.environ["PYTHONPATH"] = REF
        with contextlib.redirect_stdout(io.StringIO()) as via_env:
            assert fuzz.main(["--cases", "10"]) == 0
        assert json.loads(via_env.getvalue())["fuzz_divergences"] == 0
    finally:
        os.environ.pop("PYTHONPATH", None)
        os.environ.pop("STOCKROOM_CMD", None)
        if saved is not None:
            os.environ["STOCKROOM_CMD"] = saved


def test_bench_fuzz_delegates_for_the_medium_fixture():
    base = os.path.join(ROOT, "bench", "fuzz.py")
    p = subprocess.run([sys.executable, base, "--fixture", "medium", "--print-hash"], capture_output=True, text=True)
    assert p.returncode == 0 and p.stdout.strip() == PINNED, p
    p = subprocess.run([sys.executable, base, "--print-hash"], capture_output=True, text=True)
    assert p.stdout.strip() == "5c7f3fbfa079d0caa1236e37f3fd06f0f45dc75f15b6087d4060c04ab80d5f87", p      # pennywise untouched
    p = subprocess.run([sys.executable, base, "--fixture", "medium", "--self", "--cases", "6"], capture_output=True, text=True)
    r = json.loads(p.stdout)
    assert (r["fuzz_cases"], r["fuzz_divergences"], r["fuzz_seed"]) == (6, 0, 621), p


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as ex: print(f"  FAIL: {name} — {ex}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)
