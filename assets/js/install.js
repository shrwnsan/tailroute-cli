/* Install switcher — reusable component (one JS file, any number of
 * instances). Markup contract; give every instance its own id prefix
 * ("hero-", "quick-", "final-", …):
 *
 * <div class="install" data-install id="hero-install">
 *   <div class="install-tabs" role="tablist" aria-label="Install">
 *     <button type="button" role="tab" id="hero-tab-cli" aria-controls="hero-panel-cli"
 *             aria-selected="false" tabindex="-1">CLI daemon</button>
 *     <button type="button" role="tab" id="hero-tab-app" aria-controls="hero-panel-app"
 *             aria-selected="true">Menu bar app</button>
 *   </div>
 *   <div class="install-panel" role="tabpanel" id="hero-panel-cli"
 *        aria-labelledby="hero-tab-cli" hidden>
 *     <p class="install-label">CLI daemon</p>
 *     <code class="install-cmd" id="hero-cmd-cli">brew install shrwnsan/tap/tailroute-cli</code>
 *     <button type="button" data-copy="brew install shrwnsan/tap/tailroute-cli"
 *             data-copy-target="hero-cmd-cli">Copy</button>
 *     <p class="install-note">…</p>
 *     <p class="install-activate">… <code>tailroute status</code> …</p>
 *   </div>
 *   <div class="install-panel" role="tabpanel" id="hero-panel-app"
 *        aria-labelledby="hero-tab-app">…</div>
 * </div>
 *
 * Rules:
 * - The default tab is whichever one the HTML marks aria-selected="true";
 *   this script never hard-codes it. Every panel's content is already in the
 *   HTML — no text swapping.
 * - Keys follow the WAI-ARIA tabs pattern with automatic activation:
 *   Left/Right move and wrap, Home/End jump, and selection follows focus.
 * - .install-activate is reserved for an activation line under the command;
 *   it is plain markup (this script and install.css don't manage it yet), so
 *   a page can add it without touching the component.
 * - .install-label only shows without JavaScript (CSS hides it when
 *   html.js is set); see the no-JS rules at the bottom of install.css.
 * - Copy buttons inside a panel are wired by copy.js (button[data-copy] with
 *   optional data-copy-target / data-copy-ok / data-copy-fail).
 */
(function () {
  "use strict";

  function activate(tabs, panels, next) {
    tabs.forEach(function (tab) {
      var on = tab === next;
      tab.setAttribute("aria-selected", on ? "true" : "false");
      tab.tabIndex = on ? 0 : -1;
    });
    panels.forEach(function (panel) {
      if (panel.id === next.getAttribute("aria-controls")) panel.removeAttribute("hidden");
      else panel.setAttribute("hidden", "");
    });
    next.focus();
  }

  document.querySelectorAll("[data-install]").forEach(function (root) {
    var tabs = Array.prototype.slice.call(root.querySelectorAll("[role=tab]"));
    var panels = tabs.map(function (tab) {
      return document.getElementById(tab.getAttribute("aria-controls"));
    });
    if (!tabs.length || panels.indexOf(null) !== -1) return;

    tabs.forEach(function (tab, i) {
      /* honour whatever the HTML preselects */
      if (tab.getAttribute("aria-selected") === "true") tab.tabIndex = 0;
      else tab.tabIndex = -1;

      tab.addEventListener("click", function () {
        activate(tabs, panels, tab);
      });
      tab.addEventListener("keydown", function (ev) {
        var last = tabs.length - 1;
        var to = null;
        if (ev.key === "ArrowRight") to = i === last ? 0 : i + 1;
        else if (ev.key === "ArrowLeft") to = i === 0 ? last : i - 1;
        else if (ev.key === "Home") to = 0;
        else if (ev.key === "End") to = last;
        if (to === null) return;
        ev.preventDefault();
        activate(tabs, panels, tabs[to]);
      });
    });
  });
})();
