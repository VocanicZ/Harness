#!/usr/bin/env bash
# rtdd: always
# test_static_hermetic_lints.sh — #1211: the repo-wide STATIC scans of the suite's hermeticity, alone. They lived in test_hermetic.sh
# (about 40s of fixtures around them), a file a lane's rtdd rounds never select for a change that only ADDS a test file or an export:
# the release gate was the first run to see the red (#1198, #1208: a new test assigned HARNESS_HOME with no pin_host_home). Every
# input here is the repo tree and each scan is one awk/grep per file, so the file is in the always-run guard set (test/guards.sh).
# What stays in test_hermetic.sh is the behaviour: the seams, the decoys, the real runs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
PRIVATE_TMP="$(mktemp -d)"; tmp_track "$PRIVATE_TMP"; export TMPDIR="$PRIVATE_TMP"
unset_inherited_config
pin_host_home "$PRIVATE_TMP/host"   # this file only reads the tree; the pin keeps the fixture strings below honest to the lint it runs

# #333: every HARNESS_* variable the engine EXPORTS reaches the agent session running this suite, so
# every one must be in the drop list — snapshot_gate's HARNESS_SNAPSHOT_FILE/_DIR made issuelib.py
# read the host's real poller snapshot instead of the stubbed gh, and an inherited absolute
# HARNESS_CLAUDE_BIN satisfied check_prereqs with no claude on PATH. The four host path pins are
# exempt: run.sh and make_env re-pin them to throwaways on purpose.
exported_vars(){ local f; for f in "$HERE/../scripts/lib.sh" "$HERE/../scripts/supervise.sh" "$HERE/../scripts/cli/"*.sh; do
    sed -e :a -e '/\\$/N; s/\\\n//; ta' "$f"; done |
  awk '{ for (i = 1; i <= NF; i++) if ($i == "export") for (j = i + 1; j <= NF; j++) {
           if ($j ~ /^HARNESS_[A-Z0-9_]+(=|$)/) { sub(/=.*/, "", $j); print $j } else if ($j !~ /^-/) break } }' | sort -u; }
missing=""
for v in $(exported_vars); do
  case " HARNESS_HOME HARNESS_POLLER_DIR HARNESS_SNAPSHOTS_DIR HARNESS_FLEETS_DIR " in *" $v "*) continue;; esac
  [[ " $(echo $HARNESS_CONFIG_VARS) " == *" $v "* ]] || missing+=" $v"
done
assert_eq "$missing" "" "every HARNESS_* variable the engine exports is in HARNESS_CONFIG_VARS"
assert_ok "the export scan sees the adapters' and snapshot_gate's exports" \
  bash -c '[[ $(tr "\n" " " <<<"$1") == *HARNESS_CLAUDE_BIN*HARNESS_SNAPSHOT_FILE* ]]' _ "$(exported_vars)"

# ...and the next variable a worker exports must not leak the same way: scan the worker launchers' exports too.
worker_missing=""
for v in $(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$HERE/../scripts/pool.sh" "$HERE/../scripts/priority.sh" |
    awk '{ for (i = 1; i <= NF; i++) if ($i == "export") for (j = i + 1; j <= NF; j++) {
             if ($j ~ /^HARNESS_[A-Z0-9_]+(=|$)/) { sub(/=.*/, "", $j); print $j } else if ($j !~ /^-/) break } }' | sort -u); do
  [[ " $(echo $HARNESS_CONFIG_VARS) $(echo $HARNESS_LANE_IDENTITY_VARS) " == *" $v "* ]] || worker_missing+=" $v"
done
assert_eq "$worker_missing" "" "every HARNESS_* variable pool.sh / priority.sh export is dropped at the suite seam"

# #1084: a LANE is handed more than the engine EXPORTS: session_env / wait_env put `-e K=V` pairs on the tmux session
# (SESSION_ENV), and LANE_ENV_NAMES lists the names a CLI passes through. The export scan above never saw them, so
# HARNESS_WAIT_FILE (the lane's own wait spec, #1066) reached the suite: test_winsma_park.sh's `ws_park` wrote a fake
# park spec (#900 acme/widget) into the file of the lane running it, and the engine never resumed that lane.
lane_vars(){ { sed -n 's/^LANE_ENV_NAMES=(\(.*\))/\1/p' "$HERE/../scripts/lib.sh" | tr ' ' '\n'
    grep -ohE -- '-e "HARNESS_[A-Z0-9_]+=' "$HERE/../scripts/"*.sh "$HERE/../scripts/cli/"*.sh | sed -e 's/^-e "//' -e 's/=$//'; } | sed '/^$/d' | sort -u; }
lane_missing=""
for v in $(lane_vars); do
  [[ " $(echo $HARNESS_CONFIG_VARS) $(echo $HARNESS_LANE_IDENTITY_VARS) " == *" $v "* ]] || lane_missing+=" $v"
done
assert_eq "$lane_missing" "" "every variable a lane is handed (LANE_ENV_NAMES, session -e pairs) is dropped at the suite seam"
assert_ok "the lane-variable scan sees the wait file and the session id (an empty scan cannot pass)" \
  bash -c '[[ " $(tr "\n" " " <<<"$1") " == *" HARNESS_WAIT_FILE "* && " $(tr "\n" " " <<<"$1") " == *" HARNESS_SESSION "* ]]' _ "$(lane_vars)"

# One source of truth (Acceptance 4): every path var the engine rewrites for native Windows programs
# (HARNESS_NATIVE_PATH_VARS) is pinned or dropped by pin_host_home, or exempted in helpers.sh WITH a reason.
source "$HERE/../scripts/portable.sh" 2>/dev/null
undecided=""
for v in $HARNESS_NATIVE_PATH_VARS; do
  [[ " $(echo $HARNESS_HOST_PIN_VARS | tr ' ' '\n' | sed 's/:.*//' | tr '\n' ' ')$(echo $HARNESS_HOST_DROP_VARS) $(echo $HARNESS_HOST_PATH_EXEMPT) " == *" $v "* ]] || undecided+=" $v"
done
assert_eq "$undecided" "" "every HARNESS_NATIVE_PATH_VARS member is pinned, dropped, or exempted with a reason"
assert_ok "the exemptions are explained in helpers.sh (a '#   NAME … — reason' line each)" bash -c '
  for v in $1; do grep -qE "^#   .*\b$v\b.* — " "$2" || { echo "no reason for $v"; exit 1; }; done' _ "$HARNESS_HOST_PATH_EXEMPT" "$HERE/helpers.sh"

# ── static lint (Acceptance 3): no test assigns HARNESS_HOME before pinning the host fleet registry ────
# host_pin_offenders <file…> — print each file that assigns HARNESS_HOME (export, plain, inline env prefix,
# os.environ, a kwarg) on a line before — or without — a line that pins the host: pin_host_home, make_env,
# or its own HARNESS_FLEETS_DIR. A pin on the SAME line as the assignment counts.
host_pin_offenders(){ local f
  for f in "$@"; do [[ -f $f ]] || continue   # an unmatched glob (a tree with no test_*.py) is no file
    awk '/^[[:space:]]*#/ { next }
         { asg = ($0 ~ /(^|[^A-Za-z0-9_])HARNESS_HOME[[:space:]]*=/ || $0 ~ /environ\[[^]]*HARNESS_HOME[^]]*\][[:space:]]*=/)
           pin = ($0 ~ /(^|[^A-Za-z0-9_])(pin_host_home|make_env)([^A-Za-z0-9_]|$)/ || $0 ~ /HARNESS_FLEETS_DIR[^A-Za-z0-9_]*[[:space:]]*=/ || $0 ~ /environ\[[^]]*HARNESS_FLEETS_DIR[^]]*\]/ )
           if (pin) pinned = 1
           if (asg && !pinned) bad = 1 }
         END { exit bad ? 1 : 0 }' "$f" || echo "${f##*/}"
  done; }
LINT="$(mktemp -d)"; tmp_track "$LINT"
printf 'source helpers.sh\nexport HARNESS_HOME="$T/host" HARNESS_SKIP_RTDD=1\nbash update.sh\n' > "$LINT/test_bad_export.sh"
printf 'HARNESS_HOME="$T/host" bash update.sh\n'                                                    > "$LINT/test_bad_inline.sh"
printf 'import os\nos.environ["HARNESS_HOME"] = d\n'                                                > "$LINT/test_bad_environ.py"
printf 'source helpers.sh\nexport HARNESS_HOME=/h\npin_host_home /h\n'                              > "$LINT/test_bad_late.sh"
printf 'source helpers.sh\npin_host_home "$T/host"\nexport HARNESS_HOME="$T/host"\n'               > "$LINT/test_good_helper.sh"
printf 'source helpers.sh\nmake_env\nHARNESS_HOME=/x cmd\n'                                          > "$LINT/test_good_make_env.sh"
printf 'export HARNESS_HOME="$T/h" HARNESS_FLEETS_DIR="$T/h/fleets"\n'                              > "$LINT/test_good_same_line.sh"
printf 'import os\nos.environ["HARNESS_FLEETS_DIR"] = d + "/f"\nos.environ["HARNESS_HOME"] = d\n'   > "$LINT/test_good_environ.py"
printf '# export HARNESS_HOME=/commented\necho hi\n'                                                 > "$LINT/test_good_comment.sh"
assert_eq "$(host_pin_offenders "$LINT"/test_bad_* | tr '\n' ' ')" \
  "test_bad_environ.py test_bad_export.sh test_bad_inline.sh test_bad_late.sh " "the lint catches a planted offender of every shape"
assert_eq "$(host_pin_offenders "$LINT"/test_good_*)" "" "...and passes a helper, make_env, a same-line pin, and a comment"
offenders="$(host_pin_offenders "$HERE"/test_*.sh "$HERE"/test_*.py | tr '\n' ' ')"
assert_eq "$offenders" "" "no test assigns HARNESS_HOME without pinning HARNESS_FLEETS_DIR (pin_host_home) first"

# ── tmux lint (Acceptance 5): a test that kills tmux must have its own private server ─────────────────
# A real `tmux kill-server` (or kill-session / kill-window on the default socket) in a test that has not
# set a private TMUX_TMPDIR AND dropped the lane's TMUX reaches the server every co-resident fleet runs on.
# Stub bodies, greps and printf'd probe text are not invocations. The scan's own pattern is built from
# parts: spelled out, it would match this file.
tm=tmux; kk=kill
TMUX_KILL_RE="(^|[;&|({'\"[:space:]])(command[[:space:]]+)?${tm}[[:space:]]+${kk}-(server|session|window)([^A-Za-z0-9_-]|\$)"
TMUX_REAL_SKIP='[[:space:]]-[LS][[:space:]]|grep|assert_|printf|echo|sess_describe'   # a private socket, a stub body, a probe string
tmux_offenders(){ local f code
  for f in "$@"; do
    code="$(grep -v '^[[:space:]]*#' "$f")"
    grep -E "$TMUX_KILL_RE" <<<"$code" | grep -vE "$TMUX_REAL_SKIP" >/dev/null || continue   # no real, default-socket kill
    # tmux_short_dir (helpers.sh, #1077) sets a private TMUX_TMPDIR and unsets TMUX itself.
    grep -E '(^|[;&|({[:space:]])tmux_short_dir([^A-Za-z0-9_]|$)' <<<"$code" >/dev/null && continue
    { grep -E '(^|[^A-Za-z0-9_])TMUX_TMPDIR=' <<<"$code" >/dev/null &&
      grep -E '(unset[[:space:]]+([A-Z_]+[[:space:]]+)*TMUX([[:space:]]|$)|env[[:space:]]+-u[[:space:]]+TMUX([[:space:]]|$))' <<<"$code" >/dev/null; } \
      || echo "${f##*/}"
  done; }
printf 'trap "%s %s-server" EXIT\n' "$tm" "$kk"                                                      > "$LINT/test_tmux_bad_server.sh"
printf 'mk(){ %s %s-session -t "=$1"; }\n' "$tm" "$kk"                                              > "$LINT/test_tmux_bad_session.sh"
printf 'export TMUX_TMPDIR="$T/tmux"\n%s %s-server\n' "$tm" "$kk"                                   > "$LINT/test_tmux_bad_no_unset.sh"
printf 'export TMUX_TMPDIR="$T/tmux"; unset TMUX TMUX_PANE\ntrap "%s %s-server" EXIT\n' "$tm" "$kk" > "$LINT/test_tmux_good_private.sh"
printf 'tmux_short_dir\ntrap "%s %s-server" EXIT\n' "$tm" "$kk"                                      > "$LINT/test_tmux_good_helper.sh"
printf '%s -L sock %s-server\n' "$tm" "$kk"                                                         > "$LINT/test_tmux_good_L.sh"
printf "grep -q '%s %s-session' \"\$CALLS\"\n" "$tm" "$kk"                                          > "$LINT/test_tmux_good_grep.sh"
assert_eq "$(tmux_offenders "$LINT"/test_tmux_bad_* | tr '\n' ' ')" \
  "test_tmux_bad_no_unset.sh test_tmux_bad_server.sh test_tmux_bad_session.sh " "the tmux lint catches a planted offender"
assert_eq "$(tmux_offenders "$LINT"/test_tmux_good_*)" "" "...and passes a private TMUX_TMPDIR + unset TMUX, tmux_short_dir, a -L socket, and a grep"
assert_eq "$(tmux_offenders "$HERE"/test_*.sh | tr '\n' ' ')" "" "every test that kills tmux has a private TMUX_TMPDIR and drops TMUX"

finish
