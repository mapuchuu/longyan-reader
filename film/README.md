# The site film

Source for `site/media/reading-12.mp4`, the "Longyan works across any app" video: 白 in a news article, a chat and a novel, with the card picking what it means in each (in the novel, a whole sentence is translated and 白's row clicked open), then the three side by side on the site's own paper. It's an HTML set, not a screen recording: every frame is a function of time, so the pointer and camera move without jumps.

- `index.html`, `film.css`, `film.js`: the set (three windows, the pointer, the camera, and the end card). Each card shows the app's light running on the film's clock (purple over every meaning, then drawn onto the one picked) and the site's "Picked from context" tip.
- `card.js`: a copy of `site/card.js` drawn at the app's 1:1 size.
- `data.js`: the cards, from `LongyanReader --site-json` for each sentence.

Make it (needs Node with `playwright-core` and Google Chrome; set `PLAYWRIGHT_CORE` to its path if it isn't installed here):

```
python3 -m http.server 8791 --bind 127.0.0.1      # from the repo root
node film/peek.js /tmp/peek 2,6,10                # check a few frames
node film/smooth.js                               # check the camera and pointer for jumps
node film/shoot.js /tmp/frames 4                  # every frame at 2560×1440
swift film/encode.swift /tmp/frames reading-13.mp4 hevc 3000000 60
swift film/encode.swift /tmp/frames reading-13-h264.mp4 h264 5000000 60
```

Give a new film a new file name (browsers cache these), upload it to the `site-media` release, and update `site/index.html` (and its poster, `site/media/reading-N.jpg`, a frame from just after the fade-in).

## The Windows cut

`index.html?os=win` is the same film on a Windows 11 desktop, for the Microsoft Store trailer: Windows title bars, a plain gradient wallpaper, Segoe UI and Microsoft YaHei, the Windows app's light card (its own symbols from `windows/LongyanReader/Icons.cs`) and eye, and an end card. `win.css` and `win.js` hold all of it.

It needs Windows' fonts in `film/fonts/` (not in git): `SegUIVar.ttf segoeui.ttf seguisb.ttf segoeuib.ttf msyh.ttc msyhbd.ttc simsun.ttc SegoeIcons.ttf` from `C:\Windows\Fonts`.

```
FILM_URL='http://127.0.0.1:8791/film/?os=win' node film/shoot.js /tmp/wframes 6 1920
swift film/encode.swift /tmp/wframes trailer.mp4 h264 12000000 60 1920 1080
```
