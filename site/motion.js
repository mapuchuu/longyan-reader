// Scroll motion below the opening: sections rise into place once, the statement's lines
// come one at a time, the recording lifts out of its backdrop, and the bar tucks away while you
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

  // Trusted by blinks into being, photon.codes's closing strip played backwards: black, then a
  // thin white line drawn out from the middle, then the band opens up and down from it, the
  // white burning off into the sky as it opens. Tied to the scroll, so going back up closes it.
  const trusted = document.querySelector(".trusted");
  if (trusted && moving) {
    const flash = document.createElement("i");
    flash.className = "blink";
    flash.setAttribute("aria-hidden", "true");
    trusted.append(flash);
    trusted.classList.add("blinking");
    const clamp = (v) => Math.max(0, Math.min(1, v));
    const ease = (v) => 1 - Math.pow(1 - v, 3);
    let queued = false;
    const blink = () => {
      queued = false;
      const r = trusted.getBoundingClientRect(), vh = innerHeight, h = r.height, w = r.width;
      if (r.bottom < -vh || r.top > 2 * vh) return;
      // From the band's middle at the foot of the screen to a little under the screen's middle.
      const c = r.top + h / 2, p = (vh * 0.98 - c) / (vh * 0.48);
      const line = ease(clamp(p / 0.24)), open = ease(clamp((p - 0.24) / 0.76));
      const tall = p <= 0 ? 0 : Math.max(2, open * h), side = (1 - line) * w / 2, cap = (h - tall) / 2;
      trusted.style.clipPath = `inset(${cap.toFixed(1)}px ${side.toFixed(1)}px ${cap.toFixed(1)}px round ${tall < 6 ? 1 : 0}px)`;
      trusted.style.setProperty("--open", open.toFixed(3));
      flash.style.opacity = (1 - clamp(open * 1.7)).toFixed(3);
    };
    const ask = () => { if (!queued) { queued = true; requestAnimationFrame(blink); } };
    window.addEventListener("scroll", ask, { passive: true });
    window.addEventListener("resize", ask);
    blink();
  }

  // The feature tiles' slow drift and little loops only run while a tile is on screen.
  if (moving) {
    const live = new IntersectionObserver((entries) => {
      for (const e of entries) e.target.classList.toggle("live", e.isIntersecting);
    });
    document.querySelectorAll(".glass-box").forEach((el) => live.observe(el));
  }

  // The statement: one line at a time beside the app's card, which shows a little more with
  // each (try.js). The section is pinned for three segments of scrolling, SEG of a screen
  // each, one per line; a bar per segment fills as you scroll through it. The next line only
  // comes once you've scrolled to the end of the one before, and never sooner than CALM after
  // it, so each line and its card change settle before the next. Going back up undoes them.
  const statement = document.getElementById("statement");
  const lines = statement ? [...statement.querySelectorAll(".lit-line")] : [];
  const demo = statement && statement.querySelector(".lit-demo");
  const fills = statement ? [...statement.querySelectorAll(".lit-progress b")] : [];
  const progressEl = statement && statement.querySelector(".lit-progress");
  const SEG = 0.6, CALM = 1200, ENTER = 0.6;

  // The card's appearance, dark unless the switch under it says light; remembered on this device.
  if (demo) {
    const radios = [...demo.querySelectorAll(".appearance [data-appearance]")];
    const set = (mode, save) => {
      demo.classList.toggle("light", mode === "light");
      radios.forEach((b) => { const on = b.dataset.appearance === mode; b.setAttribute("aria-checked", String(on)); b.tabIndex = on ? 0 : -1; });
      if (save) try { localStorage.setItem("lc-appearance-2", mode); } catch (_) {}
    };
    let saved = null;
    try { saved = localStorage.getItem("lc-appearance-2"); } catch (_) {}
    set(saved === "light" ? "light" : "dark", false);
    // Keyboard presses arrive as clicks with no detail; pointers are handled below.
    radios.forEach((b) => b.addEventListener("click", (e) => { if (!e.detail) set(b.dataset.appearance, true); }));
    // Pointers work as on iOS: pressing the chosen segment grabs the thumb, which can then be
    // dragged across and snaps to the side under the finger; pressing the other one dims it,
    // and either is chosen on release over it.
    const sw = demo.querySelector(".appearance");
    let grab = null;
    const sideAt = (x) => { const r = sw.getBoundingClientRect(); return x < r.left + r.width / 2 ? "light" : "dark"; };
    const inside = (e) => { const r = sw.getBoundingClientRect(); return e.clientX > r.left - 24 && e.clientX < r.right + 24 && e.clientY > r.top - 40 && e.clientY < r.bottom + 40; };
    const show = (e) => {
      const side = sideAt(e.clientX), over = inside(e);
      if (grab.held) { sw.classList.toggle("drag-light", side === "light"); sw.classList.toggle("drag-dark", side === "dark"); }
      else radios.forEach((b) => b.classList.toggle("pressed", over && b.dataset.appearance === side));
    };
    sw.addEventListener("pointerdown", (e) => {
      if (e.button) return;
      const mode = demo.classList.contains("light") ? "light" : "dark";
      grab = { id: e.pointerId, held: sideAt(e.clientX) === mode };
      sw.setPointerCapture(e.pointerId);
      sw.classList.toggle("held", grab.held);
      show(e);
    });
    sw.addEventListener("pointermove", (e) => { if (grab && e.pointerId === grab.id) show(e); });
    const end = (e, commit) => {
      if (!grab || e.pointerId !== grab.id) return;
      if (commit && (grab.held || inside(e))) set(sideAt(e.clientX), true);
      grab = null;
      sw.classList.remove("held", "drag-light", "drag-dark");
      radios.forEach((b) => b.classList.remove("pressed"));
    };
    sw.addEventListener("pointerup", (e) => end(e, true));
    sw.addEventListener("pointercancel", (e) => end(e, false));
    // Arrow keys move between the two, as in any radio group.
    sw.addEventListener("keydown", (e) => {
      if (!["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(e.key)) return;
      e.preventDefault();
      const next = demo.classList.contains("light") ? "dark" : "light";
      set(next, true);
      radios.find((b) => b.dataset.appearance === next).focus();
    });
  }
  let seg = -1, segAt = 0, segTimer = 0, cardTimer = 0;

  function setSeg(n) {
    const was = seg;
    seg = n; segAt = performance.now();
    lines.forEach((el, i) => { el.classList.toggle("on", i === n); el.classList.toggle("past", i < n); });
    demo.classList.toggle("on", n >= 0);
    if (progressEl) progressEl.classList.toggle("on", n >= 0);
    // The card follows a moment after its line starts to come in (the first time, once the
    // card itself is in); going back, at once.
    clearTimeout(cardTimer);
    const stage = n + 1;
    cardTimer = setTimeout(() => document.dispatchEvent(new CustomEvent("longyan:card-stage", { detail: stage })), n > was ? (n === 0 ? 700 : 500) : 0);
  }
  // Where the scroll is: -1 before the content comes into view, else 0..3 through the segments.
  function scrollPos(vh) {
    const top = statement.getBoundingClientRect().top;
    if (top > vh * ENTER) return -1;
    return Math.max(0, Math.min(lines.length, -top / (vh * SEG)));
  }
  // The line the scroll asks for, from the one showing: the next once you've scrolled to the
  // end of this one's segment, with a little give going back so a pause right at a boundary
  // doesn't flicker between two lines.
  function wantAt(p) {
    if (p < 0) return -1;
    if (seg < 0) return 0;
    if (p >= seg + 1 && seg < lines.length - 1) return seg + 1;
    if (p < seg - 0.06) return seg - 1;
    return seg;
  }
  function syncStatement(vh) {
    const p = scrollPos(vh);
    fills.forEach((b, i) => { b.style.transform = `scaleX(${p < 0 ? 0 : Math.max(0, Math.min(1, p - i))})`; });
    if (segTimer) return;
    const want = wantAt(p);
    if (want === seg) return;
    const wait = want > seg && seg >= 0 ? Math.max(0, CALM - (performance.now() - segAt)) : 0;
    segTimer = setTimeout(() => {
      segTimer = 0;
      const w = wantAt(scrollPos(window.innerHeight));
      if (w === seg) return;
      setSeg(w > seg ? seg + 1 : w < 0 ? -1 : seg - 1);
      syncStatement(window.innerHeight);
    }, wait);
  }

  const win = document.getElementById("screen");
  const bar = document.querySelector(".bar");
  let lastY = window.scrollY, ticking = false;

  function update() {
    ticking = false;
    const vh = window.innerHeight, y = window.scrollY;
    if (moving && lines.length && demo) syncStatement(vh);
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

  // The recording starts loading a screen and a half before it scrolls in, so it's ready
  // by the time it's seen, and plays only while it's on screen. Until then it shows its poster.
  // HEVC where the browser has it (much smaller for the same sharpness), else H.264.
  const video = document.querySelector("#screen video");
  if (video) {
    // Without motion it doesn't play by itself, so it gets the usual controls instead.
    if (!moving) video.controls = true;
    const fetcher = new IntersectionObserver((entries) => {
      if (!entries[0].isIntersecting) return;
      fetcher.disconnect();
      video.preload = "auto";
      video.querySelectorAll("source[data-src]").forEach((s) => (s.src = s.dataset.src));
      video.load();
    }, { rootMargin: "150% 0px" });
    fetcher.observe(video);
    new IntersectionObserver((entries) => {
      if (entries[0].isIntersecting && moving) video.play().catch(() => {});
      else video.pause();
    }, { threshold: 0.3 }).observe(video);
  }
})();
