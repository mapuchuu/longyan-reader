// The opening: the Longyan eye, set in Chinese characters, over the page's paper. It plays
// once, on its own, in seconds: the eye comes in, its characters float out of it from all
// over into the demo sentence, which try.js then lets you read (and selects a word in, the
// way you would).
//
// The eye is set in everyday sentences, in characters of many sizes: big ones where the mark
// is thick, smaller and smaller toward its edges. Every character is whole and sits inside
// the mark, a vector built from its geometry (below); nothing is masked, so the shape is just
// where the characters are, traced finely by the smallest. Characters with too little ink to
// fill their square (一, 人, 了…) are left out. Pointing at a character shows the word it's
// part of and what it means in its sentence: the app's own reading (scripts/site-data.py).
(function () {
  "use strict";
  const canvas = document.getElementById("field");
  const story = document.getElementById("story");
  if (!canvas || !window.LONGYAN) return;
  const ctx = canvas.getContext("2d");
  const demo = window.LONGYAN.demo;
  const PAGE = window.LONGYAN.page || demo.map((d) => ({ s: d.sentence, w: [] }));
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const params = new URLSearchParams(location.search);
  const og = params.has("og");
  if (og) document.documentElement.classList.add("og");
  const still = reduce || og;

  const FORMED = 0.33;     // story progress at which the sentences have formed
  // Scrolling down, progress runs from FORMED to 0, the original opening played backwards and
  // at its pace: each of the sentence's characters lifts off the line at a moment of its own
  // and takes a long, unhurried FLIGHT down into the eye, landing between LAND and LAND +
  // SPREAD; the eye spreads out from each as it lands, done by GROW_END, each character
  // flashing white for FLASH as it comes.
  const FLIGHT = 0.16, LAND = 0.075, SPREAD = 0.095, GROW_END = 0.012, FLASH = 0.02;
  const ZH = '"PingFang SC", "Hiragino Sans GB", "Noto Sans SC", "Microsoft YaHei", sans-serif';
  // The hero's inks: the paper's own hues (paper.js), azure through violet and magenta to
  // coral, lightened to read as small characters on black and softened toward a grey lilac,
  // so the opening is quieter than the paper it leads to.
  const MIST = [196, 196, 212], SOFT = 0.45;
  const soft = (c) => c.map((v, k) => Math.round(v + (MIST[k] - v) * SOFT));
  const AZURE = soft([107, 155, 255]), VIOLET = soft([169, 139, 255]), MAGENTA = soft([236, 130, 214]), CORAL = soft([255, 159, 133]);
  const INK = [245, 245, 247];
  // At rest the eye is white, like the mark in the bar, each character a little lighter or
  // darker so it reads as print and not a flat shape. The colour is in the moment a character
  // comes in: it arrives in the paper's hues, fuller than the inks above, and cools to white.
  const DIM = [170, 170, 184];
  const hotOf = (c) => c.map((v, k) => Math.round(v + (v - MIST[k]) * 0.55));
  const COOL = 0.05, COOL_T = 0.7;   // how long the colour lasts: in story progress, and in seconds
  const PUNCT = /[，。？！、：；“”（）《》…—]/;
  // Characters too light to fill a square of the eye.
  const SPARSE = /[一二三十八人入了个上下几儿小大卜七九工口]/;
  const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x));
  const smooth = (a, b, x) => { const u = clamp((x - a) / (b - a)); return u * u * (3 - 2 * u); };
  // Glide: an even pace for most of the way, then easing to a stop. Its first 60% of the time
  // covers 75% of the distance at a steady speed; the rest slows evenly to nothing.
  const GA = 0.6, GS = 2 / (1 + GA);
  const glide = (t) => (t <= GA ? GS * t : GS * GA + GS * (t - GA) - (GS * (t - GA) ** 2) / (2 * (1 - GA)));
  // The time at which glide reaches u.
  const glideAt = (u) => {
    if (u <= GS * GA) return u / GS;
    const r = Math.min(u - GS * GA, GS * (1 - GA) / 2);
    return GA + (1 - GA) * (1 - Math.sqrt(Math.max(0, 1 - (2 * r) / (GS * (1 - GA)))));
  };
  const SWEEP = 1.2;   // seconds for the eye to come in, left to right
  const easeInOut = (u) => (u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2);
  const hash = (i) => { const s = Math.sin(i * 12.9898) * 43758.5453; return s - Math.floor(s); };
  const mix = (a, b, u) => a.map((v, k) => Math.round(v + (b[k] - v) * clamp(u)));
  const rgb = (c, a = 1) => `rgba(${c[0]},${c[1]},${c[2]},${a})`;

  // MARK: The mark

  // The Longyan eye is three nested eye shapes, each the hull of a circle and two points on
  // its horizontal (the circle's radius is the half-width over √2, so the stroke is even all
  // round), plus the wedge that turns the inner one into a hook. Half-widths: 1, 5/8, 3/14.
  // Filled even-odd, the three hulls and the wedge make the mark.
  const MW = 1200, MH = 600 * Math.SQRT2, MC = [600, MH / 2];
  function hull(path, h) {
    const R = h / Math.SQRT2, [x, y] = MC;
    path.moveTo(x - h, y); path.lineTo(x - h / 2, y - h / 2);
    path.arc(x, y, R, -0.75 * Math.PI, -0.25 * Math.PI);
    path.lineTo(x + h, y); path.lineTo(x + h / 2, y + h / 2);
    path.arc(x, y, R, 0.25 * Math.PI, 0.75 * Math.PI);
    path.closePath();
  }
  const A = 600, B = 600 * 5 / 8, P = 600 * 3 / 14;
  const mark = new Path2D();
  hull(mark, A); hull(mark, B); hull(mark, P);
  mark.moveTo(MC[0] + P, MC[1]); mark.lineTo(MC[0] + B, MC[1]); mark.lineTo(MC[0] + (B + P) / 2, MC[1] + (B - P) / 2); mark.closePath();

  // MARK: The eye's text

  // Every sentence's words: [start, end, [[syllable, tone]…], meaning here].
  const words = [];            // { text, syl:[{t,tone}], gloss }
  const charInfo = PAGE.map((p) => {
    const info = [...p.s].map(() => null);
    for (const [a, b, syl, gloss] of p.w) {
      const id = words.push({ text: p.s.slice(a, b), syl: syl.map(([t, tone]) => ({ t, tone })), gloss }) - 1;
      for (let i = a; i < b; i++) info[i] = { word: id, k: i - a };
    }
    return info;
  });
  // A shuffled order of the sentences for each pass through them, so the repeats don't line up.
  function order(pass) {
    const o = PAGE.map((_, k) => k);
    for (let k = o.length - 1; k > 0; k--) { const j = Math.floor(hash(pass * 31 + k * 7.13) * (k + 1)); [o[k], o[j]] = [o[j], o[k]]; }
    return o;
  }
  // The eye's characters, packed into the mark on a grid of half units: big squares first,
  // up to 5 units, then sizes from 2 units down to a half for the rest. Characters are never
  // cut. Along the edge a character may stand a little past the outline (a bigger one by a
  // smaller share of its side, the tiniest not at all), which is about the blank margin a
  // character has round its ink anyway; that lets the edge take every size, not only the
  // smallest, and lets the pupil's point and the wedge's tip fill in so they meet.
  function pack(unit) {
    const h = unit / 2, q = h / 2;
    // Even counts, so the eye's centre line (the wedge's top edge) is a line of the grid.
    const ucols = 2 * Math.ceil(eye.w / h / 2) + 6, urows = 2 * Math.ceil(eye.h / h / 2) + 6;
    const ux0 = eye.cx - (ucols * h) / 2, uy0 = eye.cy - (urows * h) / 2;
    const test = document.createElement("canvas").getContext("2d");
    test.setTransform(...markMatrix());
    // Which points of a grid of quarter units are inside the mark.
    const FC = 2 * ucols + 1, FR = 2 * urows + 1, fin = new Uint8Array(FC * FR);
    for (let r = 0; r < FR; r++) for (let c = 0; c < FC; c++)
      fin[r * FC + c] = test.isPointInPath(mark, ux0 + c * q, uy0 + r * q, "evenodd") ? 1 : 0;
    const owner = new Int32Array(ucols * urows).fill(-1);
    const out = [];
    let seq = 0, pass = 50, queue = [];
    const next = () => {
      while (!queue.length) for (const sIdx of order(pass++)) [...PAGE[sIdx].s].forEach((ch, i) => { if (!PUNCT.test(ch) && !SPARSE.test(ch)) queue.push({ ch, s: sIdx, i }); });
      return queue.shift();
    };
    // How far past the outline, in quarter units, a square n half units on a side may stand.
    const SLACK = { 1: 0, 2: 1, 3: 1, 4: 1, 5: 1, 6: 1, 8: 1, 10: 1 };
    // A square fits if it's free and, inset by `s` quarter units (less than zero keeps it that
    // far inside), it's all inside the mark.
    const fits = (c, r, n, s = SLACK[n]) => {
      if (c < 1 || r < 1 || c + n > ucols - 1 || r + n > urows - 1) return false;
      for (let y = r; y < r + n; y++) for (let x = c; x < c + n; x++) if (owner[y * ucols + x] >= 0) return false;
      const a = 2 * c + s, b = 2 * (c + n) - s, t = 2 * r + s, d = 2 * (r + n) - s;
      for (let y = t; y <= d; y++) for (let x = a; x <= b; x++) if (!fin[y * FC + x]) return false;
      return true;
    };
    const place = (c, r, n) => {
      const k = out.length;
      for (let y = r; y < r + n; y++) for (let x = c; x < c + n; x++) owner[y * ucols + x] = k;
      out.push({ ...next(), x: ux0 + c * h, y: uy0 + r * h, w: n * h, rnd: hash(++seq * 1.37 + 0.2) });
    };
    // Where the pupil's point meets the wedge's tip the mark narrows to a point, which only the
    // smallest characters would fit. A few small ones sit right across it, their tops on the
    // wedge's edge, so the pupil and the hook read as one stroke, as in the icon.
    {
      const jc = Math.round((eye.cx + P * eye.s - ux0) / h), jr = urows / 2;
      for (const [dc, n] of [[-1, 2], [1, 2], [3, 3], [-3, 2], [-2, 2], [6, 3]]) {
        const c = jc + dc;
        for (let dx = 0; dx < n; dx++) if (fits(c - dx, jr, n, n)) { place(c - dx, jr, n); break; }
      }
    }
    // How much of the area each big size tries for.
    let area = 0;
    for (let r = 0; r < urows; r++) for (let c = 0; c < ucols; c++) if (fin[(2 * r + 1) * FC + 2 * c + 1]) area++;
    // Big ones scattered first. Some keep a little off the edge, some come right up to it,
    // so the outline is traced in all sizes.
    for (const [n, share] of [[10, 0.16], [8, 0.2], [6, 0.18], [5, 0.08], [4, 0.1]]) {
      const want = Math.round((area * share) / (n * n)), tries = want * 20;
      for (let k = 0, got = 0; k < tries && got < want; k++) {
        const c = Math.floor(hash(n * 1000 + k * 1.618) * ucols), r = Math.floor(hash(n * 2000 + k * 2.414) * urows);
        const roll = hash(n * 3000 + k * 0.577);
        const s = roll < 0.35 ? -1 : roll < 0.7 ? 0 : SLACK[n];
        if (fits(c, r, n, s)) { place(c, r, n); got++; }
      }
    }
    // Then the edge: each free cell on the outline, in no particular order, takes a size of
    // 2 to 4 half units picked at random, so the outline isn't left to the smallest.
    const edge = [];
    for (let r = 1; r < urows - 1; r++) for (let c = 1; c < ucols - 1; c++) {
      const y = 2 * r + 1, x = 2 * c + 1;
      if (fin[y * FC + x] && (!fin[y * FC + x - 4] || !fin[y * FC + x + 4] || !fin[(y - 4) * FC + x] || !fin[(y + 4) * FC + x])) edge.push(r * ucols + c);
    }
    for (let k = edge.length - 1; k > 0; k--) { const j = Math.floor(hash(k * 0.613 + 11) * (k + 1)); [edge[k], edge[j]] = [edge[j], edge[k]]; }
    for (const q of edge) {
      if (owner[q] >= 0) continue;
      const c = q % ucols, r = (q / ucols) | 0, roll = hash(q * 0.71 + 3);
      const sizes = roll < 0.3 ? [4, 3, 2] : roll < 0.7 ? [3, 2] : [2];
      let done = false;
      for (const n of sizes) {
        for (let dy = 0; dy < n && !done; dy++) for (let dx = 0; dx < n && !done; dx++)
          if (fits(c - dx, r - dy, n)) { place(c - dx, r - dy, n); done = true; }
        if (done) break;
      }
    }
    // Then the rest, in no particular order, each spot taking a size picked at random from
    // what fits there, so the characters along the edge vary as much as those inside.
    const spots = [];
    for (let r = 0; r < urows; r++) for (let c = 0; c < ucols; c++) spots.push(r * ucols + c);
    for (let k = spots.length - 1; k > 0; k--) { const j = Math.floor(hash(k * 0.917 + 5) * (k + 1)); [spots[k], spots[j]] = [spots[j], spots[k]]; }
    for (const q of spots) {
      const c = q % ucols, r = (q / ucols) | 0;
      if (owner[q] >= 0) continue;
      const roll = hash(q * 1.31 + 9);
      // Prefer the bigger sizes that fit; the roll lets some spots take a smaller one.
      const sizes = roll < 0.45 ? [4, 3, 2, 1] : roll < 0.8 ? [3, 2, 1] : [2, 1];
      for (const n of sizes) {
        // A bigger square may sit up and left of this spot too.
        let done = false;
        for (let dy = 0; dy < n && !done; dy++) for (let dx = 0; dx < n && !done; dx++)
          if (fits(c - dx, r - dy, n)) { place(c - dx, r - dy, n); done = true; }
        if (done) break;
      }
    }
    // Each character's tint, from a slow field across the eye: azure into violet, turning to
    // magenta and coral where the field turns, like light along the paper's folds.
    for (const g of out) {
      const u = (g.x + g.w / 2 - eye.x) / eye.w, v = (g.y + g.w / 2 - eye.y) / eye.h;
      g.col = pearl(0.62 * u + 0.3 * v + 0.12 * Math.sin(6.2 * v + 2.4 * u) + (g.rnd - 0.5) * 0.1);
      g.hot = hotOf(g.col).map((v) => clamp(v, 0, 255));
      g.rest = mix(DIM, INK, 0.45 + 0.55 * hash(g.x * 0.37 + g.y * 1.91) - (g.w >= unit * 3 ? 0.15 : 0));
    }
    return { unit: h, ucols, urows, ux0, uy0, owner, glyphs: out };
  }
  // The tints in order; t runs 0..1 across the eye and wraps.
  const PEARL = [AZURE, AZURE, VIOLET, MAGENTA, CORAL, VIOLET];
  function pearl(t) {
    t = ((t % 1) + 1) % 1 * PEARL.length;
    const i = Math.floor(t), f = t - i, a = PEARL[i], b = PEARL[(i + 1) % PEARL.length];
    return mix(a, b, f * f * (3 - 2 * f));
  }

  let W = 0, H = 0, dpr = 1, narrow = false;
  const STACKED = matchMedia("(max-width: 900px), (max-width: 1100px) and (orientation: portrait)");
  let fine = null;                     // the eye's characters: { unit, glyphs, owner… }
  let eye = { x: 0, y: 0, w: 1, h: 1, cx: 0, cy: 0, s: 1 };
  let lit = null;                      // the eye's text, pre-drawn
  let current = 0, lines = [], flights = [];
  let started = performance.now(), running = false, visible = true, raf = 0;
  let progress = 0, target = 0, lineY = 0;
  let hover = null;                    // { k }: the eye's character pointed at

  function markMatrix() {
    const s = eye.s;
    return [s, 0, 0, s, eye.cx - MC[0] * s, eye.cy - MC[1] * s];
  }

  function layout() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    W = canvas.clientWidth; H = canvas.clientHeight;
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
    narrow = STACKED.matches;
    // The sentence a little above the middle, with the room under it for a whole card.
    lineY = Math.round(H * (narrow ? 0.4 : 0.41));
    // The eye: on a wide screen on the right, level with the headline beside it, as big as
    // the column allows; on a phone or an upright tablet, centred over the headline.
    let ew, cx, cy;
    if (narrow) { ew = Math.min(W - 72, 560, H * 0.28 * (MW / MH)); cx = W / 2; cy = H * 0.3; }
    else {
      // The headline and the eye are one group, centred on the screen: the eye as tall as the
      // words beside it (headline, line and button), a fixed gap between, the words' column
      // as style.css sets it. The group sits a little above the middle, where the eye rests.
      const copyW = Math.min(540, W * 0.29), gap = Math.round(Math.min(110, W * 0.06));
      ew = Math.min(clamp(H * 0.38, 240, 420) * (MW / MH), W * 0.36, W - 56 - copyW - gap);
      const left = Math.round((W - (copyW + gap + ew)) / 2);
      cx = left + copyW + gap + ew / 2; cy = H * 0.48;
      if (story) story.style.setProperty("--copy-left", left + "px");
    }
    const eh = ew * (MH / MW);
    eye = { w: ew, h: eh, cx, cy, x: cx - ew / 2, y: cy - eh / 2, s: ew / MW };
    if (story) story.style.setProperty("--eye-bottom", Math.round(cy + eh / 2) + "px");

    // The eye's text: the smallest whole characters about 58 to the eye's width (fewer on a
    // small eye, so they stay characters rather than dust).
    const unit = clamp(Math.round((ew / 58) * 4) / 4, 4.5, 8);
    fine = pack(unit);
    lit = document.createElement("canvas");
    lit.width = canvas.width; lit.height = canvas.height;
    litCtx = lit.getContext("2d");
    litCtx.setTransform(dpr, 0, 0, dpr, 0, 0); litCtx.textAlign = "center"; litCtx.textBaseline = "middle";
    for (const g of fine.glyphs) {
      // Big characters a little lighter in weight, so they don't outshine the rest.
      g.wt = g.w >= unit * 3 ? 500 : 600;
      drawLit(g);
    }

    gridX = null;
    placeLines();
  }

  // One of the eye's characters on the lit layer, in its tint; `fresh` clears its square first.
  let litCtx = null;
  function drawLit(g, fresh) {
    if (fresh) litCtx.clearRect(g.x - 1, g.y - 1, g.w + 2, g.w + 2);
    litCtx.fillStyle = rgb(g.rest);
    litCtx.font = `${g.wt} ${g.w * 0.94}px ${ZH}`;
    litCtx.fillText(g.ch, g.x + g.w / 2, g.y + g.w / 2 + g.w * 0.04);
  }

  // MARK: Words in the eye

  // The word a character of the eye is part of, in its sentence.
  function wordOf(k) {
    const g = fine.glyphs[k], info = g && charInfo[g.s][g.i];
    return info ? words[info.word] : null;
  }

  // MARK: The sentences

  // The sentence to read, as a line of text. try.js shows it once it has formed; until then
  // its characters fly in from the eye.
  // Where the practice grid's columns fall, set by the first line after a layout. "Try another
  // sentence" changes only the words: every sentence is the size the longest one fits at, and
  // each sits on the same columns, so the grid behind them never moves.
  let gridX = null;
  function placeLines() {
    const s = demo[current].sentence, longest = Math.max(...demo.map((d) => d.sentence.length));
    const size = Math.floor(Math.min(narrow ? 40 : 64, (W - (narrow ? 32 : 240)) / longest));
    const y = lineY;
    // Centred on its ink: a closing 。 or ！ sits in the left of its square, so the line is
    // nudged right by the blank part of that square.
    const tail = /[。！？，]$/.test(s) ? size * 0.28 : 0;
    let x = Math.round((W - size * s.length) / 2 + tail);
    if (gridX == null) gridX = x;
    else x = gridX + Math.round((x - gridX) / size) * size;
    lines = [{ k: 0, text: s, size, x, y }];
    buildFlights();
    document.dispatchEvent(new CustomEvent("longyan:lines", { detail: { lines: lines.map((l) => ({ ...l })), W, H, current } }));
  }

  // Each character of the sentence floats out of somewhere in the eye, and it's the same
  // character all the way: one already in the eye where there's one to hand, or else a
  // character of the eye becomes it from the start (so pointing at it reads it in this
  // sentence). Most come from its big characters, so you see them lift out of the shape; the
  // rest from the middle sizes. Punctuation isn't in the eye, so it just fades in in place as
  // the line lands.
  function buildFlights() {
    flights = [];
    if (!fine) return;
    const all = fine.glyphs.map((g, k) => k);
    let big = all.filter((k) => fine.glyphs[k].w >= fine.unit * 6);
    let mid = all.filter((k) => fine.glyphs[k].w >= fine.unit * 3 && fine.glyphs[k].w < fine.unit * 6);
    if (big.length < 12) big = all;
    if (mid.length < 40) mid = all;
    const used = new Set();
    const sentence = demo[current].sentence, home = PAGE.findIndex((p) => p.s === sentence);
    // When each character leaves: word by word, each at a moment of its own spread over the
    // scroll (the old opening, played backwards), a word's characters a beat apart.
    const plan = [];
    let j = 0;
    for (const l of lines) [...l.text].forEach((ch, k) => {
      j++;
      if (PUNCT.test(ch)) { plan.push({ l, k, ch, punct: true }); return; }
      plan.push({ l, k, ch, j, start: LAND + hash(j * 3.3 + current) * SPREAD });
    });
    // The last few to land each get a beat of their own: no two of the final four closer than
    // a clear step, so the eye takes them one at a time.
    const last = plan.filter((e) => !e.punct).sort((a, b) => a.start - b.start);
    for (let i = Math.min(3, last.length - 1); i > 0; i--) last[i - 1].start = Math.min(last[i - 1].start, last[i].start - 0.016);
    // Where each lands: spread evenly over the eye, and taken in the order they land, so each
    // lands well away from the ones before it (farthest from those already down, leaning
    // a little to the middle so the first don't all go to the tips). The eye fills in
    // balanced, from all over at once, never piling up in one place at the end.
    const centre = (q) => { const g = fine.glyphs[q]; return [g.x + g.w / 2, g.y + g.w / 2]; };
    const landed = [];
    for (const e of [...plan].filter((e) => !e.punct).sort((a, b) => b.start - a.start)) {
      let pick = -1, best = -Infinity;
      for (const q of big) {
        if (used.has(q)) continue;
        const [x, y] = centre(q);
        const dx = (x - eye.cx) / (eye.w / 2), dy = (y - eye.cy) / (eye.h / 2);
        let near = 1e9;
        for (const [lx, ly] of landed) near = Math.min(near, Math.hypot(x - lx, (y - ly) * 1.6));
        if (!landed.length) near = eye.w;
        const score = near * (1 - 0.35 * Math.min(1, Math.hypot(dx, dy))) * (0.9 + 0.2 * hash(q * 1.37 + current)) + (fine.glyphs[q].ch === e.ch ? eye.w * 0.04 : 0);
        if (score > best) { best = score; pick = q; }
      }
      e.g = pick;
      if (pick >= 0) { used.add(pick); landed.push(centre(pick)); }
    }
    for (const e of plan) {
      const { l, k, ch } = e;
      // Punctuation isn't in the eye: it goes with the word before it, fading as that lifts off.
      if (e.punct) { const prev = flights[flights.length - 1]; flights.push({ line: l, k, ch, g: -1, start: prev ? prev.start : LAND }); continue; }
      const pick = e.g;
      if (pick < 0) continue;
      const g = fine.glyphs[pick];
      if (g.ch !== ch) {
        // It becomes this character, read in this sentence if it's one of the eye's, else
        // wherever the character comes up in them.
        let s = home, i = home >= 0 ? (l.k === 0 ? k : -1) : -1;
        if (i < 0 || PAGE[s].s[i] !== ch) { s = PAGE.findIndex((p) => p.s.includes(ch)); i = s >= 0 ? PAGE[s].s.indexOf(ch) : -1; }
        Object.assign(g, { ch }, s >= 0 ? { s, i } : {});
      }
      {
        drawLit(g, true);
      }
      flights.push({ line: l, k, ch, g: pick, x0: g.x + g.w / 2, y0: g.y + g.w / 2 + g.w * 0.04, size0: g.w * 0.94, col: g.hot, wt: g.wt, start: e.start });
    }
    // The eye spreads out from each character as it lands, nearest first, the big ones a beat
    // ahead of the small round them. Round a character still in the air the eye waits for
    // it, so none drops into a hole left for it: it lands, and the eye blooms out from it.
    const seeds = flights.filter((f) => f.g >= 0).map((f) => ({ g: fine.glyphs[f.g], at: f.start - FLASH }));
    const reach = eye.w * 0.5;
    const cx = (g) => g.x + g.w / 2, cy = (g) => g.y + g.w / 2;
    for (const g of fine.glyphs) {
      let best = GROW_END, cap = 1;
      for (const s of seeds) {
        const d = Math.hypot(cx(g) - cx(s.g), cy(g) - cy(s.g));
        best = Math.max(best, s.at - (s.at - GROW_END) * clamp(d / reach) ** 1.7);
        // Nothing round a character still in the air comes in before it lands; then the eye
        // spreads out from it, ring by ring, so it pushes out rather than being closed in on.
        const hold = Math.max(s.g.w * 1.5, eye.w * 0.09);
        if (d < hold) cap = Math.min(cap, s.at - 0.004 - 0.022 * (d / hold));
      }
      const small = 1 - clamp(g.w / (fine.unit * 8));
      g.leave = Math.max(GROW_END, Math.min(cap, best - small * 0.022 + (g.rnd - 0.5) * 0.01));
      g.cap = cap;
    }
    // That sets the order; the pace is set for the whole eye, so it never stalls between
    // landings: from the first landing to GROW_END the eye fills at a pace that eases off but
    // never stops, each character in its place in that order (and never before the one it
    // waits for).
    const p0 = Math.max(...seeds.map((s) => s.at)), order = fine.glyphs.slice().sort((a, b) => b.leave - a.leave);
    order.forEach((g, k) => {
      const x = 1 - (1 - (k + 0.5) / order.length) ** (1 / 1.5);
      g.leave = Math.max(GROW_END, Math.min(g.cap, p0 - (p0 - GROW_END) * x));
    });
    for (const g of fine.glyphs) g.seed = false;
    for (const f of flights) if (f.g >= 0) { fine.glyphs[f.g].leave = f.start - FLASH; fine.glyphs[f.g].seed = true; }
  }

  // MARK: Drawing

  function draw(t) {
    if (!lit) return;
    const p = progress;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);


    // The eye comes in from left to right, each character flashing white as it arrives; on
    // scroll its characters go, all over at once, the same way. Nothing masks it: its shape is
    // just where its characters are.
    if (p < 0.24) {
      ctx.save();
      const settled = still || t > 0.5 + SWEEP + 0.25 + COOL_T;
      if (settled && p <= 0.002) ctx.drawImage(lit, 0, 0, W, H);
      else {
        const flying = new Set();
        for (const f of flights) if (p > f.start) flying.add(f.g);
        ctx.textAlign = "center"; ctx.textBaseline = "middle";
        for (let k = 0; k < fine.glyphs.length; k++) {
          const g = fine.glyphs[k];
          const at = 0.5 + glideAt(clamp((g.x - eye.x) / eye.w + (g.rnd - 0.5) * 0.14)) * SWEEP, leave = g.leave == null ? 0.035 + g.rnd * 0.15 : g.leave;
          if ((!still && t < at) || p > leave + FLASH || flying.has(k)) continue;
          // Coming in: in colour, opening out from a little small to its size, then cooling to
          // its white. The cooling is done by the time the eye is whole (p = 0).
          const cool = Math.min(COOL, leave);
          const warm = still ? 0 : Math.max(p > leave ? 1 : 1 - (leave - p) / cool, t < at + COOL_T ? 1 - Math.max(0, t - at) / COOL_T : 0);
          if (warm > 0) {
            const pop = p > leave && !g.seed ? 1 - 0.3 * clamp((p - leave) / FLASH) : 1;
            ctx.fillStyle = rgb(mix(g.rest, g.hot, warm * warm * (3 - 2 * warm)));
            ctx.font = `${g.wt} ${g.w * 0.94 * pop}px ${ZH}`;
            ctx.fillText(g.ch, g.x + g.w / 2, g.y + g.w / 2 + g.w * 0.04);
          } else ctx.drawImage(lit, g.x * dpr, g.y * dpr, g.w * dpr, g.w * dpr, g.x, g.y, g.w, g.w);
        }
      }
      ctx.restore();
    }

    drawFlights(p);

    if (story) {
      const cls = story.classList;
      cls.toggle("is-away", p > 0.03);
      cls.toggle("is-eye", p < 0.06);
      cls.toggle("is-formed", p >= FORMED);
      holdAt(p);
    }
  }

  // Once the sentence has formed it plays on its own, in seconds, while the page holds still
  // (it never scrolls itself): a beat to see it, then the sentence catches the light, and a
  // moment later the button on to the statement comes in. Scrolling through the hold takes the
  // same timeline over: whichever is further along, the clock or the scroll, is where it is, so
  // a reader who scrolls on gets there with them rather than waiting. Scrolling back up runs it
  // backwards: the hold drains in step with the scroll, and the clock waits a moment before
  // filling it again. Above the sentence it resets, to play again next time.
  const CUE = 1.6, TRY = 4.4;
  let lastHold = -1, formed = false, hold = 0, clock = 0, lastPos = 0, backAt = -Infinity;
  function holdAt(p) {
    const now = performance.now();
    if (p < FORMED) { if (formed) story.classList.remove("tried", "try-done"); formed = false; }
    else if (!formed) { formed = true; hold = 0; clock = now; lastPos = 0; }
    // How far through the hold the scroll is: pos from where the sentence formed, scrolled from
    // just past where "Try it in your browser" stops.
    const pos = clamp((p - FORMED) / (1 - FORMED));
    const scrolled = clamp((pos - 0.06) / 0.8);
    if (formed) {
      const dt = Math.min(0.1, (now - clock) / 1000); clock = now;
      if (pos < lastPos - 1e-5) { hold *= pos / lastPos; backAt = now; }
      else if (now - backAt > 1000) hold += dt;
      lastPos = pos;
      hold = Math.min(TRY, Math.max(hold, scrolled * TRY));
    }
    const u = !formed ? 0 : still ? TRY : hold;
    // Skip tiny steps, but never the last one: the button comes in at the end.
    if (u === lastHold || (Math.abs(u - lastHold) < 0.0005 && u !== TRY && u !== 0)) return;
    lastHold = u;
    const cls = story.classList;
    if (u >= CUE) cls.add("cued");
    else if (u < CUE - 0.4) cls.remove("cued");
    if (u >= TRY) cls.add("try-done");
    else if (u < TRY - 0.4) cls.remove("try-done");
  }

  // The eye's characters floating out into the lines: up and over in an arc, growing, their
  // ink turning to white as they land.
  function drawFlights(p) {
    if (!flights.length || p >= FORMED) return;
    ctx.textAlign = "center"; ctx.textBaseline = "middle";
    for (const f of flights) {
      if (p <= f.start) continue;
      const u = easeInOut(clamp((p - f.start) / FLIGHT));
      const x1 = f.line.x + (f.k + 0.5) * f.line.size, y1 = f.line.y;
      if (f.g < 0) {
        ctx.font = `400 ${Math.round(f.line.size * 0.9 * 2) / 2}px ${ZH}`;
        ctx.globalAlpha = (f.line.k === 0 ? 1 : 0.3) * smooth(0.75, 1, u);
        ctx.fillStyle = rgb(INK);
        ctx.fillText(f.ch, x1, y1);
        continue;
      }
      const x0 = f.x0;
      const x = x0 + (x1 - x0) * u;
      const y = f.y0 + (y1 - f.y0) * u - Math.sin(u * Math.PI) * Math.min(120, Math.abs(x1 - x0) * 0.25 + 40);
      const size = f.size0 + (f.line.size * 0.9 - f.size0) * u;
      const final = f.line.k === 0 ? 1 : 0.3;
      // It leaves at the eye's weight and lands at the line's without snapping between them.
      const a = 1 - (1 - final) * smooth(0.6, 1, u), m = smooth(0.4, 0.75, u), px = Math.round(size * 2) / 2;
      ctx.fillStyle = rgb(mix(f.col, INK, smooth(0.35, 0.85, u)));
      // The lighter weight sits solid underneath and the bolder one fades off it, so the
      // character thins without dimming on the way.
      ctx.globalAlpha = a; ctx.font = `400 ${px}px ${ZH}`; ctx.fillText(f.ch, x, y);
      if (m < 1) { ctx.globalAlpha = a * (1 - m); ctx.font = `${f.wt} ${px}px ${ZH}`; ctx.fillText(f.ch, x, y); }
    }
    ctx.globalAlpha = 1;
  }

  function frame(now) {
    raf = 0;
    const t = reduce ? 100 : (now - started) / 1000;
    progress += (target - progress) * (reduce ? 1 : 0.14);
    if (Math.abs(target - progress) < 0.0004) progress = target;
    draw(t);
    if (running && visible && !reduce) raf = requestAnimationFrame(frame);
  }

  function start() { if (running) return; running = true; if (!raf) raf = requestAnimationFrame(frame); }
  function stop() { running = false; if (raf) cancelAnimationFrame(raf); raf = 0; }
  const kick = () => { if (!raf && visible) raf = requestAnimationFrame(frame); };

  // Scroll to story progress, the other way round from a story told forwards: the page opens
  // on the sentence (progress FORMED), and the first stretch of scrolling gathers its
  // characters back up into the eye (progress 0), with the rest of the eye filling in round
  // them. The pinned stretch after that holds the eye and the headline under it. The shared
  // preview (?og) is the eye.
  const gather = () => window.innerHeight * 0.54;
  function progressAt(d) { return og ? 0 : FORMED * (1 - clamp(d / gather())); }
  function readScroll() {
    if (!story) return;
    target = progressAt(-story.getBoundingClientRect().top);
    if (target > 0.02) setHover(null);
    kick();
  }

  // Where the sentence is, and where the eye has formed under the headline.
  function formedY() { return story.offsetTop; }
  function eyeY() { return story.offsetTop + gather() + window.innerHeight * 0.05; }

  // MARK: Pointing

  // `k`: one of the eye's characters, or null.
  function setHover(k) {
    const w = k == null ? null : wordOf(k);
    if (k != null && !w) k = null;
    if ((k != null && hover && hover.k === k) || (k == null && !hover)) return;
    hover = k == null ? null : { k };
    kick();
    const card = window.LongyanCard;
    if (!card) return;
    if (!hover) { card.peek(null); return; }
    const g = fine.glyphs[k], box = canvas.getBoundingClientRect();
    card.peek({ text: w.text, syl: w.syl, gloss: w.gloss },
      { left: box.left + g.x - 1, top: box.top + g.y - 1, right: box.left + g.x + g.w + 1, bottom: box.top + g.y + g.w + 1 });
  }
  const ready = () => fine && progress <= 0.02 && (reduce || (performance.now() - started) / 1000 > 0.5 + SWEEP + 0.25);
  // The eye's character under the pointer, or null off the mark.
  function charAt(e) {
    if (!ready()) return null;
    const box = canvas.getBoundingClientRect(), f = fine;
    const c = Math.floor((e.clientX - box.left - f.ux0) / f.unit), r = Math.floor((e.clientY - box.top - f.uy0) / f.unit);
    if (c < 0 || r < 0 || c >= f.ucols || r >= f.urows) return null;
    const k = f.owner[r * f.ucols + c];
    return k >= 0 ? k : null;
  }
  window.LongyanHero = {
    lines: () => lines.map((l) => ({ ...l })),
    formedY,
    eyeY,
    setCurrent(k) { current = k; placeLines(); kick(); },
  };

  let resizeTimer = 0, lastW = 0;
  window.addEventListener("resize", () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      // Phones resize when the toolbar hides; only rebuild when the width changes.
      if (window.innerWidth === lastW && narrow) return;
      lastW = window.innerWidth;
      setHover(null); layout(); readScroll(); kick();
    }, 120);
  });
  window.addEventListener("scroll", readScroll, { passive: true });
  const pin = canvas.parentElement;
  const offCopy = (e) => e.target.closest("a, button, .hero-copy h1, .hero-sub, .hero-actions, .try, .bar");
  pin.addEventListener("pointermove", (e) => {
    if (e.pointerType === "touch" || offCopy(e)) { if (e.pointerType !== "touch") setHover(null); return; }
    setHover(charAt(e));
  });
  // A finger lifting counts as leaving, so only a mouse puts the word away here.
  pin.addEventListener("pointerleave", (e) => { if (e.pointerType !== "touch") setHover(null); });
  // On a phone a tap shows the word, and it stays until a tap anywhere else or a real scroll.
  let tapY = 0;
  document.addEventListener("pointerdown", (e) => {
    if (e.pointerType !== "touch") return;
    tapY = window.scrollY;
    setHover(pin.contains(e.target) && !offCopy(e) ? charAt(e) : null);
  });
  window.addEventListener("scroll", () => { if (hover && Math.abs(window.scrollY - tapY) > 30) setHover(null); }, { passive: true });
  document.addEventListener("visibilitychange", () => { visible = !document.hidden; if (visible && running) kick(); });
  new IntersectionObserver((entries) => { for (const e of entries) e.isIntersecting ? start() : stop(); }).observe(canvas);


  function boot() {
    lastW = window.innerWidth;
    layout();
    // ?t=5 starts five seconds in, for screenshots.
    started = performance.now() - (+params.get("t") || 0) * 1000;
    readScroll();
    progress = target;
    if (reduce) draw(100); else start();
  }
  // The text needs the Chinese font loaded, or it would be drawn in a fallback.
  const fontsReady = document.fonts && document.fonts.load ? Promise.all([document.fonts.load(`400 14px ${ZH}`, "眼"), document.fonts.load(`600 14px ${ZH}`, "眼")]).catch(() => {}) : Promise.resolve();
  // The eye is drawn once the font is in, or after 1.5 s with whatever the browser has.
  Promise.race([fontsReady, new Promise((r) => setTimeout(r, 1500))]).then(boot);
})();
