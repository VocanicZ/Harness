#!/usr/bin/env python3
"""test_bench_large_fuzz.py — #592 (PRD #345): bench/fixture-large/fuzz.py, the differential fuzz of an arm's `tallybook`
against the reference implementation. Covered: the generator is deterministic and FROZEN (a pinned case hash; a change
makes the fuzz refuse to run), a smaller --cases is a prefix of the full plan, the plan has the mix (offline / book /
API) and the shapes the issue names; the reference has 0 divergences against itself; copies of the reference with
realistic bugs put in (half-up rounding, an off-by-one month end, the old HTTP status, a lock that spares its own
day) are caught; what is and is not compared (the brief's open spots); the example list, the time cap, a hanging or
missing command; and the command line (also through bench/fuzz.py --fixture large)."""
import contextlib, importlib.util, io, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("large_fuzz", os.path.join(ROOT, "bench", "fixture-large", "fuzz.py"))
fuzz = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fuzz)

REF = fuzz.REFERENCE_DIR
PINNED = "58bb9280f8964332d0a7280bb32bd2c79b2644a2e446efb98c71bbaaf762f97d"
SELF_CMD = [sys.executable, "-m", "tallybook"]
BUG_CASES = 150

BUGS = {
    "post-change rounding never done (half up)": [("money.py", "(_phase.PRE or q % 2 == 1)", "True")],
    "month end clamped one day short": [("dates.py", "min(d.day, last_day(year, month0 + 1))",
                                         "min(d.day, last_day(year, month0 + 1) - 1)")],
    "validation errors still answer 400": [("api/router.py", "        status = 422\n", "        status = 400\n")],
    "the lock does not cover its own day": [("ledger.py", "day <= lock", "day < lock"),
                                            ("storage/repo.py", "day <= lock", "day < lock")],
}


def env_for(path):
    return dict(os.environ, PYTHONPATH=path)


def copy_reference(dest):
    shutil.copytree(REF, dest, ignore=shutil.ignore_patterns("__pycache__"))
    return dest


def patched(dest, rel, old, new):
    p = os.path.join(dest, "tallybook", rel)
    text = open(p, encoding="utf-8").read()
    assert old in text, (rel, old)
    open(p, "w", encoding="utf-8").write(text.replace(old, new))


def test_the_generator_is_frozen():
    assert fuzz.FROZEN_HASH == PINNED, "the generator changed: that is a different measurement (see fuzz.py)"
    cases = fuzz.generate()
    assert len(cases) == fuzz.CASES == 1000 and fuzz.SEED == 592 and fuzz.CAP_S == 600
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


def test_the_plan_has_the_mix_the_issue_names():
    cases = fuzz.generate()
    kinds = [c["kind"] for c in cases]
    assert (kinds.count("calc"), kinds.count("book"), kinds.count("api")) == (650, 200, 150)
    first = kinds[:200]
    assert (first.count("calc"), first.count("book"), first.count("api")) == (130, 40, 30)      # every prefix has the same mix
    assert {c["scenario"] for c in cases if c["kind"] == "book"} == {"ledger", "bank", "planning", "lock", "file"}
    steps = sum(len(c["steps"]) for c in cases if c["kind"] == "book")
    assert 1200 < steps < 2200, steps                                  # the wall time of 1000 cases is mostly this
    assert all("calc" in c["argv"] for c in cases if c["kind"] == "calc")


def test_the_cases_cover_the_shapes_the_issue_names():
    cases = fuzz.generate()
    calc = [c for c in cases if c["kind"] == "calc"]
    words = lambda c: c["argv"][c["argv"].index("calc") + 1:]
    subs = {w[0] for w in map(words, calc) if w}
    assert {"money", "date", "schedule", "query", "journal", "report", "budget", "rate", "rules", "account", "csv"} <= subs, subs
    assert {tuple(w[:2]) for w in map(words, calc) if w[:1] == ["money"]} >= {("money", s) for s in
        ("parse", "format", "add", "sub", "scale", "allocate", "convert")}
    kinds = {w[1] for w in map(words, calc) if w[:1] == ["report"] and len(w) > 1}
    assert {"trial-balance", "balance-sheet", "income-statement", "cashflow", "register"} <= kinds
    texts = [bytes.fromhex(h) for c in calc for h in c["files"].values()]
    texts += [bytes.fromhex(c["stdin_hex"]) for c in calc if c["stdin_hex"]]
    assert any(t.startswith(b"\xef\xbb\xbf") for t in texts), "BOM"
    assert any(b"\r\n" in t for t in texts), "CRLF"
    assert any("日本".encode() in t for t in texts), "unicode payee"
    assert any(b" #" in t and b'"' in t for t in texts), "tags and quotes"

    def invalid(t):
        try:
            t.decode("utf-8")
            return False
        except UnicodeDecodeError:
            return True
    assert any(invalid(t) for t in texts), "not UTF-8"
    argvs = [c["argv"] for c in calc]
    flat = [" ".join(a) for a in argvs]
    assert any("KWD" in f for f in flat) and any("JPY" in f for f in flat), "every currency exponent"
    assert any(("0" * 20) in f or ("9" * 20) in f or len(max(a, key=len)) > 28 for f, a in zip(flat, argvs)), "huge amounts"
    assert any("-0" in f for f in flat) and any(" -" in f for f in flat), "zero and negative amounts"
    assert any(f.endswith("1/2") or "5/2" in f for f in flat if "scale" in f), "rounding ties"
    assert any("2024-02-29" in f for f in flat), "leap day"
    assert any("monthly on 31" in f or "monthly on last" in f for f in flat), "month ends"
    assert any(c["closed_stdout"] for c in calc) and any(c["stdin_hex"] for c in calc), "closed pipe and stdin"
    assert any("--today" in a and a[a.index("--today") + 1] != fuzz.TODAY for a in argvs), "another today"
    books = [c for c in cases if c["kind"] == "book"]
    steps = [s["argv"][4:] for c in books for s in c["steps"]]
    heads = {tuple(s[:2]) for s in steps}
    for want in (("init",), ("account", "add"), ("tx", "add"), ("journal", "import"), ("import", "stmt.csv"), ("rate", "set"),
                 ("budget", "add"), ("recurring", "add"), ("recurring", "materialize"), ("report", "register"),
                 ("query",), ("export", "--format"), ("lock", "set"), ("db", "backup")):
        assert any(h[:len(want)] == want for h in heads), want
    lock = [c for c in books if c["scenario"] == "lock"][0]["steps"]
    assert [s["argv"][4:6] for s in lock if s["argv"][4:5] == ["lock"]][0] == ["lock", "set"]
    assert any(s["argv"][4:5] == ["tx"] and s["argv"][5:6] == ["add"] for s in lock), "an operation the lock refuses"
    apis = [c for c in cases if c["kind"] == "api"]
    reqs = [q for c in apis for q in c["requests"]]
    paths = {q["path"].split("?")[0] for q in reqs}
    for want in ("/health", "/accounts", "/transactions", "/rates", "/budgets", "/budgets/status", "/recurring",
                 "/recurring/materialize", "/reports/trial-balance", "/reports/register", "/import", "/rules", "/export", "/lock"):
        assert want in paths, want
    assert {"GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"} <= {q["method"] for q in reqs}
    assert any(q.get("body_kind") == "big" for q in reqs) and any(q.get("body_kind", "").startswith("max") for q in reqs)
    assert any("Content-Length" in (q.get("headers") or {}) for q in reqs), "bad Content-Length"
    assert any(q.get("body", "") == "{" for q in reqs) or any(q.get("body") in ("nope", "[]") for q in reqs), "bad JSON"
    assert any(q.get("ctype") == "text/plain" and q["path"].startswith(("/accounts", "/transactions")) for q in reqs), "wrong type"
    assert any("limit=9223372036854775808" in q["path"] for q in reqs), "pagination edges"
    assert any("q=" in q["path"] and "limit" in q["path"] for q in reqs), "filters"
    assert all(len(c["requests"]) <= 18 for c in apis)


def test_the_reference_has_no_divergences_against_itself():
    r = fuzz.run(SELF_CMD, env_for(REF), cases=60)
    assert r["fuzz_cases"] == 60 and r["fuzz_divergences"] == 0 and r["fuzz_examples"] == [], r
    assert (r["fuzz_seed"], r["fuzz_hash"]) == (592, PINNED)
    assert r["fuzz_classes"] == 0 and r["fuzz_class_counts"] == {}, r


def test_the_generator_is_blind_and_says_so():
    """#620: written from the brief and the reference before any arm ran on the fixture, and it says so."""
    assert "blind" in fuzz.PROVENANCE and "before any arm" in fuzz.PROVENANCE and "brief" in fuzz.PROVENANCE
    src = open(os.path.join(ROOT, "bench", "fixture-large", "fuzz.py"), encoding="utf-8").read()
    assert "PROVENANCE (#620): this is a BLIND generator" in src
    assert '"results"' not in src and "'results'" not in src                                          # reads no arm output


def test_each_injected_bug_is_caught():
    with tempfile.TemporaryDirectory() as tmp:
        clean = copy_reference(os.path.join(tmp, "clean"))
        r = fuzz.run(SELF_CMD, env_for(clean), cases=40)
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
            print("    %-42s %3d divergences in %d cases, e.g. %s" % (
                name, r["fuzz_divergences"], BUG_CASES, " ".join(r["fuzz_examples"][0]["what"].split()[:9])))


def test_a_divergence_example_names_the_case_the_input_and_both_answers():
    with tempfile.TemporaryDirectory() as tmp:
        d = copy_reference(os.path.join(tmp, "bug"))
        patched(d, *BUGS["post-change rounding never done (half up)"][0])
        r = fuzz.run(SELF_CMD, env_for(d), cases=100)
    ex = r["fuzz_examples"][0]
    assert {"case", "kind", "step", "what", "files", "reference", "arm", "arm_stderr"} <= set(ex), ex
    assert ex["reference"] != ex["arm"] and ex["kind"] in ("calc", "book", "api"), ex
    json.dumps(r)                                                       # all of it is plain JSON


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
    gone = fuzz.run(["/no/such/tallybook"], env_for(REF), cases=3)
    assert gone["fuzz_divergences"] == 3 and gone["fuzz_examples"][0]["arm"]["exit"] == "oserror", gone


def test_a_server_that_never_announces_is_a_divergence_not_a_hang():
    cases = [c for c in fuzz.generate(60) if c["kind"] == "api"][:1]
    assert cases
    with tempfile.TemporaryDirectory() as tmp:
        stub = os.path.join(tmp, "stub.py")
        open(stub, "w").write("import sys, time\nsys.exit(0)\n")
        events = fuzz.run_case([sys.executable, stub], os.environ.copy(), cases[0], fuzz.Clock(60))
    ref = fuzz.run_case(SELF_CMD, env_for(REF), cases[0])
    assert any(e["what"] == "serve" and e["res"]["announce"] is False for e in events), events
    assert fuzz.first_difference(ref, events) is not None


def test_what_counts_leaves_room_where_the_brief_does():
    canon = fuzz.canon_cli
    ok = {"exit": 0, "stdout": "usage: tallybook [--db FILE]\n  more\n", "stderr_empty": True}
    other = dict(ok, stdout="usage: tallybook [options] COMMAND\n")
    assert canon(["--today", "2024-06-15", "calc", "--help"], ok) == canon(["--today", "2024-06-15", "calc", "--help"], other)
    assert canon(["calc", "money", "parse", "1 USD"], ok) != canon(["calc", "money", "parse", "1 USD"], other)
    a = {"exit": 0, "stdout": "locked through 2024-03-31\n", "stderr_empty": True}
    b = dict(a, stdout="lock set\n")
    g = fuzz.GLOBALS
    assert canon(g + ["lock", "set", "2024-03-31"], a) == canon(g + ["lock", "set", "2024-03-31"], b)
    assert canon(g + ["lock", "show"], a) != canon(g + ["lock", "show"], b)
    assert canon(g + ["lock", "set", "2024-03-31"], dict(a, exit=1)) != canon(g + ["lock", "set", "2024-03-31"], a)
    assert canon(["x"], dict(a, stderr_empty=False)) != canon(["x"], a)
    pipe = {"exit": 0, "stdout": "", "stderr_empty": True}
    assert canon(["calc", "date", "periods"], pipe, True) == canon(["calc", "date", "periods"], dict(pipe, stdout="x\n"), True)
    assert canon(["a"], dict(pipe, exit=141), True) != canon(["a"], pipe, True)
    assert fuzz.command_of(["--db", "b.db", "--today", "2024-06-15", "lock", "set"]) == ["lock", "set"]

    def http(status, body, ctype="application/json; charset=utf-8", **headers):
        data = body if isinstance(body, bytes) else json.dumps(body, indent=2, sort_keys=True).encode() + b"\n"
        h = {"content-type": ctype, "content-length": str(len(data))}
        h.update(headers)
        return {"status": status, "headers": h, "body": data}

    req = {"method": "GET", "path": "/accounts/x"}
    err = lambda msg, code="not_found": http(404, {"error": {"code": code, "message": msg}})
    assert fuzz.canon_http(req, err("no such account 'x'")) == fuzz.canon_http(req, err("something else entirely"))
    assert fuzz.canon_http(req, err("m")) != fuzz.canon_http(req, err("m", "conflict"))
    assert fuzz.canon_http(req, err("m")) != fuzz.canon_http(req, err(""))                          # a message must be non-empty
    assert fuzz.canon_http(req, err("m")) != fuzz.canon_http(req, http(404, {"error": "old shape"}))     # the post-change body
    loose = dict(req, loose_code=True)
    assert fuzz.canon_http(loose, err("m", "not_found")) == fuzz.canon_http(loose, err("m", "no_such_path"))
    assert fuzz.canon_http(req, http(200, {"a": 1, "b": [1, 2]})) == fuzz.canon_http(
        req, http(200, json.dumps({"b": [1, 2], "a": 1}, separators=(",", ":")).encode()))             # JSON as data
    assert fuzz.canon_http(req, http(200, {"a": 1})) != fuzz.canon_http(req, http(200, {"a": 2}))
    assert fuzz.canon_http(req, http(200, {"a": 1})) != fuzz.canon_http(req, http(201, {"a": 1}))
    assert fuzz.canon_http(req, http(200, {"a": 1})) != fuzz.canon_http(req, http(200, {"a": 1}, "text/plain"))
    assert fuzz.canon_http(req, http(200, {"a": 1}, **{"content-length": "3"})) != fuzz.canon_http(req, http(200, {"a": 1}))
    assert fuzz.canon_http(req, http(405, {"error": {"code": "method_not_allowed", "message": "m"}}, allow="GET, POST")) != \
        fuzz.canon_http(req, http(405, {"error": {"code": "method_not_allowed", "message": "m"}}, allow="POST, GET"))
    put = {"method": "PUT", "path": "/lock", "loose_ok": True}
    assert fuzz.canon_http(put, http(200, {"lock_date": "2024-03-31"})) == fuzz.canon_http(put, http(204, b""))
    assert fuzz.canon_http(put, http(409, {"error": {"code": "locked", "message": "m"}})) != fuzz.canon_http(put, http(204, b""))
    head = {"method": "HEAD", "path": "/health", "ignore_body": True}
    assert fuzz.canon_http(head, http(405, b"")) == fuzz.canon_http(head, http(405, b"{}"))
    text = http(200, b"a,b\n", "text/csv; charset=utf-8")
    assert fuzz.canon_http(req, text) != fuzz.canon_http(req, http(200, b"a;b\n", "text/csv; charset=utf-8"))
    assert fuzz.canon_http(req, {"error": "timeout"}) != fuzz.canon_http(req, text)


def test_the_http_client_reads_what_a_server_answers():
    import threading
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n)
            out = json.dumps({"len": len(body), "type": self.headers.get("Content-Type")}).encode()
            self.send_response(201)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

        def log_message(self, *a):
            pass
    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        port = srv.server_address[1]
        resp = fuzz.http_call(port, fuzz.REQ("POST", "/x", {"a": 1}))
        assert resp["status"] == 201 and json.loads(resp["body"]) == {"len": 8, "type": "application/json"}, resp
        resp = fuzz.http_call(port, fuzz.REQ("POST", "/x", None, body_kind="max3", ctype="application/json"))
        assert json.loads(resp["body"])["len"] == 1048576, resp
        resp = fuzz.http_call(port, fuzz.REQ("POST", "/x", "x", ctype=None))
        assert json.loads(resp["body"])["type"] is None, resp
        raw = fuzz.build_request(fuzz.REQ("POST", "/x", "{}", headers={"Content-Length": "abc"}))
        assert b"Content-Length: abc" in raw and raw.count(b"Content-Length") == 1, raw
    finally:
        srv.shutdown()
    assert "error" in fuzz.http_call(1, fuzz.REQ("GET", "/"))                       # nobody listens there


def test_the_command_line():
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        assert fuzz.main(["--self", "--cases", "12"]) == 0
    r = json.loads(out.getvalue())
    assert (r["fuzz_cases"], r["fuzz_divergences"], r["fuzz_hash"], r["fuzz_seed"]) == (12, 0, PINNED, 592), r
    with contextlib.redirect_stdout(io.StringIO()) as printed:
        assert fuzz.main(["--print-hash"]) == 0
    assert printed.getvalue().strip() == PINNED
    saved = os.environ.pop("TALLYBOOK_CMD", None)
    try:
        with contextlib.redirect_stderr(io.StringIO()) as e2:
            assert fuzz.main([]) == 2 and "--cmd" in e2.getvalue()
            assert fuzz.main(["--cmd", "not json"]) == 2
            assert fuzz.main(["--cmd", "[]"]) == 2
        os.environ["TALLYBOOK_CMD"] = json.dumps(SELF_CMD)
        os.environ["PYTHONPATH"] = REF
        with contextlib.redirect_stdout(io.StringIO()) as via_env:
            assert fuzz.main(["--cases", "10"]) == 0
        assert json.loads(via_env.getvalue())["fuzz_divergences"] == 0
    finally:
        os.environ.pop("PYTHONPATH", None)
        os.environ.pop("TALLYBOOK_CMD", None)
        if saved is not None:
            os.environ["TALLYBOOK_CMD"] = saved


def test_bench_fuzz_delegates_for_the_large_fixture():
    base = os.path.join(ROOT, "bench", "fuzz.py")
    p = subprocess.run([sys.executable, base, "--fixture", "large", "--print-hash"], capture_output=True, text=True)
    assert p.returncode == 0 and p.stdout.strip() == PINNED, p
    p = subprocess.run([sys.executable, base, "--print-hash"], capture_output=True, text=True)
    assert p.stdout.strip() == "5c7f3fbfa079d0caa1236e37f3fd06f0f45dc75f15b6087d4060c04ab80d5f87", p      # pennywise untouched
    p = subprocess.run([sys.executable, base, "--fixture", "pennywise", "--print-hash"], capture_output=True, text=True)
    assert p.stdout.strip() == "5c7f3fbfa079d0caa1236e37f3fd06f0f45dc75f15b6087d4060c04ab80d5f87", p
    p = subprocess.run([sys.executable, base, "--fixture", "nope", "--self"], capture_output=True, text=True)
    assert p.returncode == 2 and "unknown fixture" in p.stderr, p
    p = subprocess.run([sys.executable, base, "--fixture", "large", "--self", "--cases", "6"], capture_output=True, text=True)
    r = json.loads(p.stdout)
    assert (r["fuzz_cases"], r["fuzz_divergences"], r["fuzz_seed"]) == (6, 0, 592), p


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try: fn(); print(f"  ok: {name}")
            except AssertionError as ex: print(f"  FAIL: {name} — {ex}"); fails += 1
    print(f"── {'all pass' if not fails else str(fails)+' FAILED'}")
    sys.exit(1 if fails else 0)
