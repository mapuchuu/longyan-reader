// Installing, played on a Mac's screen: the four steps one after another, each scene a CSS
// animation started by a class on the desk ("s0" to "s3"). The step it's on is lit in the
// list beside it, with a bar filling as it plays. It plays only while it's on screen, and goes
// round again. Clicking a step shows that one. With motion reduced, nothing plays: each step
// shows its scene as a still.
(function () {
  "use strict";
  const desk = document.getElementById("desk");
  const list = document.getElementById("steps");
  if (!desk || !list) return;
  const screen = desk.parentElement;
  const items = [...list.querySelectorAll("li")];
  const bars = items.map((li) => li.querySelector(".step-bar b"));
  const app = desk.querySelector(".mb-app");
  const progress = document.getElementById("ob-progress");
  const obBar = desk.querySelector(".ob-bar b");
  const moving = document.documentElement.classList.contains("motion");
  const DUR = [5600, 5200, 5600, 7200];
  // Each app's own menus, as its menu bar shows them.
  const APP = [
    ["Finder", "File Edit View Go Window Help"], ["Finder", "File Edit View Go Window Help"],
    ["System Settings", "Edit View Window Help"], ["Longyan Reader", "Edit Window Help"],
  ];
  const menus = desk.querySelector(".mb-menus");

  // The desk is laid out at a fixed width (760 pixels, 620 on a phone) and scaled to the screen.
  new ResizeObserver(() => desk.style.setProperty("--k", screen.clientWidth / desk.offsetWidth)).observe(screen);

  let step = 0, elapsed = 0, prev = 0, visible = false, raf = 0;

  function show(i) {
    step = i; elapsed = 0;
    desk.className = "desk";
    void desk.offsetWidth;
    desk.classList.add("s" + i);
    if (!moving) desk.classList.add("still");
    else if (!visible) desk.classList.add("paused");
    app.textContent = APP[i][0];
    menus.innerHTML = APP[i][1].split(" ").map((m) => `<span>${m}</span>`).join("");
    items.forEach((li, k) => {
      li.classList.toggle("on", k === i);
      li.querySelector("button").setAttribute("aria-pressed", k === i ? "true" : "false");
    });
    bars.forEach((b) => (b.style.transform = "scaleX(0)"));
    paint();
  }

  // The reading model's download, in step 4: the bar and its words move together.
  function paint() {
    const f = Math.min(1, elapsed / DUR[step]);
    bars[step].style.transform = `scaleX(${f})`;
    if (step === 3 && moving) {
      const p = 0.1 + 0.42 * Math.max(0, Math.min(1, (f - 0.64) / 0.36));
      obBar.style.transform = `scaleX(${p})`;
      const left = Math.max(2, Math.round(6 * (1 - p)));
      progress.textContent = `${(p * 2.7).toFixed(1)} of 2.7 GB · About ${left} minutes left`;
    }
  }

  function loop(now) {
    raf = 0;
    if (!visible || document.hidden) return;
    elapsed += Math.min(100, now - prev); prev = now;
    if (elapsed >= DUR[step]) show((step + 1) % DUR.length);
    else paint();
    raf = requestAnimationFrame(loop);
  }
  function start() {
    desk.classList.remove("paused");
    if (!raf) { prev = performance.now(); raf = requestAnimationFrame(loop); }
  }
  function stop() { desk.classList.add("paused"); cancelAnimationFrame(raf); raf = 0; }

  list.addEventListener("click", (e) => {
    const b = e.target.closest("button[data-step]");
    if (b) { show(+b.dataset.step); if (moving && visible) start(); }
  });

  show(0);
  if (!moving) return;
  new IntersectionObserver((entries) => {
    visible = entries[0].isIntersecting;
    if (visible) start(); else stop();
  }, { threshold: 0.35 }).observe(screen);
  document.addEventListener("visibilitychange", () => { if (!document.hidden && visible) start(); });
})();
