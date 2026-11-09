#!/usr/bin/env bash
# test_python_lf.sh — #609 (PRD #475, Solution 6): a native Windows Python writes "\n" to stdout as CRLF, so a
# `$(python3 …)` read a stray CR and a Python-rendered prompt carried CRLF (found by the first full-suite run on winsma:
# fake `gh` stubs written in Python, `render`, the poller). install.sh's python3 shim therefore puts a sitecustomize on
# PYTHONPATH that sets stdout and stderr to "\n" (install.sh python_lf_dir; the winsma suite stage does the same for its
# venv python). Linux has no CRLF text layer, so the sitecustomize is run against streams that have one.
# Covered: python_lf_dir's file turns a CRLF stdout/stderr into LF and survives a stream it cannot reconfigure; the shim
# (forced Windows) hands its interpreter a PYTHONPATH naming the pylf dir, keeps what PYTHONPATH held, names it once; the
# interpreter really imports the sitecustomize; Linux installs write no shim and no pylf.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$(cd "$HERE/.." && pwd)"
source "$HERE/helpers.sh"
T="$(mktemp -d)"; tmp_track "$T"; trap tmp_cleanup EXIT
PY="$(command -v python3)"
pin_host_home "$T/pin"

echo "=== python_lf_dir: stdout and stderr write LF where the platform's text layer would write CRLF ==="
( HARNESS_INSTALL_NOMAIN=1 source "$R/install.sh"; python_lf_dir "$T/lf" ) >/dev/null 2>&1
assert_ok "python_lf_dir wrote sitecustomize.py"                  test -f "$T/lf/sitecustomize.py"
cat >"$T/crlf.py" <<'EOF'
import io, sys
src = open(sys.argv[1]).read()
def crlf(): return io.TextIOWrapper(io.BytesIO(), newline="\r\n", write_through=True)
sys.stdout, sys.stderr = crlf(), crlf()
sys.stdout.write("a\n"); sys.stderr.write("b\n")
before = (sys.stdout.buffer.getvalue(), sys.stderr.buffer.getvalue())
exec(compile(src, "sitecustomize.py", "exec"))
sys.stdout.write("c\n"); sys.stderr.write("d\n")
out, err = sys.stdout.buffer.getvalue(), sys.stderr.buffer.getvalue()
class NoReconfigure:                       # a stream without reconfigure() must not break the interpreter's start
    def write(self, s): pass
sys.stdout = sys.stderr = NoReconfigure()
exec(compile(src, "sitecustomize.py", "exec"))
sys.__stdout__.write("%r %r\n" % (before, (out, err)))
EOF
got="$("$PY" "$T/crlf.py" "$T/lf/sitecustomize.py" 2>&1)"
assert_eq "$got" "(b'a\\r\\n', b'b\\r\\n') (b'a\\r\\nc\\n', b'b\\r\\nd\\n')" "before: CRLF as a Windows stream writes it; after the sitecustomize: LF"

echo "=== the python3 shim (forced Windows) ==="
H="$T/home"
shimrun(){ ( unset PYTHONPATH; export HARNESS_HOME="$H" HARNESS_PLATFORM=windows HARNESS_PYTHON="$PY"; HARNESS_INSTALL_NOMAIN=1 source "$R/install.sh"; install_python_shim ) >/dev/null 2>&1; }
shimrun; shimrun
assert_ok "the shim is written"                                   test -x "$H/bin/python3"
assert_ok "… with its pylf sitecustomize beside it"               test -f "$H/bin/pylf/sitecustomize.py"
# the shim names the pylf dir the way a native program reads it (cygpath -w, C:\\…) on a real Windows host, and the suite stage
# exports its own PYTHONPATH (its pylf) to everything it runs: the shim cells start from none (#686)
LFD="$H/bin/pylf"; real_windows_host && LFD="$(cygpath -w "$LFD")"
shimpy(){ ( unset PYTHONPATH; [[ $# -gt 0 ]] && export PYTHONPATH="$1"; "$H/bin/python3" -c 'import os; print(os.environ["PYTHONPATH"])' ); }
assert_eq "$(shimpy)" "$LFD" "the interpreter gets the pylf dir as PYTHONPATH"
assert_eq "$(shimpy /opt/mine)" "$LFD;/opt/mine" "… ahead of a PYTHONPATH the caller already had"
assert_eq "$(shimpy "$LFD")" "$LFD" "… and once, when a shim run already named it (a python3 that starts a python3)"
assert_eq "$(unset PYTHONPATH; "$H/bin/python3" -c 'import sys; print(sys.modules["sitecustomize"].__file__)')" "$LFD/sitecustomize.py" "the interpreter imported that sitecustomize"
echo "=== Linux writes neither ==="
H2="$T/home2"
( unset PYTHONPATH; export HARNESS_HOME="$H2" HARNESS_PLATFORM=posix; HARNESS_INSTALL_NOMAIN=1 source "$R/install.sh"; install_python_shim ) >/dev/null 2>&1
assert_no "no shim off Windows"                                   test -e "$H2/bin/python3"
assert_no "… and no pylf"                                         test -e "$H2/bin/pylf"
finish
