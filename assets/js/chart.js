(function () {
  "use strict";

  /* ---- chart hover ---- */
  /* The release points and the viewBox are injected at deploy time by
     scripts/update-metrics.py (see the #chart-data JSON blob next to the
     SVG) — this file carries no geometry, so the chart regenerates freely.
     The tooltip mapping reads the SVG's live viewBox, staying correct for
     whatever region the injector drew. */
  var svg = document.querySelector(".chart-card svg");
  var tip = document.getElementById("chart-tip"), xh = document.getElementById("xhair"), hd = document.getElementById("hoverdot");
  var dataEl = document.getElementById("chart-data");
  if (!svg || !dataEl) return;

  var PTS, vb;
  try {
    PTS = JSON.parse(dataEl.textContent).pts.map(function (p) {
      return { x: p[0], y: p[1], d: p[2], v: p[3] };
    });
    vb = svg.viewBox.baseVal;
  } catch (e) {
    return; // malformed blob: no hover, chart still renders statically
  }
  if (!PTS.length) return;

  svg.addEventListener("mousemove", function (ev) {
    var r = svg.getBoundingClientRect();
    var sx = (ev.clientX - r.left) * (vb.width / r.width);
    var best = PTS[0], bd = Math.abs(sx - PTS[0].x);
    for (var i = 1; i < PTS.length; i++) { var d = Math.abs(sx - PTS[i].x); if (d <= bd) { bd = d; best = PTS[i]; } }
    xh.setAttribute("x1", best.x); xh.setAttribute("x2", best.x); xh.setAttribute("opacity", "1");
    hd.setAttribute("cx", best.x); hd.setAttribute("cy", best.y); hd.setAttribute("opacity", "1");
    tip.innerHTML = best.d + " · <b>" + best.v + "</b> release" + (best.v > 1 ? "s" : "");
    tip.style.left = ((best.x - vb.x) / vb.width * r.width) + "px";
    tip.style.top = ((best.y - vb.y) / vb.height * r.height) + "px";
    tip.style.opacity = "1";
  });
  svg.addEventListener("mouseleave", function () {
    xh.setAttribute("opacity", "0"); hd.setAttribute("opacity", "0"); tip.style.opacity = "0";
  });
})();
