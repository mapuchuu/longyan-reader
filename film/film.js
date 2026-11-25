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

  // MARK: The scenes

  const SCENES = [
    { id: "a", win: "#w-a", data: FILM.a, sel: [12, 14], kind: "word", hold: 3.3 },
    { id: "b", win: "#w-b", data: FILM.b, sel: [8, 10], kind: "word", hold: 3.3 },
    { id: "c", win: "#w-c", data: FILM.c, sel: [4, 10], kind: "phrase", hold: 3.9 },
  ];
  const REST = { x: 1150, y: 700 };   // where the pointer waits, at the start and the end

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
    }
  }

  // MARK: The timeline

  let T = 0, moves = [], downs = [], plan = [];
  function schedule() {
    let t = 0.55;
    let from = { ...REST };
    moves = []; downs = []; plan = [];
    SCENES.forEach((s, k) => {
      const start = { x: s.rect.left + 1.5, y: s.rect.midY };
      const far = Math.hypot(start.x - from.x, start.y - from.y);
      const go = clamp(0.62 + far / 1400, 0.7, 1.15);
      moves.push({ t0: t, t1: t + go, from, to: start, bend: k % 2 ? -0.1 : 0.12 });
      const tDown = t + go + 0.14;
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
      const p = { s, tDown, tUp, tChip, tPress, tRelease, tOpen, tClose: Infinity, start, end, toChip };
      if (plan.length) plan[plan.length - 1].tClose = tDown;
      plan.push(p);
      from = toChip;
      t = tOpen + s.hold;
    });
    // Out: a click on the page's margin puts the last card away, and the pointer goes back to
    // where it waits; the camera opens back out to the whole desk.
    const click = { x: 1150, y: 640 };
    moves.push({ t0: t, t1: t + 0.8, from, to: click, bend: 0.12 });
    const tOut = t + 0.8 + 0.12;
    downs.push({ t: tOut, up: tOut + 0.1, win: $("#w-c") });
    plan[plan.length - 1].tClose = tOut;
    moves.push({ t0: tOut + 0.5, t1: tOut + 1.4, from: click, to: REST, bend: -0.1 });
    T = Math.round((tOut + 3.4) * FPS) / FPS;
    plan.tOut = tOut;
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
    const order = ["#w-a", "#w-b", "#w-c"].map((s) => $(s));
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
      const leave = moves.find((m) => Math.abs(m.to.x - (s.rect.left + 1.5)) < 0.01 && Math.abs(m.to.y - s.rect.midY) < 0.01);
      if (t < leave.t0 + 0.1) continue;
      if (t >= plan.tOut + 0.15) return wide;
      // On the way from one card to the next, the camera eases out a little and over.
      const prev = i > 0 ? plan[i - 1] : null;
      if (prev && t < leave.t0 + 0.55) {
        const a = prev.frame || focus(prev.s), b = focus(s);
        return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, z: Math.min(a.z, b.z) * 0.78 };
      }
      if (t >= p.tOpen + 0.05 && p.frame) return p.frame;
      return focus(s);
    }
    return wide;
  }
  function focus(s) {
    return { x: (s.rect.left + s.rect.right) / 2 + 40, y: s.rect.midY + 60, z: 1.65 };
  }
  function frameFor(p, card) {
    const s = p.s, r = card;
    const l = Math.min(s.rect.left, r.left), rt = Math.max(s.chip.x + 16, r.right), tp = Math.min(s.rect.top, r.top), bt = Math.max(s.rect.bottom, r.bottom);
    const pad = 64;
    // Zoom out until the shot holds the words and the card with room, once kept on the desk.
    let z = Math.min(1.75, (W) / (rt - l + pad * 2), (H) / (bt - tp + pad * 2));
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
  function cameraAt(t) {
    const f = clamp(t * FPS, 0, camPath.length - 1), i = Math.floor(f), u = f - i;
    const a = camPath[i], b = camPath[Math.min(i + 1, camPath.length - 1)];
    return { x: lerp(a.x, b.x, u), y: lerp(a.y, b.y, u), z: lerp(a.z, b.z, u) };
  }
  function setCamera(c) {
    const z = c.z;
    const x = clamp(c.x, W / 2 / z, W - W / 2 / z), y = clamp(c.y, H / 2 / z, H - H / 2 / z);
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
    p.cardRect = { left: b.left, right: b.right, top: b.top, bottom: b.bottom };
    return card;
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

  function render(t) {
    t = clamp(t, 0, T);
    // Windows
    const wins = windowsAt(t);
    wins.order.forEach((w, i) => { w.style.zIndex = 10 + i; w.classList.toggle("key", w === wins.key); });

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
      chipEl.style.color = `rgba(255,255,255,${0.62 + 0.33 * hov})`;
    } else chipEl.style.display = "none";

    // The card
    let want = null;
    for (const p of plan) if (t >= p.tOpen && t < p.tClose + 0.14) want = p;
    if (!want || (shown && shown.p !== want)) closeCard();
    if (want && !shown) shown = { p: want, card: openCard(want) };
    if (shown) {
      const p = shown.p, k = t - p.tOpen, el = shown.card.el;
      const below = el.style.transformOrigin.startsWith("50% 0");
      const e = CARD_IN(k);
      let op = clamp(k / 0.14); op = op * op * (3 - 2 * op);
      if (t >= p.tClose) op *= 1 - clamp((t - p.tClose) / 0.12);
      el.style.transform = `translateY(${(1 - e) * (below ? -4 : 4)}px) scale(${0.96 + 0.04 * e})`;
      el.style.opacity = op;
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
      LongyanCard.close(true, true); if (c.el.isConnected) c.el.remove();
    }
    simulateCamera();
  }

  const ready = (async () => {
    await document.fonts.ready;
    await new Promise((r) => setTimeout(r, 400));
    measure();
    schedule();
    prime();
    render(0);
  })();

  window.film = { ready, render, get T() { return T; }, FPS, plan: () => plan };
})();
