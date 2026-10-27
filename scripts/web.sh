#!/usr/bin/env bash
# web.sh — `harness web`: serve the local, read-only dashboard in the foreground (#223, PRD #192).
# Host-level like supervise: it reads every fleet on the host, so it needs no project STATE_DIR.
# Bind/port: HARNESS_WEB_BIND (default 127.0.0.1) / HARNESS_WEB_PORT (default 4637).
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/web.py" "$@"
