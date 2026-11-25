// The Store screenshots: index.html?shot=1…7. Each frame is the ground of one of the site's
// feature tiles (taken from site/index.html, so they stay the same art), a headline, and the
// Windows app in front, large. The cards are the app's own lookups (site/data.js) drawn by
// film/card.js in the Windows look (film/win.css, film/win.js).
(async () => {
  const q = new URLSearchParams(location.search);
  const frame = document.getElementById("frame");
  const DEMO = window.LONGYAN.demo;
  const EYE = '<svg viewBox="0 0 1200 848.53"><path fill="currentColor" fill-rule="evenodd" d="M0 424.26L300 124.26A424.26 424.26 0 0 1 900 124.26L1200 424.26L900 724.26A424.26 424.26 0 0 1 300 724.26ZM225 424.26L412.5 236.76A265.17 265.17 0 0 1 787.5 236.76L975 424.26L787.5 611.76A265.17 265.17 0 0 1 412.5 611.76ZM471.43 424.26L535.71 359.98A90.91 90.91 0 0 1 664.29 359.98L728.57 424.26L664.29 488.55A90.91 90.91 0 0 1 535.71 488.55ZM728.57 424.26L975 424.26L851.79 547.48Z"/></svg>';
  const POINTER = '<svg class="ptr" viewBox="0 0 28 28"><path d="M8.2 4.1v16.6l3.9-3.7 2.5 5.8 2.3-1-2.4-5.6h5.3z" fill="#fff" stroke="#000" stroke-width="1.1" stroke-linejoin="round"/></svg>';
  const G = (c) => `<i class="fl">${c}</i>`;

  // The site's tiles, for their grounds.
  const site = new DOMParser().parseFromString(await (await fetch("../../site/index.html")).text(), "text/html");
  function ground(stage, extra = "") {
    const box = document.createElement("div");
    box.className = `glass-box ${site.querySelector("." + stage).className.replace("glass-box", "")} ${extra}`;
    site.querySelectorAll(`.${stage} > .ground`).forEach((g) => box.appendChild(document.importNode(g, true)));
    frame.appendChild(box);
    return box;
  }
  const put = (box, html, css) => { const e = document.createElement("div"); e.innerHTML = html; e.style.cssText = css; box.appendChild(e); return e; };
  const top = (box, h, p) => { const c = put(box, `<h1>${h}</h1><p>${p}</p>`, ""); c.className = "copy top"; return c; };
  const copy = (box, h, p) => put(box, `<h1>${h}</h1><p>${p}</p>`, "").classList.add("copy");

  // A card from the app's lookups of a sentence: a word (start-end) or a phrase.
  function card(box, n, key, css, zoom = 1.2, phrase = false) {
    const d = DEMO[n], r = { left: 0, right: 10, top: 0, bottom: 10, preferBelow: true };
    const c = phrase ? LongyanCard.openPhrase({ phrase: d.phrases[key], words: d.words }, r)
      : LongyanCard.openWord({ senses: d.words[d.cards[key].word] || [], card: d.cards[key] }, r);
    const at = document.createElement("div"); at.style.cssText = "position:absolute;z-index:4;" + css;
    const host = document.createElement("div"); host.id = "cam"; host.style.zoom = zoom;
    host.appendChild(c.el); at.appendChild(host); box.appendChild(at);
    return c;
  }
  // A sentence with the selection marked.
  const line = (box, n, a, b, css, cls = "") => {
    const s = [...DEMO[n].sentence];
    return put(box, `<span lang="zh-CN">${s.slice(0, a).join("")}<mark>${s.slice(a, b).join("")}</mark>${s.slice(b).join("")}</span>`, css + ";position:absolute").classList.add("sline", ...(cls ? [cls] : []));
  };

  const Z1 = { x: 318, y: 66, z: 1.32 };
  const SHOTS = {
    // 1. What it is: select Chinese in any app, and the eye comes up by it.
    1() {
      const b = ground("stage-menu");
      copy(b, "Select Chinese<br>in any app.", "Then click the eye beside it. A card opens with what it means there.");
      put(b, `<div class="window browser">
        <div class="tabs"><span class="tab"><i class="fav"></i><span>下班以后 · 周末随笔</span>${G("&#xE8BB;")}</span>${G("&#xE710;")}
          <span class="caps"><b>&#xE921;</b><b>&#xE922;</b><b>&#xE8BB;</b></span></div>
        <div class="tool">${G("&#xE72B;")}${G("&#xE72A;")}${G("&#xE72C;")}<span class="addr">${G("&#xE72E;")}<span>example.com/after-work</span></span>${G("&#xE712;")}</div>
        <div class="page"><p class="kicker">周末随笔</p><h2>下班以后</h2>          <p class="t" lang="zh-CN">他不想跟领导搞坏关系，所以白天认真工作，偶尔才敢<mark>摸鱼</mark>，看几分钟新闻，或者给家里打个电话。</p>
          <p class="t" lang="zh-CN">周末，他和朋友去爬山。</p></div>
      </div>`, `position:absolute;left:${Z1.x}px;top:${Z1.y}px;z-index:3;zoom:${Z1.z}`).firstElementChild.style.cssText = "width:404px;height:520px";
      const m = b.querySelector(".browser mark");
      return () => {
        // Placed in the window's own points, then zoomed with it.
        const r = m.getClientRects()[0], z = Z1.z, x = r.right / z, y = (r.top + r.bottom) / 2 / z;
        put(b, `<div class="eye">${EYE}</div>`, `position:absolute;z-index:6;zoom:${z};left:${x + 4}px;top:${y - 12}px`);
        put(b, POINTER, `position:absolute;z-index:7;zoom:${z};left:${x + 13}px;top:${y + 1}px`);
      };
    },
    // 2. The meaning that fits: 点 has fifteen; here it's "to order".
    2() {
      const b = ground("stage-history", "g-indigo");
      copy(b, "The meaning<br>that fits the<br>sentence.", "Every sense from CC-CEDICT, with the one used here picked.");
      line(b, 1, 10, 11, "left:452px;top:44px");
      card(b, 1, "10-11", "left:452px;top:108px", 1.22);
    },
    // 3. Whole sentences: the phrase card, every word under the translation.
    3() {
      const b = ground("stage-history", "g-teal");
      copy(b, "Whole sentences,<br>translated.", "Then every word, with the meaning it has there.");
      line(b, 3, 0, 15, "left:452px;top:46px", "small");
      card(b, 3, "0-15", "left:452px;top:104px", 1.16, true);
    },
    // 4. Notes: 卷 and what a dictionary can't say about it.
    4() {
      const b = ground("stage-notes", "ink-warm");
      copy(b, "Notes where<br>English falls<br>short.", "Over a thousand short notes on slang, euphemisms and words with a cultural load.");
      line(b, 0, 5, 6, "left:452px;top:44px");
      card(b, 0, "5-6", "left:452px;top:108px", 1.22);
    },
    // 5. Tones: the four, each in its colour, the panel in the card's look.
    5() {
      const b = ground("stage-tones", "ink");
      const tones = site.querySelector(".ui-tones").cloneNode(true);
      tones.className = "tones";
      const inks = ["#a8544c", "#4a8761", "#4a73a6", "#8061a3"];
      [...tones.children].forEach((d, i) => { d.style.setProperty("--ink", inks[i]); if (i === 2) d.classList.add("on"); });
      const host = put(b, "", "position:absolute;left:50%;top:200px;transform:translateX(-50%);z-index:4");
      host.appendChild(tones);
      top(b, "Every tone in its own color.", "Characters and pinyin are colored by tone, so you start to hear a word as you read it.");
    },
    // 6. History: the Windows window, every lookup with its sentence.
    6() {
      const b = ground("stage-history");
      top(b, "Every word you look up, saved.", "With the sentence it came from. Export them to Anki or a spreadsheet.");
      put(b, `<div class="window"><img src="art/history.png" alt=""></div>`, "position:absolute;left:60px;top:170px;width:1040px;z-index:3");
    },
    // 7. Private: the settings that say where it all runs.
    7() {
      const b = ground("stage-menu", "g-dusk");
      top(b, "Nothing leaves your PC.", "The dictionary and the reading model run on it. No account, and nothing you look up is sent.");
      put(b, `<div class="window"><div class="titlebar">${EYE}Longyan Reader Settings<span class="caps"><b>&#xE921;</b><b>&#xE922;</b><b>&#xE8BB;</b></span></div><img src="art/settings.png" alt=""></div>`, "position:absolute;left:70px;top:170px;width:820px;z-index:3");
    },
  };

  await document.fonts.ready;
  if (q.has("film")) return film();
  const after = SHOTS[q.get("shot") || "1"]();
  await document.fonts.ready;
  await new Promise((r) => setTimeout(r, 300));
  if (typeof after === "function") after();
  document.body.dataset.ready = "1";

  // The Store's background video (index.html?film): four of the shots in turn, each played out
  // as it happens in the app: the selection drawn a character at a time, then the card, with the
  // Mac film's springs (film/film.js). In the first, the pointer drags across 摸鱼, the eye comes
  // up, and the pointer clicks it. A pure function of t, shot like the film: window.film.render(t).
  // It loops: the last scene fades into the first one's opening frame.
  async function film() {
    const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
    const lerp = (a, b, u) => a + (b - a) * u;
    function spring(response, damping) {
      const w = (2 * Math.PI) / response, z = damping, wd = w * Math.sqrt(1 - z * z);
      return (t) => (t <= 0 ? 0 : 1 - Math.exp(-z * w * t) * (Math.cos(wd * t) + ((z * w) / wd) * Math.sin(wd * t)));
    }
    const CHIP_IN = spring(0.3, 0.68), PRESS = spring(0.2, 0.7), CARD_IN = spring(0.32, 0.82);
    const reach = (u) => { u = clamp(u); return u * u * u * (10 - 15 * u + 6 * u * u); };
    const FADE = 0.7, OUT = 0.35, PUSH = 0.025;

    // A selection as one span per character, so the drag can take them one by one.
    const chars = (m) => { const t = [...m.textContent]; m.textContent = ""; m.style.background = "none"; m.style.color = "inherit";
      return t.map((c) => { const s = document.createElement("span"); s.textContent = c; s.className = "ch"; m.appendChild(s); return s; }); };
    const select = (cs, k) => cs.forEach((s, i) => s.classList.toggle("on", i < k));
    const cardIn = (el, k, up = false) => { const e = CARD_IN(k); el.dataset.op = clamp(k / 0.18); el.style.transform = `translateY(${(1 - e) * (up ? 6 : -6)}px) scale(${0.96 + 0.04 * e})`; };
    // card.js keeps one card open and removes the last when the next opens: each scene keeps a copy.
    const keep = (box) => { const el = box.querySelector("#cam > .lc-card"); el.replaceWith(el.cloneNode(true)); };
    const build = (n) => { const i = frame.children.length; const after = SHOTS[n](); const box = frame.children[i]; if (n !== 1) keep(box); return { box, after }; };
    const scenes = [];
    document.documentElement.classList.add("filming");

    // 1. The browser: the drag, the eye, the click, the card.
    {
      const { box, after } = build(1);
      await new Promise((r) => setTimeout(r, 50)); after();
      const z = Z1.z, m = box.querySelector(".browser mark"), r0 = m.getClientRects()[0], mid = (r0.top + r0.bottom) / 2;
      const eye = box.querySelector(".eye").parentElement, ptr = box.querySelector(".ptr").parentElement;
      const cs = chars(m), rs = cs.map((c) => c.getBoundingClientRect());
      const c = card(box, 2, "3-5", "", 1.12);
      // Above the line: below it, the card would go off the screen (card.js's rule: below when it
      // fits, else the side with more room).
      const at = c.el.parentElement.parentElement, cr = c.el.getBoundingClientRect();
      at.style.left = Math.min(r0.left - 18, 960 - cr.width - 26) + "px"; at.style.top = r0.top - 10 - cr.height + "px"; at.style.transformOrigin = "30% 100%";
      keep(box);
      const ex = parseFloat(eye.style.left) * z, ey = parseFloat(eye.style.top) * z;   // the eye's corner, in frame points
      const P = { a: [880, 470], s: [rs[0].left + 2, mid], e: [rs[cs.length - 1].right - 1, mid], eye: [ex + 17, ey + 19], off: [ex + 70, ey + 96] };
      ptr.style.left = ptr.style.top = "0px"; eye.style.transformOrigin = "50% 50%";
      const go = (a, b, u) => a.map((v, i) => lerp(v, b[i], reach(u)));
      scenes.push({ box, L: 6.4, render(u) {
        // The pointer comes in, presses at the start of 摸, drags to the end of 鱼, lets go; then the eye.
        const p = u < 1.05 ? go(P.a, P.s, (u - 0.2) / 0.8) : u < 1.75 ? go(P.s, P.e, (u - 1.05) / 0.55)
          : u < 3.3 ? go(P.e, P.eye, (u - 2.25) / 0.7) : go(P.eye, P.off, (u - 3.6) / 0.9);
        const press = u >= 2.9 && u < 3.05 ? 0.86 : u >= 3.05 ? lerp(0.86, 1, PRESS(u - 3.05)) : 1;
        ptr.style.transform = `translate(${p[0] / z - 8.2}px, ${p[1] / z - 4.1}px) scale(${press})`;
        // The selection follows the drag.
        select(cs, u < 1.05 ? 0 : u >= 1.75 ? cs.length : cs.filter((x, i) => p[0] > (rs[i].left + rs[i].right) / 2).length);
        // The eye: up just after the release, pressed with the click, gone when the card opens.
        const ue = u - 1.85, gone = clamp((u - 3.1) / 0.12);
        eye.dataset.op = ue < 0 ? 0 : clamp(ue / 0.12) * (1 - gone);
        eye.style.transform = `scale(${ue < 0 ? 0.6 : lerp(0.6, 1, CHIP_IN(ue)) * (u >= 2.9 && u < 3.1 ? 0.92 : 1)})`;
        cardIn(at, u - 3.1, true);
      } });
    }
    // 2-4. A sentence, its selection drawn across it, the card.
    for (const n of [2, 4, 3]) {
      const { box } = build(n);
      const cs = chars(box.querySelector(".sline mark"));
      const at = box.querySelector("#cam").parentElement; at.style.transformOrigin = "20% 0";
      const step = n === 3 ? 0.055 : 0.12, L = n === 3 ? 6.2 : 5.4;
      scenes.push({ box, L, render(u) {
        select(cs, u < 0.7 ? 0 : Math.min(cs.length, 1 + Math.floor((u - 0.7) / step)));
        cardIn(at, u - (0.7 + cs.length * step + 0.35));
      } });
    }

    let T = 0; scenes.forEach((s) => { s.start = T; T += s.L; });
    // Each scene pushes in slowly while it's on; the next fades in over its last FADE seconds,
    // still at its own opening frame.
    function render(t) {
      t = ((t % T) + T) % T;
      scenes.forEach((s, i) => {
        const u = t - s.start;
        const at = i === 0 ? T : s.start, on = u >= 0 && u < s.L, coming = !on && t >= at - FADE && t < at;
        s.box.style.opacity = on ? 1 : coming ? (t - (at - FADE)) / FADE : 0;
        s.box.style.zIndex = coming ? 2 : 1;
        s.render(on ? u : 0);
        // The words and the app go before the grounds cross, and come after, never two at once.
        const k = on ? clamp(u / OUT) * clamp((s.L - u) / OUT) : 0;
        s.box.querySelectorAll(":scope > :not(.ground):not(.paper)").forEach((e) => { e.style.opacity = k * (e.dataset.op ?? 1); });
        s.box.style.transformOrigin = "70% 45%";
        s.box.style.transform = `scale(${1 + PUSH * (on ? u / s.L : 0)})`;
      });
    }
    await document.fonts.ready;
    render(0);
    window.film = { ready: Promise.resolve(), render, T, FPS: 60 };
    document.body.dataset.ready = "1";
  }
})();
