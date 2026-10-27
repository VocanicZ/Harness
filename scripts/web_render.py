#!/usr/bin/env python3
"""web_render.py — the one place `harness web` produces HTML (#223).

Every view is rendered here from the plain dicts web_data.py builds; nothing else, including app.js,
renders the same data a second time. Each live part of a page is a `<section data-region="…">`, the
unit a later SSE push replaces whole. No inline style or script: the server's CSP refuses both.
"""
import html
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fleetview  # noqa: E402

# state → (status-word class, label). Colour is meaning: green fine, amber waiting, red broken, grey idle.
STATES = {
    "running": ("level--green", "running"),
    "complete": ("level--green", "complete"),
    "paused": ("level--amber", "paused"),
    "stopped": ("level--grey", "stopped"),
    "dead": ("level--red", "dead"),
    "missing": ("level--red", "missing"),
}


def esc(s):
    return html.escape("" if s is None else str(s), quote=True)


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def asof_stamp(asof, now):
    """`data as of <time>` — the board's own clock (a dead poller reads stale), never the server's."""
    if asof is None:
        return '<span class="asof">data as of <span class="asof__unknown">unknown (no board snapshot)</span></span>'
    return (f'<span class="asof">data as of <time datetime="{iso(asof)}" title="{iso(asof)}">'
            f'{fleetview.fmt_age(now - asof)} ago</time></span>')


def page(title, body, asof, now, crumbs=()):
    """A whole document: the copied design tokens, the top bar with breadcrumbs and the theme toggle,
    then <body>. <crumbs> is [(label, href)] after "Harness"; the last one is the current page."""
    trail = [("Harness", "/")] + list(crumbs)
    items = []
    for i, (label, href) in enumerate(trail):
        if i == len(trail) - 1:
            items.append(f'<li><span aria-current="page">{esc(label)}</span></li>')
        else:
            items.append(f'<li><a href="{esc(href)}">{esc(label)}</a></li>')
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)} · Harness</title>
<link rel="stylesheet" href="/static/tokens.css">
<link rel="stylesheet" href="/static/components.css">
<link rel="stylesheet" href="/static/app.css">
<script src="/static/app.js"></script>
</head>
<body>
<a class="skip-link" href="#main">Skip to content</a>
<header class="topbar">
<nav class="breadcrumbs" aria-label="Breadcrumb"><ol>{"".join(items)}</ol></nav>
<div class="topbar__end">
<button type="button" class="btn btn--ghost btn--sm" data-theme-toggle aria-label="Theme: follow the system">Theme: auto</button>
</div>
</header>
<main id="main" class="page">
{body}
</main>
</body>
</html>
"""


def _tally_text(t):
    if t is None:
        return '<span class="muted">counts unknown (no board snapshot)</span>'
    return (f'<span class="num">{t["open"]}</span> open · <span class="num">{t["unblocked"]}</span> unblocked · '
            f'<span class="num">{len(t["working"])}</span> agent-working')


# session activity (the supervisor's pane rule) → status-word class. Only trouble is coloured.
ACTIVITY = {"active": "level--green", "quiet": "level--grey", "nudged": "level--amber", "frozen": "level--red"}


def _rel(ts, now):
    """`<time>` for an epoch: "in 30m" ahead of now, "5m ago" behind it, the ISO stamp as its title."""
    rel = f"in {fleetview.fmt_age(ts - now)}" if ts > now else f"{fleetview.fmt_age(now - ts)} ago"
    return f'<time datetime="{iso(ts)}" title="{iso(ts)}">{rel}</time>'


def _attention_item(a):
    k, what = a["kind"], esc(a.get("what"))
    if k == "frozen":
        return f'session <span class="mono">{what}</span> is frozen — no activity past the supervisor\'s kill time'
    if k == "stale-lock":
        repo = f' <span class="mono muted">{esc(a["repo"])}</span>' if a.get("repo") else ""
        return f'<span class="mono">{what}</span>{repo} holds the working label with no live session'
    if k == "stale-pidfile":
        return f'pid file <span class="mono">{what}</span> names a process that is gone'
    if k == "stale-claim":
        return f'claim <span class="mono">{what}</span> is held by a worker that is gone'
    if k == "alarm":
        return f'alarm <span class="mono">{what}</span>: {esc(a.get("message"))}'
    if k == "dead":
        return 'fleet is dead — pid files but no live process (<code>harness start --recover</code>)'
    if k == "missing":
        return 'project dir is gone — stale registry entry (<code>harness doctor --fix</code> prunes it)'
    return f'{esc(k)} <span class="mono">{what}</span>'


def _sessions_table(sessions, now):
    if not sessions:
        return '<p class="muted">No live sessions.</p>'
    rows = []
    for s in sessions:
        act = s["activity"]
        act_html = (f'<span class="level {ACTIVITY.get(act, "level--grey")}">{esc(act)}</span>' if act
                    else '<span class="muted">unknown</span>')
        age = "?" if s["age_s"] is None else fleetview.fmt_age(s["age_s"])
        rows.append(f'<tr data-session="{esc(s["name"])}" data-activity="{esc(act or "unknown")}">'
                    f'<td><span class="table__primary">{esc(s["issue"])}</span>'
                    f'<span class="table__secondary mono">{esc(s["name"])}</span></td>'
                    f'<td>{esc(s["kind"])}</td>'
                    f'<td>{esc(s["cli"])}<span class="table__secondary mono">{esc(s["model"] or "?")}</span></td>'
                    f'<td class="num">{age}</td><td>{act_html}</td></tr>')
    return ('<div class="table-wrap"><table class="table fleet__sessions"><caption class="sr-only">Live sessions</caption>'
            '<thead><tr><th scope="col">Issue</th><th scope="col">Kind</th><th scope="col">CLI · model</th>'
            '<th scope="col" class="num">Age</th><th scope="col">Activity</th></tr></thead>'
            f'<tbody>{"".join(rows)}</tbody></table></div>')


def rate_line(rate, now):
    """The shared GitHub budget, one line per token: each resource's remaining/limit, and any hold."""
    if not rate:
        return '<p class="fleet__rate muted">GitHub budget unknown (no rate-limit probe on this host yet)</p>'
    out = []
    for r in rate:
        res = " · ".join(f'{esc(k)} <span class="num">{"?" if v["remaining"] is None else v["remaining"]}'
                         f'/{"?" if v["limit"] is None else v["limit"]}</span>'
                         for k, v in r["resources"].items()) or '<span class="muted">no data</span>'
        hold = (f' <span class="level level--amber">held until {_rel(r["hold_until"], now)}</span>'
                if r["hold_until"] else "")
        checked = f' <span class="muted">checked {_rel(r["checked_at"], now)}</span>' if r["checked_at"] else ""
        out.append(f'<p class="fleet__rate">GitHub <span class="mono">{esc(r["key"])}</span>: {res}{hold}{checked}</p>')
    return "".join(out)


def _actions(sup):
    acts = sup["actions"]
    if not acts:
        return '<p class="muted">No recent supervisor actions.</p>'
    items = []
    for line in reversed(acts):                       # newest first
        parts = line.split(" ", 2)
        when, text = (parts[1][:5], parts[2]) if len(parts) == 3 else ("", line)
        items.append(f'<li><span class="muted num">{esc(when)}</span> <span class="mono">{esc(_short(text, 140))}</span></li>')
    return f'<ol class="fleet__actions">{"".join(items)}</ol>'


def health(f, rate, now):
    """The card's health block: the verdict first, then what needs a human, sessions, budget, actions."""
    att = f.get("attention") or []
    if att:
        verdict = f'<p class="fleet__verdict level level--amber">needs attention ({len(att)})</p>'
        items = "".join(f'<li data-attention="{esc(a["kind"])}">{_attention_item(a)}</li>' for a in att)
        verdict += f'<ul class="fleet__attention">{items}</ul>'
    else:
        verdict = '<p class="fleet__verdict level level--grey">healthy</p>'
    if f["state"] == "missing":
        return verdict
    return (f'{verdict}\n{_sessions_table(f.get("sessions") or [], now)}\n{rate_line(rate, now)}\n'
            f'<div class="fleet__log"><h3 class="fleet__subhead">Recent supervisor actions</h3>'
            f'{_actions(f.get("supervisor") or {"actions": []})}</div>')


def fleet_card(f, now, rate=()):
    cls, label = STATES.get(f["state"], ("level--grey", f["state"]))
    pfx = esc(f["prefix"])
    repos = "".join(f'<li><span class="mono">{esc(r["slug"])}</span> — {_tally_text(r["tally"])}</li>'
                    for r in f["repos"]) or '<li class="muted">no repos registered</li>'
    if f["state"] == "missing":
        detail = (f'<p class="muted">Project dir is gone (stale registry entry — '
                  f'<code>harness doctor --fix</code> prunes it).</p>')
    else:
        pool = "?" if f["pool"] is None else f["pool"]
        detail = (f'<p class="fleet__meta"><span>workers <span class="num">{f["workers"]}/{pool}</span></span>'
                  f'{asof_stamp(f["asof"], now)}</p>')
    hl = "attention" if f.get("attention") else "healthy"
    return f"""<article class="panel fleet" data-fleet="{pfx}" data-state="{esc(f["state"])}" data-health="{hl}">
<header class="panel__header">
<h2 class="panel__title"><a href="/fleet/{pfx}">{pfx}</a></h2>
<span class="level {cls}">{esc(label)}</span>
<span class="panel__meta mono">{esc(f["root"])}</span>
</header>
<div class="panel__body stack stack--sm">
{health(f, rate, now)}
{detail}
<ul class="fleet__repos">{repos}</ul>
</div>
</article>"""


def overview(view, now):
    """The host overview: every registered fleet, its state, and a link to its page."""
    fleets = view["fleets"]
    rate = view.get("rate") or []
    if fleets:
        cards = "\n".join(fleet_card(f, now, rate) for f in fleets)
    else:
        cards = ('<div class="panel empty"><div><p class="empty__title">No fleets registered on this host.</p>'
                 '<p class="empty__text"><code>harness start</code> in a project registers its fleet here.</p>'
                 '</div></div>')
    n = len(fleets)
    host = "".join(
        f'<div class="callout callout--amber" data-attention="rate-hold"><div class="callout__body">'
        f'<p class="callout__title">GitHub token <span class="mono">{esc(a["what"])}</span> is held on a rate limit '
        f'until {_rel(a["until"], now)}</p><p>No fleet on this host calls <code>gh</code> with it until then; '
        f'claims wait.</p></div></div>'
        for a in view.get("attention") or ())
    host = f'<section data-region="host-attention" class="stack stack--sm">{host}</section>\n' if host else ""
    body = f"""<div class="page-header">
<div class="page-header__main">
<h1 class="page-header__title">Fleets on this host</h1>
<p class="page-header__meta"><span>{n} fleet{"" if n == 1 else "s"}</span>{asof_stamp(view["asof"], now)}</p>
</div>
</div>
{host}<section data-region="fleets" class="fleets">
{cards}
</section>"""
    return page("Fleets", body, view["asof"], now)


# DAG node state → its label. Colour comes from app.css (`.dag [data-state=…]`, the --s-* tokens).
NODE_LABEL = {
    "done": "closed", "waiting": "waiting on a PRD", "running": "in flight", "ready": "claimable",
    "closed": "closed", "agent-blocked": "agent-blocked", "in-progress": "in progress",
    "in-review": "in review", "blocked": "blocked", "open": "open",
}
CW, RH, BW, BH = 250, 96, 186, 54   # status-page.py's geometry: column, row, box width, box height


def _short(s, n):
    return s if len(s) <= n else s[:n - 1] + "…"


def dag_svg(nodes, edges, label, prd=False):
    """A layered DAG as inline SVG, laid out as status-page.py lays it out: one column per layer,
    nodes in number order down a column, centred. Each node is a focusable `<a href="?issue=N">`.
    <prd> marks PRD nodes (data-prd, and the "[AFK] PRD:" title prefix trimmed)."""
    if not nodes:
        return ""
    by = {n["number"]: n for n in nodes}
    cols = {}
    for n in sorted(by):
        cols.setdefault(by[n]["layer"], []).append(n)
    W = max(CW * (max(cols) + 1) + 60, 420)
    H = max(RH * max(len(v) for v in cols.values()) + 50, 160)
    pos = {}
    for c, ns in cols.items():
        off = (H - len(ns) * RH) / 2
        for i, n in enumerate(ns):
            pos[n] = (40 + c * CW, off + i * RH + 12)
    out = [f'<svg class="dag__svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="group" '
           f'aria-label="{esc(label)}">']
    for a, b in edges:
        if a not in pos or b not in pos:
            continue
        (x1, y1), (x2, y2) = pos[a], pos[b]
        sx, sy, ex, ey = x1 + BW, y1 + BH / 2, x2, y2 + BH / 2
        mx = (sx + ex) / 2
        out.append(f'<path class="dag__edge" d="M{sx:g} {sy:g} C{mx:g} {sy:g} {mx:g} {ey:g} {ex:g} {ey:g}" '
                   f'data-edge="{a}-{b}"/><circle class="dag__tip" cx="{ex:g}" cy="{ey:g}" r="2.5"/>')
    for n, (x, y) in sorted(pos.items()):
        node = by[n]
        title = node["title"].replace("[AFK] PRD:", "").strip() if prd else node["title"]
        head, _, rest = title.partition("—")
        # the mono line holds ~21 characters inside the box, "#N " included
        head, rest = _short(head.strip(), max(21 - len(f"#{n} "), 8)), _short(rest.strip(), 26)
        st = node["state"]
        extra = f' data-prd="{n}" data-layer="{node["layer"]}"' if prd else f' data-layer="{node["layer"]}"'
        sub = rest or NODE_LABEL.get(st, st)
        out.append(
            f'<a href="?issue={n}" data-issue="{n}"{extra} data-state="{esc(st)}" tabindex="0" '
            f'aria-label="#{n} {esc(title)} — {esc(NODE_LABEL.get(st, st))}">'
            f'<rect class="dag__box" x="{x:g}" y="{y:g}" width="{BW}" height="{BH}" rx="4"/>'
            f'<rect class="dag__bar" x="{x:g}" y="{y:g}" width="3.5" height="{BH}" rx="1.75"/>'
            f'<text class="dag__num" x="{x + 14:g}" y="{y + 21:g}">#{n} {esc(head)}</text>'
            f'<text class="dag__sub" x="{x + 14:g}" y="{y + 38:g}">{esc(sub)}</text></a>')
    out.append("</svg>")
    return "".join(out)


def _pill(state):
    return f'<span class="dag-pill" data-state="{esc(state)}">{esc(NODE_LABEL.get(state, state))}</span>'


def unit_section(u, now):
    """One repo: its PRD DAG, each PRD's children as their own DAG, then the unparented issues."""
    slug = esc(u["slug"])
    if u.get("missing"):
        dag = ('<p class="muted">No board snapshot for this repo yet — the poller writes one on its next '
               'refresh.</p>')
    elif not u["prds"]:
        dag = '<p class="muted">No PRDs on this board.</p>'
    else:
        prds = u["prds"]
        prd_edges = [e for e in u["edges"] if e[1] in {p["number"] for p in prds}]
        parts = [f'<div class="dag">{dag_svg(prds, prd_edges, "PRD dependency graph for " + u["slug"], prd=True)}</div>']
        for p in prds:
            kids = p["children"]
            k = p["kids"]
            head = (f'<h3 class="prd__title"><a href="?issue={p["number"]}">#{p["number"]}</a> '
                    f'{esc(p["title"].replace("[AFK] PRD:", "").strip())} {_pill(p["state"])} '
                    f'<span class="muted num">{k["closed"]}/{k["closed"] + k["open"]} children closed</span></h3>')
            if kids:
                sib = {c["number"] for c in kids}
                body = (f'<div class="dag">{dag_svg(kids, [e for e in u["edges"] if e[1] in sib], f"Children of #{p['number']}")}'
                        f'</div>')
            else:
                body = '<p class="muted">No children yet.</p>'
            parts.append(f'<div class="prd stack stack--sm" data-prd-children="{p["number"]}">{head}{body}</div>')
        dag = "\n".join(parts)
    loose = u["unparented"]
    if loose:
        items = "".join(f'<li><a href="?issue={i["number"]}" data-issue="{i["number"]}" data-state="{esc(i["state"])}">'
                        f'<span class="mono">#{i["number"]}</span> {esc(i["title"])}</a> {_pill(i["state"])}</li>'
                        for i in loose)
        loose_html = f'<ul class="unparented">{items}</ul>'
    else:
        loose_html = '<p class="muted">None.</p>'
    return f"""<section data-region="dag-{slug}" class="panel unit" aria-labelledby="unit-{slug}">
<header class="panel__header">
<h2 class="panel__title" id="unit-{slug}"><span class="mono">{slug}</span></h2>
{asof_stamp(u["asof"], now)}
</header>
<div class="panel__body stack">
{dag}
</div>
</section>
<section data-region="unparented-{slug}" class="panel unit">
<header class="panel__header"><h2 class="panel__title">Unparented issues <span class="mono muted">{slug}</span></h2></header>
<div class="panel__body">
{loose_html}
</div>
</section>"""


def fleet(view, now):
    """/fleet/<prefix>: per unit (repo), the PRD → issue map as a layered DAG + the unparented list."""
    cls, label = STATES.get(view["state"], ("level--grey", view["state"]))
    units = "\n".join(unit_section(u, now) for u in view["units"]) or \
        '<p class="muted">This fleet serves no repos.</p>'
    legend = "".join(f"<li>{_pill(s)}</li>" for s in ("closed", "agent-blocked", "in-progress", "in-review",
                                                      "blocked", "open"))
    body = f"""<div class="page-header">
<div class="page-header__main">
<h1 class="page-header__title">Fleet {esc(view["prefix"])} <span class="level {cls}">{esc(label)}</span></h1>
<p class="page-header__meta"><span class="mono">{esc(view["root"])}</span>{asof_stamp(view["asof"], now)}</p>
</div>
</div>
<ul class="dag-legend" aria-label="Issue states">{legend}</ul>
{units}"""
    return page(f"Fleet {view['prefix']}", body, view["asof"], now, crumbs=[(f"Fleet {view['prefix']}", None)])
