"""Render the Harness-vs-typical-agent-loop figure as an animated light/dark SVG pair.

Same idiom as rtdd's `how-it-picks`: plain SMIL, no script, so GitHub animates it in a
README <picture>. Run: python3 docs/figures/harness_loop.py
"""

import pathlib

W, H = 980, 650
DUR = 16.0
FONT = "ui-sans-serif, -apple-system, Segoe UI, Helvetica, Arial, sans-serif"

LIGHT = dict(name="light", bg="#ffffff", ink="#1f2328", muted="#656d76", grid="#d8dee4",
             blue="#0969da", purple="#8250df", grey="#6e7781", human="#bc4c00", ok="#1a7f37")
DARK = dict(name="dark", bg="#0d1117", ink="#e6edf3", muted="#9198a1", grid="#30363d",
            blue="#4493f8", purple="#c297ff", grey="#8b949e", human="#f0883e", ok="#3fb950")


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def appear(t, fade=0.025, start="0", end="1"):
    """Hidden until fraction t of the loop, then shown until the loop restarts."""
    a, b = max(t, 0.0001), min(t + fade, 0.9999)
    return (f'<animate attributeName="opacity" values="{start};{start};{end};{end}" '
            f'keyTimes="0;{a:.4f};{b:.4f};1" dur="{DUR}s" repeatCount="indefinite"/>')


def text(x, y, s, fill, size=12, anchor="start", weight="normal", anim=""):
    op = ' opacity="0"' if anim else ""
    return (f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" font-weight="{weight}" '
            f'fill="{fill}" text-anchor="{anchor}"{op}>{esc(s)}{anim}</text>')


def box(x, y, w, h, label, stroke, fill_text, t=None, size=11, weight="600", dash=False):
    """Rounded box that lights up (faint -> full) at fraction t."""
    d = ' stroke-dasharray="4 3"' if dash else ""
    anim = appear(t, start="0.18") if t is not None else ""
    op = ' opacity="0.18"' if t is not None else ""
    return (f'<g{op}><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="none" '
            f'stroke="{stroke}" stroke-width="1.6"{d}/>'
            + text(x + w / 2, y + h / 2 + size * 0.36, label, fill_text, size, "middle", weight)
            + f"{anim}</g>")


def arrow(x1, y1, x2, y2, c, t=None):
    anim = appear(t, start="0.18") if t is not None else ""
    op = ' opacity="0.18"' if t is not None else ""
    return (f'<g{op}><line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{c}" stroke-width="1.4"/>'
            f'<path d="M{x2} {y2} l-6 -3.5 v7 z" fill="{c}"/>{anim}</g>')


def left_panel(p):
    out = [f'<rect x="20" y="72" width="456" height="560" rx="10" fill="none" stroke="{p["grid"]}"/>',
           text(40, 100, "Typical agent loop", p["ink"], 15, weight="700"),
           text(40, 120, "one human, one agent, one chat, one project", p["muted"], 11.5),
           box(40, 138, 110, 30, "YOU", p["human"], p["human"]),
           box(346, 138, 110, 30, "AGENT", p["grey"], p["grey"]),
           f'<line x1="156" y1="149" x2="340" y2="149" stroke="{p["grid"]}" stroke-width="1.4"/>',
           f'<line x1="156" y1="157" x2="340" y2="157" stroke="{p["grid"]}" stroke-width="1.4"/>',
           text(248, 145, "prompt / approve / retry", p["muted"], 10, "middle")]
    turns = [("you", "“Build the login page”"),
             ("agent", "writes 300 lines"),
             ("you", "reads the whole diff"),
             ("you", "“tests fail, fix it”"),
             ("agent", "patches"),
             ("you", "re-runs the tests"),
             ("you", "“also handle expired tokens”"),
             ("agent", "patches again"),
             ("you", "reviews, merges"),
             ("you", "“next: password reset…”")]
    for i, (who, s) in enumerate(turns):
        t = 0.04 + i * 0.07
        y = 190 + i * 32
        human = who == "you"
        x, c = (40, p["human"]) if human else (256, p["grey"])
        out.append(f'<g opacity="0"><rect x="{x}" y="{y}" width="200" height="24" rx="12" fill="none" '
                   f'stroke="{c}" stroke-width="1.3"/>'
                   + text(x + 12, y + 16, s, p["ink"] if human else p["muted"], 11.5)
                   + appear(t) + "</g>")
    out += [text(40, 540, "7 of 10 turns needed you", p["human"], 14, weight="700", anim=appear(0.76)),
            text(40, 562, "the agent idles while you read, and you idle while it types", p["muted"], 11.5,
                 anim=appear(0.79)),
            text(40, 604, "You are the loop.", p["human"], 17, weight="700", anim=appear(0.84))]
    return out


def right_panel(p):
    X = 504
    out = [f'<rect x="{X - 4}" y="72" width="460" height="560" rx="10" fill="none" stroke="{p["grid"]}"/>',
           text(X + 16, 100, "Harness", p["ink"], 15, weight="700"),
           text(X + 16, 120, "you set the destination; a fleet walks the way", p["muted"], 11.5)]

    # Projects strip: YOU moves on to the next project once the issues exist.
    tabs = ["project A", "project B", "project C"]
    for i, s in enumerate(tabs):
        out.append(box(X + 200 + i * 80, 87, 74, 22, s, p["grid"], p["muted"], size=10, weight="normal"))
    out.append(f'<g><rect x="{X + 200}" y="87" width="74" height="22" rx="6" fill="none" stroke="{p["human"]}" '
               f'stroke-width="2.2"/><animateTransform attributeName="transform" type="translate" '
               f'values="0 0;0 0;80 0;80 0;160 0;160 0" keyTimes="0;0.26;0.29;0.50;0.53;1" '
               f'dur="{DUR}s" repeatCount="indefinite"/></g>')

    # Human zone.
    out += [f'<rect x="{X + 8}" y="140" width="440" height="64" rx="8" fill="none" stroke="{p["human"]}" '
            f'stroke-dasharray="5 4"/>',
            text(X + 16, 154, "you, once per project", p["human"], 10.5, weight="700"),
            box(X + 16, 164, 128, 30, "grilling session", p["human"], p["ink"], 0.04),
            arrow(X + 146, 179, X + 166, 179, p["human"], 0.11),
            box(X + 168, 164, 128, 30, "wayfinder map", p["human"], p["ink"], 0.12),
            arrow(X + 298, 179, X + 318, 179, p["human"], 0.19),
            box(X + 320, 164, 120, 30, "PRD → issues", p["human"], p["ink"], 0.20)]

    # Autonomous zone.
    out += [f'<rect x="{X + 8}" y="216" width="440" height="330" rx="8" fill="none" stroke="{p["blue"]}" '
            f'stroke-dasharray="5 4"/>',
            text(X + 16, 232, "autonomous: no human in this loop", p["blue"], 10.5, weight="700")]

    # GitHub issue board.
    cols = ["ready-for-agent", "agent-working", "closed"]
    cx = [X + 24, X + 168, X + 312]
    for x, s in zip(cx, cols):
        out += [f'<rect x="{x}" y="244" width="128" height="74" rx="6" fill="none" stroke="{p["grid"]}"/>',
                text(x + 8, 258, s, p["muted"], 10, weight="600")]
    out.append(text(X + 440, 232, "GitHub issue board", p["muted"], 10, "end"))
    lane_start = [0.27, 0.31, 0.35]
    step = 0.055
    for k in range(3):
        s0 = lane_start[k]
        s_done = s0 + 5 * step
        y = 266 + k * 16
        kt = f"0;{s0:.4f};{s0 + 0.02:.4f};{s_done:.4f};{s_done + 0.02:.4f};1"
        out.append(f'<g opacity="0"><rect x="{cx[0] + 8}" y="{y}" width="112" height="13" rx="3" '
                   f'fill="{p["blue"]}" fill-opacity="0.16" stroke="{p["blue"]}" stroke-width="0.8"/>'
                   + text(cx[0] + 14, y + 10, f"#{41 + k}  issue", p["ink"], 9.5)
                   + appear(0.22)
                   + f'<animateTransform attributeName="transform" type="translate" '
                   f'values="0 0;0 0;144 0;144 0;288 0;288 0" keyTimes="{kt}" dur="{DUR}s" '
                   f'repeatCount="indefinite"/></g>')

    # Parallel workers: manager -> implementer -> auditor -> rtdd -> merged.
    out.append(text(X + 16, 342, "parallel workers, one issue each", p["muted"], 10, weight="600"))
    roles = [("manager", "purple"), ("implementer", "blue"), ("auditor", "purple"),
             ("rtdd ✓", "blue"), ("merged", "ok")]
    for k in range(3):
        y = 352 + k * 38
        out.append(text(X + 20, y + 19, f"worker {k + 1}", p["ink"], 10.5, weight="600"))
        for j, (role, c) in enumerate(roles):
            x = X + 80 + j * 70
            t = lane_start[k] + j * step
            out.append(box(x, y, 65, 28, role, p[c], p["ink"], t, size=10))
            if j:
                out.append(arrow(x - 8, y + 14, x - 1, y + 14, p["grid"]))
    out.append(text(X + 440, 342, "rtdd: only the tests your diff touches", p["muted"], 9.5, "end"))

    # Gauntlet review, with the loop-back that files one issue per gap.
    tg = 0.66
    out += [box(X + 24, 474, 196, 30, "gauntlet: ours vs reference", p["purple"], p["ink"], tg),
            arrow(X + 222, 489, X + 242, 489, p["purple"], tg + 0.04),
            box(X + 244, 474, 112, 30, "blind critic", p["purple"], p["ink"], tg + 0.05),
            text(X + 24, 524, "loses → files one issue for the gap, back to the board", p["muted"], 10,
                 anim=appear(tg + 0.07)),
            f'<g opacity="0"><path d="M{X + 358} 489 H{X + 438} V238 H{X + 88} V242" fill="none" '
            f'stroke="{p["purple"]}" stroke-width="1.2" stroke-dasharray="3 3"/>'
            f'<path d="M{X + 88} 244 l-3.5 -6 h7 z" fill="{p["purple"]}"/>{appear(tg + 0.07)}</g>',
            text(X + 24, 540, "wins → PRD reviewed, unit COMPLETE ✓", p["ok"], 10.5, weight="700",
                 anim=appear(tg + 0.11))]

    out += [text(X + 16, 576, "1 grilling session per project", p["blue"], 14, weight="700",
                 anim=appear(0.80)),
            text(X + 16, 594, "while A builds itself, you are already grilling B and C", p["muted"], 11.5,
                 anim=appear(0.82)),
            text(X + 16, 618, "You are outside the loop.", p["blue"], 17, weight="700", anim=appear(0.86))]
    return out


def render(p):
    body = [f'<rect x="0" y="0" width="{W}" height="{H}" fill="{p["bg"]}"/>',
            text(24, 32, "Where the human sits", p["ink"], 17, weight="700"),
            text(24, 52, "Same feature, two ways of building it. Orange is you.", p["muted"], 11.5),
            *left_panel(p), *right_panel(p)]
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
            f'role="img">\n' + "\n".join(body) + "\n</svg>\n")


if __name__ == "__main__":
    here = pathlib.Path(__file__).resolve().parent
    for p in (LIGHT, DARK):
        (here / f"harness-loop-{p['name']}.svg").write_text(render(p), encoding="utf-8")
