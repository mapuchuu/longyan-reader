// The app's lookup card, rebuilt for the web from its SwiftUI source (CardChrome.swift,
// Popup.swift, PhraseView in PhraseCard.swift, NuanceView in NotesStore.swift): the same
// spacing scale, text sizes, colors (dark appearance), Liquid Glass surface, springs, row
// highlights, Listen and Copy, resizing and moving. Pin is left out. The content comes from
// the app itself (scripts/site-data.py runs its cards' own state classes), so the picks,
// notes and lists here are exactly what the app shows for these sentences.
(function () {
  "use strict";
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // MARK: Springs

  // SwiftUI's spring(response:dampingFraction:) as a function of time, 0 → 1.
  function springAt(response, damping) {
    const w = (2 * Math.PI) / response, z = damping;
    if (z >= 1) return (t) => 1 - (1 + w * t) * Math.exp(-w * t);
    const wd = w * Math.sqrt(1 - z * z);
    return (t) => 1 - Math.exp(-z * w * t) * (Math.cos(wd * t) + ((z * w) / wd) * Math.sin(wd * t));
  }
  // The same spring as a CSS easing (linear() with 48 stops) and how long it takes to settle.
  const linearOK = window.CSS && CSS.supports && CSS.supports("transition-timing-function", "linear(0, 1)");
  function springCSS(response, damping) {
    const x = springAt(response, damping);
    let T = 0.1;
    while (T < 3 && (Math.abs(1 - x(T)) > 0.001 || Math.abs(1 - x(T + 0.05)) > 0.001)) T += 0.01;
    if (!linearOK) return { easing: "cubic-bezier(.2,.9,.25,1)", duration: T };
    const pts = [];
    for (let i = 0; i <= 48; i++) pts.push(i === 48 ? 1 : +x((T * i) / 48).toFixed(4));
    return { easing: `linear(${pts.join(",")})`, duration: T };
  }
  // cardMotion: every change inside a card. spring(response: 0.34, dampingFraction: 1).
  const MOTION = springCSS(0.34, 1);
  // The card springing in: spring(response: 0.32, dampingFraction: 0.82).
  const APPEAR = springCSS(0.32, 0.82);
  document.documentElement.style.setProperty("--lc-motion", MOTION.easing);
  document.documentElement.style.setProperty("--lc-motion-t", MOTION.duration + "s");
  document.documentElement.style.setProperty("--lc-appear", APPEAR.easing);
  document.documentElement.style.setProperty("--lc-appear-t", APPEAR.duration + "s");
  // The selection chip popping in: spring(response: 0.3, dampingFraction: 0.68).
  const CHIP = springCSS(0.3, 0.68);
  document.documentElement.style.setProperty("--lc-chip", CHIP.easing);
  document.documentElement.style.setProperty("--lc-chip-t", CHIP.duration + "s");

  // A critically damped spring that can be retargeted mid-flight, for the card's height.
  function follower(response, onValue) {
    const w = (2 * Math.PI) / response;
    let x = 0, v = 0, target = 0, raf = 0, last = 0;
    function tick(now) {
      let dt = Math.min(0.05, (now - last) / 1000); last = now;
      while (dt > 0) {
        const h = Math.min(dt, 1 / 240);
        v += (-w * w * (x - target) - 2 * w * v) * h;
        x += v * h; dt -= h;
      }
      if (Math.abs(x - target) < 0.3 && Math.abs(v) < 2) { x = target; v = 0; raf = 0; onValue(x); return; }
      onValue(x);
      raf = requestAnimationFrame(tick);
    }
    return {
      set(to, animated) {
        target = to;
        if (!animated || reduce) { x = to; v = 0; if (raf) cancelAnimationFrame(raf); raf = 0; onValue(x); return; }
        if (!raf) { last = performance.now(); raf = requestAnimationFrame(tick); }
      },
      get value() { return x; },
      get moving() { return raf !== 0; },
    };
  }

  // MARK: Symbols (drawn after SF Symbols' shapes, at 16 units)

  const svg = (body, cls = "") => `<svg class="lc-sym ${cls}" viewBox="0 0 16 16" aria-hidden="true">${body}</svg>`;
  const SYM = {
    speaker: svg('<path class="lc-fill" d="M2.2 6.1h2.2L7.6 3.4c.4-.3.9 0 .9.5v8.2c0 .5-.5.8-.9.5L4.4 9.9H2.2c-.4 0-.7-.3-.7-.7V6.8c0-.4.3-.7.7-.7z"/><path class="lc-wave lc-w1" d="M10.6 6.2c.5.5.7 1.1.7 1.8s-.2 1.3-.7 1.8"/><path class="lc-wave lc-w2" d="M12.5 4.4c1 1 1.5 2.2 1.5 3.6s-.5 2.6-1.5 3.6"/>'),
    copy: svg('<rect x="5.2" y="4.6" width="8.3" height="9.9" rx="1.9"/><path d="M3.4 11.2V3.6c0-1 .8-1.9 1.9-1.9h5.2"/>'),
    check: svg('<path d="M3.4 8.6 6.6 11.8 12.8 4.4"/>'),
    chevronRight: svg('<path d="M6.2 3.4 10.8 8l-4.6 4.6"/>'),
    chevronDown: svg('<path d="M3.4 6.2 8 10.8l4.6-4.6"/>'),
    bubble: svg('<path d="M3.6 2.6h8.8c1 0 1.8.8 1.8 1.8v5.4c0 1-.8 1.8-1.8 1.8H8.2l-3.1 2.4v-2.4H3.6c-1 0-1.8-.8-1.8-1.8V4.4c0-1 .8-1.8 1.8-1.8z"/><path d="M5 5.9h6M5 8.3h4"/>'),
    translate: svg('<path class="lc-fill" d="M2.6 1.8h6.6c.9 0 1.6.7 1.6 1.6v4.4c0 .9-.7 1.6-1.6 1.6H6.4L4.2 11.2V9.4H2.6c-.9 0-1.6-.7-1.6-1.6V3.4c0-.9.7-1.6 1.6-1.6z"/><path class="lc-knock" d="M3.6 3.9h4.6M5.9 3.1v.8M4.5 3.9c.3 1.4 1.3 2.6 2.9 3.1M7.3 3.9c-.3 1.4-1.3 2.6-2.9 3.1"/><path class="lc-fill" d="M11.6 6.4h1.8c.9 0 1.6.7 1.6 1.6v4.2c0 .9-.7 1.6-1.6 1.6h-.9v1.6l-2-1.6H8.6c-.9 0-1.6-.7-1.6-1.6v-1.6h2.2c1.3 0 2.4-1.1 2.4-2.4z"/><path class="lc-knock" d="M9.4 12.6l1.6-4.1 1.6 4.1M9.9 11.4h2.2"/>'),
    globe: svg('<circle class="lc-fill" cx="8" cy="8" r="6.8"/><path class="lc-knock-fill" d="M5.1 3.4c1 .2 1.9.9 2 1.8.1.8-.6 1.2-1.3 1.3-.8.1-1 .9-.6 1.5.5.7.2 1.5-.6 1.6-.8.1-1.4-.6-1.6-1.4C2.8 6.6 3.6 4.4 5.1 3.4zM10.4 8.6c.9-.3 1.9.2 2.1 1.1.2 1-.4 2-1.4 2.4-.9.3-1.7-.2-1.7-1.1 0-.6.4-.9.4-1.4 0-.4.2-.8.6-1z"/>'),
    uturn: svg('<path d="M5.6 3.2 2.6 6.2l3 3"/><path d="M2.8 6.2h6.6c2.2 0 4 1.8 4 4s-1.8 4-4 4H7.6"/>'),
  };

  // MARK: Helpers

  const TONE = { 1: "var(--lc-tone1)", 2: "var(--lc-tone2)", 3: "var(--lc-tone3)", 4: "var(--lc-tone4)", 5: "var(--lc-secondary)" };
  const h = (tag, cls, html) => { const e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; };
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  // Senses.preview: the chosen one, then one for each other reading, then the first others, up to five.
  function preview(senses, chosen, limit = 5) {
    const picked = [];
    if (chosen != null && chosen >= 0 && chosen < senses.length) picked.push(chosen);
    const readings = new Set(picked.map((i) => senses[i].pinyin));
    senses.forEach((s, i) => { if (picked.length < limit && !readings.has(s.pinyin)) { readings.add(s.pinyin); picked.push(i); } });
    senses.forEach((_, i) => { if (picked.length < limit && !picked.includes(i)) picked.push(i); });
    return picked.sort((a, b) => a - b);
  }
  const chars = (text, syl, size) => [...text].map((ch, k) => `<span style="color:${TONE[(syl[k] || {}).tone || 5]}">${esc(ch)}</span>`).join("");
  const pinyin = (syl) => syl.map((s, k) => `<span style="color:${TONE[s.tone] || TONE[5]}">${k ? " " : ""}${esc(s.t)}</span>`).join("");
  const voices = () => (window.speechSynthesis ? speechSynthesis.getVoices().filter((v) => /^zh[-_](CN|Hans)/i.test(v.lang) || v.lang === "zh") : []);
  if (window.speechSynthesis) speechSynthesis.getVoices();

  // Insert and remove a block the way SwiftUI's .opacity.combined(with: .offset(y:)) does,
  // with its height following, so the rows under it move with it.
  function revealBlock(el, dy) {
    // Reopened while closing, it carries on from where it is rather than starting over.
    const from = el._collapse ? el.offsetHeight : 0, fromOpacity = el._collapse ? getComputedStyle(el).opacity : "0";
    clearTimeout(el._collapse); el._collapse = 0;
    if (reduce) { el.style.cssText = ""; return; }
    el.style.cssText = "";
    const end = el.offsetHeight;
    el.style.height = from + "px"; el.style.opacity = fromOpacity; el.style.transform = from ? "none" : `translateY(${dy}px)`; el.style.overflow = "hidden";
    el.getBoundingClientRect();
    el.style.transition = `height var(--lc-motion-t) var(--lc-motion), opacity .3s ease-out .05s, transform var(--lc-motion-t) var(--lc-motion)`;
    el.style.height = end + "px"; el.style.opacity = "1"; el.style.transform = "none";
    clearTimeout(el._reveal);
    el._reveal = setTimeout(() => { el.style.height = ""; el.style.overflow = ""; el.style.transition = ""; }, MOTION.duration * 1000 + 30);
  }
  // Like concealBlock, but the block stays, hidden, to open again with revealBlock.
  function collapseBlock(el, dy) {
    clearTimeout(el._reveal);
    if (reduce) { el.hidden = true; return; }
    el.style.height = el.offsetHeight + "px"; el.style.overflow = "hidden";
    el.getBoundingClientRect();
    el.style.transition = `height var(--lc-motion-t) var(--lc-motion), opacity .16s ease-out, transform var(--lc-motion-t) var(--lc-motion)`;
    el.style.height = "0px"; el.style.opacity = "0"; el.style.transform = `translateY(${dy}px)`;
    clearTimeout(el._collapse);
    el._collapse = setTimeout(() => { el._collapse = 0; el.hidden = true; el.style.cssText = ""; }, MOTION.duration * 1000 + 30);
  }
  function concealBlock(el, dy, done) {
    clearTimeout(el._reveal);
    if (reduce) { el.remove(); done && done(); return; }
    el.style.height = el.offsetHeight + "px"; el.style.overflow = "hidden";
    el.getBoundingClientRect();
    el.style.transition = `height var(--lc-motion-t) var(--lc-motion), opacity .14s ease-out, transform var(--lc-motion-t) var(--lc-motion)`;
    el.style.height = "0px"; el.style.opacity = "0"; el.style.transform = `translateY(${dy}px)`;
    setTimeout(() => { el.remove(); done && done(); }, MOTION.duration * 1000 + 30);
  }
  // contentTransition(.opacity): the new text fades in where the old one was.
  function crossfade(el, html) {
    if (el.innerHTML === html) return;
    el.innerHTML = html;
    if (reduce) return;
    el.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 220, easing: "ease-out" });
  }

  // MARK: The card

  let open = null;          // the card on screen
  const BASE = { word: 360, phrase: 390 };
  const MIN_W = 240, MAX_W = 1000;
  const zoomFor = () => (window.innerWidth < 760 ? 1 : 1.1);

  function makeChrome(kind, z) {
    const el = h("div", "lc-card");
    el.dataset.kind = kind;
    el.setAttribute("role", "dialog");
    el.style.setProperty("--z", z);
    const glass = h("div", "lc-glass");
    const scroll = h("div", "lc-scroll");
    const content = h("div", "lc-content");
    scroll.append(content);
    el.append(glass, scroll);
    return { el, glass, scroll, content };
  }

  // Listen and Copy, fixed over the room the first line keeps for them.
  function makeActions(card, model) {
    const bar = h("div", "lc-actions");
    if (model.speech && voices().length) {
      const b = h("button", "lc-action lc-listen", SYM.speaker);
      b.type = "button"; b.title = `Listen to “${model.speech}”`; b.setAttribute("aria-label", b.title);
      b.addEventListener("click", () => {
        const s = window.speechSynthesis;
        if (b.classList.contains("on")) { s.cancel(); return; }
        s.cancel();
        const u = new SpeechSynthesisUtterance(model.speech);
        u.lang = "zh-CN"; u.voice = voices()[0]; u.rate = 0.9;
        u.onstart = () => b.classList.add("on");
        u.onend = u.onerror = () => b.classList.remove("on");
        s.speak(u);
      });
      bar.append(b);
    }
    const c = h("button", "lc-action lc-copy", `<span class="lc-swap">${SYM.copy}</span>`);
    const label = `Copy “${model.copy.length > 14 ? model.copy.slice(0, 13) + "…" : model.copy}”`;
    const name = (t) => { c.title = t; c.setAttribute("aria-label", t); };
    c.type = "button"; name(label);
    let reset = 0;
    c.addEventListener("click", () => {
      if (navigator.clipboard) navigator.clipboard.writeText(model.copy).catch(() => {});
      swapSymbol(c, SYM.check); c.classList.add("on"); name("Copied");
      clearTimeout(reset);
      reset = setTimeout(() => { swapSymbol(c, SYM.copy); c.classList.remove("on"); name(label); }, 1500);
    });
    bar.append(c);
    card.el.append(bar);
    // The first line keeps room for them, less the 6 pt they reach past the padding.
    const n = bar.children.length;
    card.el.style.setProperty("--slot", n * 26 + (n - 1) * 2 - 6 + "px");
    return bar;
  }
  // .contentTransition(.symbolEffect(.replace.downUp)): the old symbol drops away, the new one
  // drops in from above.
  function swapSymbol(button, icon) {
    const old = button.querySelector(".lc-swap");
    const next = h("span", "lc-swap", icon);
    button.append(next);
    if (reduce) { old.remove(); return; }
    old.animate([{ opacity: 1, transform: "none" }, { opacity: 0, transform: "translateY(4px) scale(.7)" }], { duration: 180, easing: "ease-in", fill: "forwards" }).onfinish = () => old.remove();
    next.animate([{ opacity: 0, transform: "translateY(-4px) scale(.7)" }, { opacity: 1, transform: "none" }], { duration: 260, delay: 60, easing: MOTION.easing, fill: "backwards" });
  }

  // The bottom-right grip and the right edge's bar, shown while the pointer is on the card,
  // and the bands along each side edge and corner that resize it.
  function makeHandles(card) {
    card.el.append(h("div", "lc-grip", '<i></i><i></i><i></i>'), h("div", "lc-grab"));
    for (const e of ["l", "r", "tl", "tr", "bl", "br"]) {
      const band = h("div", `lc-band lc-band-${e}`);
      band.dataset.edge = e;
      card.el.append(band);
    }
  }

  // Opens a card by `anchor` (the selection's rect, in the viewport): below it when it fits
  // there, else on the side with more room, its left edge on the selection's, 8 pt away.
  // With `inline` (an element), the card is built into the page there instead: it stays put,
  // isn't moved or resized, and isn't closed by clicks or scrolling.
  function show(kind, anchor, model, build, inline) {
    if (!inline) close(true);
    const z = zoomFor();
    const card = makeChrome(kind, z);
    card.kind = kind; card.model = model; card.anchor = anchor; card.zoom = z; card.inline = inline || null;
    card.width = Math.min(BASE[kind] * z, window.innerWidth - 16);
    card.el.style.width = card.width + "px";
    if (inline) { card.el.classList.add("lc-inline"); card.el.removeAttribute("role"); inline.replaceChildren(card.el); }
    else document.body.append(card.el);
    build(card);
    card.actions = makeActions(card, model);
    if (!inline) makeHandles(card);
    wire(card);
    card.height = follower(0.34, (v) => { card.el.style.height = v + "px"; updateMask(card); });
    if (inline) {
      // Built into the page, it just hugs its content, so the content's own motion is the
      // only one: nothing lags behind it, spills past the edge or gets faded at the bottom.
      card.maxH = Infinity;
      relayout(card);
      return card;
    }
    place(card, true);
    // Spring in: scale from 0.96 at the edge nearest the selection, 4 pt toward it, as the
    // window fades in over 0.14 s.
    if (!reduce) {
      card.el.animate([{ transform: `translateY(${card.below ? -4 : 4}px) scale(.96)` }, { transform: "none" }],
        { duration: APPEAR.duration * 1000, easing: APPEAR.easing });
      card.el.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 140, easing: "ease-in-out" });
    }
    open = card;
    return card;
  }

  function place(card, first) {
    const vw = window.innerWidth, vh = window.innerHeight, a = card.anchor;
    const natural = card.content.offsetHeight;
    if (first || card.movedTo == null) {
      const below = vh - a.bottom - 16, above = a.top - 16;
      if (first) card.below = below >= Math.max(natural, 320) || below >= above;
      const room = card.below ? below : above;
      card.maxH = Math.max(120, Math.min(room, vh * 0.8));
    }
    const hgt = Math.min(natural, card.maxH);
    card.height.set(hgt, !first);
    let x = card.movedTo ? card.movedTo.x : a.left;
    x = Math.min(Math.max(x, 8), vw - card.width - 8);
    card.el.style.left = x + "px";
    if (card.movedTo) { card.el.style.top = card.movedTo.y + "px"; card.el.style.bottom = ""; }
    else if (card.below) { card.el.style.top = a.bottom + 8 + "px"; card.el.style.bottom = ""; }
    else { card.el.style.bottom = vh - a.top + 8 + "px"; card.el.style.top = ""; }
    card.el.style.transformOrigin = card.below ? "50% 0" : "50% 100%";
    positionActions(card);
  }

  // The actions' centre on the first line's, wherever the card is zoomed.
  function positionActions(card) {
    const slot = card.content.querySelector(".lc-slot");
    if (!slot || !card.actions) return;
    const top = slot.offsetTop + slot.offsetHeight / 2 - 11;
    card.actions.style.top = top + "px";
    card.slotBottom = top + 22;
  }

  // The bottom edge fades while there's more below; scrolled down, content clears the band
  // under the actions and fades in below it.
  function updateMask(card) {
    const s = card.scroll;
    const below = s.scrollHeight - s.clientHeight - s.scrollTop > 2, above = s.scrollTop > 1;
    const z = card.zoom, band = above ? card.slotBottom || 0 : 0;
    const m = `linear-gradient(to bottom, transparent ${band}px, ${above ? "transparent" : "#000"} ${band}px, #000 ${band + 14 * z}px, #000 calc(100% - ${36 * z}px), ${below ? "transparent" : "#000"} 100%)`;
    s.style.webkitMaskImage = m; s.style.maskImage = m;
  }

  function relayout(card, animated = true) {
    if (card.inline) { positionActions(card); card.el.style.height = ""; updateMask(card); return; }
    if (open !== card) return;
    positionActions(card);
    const natural = card.content.offsetHeight;
    card.height.set(Math.min(natural, card.maxH), animated);
  }

  function close(instant) {
    const card = open;
    if (!card) return;
    open = null;
    if (window.speechSynthesis) speechSynthesis.cancel();
    if (card.ro) card.ro.disconnect();
    card.el.style.pointerEvents = "none";
    if (instant || reduce) { card.el.remove(); }
    // Fades out unhurried, settling back a little toward the selection as it goes.
    else card.el.animate([{ opacity: 1, transform: "none" }, { opacity: 0, transform: "scale(.985)" }], { duration: 300, easing: "cubic-bezier(.4, 0, .2, 1)", fill: "forwards" }).onfinish = () => card.el.remove();
    if (card.onClose) card.onClose();
  }

  // Hover, moving, resizing, scrolling, and following the content's size.
  function wire(card) {
    const el = card.el;
    el.addEventListener("pointerenter", () => el.classList.add("hover"));
    el.addEventListener("pointerleave", () => el.classList.remove("hover"));
    card.scroll.addEventListener("scroll", () => updateMask(card), { passive: true });
    card.ro = new ResizeObserver(() => relayout(card, !card.resizing));
    card.ro.observe(card.content);
    if (card.inline) return;

    let press = null;
    el.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return;
      const band = e.target.closest(".lc-band");
      const r = el.getBoundingClientRect();
      press = { x: e.clientX, y: e.clientY, band: band && band.dataset.edge, rect: r, zoom: card.zoom, width: card.width, moving: false, id: e.pointerId };
      if (band) { e.preventDefault(); el.setPointerCapture(e.pointerId); card.resizing = true; el.classList.add("resizing"); }
    });
    el.addEventListener("pointermove", (e) => {
      if (!press || e.pointerId !== press.id) return;
      const dx = e.clientX - press.x, dy = e.clientY - press.y;
      if (press.band) { resize(card, press, dx, dy); return; }
      // Past 4 pt, a press anywhere on the card moves it instead of clicking.
      if (!press.moving && Math.hypot(dx, dy) >= 4 && e.pointerType !== "touch") {
        press.moving = true; el.setPointerCapture(e.pointerId); el.classList.add("moving");
      }
      if (press.moving) {
        card.movedTo = { x: press.rect.left + dx, y: press.rect.top + dy };
        card.wasMoved = true;
        place(card, false);
      }
    });
    const end = (e) => {
      if (!press) return;
      if (press.moving) {
        // Swallow the click that would follow, so the row it started on isn't picked.
        const stop = (ev) => { ev.stopPropagation(); ev.preventDefault(); };
        el.addEventListener("click", stop, { capture: true, once: true });
        setTimeout(() => el.removeEventListener("click", stop, { capture: true }), 0);
      }
      if (press.band) { card.resizing = false; el.classList.remove("resizing"); relayout(card, false); }
      el.classList.remove("moving");
      press = null;
    };
    el.addEventListener("pointerup", end);
    el.addEventListener("pointercancel", end);
    // Double-click a side edge: the default width; a corner: actual size.
    el.addEventListener("dblclick", (e) => {
      const band = e.target.closest(".lc-band");
      if (!band) return;
      if (band.dataset.edge.length === 2) setZoom(card, 1);
      card.width = Math.min(BASE[card.kind] * card.zoom, window.innerWidth - 16);
      el.style.width = card.width + "px";
      place(card, false);
    });
  }

  function setZoom(card, z) {
    card.zoom = z;
    card.el.style.setProperty("--z", z);
  }

  // Side edges set the width, the opposite edge staying put; corners scale the card, text and
  // all, along its diagonal, the opposite corner staying put.
  function resize(card, press, dx, dy) {
    const e = press.band, r = press.rect, vw = window.innerWidth;
    if (!card.movedTo) card.movedTo = { x: r.left, y: r.top };
    if (e.length === 2) {
      const w = r.width, hgt = r.height;
      const outX = e.includes("r") ? dx : -dx, outY = e.includes("b") ? dy : -dy;
      const z = Math.min(2.2, Math.max(0.8, press.zoom * (1 + (outX * w + outY * hgt) / (w * w + hgt * hgt))));
      const f = z / press.zoom;
      setZoom(card, z);
      card.width = Math.min(Math.max(press.width * f, MIN_W), MAX_W);
      card.el.style.width = card.width + "px";
      card.movedTo = { x: e.includes("l") ? r.right - card.width : r.left, y: e.includes("t") ? r.bottom - card.content.offsetHeight : r.top };
    } else if (e === "r") {
      card.width = Math.min(Math.max(press.width + dx, MIN_W), MAX_W, vw - 8 - r.left);
      card.el.style.width = card.width + "px";
    } else {
      card.width = Math.min(Math.max(press.width - dx, MIN_W), MAX_W, r.right - 8);
      card.el.style.width = card.width + "px";
      card.movedTo = { x: r.right - card.width, y: r.top };
    }
    card.wasMoved = true;
    place(card, false);
  }

  // MARK: Pieces of content

  // CardRowStyle: a full-width row that highlights on hover and press, reaching 8 pt past the
  // content's edges.
  function rowButton(cls, inner, onClick) {
    const b = h("button", "lc-row " + cls, inner);
    b.type = "button";
    if (onClick) b.addEventListener("click", onClick);
    return b;
  }

  // SenseLine: number, part of speech when the definition makes it clear, and the definition.
  function senseLine(n, total, s, gloss, size, chosen, dimmed) {
    const pos = s.pos ? `<i class="lc-pos">${esc(s.pos)}</i> ` : "";
    return `<span class="lc-sense ${size}${total >= 10 ? " wide" : ""}"><span class="lc-num">${n}</span>` +
      `<span class="lc-def${chosen ? " chosen" : ""}${dimmed ? " dim" : ""}">${pos}${esc(gloss)}</span></span>`;
  }

  // NuanceView: a small coloured symbol and the kind of note, then the note, on a soft block.
  function nuance(note) {
    const lost = note.tag === "lost_in_translation";
    const el = h("div", "lc-note");
    el.innerHTML = `<div class="lc-note-head"><span class="${lost ? "lost" : "culture"}">${lost ? SYM.translate : SYM.globe}</span>${lost ? "Lost in translation" : "Cultural context"}</div><div class="lc-note-text">${esc(note.text)}</div>`;
    return el;
  }

  // A list of meanings with reading headers, Show All, and the chosen one's checkmark.
  // `opts`: { senses, word, chosen (index or null), listed, showAll, onPick, onToggle, size,
  //           dimUnchosen, noteMarks, headed, bleedV }
  function meaningList(list, opts) {
    const { senses } = opts;
    const all = senses.map((_, i) => i);
    const pv = preview(senses, opts.chosen);
    const collapsed = opts.collapsed || all.filter((i) => (opts.listed ? opts.listed.includes(i) : pv.includes(i)) || i === opts.chosen);
    const shown = opts.showAll ? all : collapsed;
    // Rows are kept by index, so a pick only restyles them and Show All only adds the rest.
    const old = new Map([...list.querySelectorAll(".lc-row[data-i]")].map((r) => [r.dataset.i, r]));
    const frag = [];
    shown.forEach((i, pos) => {
      const s = senses[i];
      if (opts.headed && (pos === 0 || senses[shown[pos - 1]].pinyin !== s.pinyin)) {
        frag.push(h("div", "lc-reading" + (pos === 0 ? " first" : ""), esc(s.marked)));
      }
      const chosen = opts.chosen === i;
      const gloss = opts.listed && opts.listed.includes(i) ? s.short : s.listed;
      const inner = `${senseLine(i + 1, senses.length, s, gloss, opts.size, chosen, opts.dimUnchosen && !chosen)}` +
        `${opts.noteMarks && s.hasNote ? `<span class="lc-notemark">${SYM.bubble}</span>` : ""}<span class="lc-check${chosen ? " on" : ""}">${SYM.check}</span>`;
      let row = old.get(String(i));
      if (row) { row.innerHTML = inner; old.delete(String(i)); }
      else {
        row = rowButton(opts.bleedV === 3 ? "tight" : "", inner, () => opts.onPick(i));
        row.dataset.i = i; row.dataset.fresh = "1";
      }
      row.title = s.readable;
      frag.push(row);
    });
    if (senses.length > collapsed.length) {
      let more = list.querySelector(".lc-more");
      if (!more) more = rowButton("lc-more" + (opts.bleedV === 3 ? " tight" : ""), "", () => opts.onToggle());
      more.innerHTML = `<span>${opts.showAll ? "Show Fewer" : `Show All ${senses.length}`}</span><span class="lc-more-chev${opts.showAll ? " up" : ""}">${SYM.chevronDown}</span>`;
      frag.push(more);
    }
    const leaving = [...old.values()];
    list.replaceChildren(...frag, ...leaving);
    for (const r of list.querySelectorAll('[data-fresh="1"]')) { r.removeAttribute("data-fresh"); if (opts.animate) revealBlock(r, -4); }
    for (const r of leaving) { if (opts.animate) concealBlock(r, -4); else r.remove(); }
  }

  // MARK: Word card (LookupView)

  // `staged`: the card starts as a dictionary would show it, the word and every meaning, none
  // picked, and the returned card's stage(n) brings in the rest: 1 lights every meaning, 2
  // opens the meaning in the sentence under the word, then moves the light onto its row and
  // checks it (and keeps it lit); 3 adds its note. Nothing in it changes size or wraps
  // differently as it goes: the pick isn't set in bold and there's no note mark. A click on
  // a meaning shows it all.
  function openWord(data, anchor, inline, staged) {
    const senses = data.senses, info = data.card;
    const st = {
      choice: info.chosen != null ? { n: info.chosen, meaning: info.meaning } : null,
      suggested: info.chosen != null ? { n: info.chosen, meaning: info.meaning } : null,
      userPicked: false, showAll: false, stage: staged ? 0 : 3, touched: false,
      staged: !!staged, pickShown: !staged,
    };
    let render = null;
    const chosenIndex = () => (st.choice ? st.choice.n - 1 : null);
    const card = show("word", anchor, { speech: info.speech, copy: info.word }, (card) => {
      const c = card.content;
      c.innerHTML = `
        <div class="lc-v m">
          <div class="lc-v xs">
            <div class="lc-head"><span class="lc-hw"></span><span class="lc-py"></span><span class="lc-spacer"></span><span class="lc-slot"></span></div>
            <div class="lc-meaning"><div class="lc-headline"></div><div class="lc-sub">Meaning in this sentence</div></div>
            <div class="lc-status"></div>
          </div>
          <div class="lc-note-slot"></div>
          <div class="lc-v s lc-senses">
            <div class="lc-divider"></div>
            <div class="lc-label">Meanings</div>
            <div class="lc-list"></div>
          </div>
        </div>`;
      const q = (s) => c.querySelector(s);
      let noteKey = null, first = true;
      render = function () {
        const ci = chosenIndex(), picked = st.stage >= 2 && st.pickShown ? ci : null;
        const sense = ci != null && ci >= 0 ? senses[ci] : null;
        const header = !st.userPicked && info.grammar ? info.header : (senses[ci != null && ci >= 0 ? ci : 0] || { syl: info.header }).syl;
        q(".lc-hw").innerHTML = chars(info.word, header);
        crossfade(q(".lc-py"), pinyin(header));
        const headline = q(".lc-headline");
        if (st.choice) crossfade(headline, esc(st.choice.meaning));
        // Staged, the meaning opens in under the word rather than appearing.
        const meaning = q(".lc-meaning"), showMeaning = !!st.choice && st.stage >= 2;
        const open = !meaning.hidden && !meaning._collapse;
        if (first) meaning.hidden = !showMeaning;
        else if (showMeaning && !open) { meaning.hidden = false; revealBlock(meaning, -4); }
        else if (!showMeaning && open) collapseBlock(meaning, -4);
        const sub = q(".lc-sub");
        const contextual = !st.userPicked && info.contextual;
        sub.hidden = !contextual;
        // Back to the model's answer, or why the order is the dictionary's.
        const status = q(".lc-status");
        status.innerHTML = "";
        if (st.userPicked && st.suggested && st.suggested.n !== st.choice.n) {
          const b = h("button", "lc-back", `${SYM.uturn}<span>Back to “${esc(st.suggested.meaning)}”</span>`);
          b.type = "button";
          b.addEventListener("click", () => { st.userPicked = false; st.choice = st.suggested; render(); });
          status.append(b);
        }
        if (info.phase !== "chosen") status.append(h("div", "lc-caption", esc(info.phase)));
        else if (info.viaTranslation && !st.userPicked) status.append(h("div", "lc-caption", "Matched to the sentence translation"));
        status.hidden = !status.childElementCount;
        // The note for the meaning shown, sliding in under the headline.
        const note = st.stage >= 3 && sense && sense.note;
        const key = note ? note.text : null;
        if (key !== noteKey) {
          const slot = q(".lc-note-slot");
          const old = slot.firstElementChild;
          if (old) { if (first) old.remove(); else concealBlock(old, -4); }
          // Wrapped, so the space above it opens and closes with it.
          if (note) { const n = h("div", "lc-note-wrap"); n.append(nuance(note)); slot.append(n); if (!first) revealBlock(n, -4); }
          noteKey = key;
        }
        const showReading = new Set(senses.map((s) => s.pinyin)).size > 1;
        meaningList(q(".lc-list"), {
          senses, chosen: picked, listed: info.grammar ? info.grammar.listed : null, showAll: st.showAll,
          headed: showReading && (!info.grammar || st.showAll), size: "body",
          dimUnchosen: picked != null, noteMarks: !st.staged, animate: !first,
          onPick: (i) => {
            if (st.stage < 3 || !st.pickShown) { clearTimeout(pickTimer); st.stage = 3; st.pickShown = true; st.touched = true; }
            if (st.choice && st.choice.n === i + 1) return;
            if (st.suggested && st.suggested.n === i + 1) { st.userPicked = false; st.choice = st.suggested; }
            else { st.userPicked = true; st.choice = { n: i + 1, meaning: senses[i].short }; }
            render();
          },
          onToggle: () => { st.showAll = !st.showAll; render(); },
        });
        if (st.staged) for (const r of q(".lc-list").querySelectorAll(".lc-row[data-i]")) {
          r.classList.toggle("lc-picked", picked != null && +r.dataset.i === picked);
          r.classList.toggle("lc-every", picked == null && st.stage >= 1);
        }
        first = false;
      };
      render();
    }, inline);
    let pickTimer = 0;
    card.stage = (n) => {
      if (st.touched || n === st.stage || !render) return;
      const was = st.stage;
      st.stage = n;
      clearTimeout(pickTimer);
      if (n < 2) st.pickShown = false;
      render();
      // A beat after the meaning opens in, its row is picked: the check springs in, the row
      // lights up and stays lit, and the other meaning steps back.
      if (was < 2 && n >= 2 && !st.pickShown) {
        pickTimer = setTimeout(() => {
          st.pickShown = true;
          render();
          if (reduce) return;
          const row = card.content.querySelector(".lc-row.lc-picked");
          const check = row && row.querySelector(".lc-check");
          if (check) { check.classList.remove("on"); check.getBoundingClientRect(); check.classList.add("on"); }
          card.content.querySelectorAll(".lc-def.dim").forEach((d) => d.classList.add("lc-dimming"));
        }, reduce ? 0 : 450);
      }
    };
    return card;
  }

  // MARK: Phrase card (PhraseView)

  function openPhrase(data, anchor) {
    const ph = data.phrase, words = data.words;
    const rows = ph.rows.map((r, id) => ({ ...r, id, senses: words[r.text] || [] }));
    const st = { expanded: null, picked: new Map(), showingAll: new Set() };
    const grammarOn = (r) => r.grammar && !st.picked.has(r.id);
    const shownSense = (r) => (st.picked.has(r.id) ? st.picked.get(r.id) : r.shown);
    const gloss = (r) => (grammarOn(r) ? r.grammar : r.senses[shownSense(r)] ? r.senses[shownSense(r)].short : r.gloss);
    const noteOf = (r) => { const s = r.senses[shownSense(r)]; return s && s.note; };
    const canOpen = (r) => r.senses.length > 1 || !!noteOf(r) || !!(!st.picked.has(r.id) && r.here) || !!r.failure;
    return show("phrase", anchor, { speech: ph.text, copy: ph.text }, (card) => {
      const c = card.content;
      c.innerHTML = `
        <div class="lc-v m">
          <div class="lc-v xs">
            <div class="lc-src-line"><span class="lc-src" lang="zh-CN">${esc(ph.text)}</span><span class="lc-slot small"></span></div>
            <div class="lc-translation">${ph.translation ? esc(ph.translation) : ""}</div>
          </div>
          <div class="lc-v s">
            <div class="lc-divider"></div>
            <div class="lc-label">Words</div>
            <div class="lc-rows"></div>
          </div>
        </div>`;
      const list = c.querySelector(".lc-rows");
      const rowEls = rows.map((r) => {
        const wrap = h("div", "lc-prow");
        const btn = rowButton("lc-wordrow", "", () => toggle(r));
        wrap.append(btn);
        list.append(wrap);
        return { r, wrap, btn, detail: null };
      });
      function toggle(r) {
        if (!canOpen(r) && st.expanded !== r.id) return;
        const prev = st.expanded;
        st.expanded = st.expanded === r.id ? null : r.id;
        for (const e of rowEls) if (e.r.id === prev || e.r.id === st.expanded) renderRow(e, true);
      }
      function renderRow(e, animate) {
        const r = e.r, isOpen = st.expanded === r.id, s = r.senses[shownSense(r)];
        const syl = s ? s.syl : r.syl;
        e.btn.innerHTML =
          `<span class="lc-wcol"><span class="lc-wchars" lang="zh-CN">${chars(r.text, syl)}</span><span class="lc-wpy">${pinyin(syl)}</span></span>` +
          `<span class="lc-wgloss${r.dim || (r.guess && !st.picked.has(r.id)) ? " dim" : ""}${isOpen ? " open" : ""}">${esc(gloss(r))}</span>` +
          `${noteOf(r) ? `<span class="lc-notemark">${SYM.bubble}</span>` : ""}` +
          `<span class="lc-chev${isOpen ? " open" : ""}${canOpen(r) ? "" : " none"}">${SYM.chevronRight}</span>`;
        e.btn.disabled = !canOpen(r) && !isOpen;
        if (isOpen && !e.detail) {
          e.detail = h("div", "lc-detail");
          e.wrap.append(e.detail);
          renderDetail(e, false);
          if (animate) revealBlock(e.detail, -6 * card.zoom);
        } else if (!isOpen && e.detail) {
          const d = e.detail; e.detail = null;
          if (animate) concealBlock(d, -6 * card.zoom); else d.remove();
        } else if (isOpen) renderDetail(e, animate);
        sizeColumn();
      }
      // An open row: what the model read, any note, and the meanings to choose from.
      function renderDetail(e, animate) {
        const r = e.r, d = e.detail;
        if (!d.firstChild) d.innerHTML = `<div class="lc-v s"><div class="lc-dstatus"></div><div class="lc-note-slot"></div><div class="lc-list"></div></div>`;
        const status = d.querySelector(".lc-dstatus");
        status.innerHTML = "";
        if (r.failure && !st.picked.has(r.id)) status.append(h("div", "lc-caption", esc(r.failure)));
        else if (r.viaTranslation && !st.picked.has(r.id)) status.append(h("div", "lc-caption", "Matched to the sentence translation"));
        else if (r.here && !st.picked.has(r.id)) status.append(h("div", "lc-here", `<span>In this sentence: </span><b>${esc(r.here)}</b>`));
        const back = st.picked.has(r.id) && (r.grammar || st.picked.get(r.id) !== r.shown);
        if (back) {
          const b = h("button", "lc-back", `${SYM.uturn}<span>Back to “${esc(r.suggested || r.gloss)}”</span>`);
          b.type = "button";
          b.addEventListener("click", () => { st.picked.delete(r.id); renderRow(e, true); });
          status.append(b);
        }
        status.hidden = !status.childElementCount;
        const slot = d.querySelector(".lc-note-slot");
        const note = noteOf(r);
        const key = note ? note.text : "";
        if (slot.dataset.key !== key) {
          slot.dataset.key = key;
          slot.innerHTML = "";
          if (note) slot.append(nuance(note));
        }
        slot.hidden = !note;
        const ci = shownSense(r);
        const listed = null;
        // The rows the app lists before Show All, plus the one picked here.
        const collapsed = (r.collapsed || preview(r.senses, ci)).slice();
        if (!grammarOn(r) && !collapsed.includes(ci) && ci != null && ci >= 0) { collapsed.push(ci); collapsed.sort((a, b) => a - b); }
        const showAll = st.showingAll.has(r.id);
        const shown = showAll ? r.senses.map((_, i) => i) : collapsed;
        meaningList(d.querySelector(".lc-list"), {
          senses: r.senses, chosen: grammarOn(r) ? null : ci, listed, collapsed, showAll,
          headed: new Set(shown.map((i) => r.senses[i].pinyin)).size > 1,
          size: "callout", dimUnchosen: true, noteMarks: false, bleedV: 3, animate,
          onPick: (i) => {
            if (!grammarOn(r) && shownSense(r) === i) return;
            if (!r.grammar && r.shown === i) st.picked.delete(r.id); else st.picked.set(r.id, i);
            renderRow(e, true);
          },
          onToggle: () => { if (showAll) st.showingAll.delete(r.id); else st.showingAll.add(r.id); renderDetail(e, true); },
        });
        if (!r.senses.length) d.querySelector(".lc-list").innerHTML = `<div class="lc-caption">Not in the dictionary</div>`;
      }
      // Every row's meaning starts at the same x: the widest word column.
      function sizeColumn() {
        const cols = rowEls.map((e) => e.btn.querySelector(".lc-wcol"));
        if (cols.some((c) => !c)) return;
        let w = 0;
        for (const col of cols) { col.style.width = ""; w = Math.max(w, col.offsetWidth); }
        list.style.setProperty("--col", w + "px");
        for (const col of cols) col.style.width = "var(--col)";
      }
      for (const e of rowEls) renderRow(e, false);
    });
  }

  // MARK: Peek: a character of the hero's eye, as the top of a word card

  let peekEl = null, peekHide = 0;
  function peek(info, rect) {
    clearTimeout(peekHide);
    if (!info) {
      if (!peekEl) return;
      const el = peekEl;
      peekHide = setTimeout(() => {
        if (peekEl !== el) return;
        peekEl = null;
        if (reduce) el.remove();
        else el.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 280, easing: "cubic-bezier(.4, 0, .2, 1)", fill: "forwards" }).onfinish = () => el.remove();
      }, 120);
      return;
    }
    const fresh = !peekEl;
    if (fresh) {
      const z = window.innerWidth < 760 ? 0.9 : 1;
      const ch = makeChrome("peek", z);
      ch.el.classList.add("lc-peek");
      ch.content.innerHTML = `<div class="lc-v xs"><div class="lc-head"><span class="lc-hw"></span><span class="lc-py"></span></div><div class="lc-headline"></div></div>`;
      document.body.append(ch.el);
      peekEl = ch.el;
    }
    peekEl.querySelector(".lc-hw").innerHTML = chars(info.text, info.syl);
    peekEl.querySelector(".lc-py").innerHTML = pinyin(info.syl);
    peekEl.querySelector(".lc-headline").textContent = info.gloss;
    // Above the word, so the lines under it stay readable; below if there's no room.
    peekEl.classList.toggle("glide", !fresh && !reduce);
    const w = peekEl.offsetWidth, ht = peekEl.offsetHeight;
    const above = rect.top - 10 - ht >= 60;
    peekEl.style.left = Math.min(Math.max(rect.left - 16, 8), window.innerWidth - w - 8) + "px";
    peekEl.style.top = (above ? rect.top - 10 - ht : rect.bottom + 10) + "px";
    peekEl.style.transformOrigin = above ? "16px 100%" : "16px 0";
    const below = !above;
    if (fresh && !reduce) {
      peekEl.animate([{ transform: `translateY(${below ? -4 : 4}px) scale(.96)` }, { transform: "none" }], { duration: APPEAR.duration * 1000, easing: APPEAR.easing });
      peekEl.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 140, easing: "ease-in-out" });
    }
  }

  // Close on a click elsewhere, Esc, or scrolling the page (unless the card was moved aside).
  document.addEventListener("pointerdown", (e) => {
    if (!open || e.target.closest(".lc-card") || (open.keepFor && e.target.closest(open.keepFor))) return;
    close();
  }, true);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && open) close(); });
  window.addEventListener("scroll", () => { if (open && !open.wasMoved) close(); }, { passive: true });
  window.addEventListener("resize", () => { if (open) close(true); });

  window.LongyanCard = {
    openWord, openPhrase, close, peek,
    get open() { return open; },
  };
})();
