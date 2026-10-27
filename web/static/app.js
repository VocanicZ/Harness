/* harness web — app.js (#223). Theme toggle only, for now: auto (follow the OS) → light → dark.
   The choice is a per-viewer convenience kept in localStorage; every access is guarded, so the page
   renders the same with storage blocked. All HTML comes from the server (scripts/web_render.py). */
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
})();
