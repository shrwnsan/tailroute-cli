(function () {
  "use strict";
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function honestCopy(text, btn, okLabel, resetLabel, okClass, failLabel) {
    function ok() { btn.textContent = okLabel; btn.classList.add(okClass); setTimeout(function () { btn.textContent = resetLabel; btn.classList.remove(okClass); }, 1600); }
    function fail() { btn.textContent = failLabel; btn.classList.add("fail"); setTimeout(function () { btn.textContent = resetLabel; btn.classList.remove("fail"); }, 2400); }
    function fallback() {
      var ta = document.createElement("textarea"); ta.value = text;
      ta.style.position = "fixed"; ta.style.opacity = "0";
      document.body.appendChild(ta); ta.select();
      var did = false; try { did = document.execCommand("copy"); } catch (e) {}
      document.body.removeChild(ta);
      if (did) ok(); else fail();
    }
    if (navigator.clipboard && navigator.clipboard.writeText && window.isSecureContext) navigator.clipboard.writeText(text).then(ok, fallback);
    else fallback();
  }

  /* shared with the install switcher's copy button */
  window.tailroute = window.tailroute || {};
  window.tailroute.copy = honestCopy;

  /* ---- open-core pricing cards: copy, don't teleport ---- */
  document.querySelectorAll(".sc-btn[data-copy]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      honestCopy(btn.getAttribute("data-copy"), btn, "✓ copied—paste into Terminal", btn.getAttribute("data-label"), "ok", "copy failed—select the command");
    });
  });

  /* ---- finale copy chips ---- */
  document.querySelectorAll(".fin-chip[data-copy]").forEach(function (chip) {
    var btn = chip.querySelector("button");
    btn.addEventListener("click", function () {
      honestCopy(chip.getAttribute("data-copy"), btn, "copied ✓", "copy", "ok", "copy failed");
    });
  });
})();
