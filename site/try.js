// The demo sentence lifted from the eye, as text to read the way the app does. Selecting
// works as it does in any Mac text: drag across characters, double-click for a word (and drag
// on by words), triple-click for the sentence, shift-click to extend. Let go and the
// selection settles onto whole words, and the card opens. The cards are card.js, filled with
// the app's own answers (scripts/site-data.py).
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

  // sel: the settled selection, in words (lo..hi) and characters (start..end).
  function clear() {
    sel = null; press = null;
    for (const el of els) el.querySelector(".hi").classList.remove("on", "snap");
    if (Card() && Card().open) Card().close();
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

  // The words a run of characters touches; null if it's only punctuation.
  function wordsIn(a, b) {
    const d = demo[indexOf(0)];
    const ts = d.tokens.map((t, i) => i).filter((i) => d.tokens[i].range[0] < b && d.tokens[i].range[1] > a);
    return ts.length ? [ts[0], ts[ts.length - 1]] : null;
  }
  function settle(lo, hi) {
    const el = currentEl(), d = demo[indexOf(0)];
    sel = { lo, hi, start: d.tokens[lo].range[0], end: d.tokens[hi].range[1], d, el };
  }

  const selRect = () => sel.el.querySelector(".hi").getBoundingClientRect();

  function lookUp() {
    if (!sel || !Card()) return;
    root.classList.add("used");
    const { d, lo, hi, start, end, el } = sel, size = sizeOf(el), box = el.getBoundingClientRect();
    // Where the selection will be once it has settled, not where it is mid-way.
    const r = { left: box.left + start * size, right: box.left + end * size, top: selRect().top, bottom: selRect().bottom };
    if (lo === hi) {
      Card().openWord({ senses: d.words[d.tokens[lo].text] || [], card: d.cards[String(start)] }, r);
    } else {
      const phrase = d.phrases[`${start}-${end}`];
      if (phrase) Card().openPhrase({ phrase, words: d.words }, r);
    }
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

  // Let go: the selection settles onto the words it touches, and the card opens for them.
  function release() {
    const p = press;
    press = null;
    if (!p) return;
    let ws = null;
    if (p.mode === "char") ws = p.a === p.b ? null : wordsIn(Math.min(p.a, p.b), Math.max(p.a, p.b));
    else ws = [Math.min(p.a, p.b), Math.max(p.a, p.b)];
    if (!ws) { clear(); return; }
    settle(ws[0], ws[1]);
    const moved = p.mode === "char" && (Math.min(p.a, p.b) !== sel.start || Math.max(p.a, p.b) !== sel.end);
    paint(sel.start, sel.end, moved);
    if (moved && !reduce) setTimeout(() => { if (sel && !press) lookUp(); }, 150);
    else lookUp();
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
      const c = caretAt(e.clientX), a = c < (sel.start + sel.end) / 2 ? sel.end : sel.start;
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
    settle(t, t);
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
  new MutationObserver(() => { if (!story.classList.contains("is-formed")) clear(); })
    .observe(story, { attributes: true, attributeFilter: ["class"] });

  // "Try it" jumps to the formed sentences.
  document.querySelectorAll("[data-try]").forEach((a) => a.addEventListener("click", (e) => {
    if (!window.LongyanHero) return;
    e.preventDefault();
    window.scrollTo({ top: window.LongyanHero.formedY(), behavior: reduce ? "auto" : "smooth" });
  }));

  // After a download starts, point to the install steps.
  document.querySelectorAll("[data-download]").forEach((a) => a.addEventListener("click", () => {
    const note = document.getElementById("started");
    if (note) note.classList.add("on");
    setTimeout(() => document.getElementById("install").scrollIntoView({ behavior: reduce ? "auto" : "smooth" }), 300);
  }));

  if (window.LongyanHero && window.LongyanHero.lines().length) build({ lines: window.LongyanHero.lines(), current: 0 });

  // The statement's card, built into the page: 躺平 in the first sentence, its literal
  // meaning a click away and the app's note on the one it picks.
  const litCard = document.getElementById("lit-card");
  if (litCard && Card()) {
    const d = demo[0], k = Object.keys(d.cards).find((i) => d.cards[i].word === "躺平");
    if (k != null) Card().openWord({ senses: d.words["躺平"] || [], card: d.cards[k] }, null, litCard);
  }
})();
