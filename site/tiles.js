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
