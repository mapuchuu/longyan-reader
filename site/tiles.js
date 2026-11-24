// The tones tile's mesh: one light behind each column of the panel, wherever the tile's
// width puts the columns.
(function () {
  "use strict";
  const box = document.querySelector(".stage-tones"), cols = box && box.querySelectorAll(".ui-tones > div");
  const mesh = box && box.querySelector(".tone-mesh");
  if (!mesh || !cols || cols.length < 4) return;
  function place() {
    const b = box.getBoundingClientRect();
    if (!b.width) return;
    cols.forEach((c, i) => { const r = c.getBoundingClientRect(); mesh.style.setProperty(`--x${i + 1}`, ((r.left + r.right) / 2 - b.left).toFixed(1) + "px"); });
  }
  new ResizeObserver(place).observe(box);
  place();
})();

// The feature tiles' one scripted motion: in History a new word arrives on top every few
// seconds while the tile is on screen (motion.js marks it "live"). The rest is CSS.
(function () {
  "use strict";
  if (!document.documentElement.classList.contains("motion")) return;
  const box = document.querySelector(".stage-history");
  const rows = box && box.querySelector(".history-rows");
  if (!rows) return;
  setInterval(() => {
    if (!box.classList.contains("live") || document.hidden) return;
    const row = rows.lastElementChild;
    row.classList.remove("arrive");
    row.style.setProperty("--h", rows.firstElementChild.offsetHeight + "px");
    rows.prepend(row);
    void row.offsetWidth;
    row.classList.add("arrive");
  }, 2800);
})();

// The notes tile's field: rows of everyday phrases with their word-for-word English struck
// through, each row twice over so it can drift without a seam.
(() => {
  const field = document.querySelector(".glosses");
  if (!field) return;
  const P = [["吃醋", "eat vinegar"], ["躺平", "lie flat"], ["加油", "add oil"], ["摸鱼", "touch fish"], ["吃瓜", "eat melon"],
    ["打酱油", "beat soy sauce"], ["马马虎虎", "horse horse tiger tiger"], ["泼冷水", "pour cold water"], ["穿小鞋", "wear small shoes"],
    ["内卷", "involution"], ["面子", "face"], ["吃苦", "eat bitterness"], ["黑历史", "black history"], ["小鲜肉", "small fresh meat"],
    ["水军", "water army"], ["吃软饭", "eat soft rice"], ["关系", "relationship"], ["开夜车", "drive the night car"]];
  const rows = 11;
  for (let r = 0; r < rows; r++) {
    const pick = P.map((_, i) => P[(i * 7 + r * 5) % P.length]);
    const html = pick.map(([zh, en]) => `<i><b>${zh}</b><s>${en}</s></i>`).join("");
    const row = document.createElement("div");
    row.className = "gl-row";
    row.innerHTML = `<span>${html}${html}</span>`;
    row.style.setProperty("--gl-t", 90 + ((r * 37) % 50) + "s");
    row.style.marginLeft = -((r * 113) % 300) + "px";
    field.append(row);
  }
})();
