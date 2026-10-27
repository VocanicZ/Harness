#!/usr/bin/env python3
"""Render an arc's live state as a self-contained HTML page for the Artifact tool.

    HARNESS_SLUG=owner/repo HARNESS_UNIT=<unit> python3 status-page.py [-o out.html]

Reads the PRD chain (label `prd`), its `## Blocked by` edges, per-PRD child counts,
the wayfinder map and its tickets, and local fleet state. Emits one HTML file.
Nothing is invented: every field is either read from GitHub or rendered as unknown.
"""
import json, os, re, subprocess, sys, html, pathlib, argparse

SLUG = os.environ.get("HARNESS_SLUG", "")
UNIT = os.environ.get("HARNESS_UNIT", "")


def gh(*args):
    try:
        out = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=90)
        return out.stdout if out.returncode == 0 else ""
    except Exception:
        return ""


def issues(label=None, state="all"):
    a = ["issue", "list", "--repo", SLUG, "--state", state, "--limit", "200",
         "--json", "number,title,body,state,labels,url"]
    if label:
        a += ["--label", label]
    try:
        return json.loads(gh(*a) or "[]")
    except json.JSONDecodeError:
        return []


def blocked_by(body):
    """Deps from the LAST `## Blocked by` header only — prose may mention it earlier."""
    if not body:
        return []
    parts = re.split(r"^## Blocked by\s*$", body, flags=re.M)
    if len(parts) < 2:
        return []
    tail = parts[-1]
    tail = re.split(r"^## ", tail, flags=re.M)[0]
    if re.search(r"\bNone\b", tail):
        return []
    return sorted({int(n) for n in re.findall(r"#(\d+)", tail)})


def parent_of(body):
    if not body:
        return None
    m = re.search(r"^## Parent\s*\n+\s*#(\d+)", body, flags=re.M)
    return int(m.group(1)) if m else None


def layers(nodes, deps):
    """Longest-path layering, so a fork renders as a fork."""
    lay, seen = {}, set()

    def depth(n):
        if n in lay:
            return lay[n]
        if n in seen:
            return 0          # cycle guard
        seen.add(n)
        d = 0 if not deps.get(n) else 1 + max(
            (depth(p) for p in deps[n] if p in nodes), default=-1)
        lay[n] = d
        return d

    for n in nodes:
        depth(n)
    return lay


def arc_model(prds, allis):
    """The arc's DAG as data: {"deps", "kids", "layers", "states"}, each keyed by PRD number, plus
    "tickets": [[number, resolved]] of the wayfinder tickets (the "Awaiting you" panel's).
    Children count by `## Parent` (PRDs and wayfinder issues are never children); a PRD is done
    (closed) / waiting (an open dep) / running (has children or is agent-working) / ready.
    `harness web`'s fleet page (scripts/web_dag.py) is golden-tested against this (#224)."""
    deps = {p["number"]: blocked_by(p["body"]) for p in prds}
    closed = {p["number"] for p in prds if p["state"] == "CLOSED"}

    kids = {p["number"]: {"open": 0, "closed": 0} for p in prds}
    for i in allis:
        names = [l["name"] for l in i["labels"]]
        if "prd" in names or any(n.startswith("wayfinder") for n in names):
            continue
        pa = parent_of(i["body"])
        if pa in kids:
            kids[pa]["closed" if i["state"] == "CLOSED" else "open"] += 1
    working = {i["number"] for i in allis
               if any(l["name"] == "agent-working" for l in i["labels"])}

    def state_of(n):
        if n in closed:
            return "done"
        if any(d not in closed for d in deps[n]):
            return "waiting"
        if kids[n]["open"] or kids[n]["closed"] or n in working:
            return "running"
        return "ready"

    return {"deps": deps, "kids": kids, "layers": layers(set(deps), deps),
            "states": {n: state_of(n) for n in deps},
            "tickets": sorted([t["number"], t["state"] == "CLOSED"] for t in wayfinder_tickets(allis))}


def wayfinder_tickets(allis):
    """Every `wayfinder:*` issue but the map, in number order."""
    return sorted([i for i in allis
                   if any(l["name"].startswith("wayfinder:") and l["name"] != "wayfinder:map"
                          for l in i["labels"])], key=lambda i: i["number"])


def dag_svg(prds, deps, state_of):
    """Layered DAG. Colours come from CSS vars so both themes resolve."""
    nums = [p["number"] for p in prds]
    lay = layers(set(nums), deps)
    cols = {}
    for n in sorted(nums):
        cols.setdefault(lay[n], []).append(n)
    CW, RH, BW, BH = 250, 96, 186, 54
    W = max(CW * (max(cols) + 1) + 60, 420)
    H = max(RH * max(len(v) for v in cols.values()) + 50, 160)
    pos = {}
    for c, ns in cols.items():
        off = (H - len(ns) * RH) / 2
        for i, n in enumerate(ns):
            pos[n] = (40 + c * CW, off + i * RH + 12)
    out = [f'<svg viewBox="0 0 {W} {H}" width="100%" role="img" '
           f'aria-label="PRD dependency graph"><title>PRD dependency graph</title>']
    for n, ps in deps.items():
        if n not in pos:
            continue
        x2, y2 = pos[n]
        for p in ps:
            if p not in pos:
                continue
            x1, y1 = pos[p]
            sx, sy, ex, ey = x1 + BW, y1 + BH / 2, x2, y2 + BH / 2
            mx = (sx + ex) / 2
            out.append(f'<path d="M{sx} {sy} C{mx} {sy} {mx} {ey} {ex} {ey}" '
                       f'fill="none" stroke="var(--line)" stroke-width="1.5"/>')
            out.append(f'<circle cx="{ex}" cy="{ey}" r="2.5" fill="var(--line)"/>')
    for n, (x, y) in pos.items():
        p = next(q for q in prds if q["number"] == n)
        st = state_of(p)
        t = p["title"].split("—", 1)
        head = t[0].replace("[AFK] PRD:", "").strip()
        rest = (t[1].strip() if len(t) > 1 else "")
        if len(rest) > 26:
            rest = rest[:25] + "…"
        out.append(
            f'<g><rect x="{x}" y="{y}" width="{BW}" height="{BH}" rx="4" '
            f'fill="var(--surface)" stroke="var(--s-{st})" stroke-width="1.5"/>'
            f'<rect x="{x}" y="{y}" width="3.5" height="{BH}" rx="1.75" fill="var(--s-{st})"/>'
            f'<text x="{x+14}" y="{y+21}" class="dn">#{n} {html.escape(head)}</text>'
            f'<text x="{x+14}" y="{y+38}" class="dt">{html.escape(rest)}</text></g>')
    out.append("</svg>")
    return "".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", default="arc-status.html")
    ap.add_argument("--title", default=None)
    args = ap.parse_args()
    if not SLUG:
        sys.exit("HARNESS_SLUG=owner/repo is required")

    prds = sorted(issues(label="prd"), key=lambda i: i["number"])
    if not prds:
        sys.exit(f"no PRDs found in {SLUG}")
    allis = issues()
    model = arc_model(prds, allis)
    deps, kids = model["deps"], model["kids"]

    def state_of(p):
        return model["states"][p["number"]]

    wf_map = next((i for i in allis if any(l["name"] == "wayfinder:map" for l in i["labels"])), None)
    tickets = wayfinder_tickets(allis)

    root = pathlib.Path.cwd()
    logs = sorted((root / ".harness" / "run").glob("worker-*.log")) if (root / ".harness").exists() else []
    sess = [l for l in gh("api", f"repos/{SLUG}", "--jq", ".name").splitlines()]  # touch API once
    try:
        panes = subprocess.run(["tmux", "ls"], capture_output=True, text=True, timeout=10).stdout
    except Exception:
        panes = ""
    pre = os.environ.get("HARNESS_SESS_PREFIX", "")
    live = [l.split(":")[0] for l in panes.splitlines()
            if UNIT and re.match(rf"^{re.escape(pre)}.*-{re.escape(UNIT)}(-|:)", l)] if panes else []

    counts = {k: sum(1 for p in prds if state_of(p) == k)
              for k in ("done", "running", "ready", "waiting")}
    LBL = {"done": "Closed", "running": "In flight", "ready": "Claimable", "waiting": "Blocked"}

    def rows():
        r = []
        for p in prds:
            n, st = p["number"], state_of(p)
            d = ", ".join(f"#{x}" for x in deps[n]) or "—"
            k = kids[n]
            kt = f'{k["closed"]}/{k["closed"]+k["open"]}' if (k["closed"] + k["open"]) else "—"
            title = p["title"].replace("[AFK] PRD:", "").strip()
            r.append(f'<tr><td class="m"><a href="{p["url"]}">#{n}</a></td>'
                     f'<td>{html.escape(title)}</td>'
                     f'<td><span class="pill {st}">{LBL[st]}</span></td>'
                     f'<td class="m">{d}</td><td class="m n">{kt}</td></tr>')
        return "".join(r)

    def tix():
        r = []
        for t in tickets:
            kind = next((l["name"].split(":")[1] for l in t["labels"]
                         if l["name"].startswith("wayfinder:")), "?")
            done = t["state"] == "CLOSED"
            gate = ", ".join(f"#{x}" for x in blocked_by(t["body"])) or "—"
            r.append(
                f'<li class="tk{" res" if done else ""}">'
                f'<div class="tkh"><span class="kind">{html.escape(kind)}</span>'
                f'<a class="m" href="{t["url"]}">#{t["number"]}</a>'
                f'<span class="pill {"done" if done else "gate"}">'
                f'{"Resolved" if done else "Awaiting a human"}</span></div>'
                f'<h3>{html.escape(t["title"])}</h3>'
                f'<p class="gt">Needs first: <span class="m">{gate}</span></p></li>')
        return "".join(r)

    name = args.title or f"{SLUG.split('/')[-1]} arc"
    doc = TEMPLATE.format(
        name=html.escape(name), slug=html.escape(SLUG),
        unit=html.escape(UNIT or "—"),
        svg=dag_svg(prds, deps, state_of), rows=rows(), tix=tix(),
        n_done=counts["done"], n_run=counts["running"],
        n_ready=counts["ready"], n_wait=counts["waiting"], n_total=len(prds),
        n_tix=sum(1 for t in tickets if t["state"] != "CLOSED"),
        map_url=(wf_map["url"] if wf_map else f"https://github.com/{SLUG}/issues"),
        workers=len(logs), live=(", ".join(live) if live else "none"),
        repo_url=f"https://github.com/{SLUG}")
    pathlib.Path(args.out).write_text(doc, encoding="utf-8")
    print(f"wrote {args.out}  ({len(prds)} PRDs, {len(tickets)} decisions)")


TEMPLATE = r"""<title>{name}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo:wght@500;600;700&family=Source+Sans+3:ital,wght@0,400;0,600;1,400&family=IBM+Plex+Mono:wght@400;500&display=swap">
<style>
:root{{
  --ground:#eef1f3; --surface:#ffffff; --sunk:#e4e9ec;
  --ink:#171d22; --muted:#5b6670; --line:#c3ced6; --hair:#d9e1e6;
  --accent:#1f5673; --accent-soft:#e2edf3;
  --s-done:#2f7a4f; --s-running:#b5851f; --s-ready:#1f5673; --s-waiting:#6b7480;
  --s-gate:#a8443a;
  --f-d:Archivo,"Helvetica Neue",Arial,sans-serif;
  --f-b:"Source Sans 3",system-ui,sans-serif;
  --f-m:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,monospace;
}}
@media (prefers-color-scheme:dark){{
  :root:not([data-theme="light"]){{
    --ground:#13181c; --surface:#1b2127; --sunk:#0e1317;
    --ink:#e3e9ee; --muted:#8d9aa5; --line:#38434c; --hair:#2a333a;
    --accent:#5fa8c7; --accent-soft:#1c2b34;
    --s-done:#5aa87a; --s-running:#d6a63f; --s-ready:#5fa8c7; --s-waiting:#7f8c98;
    --s-gate:#d1705f;
  }}
}}
:root[data-theme="dark"]{{
  --ground:#13181c; --surface:#1b2127; --sunk:#0e1317;
  --ink:#e3e9ee; --muted:#8d9aa5; --line:#38434c; --hair:#2a333a;
  --accent:#5fa8c7; --accent-soft:#1c2b34;
  --s-done:#5aa87a; --s-running:#d6a63f; --s-ready:#5fa8c7; --s-waiting:#7f8c98;
  --s-gate:#d1705f;
}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--ground);color:var(--ink);font-family:var(--f-b);
  font-size:16px;line-height:1.6;-webkit-font-smoothing:antialiased}}
.wrap{{max-width:1080px;margin:0 auto;padding:40px 24px 72px;display:flex;
  flex-direction:column;gap:40px}}
a{{color:var(--accent)}}
h1,h2,h3{{font-family:var(--f-d);text-wrap:balance;margin:0;letter-spacing:-.015em}}
h1{{font-size:1.9rem;font-weight:700}}
h2{{font-size:1.15rem;font-weight:600}}
h3{{font-size:1rem;font-weight:600}}
.m{{font-family:var(--f-m);font-size:.85em}}
.n{{font-variant-numeric:tabular-nums}}
.eyebrow{{font-family:var(--f-m);font-size:.72rem;letter-spacing:.11em;
  text-transform:uppercase;color:var(--muted)}}
header{{display:flex;flex-direction:column;gap:8px;
  border-bottom:1px solid var(--hair);padding-bottom:24px}}
header p{{margin:0;color:var(--muted);max-width:64ch}}
.bar{{display:grid;grid-template-columns:repeat(auto-fit,minmax(112px,1fr));gap:1px;
  background:var(--hair);border:1px solid var(--hair);border-radius:5px;overflow:hidden}}
.cell{{background:var(--surface);padding:14px 16px;display:flex;flex-direction:column;gap:3px}}
.cell b{{font-family:var(--f-d);font-size:1.65rem;font-weight:700;line-height:1;
  font-variant-numeric:tabular-nums}}
.cell span{{font-size:.76rem;color:var(--muted);letter-spacing:.02em}}
.cell.done b{{color:var(--s-done)}} .cell.running b{{color:var(--s-running)}}
.cell.ready b{{color:var(--s-ready)}} .cell.waiting b{{color:var(--s-waiting)}}
section{{display:flex;flex-direction:column;gap:14px}}
.panel{{background:var(--surface);border:1px solid var(--hair);border-radius:6px;
  padding:20px;overflow-x:auto}}
svg text.dn{{font-family:var(--f-m);font-size:12.5px;font-weight:500;fill:var(--ink)}}
svg text.dt{{font-family:var(--f-b);font-size:12px;fill:var(--muted)}}
table{{width:100%;border-collapse:collapse;font-size:.93rem}}
th{{text-align:left;font-family:var(--f-m);font-size:.7rem;letter-spacing:.09em;
  text-transform:uppercase;color:var(--muted);font-weight:400;
  padding:0 12px 9px;border-bottom:1px solid var(--hair)}}
td{{padding:11px 12px;border-bottom:1px solid var(--hair);vertical-align:top}}
tr:last-child td{{border-bottom:0}}
.pill{{display:inline-block;font-family:var(--f-m);font-size:.7rem;letter-spacing:.05em;
  padding:2px 8px;border-radius:3px;white-space:nowrap;
  border:1px solid currentColor}}
.pill.done{{color:var(--s-done)}} .pill.running{{color:var(--s-running)}}
.pill.ready{{color:var(--s-ready)}} .pill.waiting{{color:var(--s-waiting)}}
.pill.gate{{color:var(--s-gate)}}
ul.tks{{list-style:none;margin:0;padding:0;display:grid;gap:12px;
  grid-template-columns:repeat(auto-fit,minmax(280px,1fr))}}
.tk{{background:var(--surface);border:1px solid var(--hair);border-left:3px solid var(--s-gate);
  border-radius:5px;padding:16px;display:flex;flex-direction:column;gap:7px}}
.tk.res{{border-left-color:var(--s-done);opacity:.72}}
.tkh{{display:flex;align-items:center;gap:9px;flex-wrap:wrap}}
.kind{{font-family:var(--f-m);font-size:.68rem;letter-spacing:.08em;text-transform:uppercase;
  color:var(--muted);background:var(--sunk);padding:2px 7px;border-radius:3px}}
.gt{{margin:0;font-size:.8rem;color:var(--muted)}}
.note{{background:var(--accent-soft);border:1px solid var(--hair);border-radius:6px;
  padding:18px 20px;font-size:.93rem}}
.note p{{margin:0 0 10px}} .note p:last-child{{margin:0}}
.note strong{{font-weight:600}}
footer{{border-top:1px solid var(--hair);padding-top:20px;font-size:.83rem;color:var(--muted);
  display:flex;gap:20px;flex-wrap:wrap}}
a:focus-visible,tr:focus-visible{{outline:2px solid var(--accent);outline-offset:2px}}
@media (prefers-reduced-motion:reduce){{*{{transition:none!important;animation:none!important}}}}
</style>

<div class="wrap">
<header>
  <div class="eyebrow">Harness arc · unit {unit}</div>
  <h1>{name}</h1>
  <p>A sequenced chain of PRDs running unattended. Each box closes only when every one of its
  children closes, and the unit stays incomplete until the whole chain is done — so the pool
  cannot retire mid-queue.</p>
  <p class="m"><a href="{repo_url}">{slug}</a></p>
</header>

<div class="bar">
  <div class="cell done"><b class="n">{n_done}</b><span>Closed</span></div>
  <div class="cell running"><b class="n">{n_run}</b><span>In flight</span></div>
  <div class="cell ready"><b class="n">{n_ready}</b><span>Claimable</span></div>
  <div class="cell waiting"><b class="n">{n_wait}</b><span>Blocked</span></div>
  <div class="cell"><b class="n">{n_tix}</b><span>Awaiting you</span></div>
  <div class="cell"><b class="n">{workers}</b><span>Workers</span></div>
</div>

<section>
  <h2>Dependency chain</h2>
  <div class="panel">{svg}</div>
</section>

<section>
  <h2>Programme</h2>
  <div class="panel">
    <table>
      <thead><tr><th>PRD</th><th>Scope</th><th>State</th><th>Needs first</th><th>Children</th></tr></thead>
      <tbody>{rows}</tbody>
    </table>
  </div>
</section>

<section>
  <h2>Decisions the fleet will not make</h2>
  <div class="note">
    <p>These are <strong>human-only</strong>. They carry no <span class="m">prd</span> or
    <span class="m">ready-for-agent</span> label, so the engine cannot see them and they cost
    the chain nothing.</p>
    <p>None of them appears in any PRD's blocked-by section — that would wedge the chain
    permanently while the fleet reported itself healthy, with nothing in the loop able to
    recover it. The PRDs that need these answers build their artifacts, stop before the gated
    action, and close.</p>
  </div>
  <ul class="tks">{tix}</ul>
  <p class="gt">Map: <a href="{map_url}">wayfinder map</a></p>
</section>

<footer>
  <span>Live sessions: <span class="m">{live}</span></span>
  <span>{n_total} PRDs</span>
  <span>Regenerate: <span class="m">status-page.py</span></span>
</footer>
</div>
"""

if __name__ == "__main__":
    main()
