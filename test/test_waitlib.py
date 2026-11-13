"""test_waitlib.py — #1066: scripts/waitlib.py, the wait spec an engine-owned wait is made of. No network, no tmux, no lane:
real detached jobs and real files. A spec names a condition (a pid exits, a file appears, a regex appears in a log from now on,
the winsma queue, the usage limit) and a deadline; `fire` takes it exactly once and prints the message the engine resumes the
lane with (`wait done: <condition>, rc=<n>, log tail: …`)."""
import json, os, shutil, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
WAITLIB = os.path.join(ROOT, "scripts", "waitlib.py")

FAILS = []
RUN = 0


def check(cond, msg):
    global RUN
    RUN += 1
    if cond:
        print(f"  ok: {msg}")
    else:
        print(f"  FAIL: {msg}")
        FAILS.append(msg)


tmp = tempfile.mkdtemp(prefix="waitlib-")
SPEC = os.path.join(tmp, "lane.wait")
env = {k: v for k, v in os.environ.items() if not k.startswith("HARNESS_")}
env["HARNESS_WAIT_FILE"] = SPEC
started = []


def wl(*args, check_rc=None):
    p = subprocess.run([sys.executable, WAITLIB, *args], capture_output=True, text=True, env=env, timeout=60)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def spec():
    with open(SPEC, encoding="utf-8") as f:
        return json.load(f)


def wait_until(pred, secs=15):
    end = time.time() + secs
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.05)
    return False


print("== run: a detached job, its exit code, its log tail ==")
log = os.path.join(tmp, "job.log")
rc, out, _ = wl("run", "--deadline-s", "1800", "--log", log, "--", sys.executable, "-c",
                "import sys,time; print('start'); sys.stdout.flush(); time.sleep(1.2); print('all green'); sys.exit(3)")
check(rc == 0 and "wait set:" in out and "End your turn now" in out, "run prints that the wait is set and tells the lane to end its turn")
s = spec()
check(s["cond"] == "pid" and s["resume"] == "inject" and s["rc_file"] == log + ".rc" and s["log"] == log, "the spec is a pid wait on the job, with its log and rc file")
check(1790 < s["deadline"] - s["created"] <= 1800, "…and a deadline 1800 seconds out")
rc, out, _ = wl("check")
check(rc == 1 and json.loads(out)["done"] is False, "while the job runs, check says pending (exit 1)")
rc, out, _ = wl("fire")
check(rc == 1 and out == "", "…and fire takes nothing and prints nothing")
check(os.path.exists(SPEC), "…the spec stays")
check(wait_until(lambda: wl("check")[0] == 0), "the job exits: check says done (exit 0)")
c = json.loads(wl("check")[1])
check(c["rc"] == 3 and "all green" in c["tail"], "…with the job's exit code and its log tail")
rc, msg, _ = wl("fire")
check(rc == 0 and msg.startswith("wait done: pid ") and " exited, rc=3, log tail: start | all green" in msg,
      "fire prints `wait done: <condition>, rc=<n>, log tail: …`")
check(not os.path.exists(SPEC), "…and takes the spec")
rc, out, _ = wl("fire")
check(rc == 2 and out == "", "a second fire finds nothing: the lane is resumed once")

print("== fire is atomic: of many callers exactly one gets the message ==")
rc, _, _ = wl("set", "--deadline-s", "60", "--path", os.path.join(tmp, "go"))
open(os.path.join(tmp, "go"), "w").close()
with ThreadPoolExecutor(8) as ex:
    res = list(ex.map(lambda _: wl("fire"), range(8)))
check(sum(1 for r in res if r[0] == 0) == 1 and sum(1 for r in res if r[0] == 2) == 7, "one of eight concurrent fires wins, the others find no spec")

print("== set: pid, path, regex ==")
sleeper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
started.append(sleeper)
rc, out, _ = wl("set", "--deadline-s", "600", "--pid", str(sleeper.pid))
check(rc == 0 and wl("check")[0] == 1, "--pid: pending while the process lives")
sleeper.kill(); sleeper.wait()
check(wl("check")[0] == 0 and "exited" in json.loads(wl("check")[1])["reason"], "--pid: done once it exits")
wl("clear")
flag = os.path.join(tmp, "appears")
wl("set", "--deadline-s", "600", "--path", flag)
check(wl("check")[0] == 1, "--path: pending without the file")
open(flag, "w").close()
check(wl("check")[0] == 0 and "appeared" in json.loads(wl("check")[1])["reason"], "--path: done when the file appears")
wl("clear")
rlog = os.path.join(tmp, "r.log")
with open(rlog, "w") as f:
    f.write("PASS earlier run\n")
wl("set", "--deadline-s", "600", "--regex", r"^PASS .*done$", "--log", rlog)
check(wl("check")[0] == 1, "--regex: a line written BEFORE the spec does not match")
with open(rlog, "a") as f:
    f.write("PASS x\n")
check(wl("check")[0] == 1, "…nor a line that does not match")
with open(rlog, "a") as f:
    f.write("PASS all done\n")
check(wl("check")[0] == 0, "…a matching line appended after it does")
rc, msg, _ = wl("fire")
check(rc == 0 and msg.startswith("wait done: /^PASS .*done$/ matched in ") and msg.endswith("PASS all done"), "…and the message carries the log tail")
rc, _, err = wl("set", "--regex", "x")
check(rc != 0 and "--regex needs --log" in err, "--regex without --log is refused")
rc, _, err = wl("set", "--deadline-s", "10")
check(rc != 0 and "exactly one of" in err, "a spec without a condition is refused")

print("== the deadline ==")
wl("clear")
sleeper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
started.append(sleeper)
wl("set", "--deadline-s", "1", "--pid", str(sleeper.pid))
check(wl("check")[0] == 1, "before the deadline the job is pending")
time.sleep(1.3)
rc, msg, _ = wl("fire")
check(rc == 0 and msg.startswith("wait done: deadline passed (pid ") and ", rc=-, log tail: (empty)" in msg,
      "past it the lane is resumed anyway, naming the deadline, with rc=- and an empty tail")
sleeper.kill(); sleeper.wait()
wl("set", "--pid", "999999", "--deadline-s", "99999999")
check(0 < spec()["deadline"] - spec()["created"] <= 24 * 3600, "no deadline is longer than 24 hours")
wl("set", "--pid", "999999")
check(spec()["deadline"] - spec()["created"] == 6 * 3600, "a spec without one gets 6 hours")
wl("clear")

print("== the conditions the engine judges: winsma, limit ==")
wl("set", "--deadline-s", "600", "--winsma", "77", "--slug", "acme/widget", "--label", "waiting-winsma")
rc, out, _ = wl("check")
check(rc == 3 and json.loads(out)["done"] is False, "winsma: check leaves it to the engine (exit 3)")
check(wl("fire")[0] == 1, "…fire does not take it")
rc, msg, _ = wl("fire", "--satisfied", "#77 is first in the winsma queue")
check(rc == 0 and msg.startswith("wait done: #77 is first in the winsma queue, rc=-,"), "…the engine fires it with its own reason")
until = time.time() + 5
wl("set", "--limit", "--until", str(until), "--account", "acct1", "--what", "usage limit (resets 5pm)")
s = spec()
check(s["cond"] == "limit" and s["not_before"] == until and s["account"] == "acct1" and s["deadline"] == 0, "limit: the spec holds the earliest time and the account, no deadline")
check(wl("check")[0] == 3 and wl("fire")[0] == 1, "…and is the engine's to judge")
check(wl("fields", "cond", "account", "not_before")[1].split("\t")[:2] == ["limit", "acct1"], "fields prints the named fields on one line")
wl("clear")
# #1100: a limit park whose deadline ends before --until would wake the lane into a limit that has not cleared (the spec is
# consumed, the lane idles with none). Refused, and no spec is written; a deadline at or past --until, or none, is fine.
far = time.time() + 3 * 86400
rc, out, err = wl("set", "--limit", "--until", str(far), "--deadline-s", "20")
check(rc != 0 and "must not end before --until" in err and "omit --deadline-s" in err, "limit: a --deadline-s that ends before --until is refused with a clear message")
check(not os.path.exists(SPEC), "…and no spec is written")
rc, _, err = wl("set", "--limit", "--until", str(time.time() + 90000), "--deadline-s", "999999")
check(rc != 0 and "must not end before --until" in err, "…the 24 h cap counts: a deadline clamped to 24 h still ends before an --until further out")
wl("set", "--limit", "--until", str(time.time() + 600), "--deadline-s", "3600")
check(spec()["cond"] == "limit" and spec()["deadline"] > spec()["not_before"], "limit: a deadline past --until is accepted")
wl("clear")
wl("set", "--limit", "--until", str(far))
check(spec()["deadline"] == 0 and spec()["not_before"] == far, "limit: no --deadline-s still parks until the reset")
wl("clear")

print("== the redispatch park (winsma.sh park, #1034) ==")
d = os.path.join(tmp, "run"); os.makedirs(d)
wl("set", "--file", os.path.join(d, "hz-main-i5.wait"), "--winsma", "5", "--resume", "redispatch", "--deadline-s", "600")
wl("set", "--file", os.path.join(d, "hz-main-i6.wait"), "--winsma", "6", "--deadline-s", "600")
wl("set", "--file", os.path.join(d, "hz-main-i7.wait"), "--pid", "999999", "--resume", "redispatch")
rc, out, _ = wl("parked", "--dir", d)
rows = [l.split("\t") for l in out.splitlines()]
check(rc == 0 and [r[1] for r in rows] == ["5"] and int(rows[0][2]) > time.time(), "parked lists the redispatch winsma specs only: issue and deadline")
wl("forget", "--dir", d, "--issue", "5")
check(wl("parked", "--dir", d)[1] == "" and os.path.exists(os.path.join(d, "hz-main-i6.wait")), "forget drops that issue's park and nothing else")

print("== a native Windows job is judged by its Windows pid, not an MSYS pid (#1109) ==")
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import waitlib  # noqa: E402
seen = []
real_alive = waitlib.portable.win_process_alive
try:
    for alive in (True, False):
        waitlib.portable.win_process_alive = lambda w, alive=alive: seen.append(w) or alive
        ev = waitlib.evaluate({"cond": "pid", "pid": 999999, "winpid": 4242, "deadline": time.time() + 600})
        check(ev["done"] is (not alive), f"a spec with a winpid is {'pending' if alive else 'done'} when its Windows process is {'alive' if alive else 'gone'}")
    check(seen == [4242, 4242], "…and the Windows pid is the one asked about")
finally:
    waitlib.portable.win_process_alive = real_alive
check(waitlib.evaluate({"cond": "pid", "pid": 999999, "deadline": time.time() + 600})["done"] is True,
      "a spec with no winpid (an MSYS or POSIX pid) is still read as before: a dead pid is done")

for p in started:
    try:
        p.kill()
    except OSError:
        pass
shutil.rmtree(tmp, ignore_errors=True)
print(f"── {RUN - len(FAILS)}/{RUN} passed")
sys.exit(1 if FAILS else 0)
