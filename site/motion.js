// Scroll motion below the opening: sections rise into place once, the statement's sentences
// fade in one at a time, the video window lifts out of its backdrop, and the bar tucks away while you
// scroll down. The "motion" class is set in the page head unless motion is reduced.
(function () {
  "use strict";
  const root = document.documentElement;
  const moving = root.classList.contains("motion");

  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      e.target.classList.add("in");
      io.unobserve(e.target);
    }
  }, { rootMargin: "0px 0px -12% 0px" });
  document.querySelectorAll("[data-reveal]").forEach((el) => io.observe(el));

  // The statement: the card, then its three sentences, in order. How many should be showing
  // comes from the scroll; they're shown (or hidden, going back up) one step at a time, a
  // beat apart, so even a fast scroll brings them in one after another.
  const statement = document.getElementById("statement");
  const steps = statement ? [statement.querySelector(".lit-demo"), ...statement.querySelectorAll(".lit-line")].filter(Boolean) : [];
  let shown = 0, want = 0, stepper = 0;
  function step() {
    stepper = 0;
    if (shown === want) return;
    // The card comes in with the first sentence.
    if (want > shown) { shown++; if (shown === 1 && steps.length > 1) shown = 2; }
    else { shown--; if (shown === 1) shown = 0; }
    steps.forEach((el, i) => el.classList.toggle("on", i < shown));
    if (shown !== want) stepper = setTimeout(step, 420);
    syncCard();
  }

  // The card beside them shows a little more with each line: every meaning with the first, the
  // one picked with the second, its note with the third (try.js). Each change waits for its
  // line to start fading in, then takes its time, so they come one after another. On a narrow
  // screen, where the card sits below the lines, each also waits for the card to come up the
  // screen, so it happens where you can see it.
  const demo = statement && statement.querySelector(".lit-demo");
  let cardShown = 1, cardWant = 1, cardTimer = 0;
  function cardStep() {
    cardTimer = 0;
    if (cardShown === cardWant) return;
    cardShown += cardWant > cardShown ? 1 : -1;
    document.dispatchEvent(new CustomEvent("longyan:card-stage", { detail: cardShown }));
    if (cardShown !== cardWant) cardTimer = setTimeout(cardStep, cardWant > cardShown ? 1000 : 250);
  }
  function syncCard() {
    if (!demo) return;
    let n = shown < 2 ? 1 : Math.min(3, shown - 1);
    if (getComputedStyle(statement.firstElementChild).position !== "sticky") {
      const top = demo.getBoundingClientRect().top / window.innerHeight;
      n = Math.min(n, top < 0.5 ? 3 : top < 0.68 ? 2 : 1);
    }
    cardWant = n;
    if (cardWant !== cardShown && !cardTimer) cardTimer = setTimeout(cardStep, cardWant > cardShown ? 550 : 0);
  }
  function wantSteps(vh) {
    if (!steps.length) return 0;
    const r = statement.getBoundingClientRect();
    if (getComputedStyle(statement.firstElementChild).position === "sticky") {
      // Pinned: the first as soon as the content comes into view, just as the demo sentence
      // above leaves, so there's no empty screen between them; the rest a third of a screen
      // of scrolling apart.
      const d = vh * 0.55 - r.top;
      return d < 0 ? 0 : Math.min(steps.length, 2 + Math.floor(d / (vh * 0.33)));
    }
    // In the flow: each as it comes up into view.
    let n = 0;
    steps.forEach((el, i) => { if (el.getBoundingClientRect().top < vh * 0.88) n = Math.max(n, i + 1); });
    // The card sits under the sentences on a narrow screen; it comes in with the first.
    if (n === 1) n = 2;
    return n;
  }

  const win = document.getElementById("video-window");
  const bar = document.querySelector(".bar");
  let lastY = window.scrollY, ticking = false;

  function update() {
    ticking = false;
    const vh = window.innerHeight, y = window.scrollY;
    if (moving && steps.length) {
      want = wantSteps(vh);
      if (want !== shown && !stepper) step();
      syncCard();
    }
    if (moving && win) {
      const r = win.getBoundingClientRect();
      const u = Math.max(0, Math.min(1, (vh - r.top) / (vh * 0.75)));
      const e = 1 - Math.pow(1 - u, 3);
      win.style.transform = `translateY(${(1 - e) * 90}px) scale(${0.94 + 0.06 * e})`;
    }
    if (bar) {
      const down = y > lastY + 4, up = y < lastY - 4;
      if (down && y > 200) bar.classList.add("tucked");
      else if (up || y < 200) bar.classList.remove("tucked");
      bar.classList.toggle("solid", y > 20);
      lastY = y;
    }
  }
  window.addEventListener("scroll", () => { if (!ticking) { ticking = true; requestAnimationFrame(update); } }, { passive: true });
  window.addEventListener("resize", update);
  update();

  // The recording, once it exists, loads and plays only while it's visible.
  const video = document.querySelector("video[data-src]");
  if (video && video.dataset.src) {
    new IntersectionObserver((entries) => {
      const on = entries[0].isIntersecting;
      if (on && !video.src) {
        video.src = video.dataset.src;
        video.addEventListener("loadeddata", () => video.classList.add("ready"), { once: true });
      }
      if (on && moving) video.play().catch(() => {});
      else video.pause();
    }, { threshold: 0.3 }).observe(video);
  }
})();
