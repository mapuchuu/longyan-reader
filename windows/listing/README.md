# Store listing art

The Microsoft Store listing's pictures, drawn in Chrome from the site and the app's own parts:
the grounds are the site's feature tiles (site/style.css, cloned from site/index.html), the cards
are film/card.js in the Windows look (film/win.css, film/win.js), the fonts are Windows' own
(film/fonts, not in git: see film/README.md).

Serve the repo root first: `python3 -m http.server 8793` from the repo.

- Screenshots, 1920×1080: `node shoot.js <outdir> 2` (index.html?shot=1…7). Upload these, not a
  4× set: shots 6 and 7 are captures from Windows at 2×, so at 3840 they'd be stretched.
- Background video (the listing's first trailer), 23.4 s, loops:
  `node shootfilm.js <frames> 2`, then
  `swift ../../film/encode.swift <frames> hero.mp4 h264 12000000 60 1920 1080`.
  `node shootfilm.js <dir> 2 5.5` draws one frame (t = 5.5 s), for its thumbnail.
- Super hero art (16:9, artwork only, no headline): the video's frame at 5.5 s without its
  words, so the page goes from the video's end to the same picture.
  `BARE=1 node shootfilm.js <dir> 4 5.5` (3840×2160; the card and browser are drawn, so 4× is sharp).
- Logo art, black mark on white (box art 2160 and 1080, the 300 px tile, the 2:3 poster):
  `node logo.js <outdir>`.

Set PLAYWRIGHT_CORE to a playwright-core install; Chrome itself is used.

art/history.png and art/settings.png are the Windows app's lookup history and settings windows,
shot in the Windows 11 VM.
