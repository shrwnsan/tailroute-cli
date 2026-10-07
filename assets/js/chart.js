(function () {
  "use strict";
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---- chart hover ---- */
  var PTS = [
    { x: 46, y: 207.6, d: "2026-03-27", v: 1 }, { x: 84.8, y: 201.2, d: "2026-04-09", v: 2 },
    { x: 493.6, y: 194.8, d: "2026-08-24", v: 3 }, { x: 514.5, y: 188.4, d: "2026-08-31", v: 4 },
    { x: 520.2, y: 143.8, d: "2026-09-01", v: 11 }, { x: 525.9, y: 67.1, d: "2026-09-02", v: 23 },
    { x: 531.6, y: 47.9, d: "2026-09-03", v: 26 }, { x: 555.5, y: 41.5, d: "2026-09-11", v: 27 },
    { x: 588.3, y: 35.1, d: "2026-09-22", v: 28 }, { x: 591.4, y: 28.7, d: "2026-09-23", v: 29 },
    { x: 594.4, y: 22.4, d: "2026-09-24", v: 30 }, { x: 612.3, y: 16, d: "2026-09-30", v: 31 }
  ];
  var svg = document.querySelector(".chart-card svg");
  var tip = document.getElementById("chart-tip"), xh = document.getElementById("xhair"), hd = document.getElementById("hoverdot");
  if (svg) {
    svg.addEventListener("mousemove", function (ev) {
      var r = svg.getBoundingClientRect();
      var sx = (ev.clientX - r.left) * (640 / r.width);
      var best = PTS[0], bd = Math.abs(sx - PTS[0].x);
      for (var i = 1; i < PTS.length; i++) { var d = Math.abs(sx - PTS[i].x); if (d < bd) { bd = d; best = PTS[i]; } }
      xh.setAttribute("x1", best.x); xh.setAttribute("x2", best.x); xh.setAttribute("opacity", "1");
      hd.setAttribute("cx", best.x); hd.setAttribute("cy", best.y); hd.setAttribute("opacity", "1");
      tip.innerHTML = best.d + " · <b>" + best.v + "</b> release" + (best.v > 1 ? "s" : "");
      tip.style.left = (best.x / 640 * r.width) + "px";
      tip.style.top = (best.y / 250 * r.height) + "px";
      tip.style.opacity = "1";
    });
    svg.addEventListener("mouseleave", function () {
      xh.setAttribute("opacity", "0"); hd.setAttribute("opacity", "0"); tip.style.opacity = "0";
    });
  }
})();
