// shootfilm.js <outdir> [scale] [from] [to] : every frame of the background video
// (index.html?film) at 960x540 points × scale (2 for 1920x1080), JPEG q95. Serve the repo on 8793.
// Encode: swift ../../film/encode.swift <outdir> out.mp4 h264 12000000 60 1920 1080
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'playwright-core');
const fs = require('fs');
const [out, scale = '2', from, to] = process.argv.slice(2);
fs.mkdirSync(out, { recursive: true });
(async () => {
  const b = await chromium.launch({ channel: 'chrome' });
  const p = await (await b.newContext({ viewport: { width: 960, height: 540 }, deviceScaleFactor: Number(scale) })).newPage();
  p.on('pageerror', (e) => console.log('error', e.message));
  await p.goto(`${process.env.STORE_URL || 'http://127.0.0.1:8793/windows/listing/'}?film${process.env.BARE ? "&bare" : ""}`, { waitUntil: 'load' });
  await p.waitForFunction(() => document.body.dataset.ready === '1', null, { timeout: 15000 });
  await p.waitForTimeout(300);
  const { T, FPS } = await p.evaluate(() => ({ T: window.film.T, FPS: window.film.FPS }));
  const times = from !== undefined ? (to !== undefined ? null : from.split(',').map(Number)) : null;
  if (times) {
    for (const t of times) { await p.evaluate((t) => window.film.render(t), t); await p.screenshot({ path: `${out}/t${t}.png` }); }
  } else {
    const N = Math.round(T * FPS); console.log('frames', N, 'T', T);
    for (let i = 0; i < N; i++) {
      await p.evaluate((t) => window.film.render(t), i / FPS);
      await p.screenshot({ path: `${out}/f${String(i).padStart(5, '0')}.jpg`, type: 'jpeg', quality: 95 });
      if (i % 200 === 0) console.log(i);
    }
  }
  await b.close();
})();
