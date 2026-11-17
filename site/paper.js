// Paper: soft color fields with folds of light, like a macOS wallpaper. One WebGL context draws
// every backdrop on the page into its own 2D canvas. Backdrops marked data-live drift slowly
// while they're on screen; the rest are drawn once. The grain is a CSS overlay at full
// resolution, so the color can be rendered at a lower one.
(function () {
  "use strict";
  const targets = [...document.querySelectorAll("canvas[data-paper]")];
  if (!targets.length) return;
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Five stops from deep to light, then the fold direction and a disc (x, y, radius) or none.
  const PAPERS = {
    azure:  { c: ["#0a3fb8", "#1f6fe0", "#4aa2f2", "#9fd2fa", "#e6f5ff"], dir: [1, -0.55], disc: null },
    rose:   { c: ["#8f2340", "#cf4f5c", "#ec8a7e", "#f8c3b5", "#fff0ea"], dir: [1, -0.4], disc: [0.18, 0.3, 0.42] },
    green:  { c: ["#0b5e44", "#1c9468", "#4fc28d", "#a9e6c2", "#ecfbf2"], dir: [1, -0.7], disc: [0.86, 0.2, 0.36] },
    blue:   { c: ["#1a2f9c", "#3b62e0", "#7398f5", "#bccdfd", "#eef2ff"], dir: [1, -0.5], disc: [0.2, 0.75, 0.4] },
    violet: { c: ["#3f1d9c", "#6b3fe0", "#9b74f5", "#d0bcfc", "#f4effe"], dir: [1, -0.6], disc: [0.8, 0.82, 0.38] },
    dusk:   { c: ["#2a1450", "#6b2f86", "#c4567a", "#f29a7e", "#ffe2c8"], dir: [1, -0.45], disc: null },
  };

  const VERT = "attribute vec2 a;void main(){gl_Position=vec4(a,0.,1.);}";
  const FRAG = `
precision highp float;
uniform vec2 uRes; uniform float uTime; uniform float uSeed; uniform float uSplit;
uniform vec3 uC0, uC1, uC2, uC3, uC4; uniform vec2 uDir; uniform vec3 uDisc;
float h(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float n(vec2 p){ vec2 i = floor(p), f = fract(p); f = f*f*(3.-2.*f);
  return mix(mix(h(i), h(i+vec2(1,0)), f.x), mix(h(i+vec2(0,1)), h(i+vec2(1,1)), f.x), f.y); }
float fbm(vec2 p){ float s = 0., a = .5; for (int i = 0; i < 4; i++){ s += a*n(p); p = p*2.03 + 17.1; a *= .5; } return s; }
vec3 ramp(float g){
  g = clamp(g, 0., 1.) * 4.;
  if (g < 1.) return mix(uC0, uC1, g);
  if (g < 2.) return mix(uC1, uC2, g-1.);
  if (g < 3.) return mix(uC2, uC3, g-2.);
  return mix(uC3, uC4, g-3.);
}
void main(){
  vec2 uv = gl_FragCoord.xy / uRes; uv.y = 1. - uv.y;
  float asp = uRes.x / uRes.y;
  vec2 p = vec2(uv.x * asp, uv.y);
  float t = uTime * .035;
  vec2 q = p * .9 + uSeed;
  float w = fbm(q + vec2(t, -t*.6));
  float w2 = fbm(q*1.6 - vec2(t*.7, t*.3) + 1.7*w);
  float g = .12 + .5*uv.x + .3*(1.-uv.y) + .55*(w2 - .5);
  vec3 col = ramp(g);
  // Folds: light rises slowly toward a crease, then drops off at it.
  vec2 d = normalize(uDir);
  float span = abs(d.x)*asp + abs(d.y);
  for (int k = 0; k < 3; k++){
    float fk = float(k);
    float x = dot(p, d) + (d.y < 0. ? -d.y : 0.) + .16*(w - .5) + .03*sin(uTime*.05 + fk*2.1);
    float c = span * (.24 + .3*fk) + .14*sin(uSeed*1.7 + fk*2.3);
    float wd = .2 + .12*fk;
    float rise = smoothstep(c - wd, c, x);
    float fall = 1. - smoothstep(c, c + .006, x);
    float shade = smoothstep(c, c + .006, x) * (1. - smoothstep(c + .006, c + .22, x));
    col = mix(col, vec3(1.), rise*rise*fall*.32);
    col *= 1. - shade*.1;
  }
  // A disc of lighter paper, cut cleanly.
  if (uDisc.z > 0.){
    float r = length((uv - uDisc.xy) * vec2(asp, 1.)) - uDisc.z;
    float inside = 1. - smoothstep(-.002, .002, r);
    col = mix(col, mix(col, uC4, .35), inside);
    col *= 1. - .12 * (1. - smoothstep(0., .08, r)) * (1. - inside);
  }
  // A lighter band along the bottom with a clean edge, like a second sheet.
  if (uSplit > 0.){
    float s = smoothstep(uSplit - .0015, uSplit + .0015, uv.y);
    col *= 1. - .1 * (1. - smoothstep(0., .05, uSplit - uv.y)) * (1. - s);
    col = mix(col, mix(col, uC4, .55), s);
  }
  gl_FragColor = vec4(col, 1.);
}`;

  const glc = document.createElement("canvas");
  const gl = glc.getContext("webgl", { antialias: false, preserveDrawingBuffer: true, premultipliedAlpha: false });
  if (!gl) { targets.forEach((c) => c.classList.add("paper-fallback")); return; }
  const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; };
  const prog = gl.createProgram();
  gl.attachShader(prog, sh(gl.VERTEX_SHADER, VERT));
  gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FRAG));
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) { targets.forEach((c) => c.classList.add("paper-fallback")); return; }
  gl.useProgram(prog);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(prog, "a");
  gl.enableVertexAttribArray(loc);
  gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  const U = {};
  ["uRes", "uTime", "uSeed", "uSplit", "uC0", "uC1", "uC2", "uC3", "uC4", "uDir", "uDisc"].forEach((k) => (U[k] = gl.getUniformLocation(prog, k)));
  const rgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);

  const items = targets.map((canvas, i) => ({
    canvas, ctx: canvas.getContext("2d"),
    paper: PAPERS[canvas.dataset.paper] || PAPERS.azure,
    seed: +(canvas.dataset.seed || i * 3.7 + 1.3),
    split: +(canvas.dataset.split || 0),
    live: canvas.hasAttribute("data-live") && !reduce,
    visible: false, w: 0, h: 0,
  }));

  function size(it) {
    // Color fields have no fine detail, so they're drawn at CSS pixels, not device pixels.
    const r = it.canvas.getBoundingClientRect();
    const scale = Math.min(1, 1600 / Math.max(1, r.width));
    it.w = Math.max(2, Math.round(r.width * scale)); it.h = Math.max(2, Math.round(r.height * scale));
    if (it.canvas.width !== it.w || it.canvas.height !== it.h) { it.canvas.width = it.w; it.canvas.height = it.h; }
  }

  function render(it, time) {
    if (glc.width !== it.w || glc.height !== it.h) { glc.width = it.w; glc.height = it.h; }
    gl.viewport(0, 0, it.w, it.h);
    const p = it.paper;
    gl.uniform2f(U.uRes, it.w, it.h);
    gl.uniform1f(U.uTime, time);
    gl.uniform1f(U.uSeed, it.seed);
    gl.uniform1f(U.uSplit, it.split);
    p.c.forEach((hex, k) => gl.uniform3fv(U["uC" + k], rgb(hex)));
    gl.uniform2fv(U.uDir, p.dir);
    gl.uniform3fv(U.uDisc, it.canvas.dataset.disc === "none" || !p.disc ? [0, 0, 0] : p.disc);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    it.ctx.drawImage(glc, 0, 0);
  }

  const t0 = performance.now();
  let raf = 0, last = 0;
  function loop(now) {
    raf = 0;
    // Thirty frames a second is plenty for something this slow.
    if (now - last > 32) {
      last = now;
      for (const it of items) if (it.live && it.visible) render(it, (now - t0) / 1000 + 40);
    }
    if (items.some((it) => it.live && it.visible) && !document.hidden) raf = requestAnimationFrame(loop);
  }
  const wake = () => { if (!raf) raf = requestAnimationFrame(loop); };

  function drawAll() { for (const it of items) { size(it); render(it, 40); } }
  drawAll();

  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      const it = items.find((x) => x.canvas === e.target);
      it.visible = e.isIntersecting;
    }
    wake();
  }, { rootMargin: "100px" });
  items.forEach((it) => io.observe(it.canvas));
  document.addEventListener("visibilitychange", wake);
  let timer = 0;
  window.addEventListener("resize", () => { clearTimeout(timer); timer = setTimeout(drawAll, 150); });
})();
