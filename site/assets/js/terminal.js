(function () {
  "use strict";
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---- terminal decision loop ---- */
  var termBody = document.getElementById("term-body");
  var stDns = document.getElementById("st-dns"), stProxy = document.getElementById("st-proxy"), stPhase = document.getElementById("st-phase");
  var SCRIPT = [
    { cls: "cmd",  text: "route monitor: default → utun3 (vpn up)" },
    { cls: "dim",  text: "tailscale: utun4 active · vpn: utun3 active" },
    { cls: "warn", text: "both active → magicdns off, proxy up" },
    { state: { dns: "off", proxy: "up", phase: "COEXIST" } },
    { cls: "ok",   text: "✓ tailscale set --accept-dns=false" },
    { cls: "ok",   text: "✓ socks5 listening on 127.0.0.1:1055" },
    { cls: "dim",  text: "internet: via vpn ✓ · peers: via proxy ✓" },
    { pause: 2600 },
    { cls: "cmd",  text: "route monitor: utun3 removed (vpn down)" },
    { cls: "warn", text: "tailscale only → magicdns on, proxy down" },
    { state: { dns: "on", proxy: "down", phase: "MESH" } },
    { cls: "ok",   text: "✓ tailscale set --accept-dns=true" },
    { cls: "ok",   text: "✓ proxy stopped" },
    { cls: "dim",  text: "names: *.ts.net resolving again ✓" },
    { pause: 2600 },
    { cls: "cmd",  text: "route monitor: utun4 removed (tailscale down)" },
    { cls: "dim",  text: "no tailscale → nothing to do" },
    { state: { dns: "—", proxy: "—", phase: "IDLE" } },
    { cls: "dim",  text: "watching…" },
    { pause: 3400, clear: true }
  ];
  function setState(s) {
    stDns.textContent = s.dns; stDns.className = s.dns === "on" ? "fon" : s.dns === "off" ? "foff" : "";
    stProxy.textContent = s.proxy; stProxy.className = s.proxy === "up" ? "fon" : s.proxy === "down" ? "foff" : "";
    stPhase.textContent = s.phase;
  }
  function makeLine(cls) {
    var div = document.createElement("div"); div.className = "tl-" + cls; termBody.appendChild(div);
    /* cap must stay in sync with .term-body's fixed 10-line height */
    while (termBody.children.length > 10) termBody.removeChild(termBody.firstChild);
    return div;
  }
  function runTerminal() {
    if (reduced) {
      SCRIPT.forEach(function (s) {
        if (s.state) setState(s.state);
        if (s.cls) makeLine(s.cls).textContent = s.text;
      });
      return;
    }
    var i = 0;
    function next() {
      if (i >= SCRIPT.length) { i = 0; termBody.innerHTML = ""; }
      var step = SCRIPT[i++];
      if (step.clear) { termBody.innerHTML = ""; setTimeout(next, 400); return; }
      if (step.pause) { setTimeout(next, step.pause); return; }
      if (step.state) { setState(step.state); setTimeout(next, 250); return; }
      var el = makeLine(step.cls); typeInto(el, step.text, 0);
    }
    function typeInto(el, text, pos) {
      if (pos >= text.length) { setTimeout(next, text.indexOf("route monitor") === 0 ? 500 : 330); return; }
      el.textContent = text.slice(0, pos + 1);
      setTimeout(function () { typeInto(el, text, pos + 1); }, 11 + Math.random() * 14);
    }
    next();
  }

  runTerminal();
})();
