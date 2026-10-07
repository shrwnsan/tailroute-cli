(function () {
  "use strict";
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---- mobile menu: close on select, Escape, or outside tap ---- */
  var navMenu = document.querySelector(".nav-menu");
  if (navMenu) {
    navMenu.addEventListener("toggle", function () { document.body.style.overflow = navMenu.hasAttribute("open") ? "hidden" : ""; });
    navMenu.addEventListener("click", function (ev) {
      if (ev.target.closest(".nav-panel a")) navMenu.removeAttribute("open");
    });
    document.addEventListener("keydown", function (ev) {
      if (ev.key === "Escape" && navMenu.hasAttribute("open")) { navMenu.removeAttribute("open"); navMenu.querySelector("summary").focus(); }
    });
    document.addEventListener("click", function (ev) { if (!navMenu.contains(ev.target)) navMenu.removeAttribute("open"); });
  }
})();
