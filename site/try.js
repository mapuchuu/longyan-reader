// The demo sentence lifted from the eye, as text to read the way the app does. Selecting
// works as it does in any Mac text: drag across characters, double-click for a word (and drag
// on by words), triple-click for the sentence, shift-click to extend. Let go and the card
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
    story.classList.add("tried");
    return sel;
  }

  const selRect = () => sel.el.querySelector(".hi").getBoundingClientRect();

  function lookUp(inPlace) {
    if (!sel || !Card()) return;
    root.classList.add("used");
    const { d, start, end, word, el } = sel, size = sizeOf(el), box = el.getBoundingClientRect();
    // Where the selection will be once it has settled, not where it is mid-way.
    const r = { left: box.left + sel.a * size, right: box.left + sel.b * size, top: selRect().top, bottom: selRect().bottom };
    const key = `${start}-${end}`;
    if (word) {
      const card = d.cards[key];
      if (!card) return;
      Card().openWord({ senses: d.words[card.word] || [], card, inPlace, onPart: (part) => openPart(part) }, r);
    } else {
      const phrase = d.phrases[key];
      if (phrase) Card().openPhrase({ phrase, words: d.words }, r);
    }
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
    if (Card() && Card().open) Card().close();
    const d = demo[indexOf(0)];
    const touch = e.pointerType === "touch";
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
      press = { mode: "char", a: c, b: c, id: e.pointerId, touch, x: e.clientX };
      sel = null;
      paint(c, c);
    }
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
    if (!press || e.pointerId !== press.id) return;
    // A tap on a phone takes the word under it; a click on a Mac only places the caret.
    if (press.touch && press.a === press.b) {
      const t = wordAtChar(charAt(press.x));
      press = { mode: "word", a: t, b: t };
    }
    release();
  });
  box.addEventListener("pointercancel", () => { press = null; });

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
    if (!sel || e.target.closest(".lines, .lc-card")) return;
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

  function glideTo(y) {
    const from = window.scrollY, dist = y - from;
    if (reduce || Math.abs(dist) < 2) { window.scrollTo(0, y); return; }
    // Away at once, then a long, gentle settle: cubic-bezier(.25, .4, .1, 1), so it is moving
    // on the first frame after the click and only slows near the end.
    const dur = Math.min(1400, 700 + Math.abs(dist) * 0.25), t0 = performance.now();
    const ease = bezier(0.25, 0.4, 0.1, 1);
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

  document.querySelectorAll("[data-try]").forEach((a) => a.addEventListener("click", (e) => {
    if (!window.LongyanHero) return;
    e.preventDefault();
    glideTo(window.LongyanHero.formedY());
    // From the keyboard, carry on into the sentence: its first word takes the focus once it's there.
    if (e.detail === 0) {
      const t0 = performance.now();
      (function focusFirst() {
        const w = story.classList.contains("is-formed") && box.querySelector(".line.current .w");
        if (w) w.focus({ preventScroll: true });
        else if (performance.now() - t0 < 3000) requestAnimationFrame(focusFirst);
      })();
    }
  }));

  // "How it picks the meaning", once the sentence has had its turn: on to the statement, the
  // same slow glide.
  // The statement's first line comes in as its pinned stretch reaches the top.
  document.querySelectorAll("[data-continue]").forEach((b) => b.addEventListener("click", () => {
    const st = document.getElementById("statement");
    if (st) glideTo(st.getBoundingClientRect().top + window.scrollY);
  }));

  // The hero's Download for Mac: down to the closing, where the download button is, with what
  // it needs (Apple silicon, macOS 15), on the same glide. Without script it's a plain link.
  document.querySelectorAll("[data-glide]").forEach((a) => a.addEventListener("click", (e) => {
    const t = document.querySelector(a.getAttribute("href"));
    if (!t) return;
    e.preventDefault();
    glideTo(t.getBoundingClientRect().top + window.scrollY);
  }));

  // After a download starts, point to the install steps.
  document.querySelectorAll("[data-download]").forEach((a) => a.addEventListener("click", () => {
    const note = document.getElementById("started");
    if (note) note.classList.add("on");
    setTimeout(() => document.getElementById("install").scrollIntoView({ behavior: reduce ? "auto" : "smooth" }), 300);
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
