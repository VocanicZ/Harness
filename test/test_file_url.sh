#!/usr/bin/env bash
# test_file_url.sh — #608: a fixture that serves a fake release over file:// names it the way a NATIVE curl reads it. Git for
# Windows' curl takes `file:///C:/x/y`, not the MSYS `file:///c/x/y` (it reads C:\c\x\y), so before file_url every
# install/update/rollback fixture exited 1 or 3 on winsma while test_windows_lifecycle's forced-Windows fakes were green.
# Forced on Linux with HARNESS_PLATFORM=windows and a cygpath fake that maps /c/<rest> to C:/<rest> like the real one.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"; source "$HERE/release_fixture.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# $T/c plays the drive: $T/c/x is "/c/x" (MSYS) and so "C:/x" (native). A real /c is not created.
cat > "$T/bin/cygpath" <<SH
#!/bin/sh
[ "\$1" = -m ] || exit 2
case "\$2" in $T/c/*) printf 'C:/%s\n' "\${2#$T/c/}";; *) printf '%s\n' "\$2";; esac
SH
chmod +x "$T/bin/cygpath"

echo "=== posix: unchanged ==="
assert_eq "$(HARNESS_PLATFORM=posix file_url /tmp/x/latest.json)" "file:///tmp/x/latest.json" "a POSIX path stays file:///path"
assert_eq "$(HARNESS_PLATFORM=posix file_url '/tmp/a b/x')" "file:///tmp/a b/x" "…spaces and all"

echo "=== windows: the native spelling ==="
export PATH="$T/bin:$PATH"
assert_eq "$(HARNESS_PLATFORM=windows file_url "$T/c/hx-608/tmp/srv/latest.json")" "file:///C:/hx-608/tmp/srv/latest.json" "an MSYS path becomes file:///C:/…"
assert_eq "$(HARNESS_PLATFORM=windows file_url C:/hx-608/x)" "file:///C:/hx-608/x" "a path already in the C:/ form is not doubled"
assert_eq "$(HARNESS_PLATFORM=windows file_url /x/y)" "file:///x/y" "a path off the drive is left as it is"
export HARNESS_PLATFORM=windows
rel_server "$T/c/hx-608/srv"
assert_eq "$HARNESS_API_URL" "file:///C:/hx-608/srv/latest.json" "rel_server: the releases/latest endpoint is a native URL"
assert_eq "$HARNESS_BASE_URL" "file:///C:/hx-608/srv/download" "rel_server: the download base is a native URL"
finish
