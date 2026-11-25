const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'playwright-core');
(async () => {
  const b = await chromium.launch({ channel: 'chrome' });
  const p = await (await b.newContext({ viewport: { width: 1440, height: 810 }, reducedMotion: 'reduce' })).newPage();
  await p.goto((process.env.FILM_URL || 'http://127.0.0.1:8791/film/'), { waitUntil: 'load' });
  await p.evaluate(() => window.film.ready);
  const rows = await p.evaluate(() => {
    const out = [], N = Math.round(window.film.T * 60);
    for (let i = 0; i < N; i++) {
      window.film.render(i / 60);
      const m = new DOMMatrix(getComputedStyle(document.getElementById('cam')).transform);
      const c = document.getElementById('cursor').getBoundingClientRect();
      out.push([(720 - m.e) / m.a, (405 - m.f) / m.a, Math.log(m.a) * 1000, (c.left - m.e) / m.a, (c.top - m.f) / m.a]);
    }
    return out;
  });
  const names = ['camX', 'camY', 'zoom', 'curX', 'curY'];
  for (let k = 0; k < 5; k++) {
    let worst = [];
    for (let i = 2; i < rows.length; i++) {
      const v1 = rows[i][k] - rows[i - 1][k], v0 = rows[i - 1][k] - rows[i - 2][k];
      worst.push([Math.abs(v1 - v0), i, v0.toFixed(2), v1.toFixed(2)]);
    }
    worst.sort((a, b) => b[0] - a[0]);
    console.log(names[k], worst.slice(0, 5).map((w) => `f${w[1]} t=${(w[1] / 60).toFixed(2)} dv=${w[0].toFixed(2)} (${w[2]}->${w[3]})`).join(' | '));
  }
  // loop seam: last vs first
  console.log('seam', JSON.stringify(rows[rows.length - 1]), JSON.stringify(rows[0]));
  await b.close();
})();
