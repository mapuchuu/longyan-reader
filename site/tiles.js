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
