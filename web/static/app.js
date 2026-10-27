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
  // whole. Focus inside a replaced region goes back to the same issue node, else to the region. A
  // region the page does not have means the page's shape changed (a repo joined): reload it.
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
    var tpl = document.createElement("template");
    tpl.innerHTML = html.trim();
    var fresh = tpl.content.firstElementChild;
    if (!fresh) return true;
    old.replaceWith(fresh);
    if (had) {
      var target = issue && fresh.querySelector('[data-issue="' + issue + '"]');
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
    var url = "/events?view=" + encodeURIComponent(view) +
      "&since=" + encodeURIComponent(root.getAttribute("data-version") || "");
    var es = new EventSource(url);
    es.addEventListener("open", function () { live("live"); });
    es.addEventListener("error", function () {
      live(es.readyState === EventSource.CLOSED ? "offline" : "reconnecting");
    });
    es.addEventListener("patch", function (ev) {
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
    });
  });
})();
