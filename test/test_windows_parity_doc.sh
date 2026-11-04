#!/usr/bin/env bash
# test_windows_parity_doc.sh — #478 / PRD #475: the Windows parity matrix in docs/reference.md stays complete and honest.
#
# The matrix has one row per `harness` subcommand (read from bin/harness), per /harness* skill (skill/), per
# agent CLI (test/fixtures/cli/) and per lifecycle feature the PRD names. Every row has a Linux and a Windows
# value: `✓`, or `n/a` with a source link. `✓ target (#N …)` marks a feature planned but not yet working on
# Windows. `n/a` on Windows is allowed only for the external Linux-only service (swarm) and for an agent CLI
# row (a vendor with no Windows build / no non-interactive mode). The per-CLI non-interactive research table
# has a sourced row for every CLI.
#
# The checker runs on the real doc (must pass) and on copies of it with one defect each (must fail, naming it).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
ROOT="$HERE/.."
DOC="$ROOT/docs/reference.md"

CHECK='
import os, re, sys
doc, root = sys.argv[1], sys.argv[2]
lines = open(doc, encoding="utf-8").read().split("\n")
problems = []

def section(title):
    """Lines under "### <title>" up to the next ##/### heading (#### subsections stay inside)."""
    out, on = [], False
    for l in lines:
        if re.match(r"^#{2,3} ", l):
            on = l.startswith("### " + title)
            continue
        if on:
            out.append(l)
    return out

def cells(l):
    return [c.strip() for c in re.split(r"(?<!\\)\|", l.strip())[1:-1]]

sec = section("Windows parity matrix")
if not sec:
    print("no section: ### Windows parity matrix"); sys.exit(1)

# --- the feature matrix: the table whose header is | feature | Linux | Windows |
rows, intable = {}, False
for l in sec:
    if l.startswith("|"):
        c = cells(l)
        if c[:3] == ["feature", "Linux", "Windows"]:
            intable = True; continue
        if intable and not re.match(r"^[-| :]+$", l):
            if len(c) != 3:
                problems.append("row with %d cells, want 3: %s" % (len(c), l[:60])); continue
            rows[c[0].strip("`")] = (c[1], c[2])
    elif intable and l.strip():
        break
if not rows:
    problems.append("no matrix table (| feature | Linux | Windows |)")

URL = re.compile(r"https?://[^\s)]+")
for name, (lin, win) in rows.items():
    for col, v in (("Linux", lin), ("Windows", win)):
        if not v:
            problems.append("row `%s`: no %s value" % (name, col)); continue
        if v.startswith("n/a"):
            if not URL.search(v):
                problems.append("row `%s`: %s n/a has no source link" % (name, col))
            if col == "Windows" and not (name == "swarm submission" or name.startswith("cli ")):
                problems.append("row `%s`: Windows n/a is allowed only for swarm submission and agent CLIs" % name)
        elif v.startswith("✓"):
            if v.startswith("✓ target") and not re.search(r"\(#[0-9]+", v):
                problems.append("row `%s`: %s target names no issue" % (name, col))
        else:
            problems.append("row `%s`: %s value is neither ✓ nor n/a: %s" % (name, col, v[:40]))

# --- coverage: what the repo has must have a row
src = open(os.path.join(root, "bin", "harness"), encoding="utf-8").read()
subs = set()
for m in re.finditer(r"^  ([a-z-][a-zA-Z|-]*)\)", src, re.M):
    for w in m.group(1).split("|"):
        if w and not w.startswith("-") and w not in ("help",):
            subs.add(w)
for w in sorted(subs):
    if "harness " + w not in rows:
        problems.append("no row for subcommand `harness %s`" % w)
skills = ["harness"] + sorted(d for d in os.listdir(os.path.join(root, "skill")) if d.startswith("harness-"))
for s in skills:
    if "/" + s not in rows:
        problems.append("no row for skill `/%s`" % s)
clis = sorted(d for d in os.listdir(os.path.join(root, "test", "fixtures", "cli")) if os.path.isdir(os.path.join(root, "test", "fixtures", "cli", d)))
for c in clis:
    if "cli " + c not in rows:
        problems.append("no row for agent CLI `%s`" % c)
for f in ["rtdd", "supervise --install", "web --install", "harness-one", "inject",
          "pause --force and resume", "install via npx", "install via curl", "update --rollback", "swarm submission"]:
    if f not in rows:
        problems.append("no row for `%s`" % f)

# --- the per-CLI non-interactive research: a sourced row for every CLI
res, hdr = {}, None
for l in sec:
    if l.startswith("|"):
        c = cells(l)
        if c[:1] == ["cli"]:
            hdr = c; continue
        if hdr and not re.match(r"^[-| :]+$", l):
            res[c[0].strip("`")] = c
if not hdr:
    problems.append("no per-CLI research table (| cli | non-interactive command | …)")
else:
    for c in clis:
        r = res.get(c)
        if not r:
            problems.append("no non-interactive research row for CLI `%s`" % c); continue
        if len(r) != len(hdr) or any(not x for x in r):
            problems.append("research row `%s` has an empty cell" % c); continue
        if not URL.search(r[hdr.index("sources")]):
            problems.append("research row `%s` has no source link" % c)

for p in problems:
    print(p)
sys.exit(1 if problems else 0)
'
check(){ python3 -I -c "$CHECK" "$1" "$ROOT"; }

out="$(check "$DOC" 2>&1)"; rc=$?
assert_eq "$rc" "0" "the real matrix passes ($out)"

# --- fixture cases: the real doc with one defect each; the checker must fail and name it ----------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mutate(){ # <name> <python expression editing s> — writes $TMP/<name>.md from the real doc
  python3 -I -c '
import sys
s = open(sys.argv[1], encoding="utf-8").read()
exec(sys.argv[3])
open(sys.argv[2], "w", encoding="utf-8").write(s)' "$DOC" "$TMP/$1.md" "$2"; }
expect_fail(){ # <name> <message fragment> <why>
  local o rc; o="$(check "$TMP/$1.md" 2>&1)"; rc=$?
  assert_ok "fixture $1: checker fails ($3)" test "$rc" -ne 0
  assert_ok "fixture $1: names the defect" grep -qF "$2" <<<"$o"; }

mutate no-windows 's = s.replace("| `harness stop` | ✓ | ✓ |", "| `harness stop` | ✓ |  |")'
expect_fail no-windows "row \`harness stop\`: no Windows value" "a row with no Windows value"

mutate no-linux 's = s.replace("| `harness stop` | ✓ | ✓ |", "| `harness stop` |  | ✓ |")'
expect_fail no-linux "row \`harness stop\`: no Linux value" "a row with no Linux value"

mutate bad-value 's = s.replace("| `harness stop` | ✓ | ✓ |", "| `harness stop` | ✓ | planned |")'
expect_fail bad-value "neither ✓ nor n/a" "a value that is neither ✓ nor n/a"

mutate na-no-source 's = s.replace("(\"Linux with systemd + cgroup v2\", [VocanicZ/swarm README](https://github.com/VocanicZ/swarm#readme))", "(\"Linux with systemd + cgroup v2\")")'
expect_fail na-no-source "n/a has no source link" "an n/a with no source"

mutate na-not-allowed 's = s.replace("| `harness stop` | ✓ | ✓ |", "| `harness stop` | ✓ | n/a: not verified on winsma (https://example.com) |")'
expect_fail na-not-allowed "Windows n/a is allowed only for" "n/a on a feature Windows can do"

mutate target-no-issue 's = s.replace("| `harness release` | ✓ | ✓ target (#475 task 8) |", "| `harness release` | ✓ | ✓ target |")'
expect_fail target-no-issue "target names no issue" "a target with no issue"

mutate missing-subcommand 's = s.replace("| `harness doctor` | ✓ | ✓ |\n", "")'
expect_fail missing-subcommand "no row for subcommand \`harness doctor\`" "a subcommand with no row"

mutate missing-skill 's = "\n".join(l for l in s.split("\n") if not l.startswith("| `/harness-stop` |"))'
expect_fail missing-skill "no row for skill \`/harness-stop\`" "a skill with no row"

mutate missing-cli-research 's = "\n".join(l for l in s.split("\n") if not l.startswith("| `hermes` | `hermes chat -q"))'
expect_fail missing-cli-research "no non-interactive research row for CLI \`hermes\`" "a CLI with no research row"

mutate research-no-source 's = s.replace("[agent exec](https://docs.openclaw.ai/cli/agent), [Windows](https://docs.openclaw.ai/platforms/windows) |", "see the docs |")'
expect_fail research-no-source "research row \`openclaw\` has no source link" "a research row with no source"
finish
