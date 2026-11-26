// The film: one continuous shot of a desktop, read in three apps. Everything on screen is a
// pure function of the time t (seconds), so it can be rendered frame by frame: film.render(t).
// The cards are the site's port of the app's cards (card.js), filled with the app's own
// lookups of these sentences (data.js, from LongyanReader --site-json).
(() => {
  const FPS = 60;
  const $ = (s) => document.querySelector(s);
  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
  const lerp = (a, b, u) => a + (b - a) * u;
  // SwiftUI's spring(response:dampingFraction:), 0 → 1.
  function spring(response, damping) {
    const w = (2 * Math.PI) / response, z = damping;
    if (z >= 1) return (t) => (t <= 0 ? 0 : 1 - (1 + w * t) * Math.exp(-w * t));
    const wd = w * Math.sqrt(1 - z * z);
    return (t) => (t <= 0 ? 0 : 1 - Math.exp(-z * w * t) * (Math.cos(wd * t) + ((z * w) / wd) * Math.sin(wd * t)));
  }
  const CHIP_IN = spring(0.3, 0.68), CHIP_HOVER = spring(0.25, 0.7), PRESS = spring(0.2, 0.7), CARD_IN = spring(0.32, 0.82);
  // A hand's reach: minimum jerk.
  const reach = (u) => { u = clamp(u); return u * u * u * (10 - 15 * u + 6 * u * u); };
  const sine = (u) => 0.5 - 0.5 * Math.cos(Math.PI * clamp(u));

  const cam = $("#cam"), cursorEl = $("#cursor"), chipEl = $("#chip");
  const W = 1440, H = 810;
  const WIN = !!window.FILM_WIN;
  let winSel = null;
  const END = 6.5;   // seconds of the Windows cut's end card
  const END_MAC = 9.6;   // the Mac cut's: the three 白 side by side, then the name, then dark for the loop

  // MARK: The scenes

  // One word, three apps, three meanings: 白, which every learner knows as "white", and
  // never means white here. The window on top first (the news), then the chat under it, then a novel.
  const SCENES = [
    { id: "a", win: "#w-a", data: FILM.a, sel: [10, 11], kind: "word", hold: 4.7, pickAt: 1.9, tip: true },
    { id: "b", win: "#w-b", data: FILM.b, sel: [9, 10], kind: "word", hold: 4.7, pickAt: 1.9, tip: true, focus: ".room .input", context: ".room" },
    { id: "c", win: "#w-c", data: FILM.c, sel: [7, 8], kind: "word", hold: 4.7, pickAt: 1.9, tip: true },
  ];
  // The end: the three sentences, their 白 in one column, each with what it meant there.
  // Top down from the last one seen (the push lands on its 白), so the film's last words are
  // "free of charge".
  const ROWS = [["讲得很", "", "clear"], ["外面全", "了", "white"], ["第二件", "送", "free of charge"]];
  const PICK = spring(0.5, 0.86);
  const pickAt = (s) => s.pickAt || 0.95;   // seconds after a card opens that its light draws in   // the light drawing in onto the meaning picked
  const OPEN = 0.7;   // seconds the opening line holds before the first reach
  const REST = { x: 1150, y: 700 };
  const MENUS = {
    "w-a": ["Safari", "文件　编辑　显示　历史记录　书签　窗口　帮助"],
    "w-b": ["聊天", "文件　编辑　显示　会话　窗口　帮助"],
    "w-c": ["预览", "文件　编辑　显示　前往　工具　窗口　帮助"],
  };   // where the pointer waits, at the start and the end

  // Geometry, measured once with the camera at rest (screen points = set points).
  function measure() {
    for (const s of SCENES) {
      const win = $(s.win), span = win.querySelector(".s"), node = span.firstChild;
      s.winEl = win;
      s.hl = win.querySelector(".hl");
      const hb = s.hl.parentElement.getBoundingClientRect();
      s.hlOrigin = { x: hb.left, y: hb.top };
      s.chars = [];
      for (let i = 0; i < node.length; i++) {
        const r = document.createRange(); r.setStart(node, i); r.setEnd(node, i + 1);
        const b = r.getBoundingClientRect();
        s.chars.push({ left: b.left, right: b.right, top: b.top, bottom: b.bottom });
      }
      const [a, b] = s.sel, cs = s.chars.slice(a, b);
      s.rect = { left: cs[0].left, right: cs[cs.length - 1].right, top: Math.min(...cs.map((c) => c.top)), bottom: Math.max(...cs.map((c) => c.bottom)) };
      s.rect.midY = (s.rect.top + s.rect.bottom) / 2;
      s.chip = { x: s.rect.right + 4 + 15, y: s.rect.midY };
      s.text = [...win.querySelectorAll(".t, h1")].map((e) => e.getBoundingClientRect());
      s.box = win.getBoundingClientRect();
      if (s.focus) {
        const h = win.querySelector(s.focus).getBoundingClientRect(), c = win.querySelector(s.context).getBoundingClientRect();
        s.focusPt = { x: h.right - 110, y: (h.top + h.bottom) / 2 };
        s.contextRect = { left: c.left, right: c.right, top: c.top, bottom: c.bottom };
        s.wantWinShot = true;
      }
    }
  }

  // MARK: The timeline

  let T = 0, moves = [], downs = [], plan = [];
  function schedule() {
    let t = OPEN;
    let from = { ...REST };
    moves = []; downs = []; plan = [];
    SCENES.forEach((s, k) => {
      const tLeave = t;
      let tFocus = null;
      if (s.focusPt) {
        // A window that's mostly covered is clicked to the front first (on its title, clear of the
        // card that's open), and held a moment so it can be read before anything is chosen in it.
        const far = Math.hypot(s.focusPt.x - from.x, s.focusPt.y - from.y);
        const go = clamp(0.62 + far / 1400, 0.7, 1.15);
        moves.push({ t0: t, t1: t + go, from, to: s.focusPt, bend: -0.12 });
        tFocus = t + go + 0.1;
        downs.push({ t: tFocus, up: tFocus + 0.1, win: s.winEl });
        if (plan.length) plan[plan.length - 1].tClose = tFocus;
        from = s.focusPt;
        t = tFocus + 0.1 + 0.85;
      }
      const start = { x: s.rect.left + 1.5, y: s.rect.midY };
      const far = Math.hypot(start.x - from.x, start.y - from.y);
      const go = clamp(0.62 + far / 1400, 0.7, 1.15);
      moves.push({ t0: t, t1: t + go, from, to: start, bend: k % 2 ? -0.1 : 0.12 });
      const tReached = t + go;
      const tDown = t + go + (k ? 0.45 : 0.14);
      const n = s.sel[1] - s.sel[0];
      const drag = 0.2 + 0.07 * n;
      const end = { x: s.rect.right - 1.5, y: s.rect.midY };
      moves.push({ t0: tDown + 0.03, t1: tDown + 0.03 + drag, from: start, to: end, drag: true });
      const tUp = tDown + 0.03 + drag + 0.08;
      const tChip = tUp + 0.12;
      const toChip = { x: s.chip.x - 1, y: s.chip.y + 1 };
      const m0 = tChip + 0.2;
      moves.push({ t0: m0, t1: m0 + 0.42, from: end, to: toChip, bend: -0.25 });
      const tPress = m0 + 0.42 + 0.16, tRelease = tPress + 0.1, tOpen = tRelease + 0.03;
      downs.push({ t: tDown, up: tUp, win: s.winEl });
      downs.push({ t: tPress, up: tRelease, win: null });
      const p = { s, tLeave, tFocus, tReached, tDown, tUp, tChip, tPress, tRelease, tOpen, tClose: Infinity, start, end, toChip };
      if (plan.length && tFocus === null) plan[plan.length - 1].tClose = tDown;
      plan.push(p);
      from = toChip;
      t = tOpen + s.hold;
    });
    if (WIN) {
      // Out: a click on the page's margin puts the last card away, and the pointer goes back to
      // where it waits; the camera opens back out to the whole desk.
      const click = { x: 1150, y: 640 };
      moves.push({ t0: t, t1: t + 0.8, from, to: click, bend: 0.12 });
      const tOut = t + 0.8 + 0.12;
      downs.push({ t: tOut, up: tOut + 0.1, win: $("#w-c") });
      plan[plan.length - 1].tClose = tOut;
      moves.push({ t0: tOut + 0.5, t1: tOut + 1.4, from: click, to: REST, bend: -0.1 });
      // The Windows cut ends on a title card (win.js), held long enough to read.
      plan.tEnd = Math.round((tOut + 3.4) * FPS) / FPS;
      plan.tOut = tOut;
      T = Math.round((plan.tEnd + END) * FPS) / FPS;
    } else {
      // Out, on the Mac: the last card stays, and the camera keeps going into it until only its
      // glass and its word are left; the end card takes over from there.
      plan.tOut = t - 0.5;
      plan.tEnd = t + 0.6;
      T = Math.round((plan.tEnd + END_MAC) * FPS) / FPS;
    }
  }

  function cursorAt(t) {
    let pos = { ...REST }, moving = null;
    for (const m of moves) {
      if (t >= m.t1) pos = { ...m.to };
      else if (t >= m.t0) { moving = m; break; }
      else break;
    }
    if (moving) {
      const m = moving, u = (t - m.t0) / (m.t1 - m.t0);
      if (m.drag) {
        const e = sine(u);
        pos = { x: lerp(m.from.x, m.to.x, e), y: lerp(m.from.y, m.to.y, e) };
      } else {
        const e = reach(u);
        const dx = m.to.x - m.from.x, dy = m.to.y - m.from.y, d = Math.hypot(dx, dy) || 1;
        const cx = (m.from.x + m.to.x) / 2 - (dy / d) * d * m.bend, cy = (m.from.y + m.to.y) / 2 + (dx / d) * d * m.bend;
        pos = { x: (1 - e) * (1 - e) * m.from.x + 2 * (1 - e) * e * cx + e * e * m.to.x, y: (1 - e) * (1 - e) * m.from.y + 2 * (1 - e) * e * cy + e * e * m.to.y };
      }
    }
    return pos;
  }

  // The window in front, and which is key, from the clicks so far.
  function windowsAt(t) {
    const order = ["#w-b", "#w-a", "#w-c"].map((s) => $(s));
    let key = $("#w-c");
    for (const d of downs) {
      if (d.t > t) break;
      if (!d.win) continue;
      key = d.win;
      order.splice(order.indexOf(d.win), 1); order.push(d.win);
    }
    return { order, key };
  }

  // MARK: The camera
  // Follows a target with a critically damped spring (log zoom), simulated once for the whole
  // film so any frame can be drawn on its own.
  let camPath = [];
  function targetAt(t) {
    const wide = { x: W / 2, y: H / 2, z: 1 };
    for (let i = plan.length - 1; i >= 0; i--) {
      const p = plan[i], s = p.s;
      if (t < p.tLeave + 0.1) continue;
      if (t >= plan.tOut + 0.15) {
        if (WIN || !p.frame) return wide;
        return p.frame;   // the Mac cut's push is drawn by pushAt, not the spring
      }
      // On the way from one card to the next, the camera eases out a little and over.
      const prev = i > 0 ? plan[i - 1] : null;
      const here = s.winShot || focus(s);
      if (prev && t < p.tLeave + 0.55) {
        const a = prev.frame || focus(prev.s);
        return { x: (a.x + here.x) / 2, y: (a.y + here.y) / 2, z: Math.min(a.z, here.z) * 0.78 };
      }
      const tp = p.tOpen + pickAt(s) + 0.3;
      if (t >= tp && p.pickFrame) {
        // held, it keeps going in, slowly, so no frame stands still
        const f = p.pickFrame;
        return { x: f.x, y: f.y, z: f.z * (1 + 0.022 * Math.min(2.5, t - tp)) };
      }
      if (t >= p.tOpen + 0.05 && p.frame) return p.frame;
      return here;
    }
    return wide;
  }
  // A window brought forward is shown whole while its words are found and selected.
  function winShot(s) {
    const r = s.box, pad = 36;
    const z = Math.min(1.75, W / (r.right - r.left + pad * 2), H / (r.bottom - r.top + pad * 2));
    return onStage({ x: (r.left + r.right) / 2, y: (r.top + r.bottom) / 2, z });
  }
  function focus(s) {
    return { x: (s.rect.left + s.rect.right) / 2 + 40, y: s.rect.midY + 60, z: 1.65 };
  }
  function frameFor(p, card, cap = 1.75) {
    const s = p.s, r = card;
    const l = Math.min(s.rect.left, r.left), rt = Math.max(s.chip.x + 16, r.right), tp = Math.min(s.rect.top, r.top), bt = Math.max(s.rect.bottom, r.bottom);
    const pad = 64;
    // Zoom out until the shot holds the words and the card with room, once kept on the desk.
    let z = Math.min(cap, (W) / (rt - l + pad * 2), (H) / (bt - tp + pad * 2));
    for (;;) {
      const g = onStage({ x: (l + rt) / 2, y: (tp + bt) / 2, z });
      const hw = W / 2 / z, hh = H / 2 / z, m = pad / z * 0.75;
      if (z <= 1 || (l - m >= g.x - hw && rt + m <= g.x + hw && tp - m >= g.y - hh && bt + m <= g.y + hh)) return g;
      z *= 0.99;
    }
  }
  // Keep the view on the desk by clamping where the camera aims, never the camera itself: a clamp
  // on the drawn camera kinks its path.
  function onStage(g) {
    const z = g.z;
    return { x: clamp(g.x, W / 2 / z, W - W / 2 / z), y: clamp(g.y, H / 2 / z, H - H / 2 / z), z };
  }
  function simulateCamera() {
    camPath = [];
    // Two critically damped springs in series: the first softens each new aim, the second follows
    // it, so a move eases in instead of starting at full acceleration.
    let ax = W / 2, ay = H / 2, az = 0, ux = 0, uy = 0, uz = 0;
    let x = W / 2, y = H / 2, lz = 0, vx = 0, vy = 0, vz = 0;
    const w1 = (2 * Math.PI) / 0.42, w = (2 * Math.PI) / 0.8, h = 1 / 600;
    const frames = Math.round(T * FPS);
    let t = 0;
    for (let f = 0; f <= frames; f++) {
      const tf = f / FPS;
      while (t < tf - 1e-9) {
        const g = onStage(targetAt(t)), tz = Math.log(g.z);
        ux += (-w1 * w1 * (ax - g.x) - 2 * w1 * ux) * h; ax += ux * h;
        uy += (-w1 * w1 * (ay - g.y) - 2 * w1 * uy) * h; ay += uy * h;
        uz += (-w1 * w1 * (az - tz) - 2 * w1 * uz) * h; az += uz * h;
        vx += (-w * w * (x - ax) - 2 * w * vx) * h; x += vx * h;
        vy += (-w * w * (y - ay) - 2 * w * vy) * h; y += vy * h;
        vz += (-w * w * (lz - az) - 2 * w * vz) * h; lz += vz * h;
        t += h;
      }
      camPath.push({ x, y, z: Math.exp(lz) });
    }
  }
  // The Mac cut's push into the last card: from wherever the camera is when it starts, eased
  // (log zoom) to the shot where the card's word lands exactly on the end card's word.
  let push = null;
  function pushAt(t) {
    if (!push) {
      const p = plan[plan.length - 1], hw = p.hwRect, w = document.querySelector("#endcard .word b").getBoundingClientRect();
      const z = (w.bottom - w.top) / hw.h;
      const sx = (w.left + w.right) / 2, sy = (w.top + w.bottom) / 2;
      push = { hw, t0: plan.tOut, t1: plan.tEnd + 0.4, a: camAt(plan.tOut), b: { x: hw.x - (sx - W / 2) / z, y: hw.y - (sy - H / 2) / z, z } };
    }
    const u = clamp((t - push.t0) / (push.t1 - push.t0)), e = u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2;
    const { a, b, hw } = push, z = Math.exp(lerp(Math.log(a.z), Math.log(b.z), e));
    // The word's point on screen moves in a straight line while the zoom changes.
    const s0 = { x: (hw.x - a.x) * a.z + W / 2, y: (hw.y - a.y) * a.z + H / 2 };
    const s1 = { x: (hw.x - b.x) * b.z + W / 2, y: (hw.y - b.y) * b.z + H / 2 };
    const sx = lerp(s0.x, s1.x, e), sy = lerp(s0.y, s1.y, e);
    return { x: hw.x - (sx - W / 2) / z, y: hw.y - (sy - H / 2) / z, z, free: true };
  }
  function cameraAt(t) {
    if (!WIN && plan.tOut && t >= plan.tOut) return pushAt(t);
    return camAt(t);
  }
  function camAt(t) {
    const f = clamp(t * FPS, 0, camPath.length - 1), i = Math.floor(f), u = f - i;
    const a = camPath[i], b = camPath[Math.min(i + 1, camPath.length - 1)];
    return { x: lerp(a.x, b.x, u), y: lerp(a.y, b.y, u), z: lerp(a.z, b.z, u) };
  }
  function setCamera(c) {
    const z = c.z;
    const free = c.free;
    const x = free ? c.x : clamp(c.x, W / 2 / z, W - W / 2 / z), y = free ? c.y : clamp(c.y, H / 2 / z, H - H / 2 / z);
    if (Math.abs(x - c.x) > 0.5 || Math.abs(y - c.y) > 0.5) window.film && (window.film.clamped = (window.film.clamped || 0) + 1);
    cam.style.transform = `translate(${W / 2 - x * z}px, ${H / 2 - y * z}px) scale(${z})`;
  }

  // MARK: Cards

  let shown = null;   // { p, card }
  function openCard(p) {
    const s = p.s, d = s.data, key = `${s.sel[0]}-${s.sel[1]}`;
    const r = { left: s.rect.left, right: s.rect.right, top: s.rect.top, bottom: s.rect.bottom, preferBelow: true };
    let card;
    if (s.kind === "word") {
      const info = d.cards[key];
      card = LongyanCard.openWord({ senses: d.words[info.word] || [], card: info }, r);
    } else {
      card = LongyanCard.openPhrase({ phrase: d.phrases[key], words: d.words }, r);
    }
    cam.appendChild(card.el);
    const b = card.el.getBoundingClientRect();
    if (!p.cardRect) {
      p.cardRect = { left: b.left, right: b.right, top: b.top, bottom: b.bottom };
      const hw = card.el.querySelector(".lc-hw"), r = hw && hw.getBoundingClientRect();
      if (r) p.hwRect = { x: (r.left + r.right) / 2, y: (r.top + r.bottom) / 2, h: r.bottom - r.top };
      const ch = card.el.querySelector(".lc-def.chosen");
      if (ch) { const rb = ch.closest(".lc-row").getBoundingClientRect(); p.pickRect = { left: b.left, right: b.right, top: b.top, bottom: rb.bottom }; }
      if (!WIN && p.s.tip && !p.tipEl) { p.tipEl = makeTip(p, card); if (p.pickRect) { p.pickRect.right = Math.max(p.pickRect.right, p.tipRect.right); p.pickRect.left = Math.min(p.pickRect.left, p.tipRect.left); } }
    }
    if (!WIN) lightUp(card.el);
    if (!WIN && p.s.tip && !p.tipEl) p.tipEl = makeTip(p, card);
    return card;
  }
  // The app's light, run by the film's clock: purple over every meaning the dictionary has (a
  // dictionary would stop there), then drawn in onto the one this sentence means, turning the
  // checkmark's blue, as its check springs in, the others step back and the answer opens under
  // the word.
  function lightUp(el) {
    const senses = el.querySelector(".lc-senses"), rows = [...el.querySelectorAll(".lc-list .lc-row[data-i]")];
    const chosen = rows.find((r) => r.querySelector(".lc-def.chosen"));
    if (!senses || !chosen) return;
    const light = document.createElement("div");
    light.className = "lc-light film-light";
    light.innerHTML = '<i class="purple"></i><i class="blue"></i>';
    senses.prepend(light);
    const box = (a, b) => ({ top: a.offsetTop, left: a.offsetLeft, width: a.offsetWidth, height: b.offsetTop + b.offsetHeight - a.offsetTop });
    const defs = rows.filter((r) => r !== chosen).map((r) => r.querySelector(".lc-def"));
    const on = getComputedStyle(chosen.querySelector(".lc-def")).color, off = defs[0] ? getComputedStyle(defs[0]).color : on;
    el._light = { light, all: box(rows[0], rows[rows.length - 1]), one: box(chosen, chosen), defs, on, off,
      check: chosen.querySelector(".lc-check"), meaning: el.querySelector(".lc-meaning") };
  }
  const rgba = (c) => (c.match(/[\d.]+/g) || [0, 0, 0, 1]).map(Number).concat([1]).slice(0, 4);
  function drawLight(el, k, at) {
    const L = el._light;
    if (!L) return;
    const k0 = k;   // the purple comes on as the card opens, however long it holds
    k += 0.95 - at;   // the timings below are for a light that draws in at 0.95 s
    const u = PICK(k - 0.95);
    const g = (key) => lerp(L.all[key], L.one[key], u);
    L.light.style.cssText = `opacity:${sine((k0 - 0.12) / 0.4)};top:${g("top")}px;left:${g("left")}px;width:${g("width")}px;height:${g("height")}px`;
    L.light.children[0].style.opacity = 1 - sine((k - 0.95) / 0.3);
    L.light.children[1].style.opacity = sine((k - 0.95) / 0.45);
    const a = rgba(L.on), b = rgba(L.off), d = sine((k - 1.0) / 0.45);
    const col = `rgba(${a.map((v, i) => (i < 3 ? Math.round(lerp(v, b[i], d)) : lerp(v, b[i], d).toFixed(3))).join(",")})`;
    L.defs.forEach((x) => { x.style.color = col; });
    const c = spring(0.35, 0.62)(k - 1.05);
    L.check.style.opacity = clamp((k - 1.05) / 0.12);
    L.check.style.transform = `scale(${0.6 + 0.4 * c})`;
    if (L.meaning) {
      const m = sine((k - 1.05) / 0.45);
      L.meaning.style.opacity = m;
      L.meaning.style.transform = `translateY(${(1 - m) * -5}px)`;
    }
  }
  // "Picked from context": the site's tip, out of its arrow beside the row picked.
  const TIP = { gap: 6, arrow: 8, base: 8, r: 12 };
  function tipPath(w, h, ay) {
    const { arrow: A, base: b, r } = TIP, f = (v) => Math.round(v * 100) / 100;
    return `M${A + r},0 H${f(A + w - r)} A${r},${r} 0 0 1 ${f(A + w)},${r} V${f(h - r)} A${r},${r} 0 0 1 ${f(A + w - r)},${f(h)}` +
      ` H${A + r} A${r},${r} 0 0 1 ${A},${f(h - r)} V${f(ay + b)} C${A},${f(ay + b * 0.45)} 1.6,${f(ay + 1.7)} .6,${f(ay + 0.55)}` +
      ` Q0,${f(ay)} .6,${f(ay - 0.55)} C1.6,${f(ay - 1.7)} ${A},${f(ay - b * 0.45)} ${A},${f(ay - b)} V${r} A${r},${r} 0 0 1 ${A + r},0 Z`;
  }
  function makeTip(p, card) {
    const row = card.el.querySelector(".lc-def.chosen").closest(".lc-row").getBoundingClientRect();
    const el = document.createElement("div");
    el.className = "pick-note on film-tip";
    el.innerHTML = `<div class="pick-tip"><div class="pick-glass"></div>
      <svg class="pick-shape" aria-hidden="true"><defs><linearGradient id="pick-edge" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".24"/><stop offset=".5" stop-color="#fff" stop-opacity=".1"/><stop offset="1" stop-color="#fff" stop-opacity=".07"/></linearGradient></defs><path/></svg>
      <p class="pick-title">Picked from context</p></div>`;
    cam.appendChild(el);
    const tip = el.firstElementChild, glass = tip.children[0], shape = tip.children[1];
    const w = el.offsetWidth, h = el.offsetHeight, mid = (row.top + row.bottom) / 2;
    const d = tipPath(w, h, h / 2), Wd = w + TIP.arrow, reach = TIP.gap + TIP.arrow;
    // On the card's right if it fits on the desk, else its left, mirrored, as the site does.
    const right = p.cardRect.right + reach + w <= W - 24;
    const left = right ? -TIP.arrow : 0, flip = right ? "none" : "scaleX(-1)";
    shape.querySelector("path").setAttribute("d", d);
    shape.setAttribute("viewBox", `-.5 -.5 ${Wd + 1} ${h + 1}`);
    Object.assign(shape.style, { left: left - 0.5 + "px", top: "-.5px", width: Wd + 1 + "px", height: h + 1 + "px", transform: flip });
    Object.assign(glass.style, { left: left + "px", top: "0", width: Wd + "px", height: h + "px", clipPath: `path("${d}")`, transform: flip });
    tip.style.transformOrigin = `${right ? -TIP.arrow : w + TIP.arrow}px ${h / 2}px`;
    const x = right ? p.cardRect.right + reach : p.cardRect.left - reach - w, y = Math.round(mid - h / 2);
    el.style.transform = `translate(${x}px, ${y}px)`;
    p.tipRect = { left: right ? x - TIP.arrow : x, right: right ? x + w : x + w + TIP.arrow, top: y, bottom: y + h };
    return el;
  }
  const TIP_IN = spring(0.42, 0.78);
  function drawTip(p, k) {
    // out of its arrow's tip once the check is in, and gone with the card
    const e = TIP_IN(k - 0.5), o = clamp((k - 0.5) / 0.2) * (shown && shown.p === p ? +shown.card.el.style.opacity : 0);
    p.tipEl.style.opacity = o;
    const tp = p.tipEl.firstElementChild; tp.style.opacity = 1; tp.style.transform = `scale(${0.94 + 0.06 * e})`;
  }
  function closeCard() {
    if (!shown) return;
    LongyanCard.close(true, true);
    if (shown.card.el.isConnected) shown.card.el.remove();
    shown = null;
  }

  // MARK: Drawing

  function drawSelection(s, count, show) {
    s.hl.innerHTML = "";
    // On Windows the page's own selection, so the words turn white in the highlight as they do there.
    if (WIN) {
      if (!show || count <= 0) return;
      const node = s.winEl.querySelector(".s").firstChild, r = document.createRange();
      r.setStart(node, s.sel[0]); r.setEnd(node, s.sel[0] + count);
      winSel = r;
      return;
    }
    if (!show || count <= 0) return;
    const cs = s.chars.slice(s.sel[0], s.sel[0] + count);
    const lines = [];
    for (const c of cs) {
      const l = lines.find((x) => Math.abs(x.top - c.top) < 4);
      if (l) { l.left = Math.min(l.left, c.left); l.right = Math.max(l.right, c.right); l.bottom = Math.max(l.bottom, c.bottom); }
      else lines.push({ ...c });
    }
    for (const l of lines) {
      const i = document.createElement("i");
      i.style.cssText = `left:${l.left - s.hlOrigin.x}px;top:${l.top - s.hlOrigin.y}px;width:${l.right - l.left}px;height:${l.bottom - l.top}px`;
      s.hl.appendChild(i);
    }
  }

  function overText(pos, wins) {
    // The topmost window under the pointer, and whether it's over its words there.
    for (let i = wins.order.length - 1; i >= 0; i--) {
      const w = wins.order[i], s = SCENES.find((x) => x.winEl === w), b = s.box;
      if (pos.x < b.left || pos.x > b.right || pos.y < b.top || pos.y > b.bottom) continue;
      return s.text.some((r) => pos.x >= r.left && pos.x <= r.right && pos.y >= r.top - 2 && pos.y <= r.bottom + 2);
    }
    return false;
  }

  let endGeo = null;
  function measureEnd(end) {
    const big = end.querySelector(".word b"), cmp = end.querySelector(".cmp");
    const bai = [...cmp.querySelectorAll("b")], r0 = big.getBoundingClientRect(), r1 = bai[0].getBoundingClientRect();
    return { paper: document.getElementById("endpaper"), shift: W / 2 - (r1.left + r1.right) / 2, big, cmp, bai, ctx: [...cmp.querySelectorAll(".pre, .post")], mean: [...cmp.querySelectorAll(".m")], name: end.querySelector(".name"),
      dx: (r1.left + r1.right) / 2 - (r0.left + r0.right) / 2, dy: (r1.top + r1.bottom) / 2 - (r0.top + r0.bottom) / 2, s: (r1.bottom - r1.top) / (r0.bottom - r0.top) };
  }
  function render(t) {
    t = clamp(t, 0, T);
    {
      const e = WIN ? sine((t - plan.tEnd) / 0.7) : sine((t - plan.tEnd - 0.2) / 0.45), end = document.getElementById("endcard");
      end.style.opacity = e;
      if (WIN) end.firstElementChild.style.transform = `translateY(${(1 - sine((t - plan.tEnd - 0.1) / 0.9)) * 14}px)`;
      else {
        // The word the push lands on moves up into the first of three rows, two more 白 come in
        // under it, then their sentences around them, then what each meant, one by one.
        const k = t - plan.tEnd, E = endGeo || (endGeo = measureEnd(end));
        const io = (u) => { u = clamp(u); return u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2; };
        // The column of 白 stands in the middle of the frame until the sentences come in around
        // it; then the whole block eases over to sit centred itself.
        const slide = E.shift * (1 - io((k - 1.95) / 1.0));
        const mv = io((k - 0.95) / 0.9), landed = k >= 1.85;
        E.big.style.opacity = landed ? 0 : sine((k - 0.15) / 0.6);
        E.big.style.transform = `translate(${(E.dx + E.shift) * mv}px, ${E.dy * mv}px) scale(${lerp(1, E.s, mv)})`;
        E.bai.forEach((b, i) => {
          if (i === 0) { b.style.opacity = landed ? 1 : 0; return; }
          const e = sine((k - 1.3 - (i - 1) * 0.16) / 0.5);
          b.style.opacity = e; b.style.transform = `translateY(${(1 - e) * 14}px)`;
        });
        const ctx = sine((k - 2.05) / 0.7);
        // Once all three are read, the first two step back and "free of charge" stays lit.
        const back = sine((k - 4.75) / 0.8);
        E.ctx.forEach((c, i) => { c.style.opacity = ctx * (i < 4 ? 1 - 0.55 * back : 1); });
        E.bai.forEach((b, i) => { if (i < 2 && k >= 1.85) b.style.opacity = (i === 0 ? 1 : sine((k - 1.3) / 0.5)) * (1 - 0.55 * back); });
        E.mean.forEach((m, i) => {
          // each meaning wipes in from the left as it fades up
          const e = sine((k - 2.6 - i * 0.42) / 0.6);
          m.style.opacity = e * (i < 2 ? 1 - 0.55 * back : 1);
          m.style.clipPath = `inset(-20% ${((1 - e) * 100).toFixed(2)}% -20% 0)`;
          m.style.transform = `translateX(${(1 - e) * -8}px)`;
        });
        // The block drifts in, slowly, the whole time it's up, then dissolves through a blur
        // into the name, which resolves out of one.
        const o = sine((k - 6.3) / 0.7);
        E.cmp.style.opacity = 1 - o;
        E.cmp.style.filter = o > 0.001 ? `blur(${(o * 12).toFixed(2)}px)` : "";
        E.cmp.style.transform = `translateX(${slide}px) scale(${1 + 0.03 * clamp((k - 1.9) / 5.1) + 0.02 * o})`;
        const ni = sine((k - 6.75) / 0.9), no = sine((k - 9.0) / 0.55);
        E.name.style.opacity = ni * (1 - no);
        E.name.style.filter = ni < 0.999 ? `blur(${((1 - ni) * 10).toFixed(2)}px)` : "";
        E.name.style.transform = `scale(${0.97 + 0.03 * ni + 0.01 * clamp((k - 7.6) / 1.4)})`;
        // The site's paper behind it all, rising very slowly.
        E.paper.style.transform = `translateY(${(1 - clamp(k / 9.6)) * 26}px) scale(1.04)`;
        // and last it sinks into the night the film opens out of, for the loop
        E.paper.style.opacity = 1 - sine((k - 9.0) / 0.6);
      }
    }
    // The loop: the film opens out of the end card's dark.
    if (!WIN) { const f = document.getElementById("fadein"); f.style.opacity = 1 - sine(t / 0.6); }

    // Depth: the windows not being read go a little soft and dim, like a lens's focus falling off.
    if (!WIN) {
      let cur = null;
      for (const p of plan) if (t >= p.tLeave) cur = p;
      for (const s of SCENES) {
        let d = 0;
        if (cur) {
          const on = s === cur.s, prev = plan[plan.indexOf(cur) - 1];
          const u = sine((t - cur.tLeave - 0.15) / 0.7);
          d = on ? (prev ? 1 - u : 0) : prev && prev.s !== s ? 1 : u;
        }
        // and as the camera pushes into the last card, everything behind it falls away
        const push = sine((t - plan.tOut) / 0.9);
        const bl = 1.3 * d + 3.5 * push, dim = Math.max(d, push);
        s.winEl.style.filter = bl > 0.003 ? `blur(${bl.toFixed(2)}px) brightness(${(1 - 0.1 * dim).toFixed(3)}) saturate(${(1 - 0.12 * dim).toFixed(3)})` : "";
      }
    }

    // Windows
    const wins = windowsAt(t);
    wins.order.forEach((w, i) => { w.style.zIndex = 10 + i; w.classList.toggle("key", w === wins.key); });
    // The menu bar names the app in front, as the Mac's does.
    const mb = document.getElementById("mb-app");
    if (mb) {
      const app = MENUS[wins.key.id];
      if (mb.textContent !== app[0]) { mb.textContent = app[0]; document.getElementById("mb-menus").textContent = app[1]; }
    }

    // Selections
    for (const p of plan) {
      const s = p.s, n = s.sel[1] - s.sel[0];
      const live = t >= p.tDown && t < p.tClose;
      let count = n;
      if (t < p.tUp) {
        const x = cursorAt(t).x;
        count = s.chars.slice(s.sel[0], s.sel[1]).filter((c) => (c.left + c.right) / 2 < x).length;
      }
      drawSelection(s, count, live);
    }
    if (WIN) {
      const sel = getSelection(); sel.removeAllRanges();
      if (winSel) sel.addRange(winSel);
      winSel = null;
    }

    // The eye by the selection
    const pos = cursorAt(t);
    let chip = null;
    for (const p of plan) if (t >= p.tChip && t < p.tOpen + 0.1) chip = p;
    if (chip) {
      const p = chip, s = p.s, k = t - p.tChip;
      const hoverAt = moves.find((m) => m.to === p.toChip).t1 - 0.06;
      let scale = 0.6 + 0.4 * CHIP_IN(k);
      const hov = t >= hoverAt ? CHIP_HOVER(t - hoverAt) : 0;
      scale *= 1 + 0.08 * hov;
      if (t >= p.tPress) scale *= 1 - 0.08 * PRESS(t - p.tPress) + (t >= p.tRelease ? 0.08 * PRESS(t - p.tRelease) : 0);
      const op = clamp(k / 0.12) * (t >= p.tOpen ? 1 - clamp((t - p.tOpen) / 0.1) : 1);
      chipEl.style.display = "flex";
      chipEl.style.left = s.chip.x + "px"; chipEl.style.top = s.chip.y + "px";
      chipEl.style.transform = `scale(${scale})`;
      chipEl.style.opacity = op;
      chipEl.style.color = WIN ? `rgba(0,0,0,${0.52 + 0.33 * hov})` : `rgba(255,255,255,${0.62 + 0.33 * hov})`;
    } else chipEl.style.display = "none";

    // The card
    let want = null;
    for (const p of plan) if (t >= p.tOpen && t < p.tClose + 0.14) want = p;
    if (!want || (shown && shown.p !== want)) closeCard();
    for (const q of plan) if (q.tipEl && (!want || want !== q)) q.tipEl.style.opacity = 0;
    if (want && !shown) shown = { p: want, card: openCard(want) };
    if (shown) {
      const p = shown.p, k = t - p.tOpen, el = shown.card.el;
      const below = el.style.transformOrigin.startsWith("50% 0");
      const e = CARD_IN(k);
      let op = clamp(k / 0.14); op = op * op * (3 - 2 * op);
      if (t >= p.tClose) op *= 1 - clamp((t - p.tClose) / 0.12);
      el.style.transform = `translateY(${(1 - e) * (below ? -4 : 4)}px) scale(${0.96 + 0.04 * e})`;
      el.style.opacity = op;
      if (!WIN) drawLight(el, k - 0, pickAt(p.s));
      if (!WIN && p.tipEl) drawTip(p, k - pickAt(p.s));
      if (!WIN && p === plan[plan.length - 1]) {
        const f = 1 - sine((t - plan.tOut - 0.15) / 0.55);
        for (const x of el.querySelectorAll(".lc-py, .lc-slot, .lc-meaning, .lc-note-slot, .lc-senses, .lc-status, .lc-head > :not(.lc-hw)")) x.style.opacity = x.classList.contains("lc-meaning") ? Math.min(f, +x.style.opacity || 1) : f;
      }
    }

    // The pointer
    const pressed = downs.some((d) => t >= d.t && t < d.up + 0.02);
    let press = 1;
    for (const d of downs) {
      if (t >= d.t && t < d.up + 0.4) press = 1 - 0.12 * PRESS(t - d.t) + (t >= d.up ? 0.12 * PRESS(t - d.up) : 0);
    }
    const ibeam = !chip || Math.hypot(pos.x - chip.s.chip.x, pos.y - chip.s.chip.y) > 14 ? overText(pos, wins) || (pressed && !chip) : false;
    cursorEl.classList.toggle("ibeam", ibeam);
    const hx = ibeam ? 14 : 8.2, hy = ibeam ? 14 : 4.1;
    cursorEl.style.transform = `translate(${pos.x - hx}px, ${pos.y - hy}px) scale(${press})`;
    cursorEl.style.transformOrigin = `${hx}px ${hy}px`;
    cursorEl.style.opacity = WIN ? 1 : 1 - sine((t - plan.tOut) / 0.4);

    // The camera, last, once the card's frame is known
    for (const p of plan) if (p.cardRect && !p.frame) { p.frame = frameFor(p, p.cardRect); simulateCamera(); }
    setCamera(cameraAt(t));
  }

  // Every card is opened once up front (camera at rest) to measure its frame, so the camera
  // path is known before the first frame.
  function prime() {
    for (const p of plan) {
      const c = openCard(p);
      p.frame = frameFor(p, p.cardRect);
      if (p.pickRect && !WIN) p.pickFrame = frameFor(p, p.pickRect, 2.05);
      if (p.s.wantWinShot) p.s.winShot = winShot(p.s);
      LongyanCard.close(true, true); if (c.el.isConnected) c.el.remove();
    }
    simulateCamera();
  }

  const ready = (async () => {
    await document.fonts.ready;
    await new Promise((r) => setTimeout(r, 400));
    // The Mac cut's end card (the Windows one is made by win.js): the word, the three sentences
    // side by side, then the name.
    if (!document.getElementById("endcard")) {
      const end = document.createElement("div"); end.id = "endcard";
      const rows = ROWS.map(([pre, post, m]) => `<span class="pre">${pre}</span><b>白</b><span class="post">${post}</span><span class="m">${m}</span>`).join("");
      end.innerHTML = `<div class="word"><b>白</b></div><div class="cmp">${rows}</div>` +
        `<div class="name">${document.querySelector("#chip svg").outerHTML}<span>longyan.app</span></div>`;
      const f = document.createElement("div"); f.id = "fadein"; document.getElementById("stage").appendChild(f);
      document.getElementById("stage").appendChild(end);
      end.prepend(document.getElementById("endpaper"));
    }
    measure();
    schedule();
    prime();
    render(0);
  })();

  window.film = { ready, render, get T() { return T; }, FPS, plan: () => plan };
})();
