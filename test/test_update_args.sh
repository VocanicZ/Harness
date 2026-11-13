#!/usr/bin/env bash
# test_update_args.sh — #1119: `harness update` knows its arguments. -h/--help print the usage and change nothing;
# an unknown or dash-led argument is a usage error (stderr, exit 2) with the engine untouched. It used to ignore them:
# `--help` ran an update (a real `git pull --ff-only` from a dev checkout) and `--rollback -x` rolled back.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/release_fixture.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cd "$T"
export HOME="$T/home"; mkdir -p "$HOME"
pin_host_home "$T/host"
export HARNESS_HOME="$T/host" HARNESS_SKIP_RTDD=1 HARNESS_SUPERVISE_UNIT_DIR="$T/units" HARNESS_WEB_UNIT_DIR="$T/units"
export HARNESS_SUPERVISE_SYSTEMCTL=true HARNESS_SUPERVISE_LOGINCTL=true HARNESS_WEB_SYSTEMCTL=true HARNESS_WEB_LOGINCTL=true
H="$HARNESS_HOME"; SRV="$T/srv"; rel_server "$SRV"
rel_publish "$SRV" v0.1.0; rel_publish "$SRV" v0.2.0
rel_install_at "$SRV" v0.1.0; rel_latest "$SRV" v0.2.0   # a newer release exists: a stray update WOULD flip the engine
upd(){ env -u ENGINE_DIR -u STATE_DIR -u HARNESS_ENGINE_LINK -u HARNESS_REF bash "$H/engine/bin/harness" update "$@"; }
snap(){ readlink "$H/engine"; ls -A "$H/releases" | sort; cat "$H/releases/.installed" 2>/dev/null; }
before="$(snap)"

for h in --help -h; do
  out="$(upd "$h" 2>"$T/err")"; rc=$?
  assert_eq "$rc" 0 "update $h exits 0"
  assert_ok "update $h prints the usage on stdout" grep -q '^usage: harness update' <<<"$out"
  assert_eq "$(snap)" "$before" "update $h changes nothing (no update ran)"
done
out="$(upd --rollback --help 2>&1)"; rc=$?
assert_eq "$rc" 0 "--rollback --help is help, not a rollback"
assert_eq "$(snap)" "$before" "--rollback --help changes nothing"

for bad in --bogus -x - --flag; do
  out="$(upd "$bad" 2>"$T/err")"; rc=$?
  assert_eq "$rc" 2 "update $bad is a usage error (exit 2)"
  assert_ok "update $bad names the argument on stderr" grep -qF "unknown argument: $bad" "$T/err"
  assert_ok "update $bad prints the usage on stderr" grep -q '^usage: harness update' "$T/err"
  assert_eq "$out" "" "update $bad prints nothing on stdout"
  assert_eq "$(snap)" "$before" "update $bad changes nothing (no update ran)"
done

# a rollback is possible here (v0.1.0 -> v0.2.0 first), and a stray argument must not trigger it
upd >/dev/null 2>&1; assert_eq "$(readlink "$H/engine")" releases/v0.2.0 "setup: a plain update moved the engine"
before="$(snap)"
for bad in -x - --flag; do
  upd --rollback "$bad" >/dev/null 2>"$T/err"; rc=$?
  assert_eq "$rc" 2 "update --rollback $bad is a usage error (exit 2)"
  assert_eq "$(snap)" "$before" "update --rollback $bad does not roll back"
done
upd --rollback >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 "a plain --rollback still works"
assert_eq "$(readlink "$H/engine")" releases/v0.1.0 "…and flips the engine back"
finish
