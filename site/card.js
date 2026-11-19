// The app's lookup card, rebuilt for the web from its SwiftUI source (CardChrome.swift,
// Popup.swift, PhraseView in PhraseCard.swift, NuanceView in NotesStore.swift): the same
// spacing scale, text sizes, colors (dark appearance), Liquid Glass surface, springs, row
// highlights, Listen, Copy and Pin, resizing and moving. The content comes from
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
    pin: svg('<path d="M5.4 2.2h5.2M6.2 2.2v4.1L4.2 9h7.6L9.8 6.3V2.2M8 9v4.8"/>'),
    pinFill: svg('<path class="lc-fill" d="M5.4 1.6h5.2c.3 0 .6.3.6.6s-.3.6-.6.6h-.2v3.3l1.9 2.5c.3.4 0 1-.5 1H8.6v4.2c0 .3-.3.6-.6.6s-.6-.3-.6-.6V9.6H4.6c-.5 0-.8-.6-.5-1l1.9-2.5V2.8h-.6c-.3 0-.6-.3-.6-.6s.3-.6.6-.6z"/>'),
    xmark: svg('<path d="M4.6 4.6l6.8 6.8M11.4 4.6l-6.8 6.8"/>'),
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
  // The best Mandarin voice on this device, as the app picks it: a Premium or Enhanced voice
  // first, then the browser's good ones (Edge's natural voices, Chrome's Google voice), then
  // the system's own Tingting, and the novelty voices (Eddy, Grandma...) only if nothing else.
  const NOVELTY = /^(Eddy|Flo|Grandma|Grandpa|Reed|Rocko|Sandy|Shelley)\b/i;
  const rank = (v) => {
    const id = `${v.name} ${v.voiceURI}`;
    if (NOVELTY.test(v.name)) return 0;
    if (/natural/i.test(id)) return 60;
    if (/premium/i.test(id)) return 50;
    if (/enhanced/i.test(id)) return 40;
    if (/google/i.test(id)) return 30;
    if (/tingting|lilian|li-mu|yue|yu-shu|xiaoxiao|yunxi/i.test(id)) return 20;
    return 10;
  };
  const bestVoice = () => voices().reduce((best, v) => (!best || rank(v) > rank(best) ? v : best), null);
  if (window.speechSynthesis) speechSynthesis.getVoices();

  // While blocks inside a card are opening, closing or changing height, the card's own height
  // follows its content frame by frame (they share one spring) instead of chasing it.
  let flowUntil = 0;
  const flowing = () => { if (!reduce) flowUntil = performance.now() + MOTION.duration * 1000 + 60; };

  // Insert and remove a block the way SwiftUI's .opacity.combined(with: .offset(y:)) does,
  // with its height following, so the rows under it move with it.
  // Its whole box moves: height and vertical padding together, on one spring, measured as a
  // border box. (A block can't be shorter than its padding, so animating the height alone
  // jumps a padded block open by its padding and then holds still until the height passes it.)
  const BOX = "height var(--lc-motion-t) var(--lc-motion), padding-top var(--lc-motion-t) var(--lc-motion), padding-bottom var(--lc-motion-t) var(--lc-motion)";
  function revealBlock(el, dy) {
    flowing();
    // Reopened while closing, it carries on from where it is rather than starting over.
    const closing = !!(el._collapse || el._conceal), cs0 = closing ? getComputedStyle(el) : null;
    const from = closing ? el.offsetHeight : 0, fromOpacity = closing ? cs0.opacity : "0";
    const fromPad = closing ? [cs0.paddingTop, cs0.paddingBottom] : ["0px", "0px"];
    clearTimeout(el._collapse); el._collapse = 0;
    clearTimeout(el._conceal); el._conceal = 0; delete el.dataset.leaving;
    if (reduce) { el.style.cssText = ""; return; }
    // Measured as it will be while it opens, clipped, so a margin inside it counts and the
    // height it opens to is the height it ends at: nothing more appears when it lets go.
    el.style.cssText = "overflow: hidden; box-sizing: border-box";
    const end = el.offsetHeight, cs = getComputedStyle(el), pad = [cs.paddingTop, cs.paddingBottom];
    el.style.height = from + "px"; el.style.paddingTop = fromPad[0]; el.style.paddingBottom = fromPad[1];
    el.style.opacity = fromOpacity; el.style.transform = from ? "none" : `translateY(${dy}px)`;
    el.getBoundingClientRect();
    el.style.transition = `${BOX}, opacity .3s ease-out .05s, transform var(--lc-motion-t) var(--lc-motion)`;
    el.style.height = end + "px"; el.style.paddingTop = pad[0]; el.style.paddingBottom = pad[1];
    el.style.opacity = "1"; el.style.transform = "none";
    clearTimeout(el._reveal);
    el._reveal = setTimeout(() => { el.style.cssText = ""; }, MOTION.duration * 1000 + 30);
  }
  // From its full box to nothing, padding included.
  function shut(el, fade) {
    flowing();
    const h0 = el.offsetHeight;
    el.style.boxSizing = "border-box"; el.style.height = h0 + "px"; el.style.overflow = "hidden";
    el.getBoundingClientRect();
    el.style.transition = `${BOX}, opacity ${fade}s ease-out, transform var(--lc-motion-t) var(--lc-motion)`;
    el.style.height = "0px"; el.style.paddingTop = "0px"; el.style.paddingBottom = "0px"; el.style.opacity = "0";
  }
  // Like concealBlock, but the block stays, hidden, to open again with revealBlock.
  function collapseBlock(el, dy) {
    clearTimeout(el._reveal);
    if (reduce) { el.hidden = true; return; }
    shut(el, 0.16); el.style.transform = `translateY(${dy}px)`;
    clearTimeout(el._collapse);
    el._collapse = setTimeout(() => { el._collapse = 0; el.hidden = true; el.style.cssText = ""; }, MOTION.duration * 1000 + 30);
  }
  // Marked as leaving until it's gone; revealBlock can still take it back.
  function concealBlock(el, dy, done) {
    clearTimeout(el._reveal);
    if (reduce) { el.remove(); done && done(); return; }
    el.dataset.leaving = "1";
    shut(el, 0.14); el.style.transform = `translateY(${dy}px)`;
    clearTimeout(el._conceal);
    el._conceal = setTimeout(() => { el._conceal = 0; el.remove(); done && done(); }, MOTION.duration * 1000 + 30);
  }
  // A slot holding one block at a time (a note): every block not already leaving goes.
  function emptySlot(slot, animate) {
    for (const o of slot.querySelectorAll(":scope > .lc-note-wrap:not([data-leaving])")) { if (animate) concealBlock(o, -4); else o.remove(); }
  }
  // contentTransition(.opacity) under cardMotion: the old content stays where it stood and
  // fades out as the new fades in over it, on the card's spring, and a block's height moves
  // from the old content's to the new's. `content` is HTML, or nodes with a `key` naming them.
  // Without `animate` (a card's first render) it's simply set.
  function crossfade(el, content, animate = true, key = content) {
    const html = typeof content === "string";
    if (el._xfKey === undefined && html && el.innerHTML === content) el._xfKey = content;
    if (el._xfKey === key) return;
    el._xfKey = key;
    const fill = (target) => { if (html) target.innerHTML = content; else target.replaceChildren(...content); };
    const prev = el._xf;
    if (!animate || reduce || !el.getClientRects().length || !el.childNodes.length) {
      if (prev) prev.end(true);
      fill(el); return;
    }
    const box = el.getBoundingClientRect(), cs = getComputedStyle(el);
    const h0 = el.offsetHeight;
    // The leaving layer: what's shown now, as far as it has faded in if it was still arriving.
    let leaving = [], from = 1;
    if (prev) { from = +getComputedStyle(prev.lead || el).opacity; leaving = prev.end(false); }
    const older = [...el.querySelectorAll(":scope > .lc-xf-ghost")];
    if (!prev) leaving = [...el.childNodes].filter((n) => !older.includes(n));
    // Placed exactly over where it was: its first box (content alone) or the content edge (text).
    const first = !html && leaving.find((n) => n.nodeType === 1);
    const at = first ? first.getBoundingClientRect() : null;
    const ghost = h("div", "lc-xf-ghost");
    ghost.setAttribute("aria-hidden", "true");
    ghost.style.cssText = `top:${at ? at.top - box.top : parseFloat(cs.paddingTop)}px; left:${at ? at.left - box.left : parseFloat(cs.paddingLeft)}px; width:${el.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)}px;` +
      (html ? "" : `display:${cs.display === "inline" ? "block" : cs.display}; flex-direction:${cs.flexDirection}; align-items:${cs.alignItems}; gap:${cs.rowGap} ${cs.columnGap};`);
    ghost.append(...leaving);
    // The arriving layer: text gets a wrapper to fade; elements fade one by one.
    let live = null;
    if (html) { live = h("span", "lc-xf-live"); fill(live); el.replaceChildren(live); }
    else { el.replaceChildren(); fill(el); }
    el.classList.add("lc-xf");
    el.append(...older, ghost);
    const T = MOTION.duration * 1000, ease = MOTION.easing;
    const arriving = html ? [live] : [...el.children].filter((c) => c !== ghost && !older.includes(c));
    const anims = arriving.map((n) => n.animate([{ opacity: 0 }, { opacity: 1 }], { duration: T, easing: ease }));
    // A leaving layer finishes on its own, even when newer content takes over meanwhile.
    // It leaves on a shorter run of the same curve than the new arrives on, so the two cross
    // early and the old doesn't linger as a smudge behind the new.
    ghost.animate([{ opacity: from }, { opacity: 0 }], { duration: T * 0.55, easing: ease, fill: "forwards" }).onfinish = () => {
      ghost.remove();
      if (!el._xf && !el.querySelector(":scope > .lc-xf-ghost")) el.classList.remove("lc-xf");
    };
    // A block's height moves with it (text that wraps to more or fewer lines).
    const h1 = el.offsetHeight, sized = cs.display !== "inline" && Math.abs(h1 - h0) > 0.5;
    if (sized) {
      flowing();
      el.style.boxSizing = "border-box"; el.style.height = h0 + "px"; el.getBoundingClientRect();
      el.style.transition = `height ${T}ms ${ease}`; el.style.height = h1 + "px";
    }
    // Lets the arriving content go free: no wrapper, no fade, its own height.
    const settle = () => {
      anims.forEach((a) => a.cancel());
      if (sized) { el.style.height = ""; el.style.transition = ""; el.style.boxSizing = ""; }
      if (html) live.replaceWith(...live.childNodes);
    };
    const state = {
      lead: arriving[0],
      // Settles: the arriving content stays, unwrapped, at its own height. With `snap` the
      // leaving layers go too; without, the content is returned to become the next leaving
      // layer (a newer change arrived), and the older layers fade out as they were.
      end(snap) {
        clearTimeout(state.timer);
        if (el._xf !== state) return [];
        el._xf = null;
        settle();
        const ghosts = [...el.querySelectorAll(":scope > .lc-xf-ghost")];
        if (snap) { ghosts.forEach((g) => g.remove()); el.classList.remove("lc-xf"); return []; }
        return [...el.childNodes].filter((n) => !ghosts.includes(n));
      },
    };
    // When it has settled, only the arriving content is left (the leaving one removes itself).
    state.timer = setTimeout(() => {
      if (el._xf !== state) return;
      el._xf = null; settle();
      if (!el.querySelector(":scope > .lc-xf-ghost")) el.classList.remove("lc-xf");
    }, T + 30);
    el._xf = state;
  }

  // The headword's characters recoloured in place, so a new reading's tones fade across.
  function paintChars(el, text, syl) {
    const list = [...text], kids = [...el.children];
    if (kids.length !== list.length || kids.some((c, k) => c.textContent !== list[k])) { el.innerHTML = chars(text, syl); return; }
    kids.forEach((c, k) => { c.style.color = TONE[(syl[k] || {}).tone || 5]; });
  }

  // A block whose content comes and goes: it opens and closes, and cross-fades when what it
  // says changes while it's showing. Going, it keeps what it said until it has closed.
  function swapBlock(el, nodes, key, animate) {
    if (el.dataset.key === key) return;
    el.dataset.key = key;
    const showing = !el.hidden && !el._collapse;
    if (!nodes.length) {
      if (el._xf) el._xf.end(true);
      if (showing) { if (animate) collapseBlock(el, -4); else el.hidden = true; }
      return;
    }
    if (showing && el.childNodes.length) { crossfade(el, nodes, animate, key); return; }
    if (el._xf) el._xf.end(true);
    el.replaceChildren(...nodes); el._xfKey = key;
    el.hidden = false;
    if (animate) revealBlock(el, -4);
  }

  // MARK: The card

  let open = null;          // the card on screen
  // Pinned, as in the app: the card stays where it is, a new lookup replaces what it shows
  // in place, and only its close button or Esc closes it. Remembered for the visit.
  let pinned = false;
  try { pinned = sessionStorage.getItem("lc-pinned") === "1"; } catch (_) {}
  const BASE = { word: 360, phrase: 390 };
  const MIN_W = 240, MAX_W = 1000;
  const zoomFor = () => (window.innerWidth < 760 ? 1 : 1.15);
  // On a desktop a card that won't fit the room next to its selection is zoomed down until it
  // does, as far as FIT_MIN, so it always shows whole rather than cut off at the window's edge.
  const FIT_MIN = 0.9;
  function fitZoom(card) {
    if (window.innerWidth < 760) return;
    const a = card.anchor, vh = window.innerHeight, z = card.zoom;
    const need = card.content.offsetHeight;
    const below = vh - a.bottom - 24, above = a.top - 24;
    const room = below >= need ? below : Math.max(below, above);
    if (need <= room) return;
    const z2 = Math.max(FIT_MIN, Math.floor((z * room / need) * 100) / 100);
    if (z2 >= z) return;
    card.zoom = z2;
    card.el.style.setProperty("--z", z2);
    card.width = Math.min(BASE[card.kind] * z2, window.innerWidth - 16);
    card.el.style.width = card.width + "px";
  }

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
        u.lang = "zh-CN"; u.voice = bestVoice(); u.rate = 0.9;
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
    if (!card.inline) {
      const p = h("button", "lc-action lc-pin", `<span class="lc-swap">${pinned ? SYM.pinFill : SYM.pin}</span>`);
      const pinName = () => { const t = pinned ? "Unpin: close when you click elsewhere" : "Pin: keep the card here for every lookup"; p.title = t; p.setAttribute("aria-label", t); p.setAttribute("aria-pressed", pinned); };
      p.type = "button"; p.classList.toggle("on", pinned); pinName();
      p.addEventListener("click", () => {
        pinned = !pinned;
        try { sessionStorage.setItem("lc-pinned", pinned ? "1" : "0"); } catch (_) {}
        swapSymbol(p, pinned ? SYM.pinFill : SYM.pin); p.classList.toggle("on", pinned); pinName();
        // Pinned, it stays where it is now, scrolling or not.
        if (pinned && !card.movedTo) { const r = card.el.getBoundingClientRect(); card.movedTo = { x: r.left, y: r.top }; place(card, false); }
        card.el.classList.toggle("pinned", pinned);
      });
      bar.append(p);
      // The close button a pinned card shows while the pointer is on it.
      const x = h("button", "lc-close", SYM.xmark);
      x.type = "button"; x.title = "Close Card"; x.setAttribute("aria-label", "Close Card");
      x.addEventListener("click", () => close(false, true));
      card.el.append(x);
      card.el.classList.toggle("pinned", pinned);
    }
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
  function show(kind, anchor, model, build, inline, inPlace) {
    // A pinned card, or one whose "Part of" row was clicked, is replaced where it stands.
    const prev = !inline && open && (pinned || inPlace) ? open.el.getBoundingClientRect() : null;
    const prevZoom = prev ? open.zoom : null, prevWidth = prev ? open.width : null;
    // Replaced in place, the old card stays under the new one while it fades in (as the
    // app's does), so the spot never shows empty glass; otherwise it makes way quickly.
    const under = prev && !reduce ? open.el : null;
    if (under) { const o = open; open = null; if (o.ro) o.ro.disconnect(); o.el.style.pointerEvents = "none"; if (window.speechSynthesis) speechSynthesis.cancel(); }
    else if (!inline) close(false, true, true);
    const z = prevZoom || zoomFor();
    const card = makeChrome(kind, z);
    card.kind = kind; card.model = model; card.anchor = anchor; card.zoom = z; card.inline = inline || null;
    card.width = prevWidth || Math.min(BASE[kind] * z, window.innerWidth - 16);
    card.el.style.width = card.width + "px";
    if (inline) { card.el.classList.add("lc-inline"); card.el.removeAttribute("role"); inline.replaceChildren(card.el); }
    else {
      document.body.append(card.el);
      card.el.setAttribute("aria-label", model.speech ? `Meaning of ${model.speech}` : "Meaning");
      card.el.tabIndex = -1;
    }
    build(card);
    takeFocus(card);
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
    if (prev) {
      card.movedTo = { x: prev.left, y: prev.top };
      if (pinned) card.wasMoved = true;
      place(card, true);
      card.height.set(prev.height, false);
      open = card;
      relayout(card);
      // The new card's glass is there at once, over the old card, so the old words blur away
      // under it as the new ones fade in sharp on top: never an empty spot, never two sets of
      // words at once. The old card goes once the new words are mostly in.
      if (under) {
        for (const part of [card.scroll, card.actions]) part.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 180, easing: "ease-out" });
        under.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 110, easing: "ease-out", fill: "forwards" }).onfinish = () => under.remove();
      }
      return card;
    }
    fitZoom(card);
    place(card, true);
    // Spring in: scale from 0.96 at the edge nearest the selection, 4 pt toward it, as the
    // window fades in over 0.14 s.
    // A card still fading out of the way is let go first, as the app's next card waits to be
    // measured: one card on screen at a time.
    if (!reduce) {
      const delay = Math.max(0, leavingUntil - performance.now());
      card.el.animate([{ transform: `translateY(${card.below ? -4 : 4}px) scale(.96)` }, { transform: "none" }],
        { duration: APPEAR.duration * 1000, delay, easing: APPEAR.easing, fill: "backwards" });
      card.el.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 140, delay, easing: "ease-in-out", fill: "backwards" });
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
    // The content is already moving on the card's spring: the edge goes with it, frame by
    // frame, rather than trailing it (and clipping the bottom row) on a spring of its own.
    const inStep = animated && performance.now() < flowUntil && !card.height.moving;
    card.height.set(Math.min(natural, card.maxH), animated && !inStep);
  }

  // `quick`: making way for the next card (a new selection, or another lookup), it goes as
  // the app's does, a 0.12 s fade with no movement, so it's gone before the next springs in
  // and the two never move against each other. Dismissed (a click elsewhere, Esc, a scroll),
  // it fades out unhurried, settling back a little toward the selection as it goes.
  let leavingUntil = 0;   // when the card making way for the next will have gone
  function close(instant, force, quick) {
    const card = open;
    if (!card || (pinned && !force)) return;
    open = null;
    if (window.speechSynthesis) speechSynthesis.cancel();
    if (card.ro) card.ro.disconnect();
    card.el.style.pointerEvents = "none";
    if (instant || reduce) { card.el.remove(); }
    else if (quick) {
      leavingUntil = performance.now() + 120;
      card.el.animate([{ opacity: getComputedStyle(card.el).opacity }, { opacity: 0 }], { duration: 120, easing: "ease-out", fill: "forwards" }).onfinish = () => card.el.remove();
    }
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
    // Rows are kept by index and restyled in place, so a pick animates (the check springs in,
    // the others fade back) and Show All only adds the rest. Nodes are only moved when the
    // order changes: taking one out of the page and putting it back cancels its transitions.
    const old = new Map([...list.querySelectorAll(".lc-row[data-i]")].map((r) => [r.dataset.i, r]));
    const oldHeads = new Map([...list.querySelectorAll(".lc-reading[data-key]")].map((r) => [r.dataset.key, r]));
    const want = [];
    shown.forEach((i, pos) => {
      const s = senses[i];
      if (opts.headed && (pos === 0 || senses[shown[pos - 1]].pinyin !== s.pinyin)) {
        const key = `${s.pinyin}|${pos === 0}`;
        let head = oldHeads.get(key);
        if (head) oldHeads.delete(key);
        else { head = h("div", "lc-reading" + (pos === 0 ? " first" : ""), esc(s.marked)); head.dataset.key = key; }
        want.push(head);
      }
      const chosen = opts.chosen === i, dimmed = !!opts.dimUnchosen && !chosen;
      const gloss = opts.listed && opts.listed.includes(i) ? s.short : s.listed;
      const mark = opts.noteMarks && s.hasNote ? `<span class="lc-notemark">${SYM.bubble}</span>` : "";
      const sig = `${gloss}|${mark ? 1 : 0}|${opts.size}`;
      let row = old.get(String(i));
      if (row && row.dataset.sig === sig) {
        old.delete(String(i));
        if (row.dataset.leaving) row.dataset.fresh = "1";   // taken back while closing: it opens again from there
        row.querySelector(".lc-def").classList.toggle("chosen", chosen);
        row.querySelector(".lc-def").classList.toggle("dim", dimmed);
        row.querySelector(".lc-check").classList.toggle("on", chosen);
      } else {
        const inner = senseLine(i + 1, senses.length, s, gloss, opts.size, chosen, dimmed) + mark + `<span class="lc-check${chosen ? " on" : ""}">${SYM.check}</span>`;
        if (row) { row.innerHTML = inner; old.delete(String(i)); if (row.dataset.leaving) row.dataset.fresh = "1"; }
        else {
          row = rowButton(opts.bleedV === 3 ? "tight" : "", inner, () => opts.onPick(i));
          row.dataset.i = i; row.dataset.fresh = "1";
        }
        row.dataset.sig = sig;
      }
      row.title = s.readable;
      want.push(row);
    });
    let more = list.querySelector(".lc-more");
    if (senses.length > collapsed.length) {
      if (!more) {
        more = rowButton("lc-more" + (opts.bleedV === 3 ? " tight" : ""), `<span></span><span class="lc-more-chev">${SYM.chevronDown}</span>`, () => opts.onToggle());
      }
      crossfade(more.firstElementChild, opts.showAll ? "Show Fewer" : `Show All ${senses.length}`, !!opts.animate);
      more.lastElementChild.classList.toggle("up", !!opts.showAll);
      want.push(more);
    } else if (more) { more.remove(); more = null; }
    for (const head of oldHeads.values()) head.remove();
    const leaving = [...old.values()];
    // Put each wanted node in its place, touching only those that aren't there already.
    want.forEach((node, k) => { if (list.children[k] !== node) list.insertBefore(node, list.children[k] || null); });
    for (const r of leaving) if (r.parentNode !== list) list.append(r);
    for (const r of list.querySelectorAll('[data-fresh="1"]')) {
      r.removeAttribute("data-fresh");
      if (opts.animate) revealBlock(r, -4);
      else if (r._conceal) { clearTimeout(r._conceal); r._conceal = 0; delete r.dataset.leaving; r.style.cssText = ""; }
    }
    for (const r of leaving) { if (opts.animate) concealBlock(r, -4); else r.remove(); }
  }

  // MARK: Word card (LookupView)

  // `staged`: the card starts as a dictionary would show it, the word and every meaning, none
  // picked, and the returned card's stage(n) brings in the rest. One light does it: 1 lights
  // every meaning in purple; 2 opens the meaning in the sentence under the word as the
  // light draws in onto that meaning and turns blue, its check springs in and the other
  // meaning steps back; 3 opens the note as the light fades. Until then the card can't be
  // clicked, so nothing breaks the sequence. Nothing in it changes size or re-wraps as it
  // goes: the pick isn't set in bold and there's no note mark.
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
            <div class="lc-head"><span class="lc-hw" lang="zh-CN"></span><span class="lc-py"></span><span class="lc-spacer"></span><span class="lc-slot"></span></div>
            <div class="lc-meaning"><div class="lc-headline"></div><div class="lc-sub">Meaning in this sentence</div></div>
            ${info.partOf ? `<button type="button" class="lc-part" title="Look up ${esc(info.partOf.word)}"><span class="lc-part-of">Part of</span><span class="lc-part-word" lang="zh-CN">${esc(info.partOf.word)}</span><span class="lc-part-py">${esc(info.partOf.pinyin)}</span>${info.partOf.meaning ? `<span class="lc-part-meaning">${esc(info.partOf.meaning)}</span>` : ""}<span class="lc-part-chev">${SYM.chevronRight}</span></button>` : ""}
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
      // A lone character inside a longer word: its row opens that word's card in place.
      if (info.partOf && data.onPart) q(".lc-part").addEventListener("click", () => data.onPart(info.partOf));
      render = function () {
        const ci = chosenIndex(), picked = st.stage >= 2 && st.pickShown ? ci : null;
        const sense = ci != null && ci >= 0 ? senses[ci] : null;
        const header = !st.userPicked && info.grammar ? info.header : (senses[ci != null && ci >= 0 ? ci : 0] || { syl: info.header }).syl;
        // The word keeps its characters; a new reading's tone colours fade across them.
        paintChars(q(".lc-hw"), info.word, header);
        crossfade(q(".lc-py"), pinyin(header), !first);
        const headline = q(".lc-headline");
        if (st.choice) crossfade(headline, esc(st.choice.meaning), !first);
        // Staged, the meaning opens in under the word rather than appearing.
        const meaning = q(".lc-meaning"), showMeaning = !!st.choice && st.stage >= 2;
        const open = !meaning.hidden && !meaning._collapse;
        if (first) meaning.hidden = !showMeaning;
        else if (showMeaning && !open) { meaning.hidden = false; revealBlock(meaning, -4); }
        else if (!showMeaning && open) collapseBlock(meaning, -4);
        // Shown or hidden, these open and close rather than snapping.
        const toggle = (el, show) => {
          const open = !el.hidden && !el._collapse;
          if (first) el.hidden = !show;
          else if (show && !open) { el.hidden = false; revealBlock(el, -4); }
          else if (!show && open) collapseBlock(el, -4);
        };
        toggle(q(".lc-sub"), !st.userPicked && !!info.contextual);
        // Back to the model's answer, or why the order is the dictionary's.
        const status = q(".lc-status");
        const back = st.userPicked && st.suggested && st.suggested.n !== st.choice.n;
        const caption = info.phase !== "chosen" ? info.phase : info.viaTranslation && !st.userPicked ? "Picked to match the translation" : "";
        const statusKey = back || caption ? `${back ? st.suggested.meaning : ""}|${caption}` : "";
        if (statusKey !== status.dataset.key) {
          const parts = [];
          if (back) {
            const b = h("button", "lc-back", `${SYM.uturn}<span>Back to “${esc(st.suggested.meaning)}”</span>`);
            b.type = "button";
            b.addEventListener("click", () => { st.userPicked = false; st.choice = st.suggested; render(); });
            parts.push(b);
          }
          if (caption) parts.push(h("div", "lc-caption", esc(caption)));
          // Opens, closes, or cross-fades from one line to the other (the caption to Back).
          swapBlock(status, parts, statusKey, !first);
        }
        // The note for the meaning shown, sliding in under the headline.
        const note = st.stage >= 3 && sense && sense.note;
        const key = note ? note.text : null;
        if (key !== noteKey) {
          const slot = q(".lc-note-slot");
          emptySlot(slot, !first);
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
            if (st.staged) st.touched = true;
            if (st.choice && st.choice.n === i + 1) return;
            if (st.suggested && st.suggested.n === i + 1) { st.userPicked = false; st.choice = st.suggested; }
            else { st.userPicked = true; st.choice = { n: i + 1, meaning: senses[i].short }; }
            render();
          },
          onToggle: () => { st.showAll = !st.showAll; render(); },
        });
        if (st.staged) placeLight(picked, first);
        first = false;
      };

      // The statement's light: one box behind the meanings, purple over all of them, then blue
      // over the one picked, then gone. It moves and changes colour as one thing; each colour
      // is its own layer so they cross-fade rather than mixing.
      let light = null;
      function placeLight(picked, instant) {
        const senses = q(".lc-senses"), rows = [...q(".lc-list").querySelectorAll(".lc-row[data-i]")];
        if (!rows.length) return;
        if (!light) {
          light = h("div", "lc-light", '<i class="purple"></i><i class="blue"></i>');
          senses.prepend(light);
        }
        const target = picked != null ? rows.find((r) => +r.dataset.i === picked) : null;
        const a = target || rows[0], b = target || rows[rows.length - 1];
        if (instant) light.classList.add("still");
        light.style.top = a.offsetTop + "px";
        light.style.left = a.offsetLeft + "px";
        light.style.width = a.offsetWidth + "px";
        light.style.height = b.offsetTop + b.offsetHeight - a.offsetTop + "px";
        light.classList.toggle("blue", picked != null);
        light.classList.toggle("on", st.stage === 1 || st.stage === 2);
        if (instant) { light.getBoundingClientRect(); light.classList.remove("still"); }
      }
      if (st.staged) {
        placeLight(null, true);
        // Kept in place if the card's width changes.
        new ResizeObserver(() => { const ci = chosenIndex(); placeLight(st.stage >= 2 && st.pickShown ? ci : null, true); }).observe(q(".lc-list"));
      }
      render();
    }, inline, data.inPlace);
    if (staged) { card.el.classList.add("lc-locked"); card.el.inert = true; }
    let unlockTimer = 0;
    card.stage = (n) => {
      if (!render || (n === st.stage && !st.touched)) return;
      // Picked something, then went back up: the story starts over from the card as it was.
      if (st.touched) {
        if (n >= 3) return;
        st.touched = false; st.userPicked = false; st.choice = st.suggested; st.showAll = false;
      }
      st.stage = n;
      clearTimeout(unlockTimer);
      // It can be clicked once its note has opened, and not before.
      // Locked, it can't be reached by Tab either.
      if (n >= 3) unlockTimer = setTimeout(() => { card.el.classList.remove("lc-locked"); card.el.inert = false; }, reduce ? 0 : 500);
      else { card.el.classList.add("lc-locked"); card.el.inert = true; }
      // As the meaning opens in, the light draws in onto it, turning blue, its check springs
      // in and the other meaning steps back, all at once.
      st.pickShown = n >= 2;
      render();
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
        // Built once and changed in place, so a pick cross-fades the meaning and pinyin, the
        // tone colours and dimming fade, and the chevron turns, rather than all of it snapping.
        if (!e.btn.firstChild) {
          e.btn.innerHTML = `<span class="lc-wcol"><span class="lc-wchars" lang="zh-CN"></span><span class="lc-wpy"></span></span>` +
            `<span class="lc-wgloss"></span><span class="lc-notemark" hidden>${SYM.bubble}</span><span class="lc-chev">${SYM.chevronRight}</span>`;
        }
        const part = (c) => e.btn.querySelector(c);
        paintChars(part(".lc-wchars"), r.text, syl);
        crossfade(part(".lc-wpy"), pinyin(syl), animate);
        const g = part(".lc-wgloss");
        g.classList.toggle("dim", !!(r.dim || (r.guess && !st.picked.has(r.id))));
        g.classList.toggle("open", isOpen);
        crossfade(g, esc(gloss(r)), animate);
        const mark = part(".lc-notemark"), hasNote = !!noteOf(r);
        if (mark.hidden === hasNote) {
          mark.hidden = !hasNote;
          if (hasNote && animate && !reduce) mark.animate([{ opacity: 0 }, { opacity: 1 }], { duration: MOTION.duration * 1000, easing: MOTION.easing });
        }
        const chev = part(".lc-chev");
        chev.classList.toggle("open", isOpen);
        chev.classList.toggle("none", !canOpen(r));
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
        // What the model read, or Back, opening, closing and cross-fading as the pick changes.
        const status = d.querySelector(".lc-dstatus");
        const picked = st.picked.has(r.id), parts = [];
        let statusKey = "";
        if (r.failure && !picked) { parts.push(h("div", "lc-caption", esc(r.failure))); statusKey = "f"; }
        else if (r.viaTranslation && !picked) { parts.push(h("div", "lc-caption", "Picked to match the translation")); statusKey = "t"; }
        else if (r.here && !picked) { parts.push(h("div", "lc-here", `<span>In this sentence: </span><b>${esc(r.here)}</b>`)); statusKey = "h"; }
        const back = picked && (r.grammar || st.picked.get(r.id) !== r.shown);
        if (back) {
          const b = h("button", "lc-back", `${SYM.uturn}<span>Back to “${esc(r.suggested || r.gloss)}”</span>`);
          b.type = "button";
          b.addEventListener("click", () => { st.picked.delete(r.id); renderRow(e, true); });
          parts.push(b); statusKey += "b";
        }
        swapBlock(status, parts, statusKey, animate);
        // The note for the meaning shown slides in under it; a new one replaces it as the
        // word card's does, the old closing as the new opens.
        const slot = d.querySelector(".lc-note-slot");
        const note = noteOf(r);
        const key = note ? note.text : "";
        if (slot.dataset.key !== key) {
          slot.dataset.key = key;
          emptySlot(slot, animate);
          if (note) { const n = h("div", "lc-note-wrap"); n.append(nuance(note)); slot.append(n); if (animate) revealBlock(n, -4); }
        }
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
      ch.content.innerHTML = `<div class="lc-v xs"><div class="lc-head"><span class="lc-hw" lang="zh-CN"></span><span class="lc-py"></span></div><div class="lc-headline"></div></div>`;
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
    // A press in the demo's sentence starts the next selection, and so the next card.
    close(false, false, !!e.target.closest(".lines"));
  }, true);
  // Opened from the keyboard, the card takes the focus so Tab reaches its rows and buttons;
  // Esc gives it back to where it came from.
  let keyed = false;
  document.addEventListener("keydown", () => { keyed = true; }, true);
  document.addEventListener("pointerdown", () => { keyed = false; }, true);
  function takeFocus(card) {
    if (!keyed || card.inline) return;
    const from = document.activeElement;
    requestAnimationFrame(() => {
      if (open !== card) return;
      card.returnFocus = from && from !== document.body ? from : null;
      card.el.focus({ preventScroll: true });
    });
  }
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape" || !open) return;
    const back = open.el.contains(document.activeElement) ? open.returnFocus : null;
    close(false, true);
    if (back && back.isConnected) back.focus({ preventScroll: true });
  });
  // A scroll closes the card, unless its selection hasn't moved (the demo's sentence holds
  // still for a while as the page scrolls on).
  window.addEventListener("scroll", () => { if (open && !open.wasMoved && !(open.anchorStill && open.anchorStill())) close(); }, { passive: true });
  window.addEventListener("resize", () => { if (open) close(true, true); });

  window.LongyanCard = {
    openWord, openPhrase, close, peek,
    get open() { return open; },
    get pinned() { return pinned; },
  };
})();
