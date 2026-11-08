(function () {
  "use strict";
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---- chart hover ---- */
  var PTS = [
    { x: 46, y: 208.8, d: "2026-03-27", v: 1 }, { x: 83.7, y: 203.6, d: "2026-04-09", v: 2 },
    { x: 480.7, y: 198.4, d: "2026-08-24", v: 3 }, { x: 501, y: 193.2, d: "2026-08-31", v: 4 },
    { x: 503.8, y: 156.8, d: "2026-09-01", v: 11 }, { x: 506.7, y: 94.4, d: "2026-09-02", v: 23 },
    { x: 509.6, y: 78.8, d: "2026-09-03", v: 26 }, { x: 532.8, y: 73.6, d: "2026-09-11", v: 27 },
    { x: 564.7, y: 68.4, d: "2026-09-22", v: 28 }, { x: 567.6, y: 63.2, d: "2026-09-23", v: 29 },
    { x: 570.5, y: 58, d: "2026-09-24", v: 30 }, { x: 587.9, y: 52.8, d: "2026-09-30", v: 31 },
    { x: 666.1, y: 47.6, d: "2026-10-27", v: 32 }, { x: 680.6, y: 42.4, d: "2026-11-01", v: 33 },
    { x: 686.4, y: 32, d: "2026-11-03", v: 35 }, { x: 698, y: 26.8, d: "2026-11-07", v: 36 }
  ];
  var svg = document.querySelector(".chart-card svg");
  var tip = document.getElementById("chart-tip"), xh = document.getElementById("xhair"), hd = document.getElementById("hoverdot");
  if (svg) {
    svg.addEventListener("mousemove", function (ev) {
      var r = svg.getBoundingClientRect();
      var sx = (ev.clientX - r.left) * (728 / r.width);
      var best = PTS[0], bd = Math.abs(sx - PTS[0].x);
      for (var i = 1; i < PTS.length; i++) { var d = Math.abs(sx - PTS[i].x); if (d < bd) { bd = d; best = PTS[i]; } }
      xh.setAttribute("x1", best.x); xh.setAttribute("x2", best.x); xh.setAttribute("opacity", "1");
      hd.setAttribute("cx", best.x); hd.setAttribute("cy", best.y); hd.setAttribute("opacity", "1");
      tip.innerHTML = best.d + " · <b>" + best.v + "</b> release" + (best.v > 1 ? "s" : "");
      tip.style.left = (best.x / 728 * r.width) + "px";
      tip.style.top = ((best.y + 10) / 260 * r.height) + "px";
      tip.style.opacity = "1";
    });
    svg.addEventListener("mouseleave", function () {
      xh.setAttribute("opacity", "0"); hd.setAttribute("opacity", "0"); tip.style.opacity = "0";
    });
  }
})();
