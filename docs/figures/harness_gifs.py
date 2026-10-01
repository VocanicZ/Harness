"""Render the two README GIFs: a typical agent loop, and one Harness PRD from grill to COMPLETE.

Each frame is a static SVG built for time t, rasterised with librsvg, then encoded by ffmpeg
(the same pipeline as rtdd's rtdd-loop.gif). Run: python3 docs/figures/harness_gifs.py
Needs python3-gi (Rsvg 2.0), pycairo and ffmpeg.
"""

import pathlib
import subprocess

import cairo
import gi

gi.require_version("Rsvg", "2.0")
from gi.repository import Rsvg  # noqa: E402

W, H = 1040, 680
FPS = 10
SCALE = 2
FONT = "ui-sans-serif, -apple-system, Segoe UI, Helvetica, Arial, sans-serif"
C = dict(bg="#0d1117", ink="#e6edf3", muted="#9198a1", grid="#30363d", faint="#161b22",
         blue="#4493f8", purple="#c297ff", grey="#8b949e", human="#f0883e", ok="#3fb950", bad="#ff3b3b")


# --- drawing helpers ---------------------------------------------------------------------

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def fade(t, t0, d=0.3):
    return max(0.0, min(1.0, (t - t0) / d))


def text(x, y, s, fill=C["ink"], size=12, anchor="start", weight="normal", op=1.0):
    if op <= 0:
        return ""
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-family="{FONT}" font-size="{size}" font-weight="{weight}" '
            f'fill="{fill}" text-anchor="{anchor}" opacity="{op:.2f}">{esc(s)}</text>')


def rect(x, y, w, h, stroke=C["grid"], fill="none", fill_op=1.0, rx=6, sw=1.3, dash=False, op=1.0):
    if op <= 0 or w <= 0:
        return ""
    d = ' stroke-dasharray="4 3"' if dash else ""
    return (f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{rx}" fill="{fill}" '
            f'fill-opacity="{fill_op}" stroke="{stroke}" stroke-width="{sw}"{d} opacity="{op:.2f}"/>')


def arrow(x1, y1, x2, y2, c, op=1.0, dash=False):
    if op <= 0:
        return ""
    d = ' stroke-dasharray="3 3"' if dash else ""
    mx = (x1 + x2) / 2
    return (f'<g opacity="{op:.2f}"><path d="M{x1} {y1} C{mx} {y1}, {mx} {y2}, {x2 - 6} {y2}" fill="none" '
            f'stroke="{c}" stroke-width="1.4"{d}/><path d="M{x2} {y2} l-7 -4 v8 z" fill="{c}"/></g>')


def svg(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">'
            f'<rect width="{W}" height="{H}" fill="{C["bg"]}"/>' + "".join(body) + "</svg>")


def caption_at(t, captions):
    cur = captions[0][1]
    for t0, s in captions:
        if t >= t0:
            cur = s
    return cur


# --- GIF 2: Harness -----------------------------------------------------------------------

STEPS = ["manager", "implementer", "auditor", "rtdd", "merge"]
STEP_NOTE = {"manager": "manager: reads the issue, plans the subtasks",
             "implementer": "implementer: writes the code and its tests",
             "auditor": "auditor: independent check against the issue",
             "rtdd": "rtdd: runs only the 4 of 53 tests this diff touches",
             "merge": "merge: green on the moved base, then into main"}

ISSUES = {  # id: (title, blocked by, node x, node y)
    41: ("DB schema", [], 520, 100),
    42: ("UI kit", [], 520, 158),
    43: ("mail client", [], 520, 216),
    44: ("auth API", [41], 690, 100),
    45: ("login page", [42, 44], 860, 128),
    46: ("password reset", [43, 44], 860, 206),
    47: ("faster login", [], 350, 220),
}
APPEAR = {41: 5.3, 42: 5.6, 43: 5.9, 44: 6.2, 45: 6.5, 46: 6.8, 47: 25.4}
SPLIT_DONE = 8.2


def job(issue, start, d=0.9, fail_audit=False):
    seq = [0, 1, 2, 3, 4] if not fail_audit else [0, 1, "fail", 1, 2, 3, 4]
    steps, t = [], start
    for s in seq:
        steps.append((s, t, t + d))
        t += d
    return dict(issue=issue, start=start, end=t, steps=steps)


WORKERS = [
    [job(41, 9.0), job(44, 13.7), job(45, 18.4)],
    [job(42, 9.0, fail_audit=True), job(47, 25.6, d=0.7)],
    [job(43, 9.0), job(46, 18.4)],
]
CLOSED = {j["issue"]: j["end"] for w in WORKERS for j in w}
TAKEN = {j["issue"]: (j["start"], wi + 1) for wi, w in enumerate(WORKERS) for j in w}
T_REVIEW, T_G1, T_FILE, T_G2, T_DONE, T_END = 23.2, 24.4, 25.4, 29.3, 30.3, 35.0

H_CAPTIONS = [
    (0.0, "1 · You describe the feature. Harness grills you until every decision is made."),
    (3.3, "Wayfinder charts the open decisions and resolves them one at a time."),
    (4.2, "The answers become PRD #40, a GitHub issue."),
    (5.0, "2 · Harness splits PRD #40 into 6 issues…"),
    (6.9, "…and records which issue blocks which (## Blocked by)."),
    (SPLIT_DONE, "Only unblocked issues become ready-for-agent. You are no longer needed: on to project B."),
    (9.0, "3 · Three workers each claim a ready issue: manager → implementer → auditor → rtdd → merge."),
    (10.8, "The auditor FAILS #42: buttons aren't keyboard-focusable. Back to the implementer, no human involved."),
    (13.5, "#41 merged, so #44 unblocks and worker 1 takes it. Worker 3 waits: its next issues need #44."),
    (15.3, "#42 passes its second audit and merges."),
    (18.2, "#44 merged, so #45 and #46 unblock. Two workers build them in parallel."),
    (T_REVIEW, "4 · All 6 issues closed. The reviewer checks PRD #40's acceptance criteria: 6 of 6 pass."),
    (T_G1, "Gauntlet round 1: a blind critic compares ours with the reference. Ours loses: login is slower."),
    (T_FILE, "The reviewer files one issue for that gap (#47), and a worker picks it up."),
    (T_G2, "Gauntlet round 2: ours wins."),
    (T_DONE, "5 · PRD #40 is reviewed and COMPLETE. You were needed for one grilling session."),
]


def issue_state(i, t):
    if t < APPEAR[i]:
        return None
    if i in CLOSED and t >= CLOSED[i]:
        return "closed"
    if i in TAKEN and t >= TAKEN[i][0]:
        return "working"
    if t < SPLIT_DONE and i != 47:
        return "new"
    deps = ISSUES[i][1]
    return "ready" if all(d in CLOSED and t >= CLOSED[d] for d in deps) else "blocked"


def current(wi, t):
    for j in WORKERS[wi]:
        if j["start"] <= t < j["end"]:
            for s, a, b in j["steps"]:
                if a <= t < b:
                    return j, s, (t - a) / (b - a)
    return None, None, 0


def harness_frame(t):
    b = [text(24, 34, "Harness: one PRD, from idea to done", size=19, weight="700")]
    phases = [("grill", 0, C["human"]), ("decompose", 5, C["blue"]), ("build", 9, C["blue"]),
              ("review", T_REVIEW, C["purple"]), ("done", T_DONE, C["ok"])]
    for k, (name, t0, c) in enumerate(phases):
        nxt = phases[k + 1][1] if k + 1 < len(phases) else 99
        active = t0 <= t < nxt
        x = 580 + k * 88
        b.append(rect(x, 16, 82, 24, stroke=c if active or t >= nxt else C["grid"],
                      fill=c, fill_op=0.15 if active else 0, sw=2 if active else 1.2))
        b.append(text(x + 41, 32, f"{k + 1} {name}", c if active else C["muted"], 11, "middle",
                      "700" if active else "normal"))
    b.append(text(24, 62, caption_at(t, H_CAPTIONS), C["ink"], 13, weight="600"))

    # YOU panel.
    b.append(rect(20, 76, 300, 584, stroke=C["human"], sw=1.6))
    b.append(text(36, 100, "YOU", C["human"], 14, weight="700"))
    bubbles = [(0.4, "agent", "Who logs in: email or SSO?"), (1.1, "you", "email + password"),
               (1.8, "agent", "Reset by email link?"), (2.5, "you", "yes, link expires in 30 min"),
               (3.3, "map", "wayfinder: 4 decisions resolved"), (4.2, "prd", "PRD #40 written ✓")]
    dim = 0.45 if t >= SPLIT_DONE else 1.0
    for k, (t0, who, s) in enumerate(bubbles):
        op = fade(t, t0) * dim
        y = 116 + k * 40
        x, c = {"agent": (100, C["grey"]), "you": (36, C["human"]),
                "map": (36, C["purple"]), "prd": (36, C["blue"])}[who]
        b.append(rect(x, y, 268 if who in ("map", "prd") else 204, 28, stroke=c, rx=14, op=op))
        b.append(text(x + 12, y + 18, s, C["ink"] if who != "agent" else C["muted"], 11.5, op=op))
    b.append(text(36, 372, "you leave the loop", C["human"], 12, weight="700", op=fade(t, SPLIT_DONE)))
    away = [(SPLIT_DONE, "→ grilling project B"), (16.0, "→ grilling project C"),
            (T_DONE, "✓ notified: PRD #40 COMPLETE")]
    for k, (t0, s) in enumerate(away):
        c = C["ok"] if s.startswith("✓") else C["human"]
        b.append(rect(36, 386 + k * 40, 268, 28, stroke=c, rx=14, op=fade(t, t0)))
        b.append(text(48, 404 + k * 40, s, C["ink"], 11.5, op=fade(t, t0)))
    op = fade(t, T_DONE + 0.4)
    b.append(text(36, 612, "your time on PRD #40:", C["muted"], 11.5, op=op))
    b.append(text(36, 636, "1 grilling session", C["human"], 17, weight="700", op=op))

    # Dependency map = the GitHub issue board.
    b.append(rect(340, 76, 680, 194))
    b.append(text(352, 96, "GitHub issues: who blocks whom", C["muted"], 11, weight="700"))
    b.append(text(1008, 96, "label = state", C["muted"], 10, "end"))
    prd_op = fade(t, 4.2)
    b.append(rect(356, 150, 110, 44, stroke=C["blue"], sw=1.8, op=prd_op))
    b.append(text(411, 168, "PRD #40", C["ink"], 11.5, "middle", "700", op=prd_op))
    closed_all = t >= T_DONE
    b.append(text(411, 184, "reviewed ✓" if closed_all else "prd", C["ok"] if closed_all else C["muted"],
                  9.5, "middle", op=prd_op))
    for i in range(41, 47):
        split_op = fade(t, APPEAR[i]) * (1 - 0.85 * fade(t, SPLIT_DONE, 0.8))
        b.append(arrow(466, 172, ISSUES[i][2], ISSUES[i][3] + 18, C["grid"], split_op, dash=True))
    for i, (_, deps, x, y) in ISSUES.items():
        for d in deps:
            dx, dy = ISSUES[d][2], ISSUES[d][3]
            b.append(arrow(dx + 120, dy + 18, x, y + 18, C["grey"], fade(t, 6.9 + 0.2 * (i - 44))))
    if t >= T_FILE:
        b.append(text(352, 212, "filed by the gauntlet ↓", C["purple"], 9.5, "start", op=fade(t, T_FILE)))
    for i, (title, _, x, y) in ISSUES.items():
        st = issue_state(i, t)
        if st is None:
            continue
        op = fade(t, APPEAR[i])
        failing = False
        if st == "working":
            wn = TAKEN[i][1]
            _, s, _ = current(wn - 1, t)
            failing = s == "fail"
        stroke, fill, fop, label, lc = {
            "new": (C["grey"], "none", 0, "new", C["muted"]),
            "blocked": (C["grey"], "none", 0, "blocked", C["muted"]),
            "ready": (C["blue"], "none", 0, "ready-for-agent", C["blue"]),
            "working": (C["blue"], C["blue"], 0.14, f"agent-working · W{TAKEN[i][1]}" if i in TAKEN else "",
                        C["blue"]),
            "closed": (C["ok"], C["ok"], 0.12, "closed ✓", C["ok"]),
        }[st]
        if failing:
            stroke, fill, label, lc = C["bad"], C["bad"], "audit FAILED", C["bad"]
        b.append(rect(x, y, 120, 36, stroke=stroke, fill=fill, fill_op=fop, sw=1.8,
                      dash=st == "blocked", op=op))
        b.append(text(x + 8, y + 15, f"#{i} {title}", C["ink"] if st != "blocked" else C["muted"], 10.5,
                      weight="700", op=op))
        b.append(text(x + 8, y + 29, label, lc, 9.5, op=op))

    # Workers.
    b.append(rect(340, 280, 680, 270))
    b.append(text(352, 300, "3 parallel workers", C["muted"], 11, weight="700"))
    for wi in range(3):
        y = 314 + wi * 76
        b.append(text(352, y + 19, f"worker {wi + 1}", C["ink"], 11.5, weight="700"))
        j, s, prog = current(wi, t)
        if j is None:
            if t < 9:
                why = "waiting for issues"
            elif t < 18.4 and wi > 0:
                why = "idle: next issues are blocked by #44"
            elif t < T_REVIEW:
                why = "idle: nothing ready"
            else:
                why = "idle"
            b.append(text(428, y + 19, why, C["muted"], 11))
            continue
        b.append(text(428, y + 19, f"#{j['issue']} {ISSUES[j['issue']][0]}", C["blue"], 11.5, weight="700"))
        pill = 2 if s == "fail" else s
        reworked = any(st == "fail" and t >= bb for st, _, bb in j["steps"])
        for k, name in enumerate(STEPS):
            x = 560 + k * 92
            col = C["purple"] if name in ("manager", "auditor") else C["blue"]
            if name == "merge":
                col = C["ok"]
            label = name
            if k < pill:
                b.append(rect(x, y, 84, 28, stroke=col, fill=col, fill_op=0.10))
                label = name + " ✓"
            elif k == pill:
                if s == "fail":
                    col, label = C["bad"], "auditor ✗"
                b.append(rect(x, y, 84, 28, stroke=col, sw=2.2))
                b.append(rect(x, y, 84 * prog, 28, stroke="none", fill=col, fill_op=0.22))
            else:
                b.append(rect(x, y, 84, 28, op=0.6))
            b.append(text(x + 42, y + 18, label, C["ink"] if k <= pill else C["muted"], 10.5, "middle",
                          "700" if k == pill else "normal"))
        if s == "fail":
            note, nc = "auditor: FAIL, buttons aren't keyboard-focusable → back to the implementer", C["bad"]
        else:
            note, nc = STEP_NOTE[STEPS[s]], C["muted"]
            if reworked and s == 1:
                note, nc = "implementer: fixes what the auditor found", C["bad"]
            elif reworked and s == 2:
                note, nc = "auditor: second check passes", C["ok"]
        b.append(text(560, y + 48, note, nc, 10.5))

    # Review.
    b.append(rect(340, 560, 680, 100, stroke=C["purple"] if t >= T_REVIEW else C["grid"]))
    b.append(text(352, 580, "review", C["muted"], 11, weight="700"))
    chips = [(T_REVIEW + 0.4, "criteria 6/6 ✓", C["ok"]), (T_G1, "gauntlet r1 ✗ lose", C["bad"]),
             (T_FILE, "#47 filed → fixed", C["blue"]), (T_G2, "gauntlet r2 ✓ win", C["ok"])]
    for k, (t0, s, c) in enumerate(chips):
        x = 352 + k * 166
        if k == 2 and t < CLOSED[47]:
            s = "#47 filed → building"
        b.append(rect(x, 590, 156, 28, stroke=c, op=fade(t, t0)))
        b.append(text(x + 78, 609, s, C["ink"], 11, "middle", "700", op=fade(t, t0)))
        if k:
            b.append(arrow(x - 10, 604, x - 1, 604, C["grid"], fade(t, t0)))
    if t < T_DONE:
        b.append(text(352, 644, "critic sees only two unlabelled folders, A and B, and picks a winner",
                      C["muted"], 10.5, op=fade(t, T_G1)))
    b.append(text(352, 646, "PRD #40 reviewed · COMPLETE ✓", C["ok"], 17, weight="700", op=fade(t, T_DONE)))
    return svg(b)


# --- GIF 1: typical agent loop -------------------------------------------------------------

X0, X1, TSPAN = 196, 1010, 25.0


def tx(t):
    return X0 + (X1 - X0) * t / TSPAN


def chat_timeline():
    """(who, label, start, end, colour) blocks for one chat agent doing 6 issues in a row."""
    out, t = [], 0.0
    for i in range(41, 47):
        out.append(("you", "prompt", t, t + 0.5, "human")); t += 0.5
        out.append(("agent", f"#{i}", t, t + 2.0, "blue")); out.append(("you", "waiting", t, t + 2.0, "wait")); t += 2.0
        out.append(("you", "review", t, t + 0.8, "human")); t += 0.8
        if i == 42:
            out.append(("you", "fix it", t, t + 0.4, "bad")); t += 0.4
            out.append(("agent", "fix", t, t + 1.0, "blue")); out.append(("you", "", t, t + 1.0, "wait")); t += 1.0
            out.append(("you", "review", t, t + 0.5, "human")); t += 0.5
        out.append(("you", "merge", t, t + 0.3, "human")); t += 0.3
    return out


def loop_timeline():
    """(who, label, start, end, colour) blocks for one autonomous agent looping the same 6 issues."""
    out, t = [("you", "prompt", 0.0, 0.5, "human")], 0.5
    for i in range(41, 47):
        out.append(("agent", f"#{i}", t, t + 1.8, "blue")); t += 1.8
        out.append(("agent", "self", t, t + 0.5, "grey")); t += 0.5
        out.append(("agent", "suite", t, t + 1.2, "suite")); t += 1.2
    out.append(("you", "review PR", t, t + 2.0, "human")); t += 2.0
    out.append(("you", "bug!", t, t + 1.2, "bad"))
    return out


CHAT, LOOP = chat_timeline(), loop_timeline()
T1_END = 28.0

T_CAPTIONS = [
    (0.0, "Same feature, same 6 issues, same speed per step as the Harness GIF. Time runs left to right."),
    (0.6, "Chat agent: you write every prompt, then sit and wait while it codes…"),
    (3.0, "…then you read the diff and merge before the next issue can even start."),
    (6.0, "Tests fail on #42. You notice, you re-prompt, you review again."),
    (11.0, "Single-agent loop: you are free per step, but one agent does one issue at a time…"),
    (14.0, "…grades its own work in the same context, and re-runs the full suite every time."),
    (21.5, "At the end you review one big PR, and find the bug its self-review missed."),
    (24.5, "Either way: one agent, one issue at a time, one project at a time, and you are the quality gate."),
]


def lane(b, t, y, title, sub, blocks, stats):
    b.append(rect(20, y, 1000, 236))
    b.append(text(36, y + 24, title, C["ink"], 15, weight="700"))
    b.append(text(36, y + 42, sub, C["muted"], 11.5))
    rows = {"agent": y + 66, "you": y + 116}
    b.append(text(36, rows["agent"] + 19, "agent", C["grey"], 12, weight="700"))
    b.append(text(36, rows["you"] + 19, "you", C["human"], 12, weight="700"))
    for yy in rows.values():
        b.append(rect(X0, yy, X1 - X0, 28, stroke=C["grid"], fill=C["faint"], rx=4, sw=0.8))
    touches = 0
    for who, label, a, e, kind in blocks:
        if t < a:
            continue
        if kind in ("human", "bad"):
            touches += 1
        e2 = min(e, t)
        col = {"human": C["human"], "bad": C["bad"], "blue": C["blue"], "grey": C["grey"],
               "suite": C["grey"], "wait": C["human"]}[kind]
        fop = {"wait": 0.10, "suite": 0.30, "grey": 0.15}.get(kind, 0.85)
        b.append(rect(tx(a) + 0.5, rows[who] + 2, tx(e2) - tx(a) - 1, 24, stroke="none", fill=col,
                      fill_op=fop, rx=3))
        if label and tx(e2) - tx(a) >= len(label) * 6.2 + 8:
            tc = "#ffffff" if fop > 0.5 else C["ink"]
            b.append(text((tx(a) + tx(e2)) / 2, rows[who] + 18, label, tc, 10, "middle", "700"))
    b.append(text(X0, y + 176, stats[0].format(touches=touches, s="" if touches == 1 else "s"), C["human"], 12.5, weight="700"))
    b.append(text(X0, y + 196, stats[1], C["muted"], 11.5))
    b.append(text(X0, y + 216, stats[2], C["muted"], 11.5))


def typical_frame(t):
    b = [text(24, 34, "Typical agentic coding: the same 6 issues", size=19, weight="700"),
         text(24, 62, caption_at(t, T_CAPTIONS), C["ink"], 13, weight="600")]
    lane(b, t, 80, "Chat agent", "orange: you prompt, review, merge · faint: you wait while it codes · red: you catch a failure", CHAT,
         ("you were needed {touches} time{s}", "workers: 1 · issues in parallel: 1",
          "you are watching the whole time, so: projects at once: 1"))
    lane(b, t, 326, "Single-agent loop harness", "blue: codes an issue · grey: grades its own work, then runs the full suite · red: the bug you find at the end",
         LOOP, ("you were needed {touches} time{s}", "workers: 1 · full test suite after every issue",
                "nobody independent checks the work until you do, at the end"))
    for k in range(0, 26, 5):
        b.append(text(tx(k), 578, f"{k}s", C["muted"], 10, "middle"))
    if t < TSPAN:
        x = tx(t)
        b.append(f'<line x1="{x:.1f}" y1="140" x2="{x:.1f}" y2="568" stroke="{C["ink"]}" stroke-width="1.2" '
                 f'stroke-dasharray="3 3"/>')
    b.append(rect(20, 594, 1000, 66, stroke=C["grid"], fill=C["faint"]))
    b.append(text(36, 622, "Harness, same work:", C["blue"], 13, weight="700"))
    b.append(text(36, 644, "3 workers in parallel · an independent auditor per issue · rtdd instead of the full "
                  "suite · you needed once.", C["ink"], 12.5, op=1))
    return svg(b)


# --- encode ------------------------------------------------------------------------------

def encode(frame_fn, seconds, out):
    mp4 = out.with_suffix(".mp4")
    w, h = W * SCALE, H * SCALE
    proc = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo",
                             "-pixel_format", "bgra", "-video_size", f"{w}x{h}", "-framerate", str(FPS),
                             "-i", "pipe:0", "-c:v", "libx264", "-crf", "16", "-pix_fmt", "yuv420p", str(mp4)],
                            stdin=subprocess.PIPE)
    for n in range(int(seconds * FPS)):
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
        handle = Rsvg.Handle.new_from_data(frame_fn(n / FPS).encode())
        vp = Rsvg.Rectangle()
        vp.x, vp.y, vp.width, vp.height = 0, 0, w, h
        handle.render_document(cairo.Context(surface), vp)
        proc.stdin.write(surface.get_data())
    proc.stdin.close()
    assert proc.wait() == 0
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(mp4), "-filter_complex",
                    f"fps={FPS},scale={W}:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];"
                    "[b][p]paletteuse=dither=none", "-loop", "0", str(out)], check=True)
    mp4.unlink()


if __name__ == "__main__":
    here = pathlib.Path(__file__).resolve().parent
    encode(typical_frame, T1_END, here / "typical-agent-loop.gif")
    encode(harness_frame, T_END, here / "harness-loop.gif")
