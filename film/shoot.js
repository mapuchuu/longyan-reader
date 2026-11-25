// shoot.js <outdir> <workers> : every frame of the film at 2560×1440, JPEG q95.
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'playwright-core');
const fs = require('fs');
const out = process.argv[2], W = Number(process.argv[3] || 4);
fs.mkdirSync(out, { recursive: true });
(async () => {
  const b = await chromium.launch({ channel: 'chrome' });
  const open = async () => {
    const p = await (await b.newContext({ viewport: { width: 1440, height: 810 }, deviceScaleFactor: 2560 / 1440, reducedMotion: 'reduce' })).newPage();
    await p.goto((process.env.FILM_URL || 'http://127.0.0.1:8791/film/'), { waitUntil: 'load' });
    await p.evaluate(() => window.film.ready);
    return p;
  };
  const pages = await Promise.all(Array.from({ length: W }, open));
  const { T, FPS } = await pages[0].evaluate(() => ({ T: window.film.T, FPS: window.film.FPS || 60 }));
  const N = Math.round(T * FPS);
  console.log('frames', N, 'fps', FPS);
  let done = 0;
  await Promise.all(pages.map(async (p, w) => {
    for (let i = w; i < N; i += W) {
      const f = `${out}/f${String(i).padStart(5, '0')}.jpg`;
      if (fs.existsSync(f)) { done++; continue; }
      await p.evaluate((t) => window.film.render(t), i / FPS);
      await p.screenshot({ path: f, type: 'jpeg', quality: 95 });
      if (++done % 100 === 0) console.log(done);
    }
  }));
  await b.close();
  console.log('done', N);
})();
