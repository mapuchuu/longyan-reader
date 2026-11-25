// Installing, played on a computer's screen: for the Mac and for Windows, each its three
// steps one after another, each scene a CSS animation started by a class on the desk ("s0" to
// "s2"). The step it's on is lit in the list beside it, with a bar filling as it plays. It
// plays only while it's on screen, and goes round again. Clicking a step shows that one.
// With motion reduced, nothing plays: each step shows its scene as a still.
//
// The switch under the heading picks the computer: only its download, small print and steps
// show. A download button for one system picks it too (try.js calls LongyanInstall.pick).
(function () {
  "use strict";
  const install = document.getElementById("install");
  if (!install) return;
  const moving = document.documentElement.classList.contains("motion");

  // Each system's scenes: how long each plays, and what moves with it besides the CSS.
  const SYSTEMS = {
    mac: {
      dur: [5600, 5200, 7200],
      // Each app's own menus, as its menu bar shows them.
      menus: [["Finder", "File Edit View Go Window Help"], ["Finder", "File Edit View Go Window Help"], ["Longyan Reader", "Edit Window Help"]],
      // The reading model's download in step 3, under Accessibility.
      download: { step: 2, from: 0.64, text: (gb, left) => `${gb} of 2.7 GB · About ${left} minutes left` },
    },
    win: {
      dur: [5600, 7600, 7600],
      download: { step: 1, from: 0.27, text: (gb, left) => `Downloading: ${gb} of 2.7 GB · About ${left} minutes left` },
    },
  };

  function player(grid, sys) {
    const desk = grid.querySelector(".desk");
    const screen = desk.parentElement;
    const items = [...grid.querySelectorAll(".steps li")];
    const bars = items.map((li) => li.querySelector(".step-bar b"));
    const app = desk.querySelector(".mb-app"), menus = desk.querySelector(".mb-menus");
    const words = desk.querySelector(".ob-progress, .wl-during");
    const fill = desk.querySelector(".ob-bar b, .wl-bar b");
    const { dur, download } = sys;
    let step = 0, elapsed = 0, prev = 0, visible = false, raf = 0;

    // The desk is laid out at a fixed width (760 pixels, 620 on a phone) and scaled to the screen.
    new ResizeObserver(() => { if (desk.offsetWidth) desk.style.setProperty("--k", screen.clientWidth / desk.offsetWidth); }).observe(screen);

    function show(i) {
      step = i; elapsed = 0;
      const base = desk.classList.contains("wdesk") ? "desk wdesk" : "desk";
      desk.className = base;
      void desk.offsetWidth;
      desk.classList.add("s" + i);
      if (!moving) desk.classList.add("still");
      else if (!visible) desk.classList.add("paused");
      if (app) {
        app.textContent = sys.menus[i][0];
        menus.innerHTML = sys.menus[i][1].split(" ").map((m) => `<span>${m}</span>`).join("");
      }
      items.forEach((li, k) => {
        li.classList.toggle("on", k === i);
        li.querySelector("button").setAttribute("aria-pressed", k === i ? "true" : "false");
      });
      bars.forEach((b) => (b.style.transform = "scaleX(0)"));
      paint();
    }

    // The reading model's download: the bar and its words move together.
    function paint() {
      const f = Math.min(1, elapsed / dur[step]);
      bars[step].style.transform = `scaleX(${f})`;
      if (step === download.step && moving) {
        const p = 0.04 + 0.4 * Math.max(0, Math.min(1, (f - download.from) / (1 - download.from)));
        fill.style.transform = `scaleX(${p})`;
        words.textContent = download.text((p * 2.7).toFixed(1), Math.max(2, Math.round(7 * (1 - p))));
      }
    }

    function loop(now) {
      raf = 0;
      if (!visible || document.hidden) return;
      elapsed += Math.min(100, now - prev); prev = now;
      if (elapsed >= dur[step]) show((step + 1) % dur.length);
      else paint();
      raf = requestAnimationFrame(loop);
    }
    function start() {
      desk.classList.remove("paused");
      if (!raf) { prev = performance.now(); raf = requestAnimationFrame(loop); }
    }
    function stop() { desk.classList.add("paused"); cancelAnimationFrame(raf); raf = 0; }

    grid.querySelector(".steps").addEventListener("click", (e) => {
      const b = e.target.closest("button[data-step]");
      if (b) { show(+b.dataset.step); if (moving && visible) start(); }
    });

    show(0);
    if (!moving) return { restart() {} };
    new IntersectionObserver((entries) => {
      visible = entries[0].isIntersecting;
      if (visible) start(); else stop();
    }, { threshold: 0.35 }).observe(screen);
    document.addEventListener("visibilitychange", () => { if (!document.hidden && visible) start(); });
    // Shown again by the switch: from the first step.
    return { restart() { show(0); if (visible) start(); } };
  }

  const players = {};
  install.querySelectorAll(".install-grid[data-for]").forEach((g) => { players[g.dataset.for] = player(g, SYSTEMS[g.dataset.for]); });

  // Positions the Windows pointer reads from the layout rather than from fixed numbers: the
  // welcome window's Download and Done, and the menu's Lookup history, wherever their words
  // put them. In desk pixels, so they hold at any scale.
  const wdesk = install.querySelector(".wdesk");
  function aim() {
    if (!wdesk || !wdesk.offsetWidth) return;
    const k = wdesk.getBoundingClientRect().width / wdesk.offsetWidth;
    const origin = wdesk.querySelector(".layer").getBoundingClientRect();
    const at = (sel, name, dx, dy) => {
      const r = wdesk.querySelector(sel).getBoundingClientRect();
      wdesk.style.setProperty(`--${name}-x`, `${((r.left - origin.left) / k + r.width / k * dx).toFixed(1)}px`);
      wdesk.style.setProperty(`--${name}-y`, `${((r.top - origin.top) / k + r.height / k * dy).toFixed(1)}px`);
    };
    at(".get-btn", "get", 0.62, 0.55);
    at(".wl-download", "dl", 0.66, 0.6);
    at(".wl-done", "dn", 0.64, 0.6);
    at(".m-hist", "hist", 0.34, 0.6);
    at(".tb-chev", "chev", 0.5, 0.5);
    at(".fly-eye", "eye", 0.55, 0.5);
  }

  // Which computer. Remembered on this device, as a convenience only.
  const radios = [...install.querySelectorAll(".os-switch [data-os]")];
  function pick(os, save) {
    if (!SYSTEMS[os]) return;
    const was = install.dataset.os || "mac";
    install.dataset.os = os;
    radios.forEach((b) => { const on = b.dataset.os === os; b.setAttribute("aria-checked", String(on)); b.tabIndex = on ? 0 : -1; });
    if (save) try { localStorage.setItem("ly-os", os); } catch (_) {}
    if (was === os) return;
    install.querySelectorAll(`[data-for="${os}"]`).forEach((el) => {
      el.classList.remove("swapped"); void el.offsetWidth; el.classList.add("swapped");
    });
    install.classList.remove("downloading");
    requestAnimationFrame(() => { aim(); if (players[os]) players[os].restart(); });
  }
  radios.forEach((b) => b.addEventListener("click", () => pick(b.dataset.os, true)));
  // Arrow keys move between the two, as in any radio group.
  install.querySelector(".os-switch").addEventListener("keydown", (e) => {
    if (!/^Arrow(Left|Right|Up|Down)$/.test(e.key)) return;
    e.preventDefault();
    const next = (install.dataset.os || "mac") === "mac" ? "win" : "mac";
    pick(next, true);
    radios.find((b) => b.dataset.os === next).focus();
  });
  let saved = null;
  try { saved = localStorage.getItem("ly-os"); } catch (_) {}
  // A PC opens on Windows unless this device picked the Mac before.
  const onWindows = /Windows/.test(navigator.userAgent) && !/Windows Phone/.test(navigator.userAgent);
  if (saved === "win" || (!saved && onWindows)) pick("win", false);
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(aim);
  window.addEventListener("resize", aim);
  aim();

  window.LongyanInstall = { pick: (os) => pick(os, true) };
})();
