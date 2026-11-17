// The three sentences lifted from the page, as text to read the way the app does: select a
// word (click it) or a few (drag across them, or triple-click for the whole sentence), and
// the card opens as you let go. The cards are card.js, filled with the app's own answers
// (scripts/site-data.py). The lines scroll like lyrics: the middle one is the one you read,
// "Next sentence" moves them up.
(function () {
  "use strict";
  const demo = window.LONGYAN && window.LONGYAN.demo;
  const root = document.getElementById("try");
  const story = document.getElementById("story");
  const box = document.getElementById("lines");
  const next = document.getElementById("another");
  if (!demo || !root || !box) return;
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const Card = () => window.LongyanCard;
  const N = demo.length;

  let lines = [], current = 0, els = [], sel = null, shift = 0;
  const indexOf = (k) => (((current + k) % N) + N) % N;
  const currentEl = () => els.find((e) => e.dataset.k === "0");
  const sizeOf = (el) => parseFloat(el.style.getPropertyValue("--size"));

  // MARK: The lines, where hero.js drew them

  function build(detail) {
    const old = els;
    lines = detail.lines; current = detail.current;
    const gap = lines.length > 1 ? lines[1].y - lines[0].y : 0;
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

    // Like lyrics: every line slides up from where it was, the top one fades out past the
    // edge and the new one fades in from below.
    if (shift && !reduce && old.length) {
      const s = shift;
      for (const o of old) {
        if (+o.dataset.k !== -s) continue;
        o.classList.add("leaving");
        box.append(o);
        o.getBoundingClientRect();
        o.style.transform = `translateY(${-s * gap}px)`;
        setTimeout(() => o.remove(), 900);
      }
      for (const el of els) {
        el.classList.add("from");
        el.style.transform = `translateY(${s * gap}px)`;
        const was = +el.dataset.k + s;
        el.style.opacity = was === 0 ? 1 : Math.abs(was) === 1 ? 0.3 : 0;
      }
      box.getBoundingClientRect();
      for (const el of els) { el.classList.remove("from"); el.style.transform = ""; el.style.opacity = ""; }
    }
    shift = 0;
    sel = null;
  }
  document.addEventListener("longyan:lines", (e) => build(e.detail));

  // MARK: Selecting, as text is

  function clear() {
    sel = null;
    for (const el of els) el.querySelector(".hi").classList.remove("on");
    if (Card() && Card().open) Card().close();
  }

  // Words a through b of the current line, and everything between them.
  function select(a, b) {
    const lo = Math.min(a, b), hi = Math.max(a, b);
    const el = currentEl(), d = demo[indexOf(0)];
    const start = d.tokens[lo].range[0], end = d.tokens[hi].range[1];
    if (sel && sel.start === start && sel.end === end) return;
    sel = { lo, hi, start, end, d, el };
    const size = sizeOf(el), hiEl = el.querySelector(".hi");
    hiEl.style.left = start * size + "px";
    hiEl.style.width = (end - start) * size + "px";
    hiEl.classList.add("on");
    if (Card() && Card().open) Card().close();
  }

  const selRect = () => sel.el.querySelector(".hi").getBoundingClientRect();

  function lookUp() {
    if (!sel || !Card()) return;
    root.classList.add("used");
    const { d, lo, hi, start, end } = sel, r = selRect();
    const anchor = { left: r.left, top: r.top, right: r.right, bottom: r.bottom };
    if (lo === hi) {
      Card().openWord({ senses: d.words[d.tokens[lo].text] || [], card: d.cards[String(start)] }, anchor);
    } else {
      const phrase = d.phrases[`${start}-${end}`];
      if (phrase) Card().openPhrase({ phrase, words: d.words }, anchor);
    }
  }

  // The word at a point on the current line; on punctuation, the nearest one toward `from`.
  function tokenAt(x, from) {
    const el = currentEl(), d = demo[indexOf(0)], size = sizeOf(el);
    const ci = Math.max(0, Math.min(d.sentence.length - 1, Math.floor((x - el.getBoundingClientRect().left) / size)));
    let t = d.tokens.findIndex((tk) => ci >= tk.range[0] && ci < tk.range[1]);
    if (t >= 0) return t;
    if (from == null) return -1;
    const after = d.tokens.findIndex((tk) => tk.range[0] > ci);
    if (after < 0) return d.tokens.length - 1;
    return d.tokens[from].range[0] < ci ? Math.max(0, after - 1) : after;
  }

  // Press on a word and drag to take in more; three clicks take the sentence.
  let press = null;
  box.addEventListener("pointerdown", (e) => {
    const line = e.target.closest(".line");
    if (!line || e.button > 0 || line.dataset.k !== "0") return;
    e.preventDefault();
    const t = tokenAt(e.clientX);
    if (e.detail >= 3) { select(0, demo[indexOf(0)].tokens.length - 1); press = { done: true, id: e.pointerId }; lookUp(); return; }
    if (t < 0) { clear(); return; }
    press = { anchor: t, focus: t, id: e.pointerId };
    select(t, t);
    try { box.setPointerCapture(e.pointerId); } catch (_) {}
  });
  box.addEventListener("pointermove", (e) => {
    if (!press || press.done || e.pointerId !== press.id) return;
    const t = tokenAt(e.clientX, press.anchor);
    if (t !== press.focus) { press.focus = t; select(press.anchor, t); }
  });
  box.addEventListener("pointerup", (e) => {
    if (!press || e.pointerId !== press.id) return;
    const done = press.done;
    press = null;
    // Let go, and the card opens for what's selected.
    if (!done) lookUp();
  });
  box.addEventListener("pointercancel", () => { press = null; });

  // A dim line: make it the one you read.
  box.addEventListener("click", (e) => {
    const line = e.target.closest(".line");
    if (!line || line.dataset.k === "0" || line.classList.contains("leaving")) return;
    move(+line.dataset.k);
  });

  box.addEventListener("keydown", (e) => {
    const w = e.target.closest(".w");
    if (!w || (e.key !== "Enter" && e.key !== " ")) return;
    e.preventDefault();
    select(+w.dataset.t, +w.dataset.t);
    lookUp();
  });
  // The app's shortcut: ⌃⌥L looks up what's selected.
  document.addEventListener("keydown", (e) => {
    if (e.ctrlKey && e.altKey && e.code === "KeyL" && sel) { e.preventDefault(); lookUp(); }
  });
  // A press anywhere else lets go of the selection, as it would in any text.
  document.addEventListener("pointerdown", (e) => {
    if (!sel || e.target.closest(".lines, .lc-card, .another")) return;
    clear();
  });

  // MARK: Moving between sentences

  function move(by) {
    if (!window.LongyanHero) return;
    clear();
    shift = by;
    window.LongyanHero.setCurrent((((current + by) % N) + N) % N);
  }
  next.addEventListener("click", () => move(1));

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
})();
