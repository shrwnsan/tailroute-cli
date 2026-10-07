(function () {
  "use strict";
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---- install switcher ---- */
  var CMDS = {
    app: { cmd: "brew install --cask shrwnsan/tap/tailroute", note: "includes the CLI" },
    cli: { cmd: "brew install shrwnsan/tap/tailroute-cli", note: "then: sudo tailroute install" }
  };
  var current = "app";
  var tabApp = document.getElementById("tab-app"), tabCli = document.getElementById("tab-cli");
  var swText = document.getElementById("sw-text"), swNote = document.getElementById("sw-note");
  function pick(which) {
    current = which;
    tabApp.classList.toggle("on", which === "app"); tabApp.setAttribute("aria-selected", which === "app");
    tabCli.classList.toggle("on", which === "cli"); tabCli.setAttribute("aria-selected", which === "cli");
    tabApp.tabIndex = which === "app" ? 0 : -1; tabCli.tabIndex = which === "cli" ? 0 : -1;
    swText.textContent = CMDS[which].cmd; swNote.textContent = CMDS[which].note;
  }
  tabApp.addEventListener("click", function () { pick("app"); });
  tabCli.addEventListener("click", function () { pick("cli"); });
  [tabApp, tabCli].forEach(function (t) {
    t.addEventListener("keydown", function (ev) {
      if (ev.key !== "ArrowLeft" && ev.key !== "ArrowRight") return;
      ev.preventDefault();
      var toCli = t === tabApp;
      pick(toCli ? "cli" : "app");
      (toCli ? tabCli : tabApp).focus();
    });
  });

  document.getElementById("sw-copy").addEventListener("click", function () {
    window.tailroute.copy(CMDS[current].cmd, this, "Copied ✓", "Copy", "ok", "copy failed");
  });
})();
