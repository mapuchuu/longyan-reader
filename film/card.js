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
  const glyph = (cls, box, d) => `<svg class="lc-sym ${cls}" viewBox="${box}" aria-hidden="true"><path class="lc-fill" fill-rule="evenodd" d="${d}"/></svg>`;
  const SYM = {
    speaker: svg('<path class="lc-fill" d="M2.2 6.1h2.2L7.6 3.4c.4-.3.9 0 .9.5v8.2c0 .5-.5.8-.9.5L4.4 9.9H2.2c-.4 0-.7-.3-.7-.7V6.8c0-.4.3-.7.7-.7z"/><path class="lc-wave lc-w1" d="M10.6 6.2c.5.5.7 1.1.7 1.8s-.2 1.3-.7 1.8"/><path class="lc-wave lc-w2" d="M12.5 4.4c1 1 1.5 2.2 1.5 3.6s-.5 2.6-1.5 3.6"/>'),
    copy: svg('<rect x="5.2" y="4.6" width="8.3" height="9.9" rx="1.9"/><path d="M3.4 11.2V3.6c0-1 .8-1.9 1.9-1.9h5.2"/>'),
    check: svg('<path d="M3.4 8.6 6.6 11.8 12.8 4.4"/>'),
    chevronRight: svg('<path d="M6.2 3.4 10.8 8l-4.6 4.6"/>'),
    chevronDown: svg('<path d="M3.4 6.2 8 10.8l4.6-4.6"/>'),
    bubble: svg('<path d="M3.6 2.6h8.8c1 0 1.8.8 1.8 1.8v5.4c0 1-.8 1.8-1.8 1.8H8.2l-3.1 2.4v-2.4H3.6c-1 0-1.8-.8-1.8-1.8V4.4c0-1 .8-1.8 1.8-1.8z"/><path d="M5 5.9h6M5 8.3h4"/>'),
    // The two note symbols are SF Symbols' own outlines (translate, globe.asia.australia.fill),
    // traced from the system's semibold glyph, in 1/100 em: the label sizes them as the app does.
    translate: glyph("lc-translate", "0 0 159.85 114", "M130.8 114.01 129.95 114.02 129.25 113.96 128.45 113.82 127.45 113.51 126.5 113.12 125.45 112.56 123.75 111.45 121.55 109.72 104.85 95.55 88.05 95.53 86.3 95.47 85.15 95.36 82.6 94.97 81.3 94.67 80.1 94.32 78.8 93.86 77.75 93.42 76.45 92.76 75.58 92.25 74.42 91.45 73.5 90.71 72.15 89.43 71.34 88.5 70.58 87.5 69.88 86.4 69.24 85.2 68.69 83.95 68.28 82.85 67.83 81.3 67.53 79.9 67.33 78.55 67.18 76.65 67.14 71.45 67.1 71.34 55.35 71.35 38.15 85.96 36.4 87.31 34.7 88.42 33.3 89.12 32.2 89.51 31 89.77 29.7 89.82 28.6 89.71 27.45 89.42 26.55 89.01 26 88.67 25.5 88.28 24.75 87.5 24.4 87 24 86.29 23.59 85.25 23.39 84.5 23.24 83.7 23.14 82.2 23.14 71.45 23.11 71.35 20.2 71.34 18.55 71.27 16.75 71.07 15.1 70.77 13.35 70.32 11.6 69.71 9.95 68.97 8.45 68.12 7 67.1 5.84 66.1 4.64 64.85 3.53 63.45 2.69 62.15 1.89 60.6 1.28 59.1 0.69 57.15 0.44 56.05 0.18 54.5 0.03 52.95 -0.02 51.65 -0.03 20.75 0.03 18.85 0.19 17.3 0.49 15.5 0.83 14.05 1.33 12.5 1.88 11.15 2.64 9.65 3.54 8.2 4.49 6.95 5.5 5.84 6.35 5.05 7.4 4.18 8.85 3.19 10.35 2.35 12.05 1.59 14.15 0.89 16.35 0.39 18.5 0.09 19.9 -0.02 21.4 -0.05 71.6 -0.05 73.95 0.03 75.75 0.23 77.7 0.59 79.6 1.09 81.4 1.74 83.3 2.65 84.5 3.37 85.3 3.93 86.75 5.09 87.55 5.84 88.26 6.6 89.41 8.05 90.01 8.95 90.51 9.8 91.27 11.35 91.92 13.05 92.47 15 92.82 16.85 93.02 18.7 93.08 20.15 93.1 24.13 138.4 24.15 140.8 24.23 142.6 24.44 144.25 24.73 145.7 25.09 147.4 25.64 148.75 26.19 150.35 26.99 151.7 27.83 152.98 28.8 154.35 30.05 155.56 31.4 156.51 32.7 157.45 34.3 158.32 36.2 158.96 38.1 159.36 39.75 159.71 42 159.82 43.3 159.86 44.95 159.86 75.65 159.81 76.95 159.66 78.55 159.47 79.85 159.12 81.45 158.56 83.25 157.77 85.15 157.1 86.4 156.26 87.7 155.11 89.15 154.13 90.15 152.62 91.45 151.45 92.27 149.9 93.16 148.35 93.86 146.65 94.46 144.95 94.92 143.05 95.26 141.25 95.46 140.15 95.52 137.12 95.55 137.09 106.8 136.96 108.15 136.62 109.55 136.22 110.5 135.76 111.3 135.16 112.05 134.5 112.66 133.65 113.21 132.75 113.62 131.85 113.86ZM32.82 78.05 48.45 63.93 49.9 62.83 51.15 62.13 51.95 61.79 52.75 61.54 53.75 61.33 54.65 61.23 67.11 61.2 67.14 61.1 67.14 44.95 67.23 42.6 67.43 40.85 67.78 39 68.28 37.2 68.83 35.7 69.23 34.8 69.88 33.55 70.99 31.85 72.23 30.35 73.05 29.53 73.95 28.73 74.9 28 76.05 27.24 77.75 26.33 78.65 25.94 80 25.44 82.3 24.77 82.3 21.8 82.21 20.25 81.91 18.45 81.47 16.95 81.12 16.1 80.72 15.35 79.97 14.2 79.47 13.6 78.87 13 77.7 12.08 77.05 11.68 76.05 11.18 74.5 10.63 73.45 10.38 72.55 10.23 70.7 10.09 22.35 10.09 20.9 10.18 19.35 10.43 17.9 10.83 16.55 11.39 15.5 11.98 14.55 12.68 13.59 13.6 12.83 14.55 12.04 15.9 11.69 16.7 11.39 17.55 10.98 19.25 10.77 21.15 10.76 49.6 10.79 50.4 10.93 51.75 11.14 52.85 11.38 53.75 11.84 55 12.29 55.9 12.93 56.9 13.59 57.7 14.2 58.31 15.15 59.07 16.25 59.75 16.95 60.09 18.16 60.55 18.7 60.71 19.85 60.96 20.95 61.11 22.45 61.2 28.25 61.21 29.2 61.28 30 61.49 30.65 61.78 31.3 62.24 31.71 62.65 32.16 63.3 32.41 63.85 32.62 64.55 32.72 65.25 32.74 78 32.75 78.08ZM59.8 55.11 59.1 55.15 58.4 55.11 57.85 55.02 57.35 54.86 56.8 54.61 56.35 54.31 55.9 53.87 55.59 53.5 55.14 52.75 54.83 52.05 52.4 45.12 39.55 45.13 37.01 52.4 36.71 53 36.31 53.6 35.9 54.05 35.4 54.46 34.99 54.7 34.5 54.9 33.6 55.11 32.55 55.13 31.6 55 30.75 54.7 30.02 54.25 29.63 53.9 29.28 53.5 28.79 52.65 28.52 51.85 28.41 51 28.43 50.1 28.64 49.1 39.13 20.05 39.49 19.2 39.83 18.55 40.29 17.85 40.64 17.4 41.05 16.96 41.6 16.48 42.15 16.1 42.85 15.73 44.2 15.29 44.85 15.19 45.65 15.13 46.45 15.14 47.35 15.24 47.9 15.35 48.8 15.65 49.8 16.14 50.35 16.53 50.85 16.97 51.26 17.4 51.76 18.05 52.22 18.8 52.51 19.4 63.31 48.85 63.51 49.6 63.61 50.7 63.51 51.7 63.3 52.44 63 53.05 62.75 53.45 62.2 54.05 61.5 54.57 60.7 54.91ZM50.36 38.1 46.11 24.75 46 24.4 45.95 24.37 41.6 38.1ZM113.09 47.3 113.92 47.1 114.75 46.67 115.39 46.15 115.92 45.5 116.3 44.75 116.5 44 116.52 43.1 116.35 42.3 116 41.5 113.71 36.9 113.32 36.25 112.9 35.75 112.15 35.12 111.65 34.85 111.2 34.69 110.75 34.6 110.2 34.56 109.7 34.61 109.25 34.72 108.35 35.11 107.8 35.48 107.29 35.95 106.79 36.65 106.48 37.4 106.35 38.25 106.38 39 106.54 39.65 106.74 40.15 109.08 45.05 109.58 45.85 110 46.3 110.4 46.62 111.29 47.1 112.15 47.3ZM130.24 80.9 130.85 80.81 131.4 80.66 131.85 80.47 132.3 80.21 132.97 79.6 133.46 78.8 133.67 78.2 133.8 77.55 133.85 77 133.82 76.5 133.72 75.95 133.53 75.45 133.31 75.05 133 74.65 132.63 74.3 132.25 74.03 131.55 73.69 127.5 72.58 125.35 71.82 124 71.26 121.9 70.26 120.55 69.52 119.48 68.85 120.45 67.7 121.61 66.2 122.72 64.55 123.67 62.95 124.47 61.4 125.12 59.95 125.77 58.25 126.45 56.08 130.2 56.06 131 55.97 131.65 55.77 132.35 55.42 132.89 55 133.37 54.45 133.71 53.85 133.91 53.25 134.02 52.55 134 51.9 133.87 51.25 133.62 50.65 133.26 50.1 132.77 49.6 132.25 49.23 131.6 48.93 130.85 48.73 130.25 48.67 97.4 48.66 96.55 48.74 95.6 49.03 94.9 49.44 94.29 50 93.93 50.5 93.69 51 93.49 51.75 93.45 52.3 93.49 52.9 93.63 53.5 93.84 54 94.14 54.5 94.6 55.01 95.2 55.47 95.8 55.77 96.45 55.97 97.25 56.06 101 56.08 101.64 58 102.34 59.8 103.09 61.45 103.88 62.95 104.83 64.55 105.94 66.2 106.79 67.35 108.02 68.85 106.85 69.56 105.65 70.21 103.4 71.27 101.9 71.87 99.95 72.55 97.55 73.25 96.25 73.58 95.6 73.88 95 74.29 94.33 75 94 75.55 93.69 76.4 93.59 77.15 93.64 78 93.84 78.65 94.19 79.3 94.5 79.69 94.81 80 95.3 80.36 96.05 80.72 96.9 80.91 97.55 80.95 98.45 80.86 99.35 80.66 102.3 79.86 105.28 78.8 107.1 78.02 108.45 77.37 111.1 75.91 112.45 75.07 113.8 74.14 116.05 75.66 117.65 76.62 119.75 77.72 122.11 78.8 124.35 79.66 127.15 80.51 128.75 80.86 129.4 80.92ZM113.8 64.1 112.35 62.35 111.1 60.55 110.34 59.25 109.79 58.2 109.09 56.65 108.88 56.1 108.9 56.07 118.5 56.07 118.57 56.1 117.7 58.18 116.6 60.25 115.25 62.3 114.35 63.48Z"),
    globe: glyph("lc-globe", "0 0 101.1 101.1", "M52.05 101.1 49.35 101.12 47.1 101.01 44.45 100.77 42 100.41 39.7 99.97 37.25 99.37 34.9 98.67 32.35 97.76 30.4 96.96 28.05 95.87 25.95 94.76 23.6 93.36 21.35 91.86 19.35 90.36 17.3 88.66 15.65 87.16 13.94 85.45 12.39 83.75 10.38 81.3 9.24 79.75 7.74 77.5 6.54 75.5 5.48 73.55 4.34 71.15 3.44 69 2.58 66.65 1.89 64.4 1.24 61.85 0.73 59.35 0.39 57.05 0.14 54.65 -0.01 51.85 -0.01 49.25 0.13 46.5 0.39 44.05 0.73 41.75 1.24 39.25 1.74 37.25 2.44 34.9 3.34 32.35 4.34 29.95 5.23 28.05 6.34 25.95 7.74 23.6 9.03 21.65 10.39 19.8 12.39 17.35 13.94 15.65 15.6 13.99 17.3 12.44 19.35 10.74 21.35 9.25 23.6 7.74 25.6 6.54 27.55 5.49 29.95 4.34 32.1 3.44 34.3 2.63 36.7 1.89 39.25 1.23 41.7 0.74 44.05 0.38 46.45 0.13 49.25 -0.01 51.7 -0.01 53.95 0.09 56.6 0.33 59.05 0.69 61.35 1.13 63.8 1.73 66.15 2.43 68.45 3.24 70.9 4.24 73.05 5.25 75.3 6.44 77.4 7.69 79.65 9.19 81.6 10.63 83.55 12.24 85.44 13.95 86.76 15.25 88.61 17.25 90.67 19.75 91.81 21.3 93.16 23.3 94.66 25.8 95.86 28.05 96.86 30.2 97.87 32.65 98.65 34.9 99.31 37.1 99.87 39.3 100.37 41.8 100.71 44.1 100.96 46.55 101.11 49.45 101.11 51.65 100.96 54.55 100.71 57 100.37 59.3 99.87 61.8 99.31 64 98.65 66.2 97.81 68.6 96.86 70.9 95.86 73.05 94.86 74.95 93.51 77.25 92.16 79.3 90.67 81.35 89.21 83.15 87.57 85 85.65 86.95 83.9 88.56 81.8 90.31 79.8 91.81 77.65 93.25 75.65 94.46 73.55 95.6 71.35 96.66 69.1 97.61 66.8 98.46 64.55 99.16 62.05 99.81 59.35 100.36 57.05 100.71 54.6 100.97ZM52.25 92.45 54.4 92.31 56.9 92.01 59.1 91.61 61.4 91.06 63.9 90.3 65.85 89.58 67.75 88.77 69.53 87.9 69.2 87.51 68.54 86.9 67.9 86.44 67 85.99 66.05 85.74 65 85.67 64.05 85.74 63.25 85.89 60.4 86.57 59.4 86.72 58.6 86.78 57.55 86.77 56.75 86.67 55.9 86.42 55.15 86.07 54.35 85.52 53.63 84.85 53.03 84.1 52.29 82.9 51.78 81.75 51.26 80.2 50.9 78.75 50.64 77.25 50.51 76 50.48 75.2 50.52 74.4 50.6 73.75 50.75 73.1 50.96 72.5 51.23 71.95 51.57 71.45 51.95 71.01 52.35 70.64 53.35 69.98 54.4 69.49 56.9 68.56 58.35 67.96 59.45 67.36 60.14 66.8 60.56 66.3 60.87 65.75 61.93 62.85 62.53 61.55 63.04 60.6 63.58 59.75 64.19 58.95 64.82 58.25 65.45 57.68 66.2 57.14 67.1 56.65 68.05 56.28 69 56.04 70.1 55.89 71.25 55.84 72.25 55.89 73.25 56.04 73.8 56.19 74.45 56.43 75.15 56.79 75.75 57.19 76.75 58.04 78.32 59.7 78.6 59.92 79 60.11 79.4 60.17 79.85 60.12 81.9 59.54 82.75 59.39 83.75 59.29 84.75 59.28 85.4 59.34 86.1 59.49 86.85 59.74 87.85 60.24 88.84 61 89.35 61.51 89.71 61.95 90.5 63.08 90.81 62.15 91.26 60.45 91.61 58.9 91.91 57.2 92.16 55.4 92.31 53.85 92.41 52.15 92.43 50.55 92.41 48.95 92.31 47.25 92.16 45.7 91.91 43.9 91.61 42.2 91.26 40.65 90.81 38.95 90.31 37.35 89.71 35.65 89.11 34.15 87.82 31.4 86.4 28.87 85.25 27.1 84.11 25.5 82.2 23.12 80.85 21.65 79.5 20.29 77.95 18.88 77 18.08 75.6 16.98 74.2 15.98 73 15.18 71.3 14.14 70.35 14.54 69.65 14.99 69.33 15.4 69.28 15.6 69.3 15.8 69.54 16.25 69.96 16.7 72.55 18.93 73.95 20.27 74.76 21.25 75.26 22.05 75.61 22.95 75.71 23.55 75.71 23.95 75.62 24.65 75.47 25.2 75.27 25.75 74.92 26.45 74.22 27.55 73.37 28.6 72.35 29.65 71.15 30.72 70 31.61 69 32.31 67.15 33.47 64.85 34.74 64.2 35.19 63.61 35.7 63.13 36.25 62.79 36.85 62.63 37.25 62.32 38.4 61.96 39.15 61.45 39.8 61.09 40.1 60.65 40.36 60.05 40.56 59.35 40.64 58.5 40.56 57.75 40.35 56.8 39.95 56 39.51 53.75 37.94 53.2 37.68 52.75 37.54 52.25 37.48 51.75 37.55 51.3 37.74 50.94 38.05 50.69 38.5 50.61 39 50.7 39.5 50.94 40 51.68 41 53.7 43.15 54.56 44.15 55.16 45 55.56 45.75 55.8 46.45 55.89 47.15 55.81 48.1 55.61 48.95 55.31 49.75 54.86 50.65 54.45 51.3 53.82 52.15 53.05 53 52.4 53.6 51.55 54.31 50.55 55.01 48.95 55.91 47.9 56.36 47.05 56.66 45.95 56.97 44.85 57.17 42.6 57.34 42.05 57.55 41.74 57.85 41.64 58.1 41.63 58.35 41.83 58.9 42.28 59.55 43.92 61.55 44.31 62.25 44.42 62.55 44.47 62.9 44.42 63.6 44.27 64.35 44.01 65.15 43.76 65.75 43.42 66.4 43.01 67.05 42.32 67.95 41.9 68.4 41.05 69.16 40.4 69.61 39.5 70.06 38.8 70.26 37.9 70.32 37.15 70.21 36.35 69.96 35.4 69.51 34.55 68.96 33.65 68.26 32.6 67.3 31.55 66.22 29.49 63.85 26.41 60 24.95 58.45 24.2 57.84 23.5 57.43 22.9 57.23 22.25 57.18 21.9 57.29 21.55 57.53 21.23 57.9 20.89 58.45 20.28 59.8 18.96 63.15 18.05 65.1 17.11 66.8 16.32 68 15.55 68.99 14.75 69.9 13.87 70.75 13.94 70.95 14.69 72.25 15.83 74 17 75.65 18.89 78 20.91 80.15 23 82.12 25.4 84.07 27.3 85.42 30.1 87.15 32.8 88.54 35.2 89.57 36.6 90.11 38.1 90.61 41.05 91.41 43.85 91.96 46.65 92.31 49.15 92.46ZM62.1 47.95 61.3 47.92 60.85 47.82 60.45 47.67 60.15 47.51 59.85 47.27 59.44 46.75 59.23 46.15 59.18 45.3 59.33 44.55 59.53 44.15 59.73 43.9 60.2 43.49 60.75 43.18 61.35 42.93 63.65 42.16 64.4 41.8 65.05 41.36 65.4 41.03 65.7 40.65 66.59 39 67.3 38 68.05 37.23 68.95 36.59 69.56 36.3 69.9 36.19 70.45 36.09 70.95 36.07 71.5 36.14 71.85 36.25 72.5 36.68 72.92 37.2 73.21 37.85 73.37 38.65 73.36 39.65 73.17 40.65 72.87 41.45 72.42 42.25 71.86 42.95 71.4 43.36 70.7 43.82 70.3 44.01 68.95 44.48 67.75 45.08 66.8 45.68 65.1 46.87 64.25 47.37 63.25 47.77 62.55 47.92ZM48.5 69.65 47.75 69.67 47.3 69.62 46.7 69.41 46.3 69.15 45.99 68.8 45.8 68.4 45.71 67.9 45.74 67.35 45.85 66.95 46.04 66.55 46.96 65.35 47.23 64.8 47.33 64.35 47.44 62.5 47.59 61.6 47.9 60.6 48.24 59.9 48.82 59.2 49.4 58.8 49.85 58.64 50.15 58.6 50.8 58.64 51.4 58.85 52.02 59.3 52.38 59.7 52.7 60.19 52.96 60.75 53.21 61.6 53.36 62.5 53.42 63.9 53.3 64.75 53.06 65.6 52.72 66.35 52.17 67.2 51.51 68 50.7 68.71 50 69.16 49.3 69.46ZM39.95 78.61 39.05 78.63 37.95 78.57 36.85 78.36 36 78.07 35.2 77.62 34.65 77.16 34.19 76.65 33.26 75.4 32.65 74.83 32.3 74.64 32 74.54 30.5 74.37 30.05 74.2 29.7 74.02 29.4 73.78 29.12 73.45 28.99 73.2 28.88 72.85 28.89 72.2 28.98 71.85 29.18 71.45 29.4 71.17 29.7 70.89 30.4 70.53 31.15 70.37 31.75 70.37 32.2 70.44 32.65 70.58 33.15 70.83 35.3 72.36 35.9 72.7 36.6 73.02 37.35 73.26 38.3 73.47 39.1 73.57 40.55 73.62 40.95 73.68 41.45 73.84 41.8 74.03 42.31 74.5 42.52 74.85 42.66 75.25 42.72 75.65 42.71 76.05 42.67 76.4 42.52 76.9 42.17 77.5 41.55 78.06 40.8 78.42Z"),
    pin: svg('<path d="M5.4 2.2h5.2M6.2 2.2v4.1L4.2 9h7.6L9.8 6.3V2.2M8 9v4.8"/>'),
    pinFill: svg('<path class="lc-fill" d="M5.4 1.6h5.2c.3 0 .6.3.6.6s-.3.6-.6.6h-.2v3.3l1.9 2.5c.3.4 0 1-.5 1H8.6v4.2c0 .3-.3.6-.6.6s-.6-.3-.6-.6V9.6H4.6c-.5 0-.8-.6-.5-1l1.9-2.5V2.8h-.6c-.3 0-.6-.3-.6-.6s.3-.6.6-.6z"/>'),
    xmark: svg('<path d="M4.6 4.6l6.8 6.8M11.4 4.6l-6.8 6.8"/>'),
    uturn: svg('<path d="M5.6 3.2 2.6 6.2l3 3"/><path d="M2.8 6.2h6.6c2.2 0 4 1.8 4 4s-1.8 4-4 4H7.6"/>'),
  };
  // The film's Windows cut (win.js) draws the Windows app's own symbols.
  Object.assign(SYM, window.LC_SYM || {});

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
  const zoomFor = () => window.FILM_CARD_ZOOM || 1;
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
      const below = vh - a.bottom - 16 - (a.reserveBelow || 0), above = a.top - 16;
      // The opening's sentence asks for below where there's a fair room for it: its card then
      // scrolls inside rather than covering the line over it.
      if (first) card.below = below >= Math.max(natural, 320) || below >= above || (a.preferBelow && below >= 260);
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

    // On a touch screen a swipe on the card is the card's: it scrolls the card when the card
    // has more to show and does nothing past its ends, but never scrolls the page under it,
    // which would put the card away mid-read. (overscroll-behavior alone doesn't hold on a
    // card that fits, or on iOS.)
    let touchY = 0;
    el.addEventListener("touchstart", (e) => { touchY = e.touches[0].clientY; }, { passive: true });
    el.addEventListener("touchmove", (e) => {
      if (e.touches.length !== 1) return;
      const s = card.scroll, y = e.touches[0].clientY, dy = touchY - y;
      touchY = y;
      const room = s.scrollHeight - s.clientHeight;
      const can = room > 1 && (dy > 0 ? s.scrollTop < room - 1 : s.scrollTop > 0);
      if (!can || !e.target.closest(".lc-scroll")) e.preventDefault();
    }, { passive: false });

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
      // For the page around the card: while a word's meanings are open, and the app picked one
      // of them from the sentence, the open list and that meaning. Nothing while closed, or
      // for a word it couldn't pick from context (one meaning, grammar, matched to the
      // translation, a guess).
      card.pickTarget = () => {
        const e = rowEls.find((x) => x.r.id === st.expanded && x.detail), r = e && e.r;
        if (!r || r.senses.length < 2 || r.shown == null || r.grammar || r.viaTranslation || r.guess || r.failure) return null;
        return { scope: e.detail, chosen: r.shown, id: r.id };
      };
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
