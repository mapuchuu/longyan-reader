// The Store's logo art: the mark, black, on white. node logo.js <outdir>
// Box art 1:1 (2160, 1080), the 300 px tile, and the 2:3 poster (1440x2160, 720x1080).
// The poster has the name under the mark. The mark is 56% of the short side, as on the old cream art; the white falls off by 3% toward
// the bottom so the square still has an edge on a white page.
const path = require("path");
const { chromium } = require(process.env.PLAYWRIGHT_CORE || "playwright-core");
const out = process.argv[2];
const EYE = '<svg viewBox="0 0 1200 848.53" style="width:56%;display:block"><path fill="#1b1b1b" fill-rule="evenodd" d="M0 424.26L300 124.26A424.26 424.26 0 0 1 900 124.26L1200 424.26L900 724.26A424.26 424.26 0 0 1 300 724.26ZM225 424.26L412.5 236.76A265.17 265.17 0 0 1 787.5 236.76L975 424.26L787.5 611.76A265.17 265.17 0 0 1 412.5 611.76ZM471.43 424.26L535.71 359.98A90.91 90.91 0 0 1 664.29 359.98L728.57 424.26L664.29 488.55A90.91 90.91 0 0 1 535.71 488.55ZM728.57 424.26L975 424.26L851.79 547.48Z"/></svg>';
const SIZES = [["box-2160.png", 2160, 2160], ["box-1080.png", 1080, 1080], ["tile-300.png", 300, 300], ["poster-1440x2160.png", 1440, 2160], ["poster-720x1080.png", 720, 1080]];
(async () => {
  const b = await chromium.launch({ channel: "chrome" });
  for (const [name, w, h] of SIZES) {
    const p = await b.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 1 });
    const side = Math.min(w, h);
    const poster = h > w, u = w / 100;
    await p.goto("file://" + path.resolve(__dirname, "../../film/fonts/") + "/");
    await p.setContent(`<style>@font-face{font-family:"W Segoe";src:url("file://${path.resolve(__dirname, "../../film/fonts/SegUIVar.ttf")}");font-weight:200 700}</style><body style="margin:0;width:${w}px;height:${h}px;background:linear-gradient(#fff 45%,#f5f6f8);display:grid;place-items:center">
      <div style="width:${side}px;display:grid;place-items:center;${poster ? `margin-top:-${18 * u}px` : ""}">${EYE}</div>
      ${poster ? `<div style="position:absolute;left:0;right:0;top:${h / 2 + 23 * u}px;text-align:center;font:600 ${7.4 * u}px/1.1 'W Segoe';letter-spacing:-.01em;color:#1b1b1b">Longyan Reader<div style="margin-top:${2.2 * u}px;font-weight:400;font-size:${3.9 * u}px;color:rgba(0,0,0,.56)">Read Chinese in any app</div></div>` : ""}</body>`);
    await p.evaluate(() => document.fonts.ready);
    await p.screenshot({ path: path.join(out, name) });
    await p.close();
  }
  await b.close();
})();
