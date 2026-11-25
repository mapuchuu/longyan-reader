# The site film

Source for `site/media/reading-9.mp4`, the "Longyan works everywhere you read" video. It's an HTML set, not a screen recording: every frame is a function of time, so the pointer and camera move without jumps.

- `index.html`, `film.css`, `film.js`: the set (three windows, the pointer, the camera).
- `card.js`: a copy of `site/card.js` drawn at the app's 1:1 size.
- `data.js`: the cards, from `LongyanReader --site-json` for each sentence.

Make it (needs Node with `playwright-core` and Google Chrome; set `PLAYWRIGHT_CORE` to its path if it isn't installed here):

```
python3 -m http.server 8791 --bind 127.0.0.1      # from the repo root
node film/peek.js /tmp/peek 2,6,10                # check a few frames
node film/smooth.js                               # check the camera and pointer for jumps
node film/shoot.js /tmp/frames 4                  # every frame at 2560×1440
swift film/encode.swift /tmp/frames reading-10.mp4 hevc 3000000 60
swift film/encode.swift /tmp/frames reading-10-h264.mp4 h264 5000000 60
```

Give a new film a new file name (browsers cache these), upload it to the `site-media` release, and update `site/index.html`.
