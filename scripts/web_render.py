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
    return f"""<article class="panel fleet" data-fleet="{pfx}" data-state="{esc(f["state"])}">
<header class="panel__header">
<h2 class="panel__title"><a href="/fleet/{pfx}">{pfx}</a></h2>
<span class="level {cls}">{esc(label)}</span>
<span class="panel__meta mono">{esc(f["root"])}</span>
</header>
<div class="panel__body stack stack--sm">
{detail}
<ul class="fleet__repos">{repos}</ul>
</div>
</article>"""


def overview(view, now):
    """The host overview: every registered fleet, its state, and a link to its page."""
    fleets = view["fleets"]
    if fleets:
        cards = "\n".join(fleet_card(f, now) for f in fleets)
    else:
        cards = ('<div class="panel empty"><div><p class="empty__title">No fleets registered on this host.</p>'
                 '<p class="empty__text"><code>harness start</code> in a project registers its fleet here.</p>'
                 '</div></div>')
    n = len(fleets)
    body = f"""<div class="page-header">
<div class="page-header__main">
<h1 class="page-header__title">Fleets on this host</h1>
<p class="page-header__meta"><span>{n} fleet{"" if n == 1 else "s"}</span>{asof_stamp(view["asof"], now)}</p>
</div>
</div>
<section data-region="fleets" class="fleets">
{cards}
</section>"""
    return page("Fleets", body, view["asof"], now)


def fleet_stub(f, now):
    """/fleet/<prefix> until the DAG page lands (#224): the fleet's overview card on its own."""
    body = f"""<div class="page-header">
<div class="page-header__main">
<h1 class="page-header__title">Fleet {esc(f["prefix"])}</h1>
<p class="page-header__meta"><span class="mono">{esc(f["root"])}</span>{asof_stamp(f["asof"], now)}</p>
</div>
</div>
<section data-region="fleet" class="fleets">
{fleet_card(f, now)}
</section>
<p class="muted">The PRD → issue map for this fleet is not on this page yet.</p>"""
    return page(f"Fleet {f['prefix']}", body, f["asof"], now, crumbs=[(f"Fleet {f['prefix']}", None)])
