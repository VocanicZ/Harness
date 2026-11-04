#!/usr/bin/env bash
# common.sh — the claude-host side of the winsma helpers (#479): where the Windows host is, and the one seam
# every helper reaches it through. Sourced by winsma.sh. See docs/windows-smoke.md and PRD #475.
#
#   HARNESS_WINDOWS_HOST  the ssh alias of the Windows check host (env, or `.harness/config` through lib.sh);
#                         unset = no Windows host, and every helper refuses to run
#   WINSMA_SSH            test seam: a command that reads a bash script on stdin and runs it as the host would
#                         (default: ssh -T -o BatchMode=yes <host> "C:\Program Files\Git\bin\bash.exe" -l -s)
WS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ws_die(){ echo "winsma: $*" >&2; return 1; }
ws_log(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "${WS_LOG:-/dev/null}"; }
# The usual config path: env wins over `.harness/config`, which lib.sh sources (`: "${KEY:=val}"`).
ws_host(){ local h="${HARNESS_WINDOWS_HOST:-}"
  [[ -n "$h" ]] || h="$( (set +u; source "$WS_DIR/../../../scripts/lib.sh" >/dev/null 2>&1; printf %s "${HARNESS_WINDOWS_HOST:-}") )"
  printf %s "$h"; }
ws_need_host(){ local h; h="$(ws_host)"
  [[ -n "$h" ]] || { ws_die "HARNESS_WINDOWS_HOST is not set: there is no Windows host to run on"; return 1; }
  printf %s "$h"; }
_ws_ssh(){ local h; h="$(ws_need_host)" || return 1
  if [[ -n "${WINSMA_SSH:-}" ]]; then $WINSMA_SSH
  else ssh -T -o BatchMode=yes "$h" '"C:\Program Files\Git\bin\bash.exe" -l -s'; fi; }
# The GH_TOKEN a run uses: the caller's, else the host's gh login. Never printed, never put on a command line.
ws_token(){ [[ -n "${GH_TOKEN:-}" ]] && { printf %s "$GH_TOKEN"; return 0; }; gh auth token 2>/dev/null; }
# The settings the remote side reads, carried over only when set here.
_ws_prelude(){ local v; for v in WS_C WS_HB_INTERVAL WS_CLAUDE_TOP_KEYS WS_GIT_NAME WS_GIT_EMAIL HX_REAL_HOME WS_VENV_ARGS; do
  [[ -n "${!v:-}" ]] && printf 'export %s=%q\n' "$v" "${!v}"; done; return 0; }
# ws_stream [--token] <script on stdin> — what the host's bash reads: [the token on its own first line, read into
# GH_TOKEN and exported], the prelude, remote.sh, then the script.
ws_stream(){ local tok=""
  if [[ "${1:-}" == --token ]]; then tok="$(ws_token)" || true; fi
  if [[ -n "$tok" ]]; then printf 'IFS= read -r GH_TOKEN; export GH_TOKEN\n%s\n' "$tok"; fi
  _ws_prelude; cat "$WS_DIR/remote.sh"; cat; }
# ws_call [--token] <function> [args…] — run one remote.sh function on the host; its exit status comes back.
ws_call(){ local tflag=""; [[ "${1:-}" == --token ]] && { tflag=--token; shift; }
  { printf '%q ' "$@"; echo; } | ws_stream $tflag | _ws_ssh; }
