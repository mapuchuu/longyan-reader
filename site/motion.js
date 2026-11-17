// Scroll motion below the opening: sections rise into place once, the statement lights up
// word by word, the video window lifts out of its backdrop, and the bar tucks away while you
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

  // Split the statement into words (Chinese stays in its own span).
  const lit = document.getElementById("lit");
  let litWords = [];
  if (lit) {
    const parts = [];
    lit.childNodes.forEach((n) => {
      if (n.nodeType === 3) n.textContent.split(/(\s+)/).forEach((w) => parts.push(w.trim() ? `<span class="lw">${w}</span>` : w));
      else { n.classList.add("lw"); parts.push(n.outerHTML); }
    });
    lit.innerHTML = parts.join("");
    litWords = [...lit.querySelectorAll(".lw")];
  }

  const win = document.getElementById("video-window");
  const bar = document.querySelector(".bar");
  let lastY = window.scrollY, ticking = false;

  function update() {
    ticking = false;
    const vh = window.innerHeight, y = window.scrollY;
    if (moving && litWords.length) {
      // Words light up as the paragraph moves from the bottom third to the middle.
      const r = lit.getBoundingClientRect();
      const u = Math.max(0, Math.min(1, (vh * 0.78 - r.top) / (r.height + vh * 0.3)));
      const n = u * litWords.length * 1.05;
      litWords.forEach((w, i) => { w.style.opacity = Math.max(0.16, Math.min(1, n - i)); });
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
