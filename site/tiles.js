// The tones tile's mesh: one light behind each column of the panel, wherever the tile's
// width puts the columns.
(function () {
  "use strict";
  const box = document.querySelector(".stage-tones"), cols = box && box.querySelectorAll(".ui-tones > div");
  const mesh = box && box.querySelector(".tone-mesh");
  if (!mesh || !cols || cols.length < 4) return;
  function place() {
    const b = box.getBoundingClientRect();
    if (!b.width) return;
    cols.forEach((c, i) => { const r = c.getBoundingClientRect(); mesh.style.setProperty(`--x${i + 1}`, ((r.left + r.right) / 2 - b.left).toFixed(1) + "px"); });
  }
  new ResizeObserver(place).observe(box);
  place();
})();

// The feature tiles' one scripted motion: in History a new word arrives on top every few
// seconds while the tile is on screen (motion.js marks it "live"). The rest is CSS.
(function () {
  "use strict";
  if (!document.documentElement.classList.contains("motion")) return;
  const box = document.querySelector(".stage-history");
  const rows = box && box.querySelector(".history-rows");
  if (!rows) return;
  setInterval(() => {
    if (!box.classList.contains("live") || document.hidden) return;
    const row = rows.lastElementChild;
    row.classList.remove("arrive");
    row.style.setProperty("--h", rows.firstElementChild.offsetHeight + "px");
    rows.prepend(row);
    void row.offsetWidth;
    row.classList.add("arrive");
  }, 2800);
})();

// "Trusted by …", typed in when it comes into view, at a person's pace: quick runs inside a
// word, a beat at a space, a longer one at a comma, now and then a hesitation. The highlight
// and the pills grow with the caret (the layout never moves; the clips do).
(() => {
  const h = document.querySelector(".trusted-sel");
  if (!h || !("IntersectionObserver" in window) || matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  const steps = [], pills = [], sels = [...h.querySelectorAll(".sel")];
  const wrap = (node, pill) => {
    for (const n of [...node.childNodes]) {
      if (n.nodeType === 3) {
        const frag = document.createDocumentFragment();
        for (const c of n.data) {
          const s = document.createElement("span");
          s.className = "ch wait"; s.textContent = c;
          frag.append(s); steps.push({ el: s, c, pill });
        }
        if (pill) { const pw = document.createElement("span"); pw.className = "pw"; pw.append(frag); n.replaceWith(pw); }
        else n.replaceWith(frag);
      } else if (n.classList && n.classList.contains("pill")) {
        pills.push(n); steps.push({ pill: n, start: true }); wrap(n, n);
      } else if (n.classList && n.classList.contains("sel")) wrap(n, null);
    }
  };
  wrap(h, null);
  const caret = document.createElement("i");
  caret.className = "caret"; caret.setAttribute("aria-hidden", "true");
  h.querySelector(".knob-a").after(caret);
  h.classList.add("js", "typing");

  // One highlight layer per line of the selection, where the browser drew the line's own.
  let layers = [], done = false, current = null;
  function build() {
    layers.forEach((l) => l.el.remove());
    const o = h.getBoundingClientRect();
    layers = sels.flatMap((sel) => [...sel.getClientRects()].map((r) => {
      const el = document.createElement("i");
      el.className = "hl"; el.setAttribute("aria-hidden", "true");
      Object.assign(el.style, { left: r.left - o.left + "px", top: r.top - o.top + "px", width: r.width + "px", height: r.height + "px" });
      h.prepend(el);
      h.style.setProperty("--line-h", r.height + "px");
      return { el, top: r.top - o.top, bottom: r.bottom - o.top, left: r.left - o.left, width: r.width };
    }));
    clip();
  }
  // Each layer to just past the caret, or all of it once the caret's past its line.
  function clip() {
    const o = h.getBoundingClientRect(), c = caret.getBoundingClientRect();
    const cx = c.left - o.left, cy = (c.top + c.bottom) / 2 - o.top, pad = parseFloat(getComputedStyle(h).fontSize) * 0.16;
    let past = !done;
    for (const l of layers) {
      if (done) { l.el.style.clipPath = ""; continue; }
      const on = cy >= l.top && cy <= l.bottom;
      if (on) { l.el.style.clipPath = `inset(0 ${Math.max(0, l.width - (cx - l.left) - pad)}px 0 0 round .14em)`; past = false; }
      else l.el.style.clipPath = past ? "" : "inset(0 100% 0 0)";
    }
    for (const p of pills) {
      if (done || (p !== current && p.dataset.typed)) { p.style.clipPath = ""; p.style.visibility = ""; continue; }
      if (p !== current) { p.style.visibility = "hidden"; continue; }
      const r = p.getBoundingClientRect(), ps = parseFloat(getComputedStyle(p).paddingRight);
      p.style.visibility = "";
      p.style.clipPath = `inset(-12px ${Math.max(0, r.right - c.left - ps)}px -24px -12px round .6em)`;
    }
  }
  build();
  // Again whenever the lines move (a font coming in, a resize).
  new ResizeObserver(() => build()).observe(h);
  if (document.fonts) document.fonts.ready.then(build);

  // Seeded, so it types the same way every time.
  let seed = 7;
  const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
  let i = 0;
  function next() {
    if (i >= steps.length) {
      if (current) current.dataset.typed = 1;
      done = true; clip(); caret.classList.remove("busy");
      setTimeout(() => { caret.remove(); h.classList.remove("typing"); }, 900);
      return;
    }
    const s = steps[i++];
    if (s.start) {
      if (current) current.dataset.typed = 1;
      current = s.pill;
      s.pill.querySelector(".pw").prepend(caret);
      clip();
      return setTimeout(next, 150 + rnd() * 60);
    }
    if (!s.pill && current) { current.dataset.typed = 1; current = null; }
    s.el.classList.remove("wait");
    s.el.after(caret);
    clip();
    const n = steps[i], c = s.c;
    let d = 34 + rnd() * 38;
    if (c === ",") d = 230 + rnd() * 110;
    else if (c === " ") d = 70 + rnd() * 60;
    else if (n && n.start) d = 110 + rnd() * 50;
    else if (rnd() < 0.06) d += 170;
    setTimeout(next, d);
  }
  const io = new IntersectionObserver((es) => {
    if (!es[0].isIntersecting) return;
    io.disconnect();
    setTimeout(() => { caret.classList.add("busy"); next(); }, 400);
  }, { threshold: 0.9, rootMargin: "0px 0px -12% 0px" });
  io.observe(h);
})();
