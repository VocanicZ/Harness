#!/usr/bin/env bash
# test_web_install.sh — #226: `harness web --install` writes and enables a systemd user unit for the
# dashboard; re-running is idempotent; `harness update` redeploys an installed unit of THIS engine and
# leaves every other host alone; uninstall removes it. systemctl/loginctl are stubs that log argv.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# update.sh sources install.sh, whose prereq checks run agy (#240): pin it at a no-op stub.
AGY_STUB_DIR="$(mktemp -d)"; printf '#!/usr/bin/env bash\nexit 0\n' >"$AGY_STUB_DIR/agy"; chmod +x "$AGY_STUB_DIR/agy"
export HARNESS_AGY_BIN="$AGY_STUB_DIR/agy" PATH="$AGY_STUB_DIR:$PATH"
source "$HERE/helpers.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T" "$AGY_STUB_DIR"' EXIT
printf '#!/bin/sh\necho "$@" >> %s/systemctl.calls\n' "$T" >"$T/systemctl"; chmod +x "$T/systemctl"
printf '#!/bin/sh\necho "$@" >> %s/loginctl.calls\n' "$T" >"$T/loginctl"; chmod +x "$T/loginctl"
export HARNESS_WEB_UNIT_DIR="$T/unit" HARNESS_WEB_SYSTEMCTL="$T/systemctl" HARNESS_WEB_LOGINCTL="$T/loginctl"
export HARNESS_WEB_HARNESS=/eng/bin/harness HARNESS_WEB_BIND=0.0.0.0 HARNESS_WEB_PORT=4637
source "$HERE/../scripts/web.sh"
F="$T/unit/harness-web.service"
has(){ grep -qF -- "$1" "$2"; }
line(){ grep -qx -- "$1" "$2"; }

echo "=== harness web --install ==="
web_install >/dev/null
assert_ok "--install writes the unit"                 test -f "$F"
assert_ok "unit runs this engine's harness web"       line "ExecStart=/eng/bin/harness web" "$F"
assert_ok "unit restarts always"                      line "Restart=always" "$F"
assert_ok "unit starts with the user manager"         line "WantedBy=default.target" "$F"
assert_ok "unit carries the bind"                     line "Environment=HARNESS_WEB_BIND=0.0.0.0" "$F"
assert_ok "unit carries the port"                     line "Environment=HARNESS_WEB_PORT=4637" "$F"
assert_ok "systemd reloaded"                          has "--user daemon-reload" "$T/systemctl.calls"
assert_ok "unit enabled"                              has "--user enable harness-web.service" "$T/systemctl.calls"
assert_ok "unit (re)started"                          has "--user restart harness-web.service" "$T/systemctl.calls"
assert_ok "linger enabled (survives logout/reboot)"   has "enable-linger" "$T/loginctl.calls"
assert_ok "installed from this engine"                web_installed
before="$(cat "$F")"; web_install >/dev/null
assert_eq "$(cat "$F")" "$before" "re-install is idempotent"
assert_eq "$(ls "$T/unit" | wc -l | tr -d ' ')" 1 "re-install writes one unit"
other(){ local WEB_HARNESS=/other/bin/harness; web_installed; }
assert_no "another engine's checkout does not own the unit" other
kept(){ local HARNESS_WEB_BIND= HARNESS_WEB_PORT=; web_install >/dev/null; }
kept
assert_ok "a re-install without the env keeps the unit's bind" line "Environment=HARNESS_WEB_BIND=0.0.0.0" "$F"
assert_ok "…and its port"                             line "Environment=HARNESS_WEB_PORT=4637" "$F"
printf '#!/bin/sh\nexit 1\n' >"$T/loginctl.fail"; chmod +x "$T/loginctl.fail"
out="$(WEB_LOGINCTL="$T/loginctl.fail" web_install 2>&1)"
assert_ok "a linger failure is warned about"          grep -q "enable-linger failed" <<<"$out"
assert_ok "harness help lists web --install"          bash -c "bash '$HERE/../bin/harness' help | grep -q '^  web .*--install'"

echo "=== harness update redeploys only this engine's installed unit ==="
R="$HERE/.."; REMOTE="$T/eng.git"; git init -q --bare -b main "$REMOTE"
EW="$T/ew"; mkdir -p "$EW/scripts" "$EW/bin"
cp "$R/update.sh" "$R/install.sh" "$EW/"; cp "$R/scripts/web.sh" "$R/scripts/supervise.sh" "$EW/scripts/"; cp "$R/bin/harness" "$EW/bin/"
git -C "$EW" init -q -b main; git -C "$EW" add -A
git -C "$EW" -c user.name=t -c user.email=t@t commit -qm init; git -C "$EW" push -q "$REMOTE" main
ENG="$T/engine"; git clone -q "$REMOTE" "$ENG"
U2="$T/unit2"; mkdir -p "$U2"
upd(){ HARNESS_SKIP_RTDD=1 HARNESS_WEB_UNIT_DIR="$U2" HARNESS_WEB_HARNESS= HARNESS_WEB_BIND= HARNESS_WEB_PORT= \
  HARNESS_SUPERVISE_UNIT_DIR="$T/none" ENGINE_DIR="$ENG" bash "$R/update.sh" >/dev/null 2>&1; }
printf '[Service]\nExecStart=%s/bin/harness web\nEnvironment=PATH=stale\nEnvironment=HARNESS_WEB_BIND=0.0.0.0\n' "$ENG" >"$U2/harness-web.service"
: >"$T/systemctl.calls"; upd
assert_no "update rewrites an installed unit"         grep -q "PATH=stale" "$U2/harness-web.service"
assert_ok "update keeps the unit's LAN bind"          line "Environment=HARNESS_WEB_BIND=0.0.0.0" "$U2/harness-web.service"
assert_ok "update restarts it on the new engine"      has "restart harness-web.service" "$T/systemctl.calls"
printf '[Service]\nExecStart=/other/bin/harness web\nEnvironment=PATH=stale\n' >"$U2/harness-web.service"
: >"$T/systemctl.calls"; upd
assert_ok "update leaves another engine's unit alone" grep -q "PATH=stale" "$U2/harness-web.service"
assert_no "…and restarts nothing"                     grep -q restart "$T/systemctl.calls"
rm -f "$U2/harness-web.service"; upd
assert_no "update never installs a unit that was not installed" test -f "$U2/harness-web.service"

echo "=== uninstall ==="
UR="$T/un"; mkdir -p "$UR/.harness/engine" "$UR/bin" "$UR/proj/.harness"
printf '[Service]\nExecStart=%s/bin/harness web\n' "$(cd "$R" && pwd)" >"$U2/harness-web.service"
( HARNESS_UNINSTALL_NOMAIN=1 HARNESS_HOME="$UR/.harness" HARNESS_BIN_DIR="$UR/bin" HARNESS_USER_SKILLS="$UR/skills" \
  STATE_DIR="$UR/proj/.harness" HARNESS_WEB_UNIT_DIR="$U2" HARNESS_WEB_HARNESS= HARNESS_SUPERVISE_UNIT_DIR="$T/none" \
  bash -c 'source "$1"; other_fleets_depend_on_engine(){ return 1; }; main --force' _ "$R/scripts/uninstall.sh" ) >/dev/null 2>&1 </dev/null
assert_no "uninstall removes this engine's web unit"  test -f "$U2/harness-web.service"
web_uninstall >/dev/null
assert_no "--uninstall removes the unit"              test -f "$F"
assert_ok "--uninstall disables it"                   has "disable --now harness-web.service" "$T/systemctl.calls"
out="$(web_uninstall)"
assert_ok "--uninstall twice is a no-op"              grep -q "not installed" <<<"$out"
finish
