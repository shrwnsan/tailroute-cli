/* tailroute landing — terminal decision loop, copy chips, scroll reveals */
(function () {
  "use strict";

  var reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- hero terminal: the daemon's decision loop ---------- */

  var termBody = document.getElementById("term-body");
  var stDns = document.getElementById("st-dns");
  var stProxy = document.getElementById("st-proxy");
  var stPhase = document.getElementById("st-phase");

  // type: line classes — cmd (prompted), out, dim, ok, warn; state flips the status chips
  var SCRIPT = [
    { cls: "cmd",  text: "route monitor: default \u2192 utun3 (vpn up)" },
    { cls: "dim",  text: "tailscale: utun4 active \u00b7 vpn: utun3 active" },
    { cls: "warn", text: "both active \u2192 magicdns off, proxy up" },
    { state: { dns: "off", proxy: "up", phase: "COEXIST" } },
    { cls: "ok",   text: "\u2713 tailscale set --accept-dns=false" },
    { cls: "ok",   text: "\u2713 socks5 listening on 127.0.0.1:1055" },
    { cls: "dim",  text: "internet: via vpn \u2713 \u00b7 peers: via proxy \u2713" },
    { pause: 2600 },
    { cls: "cmd",  text: "route monitor: utun3 removed (vpn down)" },
    { cls: "warn", text: "tailscale only \u2192 magicdns on, proxy down" },
    { state: { dns: "on", proxy: "down", phase: "MESH" } },
    { cls: "ok",   text: "\u2713 tailscale set --accept-dns=true" },
    { cls: "ok",   text: "\u2713 proxy stopped" },
    { cls: "dim",  text: "names: *.ts.net resolving again \u2713" },
    { pause: 2600 },
    { cls: "cmd",  text: "route monitor: utun4 removed (tailscale down)" },
    { cls: "dim",  text: "no tailscale \u2192 nothing to do" },
    { state: { dns: "\u2014", proxy: "\u2014", phase: "IDLE" } },
    { cls: "dim",  text: "watching\u2026" },
    { pause: 3400, clear: true }
  ];

  function setState(s) {
    stDns.textContent = s.dns;
    stDns.className = s.dns === "on" ? "st-on" : s.dns === "off" ? "st-off" : "st-idle";
    stProxy.textContent = s.proxy;
    stProxy.className = s.proxy === "up" ? "st-on" : s.proxy === "down" ? "st-off" : "st-idle";
    stPhase.textContent = s.phase;
  }

  function makeLine(cls) {
    var div = document.createElement("div");
    div.className = "tl-" + cls;
    termBody.appendChild(div);
    while (termBody.children.length > 11) termBody.removeChild(termBody.firstChild);
    return div;
  }

  function runTerminal() {
    if (reducedMotion) {
      // no animation: print the coexistence story once, statically
      SCRIPT.forEach(function (step) {
        if (step.state) setState(step.state);
        if (step.cls) {
          var line = makeLine(step.cls);
          line.textContent = step.text;
        }
      });
      return;
    }
    var i = 0;
    function next() {
      if (i >= SCRIPT.length) { i = 0; termBody.innerHTML = ""; }
      var step = SCRIPT[i++];
      if (!step) return;
      if (step.clear) { termBody.innerHTML = ""; setTimeout(next, 400); return; }
      if (step.pause) { setTimeout(next, step.pause); return; }
      if (step.state) { setState(step.state); setTimeout(next, 250); return; }
      var el = makeLine(step.cls);
      typeInto(el, step.text, 0);
    }
    function typeInto(el, text, pos) {
      if (pos >= text.length) { setTimeout(next, step_gap(text)); return; }
      el.textContent = text.slice(0, pos + 1);
      setTimeout(function () { typeInto(el, text, pos + 1); }, 11 + Math.random() * 14);
    }
    function step_gap(text) {
      return text.indexOf("route monitor") === 0 ? 500 : 330;
    }
    next();
  }

  // blinking caret parked on a live line while the loop runs
  function keepCaret() {
    if (reducedMotion) return;
    setInterval(function () {
      var lines = termBody.querySelectorAll(".tl-cmd");
      var last = lines[lines.length - 1];
      if (last && !last.querySelector(".tl-caret") && last.textContent.length > 0) {
        // caret lives at the end of the most recent prompt line
        termBody.querySelectorAll(".tl-caret").forEach(function (c) { c.remove(); });
        last.appendChild(document.createTextNode(" "));
        last.appendChild(caretEl());
      }
    }, 1200);
  }
  function caretEl() {
    var s = document.createElement("span");
    s.className = "tl-caret";
    return s;
  }

  /* ---------- copy chips ---------- */

  document.querySelectorAll(".install-chip[data-copy]").forEach(function (chip) {
    var btn = chip.querySelector(".copy-btn");
    if (!btn) return;
    btn.addEventListener("click", function () {
      var text = chip.getAttribute("data-copy");
      function done() {
        btn.textContent = "copied \u2713";
        btn.classList.add("copied");
        setTimeout(function () {
          btn.textContent = "copy";
          btn.classList.remove("copied");
        }, 1600);
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, done);
      } else {
        var ta = document.createElement("textarea");
        ta.value = text;
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand("copy"); } catch (e) { /* noop */ }
        document.body.removeChild(ta);
        done();
      }
    });
  });

  /* ---------- scroll reveals ---------- */

  var revealEls = document.querySelectorAll(".reveal");
  if (reducedMotion || !("IntersectionObserver" in window)) {
    revealEls.forEach(function (el) { el.classList.add("in"); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add("in");
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.12, rootMargin: "0px 0px -40px 0px" });
    revealEls.forEach(function (el) { io.observe(el); });
  }

  /* ---------- boot ---------- */

  if (termBody && stDns && stProxy && stPhase) {
    runTerminal();
    keepCaret();
  }
})();
