/* harness web — app.js (#223). The theme toggle: auto (follow the OS) → light → dark, a per-viewer
   convenience kept in localStorage; every access is guarded, so the page renders the same with
   storage blocked. Live updates (#227): an EventSource on /events swaps each pushed region whole.
   All HTML comes from the server (scripts/web_render.py); nothing here renders data. */
(function () {
  "use strict";
  var KEY = "harness-web-theme";
  var ORDER = ["auto", "light", "dark"];
  var LABEL = { auto: "Theme: follow the system", light: "Theme: light", dark: "Theme: dark" };

  function stored() {
    try { var v = window.localStorage.getItem(KEY); return ORDER.indexOf(v) >= 0 ? v : "auto"; }
    catch (e) { return "auto"; }
  }
  function apply(theme) {
    var root = document.documentElement;
    if (theme === "auto") root.removeAttribute("data-theme"); else root.setAttribute("data-theme", theme);
  }
  function label(btn, theme) {
    btn.textContent = "Theme: " + theme;
    btn.setAttribute("aria-label", LABEL[theme]);
  }

  apply(stored());   // runs in <head>, before first paint: no flash of the wrong theme

  document.addEventListener("DOMContentLoaded", function () {
    var btn = document.querySelector("[data-theme-toggle]");
    if (!btn) return;
    label(btn, stored());
    btn.addEventListener("click", function () {
      var next = ORDER[(ORDER.indexOf(stored()) + 1) % ORDER.length];
      try { window.localStorage.setItem(KEY, next); } catch (e) { /* storage blocked: this view only */ }
      apply(next);
      label(btn, next);
    });
  });

  // --- live updates (#227) ----------------------------------------------------------------------
  // `patch` carries {asof, regions: {id: html}}: each region's <section data-region> is replaced
  // whole. Focus inside a replaced region goes back to the same issue node or link, else to the
  // region. A region the page does not have means the page's shape changed (a repo joined): reload.
  function region(id) {
    var all = document.querySelectorAll("[data-region]");
    for (var i = 0; i < all.length; i++) if (all[i].getAttribute("data-region") === id) return all[i];
    return null;
  }
  function swap(id, html) {
    var old = region(id);
    if (!old) return false;
    var active = document.activeElement;
    var had = active && old.contains(active);
    var issue = had && active.getAttribute ? active.getAttribute("data-issue") : null;
    var href = had && active.getAttribute ? active.getAttribute("href") : null;
    var tpl = document.createElement("template");
    tpl.innerHTML = html.trim();
    var fresh = tpl.content.firstElementChild;
    if (!fresh) return true;
    old.replaceWith(fresh);
    if (had) {
      var target = null, cands = fresh.querySelectorAll(issue ? "[data-issue]" : "[href]");
      for (var i = 0; i < cands.length && !target; i++) {
        if (issue ? cands[i].getAttribute("data-issue") === issue : cands[i].getAttribute("href") === href) target = cands[i];
      }
      if (!target) { fresh.setAttribute("tabindex", "-1"); target = fresh; }
      target.focus();
    }
    return true;
  }
  function live(state) {
    var el = document.querySelector("[data-live]");
    if (el) el.setAttribute("data-live", state);
  }

  document.addEventListener("DOMContentLoaded", function () {
    var root = document.documentElement;
    var view = root.getAttribute("data-view");
    if (!view || !window.EventSource) return;
    // EventSource retries a dropped stream by itself, but gives up for good on a non-200 answer
    // (a fleet briefly unregistered by `harness stop`/`update`, a 503 when every slot is taken).
    // Then open a fresh one after a pause, from the version this page holds.
    function connect() {
      var es = new EventSource("/events?view=" + encodeURIComponent(view) +
        "&since=" + encodeURIComponent(root.getAttribute("data-version") || ""));
      es.addEventListener("open", function () { live("live"); });
      es.addEventListener("error", function () {
        if (es.readyState !== EventSource.CLOSED) { live("reconnecting"); return; }
        live("offline");
        es.close();
        setTimeout(connect, 15000);
      });
      es.addEventListener("patch", onPatch);
    }
    function onPatch(ev) {
      var msg;
      try { msg = JSON.parse(ev.data); } catch (e) { return; }
      var regions = msg.regions || {};
      for (var id in regions) {
        if (Object.prototype.hasOwnProperty.call(regions, id) && !swap(id, regions[id])) {
          window.location.reload();
          return;
        }
      }
      if (ev.lastEventId) root.setAttribute("data-version", ev.lastEventId);
      refreshDrawer(regions);
    }
    connect();
  });

  // --- the issue drawer (#228) ------------------------------------------------------------------
  // A click (or Enter, which clicks a focused link) on a `?issue=N` link fetches that issue's drawer
  // fragment from the server and shows it in [data-drawer-host], outside every region, so a push
  // never closes it. Tab cycles inside it; Esc or Close removes it and puts focus back on the node
  // that opened it. The open issue is mirrored into `?issue=N` so the URL is shareable; without JS
  // the same links load that URL, which the server renders with the drawer open.
  var opened = null;   // {issue, repo, region}: what the drawer shows and where its opener lives

  function drawerHost() { return document.querySelector("[data-drawer-host]"); }
  function drawerEl() { var h = drawerHost(); return h && h.querySelector("[role=dialog]"); }
  function linkTarget(a) {
    var q = new URLSearchParams((a.getAttribute("href") || "").replace(/^[^?]*/, ""));
    var reg = a.closest("[data-region]");
    var rid = reg ? reg.getAttribute("data-region") : null;
    var repo = q.get("repo") || (rid && rid.replace(/^(dag|unparented)-/, "")) || null;
    return { issue: q.get("issue"), repo: repo, region: rid };
  }
  function setUrl(t) {
    var u = new URL(window.location.href);
    u.searchParams.delete("issue"); u.searchParams.delete("repo");
    if (t) { u.searchParams.set("issue", t.issue); if (t.repo) u.searchParams.set("repo", t.repo); }
    history.replaceState(history.state, "", u.pathname + u.search + u.hash);
  }
  function fragmentUrl(t) {
    return document.documentElement.getAttribute("data-view") + "/issue/" + encodeURIComponent(t.issue) +
      (t.repo ? "?repo=" + encodeURIComponent(t.repo) : "");
  }
  function show(html) {
    drawerHost().innerHTML = html;
    var d = drawerEl();
    if (d) d.focus();
  }
  function openIssue(t) {
    fetch(fragmentUrl(t), { headers: { Accept: "text/html" } }).then(function (r) {
      if (!r.ok) throw new Error(r.status);
      return r.text();
    }).then(function (html) {
      if (opened && t.region === null) t.region = opened.region;   // a link inside the drawer
      opened = t;
      show(html);
      setUrl(t);
    }).catch(function () {
      window.location.search = "?issue=" + encodeURIComponent(t.issue) + (t.repo ? "&repo=" + encodeURIComponent(t.repo) : "");
    });
  }
  function opener(t) {
    var n = CSS.escape(t.issue);
    var sel = '[data-issue="' + n + '"], [data-awaiting="' + n + '"] > a';   // a DAG node, or an "Awaiting you" item
    var scopes = [t.region && document.querySelector('[data-region="' + CSS.escape(t.region) + '"]'), document.querySelector("main")];
    for (var s = 0; s < scopes.length; s++) {
      var all = scopes[s] ? scopes[s].querySelectorAll(sel) : [];
      for (var i = 0; i < all.length; i++) if (!all[i].closest("[data-drawer-host]")) return all[i];
    }
    return null;
  }
  function closeDrawer() {
    var d = drawerEl();
    if (!d) return;
    var t = opened || { issue: d.getAttribute("data-issue"), repo: d.getAttribute("data-repo"), region: null };
    drawerHost().innerHTML = "";
    opened = null;
    setUrl(null);
    var back = opener(t);
    if (back) back.focus();
  }
  function focusables(d) {
    var out = [], all = d.querySelectorAll("a[href], button:not([disabled]), [tabindex]:not([tabindex='-1'])");
    for (var i = 0; i < all.length; i++) if (all[i].getClientRects().length) out.push(all[i]);
    return out;
  }
  function refreshDrawer(regions) {
    var d = drawerEl();
    if (!d) return;
    var mark = 'data-issue="' + d.getAttribute("data-issue") + '"';
    var touched = false;
    for (var id in regions) if (Object.prototype.hasOwnProperty.call(regions, id) && regions[id].indexOf(mark) >= 0) touched = true;
    if (!touched) return;
    var t = { issue: d.getAttribute("data-issue"), repo: d.getAttribute("data-repo") };
    fetch(fragmentUrl(t), { headers: { Accept: "text/html" } }).then(function (r) {
      return r.ok ? r.text() : null;
    }).then(function (html) {
      var cur = drawerEl();
      if (!html || !cur || cur.getAttribute("data-issue") !== t.issue) return;
      var a = document.activeElement, inside = a && cur.contains(a);
      var key = inside && a.getAttribute ? (a.getAttribute("href") || (a.hasAttribute("data-drawer-close") ? "close" : null)) : null;
      drawerHost().innerHTML = html;
      if (!inside) return;
      var fresh = drawerEl(), target = null;
      if (key === "close") target = fresh.querySelector("[data-drawer-close]");
      else if (key) { var c = fresh.querySelectorAll("[href]"); for (var i = 0; i < c.length && !target; i++) if (c[i].getAttribute("href") === key) target = c[i]; }
      (target || fresh).focus();
    }).catch(function () { /* the drawer keeps what it shows */ });
  }

  document.addEventListener("DOMContentLoaded", function () {
    if (!drawerHost()) return;
    var d = drawerEl();
    if (d) {   // a deep link: the server rendered it open
      opened = { issue: d.getAttribute("data-issue"), repo: d.getAttribute("data-repo"), region: null };
      var node = opener(opened);
      var reg = node && node.closest("[data-region]");
      opened.region = reg ? reg.getAttribute("data-region") : null;
      d.focus();
    }
    document.addEventListener("click", function (e) {
      if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      if (e.target.closest && e.target.closest("[data-drawer-close]")) { e.preventDefault(); closeDrawer(); return; }
      var a = e.target.closest && e.target.closest("a[href]");
      if (!a || !/^\?issue=\d+/.test(a.getAttribute("href") || "")) return;
      e.preventDefault();
      openIssue(linkTarget(a));
    });
    document.addEventListener("keydown", function (e) {
      var dlg = drawerEl();
      if (!dlg) return;
      if (e.key === "Escape") { e.preventDefault(); closeDrawer(); return; }
      if (e.key !== "Tab") return;
      var f = focusables(dlg);
      if (!f.length) { e.preventDefault(); dlg.focus(); return; }
      var first = f[0], last = f[f.length - 1], a = document.activeElement;
      if (!dlg.contains(a) || a === dlg) { e.preventDefault(); (e.shiftKey ? last : first).focus(); }
      else if (e.shiftKey && a === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && a === last) { e.preventDefault(); first.focus(); }
    });
  });
})();
