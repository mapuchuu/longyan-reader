// Paper: sheets of colour folded over a night ground, like a Mac wallpaper, under a fine grain. One WebGL context draws
// every backdrop on the page into its own 2D canvas. Backdrops marked data-live drift slowly
// while they're on screen; the rest are drawn once. The grain is a CSS overlay at full
// resolution, so the color can be rendered at a lower one.
(function () {
  "use strict";
  const targets = [...document.querySelectorAll("canvas[data-paper]")];
  if (!targets.length) return;
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Each backdrop is a few sheets of colour folded over a deep night ground, the way a Mac
  // wallpaper is: lit along their top edges, shading deeper below, each casting a soft shadow
  // on the one behind. The colours are the demo selection's own sheen (system blue through
  // violet to rose), so the glass over them has something to catch. Per backdrop: the ground,
  // the three sheets back to front, and the light along their edges. The closing's turns
  // toward dawn.
  const PAPERS = {
    azure:  { c: ["#040720", "#1a2a9e", "#2f6dff", "#9a5cf5", "#d6e4ff"] },
    cobalt: { c: ["#07051c", "#3a1f9e", "#7a4df2", "#e05bc8", "#ffd6f4"] },
    sky:    { c: ["#030a1c", "#0d3c9e", "#1b8cf5", "#36d0e0", "#d0f6ff"] },
    indigo: { c: ["#08061c", "#2d1f8a", "#5a48e8", "#ff6a9a", "#ffd9e4"] },
    dawn:   { c: ["#0b0c2c", "#3b2c9a", "#8a5ce0", "#ff8a6a", "#ffe6d2"] },
  };

  const VERT = "attribute vec2 a;void main(){gl_Position=vec4(a,0.,1.);}";
  const FRAG = `
precision highp float;
uniform vec2 uRes; uniform float uTime; uniform float uSeed; uniform float uDrop;
uniform vec3 uC0, uC1, uC2, uC3, uC4;
float h(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float n(vec2 p){ vec2 i = floor(p), f = fract(p); f = f*f*(3.-2.*f);
  return mix(mix(h(i), h(i+vec2(1,0)), f.x), mix(h(i+vec2(0,1)), h(i+vec2(1,1)), f.x), f.y); }
// One sheet: its top edge a long, uneven wave across the frame. Returns the colour over
// what's behind it.
vec3 sheet(vec3 under, vec2 p, float k, vec3 c, vec3 next, float off, float ang, float t, float px){
  float s = uSeed + k*7.31;
  vec2 d = vec2(cos(ang), sin(ang));
  float x = dot(p, d), y = dot(p, vec2(-d.y, d.x));
  float edge = off
    + .10*sin(x*1.15 + s*1.7 + t)
    + .045*sin(x*2.6 - s*.9 - t*.8)
    + .07*(n(vec2(x*.9 + s, s*3.1 + t*.3)) - .5);
  float dist = y - edge;                       // below the edge (inside the sheet) is > 0
  float inside = smoothstep(-px, px, dist);
  // Behind the edge, the sheet's shadow on what's under it.
  under *= 1. - .5*exp(-max(-dist, 0.)*9.)*(1. - inside);
  // The sheet: its colour drifting toward the next one along its length, lit at the edge,
  // deepening away from it.
  vec3 col = mix(c, next, .35 + .35*sin(x*1.3 + s));
  col = mix(col, uC0*.6 + col*.25, smoothstep(.04, .85, dist));
  col = mix(col, uC4, .55*exp(-max(dist, 0.)*26.));
  return mix(under, col, inside);
}
void main(){
  vec2 uv = gl_FragCoord.xy / uRes; uv.y = 1. - uv.y;
  float asp = uRes.x / uRes.y;
  vec2 p = vec2((uv.x - .5) * asp, uv.y - .5) / max(1., asp*.62);
  float px = 1.6 / uRes.y;
  float t = uTime * .035;
  // The ground: deep at the top, a glow of the middle sheet's colour low down.
  vec3 col = mix(uC0, uC1*.5 + uC0*.5, smoothstep(-.2, 1.1, uv.y));
  col += uC2 * .22 * exp(-dot(p - vec2(.25*sin(uSeed), .35), p - vec2(.25*sin(uSeed), .35)) * 3.);
  // Three sheets, back to front, each a little lower and at its own angle.
  // Some rise to the right, some to the left, at angles of their own.
  float a = (fract(uSeed*.618) < .5 ? -1. : 1.) * (.22 + .14*fract(uSeed*1.37));
  // uDrop sets them lower, for a backdrop with words across its top.
  col = sheet(col, p, 0., uC1, uC2, -.12 + uDrop, a + .06, t, px*2.);
  col = sheet(col, p, 1., uC2, uC3, .06 + uDrop, a - .05, t*.8, px*1.5);
  col = sheet(col, p, 2., uC3, uC1, .24 + uDrop, a + .1, t*.6, px);
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
  ["uRes", "uTime", "uSeed", "uDrop", "uC0", "uC1", "uC2", "uC3", "uC4"].forEach((k) => (U[k] = gl.getUniformLocation(prog, k)));
  const rgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);

  const items = targets.map((canvas, i) => ({
    canvas, ctx: canvas.getContext("2d"),
    paper: PAPERS[canvas.dataset.paper] || PAPERS.azure,
    seed: +(canvas.dataset.seed || i * 3.7 + 1.3),
    drop: +(canvas.dataset.drop || 0),
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
    gl.uniform1f(U.uDrop, it.drop);
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
