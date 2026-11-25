// peek.js <outdir> t1,t2,... : render the film at those times (1440×810 @1x) to check it.
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'playwright-core');
const out = process.argv[2];
const times = (process.argv[3] || '0').split(',').map(Number);
(async () => {
  const b = await chromium.launch({ channel: 'chrome' });
  const p = await (await b.newContext({ viewport: { width: 1440, height: 810 }, deviceScaleFactor: Number(process.argv[4] || 1), reducedMotion: 'reduce' })).newPage();
  const errs = []; p.on('pageerror', (e) => errs.push(e.message)); p.on('response', (r) => { if (r.status() >= 400) errs.push(r.status() + ' ' + r.url()); }); p.on('console', (m) => { if (m.type() === 'error') errs.push(m.text()); });
  await p.goto((process.env.FILM_URL || 'http://127.0.0.1:8791/film/').replace(/$/, (process.env.FILM_URL || '').includes('?') ? '&r=' + Date.now() : '?r=' + Date.now()), { waitUntil: 'load' });
  await p.evaluate(() => window.film.ready);
  console.log('T', await p.evaluate(() => window.film.T), JSON.stringify(await p.evaluate(() => window.film.plan().map((x) => ({ down: +x.tDown.toFixed(2), open: +x.tOpen.toFixed(2), close: +x.tClose.toFixed(2), frame: x.frame })))));
  for (const t of times) {
    await p.evaluate((t) => window.film.render(t), t);
    await p.screenshot({ path: `${out}/t${t.toFixed(2)}.png` });
  }
  console.log('errors', errs);
  await b.close();
})();
