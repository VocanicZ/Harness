#!/usr/bin/env python3
"""web_render.py — the one place `harness web` produces HTML (#223).

Every view is rendered here from the plain dicts web_data.py builds; nothing else, including app.js,
renders the same data a second time. Each live part of a page is a `<section data-region="…">`, the
unit an SSE push (#227) replaces whole: regions(path, view, now) is every region of one page, the page
itself is built from that same dict, and version() names it. No inline style or script: the server's
CSP refuses both.
"""
import hashlib
import html
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fleetview  # noqa: E402
import stats      # noqa: E402
import session_backend  # noqa: E402

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


def asof_stamp(asof, now, page=False):
    """`data as of <time>` — the board's own clock (a dead poller reads stale), never the server's.
    <page> marks the page-level stamp (`<time data-asof>`), the one a push advances."""
    if asof is None:
        return '<span class="asof">data as of <span class="asof__unknown">unknown (no board snapshot)</span></span>'
    mark = " data-asof" if page else ""
    return (f'<span class="asof">data as of <time{mark} datetime="{iso(asof)}" title="{iso(asof)}">'
            f'{fleetview.fmt_age(now - asof)} ago</time></span>')


def version(regions):
    """A short hash naming one rendering of a page's regions: the SSE event id (#227)."""
    return hashlib.sha1(json.dumps(regions, sort_keys=True).encode("utf-8")).hexdigest()[:16]


def page(title, body, asof, now, crumbs=(), view=None, ver=None):
    """A whole document: the copied design tokens, the top bar with breadcrumbs, the live-update
    status and the theme toggle, then <body>. <crumbs> is [(label, href)] after "Harness"; the last
    one is the current page. <view> (the page's path) and <ver> (its regions' version) tell app.js
    which SSE stream to open and what it already holds."""
    trail = [("Harness", "/")] + list(crumbs)
    items = []
    for i, (label, href) in enumerate(trail):
        if i == len(trail) - 1:
            items.append(f'<li><span aria-current="page">{esc(label)}</span></li>')
        else:
            items.append(f'<li><a href="{esc(href)}">{esc(label)}</a></li>')
    live = f' data-view="{esc(view)}" data-version="{esc(ver)}"' if view is not None else ""
    return f"""<!doctype html>
<html lang="en"{live}>
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
<span class="live" data-live="idle" role="status"><span class="live__reconnecting">reconnecting…</span><span class="live__offline">live updates off — retrying</span></span>
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


def _until(ts, now):
    """`08:30 (in 30m)`: a hold's end as the host's clock reads it, then how far off (#231 — "until in
    30m" read as a typo)."""
    return (f'<time datetime="{iso(ts)}" title="{iso(ts)}">{time.strftime("%H:%M", time.localtime(ts))}</time> '
            f'<span class="muted">({"in " + fleetview.fmt_age(ts - now) if ts > now else "past"})</span>')


def _session_issue(s, prefix, many):
    """The session's issue, linked into the fleet page's drawer (#228) when it names one. <many>: the
    fleet serves several repos, so the link names the session's own repo (when its launch said)."""
    n = fleetview.session_number(s["name"])
    if n is None or prefix is None:
        return f'<span class="table__primary">{esc(s["issue"])}</span>'
    repo = f'&repo={esc(s["repo"])}' if many and s.get("repo") else ""
    return f'<a class="table__primary" href="/fleet/{esc(prefix)}?issue={n}{repo}">{esc(s["issue"])}</a>'


def _sessions_table(sessions, now, prefix=None, many=False):
    if not sessions:
        return '<p class="muted">No live sessions.</p>'
    rows = []
    for s in sessions:
        act = s["activity"]
        act_html = (f'<span class="level {ACTIVITY.get(act, "level--grey")}">{esc(act)}</span>' if act
                    else '<span class="muted">unknown</span>')
        age = "?" if s["age_s"] is None else fleetview.fmt_age(s["age_s"])
        model = s["model"] or "?"
        # the kind beside the issue and the model's short name: four columns fit a 400 px card (#231)
        rows.append(f'<tr data-session="{esc(s["name"])}" data-activity="{esc(act or "unknown")}">'
                    f'<td>{_session_issue(s, prefix, many)} <span class="muted">{esc(s["kind"])}</span>'
                    f'<span class="table__secondary mono">{esc(s["name"])}</span></td>'
                    f'<td>{esc(s["cli"])}<span class="table__secondary mono" title="{esc(model)}">'
                    f'{esc(model.replace("claude-", ""))}</span></td>'
                    f'<td class="num">{age}</td><td>{act_html}</td></tr>')
    return ('<div class="table-wrap"><table class="table fleet__sessions"><caption class="sr-only">Live sessions</caption>'
            '<thead><tr><th scope="col">Issue · kind</th><th scope="col">CLI · model</th>'
            '<th scope="col" class="num">Age</th><th scope="col">Activity</th></tr></thead>'
            f'<tbody>{"".join(rows)}</tbody></table></div>')


def rate_line(rate, now):
    """The shared GitHub budget, one item per token: each resource's remaining/limit and when it was
    checked. Host-wide — every fleet spends the same token — so it is said once, in the page header
    (#231); a hold is the host callout's."""
    if not rate:
        return '<span class="fleet__rate">GitHub budget unknown (no rate-limit probe on this host yet)</span>'
    out = []
    for r in rate:
        res = " · ".join(f'{esc(k)} <span class="num">{"?" if v["remaining"] is None else v["remaining"]}'
                         f'/{"?" if v["limit"] is None else v["limit"]}</span>'
                         for k, v in r["resources"].items()) or "no data"
        checked = f' (checked {_rel(r["checked_at"], now)})' if r["checked_at"] else ""
        out.append(f'<span class="fleet__rate">GitHub <span class="mono">{esc(r["key"])}</span>: {res}{checked}</span>')
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


def health(f, now):
    """The card's health block: the verdict first, then what needs a human, sessions, budget, actions."""
    att = f.get("attention") or []
    if att:
        verdict = f'<p class="fleet__verdict level level--amber">needs attention ({len(att)})</p>'
        items = "".join(f'<li data-attention="{esc(a["kind"])}">{_attention_item(a)}</li>' for a in att)
        verdict += f'<ul class="fleet__attention">{items}</ul>'
    else:
        verdict = '<p class="fleet__verdict level level--grey">healthy</p>'
    aw = f.get("awaiting") or 0
    if aw:      # the fleet page's "Awaiting you", one click away: `/` answers "what needs me?" (#231)
        verdict += (f'<p class="fleet__awaiting"><a href="/fleet/{esc(f["prefix"])}#awaiting-title" '
                    f'data-awaiting-count="{aw}"><span class="num">{aw}</span> awaiting you</a></p>')
    if f["state"] == "missing":
        return verdict
    return (f'{verdict}\n{_sessions_table(f.get("sessions") or [], now, f["prefix"], len(f.get("repos") or ()) > 1)}\n'
            f'<div class="fleet__log"><h3 class="fleet__subhead">Recent supervisor actions</h3>'
            f'{_actions(f.get("supervisor") or {"actions": []})}</div>')


def fleet_card(f, now):
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
<p class="fleet__root mono" title="{esc(f["root"])}">{esc(f["root"])}</p>
</header>
<div class="panel__body stack stack--sm">
{health(f, now)}
{detail}
<ul class="fleet__repos">{repos}</ul>
</div>
</article>"""


def overview_regions(view, now):
    """The host overview's regions: the header (fleet count, as-of), host-wide attention, the fleets."""
    fleets = view["fleets"]
    rate = view.get("rate") or []
    if fleets:
        cards = "\n".join(fleet_card(f, now) for f in fleets)
    else:
        cards = ('<div class="panel empty"><div><p class="empty__title">No fleets registered on this host.</p>'
                 '<p class="empty__text"><code>harness start</code> in a project registers its fleet here.</p>'
                 '</div></div>')
    n = len(fleets)
    host = "".join(
        f'<div class="callout callout--amber" data-attention="rate-hold"><div class="callout__body">'
        f'<p class="callout__title">GitHub token <span class="mono">{esc(a["what"])}</span> hit its rate limit: held until '
        f'{_until(a["until"], now)}</p><p>No fleet on this host calls <code>gh</code> with it until then; '
        f'claims wait.</p></div></div>'
        for a in view.get("attention") or ())
    hidden = "" if host else " hidden"
    return {
        "header": f"""<section data-region="header" class="page-header">
<div class="page-header__main">
<h1 class="page-header__title">Fleets on this host</h1>
<p class="page-header__meta"><span>{n} fleet{"" if n == 1 else "s"}</span>{asof_stamp(view["asof"], now, page=True)}{rate_line(rate, now)}</p>
</div>
</section>""",
        "host-attention": f'<section data-region="host-attention" class="stack stack--sm"{hidden}>{host}</section>',
        "fleets": f"""<section data-region="fleets" class="fleets">
{cards}
</section>""",
    }


def overview(view, now):
    """The host overview: every registered fleet, its state, and a link to its page."""
    regs = overview_regions(view, now)
    return page("Fleets", "\n".join(regs.values()), view["asof"], now, view="/", ver=version(regs))


# DAG node state → its label. Colour comes from app.css (`.dag [data-state=…]`, the --s-* tokens).
NODE_LABEL = {
    "done": "closed", "waiting": "waiting on a PRD", "running": "in flight", "ready": "claimable",
    "closed": "closed", "agent-blocked": "agent-blocked", "in-progress": "in progress",
    "in-review": "in review", "blocked": "blocked", "open": "open",
}
CW, RH, BW, BH = 236, 66, 186, 50   # column, row, box width, box height (#231: tighter than status-page.py's)
PAD = 6                             # the margin round the boxes, room for the focus ring
STAT_H = 16                         # the stats overlay's third line (#229)


def _short(s, n):
    return s if len(s) <= n else s[:n - 1] + "…"


def _compact(n):
    """8700 → 8.7k, 2400000 → 2.4M: a token count that fits a DAG box."""
    for div, unit in ((1_000_000, "M"), (1_000, "k")):
        if n >= div:
            return f"{n / div:.1f}".rstrip("0").rstrip(".") + unit
    return str(n)


def _stat_parts(st, short):
    """The overlay's words, tokens · model · retries (#229), each only when the log has it. <short>:
    the DAG box's compact form."""
    parts = []
    if "tokens" in st:
        parts.append(f'{_compact(st["tokens"])} out' if short else f'{st["tokens"]:,} output tokens')
    if st.get("model"):
        parts.append(st["model"].replace("claude-", "") if short else st["model"])
    r = st["retries"]
    parts.append(f'{r} {"retry" if r == 1 else "retries"}')
    return parts


def _stat_attrs(st):
    return (f' data-tokens="{st["tokens"]}"' if "tokens" in st else "") + f' data-retries="{st["retries"]}"'


def prd_stats_line(st):
    """A PRD header's rollup (stats.prd_rollup's total), or nothing at all without data."""
    if not st:
        return ""
    n = st["sessions"]
    words = " · ".join(esc(w) for w in _stat_parts(st, False) + [f'{n} session{"" if n == 1 else "s"}'])
    return f'<span class="prd__stats muted"{_stat_attrs(st)}>{words}</span>'


def dag_svg(nodes, edges, label, prd=False):
    """A layered DAG as inline SVG, laid out as status-page.py lays it out: one column per layer,
    nodes in number order down a column, centred. Each node is a focusable `<a href="?issue=N">`.
    <prd> marks PRD nodes (data-prd, and the "[AFK] PRD:" title prefix trimmed). A node with `stats`
    (#229) gets a third line, and every box in that DAG grows to hold it."""
    if not nodes:
        return ""
    by = {n["number"]: n for n in nodes}
    grow = STAT_H if any(n.get("stats") for n in nodes) else 0
    bh, rh = BH + grow, RH + grow
    cols = {}
    for n in sorted(by):
        cols.setdefault(by[n]["layer"], []).append(n)
    gap = rh - bh
    W = CW * max(cols) + BW + 2 * PAD
    H = rh * max(len(v) for v in cols.values()) - gap + 2 * PAD
    pos = {}
    for c, ns in cols.items():
        off = (H - len(ns) * rh + gap) / 2
        for i, n in enumerate(ns):
            pos[n] = (PAD + c * CW, off + i * rh)
    out = [f'<svg class="dag__svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="group" '
           f'aria-label="{esc(label)}">']
    for a, b in edges:
        if a not in pos or b not in pos:
            continue
        (x1, y1), (x2, y2) = pos[a], pos[b]
        sx, sy, ex, ey = x1 + BW, y1 + bh / 2, x2, y2 + bh / 2
        mx = (sx + ex) / 2
        out.append(f'<path class="dag__edge" d="M{sx:g} {sy:g} C{mx:g} {sy:g} {mx:g} {ey:g} {ex:g} {ey:g}" '
                   f'data-edge="{a}-{b}"/><circle class="dag__tip" cx="{ex:g}" cy="{ey:g}" r="2.5"/>')
    for n, (x, y) in sorted(pos.items()):
        node = by[n]
        title = node["title"].replace("[AFK] PRD:", "").strip() if prd else node["title"]
        head, _, rest = title.partition("—")
        # the title line holds ~24 characters inside the box, "#N " included
        head, rest = _short(head.strip(), max(24 - len(f"#{n} "), 8)), _short(rest.strip(), 25)
        st = node["state"]
        extra = f' data-prd="{n}" data-layer="{node["layer"]}"' if prd else f' data-layer="{node["layer"]}"'
        sub = rest or NODE_LABEL.get(st, st)
        stat = ""
        if node.get("stats"):
            stat = (f'<text class="dag__stat" x="{x + 14:g}" y="{y + 50:g}"{_stat_attrs(node["stats"])}>'
                    f'{esc(_short(" · ".join(_stat_parts(node["stats"], True)), 32))}</text>')
        out.append(
            f'<a href="?issue={n}" data-issue="{n}"{extra} data-state="{esc(st)}" tabindex="0" '
            f'aria-label="#{n} {esc(title)} — {esc(NODE_LABEL.get(st, st))}">'
            f'<rect class="dag__box" x="{x:g}" y="{y:g}" width="{BW}" height="{bh}" rx="6"/>'
            f'<rect class="dag__bar" x="{x + 0.75:g}" y="{y + 0.75:g}" width="4" height="{bh - 1.5:g}" rx="2"/>'
            f'<text class="dag__num" x="{x + 14:g}" y="{y + 20:g}"><tspan class="dag__id">#{n}</tspan> {esc(head)}</text>'
            f'<text class="dag__sub" x="{x + 14:g}" y="{y + 36:g}">{esc(sub)}</text>{stat}</a>')
    out.append("</svg>")
    return "".join(out)


def _pill(state):
    return f'<span class="dag-pill" data-state="{esc(state)}">{esc(NODE_LABEL.get(state, state))}</span>'


def unit_regions(u, now):
    """One repo's two regions: its PRD DAG with each PRD's children as their own DAG, then the
    unparented issues."""
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
                    f'<span class="muted num">{k["closed"]}/{k["closed"] + k["open"]} children closed</span>'
                    f'{prd_stats_line(p.get("stats"))}</h3>')
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
    return {f"dag-{u['slug']}": f"""<section data-region="dag-{slug}" class="panel unit" aria-labelledby="unit-{slug}">
<header class="panel__header">
<h2 class="panel__title" id="unit-{slug}"><span class="mono">{slug}</span></h2>
<span class="panel__meta">{asof_stamp(u["asof"], now)}</span>
</header>
<div class="panel__body stack">
{dag}
</div>
</section>""", f"unparented-{u['slug']}": f"""<section data-region="unparented-{slug}" class="panel unit">
<header class="panel__header"><h2 class="panel__title">Unparented issues <span class="mono muted">{slug}</span></h2></header>
<div class="panel__body">
{loose_html}
</div>
</section>"""}


AWAITING_TAG = {"wayfinder": "decision", "agent-blocked": "agent question", "operator": "operator task"}


def _awaiting_item(slug, a, many):
    """One item. Its link opens the drawer but carries no data-issue — that names the issue's DAG node,
    which the page (and app.js) find by it; the drawer finds this opener by its li's data-awaiting."""
    repo = f' <span class="mono muted">{esc(slug)}</span>' if many else ""
    needs = (' <span class="awaiting__needs muted">needs first ' +
             ", ".join(f'<span class="mono">#{d}</span>' for d in a["needs"]) + "</span>") if a["needs"] else ""
    return (f'<li class="awaiting__item" data-awaiting="{a["number"]}" data-kind="{esc(a["kind"])}" '
            f'data-resolved="{"true" if a["resolved"] else "false"}">'
            f'<span class="awaiting__kind">{esc(AWAITING_TAG.get(a["kind"], a["kind"]))}</span> '
            f'<a href="?issue={a["number"]}&amp;repo={esc(slug)}">'
            f'<span class="mono">#{a["number"]}</span> {esc(a["title"])}</a>{repo}{needs}</li>')


def awaiting_region(units):
    """"Awaiting you" (#229): the human-only work across the fleet's repos — open items first, the
    resolved wayfinder tickets collapsed at the end. status-page.py's wayfinder section, plus
    agent-blocked questions and operator issues."""
    many = len(units) > 1
    items = [(u["slug"], a) for u in units for a in u.get("awaiting") or ()]
    todo = [_awaiting_item(slug, a, many) for slug, a in items if not a["resolved"]]
    done = [_awaiting_item(slug, a, many) for slug, a in items if a["resolved"]]
    body = f'<ul class="awaiting">{"".join(todo)}</ul>' if todo else '<p class="muted">Nothing needs you right now.</p>'
    if done:
        body += (f'<details class="awaiting__resolved"><summary>{len(done)} resolved</summary>'
                 f'<ul class="awaiting">{"".join(done)}</ul></details>')
    count = f' <span class="level level--amber num">{len(todo)}</span>' if todo else ""
    return f"""<section data-region="awaiting" class="panel" aria-labelledby="awaiting-title">
<header class="panel__header"><h2 class="panel__title" id="awaiting-title">Awaiting you{count}</h2></header>
<div class="panel__body stack stack--sm">
{body}
</div>
</section>"""


def fleet_regions(view, now):
    """/fleet/<prefix>'s regions: the header (state, as-of), "Awaiting you" (#229) — answer first: the
    work only a human can do leads the page — then each unit's DAG and unparented list."""
    cls, label = STATES.get(view["state"], ("level--grey", view["state"]))
    regs = {"header": f"""<section data-region="header" class="page-header">
<div class="page-header__main">
<h1 class="page-header__title">Fleet {esc(view["prefix"])} <span class="level {cls}">{esc(label)}</span></h1>
<p class="page-header__meta"><span class="mono">{esc(view["root"])}</span>{asof_stamp(view["asof"], now, page=True)}</p>
</div>
</section>""", "awaiting": awaiting_region(view["units"])}
    for u in view["units"]:
        regs.update(unit_regions(u, now))
    return regs


def regions(path, view, now):
    """Every region of the page at <path> ("/" or "/fleet/<prefix>"), in page order."""
    return overview_regions(view, now) if path == "/" else fleet_regions(view, now)


def fleet(view, now, issue=None):
    """/fleet/<prefix>: per unit (repo), the PRD → issue map as a layered DAG + the unparented list.
    <issue> (an issue_view) opens its drawer on first paint — outside every region, so no push closes it."""
    regs = fleet_regions(view, now)
    header, awaiting = regs.pop("header"), regs.pop("awaiting")
    units = "\n".join(regs.values())
    legend = "".join(f'<li data-state="{s}"><span class="dag-legend__swatch"></span>{esc(NODE_LABEL[s])}</li>'
                     for s in ("closed", "in-progress", "in-review", "blocked", "agent-blocked", "open"))
    body = f"""{header}
{awaiting}
<ul class="dag-legend" aria-label="Issue states">{legend}</ul>
{units or '<p class="muted">This fleet serves no repos.</p>'}
<div data-drawer-host>{drawer(issue, now) if issue else ""}</div>"""
    return page(f"Fleet {view['prefix']}", body, view["asof"], now, crumbs=[(f"Fleet {view['prefix']}", None)],
                view=f"/fleet/{view['prefix']}", ver=version(dict(regs, header=header, awaiting=awaiting)))


# --- the issue drawer (#228) ---------------------------------------------------------------------
CI = {"success": "level--green", "failure": "level--red", "pending": "level--amber", "none": "level--grey"}


def _event_detail(e):
    """The few facts worth a glance on one timeline line: model, why, how long, how much output."""
    bits = []
    if e.get("model"):
        bits.append(esc(e["model"]))
    if e.get("reason"):
        bits.append(esc(e["reason"]))
    if isinstance(e.get("wall_s"), int):
        bits.append(f'{fleetview.fmt_age(e["wall_s"])} wall')
    out = sum(u.get("output") or 0 for u in (e.get("usage") or {}).values() if isinstance(u, dict))
    if out:
        bits.append(f'<span class="num">{out:,}</span> output tokens')
    return " · ".join(bits)


def _timeline(events, now):
    if not events:
        return '<p class="muted" data-timeline="empty">No events recorded for this issue.</p>'
    items = []
    for e in events:
        ts = stats.parse_ts(e.get("ts"))
        when = _rel(int(ts), now) if ts is not None else '<span class="muted">?</span>'
        detail = _event_detail(e)
        detail = f' <span class="muted">{detail}</span>' if detail else ""
        items.append(f'<li data-event="{esc(e.get("event"))}"><span class="drawer__when">{when}</span> '
                     f'<span class="mono">{esc(e.get("event"))}</span>{detail}</li>')
    return f'<ol class="drawer__timeline">{"".join(items)}</ol>'


def _kv(*rows):
    """A field's key/value rows: the key a fixed quiet column, so the values line up (#231)."""
    return '<div class="drawer__kv">' + "".join(f'<span class="drawer__key">{k}</span><span>{v}</span>'
                                                for k, v in rows) + "</div>"


def _field(name, label, body):
    return f'<div class="drawer__field" data-field="{name}"><dt>{label}</dt><dd>{body}</dd></div>'


def drawer(v, now):
    """The issue drawer: a dialog with the fields in #228's order — title, labels, `## Blocked by` /
    `## Parent`, the linked PR and its CI state, the live session and its timeline — and the issue on
    GitHub last. PR and CI that the poller has not cached read "unknown"; nothing is fetched for them."""
    n, slug = v["number"], v["slug"]
    labels = "".join(f'<li class="drawer__label mono" data-label="{esc(l)}">{esc(l)}</li>' for l in v["labels"])
    labels = f'<ul class="drawer__labels">{labels}</ul>' if labels else '<span class="muted">none</span>'
    deps = "".join(f'<li data-blocked-by="{d["number"]}" data-state="{esc(d["state"])}">'
                   f'<a href="?issue={d["number"]}&amp;repo={esc(slug)}" data-issue="{d["number"]}">#{d["number"]}</a> '
                   f'{_pill(d["state"])}</li>' for d in v["blocked_by"])
    deps = f'<ul class="drawer__deps">{deps}</ul>' if deps else '<span class="muted">nothing</span>'
    parent = (f'<a href="?issue={v["parent"]}&amp;repo={esc(slug)}" data-parent="{v["parent"]}" '
              f'data-issue="{v["parent"]}">#{v["parent"]}</a>' if v["parent"] is not None
              else '<span class="muted" data-parent="none">none</span>')
    pr = v["pr"]
    if pr:
        draft = ' <span class="level level--grey">draft</span>' if pr.get("draft") else ""
        pr_html = (f'<a href="{esc(pr.get("url"))}" data-pr="{esc(pr.get("number"))}">PR #{esc(pr.get("number"))}</a>'
                   f'{draft} <span class="mono muted">{esc(pr.get("head_ref"))}</span>')
    elif v["pr_cached"]:
        pr_html = '<span class="muted" data-pr="none">no open PR</span>'
    else:
        pr_html = '<span class="muted" data-pr="unknown">unknown (not cached by the poller yet)</span>'
    ci = v["ci"]
    ci_html = (f'<span class="level {CI.get(ci, "level--grey")}" data-ci="{esc(ci)}">{esc(ci)}</span>' if ci
               else '<span class="muted" data-ci="unknown">unknown</span>')
    s = v["session"]
    if s:
        act = s.get("activity")
        act_html = (f' <span class="level {ACTIVITY.get(act, "level--grey")}">{esc(act)}</span>' if act else "")
        age = "" if s.get("age_s") is None else f' <span class="muted">up {fleetview.fmt_age(s["age_s"])}</span>'
        sess = (f'<p data-session="{esc(s["name"])}"><span class="mono">{esc(s["name"])}</span>{act_html}{age}'
                f'<span class="table__secondary">{esc(s.get("cli"))} · <span class="mono">{esc(s.get("model") or "?")}</span>'
                f' — <code>{esc(session_backend.attach_hint(s["name"]))}</code></span></p>')
    else:
        sess = '<p class="muted" data-session="none">No live session.</p>'
    return f"""<aside class="drawer" role="dialog" aria-modal="true" aria-labelledby="drawer-title" data-issue="{n}" data-repo="{esc(slug)}" tabindex="-1">
<header class="drawer__header">
<h2 class="drawer__title" id="drawer-title"><span class="drawer__num">#{n}</span> {esc(v["title"])}</h2>
<button type="button" class="btn btn--ghost btn--sm" data-drawer-close aria-label="Close issue #{n}">Close</button>
</header>
<p class="drawer__meta"><span class="mono muted">{esc(slug)}</span> {_pill(v["state"])}{asof_stamp(v["asof"], now)}</p>
<dl class="drawer__fields">
{_field("labels", "Labels", labels)}
{_field("deps", "Dependencies", _kv(("Blocked by", deps), ("Parent", parent)))}
{_field("pr", "Pull request", _kv(("PR", pr_html), ("CI", ci_html)))}
{_field("session", "Session", sess + _timeline(v["timeline"], now))}
{_field("github", "On GitHub", f'<a href="{esc(v["url"])}">{esc(slug)}#{n}</a>')}
</dl>
</aside>"""
