// Paper: pieces of sky, deep blue with high cloud drifting across it, under a fine grain. One WebGL context draws
// every backdrop on the page into its own 2D canvas. Backdrops marked data-live drift slowly
// while they're on screen; the rest are drawn once. The grain is a CSS overlay at full
// resolution, so the color can be rendered at a lower one.
(function () {
  "use strict";
  const targets = [...document.querySelectorAll("canvas[data-paper]")];
  if (!targets.length) return;
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Each backdrop is a piece of sky: deep, mid and bright blue, the colour of its wisps,
  // and the colour it drifts toward in one corner. One family of blues across the site.
  const PAPERS = {
    azure:  { c: ["#0a3db2", "#166fdf", "#2e9feb", "#d2e8ff", "#1cb0c6"] },
    cobalt: { c: ["#13289c", "#2450d6", "#4887ec", "#d8e5ff", "#3b9fe6"] },
    sky:    { c: ["#0a52b4", "#1384de", "#2fb3ea", "#d8f2ff", "#1fbfc4"] },
    indigo: { c: ["#171987", "#2f37c2", "#556ce4", "#dee1ff", "#4c8cee"] },
  };

  const VERT = "attribute vec2 a;void main(){gl_Position=vec4(a,0.,1.);}";
  const FRAG = `
precision highp float;
uniform vec2 uRes; uniform float uTime; uniform float uSeed;
uniform vec3 uC0, uC1, uC2, uC3, uC4;
float h(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float n(vec2 p){ vec2 i = floor(p), f = fract(p); f = f*f*(3.-2.*f);
  return mix(mix(h(i), h(i+vec2(1,0)), f.x), mix(h(i+vec2(0,1)), h(i+vec2(1,1)), f.x), f.y); }
float fbm(vec2 p){ float s = 0., a = .5; for (int i = 0; i < 5; i++){ s += a*n(p); p = p*2.02 + 17.1; a *= .5; } return s; }
// Wisps of high cloud along a direction: noise stretched along it, bent by a slower noise,
// kept only where it's strong, with finer fibres running through.
float wisps(vec2 p, float ang, float stretch, float seed, float t){
  vec2 d = vec2(cos(ang), sin(ang)), m = vec2(-d.y, d.x);
  vec2 r = vec2(dot(p, d), dot(p, m));
  r.y += .22*(fbm(r*.9 + seed + t) - .5);
  r.x += .4*(fbm(r*.6 - seed) - .5);
  float body = fbm(vec2(r.x*.55, r.y*stretch) + seed);
  float streak = smoothstep(.44, .84, body);
  float fibre = fbm(vec2(r.x*1.6, r.y*stretch*3.4) + seed*1.7 + t*.5);
  return streak * (.6 + .55*fibre);
}
void main(){
  vec2 uv = gl_FragCoord.xy / uRes; uv.y = 1. - uv.y;
  float asp = uRes.x / uRes.y;
  vec2 p = vec2(uv.x * asp, uv.y) * (1.4 / max(1., asp*.75));
  float t = uTime * .012;
  // The sky: deeper above, brighter below, uneven everywhere (a field warped by itself).
  vec2 q = p*.8 + uSeed;
  vec2 wq = vec2(fbm(q + t), fbm(q + 5.2 - t));
  float g = fbm(q*.9 + 1.6*wq);
  float lift = clamp(.18 + .55*uv.y + .12*uv.x + .7*(g - .5), 0., 1.);
  vec3 col = lift < .5 ? mix(uC0, uC1, lift*2.) : mix(uC1, uC2, lift*2. - 1.);
  // Toward one corner it turns, as a real sky does near the horizon.
  float turn = smoothstep(.35, 1., uv.y*.7 + uv.x*.5 + .5*(fbm(q*.7 + 9.) - .5));
  col = mix(col, uC4, turn*.55);
  // High cloud: one broad set of wisps, a finer set at a slightly different angle, and a
  // faint haze across both.
  float w1 = wisps(p, -.42 + .08*sin(uSeed), 3.2, uSeed + 3., t);
  float w2 = wisps(p, -.3 + .1*cos(uSeed*1.3), 7., uSeed + 11., t);
  float w3 = wisps(p*.55, -.5, 1.8, uSeed + 23., t);
  // Cloud gathers in some places and clears in others.
  float gather = smoothstep(.24, .66, fbm(p*.45 + uSeed + 40.));
  float cloud = clamp((w1*.78 + w2*.28 + w3*.5) * (.35 + 1.*gather), 0., 1.);
  col = mix(col, uC3, cloud*.76);
  col += (uC3 - col) * pow(cloud, 3.) * .35;
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
  ["uRes", "uTime", "uSeed", "uC0", "uC1", "uC2", "uC3", "uC4"].forEach((k) => (U[k] = gl.getUniformLocation(prog, k)));
  const rgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);

  const items = targets.map((canvas, i) => ({
    canvas, ctx: canvas.getContext("2d"),
    paper: PAPERS[canvas.dataset.paper] || PAPERS.azure,
    seed: +(canvas.dataset.seed || i * 3.7 + 1.3),
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
    p.c.forEach((hex, k) => gl.uniform3fv(U["uC" + k], rgb(hex)));
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
