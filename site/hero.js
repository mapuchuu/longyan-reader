// The opening: the Longyan eye over a range of mountains, all of it in Chinese characters.
//
// The mountains are drawn the way a halftone draws, by how much ink each character has:
// light characters (一, 人) where it's dim, dense ones where it's bright, none where it's
// dark, on a 4×4 ordered dither. A few faint characters are stars.
//
// The eye is set in everyday sentences, in characters of many sizes: big ones where the mark
// is thick, smaller and smaller toward its edges. Every character is whole and sits inside
// the mark, a vector built from its geometry (below); nothing is masked, so the shape is just
// where the characters are, traced finely by the smallest. Characters with too little ink to
// fill their square (一, 人, 了…) are left out. Pointing at a character shows the word it's
// part of and what it means in its sentence: the app's own reading (scripts/site-data.py).
// Scrolling breaks the eye up, and characters float out of it from all over into the demo
// sentence, which try.js lets you read.
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
  const ZH = '"PingFang SC", "Hiragino Sans GB", "Noto Sans SC", "Microsoft YaHei", sans-serif';
  // The hero's one ink: blue to lavender, left to right.
  const BLUE = [161, 189, 227], LAV = [194, 171, 224], INK = [245, 245, 247];
  const PUNCT = /[，。？！、：；“”（）《》…—]/;
  // Characters too light to fill a square of the eye.
  const SPARSE = /[一二三十八人入了个上下几儿小大卜七九工口]/;
  const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x));
  const smooth = (a, b, x) => { const u = clamp((x - a) / (b - a)); return u * u * (3 - 2 * u); };
  const easeInOut = (u) => (u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2);
  const hash = (i) => { const s = Math.sin(i * 12.9898) * 43758.5453; return s - Math.floor(s); };
  const mix = (a, b, u) => a.map((v, k) => Math.round(v + (b[k] - v) * clamp(u)));
  const rgb = (c, a = 1) => `rgba(${c[0]},${c[1]},${c[2]},${a})`;

  // Noise for the mountains and the mist.
  const h1 = (x) => { const s = Math.sin(x * 127.1) * 43758.5453; return s - Math.floor(s); };
  const n1 = (x) => { const i = Math.floor(x); let f = x - i; f = f * f * (3 - 2 * f); return h1(i) + (h1(i + 1) - h1(i)) * f; };
  const h2 = (x, y) => { const s = Math.sin(x * 127.1 + y * 311.7) * 43758.5453; return s - Math.floor(s); };
  function n2(x, y) {
    const ix = Math.floor(x), iy = Math.floor(y);
    let fx = x - ix, fy = y - iy; fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy);
    const a = h2(ix, iy), b = h2(ix + 1, iy), c = h2(ix, iy + 1), d = h2(ix + 1, iy + 1);
    return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy;
  }
  function fbm(x, y) { let s = 0, a = 0.5; for (let i = 0; i < 4; i++) { s += a * n2(x, y); x = x * 2.02 + 9.7; y = y * 2.02 + 9.7; a *= 0.5; } return s; }
  function ridge(x) { let v = 0, a = 0.55, f = 1; for (let i = 0; i < 5; i++) { v += a * (1 - Math.abs(2 * n1(x * f) - 1)); a *= 0.48; f *= 2.13; } return v; }
  // 4×4 ordered-dither thresholds, 0..1.
  const BAYER = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map((v) => (v + 0.5) / 16);

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
  // The characters the mountains are drawn with: every one in the sentences.
  const CHARS = [...new Set(PAGE.map((p) => p.s).join(""))].filter((ch) => !PUNCT.test(ch));

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
    // Each character's tint, from a slow field across the eye: mostly blue and lavender, with
    // a little rose and mint where the field turns, like the colours in a pearl.
    for (const g of out) {
      const u = (g.x + g.w / 2 - eye.x) / eye.w, v = (g.y + g.w / 2 - eye.y) / eye.h;
      g.col = pearl(0.62 * u + 0.3 * v + 0.12 * Math.sin(6.2 * v + 2.4 * u) + (g.rnd - 0.5) * 0.1);
    }
    return { unit: h, ucols, urows, ux0, uy0, owner, glyphs: out };
  }
  // The pearl tints in order; t runs 0..1 across the eye and wraps.
  const PEARL = [[158, 208, 222], BLUE, LAV, [222, 174, 208], LAV, BLUE];
  function pearl(t) {
    t = ((t % 1) + 1) % 1 * PEARL.length;
    const i = Math.floor(t), f = t - i, a = PEARL[i], b = PEARL[(i + 1) % PEARL.length];
    return mix(a, b, f * f * (3 - 2 * f));
  }

  let W = 0, H = 0, dpr = 1, narrow = false;
  let fine = null;                     // the eye's characters: { unit, glyphs, owner… }
  let eye = { x: 0, y: 0, w: 1, h: 1, cx: 0, cy: 0, s: 1 };
  let lit = null;                      // the eye's text, pre-drawn
  let current = 0, lines = [], flights = [];
  let started = performance.now(), running = false, visible = true, raf = 0;
  let progress = 0, target = 0;
  let hover = null;                    // { k }: the eye's character pointed at

  // The mountains' grid, and an atlas of the characters in four tints, by ink.
  let cell = 12, cols = 0, rows = 0, zh = 10, tile = 24, landBase = 0.8;
  let order_ = [], landAtlas = [], star = null, tops = [], copyBand = null;
  const atlasCols = 32;

  function markMatrix() {
    const s = eye.s;
    return [s, 0, 0, s, eye.cx - MC[0] * s, eye.cy - MC[1] * s];
  }

  function buildAtlas() {
    tile = Math.max(8, Math.round(cell * dpr));
    const white = document.createElement("canvas");
    white.width = atlasCols * tile; white.height = Math.ceil(CHARS.length / atlasCols) * tile;
    const g = white.getContext("2d", { willReadFrequently: true });
    g.fillStyle = "#fff"; g.textAlign = "center"; g.textBaseline = "middle";
    g.font = `400 ${Math.round(zh * dpr)}px ${ZH}`;
    CHARS.forEach((ch, k) => g.fillText(ch, (k % atlasCols) * tile + tile / 2, ((k / atlasCols) | 0) * tile + tile / 2 + dpr * 0.5));
    // Ink per character, measured once.
    const data = g.getImageData(0, 0, white.width, white.height).data;
    const ink = CHARS.map((_, k) => {
      const x0 = (k % atlasCols) * tile, y0 = ((k / atlasCols) | 0) * tile;
      let s = 0;
      for (let y = y0; y < y0 + tile; y++) for (let x = x0; x < x0 + tile; x++) s += data[(y * white.width + x) * 4 + 3];
      return s;
    });
    order_ = CHARS.map((_, k) => k).sort((a, b) => ink[a] - ink[b]);
    landAtlas = [0, 1, 2, 3].map((k) => {
      const a = document.createElement("canvas");
      a.width = white.width; a.height = white.height;
      const t = a.getContext("2d");
      t.drawImage(white, 0, 0);
      t.globalCompositeOperation = "source-in";
      t.fillStyle = rgb(mix(BLUE, LAV, k / 3)); t.fillRect(0, 0, a.width, a.height);
      return a;
    });
  }
  // A character with about `u` (0..1) of the most ink, varied by `seed`; reflected at the
  // ends rather than clamped, so the densest isn't picked half the time.
  function byInk(u, seed, spread = 0.08) {
    let v = u + (seed - 0.5) * spread * 2;
    if (v > 1) v = 2 - v; else if (v < 0) v = -v;
    return order_[Math.round(clamp(v) * (order_.length - 1))];
  }
  function blit(atlas, k, c, r) {
    ctx.drawImage(atlas, (k % atlasCols) * tile, ((k / atlasCols) | 0) * tile, tile, tile, c * cell, r * cell, cell, cell);
  }

  function layout() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    W = canvas.clientWidth; H = canvas.clientHeight;
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
    narrow = W < 760;
    // The eye: on wide screens, beside the headline and second to it, about as tall as the
    // headline and the line under it, centred on the text; on narrow ones, at the top.
    let ew, cx, cy;
    if (narrow) {
      const copy = document.querySelector(".hero-copy");
      const top = 60, bottom = copy ? copy.getBoundingClientRect().top - canvas.getBoundingClientRect().top : H * 0.55;
      ew = Math.min(W * 0.8, (bottom - top - 48) * (MW / MH)); cx = W / 2; cy = (top + bottom) / 2 - 10;
    } else {
      ew = Math.min(W * 0.26, H * 0.42 * (MW / MH), 470);
      cx = Math.min(W * 0.7, (W + 1120) / 2 - ew / 2 + 20); cy = H * 0.45;
    }
    const eh = ew * (MH / MW);
    eye = { w: ew, h: eh, cx, cy, x: cx - ew / 2, y: cy - eh / 2, s: ew / MW };

    // The eye's text: the smallest whole characters about 58 to the eye's width (fewer on a
    // small eye, so they stay characters rather than dust).
    const unit = clamp(Math.round((ew / 58) * 4) / 4, 4.5, 8);
    fine = pack(unit);
    lit = document.createElement("canvas");
    lit.width = canvas.width; lit.height = canvas.height;
    const l = lit.getContext("2d");
    l.setTransform(dpr, 0, 0, dpr, 0, 0); l.textAlign = "center"; l.textBaseline = "middle";
    for (const g of fine.glyphs) {
      l.fillStyle = rgb(g.col);
      // Big characters a little lighter in weight, so they don't outshine the rest.
      l.font = `${g.w >= unit * 3 ? 500 : 600} ${g.w * 0.94}px ${ZH}`;
      l.fillText(g.ch, g.x + g.w / 2, g.y + g.w / 2 + g.w * 0.04);
    }

    // The mountains, under the eye.
    cell = narrow ? 10 : W < 1200 ? 11 : 12;
    zh = cell * 0.88;
    cols = Math.ceil(W / cell); rows = Math.ceil(H / cell);
    buildAtlas();
    tops = [];
    // The ranges start just under the eye, so it stands over them; on a wide screen, under
    // the headline's last line too.
    landBase = Math.min(narrow ? 0.74 : 0.84, (eye.y + eye.h) / H + (narrow ? 0.1 : 0.085));
    const copyEl = document.querySelector(".hero-copy");
    if (!narrow && copyEl) {
      const cb = copyEl.getBoundingClientRect(), top = canvas.getBoundingClientRect().top;
      landBase = Math.min(0.86, Math.max(landBase, (cb.bottom - top) / H + 0.075));
    }
    // On a phone the headline sits over the mountains: they go quiet behind it.
    const copy = document.querySelector(".hero-copy");
    if (narrow && copy) {
      const cb = copy.getBoundingClientRect(), top = canvas.getBoundingClientRect().top;
      copyBand = [cb.top - top - 10, cb.bottom - top + 10];
    } else copyBand = null;
    star = new Float32Array(cols * rows);
    const skyBottom = landBase * H - 30, pad = cell * 3;
    for (let i = 0; i < star.length; i++) {
      const x = (i % cols) * cell, y = ((i / cols) | 0) * cell;
      const nearEye = x > eye.x - pad && x < eye.x + eye.w + pad && y > eye.y - pad && y < eye.y + eye.h + pad;
      if (y < skyBottom && !nearEye && hash(i) < (narrow ? 0.005 : 0.0045)) star[i] = 0.5 + hash(i + 7) * 6.28;
    }
    placeLines();
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
  function placeLines() {
    const s = demo[current].sentence;
    const size = Math.floor(Math.min(narrow ? 40 : 64, (W - (narrow ? 32 : 240)) / s.length));
    const y = Math.round(H * (narrow ? 0.4 : 0.42));
    lines = [{ k: 0, text: s, size, x: Math.round((W - size * s.length) / 2), y }];
    buildFlights();
    document.dispatchEvent(new CustomEvent("longyan:lines", { detail: { lines: lines.map((l) => ({ ...l })), W, H, current } }));
  }

  // Each character of the sentence floats out of somewhere in the eye, the same character
  // when one's to hand. Most come from its big characters, so you see them lift out of the
  // shape; the rest from the middle sizes.
  function buildFlights() {
    flights = [];
    if (!fine) return;
    const all = fine.glyphs.map((g, k) => k);
    let big = all.filter((k) => fine.glyphs[k].w >= fine.unit * 6);
    let mid = all.filter((k) => fine.glyphs[k].w >= fine.unit * 3 && fine.glyphs[k].w < fine.unit * 6);
    if (big.length < 12) big = all;
    if (mid.length < 40) mid = all;
    const used = new Set();
    let j = 0;
    for (const l of lines) [...l.text].forEach((ch, k) => {
      j++;
      const pool = hash(j * 5.1 + current * 2.3) < 0.6 ? big : mid;
      let pick = -1;
      for (let a = 0; a < 40; a++) {
        const q = pool[Math.floor(hash(current * 97 + j * 13.1 + a * 0.71) * pool.length)];
        if (used.has(q)) continue;
        if (pick < 0) pick = q;
        if (fine.glyphs[q].ch === ch) { pick = q; break; }
      }
      if (pick < 0) return;
      used.add(pick);
      const g = fine.glyphs[pick];
      flights.push({ line: l, k, ch, g: pick, x0: g.x + g.w / 2, y0: g.y + g.w / 2, size0: g.w * 0.94, col: g.col,
        start: 0.04 + hash(j * 3.3 + current) * 0.1 });
    });
  }

  // MARK: Drawing

  // The mountains: four ranges, far to near, each a ridge line with a bright rim that fades
  // into the body below it, and mist drifting through the valleys.
  function drawLand(t, sink) {
    const intro = still ? 0 : (1 - smooth(0, 1.4, t)) * 0.25;
    const asp = W / H;
    if (!tops.length || tops[0].length !== cols) tops = [0, 1, 2, 3].map(() => new Float32Array(cols));
    let highest = 1;
    // The ridges are measured against the screen's height, as on a phone, so a wide screen
    // gets broad ranges rather than more, smaller bumps. On a wide screen they stay low under
    // the headline, and open into a valley under the eye, so it floats clear over it with
    // ranges rising either side. The layers spread further down, to the bottom of the screen.
    // As the story plays they fall away and fade, the near ranges fastest. (On a phone they
    // fade by falling behind the headline's quiet band; a wide screen fades them outright.)
    const fade = narrow ? 1 : 1 - 0.72 * sink;
    const span = narrow ? H : H * 1.7, step = narrow ? 0.055 : 0.068;
    for (let k = 0; k < 4; k++) {
      const amp = (narrow ? 0.15 : 0.18) - 0.028 * k;
      const base = landBase + step * k + intro + sink * 1.9 * (0.06 + 0.05 * k);
      for (let c = 0; c < cols; c++) {
        const px = (c + 0.5) * cell, x = px / span;
        const env = narrow ? 1 : (0.38 + 0.62 * smooth(W * 0.28, eye.x, px)) * (1 - 0.6 * Math.exp(-Math.pow((px - eye.cx) / (eye.w * 0.34), 2)));
        tops[k][c] = base - amp * env * ridge(x * (0.85 + 0.45 * k) + k * 13.7);
        if (tops[k][c] < highest) highest = tops[k][c];
      }
    }
    const r0 = Math.max(0, Math.floor((highest * H) / cell) - 1);
    for (let r = r0; r < rows; r++) {
      const y = ((r + 0.5) * cell) / H;
      const quiet = copyBand ? 1 - 0.7 * smooth(copyBand[0] - 40, copyBand[0] + 10, y * H) * (1 - smooth(copyBand[1] - 10, copyBand[1] + 40, y * H)) : 1;
      const band = smooth(landBase - 0.05, landBase + 0.12, y) * (1 - smooth(landBase + 0.12, 1, y)) * (1 - sink * 0.6);
      for (let c = 0; c < cols; c++) {
        let layer = -1, depth = 0;
        for (let k = 0; k < 4; k++) if (y > tops[k][c]) { layer = k; depth = y - tops[k][c]; }
        if (layer < 0) continue;
        let L = Math.exp(-depth * 80) * (0.46 - 0.04 * layer) + Math.exp(-depth * (14 + 3 * layer)) * (0.16 - 0.02 * layer);
        if (band > 0.01) L += Math.max(0, fbm(((c + 0.5) / cols) * asp * 1.6 - t * 0.025, y * 7 + t * 0.01) - 0.5) * 0.7 * band;
        const v = L * 2.3;
        if (v < BAYER[(r & 3) * 4 + (c & 3)] * 0.85 + 0.06) continue;
        // Quantized, so a cell keeps its character until the light on it really changes.
        const level = Math.min(7, Math.floor(v * 6));
        ctx.globalAlpha = Math.min(1, 0.32 + v * 0.5) * quiet * fade;
        blit(landAtlas[layer], byInk(level / 9, hash((r * cols + c) * 1.7 + level), 0.06), c, r);
      }
    }
    ctx.globalAlpha = 1;
  }

  function drawStars(t, p) {
    const fade = (1 - smooth(0.02, 0.2, p)) * (still ? 1 : smooth(0.2, 1.2, t));
    if (fade < 0.02) return;
    for (let i = 0; i < star.length; i++) {
      if (!star[i]) continue;
      const a = (0.16 + 0.12 * Math.sin(t * 0.7 + star[i])) * fade;
      if (a < 0.03) continue;
      ctx.globalAlpha = a;
      blit(landAtlas[1], byInk(0.25, hash(i * 7.7 + 3), 0.2), i % cols, (i / cols) | 0);
    }
    ctx.globalAlpha = 1;
  }

  function draw(t) {
    if (!lit) return;
    const p = progress;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    drawStars(t, p);
    drawLand(t, smooth(0.02, 0.3, p));

    // The eye comes in from left to right, each character flashing white as it arrives; on
    // scroll its characters go, all over at once, the same way. Nothing masks it: its shape is
    // just where its characters are.
    if (p < 0.24) {
      ctx.save();
      const settled = still || t > 0.5 + 1.0 + 0.25 + 0.2;
      if (settled && p <= 0.035) ctx.drawImage(lit, 0, 0, W, H);
      else {
        const flying = new Set();
        for (const f of flights) if (p > f.start) flying.add(f.g);
        ctx.textAlign = "center"; ctx.textBaseline = "middle"; ctx.fillStyle = "#fff";
        for (let k = 0; k < fine.glyphs.length; k++) {
          const g = fine.glyphs[k];
          const at = 0.5 + ((g.x - eye.x) / eye.w) * 1.0 + g.rnd * 0.25, leave = 0.035 + g.rnd * 0.15;
          if ((!still && t < at) || p > leave + 0.02 || flying.has(k)) continue;
          if ((!still && t < at + 0.2) || p > leave) {
            ctx.font = `600 ${g.w * 0.94}px ${ZH}`;
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
      cls.toggle("is-formed", p >= FORMED);
    }
  }

  // The eye's characters floating out into the lines: up and over in an arc, growing, their
  // ink turning to white as they land.
  function drawFlights(p) {
    if (!flights.length || p < 0.035 || p >= FORMED + 0.004) return;
    ctx.textAlign = "center"; ctx.textBaseline = "middle";
    for (const f of flights) {
      if (p <= f.start) continue;
      const u = easeInOut(clamp((p - f.start) / 0.18));
      const x1 = f.line.x + (f.k + 0.5) * f.line.size, y1 = f.line.y;
      const x0 = f.x0;
      const x = x0 + (x1 - x0) * u;
      const y = f.y0 + (y1 - f.y0) * u - Math.sin(u * Math.PI) * Math.min(120, Math.abs(x1 - x0) * 0.25 + 40);
      const size = f.size0 + (f.line.size * 0.9 - f.size0) * u;
      const final = f.line.k === 0 ? 1 : 0.3;
      ctx.font = `${u > 0.6 ? 400 : 600} ${Math.round(size * 2) / 2}px ${ZH}`;
      ctx.globalAlpha = 1 - (1 - final) * smooth(0.6, 1, u);
      ctx.fillStyle = rgb(mix(f.col, INK, smooth(0.35, 0.85, u)));
      ctx.fillText(f.ch, x, y);
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

  function readScroll() {
    if (!story) return;
    const travel = story.offsetHeight - window.innerHeight;
    target = travel > 0 ? clamp(-story.getBoundingClientRect().top / travel) : 0;
    if (target > 0.02) setHover(null);
    if (reduce) kick();
  }

  // Where to scroll to see the sentences formed.
  function formedY() { return story.offsetTop + (FORMED + 0.04) * (story.offsetHeight - window.innerHeight); }

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
    const hint = document.getElementById("hint");
    if (hint) hint.classList.add("done");
    const g = fine.glyphs[k], box = canvas.getBoundingClientRect();
    card.peek({ text: w.text, syl: w.syl, gloss: w.gloss },
      { left: box.left + g.x - 1, top: box.top + g.y - 1, right: box.left + g.x + g.w + 1, bottom: box.top + g.y + g.w + 1 });
  }
  const ready = () => fine && progress <= 0.02 && (reduce || (performance.now() - started) / 1000 > 1.8);
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
  pin.addEventListener("pointerleave", () => setHover(null));
  // On a phone a tap shows the word, and a tap anywhere else puts it away.
  pin.addEventListener("pointerdown", (e) => {
    if (e.pointerType !== "touch" || offCopy(e)) return;
    setHover(charAt(e));
  });
  document.addEventListener("visibilitychange", () => { visible = !document.hidden; if (visible && running) kick(); });
  new IntersectionObserver((entries) => { for (const e of entries) e.isIntersecting ? start() : stop(); }).observe(canvas);

  function boot() {
    lastW = window.innerWidth;
    layout();
    // ?t=5 starts five seconds in and ?p=0.6 jumps to that point of the story, for screenshots.
    started = performance.now() - (+params.get("t") || 0) * 1000;
    if (params.has("p")) window.scrollTo(0, story.offsetTop + +params.get("p") * (story.offsetHeight - window.innerHeight));
    readScroll();
    progress = target;
    document.documentElement.classList.add("hero-ready");
    if (reduce) draw(100); else start();
  }
  // The text needs the Chinese font loaded, or it would be drawn in a fallback.
  const fontsReady = document.fonts && document.fonts.load ? Promise.all([document.fonts.load(`400 14px ${ZH}`, "眼"), document.fonts.load(`600 14px ${ZH}`, "眼")]).catch(() => {}) : Promise.resolve();
  fontsReady.then(boot);
})();
