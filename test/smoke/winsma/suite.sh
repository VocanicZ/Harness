# suite.sh — the full test suite, test/run.sh, on a real Windows host (#492, PRD #475 Solution 6).
# NOT run by test/run.sh: it is the script `winsma.sh run <issue> suite "$(cat suite.sh)"` sends to the host, where it runs in
# Git Bash inside C:\hx-<issue>\ (cwd = $HX_DIR) in the `suite` isolation: HARNESS_HOME, HARNESS_BIN_DIR, HARNESS_USER_SKILLS,
# CLAUDE_CONFIG_DIR, TMPDIR, npm_config_cache AND HOME / USERPROFILE (= $HX_DIR\home) all live under the run folder, so no
# install or uninstall test can reach C:\Users\pc. See docs/windows-smoke.md. Environment (set by the caller, all optional):
#   HX_BRANCH            the branch under test (default issue/493); it must be pushed, the host clones it
#   HX_TESTS             space-separated test files in test/ to run instead of the whole suite (#493: the headless twins)
#   HARNESS_TEST_TIMEOUT per-test wall-clock cap in seconds, handed to run.sh (default 600)
#   HX_VERBOSE           1 = also print the whole of run.sh's output (every assertion line, the tail of a TIMEOUT), prefixed `| `: how a lane reads
#                        why a red file is red when the FAIL lines alone do not say (#605)
#   HX_STRICT            1 = exit with run.sh's own status (default: exit 0 once run.sh has COMPLETED, so the guard, the
#                        scan and the cleanup of `winsma.sh run` still count; the red files are in the log's summary)
# Prints `== run.sh: N/M test files passed ==` and one `FAILED: <file>` per red test file, then `SUITE-RESULT <n> failed`.
# Compare those lines with the same commit on Linux (`bash test/run.sh`): the failures Linux does not have are the Windows ones.
set -u
say(){ echo "[$(date -u +%H:%M:%S)] $*"; }
BRANCH="${HX_BRANCH:-issue/493}"
say "== host: $(uname -srm) | bash $BASH_VERSION | HOME=$HOME | USERPROFILE=${USERPROFILE:-} | TMPDIR=${TMPDIR:-}"
case "$(uname -s)" in MINGW*|MSYS*) ;; *) say "FAIL not Git Bash (uname -s must start with MINGW or MSYS)"; exit 1;; esac
# The run folder must hold HOME: a suite that can reach the real home is the one thing this stage must never be.
case "$(cygpath -u "${HOME:-/nonexistent}")" in "$(cygpath -u "$HX_DIR")"/*) ;; *) say "FAIL HOME ($HOME) is not under $HX_DIR: not the suite isolation"; exit 1;; esac
export TMPDIR="$(cygpath -u "$TMPDIR")"
say "== clone $BRANCH"
git clone -q --branch "$BRANCH" https://github.com/VocanicZ/Harness.git src || { say "FAIL clone failed"; exit 1; }
say "src at $(git -C src rev-parse --short HEAD)"
# python3 is the Microsoft Store stub on winsma, and the `python` on PATH is another user's: a venv under the run folder,
# with python.exe also named python3.exe, first on PATH (setuptools is the only thing pip-installed; the rest of the suite needs only the standard library).
say "== venv"
python -m venv "$(cygpath -w "$HX_DIR/venv")" || { say "FAIL python -m venv failed"; exit 1; }
VB="$HX_DIR/venv/Scripts"; cp "$VB/python.exe" "$VB/python3.exe" || { say "FAIL no venv python.exe"; exit 1; }
export PATH="$(cygpath -u "$VB"):$PATH"
# bench/grade.py builds the fixture with `pip install --no-build-isolation --no-index`, which needs setuptools in the interpreter
# itself; a venv made by Python 3.12+ has none, and the grader then silently falls back to PYTHONPATH (#609). The one package
# the suite installs: the Linux hosts have it system-wide.
python -m pip install --quiet --disable-pip-version-check setuptools >/dev/null 2>&1 || say "WARN setuptools not installed: test_bench_fixture.sh builds by PYTHONPATH"
# jq: the tests' fake `gh` run gh's own `-q` filters through it (gauntlet, security_audit, handoff, headless usage), and winsma
# has none (#686). The release's own sha256 pins the download; a failure is a WARN, the tests that need jq then say so.
JQ_VER=1.8.1; JQ_SHA=23cb60a1354eed6bcc8d9b9735e8c7b388cd1fdcb75726b93bc299ef22dd9334
mkdir -p "$HX_DIR/jqbin"
if curl -fsSL --retry 5 --retry-all-errors --retry-delay 4 -o "$HX_DIR/jqbin/jq.exe" "https://github.com/jqlang/jq/releases/download/jq-$JQ_VER/jq-windows-amd64.exe" \
   && [[ "$(sha256sum "$HX_DIR/jqbin/jq.exe" | cut -d' ' -f1)" == "$JQ_SHA" ]]; then
  export PATH="$(cygpath -u "$HX_DIR/jqbin"):$PATH"; say "jq = $(command -v jq): $(jq --version 2>&1)"
else rm -f "$HX_DIR/jqbin/jq.exe"; say "WARN jq $JQ_VER not downloaded: the tests that run a gh -q filter through jq fail"; fi
# What the engine's python3 shim does (install.sh, #406): Python in UTF-8 mode, or stdio and open() are cp1252 and every
# test that prints or reads a non-ASCII character fails for that alone. This venv python is not the shim, so say it here.
export PYTHONUTF8=1
# …and its LF stdio (#609): a native Windows Python writes "\n" as CRLF, which every fake `gh` written in Python, every
# `$(python3 …)` and every rendered prompt would carry. The shim puts the pylf sitecustomize on PYTHONPATH; so does this stage.
( HARNESS_INSTALL_NOMAIN=1 source src/install.sh && python_lf_dir "$HX_DIR/pylf" ) || { say "FAIL no pylf sitecustomize"; exit 1; }
export PYTHONPATH="$(cygpath -w "$HX_DIR/pylf")"
say "python3 = $(command -v python3): $(python3 --version 2>&1)"
# The suite makes real git commits and its fixtures need an identity: env vars, never a config file.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-hx-suite}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-hx-suite@example.invalid}"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export HARNESS_TEST_TIMEOUT="${HARNESS_TEST_TIMEOUT:-600}"
say "######## test/run.sh (per-test cap ${HARNESS_TEST_TIMEOUT}s)"
start=$SECONDS
( cd src && bash test/run.sh ${HX_TESTS:-} ) </dev/null > "$HX_DIR/suite.out" 2>&1; rc=$?
say "run.sh finished rc=$rc after $(( SECONDS - start ))s"
# Tests leak processes that hold this ssh session's stdout open (see src/test/smoke/winsma/reap.ps1): without this the run
# never returns to the claude host. Only processes under this run's folder that are not ours are ended.
powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$HX_DIR/src/test/smoke/winsma/reap.ps1")" -Me "$(cat /proc/$$/winpid)" -Issue "$HX_ISSUE" 2>&1 | tr -d '\r' | sed 's/^/  reap: /'
# What a reader needs: every red assertion with its file, then the summary run.sh ends with.
awk '/^== test_.*\.(sh|py) ==$/ { f=$2 } /^  FAIL:|^FAIL:|Traceback|^TIMEOUT:/ { print "  [" f "] " $0 }' "$HX_DIR/suite.out"
[[ "${HX_VERBOSE:-0}" == 1 ]] && { echo "######## full run.sh output"; tr -d '\r' < "$HX_DIR/suite.out" | sed 's/^/| /'; echo "######## end of run.sh output"; }
sed -n '/^== run.sh: /,$p' "$HX_DIR/suite.out"
if ! grep -q '^== run.sh: ' "$HX_DIR/suite.out"; then say "FAIL run.sh did not complete (no summary line); last output:"; tail -n 25 "$HX_DIR/suite.out"; exit 1; fi
n="$(grep -c '^FAILED: ' "$HX_DIR/suite.out")"
echo "SUITE-RESULT $n failed"
[[ "${HX_STRICT:-0}" == 1 ]] && exit "$rc"
exit 0
