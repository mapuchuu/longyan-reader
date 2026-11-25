// The film's Windows cut (index.html?os=win): the same shot on a Windows 11 desktop, for the
// Microsoft Store trailer. Loaded before card.js and film.js. It gives the card the Windows
// app's own symbols (windows/LongyanReader/Icons.cs, drawn as the same strokes), swaps the
// Mac title bars for Windows ones, and film.js reads window.FILM_WIN for the eye, the pointer
// and the selection. The look is in win.css.
(() => {
  window.FILM_WIN = true;
  document.documentElement.classList.add("os-win");

  // Icons.cs: each symbol in its own box (points), strokes at its widths, round caps and joins.
  const icon = (w, h, body, cls = "") =>
    `<svg class="lc-sym lw ${cls}" viewBox="0 0 ${w} ${h}" style="width:${w}px;height:${h}px" aria-hidden="true">${body}</svg>`;
  const s = (d, w, extra = "") => `<path d="${d}" stroke-width="${w}"${extra}/>`;
  const f = (d) => `<path class="lc-fill" d="${d}"/>`;
  const PIN = "M 5.6,1.65 C 5.6,2.5 5.75,3.3 5.75,4.1 V 6.3 C 4.0,6.9 2.9,7.9 2.9,9.2 H 11.0 C 11.0,7.9 9.9,6.9 8.15,6.3 V 4.1 C 8.15,3.3 8.3,2.5 8.3,1.65 Z";
  const LAND = "M -1,-1 H 9.3 L 9.3,2.2 C 9.3,3.0 8.8,3.8 8.0,4.2 C 7.5,4.4 7.0,4.3 6.8,4.7 C 6.6,5.2 7.4,5.4 7.1,6.1 C 6.8,6.7 6.1,6.7 5.8,7.2 C 5.6,7.6 5.7,8.3 5.2,8.6 C 4.8,8.7 4.6,8.2 4.4,7.8 C 4.2,7.3 3.8,7.1 3.4,7.3 C 3.0,7.5 2.9,8.3 2.5,8.8 C 2.2,9.2 1.8,9.4 1.5,9.5 L -1,10.5 Z";
  const AUS = "M 6.9,10.8 C 6.5,9.9 6.8,9.1 7.7,8.8 C 8.3,8.7 8.6,8.2 9.3,8.1 C 10.0,8.0 10.4,8.4 10.8,8.3 L 12.5,7.6 L 12.5,9.4 C 11.6,9.9 10.9,10.4 10.2,10.8 C 9.5,11.1 8.8,10.8 8.2,11.1 C 7.6,11.3 7.1,11.2 6.9,10.8 Z";
  const BUBBLE_B = "M 10.4,4.2 H 16.31 A 2,2 0 0 1 18.31,6.2 V 9.0 A 2,2 0 0 1 16.31,11.0 H 16.3 V 13.1 L 14.0,11.0 H 10.4 A 2,2 0 0 1 8.4,9.0 V 6.2 A 2,2 0 0 1 10.4,4.2 Z";
  window.LC_SYM = {
    speaker: icon(17.25, 12.62,
      s("M 2.4,4.3 H 4.4 L 7.2,1.65 V 10.97 L 4.4,8.3 H 2.4 Z", 1.15) +
      s("M 9.8,4.3 A 2.37,2.37 0 0 1 9.8,8.3", 1.15, ' class="lc-wave lc-w1"') + s("M 12.9,2.3 A 5.16,5.16 0 0 1 12.9,10.3", 1.15, ' class="lc-wave lc-w2"')),
    copy: icon(15.19, 17.06, s("M 3.25,5.0 H 7.3 L 10.0,7.7 V 14.25 A 1.2,1.2 0 0 1 8.8,15.45 H 3.25 A 1.2,1.2 0 0 1 2.05,14.25 V 6.2 A 1.2,1.2 0 0 1 3.25,5.0 Z M 7.3,5.15 V 7.7 H 9.85 M 5.2,4.6 V 2.8 A 1.2,1.2 0 0 1 6.4,1.6 H 10.4 L 13.14,4.35 V 10.3 A 1.2,1.2 0 0 1 11.94,11.5 H 10.6 M 10.4,1.75 V 4.35 H 13.0", 1.1)),
    check: icon(13.56, 12.44, s("M 2.4,6.9 L 5.3,10.4 L 11.2,1.95", 1.75)),
    chevronRight: icon(7.56, 10.56, s("M 2.55,1.55 L 6.33,5.29 L 2.55,9.02", 1.35)),
    chevronDown: icon(11.31, 6.88, s("M 1.93,1.55 L 5.65,5.33 L 9.38,1.55", 1.35)),
    bubble: icon(14.62, 12.62, s("M 3.88,1.25 H 10.75 A 2,2 0 0 1 12.75,3.25 V 6.9 A 2,2 0 0 1 10.75,8.9 H 6.2 L 3.9,11.3 V 8.9 H 3.88 A 2,2 0 0 1 1.88,6.9 V 3.25 A 2,2 0 0 1 3.88,1.25 Z", 1.0) + s("M 4.4,3.6 H 10.2 M 4.4,5.1 H 10.2 M 4.4,6.6 H 8.4", 0.85)),
    pin: icon(13.94, 16.06, s(PIN, 1.15) + s("M 3.9,1.65 H 10.0 M 6.95,9.2 V 14.4", 1.15)),
    pinFill: icon(13.94, 16.06, f(PIN) + s(PIN, 1.15) + s("M 3.9,1.65 H 10.0 M 6.95,9.2 V 14.4", 1.15)),
    xmark: icon(8.5, 8, s("M 1.65,1.4 L 6.85,6.6 M 6.85,1.4 L 1.65,6.6", 1.3)),
    uturn: icon(14.12, 12.56, s("M 5.0,1.41 L 2.1,4.3 L 5.0,7.19 M 2.1,4.3 H 8.6 A 3.42,3.42 0 0 1 8.6,11.15 H 7.0", 1.2)),
    // Cultural context: a ring, Asia and Australia filled inside it, the sea open.
    globe: icon(13.12, 13.12,
      `<defs><clipPath id="lw-earth"><circle cx="6.56" cy="6.56" r="4.77"/></clipPath></defs>` +
      `<circle cx="6.56" cy="6.56" r="5.12" stroke-width="1"/>` +
      `<g clip-path="url(#lw-earth)">${f(LAND)}${s("M 10.0,4.0 C 9.8,4.7 9.4,5.2 8.7,5.5", 0.75)}${s("M 3.6,9.6 L 4.6,9.9", 0.7)}<ellipse class="lc-fill" cx="6.35" cy="8.5" rx="0.45" ry="0.52"/>${f(AUS)}</g>`, "lc-globe"),
    // Lost in translation: a bubble with an A behind a filled one with 文.
    translate: icon(20.25, 14.44,
      `<defs><mask id="lw-tr-back"><rect width="21" height="15" fill="#fff" stroke="none"/><path d="${BUBBLE_B}" stroke="#000" stroke-width="2.4" fill="#000"/></mask>` +
      `<mask id="lw-tr-front"><rect width="21" height="15" fill="#000" stroke="none"/><path d="${BUBBLE_B}" fill="#fff" stroke="#fff" stroke-width=".5"/><path d="M 13.2,5.15 L 13.5,5.8 M 11.05,6.55 H 15.75 M 11.85,6.6 C 12.4,8.55 13.6,9.65 15.65,10.05 M 14.95,6.6 C 14.4,8.55 13.2,9.65 11.15,10.05" stroke="#000" stroke-width=".9" fill="none" stroke-linecap="round"/></mask></defs>` +
      `<g mask="url(#lw-tr-back)">${s("M 3.88,1.44 H 9.4 A 2,2 0 0 1 11.4,3.44 V 6.4 A 2,2 0 0 1 9.4,8.4 H 6.1 L 3.7,10.6 V 8.4 A 2,2 0 0 1 1.88,6.4 V 3.44 A 2,2 0 0 1 3.88,1.44 Z", 1.0)}${s("M 4.0,7.0 L 5.4,3.1 L 6.8,7.0 M 4.5,5.75 H 6.3", 0.95)}</g>` +
      `<rect class="lc-fill" width="21" height="15" mask="url(#lw-tr-front)"/>`, "lc-translate"),
  };

  // Windows 11 caption buttons (Segoe Fluent Icons: ChromeMinimize, ChromeMaximize, ChromeClose).
  const CAPS = `<span class="caps"><b>&#xE921;</b><b>&#xE922;</b><b>&#xE8BB;</b></span>`;
  const G = (c) => `<i class="fl">${c}</i>`;
  document.addEventListener("DOMContentLoaded", () => {
    const bar = (id) => document.querySelector(`${id} .bar`);
    // A browser: one tab in the title bar, the toolbar under it.
    bar("#w-a").innerHTML =
      `<div class="tabs"><span class="tab"><i class="fav"></i><span>夏天为什么容易上火？</span>${G("&#xE8BB;")}</span>${G("&#xE710;")}</div>${CAPS}` +
      `<div class="tool">${G("&#xE72B;")}${G("&#xE72A;")}${G("&#xE72C;")}<span class="addr">${G("&#xE72E;")}<span>example.com/health/summer</span></span>${G("&#xE712;")}</div>`;
    // Mail: the app's title bar.
    bar("#w-b").innerHTML = `<span class="ttl"><i class="app mailapp">${G("&#xE715;")}</i>收件箱 - 邮件</span>${CAPS}`;
    // A PDF reader: title bar, then a toolbar with the page.
    bar("#w-c").innerHTML = `<span class="ttl"><i class="app pdfapp">${G("&#xE8A5;")}</i>短篇小说选.pdf</span>${CAPS}` +
      `<div class="tool">${G("&#xE700;")}<span class="page"><span class="box">36</span>/ 212</span><span class="sp"></span>${G("&#xE738;")}<span class="zoom">100%</span>${G("&#xE710;")}${G("&#xE8A1;")}${G("&#xE712;")}</div>`;
    // Windows' own pointer and text-select cursor.
    document.querySelector("#cursor .arrow").innerHTML =
      `<path d="M8.2 4.1v16.6l3.9-3.7 2.5 5.8 2.3-1-2.4-5.6h5.3z" fill="#fff" stroke="#000" stroke-width="1.1" stroke-linejoin="round"/>`;
    document.querySelector("#cursor .ibeam").innerHTML =
      `<path d="M11 5.2h6M14 5.2v17.6M11 22.8h6M12.2 14h3.6" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round"/>` +
      `<path d="M11 5.2h6M14 5.2v17.6M11 22.8h6" fill="none" stroke="#000" stroke-width="1.2" stroke-linecap="round"/>`;
    // The wallpaper: our own soft gradient, under the windows.
    const wall = document.querySelector(".wall");
    const div = document.createElement("div"); div.className = "wwall"; wall.replaceWith(div);
  });
})();
