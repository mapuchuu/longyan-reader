// shoot.js <outdir> <scale> [shots] : the Store screenshots, 960×540 points at <scale>
// (2 for 1920×1080, 4 for 3840×2160). Serve the repo root on 8793 first.
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'playwright-core');
const [out, scale = '2', list = '1,2,3,4,5,6,7'] = process.argv.slice(2);
(async () => {
  const b = await chromium.launch({ channel: 'chrome' });
  const ctx = await b.newContext({ viewport: { width: 960, height: 540 }, deviceScaleFactor: Number(scale), reducedMotion: 'reduce' });
  for (const n of list.split(',')) {
    const p = await ctx.newPage(); const errs = [];
    p.on('pageerror', (e) => errs.push(e.message)); p.on('console', (m) => { if (m.type() === 'error') errs.push(m.text()); });
    await p.goto(`${process.env.STORE_URL || 'http://127.0.0.1:8793/windows/listing/'}?shot=${n}`, { waitUntil: 'load' });
    await p.waitForFunction(() => document.body.dataset.ready === '1', null, { timeout: 15000 }).catch(() => errs.push('not ready'));
    await p.waitForTimeout(400);
    await p.screenshot({ path: `${out}/screenshot-${n}.png` });
    if (errs.length) console.log(n, errs);
    await p.close();
  }
  await b.close();
})();
