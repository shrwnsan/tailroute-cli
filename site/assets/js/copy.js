/* Copy button — reusable, delegated. Any
 *
 *   <button type="button" data-copy="text to copy">Copy</button>
 *
 * works, anywhere on the page. Optional attributes:
 *   data-copy-target  id of the element holding the command text; when a copy
 *                     fails, its text is selected so the fail label only has
 *                     to say "Press ⌘C"
 *   data-copy-ok      label shown after a successful copy (default "Copied")
 *   data-copy-fail    label shown after a failed copy (default "Press ⌘C")
 *
 * The reset label is the button's original text. Success holds 1.6 s, failure
 * 2.4 s. Both are announced through one role="status" element this script
 * appends to <body>. The button keeps its width while labels swap: at load,
 * every label is stacked into the same grid cell (see install.css) so the
 * widest one sizes the button.
 *
 * The button gains class "ok" or "fail" while a label is showing, so page CSS
 * can colour the states (success reads best in the mesh green).
 *
 * window.tailroute.copy(text, button) stays available for other scripts.
 */
(function () {
  "use strict";

  var HOLD_OK = 1600;
  var HOLD_FAIL = 2400;
  var OK_DEFAULT = "Copied";
  var FAIL_DEFAULT = "Press ⌘C";

  /* one polite live region for every button */
  var status = document.createElement("p");
  status.setAttribute("role", "status");
  status.style.cssText =
    "position:absolute;width:1px;height:1px;margin:-1px;padding:0;border:0;" +
    "clip:rect(0 0 0 0);clip-path:inset(50%);overflow:hidden;white-space:nowrap;";
  document.body.appendChild(status);

  function prepare(btn) {
    if (btn.getAttribute("data-copy-ready") === "1") return;
    var spans = [];
    var labels = [
      btn.textContent,
      btn.getAttribute("data-copy-ok") || OK_DEFAULT,
      btn.getAttribute("data-copy-fail") || FAIL_DEFAULT
    ];
    btn.textContent = "";
    labels.forEach(function (text, i) {
      var span = document.createElement("span");
      span.textContent = text;
      if (i > 0) span.style.visibility = "hidden";
      btn.appendChild(span);
      spans.push(span);
    });
    btn.setAttribute("data-copy-ready", "1");
    btn.__copySpans = spans;
  }

  function show(btn, idx) {
    btn.__copySpans.forEach(function (span, i) {
      span.style.visibility = i === idx ? "visible" : "hidden";
    });
  }

  function reset(btn) {
    btn.classList.remove("ok");
    btn.classList.remove("fail");
    show(btn, 0);
  }

  function done(btn, cls, label, hold) {
    clearTimeout(btn.__copyTimer);
    btn.classList.remove("ok");
    btn.classList.remove("fail");
    btn.classList.add(cls);
    show(btn, cls === "ok" ? 1 : 2);
    status.textContent = label;
    btn.__copyTimer = setTimeout(function () { reset(btn); }, hold);
  }

  function selectTarget(btn) {
    var id = btn.getAttribute("data-copy-target");
    if (!id) return;
    var el = document.getElementById(id);
    if (!el || !window.getSelection || !document.createRange) return;
    var range = document.createRange();
    range.selectNodeContents(el);
    var sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }

  function copy(text, btn) {
    var okLabel = btn ? (btn.getAttribute("data-copy-ok") || OK_DEFAULT) : OK_DEFAULT;
    var failLabel = btn ? (btn.getAttribute("data-copy-fail") || FAIL_DEFAULT) : FAIL_DEFAULT;

    function ok() {
      if (btn) { prepare(btn); done(btn, "ok", okLabel, HOLD_OK); }
      else status.textContent = okLabel;
    }
    function fail() {
      if (btn) { selectTarget(btn); prepare(btn); done(btn, "fail", failLabel, HOLD_FAIL); }
      else status.textContent = failLabel;
    }
    function fallback() {
      var ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      var did = false;
      try { did = document.execCommand("copy"); } catch (e) {}
      document.body.removeChild(ta);
      if (did) ok(); else fail();
    }
    if (navigator.clipboard && navigator.clipboard.writeText && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(ok, fallback);
    } else {
      fallback();
    }
  }

  /* one delegated listener for every button[data-copy] */
  document.addEventListener("click", function (ev) {
    var target = ev.target;
    var btn = target && target.closest ? target.closest("button[data-copy]") : null;
    if (!btn) return;
    prepare(btn);
    copy(btn.getAttribute("data-copy"), btn);
  });

  /* stack labels at load so nothing shifts on the first click */
  document.querySelectorAll("button[data-copy]").forEach(prepare);

  window.tailroute = window.tailroute || {};
  window.tailroute.copy = copy;
})();
