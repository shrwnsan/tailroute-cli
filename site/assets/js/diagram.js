/* Hero route diagram: plays the 2.4s storyboard once, when half of the
   figure is first visible, and again on demand from the Replay button.
   The keyframes live in diagram.css behind html.js .route.is-playing and
   prefers-reduced-motion: no-preference, so no-JS and reduced-motion
   visitors get the final frame with no JavaScript work at all. */
(function () {
  "use strict";
  var route = document.querySelector(".route");
  if (!route) return;
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
  var replay = route.querySelector(".route-replay");

  function play() {
    if (reduce.matches) return;
    route.classList.add("is-playing");
  }

  if ("IntersectionObserver" in window) {
    var seen = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.intersectionRatio >= 0.5) {
          play();
          seen.disconnect();
        }
      });
    }, { threshold: 0.5 });
    seen.observe(route);
  } else {
    play();
  }

  if (replay) {
    replay.addEventListener("click", function () {
      route.classList.remove("is-playing");
      void route.offsetWidth; /* reflow, so the keyframes restart at 0% */
      play();
    });
  }
  /* A mid-run switch to reduced motion simply stops matching the
     keyframes' media query: the figure snaps to its final frame and the
     Replay button hides. The idle is-playing class is inert there. */
})();
