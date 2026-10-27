#!/usr/bin/env python3
"""test_web_design.py — #231: the dashboard's design critique rounds hold, and the bar they set stays met.

docs/web/ROUNDS.md records at least three rounds, each with every view × 1440/400 × light/dark in its
own docs/web/screens/round-<n>/ (test/web_shots.py writes them), and the last round finds nothing
material. With a browser, every view at 1440 and 400 px in both themes: all visible text meets WCAG AA
contrast against what it is drawn on, every control Tab reaches shows a focus ring, and the page never
scrolls sideways at 400 px."""
import os, re, shutil, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import web_fixture as wf
import web_shots

ROUNDS = os.path.join(wf.ROOT, "docs", "web", "ROUNDS.md")
SCREENS = os.path.join(wf.ROOT, "docs", "web", "screens")
SHOTS = [f"{v}-{w}-{t}.png" for v, _, _ in web_shots.VIEWS for w, _ in web_shots.WIDTHS for t in ("light", "dark")]

# Every element with its own text (or an SVG <text>): its colour, composited through opacity, against
# the first opaque background behind it (an SVG label: its node's box). AA: 4.5:1, 3:1 for large text.
CONTRAST_JS = r"""(() => {
  const rgba = (s) => { const m = s.match(/rgba?\(([^)]+)\)/); if (!m) return null;
    const p = m[1].split(/[ ,\/]+/).filter(Boolean).map(Number); return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1]; };
  const over = (top, under) => { const a = top[3]; return [0, 1, 2].map(i => top[i] * a + under[i] * (1 - a)).concat(1); };
  const lum = (c) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
    return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]); };
  const ratio = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
  const bgOf = (el) => {
    const layers = [];
    for (let e = el; e && e.nodeType === 1; e = e.parentElement) {
      if (e.tagName === "text" || e.tagName === "a" && e.closest("svg")) {
        const box = e.closest("a") && e.closest("a").querySelector("rect.dag__box");
        if (box && e.tagName === "text") { const f = rgba(getComputedStyle(box).fill); if (f) layers.push(f); if (f && f[3] >= 1) break; }
        continue;
      }
      const c = rgba(getComputedStyle(e).backgroundColor);
      if (c && c[3] > 0) { layers.push(c); if (c[3] >= 1) break; }
    }
    let bg = [255, 255, 255, 1];
    if (!layers.length || layers[layers.length - 1][3] < 1) bg = rgba(getComputedStyle(document.body).backgroundColor) || bg;
    for (let i = layers.length - 1; i >= 0; i--) bg = over(layers[i], bg);
    return bg;
  };
  const bad = [];
  for (const el of document.querySelectorAll("body *")) {
    const own = [...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
    if (!own) continue;
    const cs = getComputedStyle(el);
    if (cs.visibility !== "visible" || el.closest("[hidden], .sr-only, .skip-link, details:not([open]) > :not(summary)")) continue;
    const r = el.getBoundingClientRect(); if (!r.width || !r.height) continue;
    let fg = rgba(el.namespaceURI.endsWith("svg") ? cs.fill : cs.color); if (!fg) continue;
    let op = 1; for (let e = el; e && e.nodeType === 1; e = e.parentElement) op *= Number(getComputedStyle(e).opacity);
    const bg = bgOf(el);
    fg = over([fg[0], fg[1], fg[2], fg[3] * op], bg);
    const size = parseFloat(cs.fontSize), bold = Number(cs.fontWeight) >= 700;
    const need = size >= 24 || (size >= 18.66 && bold) ? 3 : 4.5;
    const got = ratio(fg, bg);
    if (got < need) bad.push(`${el.tagName.toLowerCase()}.${(el.getAttribute("class") || "").replace(/ /g, ".")} "${el.textContent.trim().slice(0, 30)}" ${got.toFixed(2)}:1`);
  }
  return bad;
})()"""

# The element Tab just focused, and whether it draws a visible ring (an outline, or an inset box-shadow).
FOCUS_JS = r"""(() => { const e = document.activeElement; if (!e || e === document.body) return null;
  const cs = getComputedStyle(e);
  const ring = (cs.outlineStyle !== "none" && parseFloat(cs.outlineWidth) >= 1) || /inset|0px 0px 0px [1-9]/.test(cs.boxShadow);
  return { id: e.tagName.toLowerCase() + "." + (e.getAttribute("class") || "") + " " + (e.textContent || "").trim().slice(0, 24), ring }; })()"""


def browser():
    b = os.environ.get("HARNESS_WEB_BROWSER") or shutil.which("google-chrome") or shutil.which("chromium")
    return b if b and shutil.which("node") else None


def test_rounds_are_recorded_with_their_screenshots():
    assert os.path.exists(ROUNDS), "docs/web/ROUNDS.md is missing"
    text = open(ROUNDS).read()
    rounds = re.findall(r"^## Round (\d+)\b", text, re.M)
    assert len(rounds) >= 3, f"only {len(rounds)} rounds"
    assert rounds == [str(i) for i in range(1, len(rounds) + 1)], rounds
    for n in rounds:
        d = os.path.join(SCREENS, f"round-{n}")
        missing = [s for s in SHOTS if not os.path.isfile(os.path.join(d, s))]
        assert not missing, f"round {n} lacks {missing}"
        assert f"screens/round-{n}/" in text, f"round {n} does not link its screenshots"
    last = text[text.rindex(f"## Round {rounds[-1]}"):]
    assert re.search(r"no material issue", last, re.I), "the last round still records a material issue"


def test_overview_says_what_awaits_you():
    """`/` answers "what needs me?" (#231): a card counts its fleet's open "Awaiting you" items and links
    straight to that panel; a fleet with none says nothing."""
    with wf.serving(tmux_ls=web_shots.TMUX, now=wf.NOW) as (base, host):
        _, body = wf.get(base + "/")
        cards = {m.group(1): m.group(0) for m in re.finditer(r'<article [^>]*data-fleet="(\w+)".*?</article>', body, re.S)}
        assert re.search(r'href="/fleet/hz#awaiting-title" data-awaiting-count="3"', cards["hz"]), cards["hz"]
        assert "data-awaiting-count" not in cards["dp"], cards["dp"]
        _, page = wf.get(base + "/fleet/hz")
        assert 'id="awaiting-title"' in page
        assert not os.path.exists(host.gh_called), "gh was invoked"


def test_contrast_focus_and_no_sideways_scroll():
    b = browser()
    if not b:
        print("  SKIP: needs a Chrome and Node >= 22 (HARNESS_WEB_BROWSER)"); return
    problems = []
    with wf.serving(tmux_ls=web_shots.TMUX, now=wf.NOW) as (base, host):
        for name, path, _ in web_shots.VIEWS:
            for width, height in web_shots.WIDTHS:
                for theme in ("light", "dark"):
                    with wf.cdp(b, base + path) as page:
                        page.viewport(width, height)
                        page.scheme(theme == "dark")
                        if name == "drawer":
                            page.wait(f"{web_shots.DRAWER} && {web_shots.DRAWER}.contains(document.activeElement)", 5)
                        where = f"{name} {width} {theme}"
                        for bad in page.eval(CONTRAST_JS):
                            problems.append(f"{where}: contrast {bad}")
                        if page.eval("document.documentElement.scrollWidth") > width:
                            problems.append(f"{where}: page scrolls sideways")
                        if width == 1440 and theme == "light" or name == "drawer":
                            seen = set()
                            for _ in range(40):
                                page.key("Tab")
                                f = page.eval(FOCUS_JS)
                                if f is None or f["id"] in seen:
                                    continue
                                seen.add(f["id"])
                                if not f["ring"]:
                                    problems.append(f"{where}: no focus ring on {f['id']}")
        assert not os.path.exists(host.gh_called), "gh was invoked"
    assert not problems, "\n    " + "\n    ".join(problems)


if __name__ == "__main__":
    sys.exit(wf.run_tests(globals()))
