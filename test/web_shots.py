#!/usr/bin/env python3
"""web_shots.py — the capture for #231's design critique rounds (docs/web/ROUNDS.md).

Serves the test fixture host (web_fixture.serving, the same data every web test reads) and writes one
PNG per view × width × theme into docs/web/screens/ (or <outdir>): the host overview `/`, the fleet
DAG `/fleet/hz`, and the issue drawer open on #13 — each at 1440 and 400 px, light and dark. Pages are
shot full height; the drawer (a fixed layer) is shot at the viewport. Every capture also reports the
page's scrollWidth, so a sideways scroll at 400 px shows up here and not only in a picture.

Not a test (run.sh runs test_* only): usage  python3 test/web_shots.py [outdir]
Needs a Chrome (HARNESS_WEB_BROWSER, google-chrome or chromium) and Node >= 22.
"""
import os, shutil, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import web_fixture as wf

TMUX = "hz-arc-i11\t%d\n" % (wf.NOW - 600)
VIEWS = (("overview", "/", True), ("fleet", "/fleet/hz", True), ("drawer", "/fleet/hz?issue=13", False))
WIDTHS = ((1440, 900), (400, 860))
DRAWER = "document.querySelector('aside[role=\"dialog\"]')"


def shoot(outdir, browser):
    os.makedirs(outdir, exist_ok=True)
    wide = []
    with wf.serving(tmux_ls=TMUX, now=wf.NOW) as (base, _host):
        for name, path, full in VIEWS:
            with wf.cdp(browser, base + path) as page:
                for width, height in WIDTHS:
                    for theme in ("light", "dark"):
                        page.viewport(width, height)
                        page.scheme(theme == "dark")
                        if not full:
                            page.wait(f"{DRAWER} && {DRAWER}.contains(document.activeElement)", 5)
                        page.eval("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")
                        sw = page.eval("document.documentElement.scrollWidth")
                        out = os.path.join(outdir, f"{name}-{width}-{theme}.png")
                        page.shot(out, full=full)
                        print(f"{out}  scrollWidth={sw}")
                        if sw > width:
                            wide.append(f"{name} at {width} {theme}: {sw}px")
    for w in wide:
        print("SIDEWAYS SCROLL:", w)
    return 1 if wide else 0


if __name__ == "__main__":
    browser = os.environ.get("HARNESS_WEB_BROWSER") or shutil.which("google-chrome") or shutil.which("chromium")
    if not (browser and shutil.which("node")):
        sys.exit("web_shots.py needs a Chrome (HARNESS_WEB_BROWSER) and Node >= 22")
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(wf.ROOT, "docs", "web", "screens")
    sys.exit(shoot(out, browser))
