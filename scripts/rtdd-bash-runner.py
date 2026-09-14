#!/usr/bin/env python3
"""rtdd runner for this repo's shell test suite.

rtdd selects tests from per-test coverage recorded by a real run, and ships no adapter that
can instrument bash — `rtdd init` refuses a repo it cannot instrument rather than promise a
selection it cannot make. This runner is what makes the refusal unnecessary here: bash can
record its own execution.

    env PS4='@@${BASH_SOURCE}:${LINENO}@@ ' BASH_XTRACEFD=21 SHELLOPTS=xtrace bash <test> 21>trace

SHELLOPTS is inherited by every child bash, and fd 21 survives exec, so one test's trace
carries every line executed in the test, in the helpers it sources, AND in the scripts under
test that it spawns as separate processes. That is genuine line-level, per-test, execution-
derived coverage — the same fidelity coverage.py gives Python, by a different road.

Two things it records that a line tracer alone would miss:

  * DATA FILES. Most of this suite's assertions are `grep -q <pattern> prompts/impl.md` —
    the file under test is never executed, it is read. The trace line carries the expanded
    argv, so any repo file named by a traced command is recorded as covered, whole. A read
    of a file IS a read of all of it; the alternative is a map that says no test covers
    prompts/impl.md while six tests assert on its contents.
  * test_*.py. Run under sys.settrace, same accumulator, same output.

Output is what rtdd's coverage tier expects: a coverage.py-schema `.coverage` SQLite store
with one dynamic context per test, and a JUnit report at .rtdd/junit.xml whose testcase
file= attribute is the id_template's {file}.

What it cannot see, stated plainly, because a selector that hides its blind spots is worse than
no selector:

  * REDIRECTIONS. xtrace prints the command, never its redirections, so `cat < data.txt`,
    heredocs, `read < f` and `mapfile < f` are invisible. A file read only that way gets no edge.
  * FD-SCRUBBED CHILDREN. BASH_XTRACEFD=21 is inherited through the environment, but a child
    reached via a spawner that closes inherited fds (Python's subprocess defaults to
    close_fds=True) finds fd 21 shut, and bash then writes its trace to STDERR instead. Two
    consequences: that child's coverage is lost, and its stderr now carries trace text — which is
    why strip_trace() runs over anything that reaches the report, and why a test that parses its
    own children's stderr can see text it did not produce.
  * `--flag=path` ARGUMENTS are skipped with the rest of the `-`-prefixed tokens.
  * A file is credited only if some test NAMED it or EXECUTED it. Nothing infers a dependency.

Usage:
    rtdd-bash-runner.py [--list] [--fail-fast] [test ...]      no tests = the full suite
"""
import os
import re
import shlex
import sqlite3
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CWD = ROOT / "test"        # every test runs here, so a relative BASH_SOURCE resolves against THIS
TRACE_FD = 21           # 8 and 9 are taken by the poller's flock; 21 is free repo-wide
REPORT = ROOT / ".rtdd" / "junit.xml"
COVERAGE_DB = ROOT / ".coverage"
PS4 = "@@${BASH_SOURCE}:${LINENO}@@ "
_TRACE_LINE = re.compile(r"^@+[^@]*@@ ")   # a trace line at any nesting depth


def discover():
    return sorted(
        str(p.relative_to(ROOT))
        for p in (ROOT / "test").iterdir()
        if p.name.startswith("test_") and p.suffix in (".sh", ".py")
    )


def isolate_env(tmp):
    """The hermeticity guard test/run.sh applies, applied the same way here.

    lib.sh reads STATE_DIR and the HARNESS_* host paths from the environment, and a live
    fleet exports its own to every child — so a suite run from inside an agent session would
    point these tests at a REAL project's .harness/ and at the shared host registry that
    `doctor --fix` deletes from. Each test gets its own throwaway root instead.
    """
    env = dict(os.environ)
    for k in list(env):
        if k.startswith("HARNESS_") or k in ("STATE_DIR", "CONFIG", "WORKTREES_DIR", "CHECKOUTS_DIR"):
            del env[k]
    state = Path(tmp) / ".harness"
    host = Path(tmp) / "host"
    for d in (state / "worktrees", state / "checkouts", state / "run" / "claims",
              host / "poller" / "registry", host / "snapshots", host / "fleets"):
        d.mkdir(parents=True, exist_ok=True)
    env.update(
        STATE_DIR=str(state),
        HARNESS_HOME=str(host),
        HARNESS_POLLER_DIR=str(host / "poller"),
        HARNESS_SNAPSHOTS_DIR=str(host / "snapshots"),
        HARNESS_FLEETS_DIR=str(host / "fleets"),
    )
    return env


# Commands that READ a file named in their argv. The harvest is restricted to these on purpose:
# `[[ -f x ]]` tests for a file without reading it, `ls test_*.sh` names fifty, and `cp a b` names a
# destination — each of which credited coverage for a file nothing read. A reader's argument, by
# contrast, really was consumed.
READERS = {"grep", "egrep", "fgrep", "rg", "cat", "head", "tail", "sed", "awk", "gawk", "diff",
           "cmp", "jq", "sort", "uniq", "wc", "cut", "tr", "md5sum", "sha256sum", "python3",
           "source", ".", "read", "mapfile", "readarray", "xargs", "envsubst", "yq"}
# For these the FIRST non-option argument is a PATTERN, not a file — and this suite greps for
# things like 'scripts/rtdd-bash-runner.py', which resolves to a real file nothing read.
PATTERN_FIRST = {"grep", "egrep", "fgrep", "rg", "sed", "awk", "gawk"}


def repo_rel(token, base=None):
    """A traced token as a repo-relative path, or None if it is not a repo file.

    xtrace prints EXPANDED words, so `"$HERE/../prompts/impl.md"` arrives absolute and a fixture
    copy under /tmp arrives absolute too — outside ROOT, and dropped here, which is what keeps a
    test's own scratch copies out of the map. A RELATIVE token is resolved against the test cwd,
    not the repo root: tests run in test/ and write `source ../scripts/lib.sh`, which resolved
    against ROOT lands outside the repo and silently loses that file's coverage entirely.
    """
    if not token or token.startswith("-"):
        return None
    try:
        p = Path(token)
        p = p if p.is_absolute() else (base or CWD) / p
        p = p.resolve()
        rel = p.relative_to(ROOT)
    except (ValueError, OSError):
        return None
    # .rtdd/junit.xml and .rtdd/meta.json are rewritten by every run; recording them would churn
    # every row. The adapter and the map itself are ordinary tracked files and stay recordable.
    if not p.is_file() or str(rel) in (".rtdd/junit.xml", ".rtdd/meta.json", ".coverage"):
        return None
    if str(rel).startswith((".git/", "worktrees/", "checkouts/", "run/")):
        return None
    return str(rel)


_EXECUTABLE_CACHE = {}


def is_executable_source(rel):
    """Is this a file whose OWN execution the tracer records line by line?

    The distinction decides how an argv reference is credited, and getting it wrong makes the
    uncovered report vacuous. A test that names `scripts/uninstall.sh` and runs it produces real
    per-line coverage from that child shell's own xtrace — crediting the whole file on top of it
    overwrites a 40%-covered file with 100% and no changed line can ever come back uncovered.
    A test that names `prompts/impl.md` in a `grep` produces no trace of its own, and there the
    whole-file credit IS the honest answer: the grep read all of it.
    """
    if rel in _EXECUTABLE_CACHE:
        return _EXECUTABLE_CACHE[rel]
    verdict = rel.endswith((".sh", ".py"))
    if not verdict:
        try:
            with (ROOT / rel).open("rb") as fh:
                verdict = fh.read(2) == b"#!"
        except OSError:
            verdict = False
    _EXECUTABLE_CACHE[rel] = verdict
    return verdict


def whole_file(rel):
    try:
        n = sum(1 for _ in (ROOT / rel).open("rb"))
    except OSError:
        return []
    return list(range(1, max(n, 1) + 1))


def parse_trace(path, cov):
    """Fold one test's xtrace into cov[file] -> set(lines)."""
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            if not line.startswith("@@"):
                continue
            # Bash repeats the FIRST CHARACTER of PS4 once per level of indirection, so a line from
            # inside a $(...) or a function call arrives as `@@@src:N@@ cmd` and one nested twice as
            # `@@@@src:N@@ cmd`. Parsing a fixed two-character prefix dropped every one of them —
            # measured at 52% of a real test's trace, i.e. every command substitution and pipeline
            # element. Strip the whole run of '@' instead; the delimiter after the payload is fixed.
            head, _, cmd = line.lstrip("@").partition("@@ ")
            src, _, lineno = head.rpartition(":")
            rel = repo_rel(src)
            if rel and lineno.isdigit():
                cov.setdefault(rel, set()).add(int(lineno))
            try:
                tokens = shlex.split(cmd)
            except ValueError:
                tokens = cmd.split()
            if not tokens:
                continue
            argv0 = Path(tokens[0]).name
            args = tokens[1:]
            if argv0 in PATTERN_FIRST:
                for i, t in enumerate(args):
                    if not t.startswith("-"):
                        args = args[:i] + args[i + 1:]   # drop the pattern, keep the files
                        break
            for tok in args:
                data = repo_rel(tok)
                if not data or data == rel:
                    continue
                if is_executable_source(data):
                    # A REFERENCE marker, never whole-file: one line, so the file joins this
                    # test's row and a change to it still selects this test, while the file's
                    # real line coverage stays whatever actually executed. Line 1 because it is
                    # the shebang — the one line whose "covered" verdict claims nothing.
                    cov.setdefault(data, set()).add(1)
                elif argv0 in READERS:
                    cov.setdefault(data, set()).update(whole_file(data))


PY_TRACER = r"""
import json, runpy, sys
hits = {}
root = sys.argv[1]
target = sys.argv[2]
out = sys.argv[3]
def tracer(frame, event, arg):
    if event == "call":
        return tracer
    if event == "line":
        f = frame.f_code.co_filename
        if f.startswith(root):
            hits.setdefault(f[len(root):].lstrip("/"), set()).add(frame.f_lineno)
    return tracer
sys.argv = [target]
sys.settrace(tracer)
code = 0
try:
    runpy.run_path(target, run_name="__main__")
except SystemExit as e:
    code = e.code if isinstance(e.code, int) else 1
finally:
    sys.settrace(None)
    json.dump({k: sorted(v) for k, v in hits.items()}, open(out, "w"))
sys.exit(code)
"""


def run_one(test, env_root):
    """Run one test with tracing. Returns (exit_code, output, {file: set(lines)})."""
    cov = {}
    with tempfile.TemporaryDirectory(dir=env_root) as tmp:
        env = isolate_env(tmp)
        if test.endswith(".py"):
            hits = Path(tmp) / "pyhits.json"
            proc = subprocess.run(
                [sys.executable, "-c", PY_TRACER, str(ROOT), str(ROOT / test), str(hits)],
                cwd=CWD, env=env, capture_output=True, text=True)
            if hits.exists():
                import json
                for f, lines in json.loads(hits.read_text()).items():
                    cov.setdefault(f, set()).update(lines)
            return proc.returncode, proc.stdout + proc.stderr, cov

        trace = Path(tmp) / "trace"
        # The wrapper opens fd 21 itself and re-execs through `env`, because neither half
        # can be done from here: a bare `pass_fds` lands the trace on whatever number
        # Python picked, and SHELLOPTS is readonly inside a shell, so it can only be set
        # by the process that starts bash. `env` is that process.
        env["PS4"] = PS4
        proc = subprocess.run(
            ["bash", "-c", 'exec 21>"$1"; exec env SHELLOPTS=xtrace BASH_XTRACEFD=21 bash "$2"',
             "_", str(trace), str(ROOT / test)],
            cwd=CWD, env=env, capture_output=True, text=True)
        parse_trace(trace, cov)
        return proc.returncode, proc.stdout + proc.stderr, cov


def numbits(lines):
    """coverage.py's packed line bitmap: byte i, bit j set means line i*8+j."""
    if not lines:
        return b""
    buf = bytearray(max(lines) // 8 + 1)
    for n in lines:
        buf[n // 8] |= 1 << (n % 8)
    return bytes(buf)


def write_coverage(per_test):
    if COVERAGE_DB.exists():
        COVERAGE_DB.unlink()
    db = sqlite3.connect(COVERAGE_DB)
    db.executescript("""
        CREATE TABLE meta (key TEXT, value TEXT, UNIQUE (key));
        CREATE TABLE file (id INTEGER PRIMARY KEY, path TEXT, UNIQUE (path));
        CREATE TABLE context (id INTEGER PRIMARY KEY, context TEXT, UNIQUE (context));
        CREATE TABLE line_bits (file_id INTEGER, context_id INTEGER, numbits BLOB,
                                UNIQUE (file_id, context_id));
    """)
    db.execute("INSERT INTO meta (key, value) VALUES ('has_arcs', '0')")
    files, ctxs = {}, {}
    for test, cov in per_test.items():
        ctxs.setdefault(test, len(ctxs) + 1)
        db.execute("INSERT OR IGNORE INTO context (id, context) VALUES (?, ?)", (ctxs[test], test))
        for path, lines in cov.items():
            files.setdefault(path, len(files) + 1)
            db.execute("INSERT OR IGNORE INTO file (id, path) VALUES (?, ?)", (files[path], path))
            db.execute("INSERT OR REPLACE INTO line_bits (file_id, context_id, numbits) VALUES (?, ?, ?)",
                       (files[path], ctxs[test], numbits(sorted(lines))))
    db.commit()
    db.close()


def strip_trace(text):
    """Drop xtrace lines from captured output.

    BASH_XTRACEFD=21 is inherited by every descendant, and one that arrives through a process
    which closes inherited fds (Python's subprocess defaults to close_fds=True) finds fd 21 shut
    and bash falls back to writing xtrace on STDERR — which is captured, and which write_report
    embeds in a failure. Command text does not belong in a report that can be committed.
    """
    text = "\n".join(l for l in text.splitlines() if not _TRACE_LINE.match(l))
    # C0 control bytes are not legal XML 1.0 and ElementTree writes them through verbatim. Go's
    # decoder then rejects the whole report — one test's `tput` escape aborts the entire run rather
    # than reporting one failure. scripts/status.sh uses tput, so this is reachable.
    return re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", text)


def write_report(results):
    suite = ET.Element("testsuite", name="harness", tests=str(len(results)))
    for test, (code, output, elapsed) in results.items():
        case = ET.SubElement(suite, "testcase", classname="test", name=Path(test).name,
                             file=test, time=f"{elapsed:.3f}")
        if code != 0:
            fail = ET.SubElement(case, "failure", message=f"exit {code}")
            fail.text = strip_trace(output)[-4000:]
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(suite).write(REPORT, encoding="utf-8", xml_declaration=True)


def selfcheck():
    """The two pure functions everything else trusts. Run by test/test_rtdd.sh."""
    # numbits is coverage.py's format, not ours: byte i, bit j set means line i*8+j.
    assert numbits([]) == b""
    assert numbits([1]) == b"\x02", numbits([1])
    assert numbits([8]) == b"\x00\x01", numbits([8])
    assert numbits([1, 3, 8]) == b"\x0a\x01", numbits([1, 3, 8])
    got = set()
    for n in (1, 7, 8, 63, 64):
        bits = numbits([n])
        got.update(i * 8 + j for i, b in enumerate(bits) for j in range(8) if b >> j & 1)
    assert got == {1, 7, 8, 63, 64}, got
    # repo_rel keeps repo files and drops everything else — a fixture copy under /tmp is
    # what would otherwise put a test's own scratch tree into the map.
    # A relative token is resolved against the TEST cwd, which is where every test actually runs.
    # Resolving it against ROOT put `source ../scripts/lib.sh` outside the repo, which is how
    # scripts/doctor.sh ended up with zero tests in the map while test_doctor.sh exists to test it.
    assert repo_rel("../scripts/lib.sh") == "scripts/lib.sh"
    assert repo_rel("./helpers.sh") == "test/helpers.sh"
    assert repo_rel(str(ROOT / "README.md")) == "README.md"
    assert repo_rel(".rtdd/meta.json", base=ROOT) is None      # per-run state never enters a row
    assert repo_rel("/etc/hostname") is None
    assert repo_rel("-q") is None
    assert repo_rel("no/such/file") is None
    assert repo_rel(".git/config") is None
    # The distinction that decides whether the uncovered report means anything. Crediting an
    # executed script whole — which an earlier version did — put every file a test NAMES at 100%,
    # and no changed line could ever come back uncovered.
    assert is_executable_source("scripts/lib.sh")
    assert is_executable_source("scripts/issuelib.py")
    assert is_executable_source("bin/harness")          # no extension; shebang decides
    assert not is_executable_source("prompts/impl.md")
    assert not is_executable_source("README.md")
    cov = {}
    import tempfile as _tf
    with _tf.NamedTemporaryFile("w", suffix=".trace", delete=False) as fh:
        # a line that ran in lib.sh, plus two argv references: one script, one data file
        # xtrace quotes a word containing spaces, and this repo's own path has one — so the
        # fixture must quote too, or it would not be testing what bash actually writes.
        q = shlex.quote
        fh.write("@@%s:7@@ grep -q x %s\n" % (ROOT / "scripts/lib.sh", q(str(ROOT / "prompts/impl.md"))))
        fh.write("@@%s:3@@ bash %s\n" % (ROOT / "test/run.sh", q(str(ROOT / "scripts/lib.sh"))))
        # nested twice: bash repeats PS4's first char per level, and these used to be dropped whole
        fh.write("@@@@../scripts/drive.sh:11@@ dirname %s\n" % q(str(ROOT / "README.md")))
        # a non-reader naming a data file must NOT credit it
        fh.write("@@%s:9@@ [[ -f %s ]]\n" % (ROOT / "test/run.sh", q(str(ROOT / ".gitattributes"))))
        # a grep PATTERN that happens to name a real file is not a read of that file
        fh.write("@@%s:12@@ grep -q %s %s\n" % (ROOT / "test/run.sh", q("scripts/lib.sh"),
                                                q(str(ROOT / "LICENSE"))))
        trace = fh.name
    parse_trace(trace, cov)
    os.unlink(trace)
    assert cov["scripts/lib.sh"] == {1, 7}, cov["scripts/lib.sh"]          # executed line + marker
    assert len(cov["prompts/impl.md"]) == sum(1 for _ in (ROOT / "prompts/impl.md").open("rb"))
    assert cov["test/run.sh"] == {3, 9, 12}, cov["test/run.sh"]
    assert cov["scripts/lib.sh"] == {1, 7}, "a grep pattern must not become a covered file"
    assert len(cov["LICENSE"]) == sum(1 for _ in (ROOT / "LICENSE").open("rb"))   # the FILE is read
    assert cov["scripts/drive.sh"] == {11}, cov["scripts/drive.sh"]   # nesting prefix parsed
    assert "README.md" not in cov, "dirname is not a reader"          # harvest restricted
    assert ".gitattributes" not in cov, "[[ -f ]] does not read a file"
    # A failing test must stay failed in the report, and no trace line may reach it.
    assert strip_trace("keep\n@@/x/y:3@@ secret --token abc\nkeep2") == "keep\nkeep2"
    print("selfcheck ok")
    return 0


def main(argv):
    if "--selfcheck" in argv:
        return selfcheck()
    fail_fast = "--fail-fast" in argv
    listing = "--list" in argv
    tests = [a for a in argv if not a.startswith("-")] or discover()
    per_test, results, rc = {}, {}, 0
    with tempfile.TemporaryDirectory(prefix="rtdd-bash-") as env_root:
        for test in tests:
            started = time.time()
            code, output, cov = run_one(test, env_root)
            elapsed = time.time() - started   # the traced run only; a rescue below must not inflate it
            if code != 0:
                # Re-run clean for EVIDENCE, never for absolution. A test that fails traced and
                # passes clean is either a tracing artifact or a flaky test, and nothing here can
                # tell those apart — a flaky test is how an intermittent real bug presents. The
                # exit code is the lane's test bar (the prompts gate on it), so a retry-until-green
                # here would silently hand back a pass. Record the failure, say what the re-run did.
                # Its own tmp dir, and the same interpreter dispatch as the traced run: sharing
                # env_root let one rescued test see the next one's fleet registry, and running a
                # .py test through `bash` made its exit code meaningless.
                argv = ([sys.executable, str(ROOT / test)] if test.endswith(".py")
                        else ["bash", str(ROOT / test)])
                with tempfile.TemporaryDirectory(dir=env_root) as rescue_tmp:
                    clean = subprocess.run(argv, cwd=CWD, env=isolate_env(rescue_tmp),
                                           capture_output=True, text=True)
                verdict = ("passed clean — SUSPECT TRACING ARTIFACT, still reported as a failure"
                           if clean.returncode == 0 else
                           f"also failed clean (exit {clean.returncode}) — a real failure")
                output = f"{output}\n\n[rtdd-bash-runner] re-ran untraced: {verdict}\n"
                print(f"  note: {test} failed traced, {verdict}", file=sys.stderr)
            results[test] = (code, output, elapsed)
            per_test[test] = cov
            print(f"{'FAIL' if code else 'ok  '}  {test}", file=sys.stderr)
            if code:
                rc = 1
                if fail_fast:
                    break
    write_coverage(per_test)
    write_report(results)
    if listing:
        for t in tests:
            print(t)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
