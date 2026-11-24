// The demo sentence lifted from the eye, as text to read the way the app does. A click or a
// tap looks up the word under it; otherwise selecting works as it does in any Mac text: drag
// across characters, double-click for a word (and drag on by words), triple-click for the
// sentence, shift-click to extend. Let go and the card
// opens for what the app reads there, while the selection stays exactly where it was made, as
// it does in any app: one character is one character (and its card says which word it's
// part of); a selection that cuts a word in half gets the card for the whole word, as the app
// widens it. The cards are card.js, filled with the app's own answers for every selection the
// sentence allows (scripts/site-data.py).
(function () {
  "use strict";
  const demo = window.LONGYAN && window.LONGYAN.demo;
  const root = document.getElementById("try");
  const story = document.getElementById("story");
  const box = document.getElementById("lines");
  if (!demo || !root || !box) return;
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const Card = () => window.LongyanCard;
  const N = demo.length;

  let lines = [], current = 0, els = [], sel = null;
  const indexOf = (k) => (((current + k) % N) + N) % N;
  const currentEl = () => els.find((e) => e.dataset.k === "0");
  const sizeOf = (el) => parseFloat(el.style.getPropertyValue("--size"));

  // MARK: The lines, where hero.js drew them

  // A word whose meaning here comes with a note (卷, 躺平): it's marked, so the first click
  // can find what's worth clicking.
  function hasNote(d, tk) {
    const card = d.cards[`${tk.range[0]}-${tk.range[1]}`];
    const sense = card && card.chosen != null && (d.words[card.word] || [])[card.chosen - 1];
    return !!(sense && sense.note);
  }

  function build(detail) {
    lines = detail.lines; current = detail.current;
    els = lines.map((l) => {
      const d = demo[indexOf(l.k)];
      const el = document.createElement("div");
      el.className = "line" + (l.k === 0 ? " current" : "");
      el.dataset.k = l.k;
      el.style.left = l.x + "px";
      el.style.top = l.y - l.size * 0.65 + "px";
      el.style.setProperty("--size", l.size + "px");
      const hi = document.createElement("div");
      hi.className = "hi";
      el.append(hi);
      // One character to a cell, grouped into the app's words.
      const ofChar = [];
      d.tokens.forEach((t, ti) => { for (let i = t.range[0]; i < t.range[1]; i++) ofChar[i] = ti; });
      let group = null, gi = -2;
      [...d.sentence].forEach((ch, i) => {
        const ti = ofChar[i] == null ? -1 : ofChar[i];
        if (ti !== gi || ti < 0) {
          group = document.createElement("span");
          group.className = ti < 0 ? "punct" : "w";
          if (ti >= 0) {
            group.dataset.t = ti;
            if (hasNote(d, d.tokens[ti])) group.classList.add("noted");
            if (l.k === 0) { group.tabIndex = 0; group.setAttribute("role", "button"); group.setAttribute("aria-label", `Look up ${d.tokens[ti].text}`); }
          }
          el.append(group);
          gi = ti;
        }
        const c = document.createElement("span");
        c.className = "c"; c.textContent = ch;
        c.style.setProperty("--i", i);
        group.append(c);
      });
      if (l.k !== 0) el.setAttribute("aria-hidden", "true");
      return el;
    });
    box.replaceChildren(...els);
    const l0 = lines[0], lN = lines[lines.length - 1];
    root.style.setProperty("--top-y", l0.y - l0.size * 0.65 + "px");
    root.style.setProperty("--bottom-y", lN.y + lN.size * 0.65 + "px");
    root.style.setProperty("--line-size", l0.size + "px");

    sel = null; press = null;
  }
  document.addEventListener("longyan:lines", (e) => build(e.detail));

  // MARK: Selecting, as text is

  // sel: the settled selection, as the characters the app reads (start..end) and whether
  // that's one word (a word card) or more (a phrase card).
  // `all`: the card goes too, even pinned (the sentences have gone).
  function clear(all) {
    sel = null; press = null;
    for (const el of els) el.querySelector(".hi").classList.remove("on", "snap");
    if (Card() && Card().open) Card().close(false, !!all);
  }

  // Draw the selection over characters a..b of the current line.
  function paint(a, b, snap) {
    const el = currentEl(), size = sizeOf(el), hiEl = el.querySelector(".hi");
    hiEl.classList.toggle("snap", !!snap && !reduce);
    if (b <= a) { hiEl.classList.remove("on"); return; }
    hiEl.style.left = a * size + "px";
    hiEl.style.width = (b - a) * size + "px";
    hiEl.classList.add("on");
  }

  // What the app makes of characters a..b: null for punctuation alone.
  function settle(a, b) {
    const d = demo[indexOf(0)], r = d.selections[`${a}-${b}`];
    if (!r) return null;
    sel = { a, b, start: r[0], end: r[1], word: r[2] === 1, d, el: currentEl() };
    story.classList.add("tried", "has-tried");
    // The way on comes in a moment after the first look-up, once the card has had a look.
    if (!story.classList.contains("can-continue")) setTimeout(() => { placeNext(); story.classList.add("can-continue"); }, 2200);
    return sel;
  }

  const selRect = () => sel.el.querySelector(".hi").getBoundingClientRect();

  function lookUp(inPlace) {
    if (!sel || !Card()) return;
    root.classList.add("used");
    const { d, start, end, word, el } = sel, size = sizeOf(el), box = el.getBoundingClientRect();
    // Where the selection will be once it has settled, not where it is mid-way.
    const r = { left: box.left + sel.a * size, right: box.left + sel.b * size, top: selRect().top, bottom: selRect().bottom, preferBelow: true };
    const key = `${start}-${end}`;
    let opened = null;
    if (word) {
      const info = d.cards[key];
      if (!info) return;
      const senses = d.words[info.word] || [];
      const picks = info.chosen != null && senses.length > 1 && !info.grammar;
      opened = Card().openWord({ senses, card: info, inPlace, onPart: (part) => openPart(part) }, r);
      if (opened && picks) pickNote(opened, () => ({ scope: opened.el, chosen: info.chosen - 1, id: "word" }));
    } else {
      const phrase = d.phrases[key];
      if (phrase) opened = Card().openPhrase({ phrase, words: d.words }, r);
      // On a phrase's card, the same tip on a word's meaning while its list is open.
      if (opened && opened.pickTarget) pickNote(opened, opened.pickTarget);
    }
    if (!opened) return;
    if (!tipCard) tipCard = opened;
    const at = selRect().top, s0 = sel;
    opened.anchorStill = () => sel === s0 && story.classList.contains("is-formed") && Math.abs(selRect().top - at) < 2;
    story.classList.add("card-open");
    const prevClose = opened.onClose;
    opened.onClose = () => { firstClosed = true; if (prevClose) prevClose(); if (!Card().open) story.classList.remove("card-open", "covered"); };
    // The way on to how it picks stays, unless the card is over it.
    const more = root.querySelector(".try-continue");
    (function cover() {
      if (Card().open !== opened || !more) return;
      const a = opened.el.getBoundingClientRect(), b = more.getBoundingClientRect();
      story.classList.toggle("covered", a.left < b.right + 12 && a.right > b.left - 12 && a.top < b.bottom + 12 && a.bottom > b.top - 12);
      requestAnimationFrame(cover);
    })();
  }

  // MARK: The way on

  // "Get Longyan" stays put, two thirds of the way down (and clear of the line): the card
  // opens at its full height over it if it reaches that far, and never moves it.
  let nextTop = Infinity;
  function placeNext() {
    const line = currentEl();
    if (!line) return;
    const r = line.getBoundingClientRect();
    nextTop = Math.round(Math.min(innerHeight - 44 - 56, Math.max(r.bottom + 150, innerHeight * (innerWidth <= 600 ? 0.72 : 0.66))));
    root.style.setProperty("--next-y", nextTop + "px");
  }
  window.addEventListener("resize", placeNext);
  document.addEventListener("longyan:lines", () => requestAnimationFrame(placeNext));
  // A card is never behind the button: while any card (opening, open or fading out) covers
  // its place, the button steps out of the way, and comes back once the card has gone.
  let watching = false;
  function watchCards() {
    const cards = [...document.querySelectorAll("body > .lc-card")];
    const btn = story.querySelector(".try-continue");
    if (!btn || !cards.length) { story.classList.remove("under-card"); watching = false; return; }
    const b = btn.getBoundingClientRect();
    const over = b.height > 0 && cards.some((c) => { const r = c.getBoundingClientRect(); return r.bottom > b.top - 8 && r.top < b.bottom + 8 && r.right > b.left && r.left < b.right; });
    story.classList.toggle("under-card", over);
    requestAnimationFrame(watchCards);
  }
  new MutationObserver(() => { if (!watching && document.querySelector("body > .lc-card")) { watching = true; requestAnimationFrame(watchCards); } }).observe(document.body, { childList: true });

  // MARK: The note beside the card

  // A beat after the card is in, the meaning it picked takes a blue wash, and a small tip
  // springs out beside the card pointing at it: one line, in the card's own glass, with a
  // soft arrow on the row. The row's check stays the only check. The tip is outside the card,
  // so the card stays as the app shows it, and only beside it: where there's no room (a
  // phone), the blue row says it alone. On a phrase's card it's the same, for the word whose
  // meanings are open: it comes once the list has opened, and goes as the list closes.
  const TIP = { gap: 6, arrow: 8, base: 8, r: 12 };
  // The tip and its arrow as one outline, the arrow on the left, pointing at y = ay.
  function tipPath(w, h, ay) {
    const { arrow: A, base: b, r } = TIP, f = (v) => Math.round(v * 100) / 100;
    return `M${A + r},0 H${f(A + w - r)} A${r},${r} 0 0 1 ${f(A + w)},${r} V${f(h - r)} A${r},${r} 0 0 1 ${f(A + w - r)},${f(h)}` +
      ` H${A + r} A${r},${r} 0 0 1 ${A},${f(h - r)} V${f(ay + b)} C${A},${f(ay + b * 0.45)} 1.6,${f(ay + 1.7)} .6,${f(ay + 0.55)}` +
      ` Q0,${f(ay)} .6,${f(ay - 0.55)} C1.6,${f(ay - 1.7)} ${A},${f(ay - b * 0.45)} ${A},${f(ay - b)} V${r} A${r},${r} 0 0 1 ${A + r},0 Z`;
  }
  let note = null;
  // `target()`: where the pick is now, { scope, chosen, id }, or null while there's none to show.
  const OPENING = 260;
  // "Picked from context" is a first-time thing: it shows on the first card opened only.
  let firstClosed = false, tipCard = null;
  function pickNote(card, target) {
    dropNote();
    if (firstClosed || (tipCard && tipCard !== card)) return;
    const el = document.createElement("div");
    el.className = "pick-note";
    el.innerHTML = `<div class="pick-tip">
        <div class="pick-glass"></div>
        <svg class="pick-shape" aria-hidden="true"><defs><linearGradient id="pick-edge" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".24"/><stop offset=".5" stop-color="#fff" stop-opacity=".1"/><stop offset="1" stop-color="#fff" stop-opacity=".07"/></linearGradient></defs><path/></svg>
        <p class="pick-title">Picked from context</p>
      </div>`;
    document.body.append(el);
    const tip = el.firstElementChild, glass = tip.children[0], shape = tip.children[1], outline = shape.querySelector("path");
    const n = { el, card, y: null, raf: 0, from: 0, key: "", id: null, hold: 0 };
    note = n;
    const mark = (row) => card.el.querySelectorAll(".lc-row.here").forEach((r) => { if (r !== row) r.classList.remove("here"); });
    n.unmark = () => mark(null);
    const track = () => {
      n.raf = 0;
      if (note !== n) return;
      if (!card.el.isConnected || Card().open !== card) { dropNote(); return; }
      n.raf = requestAnimationFrame(track);
      const cr = card.el.getBoundingClientRect(), vw = innerWidth, vh = innerHeight, now = performance.now();
      const t = target();
      // A new list (or the card itself) opening: the tip waits until it's in.
      if ((t && t.id) !== n.id) { n.id = t && t.id; n.from = now + (reduce ? 0 : OPENING); }
      const row = t && t.scope.querySelector(`.lc-row[data-i="${t.chosen}"]`);
      const check = row && row.querySelector(".lc-check.on");
      const otherPicked = t && !check && t.scope.querySelector(".lc-check.on");
      // Picked something else: it's the visitor's pick now, not the app's, so neither shows.
      const show = !!check && !otherPicked && now >= n.from;
      mark(show ? row : null);
      if (show) row.classList.add("here");
      // Going: it fades where it stood, rather than following a list that's closing.
      if (!show && el.classList.contains("on")) { el.classList.remove("on"); n.hold = now + 240; }
      if (!show && now < n.hold) return;
      const w = el.offsetWidth, h = el.offsetHeight, reach = TIP.gap + TIP.arrow;
      const side = cr.right + reach + w <= vw - 16 ? "right" : cr.left - reach - w >= 16 ? "left" : null;
      // Not while the row is scrolled out of the card's view: the arrow would point at nothing.
      const rr = row && row.getBoundingClientRect(), sv = card.scroll.getBoundingClientRect();
      const mid = rr && rr.top + rr.height / 2;
      const inView = rr && mid > sv.top + 8 && mid < sv.bottom - 8;
      if (!side || !rr) { el.classList.remove("on"); return; }
      // Centred on the row, kept on screen; the arrow stays on the row's middle either way.
      let ty = Math.max(8, Math.min(mid - h / 2, vh - h - 8));
      // On the row exactly, every frame, so it moves with the card's own motion and never
      // trails it. Placed even while hidden, and shown only once placed on this side, so it
      // comes out where it belongs rather than from wherever it was.
      n.y = ty;
      const x = Math.round(side === "right" ? cr.right + reach : cr.left - reach - w), y = Math.round(n.y);
      const { r, base } = TIP, ay = Math.round(Math.max(r + base, Math.min(mid - y, h - r - base)) * 2) / 2;
      const key = `${w}|${h}|${ay}|${side}`;
      if (key !== n.key) {
        n.key = key;
        const d = tipPath(w, h, ay);
        // The outline is drawn arrow-left; on the left of the card it's mirrored, arrow-right.
        const W = w + TIP.arrow, left = side === "right" ? -TIP.arrow : 0, flip = side === "right" ? "none" : "scaleX(-1)";
        outline.setAttribute("d", d);
        shape.setAttribute("viewBox", `-.5 -.5 ${W + 1} ${h + 1}`);
        Object.assign(shape.style, { left: left - 0.5 + "px", top: "-.5px", width: W + 1 + "px", height: h + 1 + "px", transform: flip });
        Object.assign(glass.style, { left: left + "px", top: "0", width: W + "px", height: h + "px", transform: flip, clipPath: `path("${d}")` });
        // It springs out of its arrow's tip.
        tip.style.transformOrigin = `${side === "right" ? -TIP.arrow : w + TIP.arrow}px ${ay}px`;
      }
      el.dataset.side = side;
      el.style.transform = `translate(${x}px, ${y}px)`;
      el.classList.toggle("on", show && inView && n.side === side);
      n.side = side;
    };
    n.raf = requestAnimationFrame(track);
  }
  function dropNote() {
    if (!note) return;
    const n = note; note = null;
    cancelAnimationFrame(n.raf); n.unmark();
    n.el.classList.remove("on");
    setTimeout(() => n.el.remove(), 300);
  }

  // "Part of 躺平" on a character's card: the word's card replaces this one where it stands,
  // as the app opens it. The selection stays on the character.
  function openPart(part) {
    if (!sel || !part.range) return;
    const [a, b] = part.range;
    sel = { ...sel, start: a, end: b, word: true };
    lookUp(true);
  }

  // Positions on the current line: the gap between characters nearest x (0..length), and
  // the character x is over.
  function caretAt(x) {
    const el = currentEl(), n = [...demo[indexOf(0)].sentence].length;
    return Math.max(0, Math.min(n, Math.round((x - el.getBoundingClientRect().left) / sizeOf(el))));
  }
  function charAt(x) {
    const el = currentEl(), n = [...demo[indexOf(0)].sentence].length;
    return Math.max(0, Math.min(n - 1, Math.floor((x - el.getBoundingClientRect().left) / sizeOf(el))));
  }
  function wordAtChar(ci) {
    const d = demo[indexOf(0)];
    let t = d.tokens.findIndex((tk) => ci >= tk.range[0] && ci < tk.range[1]);
    if (t < 0) t = d.tokens.findIndex((tk) => tk.range[0] > ci);
    return t < 0 ? d.tokens.length - 1 : t;
  }

  // Let go: the card opens for what the app reads there. The selection stays as it was made.
  function release() {
    const p = press;
    press = null;
    if (!p) return;
    const d = demo[indexOf(0)];
    let a, b;
    if (p.mode === "char") { if (p.a === p.b) { clear(); return; } a = Math.min(p.a, p.b); b = Math.max(p.a, p.b); }
    else { a = d.tokens[Math.min(p.a, p.b)].range[0]; b = d.tokens[Math.max(p.a, p.b)].range[1]; }
    if (!settle(a, b)) { clear(); return; }
    paint(a, b);
    lookUp();
  }

  let press = null;   // { mode: "char" | "word", a, b }: anchor and focus, in characters or words
  // Clicks counted here, the way the system counts them, rather than trusting event.detail.
  let last = { t: 0, x: -99, y: -99, n: 0 };
  box.addEventListener("pointerdown", (e) => {
    const line = e.target.closest(".line");
    if (!line || e.button > 0 || line.dataset.k !== "0") return;
    e.preventDefault();
    const now = performance.now();
    const n = now - last.t < 450 && Math.hypot(e.clientX - last.x, e.clientY - last.y) < 6 ? (last.n % 3) + 1 : 1;
    last = { t: now, x: e.clientX, y: e.clientY, n };
    if (Card() && Card().open) Card().close(false, false, true);
    const d = demo[indexOf(0)];
    if (n === 3) {
      press = { mode: "word", a: 0, b: d.tokens.length - 1, id: e.pointerId };
      paint(d.tokens[0].range[0], d.tokens[d.tokens.length - 1].range[1]);
    } else if (n === 2) {
      const t = wordAtChar(charAt(e.clientX));
      press = { mode: "word", a: t, b: t, id: e.pointerId };
      paint(d.tokens[t].range[0], d.tokens[t].range[1]);
    } else if (e.shiftKey && sel) {
      // Extend from the far end of what's selected.
      const c = caretAt(e.clientX), a = c < (sel.a + sel.b) / 2 ? sel.b : sel.a;
      press = { mode: "char", a, b: c, id: e.pointerId };
      paint(Math.min(a, c), Math.max(a, c));
    } else {
      const c = caretAt(e.clientX);
      press = { mode: "char", a: c, b: c, id: e.pointerId, click: true, x: e.clientX, y: e.clientY };
      sel = null;
      paint(c, c);
    }
    box.classList.add("pressing");
    try { box.setPointerCapture(e.pointerId); } catch (_) {}
  });
  box.addEventListener("pointermove", (e) => {
    if (!press || e.pointerId !== press.id) return;
    const d = demo[indexOf(0)];
    if (press.mode === "word") {
      const t = wordAtChar(charAt(e.clientX));
      if (t === press.b) return;
      press.b = t;
      const lo = Math.min(press.a, t), hi = Math.max(press.a, t);
      paint(d.tokens[lo].range[0], d.tokens[hi].range[1]);
    } else {
      const c = caretAt(e.clientX);
      if (c === press.b) return;
      press.b = c;
      paint(Math.min(press.a, c), Math.max(press.a, c));
    }
  });
  box.addEventListener("pointerup", (e) => {
    box.classList.remove("pressing");
    if (!press || e.pointerId !== press.id) return;
    // A click or a tap, without a drag, takes the word under it. A wobble of a few pixels is
    // still a click, even if it crossed into the next character.
    // On punctuation it takes nothing.
    if (press.click && (press.a === press.b || Math.hypot(e.clientX - press.x, e.clientY - press.y) < 4)) {
      const ci = charAt(press.x), d = demo[indexOf(0)];
      if (!d.tokens.some((tk) => ci >= tk.range[0] && ci < tk.range[1])) { press = null; clear(); return; }
      const t = wordAtChar(ci);
      press = { mode: "word", a: t, b: t };
    }
    release();
  });
  box.addEventListener("pointercancel", () => { press = null; box.classList.remove("pressing"); });

  box.addEventListener("keydown", (e) => {
    const w = e.target.closest(".w");
    if (!w || (e.key !== "Enter" && e.key !== " ")) return;
    e.preventDefault();
    const t = +w.dataset.t, d = demo[indexOf(0)];
    if (!settle(d.tokens[t].range[0], d.tokens[t].range[1])) return;
    paint(d.tokens[t].range[0], d.tokens[t].range[1]);
    lookUp();
  });
  // The app's shortcut: ⌃⌥L looks up what's selected.
  document.addEventListener("keydown", (e) => {
    if (e.ctrlKey && e.altKey && e.code === "KeyL" && sel) { e.preventDefault(); lookUp(); }
  });
  // A press anywhere else lets go of the selection, as it would in any text.
  document.addEventListener("pointerdown", (e) => {
    if (!sel || e.target.closest(".lines, .lc-card, .pick-note")) return;
    clear();
  });


  // Leaving the story (back up into the eye) puts it all away.
  new MutationObserver(() => { if (!story.classList.contains("is-formed")) clear(true); })
    .observe(story, { attributes: true, attributeFilter: ["class"] });
  // So does scrolling on past them: a pinned card stays only while its sentence is there.
  window.addEventListener("scroll", () => {
    if (Card() && Card().open && Card().pinned && story.getBoundingClientRect().bottom < innerHeight * 0.5) clear(true);
  }, { passive: true });

  // "Try it" jumps to the formed sentences.
  // A slow glide down to the sentence, so the eye can be seen breaking up into it (the
  // browser's own smooth scroll is over in half a second). Any wheel, touch or key of the
  // visitor's own stops it where it is.
  // A CSS cubic-bezier timing function: x(t) solved for t by Newton's method, then y(t).
  function bezier(x1, y1, x2, y2) {
    const f = (a, b, t) => 3 * a * t * (1 - t) ** 2 + 3 * b * t * t * (1 - t) + t ** 3;
    const df = (a, b, t) => 3 * a * (1 - t) ** 2 + 6 * (b - a) * t * (1 - t) + 3 * (1 - b) * t * t;
    return (u) => {
      let t = u;
      for (let i = 0; i < 8; i++) { const d = df(x1, x2, t); if (Math.abs(d) < 1e-6) break; t -= (f(x1, x2, t) - u) / d; t = Math.min(1, Math.max(0, t)); }
      return f(y1, y2, t);
    };
  }

  // Ease in over `a`, an even pace through the middle, ease out over the last `b`: the speed is a
  // trapezoid with rounded corners, so the middle of the trip (the words in flight) isn't rushed.
  function cruise(a, b) {
    const v = 1 / (1 - a / 2 - b / 2);
    return (u) => u < a ? v * u * u / (2 * a) : u <= 1 - b ? v * (a / 2 + u - a) : 1 - v * (1 - u) ** 2 / (2 * b);
  }

  function glideTo(y, how = {}) {
    const from = window.scrollY, dist = y - from;
    if (reduce || Math.abs(dist) < 2) { window.scrollTo(0, y); return; }
    // Away at once, then a long, gentle settle: cubic-bezier(.25, .4, .1, 1), so it is moving
    // on the first frame after the click and only slows near the end. `story` is for the
    // opening: just as prompt off the mark, but an even pace through the middle and longer in
    // all, so the eye is seen breaking up into the sentence on the way down.
    // `eye`, from "Get Longyan": the sentence turning into the eye is the show, so it's paced as
    // one: slow out of the line (the first words are seen peeling off), an unhurried flight
    // through the middle, and a long settle as the eye fills in and the headline rises (2.9 s).
    const dur = how.eye ? 2900 : how.story ? 2400 : Math.min(1400, 700 + Math.abs(dist) * 0.25), t0 = performance.now();
    const ease = how.eye ? cruise(0.24, 0.34) : how.story ? bezier(0.3, 0.2, 0.3, 1) : bezier(0.25, 0.4, 0.1, 1);
    let stopped = false;
    const stop = () => { stopped = true; };
    const opts = { passive: true, once: true };
    ["wheel", "touchstart", "keydown", "pointerdown"].forEach((ev) => window.addEventListener(ev, stop, opts));
    (function step(now) {
      if (stopped) return;
      const u = Math.min(1, (now - t0) / dur);
      window.scrollTo(0, from + dist * ease(u));
      if (u < 1) requestAnimationFrame(step);
      else ["wheel", "touchstart", "keydown", "pointerdown"].forEach((ev) => window.removeEventListener(ev, stop));
    })(t0);
  }

  // Firefox gives a keyboard click detail 1, like a mouse's, so the pointer is tracked instead.
  document.querySelectorAll("[data-try]").forEach((a) => a.addEventListener("pointerdown", () => { a._pressed = performance.now(); }));
  document.querySelectorAll("[data-try]").forEach((a) => a.addEventListener("click", (e) => {
    if (!window.LongyanHero) return;
    e.preventDefault();
    glideTo(window.LongyanHero.formedY(), { story: true });
    // From the keyboard, carry on into the sentence: its first word takes the focus once it's there.
    if (e.detail === 0 || !(performance.now() - (a._pressed || -1e9) < 1500)) {
      const t0 = performance.now();
      (function focusFirst() {
        const w = story.classList.contains("is-formed") && box.querySelector(".line.current .w");
        if (w) w.focus({ preventScroll: true });
        else if (performance.now() - t0 < 3000) requestAnimationFrame(focusFirst);
      })();
    }
  }));

  // "Get it on your computer", once the sentence has had its turn: on to the eye and the
  // headline, on the slow glide, so the sentence is seen gathering into the eye on the way.
  function toEye() {
    if (window.LongyanHero) glideTo(window.LongyanHero.eyeY(), { eye: true });
  }
  document.querySelectorAll("[data-continue]").forEach((b) => b.addEventListener("click", toEye));
  // "How it works", beside the download: on to the statement, which opens on its first line.
  document.querySelectorAll("[data-statement]").forEach((a) => a.addEventListener("click", (e) => {
    const st = document.getElementById("statement");
    if (!st) return;
    e.preventDefault();
    glideTo(st.getBoundingClientRect().top + window.scrollY);
  }));

  // In-page links: down to where they point, on the same glide. Without script they're plain links.
  document.querySelectorAll("[data-glide]").forEach((a) => a.addEventListener("click", (e) => {
    const t = document.querySelector(a.getAttribute("href"));
    if (!t) return;
    e.preventDefault();
    // To the section's heading, a little below the bar, not its top: the sections open with
    // a lot of night above their headings.
    const head = t.querySelector("h2");
    const y = head ? head.getBoundingClientRect().top - 120 : t.getBoundingClientRect().top;
    glideTo(Math.max(0, y + window.scrollY));
  }));

  // The Windows links, once they're live. Until then their buttons pick Windows in the steps
  // below and go nowhere else. STORE is the Microsoft Store page; INSTALLER the GitHub one.
  const WIN = {
    store: "",
    installer: "",
  };
  document.querySelectorAll("[data-store]").forEach((a) => { if (WIN.store) a.href = WIN.store; });
  document.querySelectorAll("[data-installer]").forEach((a) => { if (WIN.installer) a.href = WIN.installer; });

  // Every download button is for one system. On a computer it picks that system in the
  // steps, the link does the rest (downloads the zip or the installer, or opens the Store),
  // and the page glides to the steps, where a note says it has started, with a way to try
  // again. A phone can't run the app: there the buttons open the share sheet (AirDrop,
  // Messages, Mail) to send this page to a computer, or copy its link where there's no
  // share sheet.
  const phone = matchMedia("(hover: none) and (pointer: coarse)");
  const install = document.getElementById("install");
  const started = document.getElementById("started");
  const toInstall = () => glideTo(install.getBoundingClientRect().top + window.scrollY);
  const PAGE = "https://longyan.app/#install";
  const SHARE = { title: "Longyan Reader", url: PAGE };
  const canShare = !!(navigator.share && (!navigator.canShare || navigator.canShare(SHARE)));
  const NAME = { mac: "Mac", win: "PC" };
  const phoneLabel = (a) => `${canShare ? "Send to" : "Copy link for"} your ${NAME[a.dataset.get] || "computer"}`;
  document.querySelectorAll("[data-download] .for-phone").forEach((l) => { l.textContent = phoneLabel(l.closest("a")); });
  function copy(text) {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text).then(() => true, () => copyOld(text));
    return Promise.resolve(copyOld(text));
  }
  function copyOld(text) {
    const t = document.createElement("textarea");
    t.value = text; t.setAttribute("readonly", ""); t.style.cssText = "position:fixed;opacity:0;top:0;left:0";
    document.body.append(t); t.select();
    let ok = false;
    try { ok = document.execCommand("copy"); } catch (_) {}
    t.remove();
    return ok;
  }
  function copyWithNote(a) {
    const label = a.querySelector(".for-phone");
    copy(PAGE).then((ok) => {
      if (!label) return;
      clearTimeout(a._copied);
      label.textContent = ok ? "Link copied" : "Couldn’t copy. Open longyan.app on your computer";
      a._copied = setTimeout(() => { label.textContent = phoneLabel(a); }, ok ? 2200 : 4000);
    });
  }
  document.querySelectorAll("[data-download]").forEach((a) => a.addEventListener("click", (e) => {
    if (phone.matches) {
      e.preventDefault();
      // Closing the sheet is an AbortError: nothing to do. Any other failure copies instead.
      if (canShare) navigator.share(SHARE).catch((err) => { if (!err || err.name !== "AbortError") copyWithNote(a); });
      else copyWithNote(a);
      return;
    }
    if (window.LongyanInstall && a.dataset.get) window.LongyanInstall.pick(a.dataset.get);
    const live = !a.getAttribute("href").startsWith("#");
    if (live) {
      const store = a.hasAttribute("data-store");
      started.querySelector(".started-done").textContent = store ? "The Microsoft Store is opening." : "Your download has started.";
      started.querySelector(".started-again").textContent = store ? "Didn’t open?" : "Didn’t start?";
      started.querySelector("a").href = a.href;
      install.classList.add("downloading");
    } else e.preventDefault();
    if (!install.contains(a)) setTimeout(toInstall, live ? 300 : 0);
  }));

  if (window.LongyanHero && window.LongyanHero.lines().length) build({ lines: window.LongyanHero.lines(), current: 0 });

  // The statement's card, built into the page for 躺平. With motion it starts with just the
  // meanings and shows more as the statement's lines come in (motion.js); without, all at once.
  const litCard = document.getElementById("lit-card");
  if (litCard && Card()) {
    const d = demo[0], k = Object.keys(d.cards).find((i) => d.cards[i].word === "躺平");
    const staged = document.documentElement.classList.contains("motion");
    const c = k != null && Card().openWord({ senses: d.words["躺平"] || [], card: d.cards[k] }, null, litCard, staged);
    if (c && staged) document.addEventListener("longyan:card-stage", (e) => c.stage(e.detail));
  }
})();
