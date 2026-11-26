(function () {
  "use strict";

  /* ---- chart hover + keyboard readout ---- */
  /* The release points and the viewBox are injected at deploy time by
     scripts/update-metrics.py (see the #chart-data JSON blob next to the
     SVG) — this file carries no geometry, so the chart regenerates freely.
     The tooltip mapping reads the SVG's live viewBox, staying correct for
     whatever region the injector drew. The SVG is a tab stop: arrow keys
     step through the points with the same readout the pointer gets. */
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

  var kbIndex = PTS.length - 1;

  function show(point) {
    xh.setAttribute("x1", point.x); xh.setAttribute("x2", point.x); xh.setAttribute("opacity", "1");
    hd.setAttribute("cx", point.x); hd.setAttribute("cy", point.y); hd.setAttribute("opacity", "1");
    /* text nodes only — never build the readout from strings */
    while (tip.firstChild) tip.removeChild(tip.firstChild);
    tip.appendChild(document.createTextNode(point.d + " \u00b7 "));
    var b = document.createElement("b");
    b.textContent = point.v;
    tip.appendChild(b);
    tip.appendChild(document.createTextNode(" release" + (point.v > 1 ? "s" : "")));
    var top = (point.y - vb.y) / vb.height * svg.getBoundingClientRect().height;
    /* near the card's top edge the tooltip would leave the chart: flip below */
    var below = top < 40;
    tip.classList.toggle("below", below);
    tip.style.left = ((point.x - vb.x) / vb.width * svg.getBoundingClientRect().width) + "px";
    tip.style.top = ((point.y - vb.y) / vb.height * svg.getBoundingClientRect().height) + "px";
    tip.style.opacity = "1";
  }

  function hide() {
    xh.setAttribute("opacity", "0"); hd.setAttribute("opacity", "0"); tip.style.opacity = "0";
  }

  svg.addEventListener("mousemove", function (ev) {
    var r = svg.getBoundingClientRect();
    var sx = (ev.clientX - r.left) * (vb.width / r.width);
    var best = PTS[0], bd = Math.abs(sx - PTS[0].x);
    for (var i = 1; i < PTS.length; i++) { var d = Math.abs(sx - PTS[i].x); if (d <= bd) { bd = d; best = PTS[i]; } }
    kbIndex = PTS.indexOf(best);
    show(best);
  });
  svg.addEventListener("mouseleave", hide);
  svg.addEventListener("focus", function () { show(PTS[kbIndex]); });
  svg.addEventListener("blur", hide);
  svg.addEventListener("keydown", function (ev) {
    if (ev.key === "ArrowLeft" && kbIndex > 0) { kbIndex -= 1; show(PTS[kbIndex]); ev.preventDefault(); }
    else if (ev.key === "ArrowRight" && kbIndex < PTS.length - 1) { kbIndex += 1; show(PTS[kbIndex]); ev.preventDefault(); }
  });
})();
