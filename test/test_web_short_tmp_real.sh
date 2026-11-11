#!/usr/bin/env bash
# rtdd: always
# test_web_short_tmp_real.sh — #1080: headless Chrome makes a unix socket at $TMPDIR/org.chromium.Chromium.XXXXXX/SingletonSocket (TMPDIR + 45
# bytes) and aborts with "Socket path too long" past the AF_UNIX limit (107 bytes). The release gate's TMPDIR, plus run.sh's per-test
# nesting, came to 66 bytes: every browser-driven web test went red under the gate. test/web_cdp.mjs now launches the browser with a private
# TMPDIR directly under /tmp (the browser-side twin of tmux_short_dir, #1077), so the launch holds whatever the caller's TMPDIR is.
#   control — Chrome spawned the old way, with the deep TMPDIR, dies with "Socket path too long" (the guard is known to catch the bug)
#   launch  — web_fixture.cdp() under that TMPDIR opens a page, and the browser process's own TMPDIR is a short dir under /tmp
#   hygiene — no hxcdp.* dir is left in /tmp once the browser is closed, and a browser that dies on start names its FATAL line
# SKIP (exit 0) when there is no Chrome or no Node >= 22. Needs no tmux. Kills only the browser it started.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
unset_inherited_config
browser="${HARNESS_WEB_BROWSER:-$(command -v google-chrome || command -v chromium || true)}"
[[ -n $browser ]] || { echo "  SKIP: no Chrome (HARNESS_WEB_BROWSER)"; exit 0; }
command -v node >/dev/null 2>&1 && [[ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)" -ge 22 ]] 2>/dev/null \
  || { echo "  SKIP: needs Node >= 22"; exit 0; }
[[ "$(uname -s)" == Linux ]] || { echo "  SKIP: the singleton socket is a Linux/macOS unix socket"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "  SKIP: python3 missing"; exit 0; }

ROOT="$(mktemp -d)"; tmp_track "$ROOT"
deep="$ROOT"; while (( ${#deep} < 150 )); do deep="$deep/$(printf 'x%.0s' {1..40})"; done
mkdir -p "$deep"
flags=(--headless=new --remote-debugging-port=0 --no-first-run --no-default-browser-check --disable-gpu --no-sandbox about:blank)

# the old way: Chrome spawned with the deep TMPDIR — proves the probe below would have caught the bug
ctl="$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="$deep" timeout 20 "$browser" "${flags[@]}" 2>&1 | head -c 4000)"
assert_ok "(control) Chrome under a $(( ${#deep} ))-byte TMPDIR dies with 'Socket path too long'" grep -q "Socket path too long" <<<"$ctl"

before="$(ls -d /tmp/hxcdp.* 2>/dev/null | sort)"
out="$(env -i PATH="$PATH" HOME="$HOME" LANG=C.UTF-8 TMPDIR="$deep" HX_BROWSER="$browser" HX_HERE="$HERE" python3 -I - <<'PY'
import os, sys
sys.path.insert(0, os.environ["HX_HERE"])
import web_fixture as wf
def descendants(pid):
    kids = {}
    for p in os.listdir("/proc"):
        if p.isdigit():
            try:
                kids.setdefault(int(open(f"/proc/{p}/stat").read().rsplit(")", 1)[1].split()[1]), []).append(int(p))
            except OSError:
                pass
    todo, seen = [pid], []
    while todo:
        n = todo.pop()
        for k in kids.get(n, []):
            seen.append(k); todo.append(k)
    return seen
with wf.serving(tmux_ls="", now=wf.NOW) as (base, host):
    with wf.cdp(os.environ["HX_BROWSER"], base + "/") as page:
        print("title", page.eval("document.readyState"))
        for pid in descendants(page.proc.pid):
            try:
                env = dict(e.split("=", 1) for e in open(f"/proc/{pid}/environ").read().split("\0") if "=" in e)
            except OSError:
                continue
            if "TMPDIR" in env:
                print("tmpdir", env["TMPDIR"], len(env["TMPDIR"]) + 45); break
PY
)"
assert_eq "$(sed -n 's/^title //p' <<<"$out")" "complete" "web_fixture.cdp() opens a page under a TMPDIR of ${#deep} bytes"
td="$(sed -n 's/^tmpdir //p' <<<"$out" | awk '{print $1}')"; sock="$(sed -n 's/^tmpdir //p' <<<"$out" | awk '{print $2}')"
case "$td" in /tmp/hxcdp.*) r=ok;; *) r="[$td]";; esac
assert_eq "$r" "ok" "the browser process's TMPDIR is a private dir directly under /tmp"
assert_ok "…and its SingletonSocket path is under 107 bytes ($sock)" test "${sock:-999}" -lt 107
after="$(ls -d /tmp/hxcdp.* 2>/dev/null | sort)"
assert_eq "$(comm -13 <(echo "$before") <(echo "$after"))" "" "no hxcdp.* dir is left in /tmp after the browser closes"

# a browser that dies before DevTools listens: its FATAL line reaches the error, not just a register dump
fake="$ROOT/fakechrome"; printf '#!/bin/sh\necho "FATAL:chrome/browser/process_singleton_posix.cc:313] Socket path too long: /x/SingletonSocket." >&2\ni=0; while [ $i -lt 60 ]; do echo "rax=0000 rbx=0000 rcx=0000 rdx=0000 rsi=0000 rdi=0000" >&2; i=$((i+1)); done\nexit 134\n' > "$fake"; chmod +x "$fake"
err="$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="$deep" node "$HERE/web_cdp.mjs" "$fake" about:blank 2>&1 | head -c 4000)"
assert_ok "an early browser exit reports Chrome's FATAL line" grep -q "Socket path too long" <<<"$err"
after="$(ls -d /tmp/hxcdp.* 2>/dev/null | sort)"
assert_eq "$(comm -13 <(echo "$before") <(echo "$after"))" "" "…and leaves no hxcdp.* dir behind"
finish
