/* These examples are ordinary readable HTML first. Only the visible example
   plays, once; offscreen and background tabs never consume its reading time. */
(function () {
  "use strict";
  if (!window.matchMedia || !window.requestAnimationFrame) return;
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)");

  // Without JavaScript these are links to complete, readable examples.
  // With it, one example occupies the same space and the arrow keys switch it.
  document.querySelectorAll("[data-example-picker]").forEach(function (picker) {
    var tabs = Array.from(picker.querySelectorAll(".example-tabs a"));
    var panels = tabs.map(function (tab) { return document.getElementById(tab.hash.slice(1)); });
    var selected = 0;
    picker.querySelector(".example-tabs").setAttribute("role", "tablist");
    tabs.forEach(function (tab, i) {
      tab.setAttribute("role", "tab");
      tab.setAttribute("aria-controls", panels[i].id);
      panels[i].setAttribute("role", "tabpanel");
      panels[i].setAttribute("aria-labelledby", tab.id);
      panels[i].tabIndex = 0;
    });
    function select(index, focus, updateURL) {
      selected = index;
      tabs.forEach(function (tab, i) {
        tab.setAttribute("aria-selected", i === index ? "true" : "false");
        tab.tabIndex = i === index ? 0 : -1;
        panels[i].hidden = i !== index;
      });
      if (focus) tabs[index].focus();
      if (updateURL && window.history && window.history.replaceState) {
        window.history.replaceState(window.history.state, "", tabs[index].hash);
      }
      document.dispatchEvent(new Event("examplechange"));
    }
    function fromHash() {
      var target = document.getElementById(window.location.hash.slice(1));
      var index = panels.findIndex(function (panel) { return target && panel.contains(target); });
      if (index >= 0) select(index, false);
    }
    tabs.forEach(function (tab, i) {
      tab.addEventListener("click", function (event) {
        if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        event.preventDefault();
        select(i, false, true);
      });
      tab.addEventListener("keydown", function (event) {
        var index = event.key === "ArrowRight" ? (i + 1) % tabs.length : event.key === "ArrowLeft" ? (i + tabs.length - 1) % tabs.length : event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1 : null;
        if (index !== null) { event.preventDefault(); select(index, true, true); }
      });
    });
    window.addEventListener("hashchange", fromHash);
    window.addEventListener("beforeprint", function () { panels.forEach(function (panel) { panel.hidden = false; }); });
    window.addEventListener("afterprint", function () { select(selected, false); });
    select(0, false);
    fromHash();
  });

  document.querySelectorAll(".everyday-demo").forEach(function (demo) {
    var duration = Number(demo.dataset.duration);
    var name = demo.dataset.demoName;
    var pane = demo.querySelector(".slack-scroll");
    var controls = demo.querySelector(".demo-controls");
    var play = demo.querySelector(".playback-toggle");
    var chapters = Array.from(demo.querySelectorAll("[data-seek]"));
    var events = Array.from(demo.querySelectorAll("[data-moment]")).map(function (node) {
      return { node: node, from: Number(node.dataset.moment), until: node.hasAttribute("data-until") ? Number(node.dataset.until) : Infinity, sceneUntil: node.hasAttribute("data-scene-until") ? Number(node.dataset.sceneUntil) : Infinity, update: Boolean(node.closest("[data-live-card]")) };
    });
    var presence = demo.querySelector("[data-working]");
    var workingRanges = (presence ? presence.dataset.working.split(",") : []).map(function (range) {
      return range.split(":").map(Number);
    });
    var time = 0;
    var frame = 0;
    var previous = 0;
    var lastPaint = 0;
    var paused = false;
    var printing = false;
    var visible = !window.IntersectionObserver;

    function animated() { return !reduced.matches && !printing; }
    function render(instant) {
      var enabled = animated();
      var t = enabled ? time : duration;
      var arrived = false;
      events.forEach(function (event) {
        var hidden = t < event.from || t >= event.until || (enabled && t >= event.sceneUntil);
        if (instant || paused || !enabled) event.node.classList.remove("is-arriving");
        if (event.node.hidden !== hidden) {
          event.node.classList.toggle("is-arriving", !event.update && !hidden && enabled && !instant && !paused);
          event.node.hidden = hidden;
          arrived = arrived || (!event.update && !hidden && !event.node.closest("[hidden]"));
        }
      });
      demo.classList.toggle("is-paused", paused || !visible || document.hidden);
      var working = enabled && workingRanges.some(function (range) { return t >= range[0] && t < range[1]; });
      arrived = arrived || (working && !demo.classList.contains("is-working"));
      demo.classList.toggle("is-working", working);
      chapters.forEach(function (button, i) {
        var from = Number(button.dataset.seek);
        var until = chapters[i + 1] ? Number(chapters[i + 1].dataset.seek) : duration;
        button.style.setProperty("--progress", Math.min(1, Math.max(0, (t - from) / (until - from))));
        if (t >= from && (t < until || i === chapters.length - 1)) button.setAttribute("aria-current", "step");
        else button.removeAttribute("aria-current");
      });
      var done = time >= duration;
      play.setAttribute("data-playback-state", done ? "replay" : paused ? "play" : "pause");
      play.setAttribute("aria-label", (done ? "Replay " : paused ? "Play " : "Pause ") + name + " animation");
      play.title = play.getAttribute("aria-label");
      if (enabled && (arrived || instant)) {
        // Follow new messages and explicit seeks. Editing an existing card
        // keeps the reader's place, even when a newer reply is below it.
        var latest = events.filter(function (event) { return !event.node.closest("[hidden]"); })
          .reduce(function (last, event) { return !last || event.from >= last.from ? event : last; }, null);
        var card = latest && latest.node.closest("[data-live-card]");
        var showRequest = latest && (latest.node.dataset.cardState || "").endsWith("-planning");
        var cardFocus = card && (!showRequest && latest.node.querySelector(".task-stages") || card.closest(".chat-message"));
        var top = cardFocus ? pane.scrollTop + cardFocus.getBoundingClientRect().top - pane.getBoundingClientRect().top - 36 : pane.scrollHeight;
        pane.scrollTo({ top: top, behavior: instant ? "instant" : "smooth" });
      }
    }

    function stop() {
      if (frame) window.cancelAnimationFrame(frame);
      frame = 0;
      previous = 0;
    }
    function canPlay() { return animated() && !paused && visible && !document.hidden && !demo.closest("[hidden]") && time < duration; }
    function tick(now) {
      frame = 0;
      if (!canPlay()) { previous = 0; return; }
      if (previous) time = Math.min(duration, time + Math.min((now - previous) / 1000, .1));
      previous = now;
      if (now - lastPaint >= 32 || time >= duration) { render(false); lastPaint = now; }
      if (canPlay()) frame = window.requestAnimationFrame(tick);
    }
    function run() { if (!frame && canPlay()) frame = window.requestAnimationFrame(tick); }
    function seek(value) { stop(); time = value; render(true); run(); }
    function configure() {
      stop();
      demo.classList.toggle("is-animated", animated());
      controls.hidden = reduced.matches || printing;
      render(true);
      run();
    }
    function pauseForReading() { paused = true; stop(); render(false); }

    play.addEventListener("click", function () {
      if (time >= duration) { paused = false; seek(0); }
      else { paused = !paused; stop(); render(false); run(); }
    });
    chapters.forEach(function (button) { button.addEventListener("click", function () { seek(Number(button.dataset.seek)); }); });
    pane.addEventListener("focus", pauseForReading);
    pane.addEventListener("wheel", pauseForReading, { passive: true });
    pane.addEventListener("touchstart", pauseForReading, { passive: true });
    pane.addEventListener("keydown", function (event) {
      if (["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End"].includes(event.key)) pauseForReading();
    });
    document.addEventListener("visibilitychange", function () { stop(); render(false); run(); });
    document.addEventListener("examplechange", function () { stop(); render(false); run(); });
    window.addEventListener("beforeprint", function () { printing = true; configure(); });
    window.addEventListener("afterprint", function () { printing = false; configure(); });
    reduced.addEventListener("change", configure);
    if (window.IntersectionObserver) {
      new IntersectionObserver(function (entries) {
        visible = entries[0].isIntersecting && entries[0].intersectionRatio >= .4;
        stop(); render(false); run();
      }, { threshold: [0, .4] }).observe(demo.querySelector(".demo-viewport"));
    }
    configure();
  });
})();
