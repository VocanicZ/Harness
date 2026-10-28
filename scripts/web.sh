#!/usr/bin/env bash
# web.sh — `harness web`: serve the local, read-only dashboard in the foreground (#223, PRD #192).
# Host-level like supervise: it reads every fleet on the host, so it needs no project STATE_DIR.
# Bind/port: HARNESS_WEB_BIND (default 127.0.0.1) / HARNESS_WEB_PORT (default 4637).
#
# usage: harness web | --install | --uninstall
#   --install    write + enable a systemd user unit (Restart=always, linger) running `harness web`
#                with this shell's HARNESS_WEB_BIND / HARNESS_WEB_PORT (#226); re-running is
#                idempotent, and `harness update` re-runs it so the unit follows the engine
#   --uninstall  stop, disable and remove that unit
WEB_ENGINE_DIR="${ENGINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# The unit runs the STABLE engine path (#281) when it resolves to this engine; see supervise.sh.
WEB_LINK="${HARNESS_ENGINE_LINK:-$WEB_ENGINE_DIR}"
[[ "$(realpath -m "$WEB_LINK" 2>/dev/null)" == "$(realpath -m "$WEB_ENGINE_DIR" 2>/dev/null)" ]] || WEB_LINK="$WEB_ENGINE_DIR"
WEB_HARNESS="${HARNESS_WEB_HARNESS:-$WEB_LINK/bin/harness}"
WEB_UNIT_DIR="${HARNESS_WEB_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
WEB_UNIT=harness-web.service
WEB_SYSTEMCTL="${HARNESS_WEB_SYSTEMCTL:-systemctl}"
WEB_LOGINCTL="${HARNESS_WEB_LOGINCTL:-loginctl}"

# --- systemd user unit (modelled on supervise.sh's sup_install, #180) ---------------------------
# web_unit_path — the unit's PATH: systemd hands a user unit a bare one, and the server shells out
# to tmux and ps for its live-session view.
web_unit_path(){ local b p out=()
  for b in python3 tmux ps git; do
    p=$(command -v "$b" 2>/dev/null) && [[ $p == /* ]] && out+=("$(dirname "$p")")
  done
  out+=("$HOME/.local/bin" /usr/local/bin /usr/bin /bin)
  printf '%s\n' "${out[@]}" | awk '!seen[$0]++' | paste -sd: -
}
# web_unit_env <VAR> — the value the unit gets: this shell's, else the installed unit's own. So a
# redeploy (`harness update`, which runs with none of them set) never drops the claude host's
# HARNESS_WEB_BIND=0.0.0.0 back to localhost.
web_unit_env(){ local v="${!1:-}"
  [[ -n $v ]] || v=$(sed -n "s/^Environment=$1=//p" "$WEB_UNIT_DIR/$WEB_UNIT" 2>/dev/null | tail -1)
  printf '%s' "$v"
}
# The server starts no long-lived children, so systemd's default control-group KillMode is right.
web_install(){ local unit="$WEB_UNIT_DIR/$WEB_UNIT" bind port env=""
  bind=$(web_unit_env HARNESS_WEB_BIND); port=$(web_unit_env HARNESS_WEB_PORT)
  [[ -n $bind ]] && env+="Environment=HARNESS_WEB_BIND=$bind"$'\n'
  [[ -n $port ]] && env+="Environment=HARNESS_WEB_PORT=$port"$'\n'
  mkdir -p "$WEB_UNIT_DIR" || { echo "ERROR: cannot create $WEB_UNIT_DIR" >&2; return 1; }
  cat >"$unit" <<EOF
[Unit]
Description=Harness web: read-only dashboard of every fleet on this host
After=network-online.target

[Service]
ExecStart=$WEB_HARNESS web
Restart=always
RestartSec=5
Nice=10
Environment=PATH=$(web_unit_path)
Environment=HARNESS_HOME=${HARNESS_HOME:-$HOME/.harness}
${env}
[Install]
WantedBy=default.target
EOF
  echo "  wrote $unit"
  "$WEB_SYSTEMCTL" --user daemon-reload || echo "WARNING: systemctl --user daemon-reload failed" >&2
  "$WEB_SYSTEMCTL" --user enable "$WEB_UNIT" || echo "WARNING: could not enable $WEB_UNIT" >&2
  "$WEB_SYSTEMCTL" --user restart "$WEB_UNIT" || echo "WARNING: could not (re)start $WEB_UNIT" >&2
  # linger keeps the user manager (and so this unit) running with no login session open.
  "$WEB_LOGINCTL" enable-linger "$(id -un)" 2>/dev/null \
    || echo "WARNING: loginctl enable-linger failed — the dashboard stops when you log out" >&2
  echo "  dashboard running on ${bind:-127.0.0.1}:${port:-4637}: systemctl --user status $WEB_UNIT"
}
web_uninstall(){ local unit="$WEB_UNIT_DIR/$WEB_UNIT"
  [[ -f $unit ]] || { echo "  $WEB_UNIT not installed"; return 0; }
  "$WEB_SYSTEMCTL" --user disable --now "$WEB_UNIT" 2>/dev/null || true
  rm -f "$unit"; "$WEB_SYSTEMCTL" --user daemon-reload 2>/dev/null || true
  echo "  removed $unit"
}
# web_installed — the unit is installed AND runs THIS engine. update/uninstall act only then, so a
# second engine checkout (a dev clone, a test sandbox) never rewrites or removes the host's unit.
web_installed(){ grep -qxF "ExecStart=$WEB_HARNESS web" "$WEB_UNIT_DIR/$WEB_UNIT" 2>/dev/null; }

[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0   # sourced (tests, update.sh): define functions only
set -euo pipefail
case "${1:-}" in
  --install) web_install; exit ;;
  --uninstall) web_uninstall; exit ;;
esac
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/web.py" "$@"
