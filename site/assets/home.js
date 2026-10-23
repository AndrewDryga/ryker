/* A single, deterministic timeline: messages accumulate in Slack, a draft opens
   over that same thread, and the result comes back. No network or app actions. */
(function () {
  "use strict";

  var story = document.querySelector(".work-story");
  var demo = document.querySelector(".product-demo");
  if (!story || !demo || !window.matchMedia || !window.requestAnimationFrame) return;

  var duration = 82;
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
  var roomy = window.matchMedia("(min-width: 960px) and (min-height: 760px)");
  var controls = demo.querySelector(".demo-controls");
  var seekButtons = Array.from(demo.querySelectorAll("[data-seek]"));
  var starts = seekButtons.map(function (button) { return Number(button.dataset.seek); });
  var events = Array.from(demo.querySelectorAll("[data-at]")).map(function (node) {
    return { node: node, at: Number(node.dataset.at), until: node.hasAttribute("data-until") ? Number(node.dataset.until) : Infinity, update: Boolean(node.closest("[data-live-card]")) };
  });
  var checks = Array.from(demo.querySelectorAll("[data-check-at]"));
  var slack = demo.querySelector(".slack-window");
  var github = demo.querySelector(".github-window");
  var slackScroll = demo.querySelector(".slack-scroll");
  var prScroll = demo.querySelector(".pr-scroll");
  var composer = demo.querySelector(".composer-copy");
  var play = demo.querySelector(".playback-toggle");
  var checkSummary = demo.querySelector(".checks-summary");
  var checkCount = demo.querySelector(".checks-count");
  var prState = demo.querySelector(".pr-state");
  var prAuthor = demo.querySelector(".pr-author");
  var mergeDescription = demo.querySelector(".merge-description");
  var filesTab = demo.querySelector(".files-tab");
  var conversationTab = demo.querySelector(".conversation-tab");
  var drafts = [
    { from: 11, to: 13, text: demo.querySelector('[data-at="13"] div > p:last-child').textContent }
  ];
  var time = 0;
  var frame = 0;
  var previous = 0;
  var paused = false;
  var printing = false;
  var visible = true;
  var seekTimer = 0;
  var lastPaint = -1;

  function setText(node, value) {
    if (node.textContent !== value) node.textContent = value;
  }

  function isAnimated() { return !reduced.matches && !printing; }

  function fit() {
    var height = demo.offsetHeight;
    demo.style.setProperty("--demo-height", height + "px");
    story.classList.toggle("is-pinned", isAnimated() && roomy.matches && height <= window.innerHeight - 112);
  }

  function scrollToLatest(instant, followSlack, followPR) {
    // The page never scrolls itself. Only the two example app windows follow
    // new messages; wheel/touch interaction pauses playback for reading.
    if (followSlack) {
      var latest = events.filter(function (event) { return slack.contains(event.node) && !event.node.closest("[hidden]"); })
        .reduce(function (last, event) { return !last || event.at >= last.at ? event : last; }, null);
      var card = latest && latest.node.closest("[data-live-card]");
      var showRequest = latest && (latest.node.dataset.cardState || "").endsWith("-planning");
      var cardFocus = card && (!showRequest && latest.node.querySelector(".task-stages") || card.closest(".chat-message"));
      var top = cardFocus ? slackScroll.scrollTop + cardFocus.getBoundingClientRect().top - slackScroll.getBoundingClientRect().top - 36 : slackScroll.scrollHeight;
      slackScroll.scrollTo({ top: top, behavior: instant ? "instant" : "smooth" });
    }
    if (followPR) prScroll.scrollTo({ top: prScroll.scrollHeight, behavior: instant ? "instant" : "smooth" });
  }

  function render(instant) {
    var animated = isAnimated();
    var t = animated ? time : duration;
    var filesVisible = t < 47.5 || (t >= 59 && t < 63);
    var slackArrived = false;
    var prArrived = false;
    events.forEach(function (event) {
      var view = event.node.dataset.prView;
      var hidden = t < event.at || t >= event.until ||
        (animated && Boolean(view) && (view === "files" ? !filesVisible : filesVisible));
      if (instant || paused || !animated) event.node.classList.remove("is-arriving");
      if (event.node.hidden !== hidden) {
        // A live card edits the existing message; only new content arrives.
        event.node.classList.toggle("is-arriving", !event.update && !hidden && animated && !instant && !paused);
        event.node.hidden = hidden;
        if (!event.update && !hidden && !event.node.closest("[hidden]")) {
          slackArrived = slackArrived || slack.contains(event.node);
          prArrived = prArrived || github.contains(event.node);
        }
      }
    });

    var prOpen = animated && t >= 41 && t < 77;
    demo.classList.toggle("is-pr-open", prOpen);
    github.inert = animated && !prOpen;
    slack.inert = prOpen;
    github.setAttribute("aria-hidden", animated && !prOpen ? "true" : "false");
    slack.setAttribute("aria-hidden", prOpen ? "true" : "false");
    demo.classList.toggle("checks-done", t >= 65);
    demo.classList.toggle("checks-failed", t >= 51 && t < 60);
    demo.classList.toggle("is-paused", paused || !visible || document.hidden);

    var completed = 0;
    checks.forEach(function (check) {
      var failed = check.hasAttribute("data-fail-at") && t >= Number(check.dataset.failAt) && t < 60;
      var done = t >= Number(t >= 60 ? check.dataset.recheckAt : check.dataset.checkAt);
      if (done) completed += 1;
      check.classList.toggle("is-pending", !done && !failed);
      check.classList.toggle("is-failed", failed);
      setText(check.querySelector(".check-mark"), failed ? "×" : "✓");
      setText(check.querySelector(".check-result"), failed ? "Failed" : done ? "Passed" : "Running");
    });
    setText(checkSummary, t >= 51 && t < 60 ? "One check failed" : completed === checks.length ? "All checks passed" : t >= 60 ? "Checking the updated change…" : "Checks are running…");
    setText(checkCount, completed + " / " + checks.length);
    prState.classList.toggle("is-merged", t >= 75);
    prState.classList.toggle("is-open", t >= 72 && t < 75);
    setText(prState.querySelector(".pr-state-label"), t >= 75 ? "Merged" : t >= 72 ? "Open" : "Draft");
    setText(prAuthor, t >= 75 ? "You" : "Ryker");
    setText(mergeDescription, t >= 75 ? "merged into" : "wants to merge into");
    setText(filesTab.querySelector("i"), t >= 59 ? "3" : "2");
    setText(demo.querySelector(".diff-totals"), t >= 59 ? "+7 −1" : "+3 −1");
    filesTab.classList.toggle("is-selected", filesVisible);
    conversationTab.classList.toggle("is-selected", !filesVisible);
    setText(demo.querySelector(".commits-tab i"), t >= 60 ? "2" : "1");

    var draft = drafts.find(function (item) { return t >= item.from && t < item.to; });
    demo.classList.toggle("is-composing", Boolean(draft));
    setText(composer, draft ? draft.text.slice(0, Math.ceil((t - draft.from) / (draft.to - draft.from) * draft.text.length)) : "Reply…");
    var working = animated && ((t >= 1.2 && t < 6) || (t >= 13.5 && t < 15) || (t >= 77 && t < 78));
    slackArrived = slackArrived || (working && !demo.classList.contains("is-working"));
    demo.classList.toggle("is-working", working);
    seekButtons.forEach(function (button, i) {
      var end = starts[i + 1] || duration;
      button.style.setProperty("--progress", Math.min(1, Math.max(0, (t - starts[i]) / (end - starts[i]))));
      if (t >= starts[i] && (t < end || i === starts.length - 1)) button.setAttribute("aria-current", "step");
      else button.removeAttribute("aria-current");
    });
    var stopped = paused || time >= duration;
    setText(play.querySelector(".playback-icon"), time >= duration ? "↺" : stopped ? "▷" : "Ⅱ");
    play.setAttribute("aria-label", time >= duration ? "Play animation again" : stopped ? "Play animation" : "Pause animation");
    play.title = play.getAttribute("aria-label");
    if (animated && (slackArrived || prArrived || instant)) scrollToLatest(instant, slackArrived || instant, prArrived || instant);
  }

  function stopFrame() {
    if (frame) window.cancelAnimationFrame(frame);
    frame = 0;
    previous = 0;
  }

  function tick(now) {
    frame = 0;
    if (!isAnimated() || paused || !visible || document.hidden || time >= duration) { previous = 0; return; }
    if (previous) time = Math.min(duration, time + Math.min((now - previous) / 1000, .1));
    previous = now;
    // Thirty paints per second is enough for the progress bars and composing
    // text; content changes only when the timeline crosses an event boundary.
    if (now - lastPaint >= 32 || time >= duration) { render(false); lastPaint = now; }
    if (time < duration) frame = window.requestAnimationFrame(tick);
  }

  function run() {
    if (!frame && isAnimated() && !paused && visible && !document.hidden && time < duration) frame = window.requestAnimationFrame(tick);
  }

  function seek(value) {
    stopFrame();
    demo.classList.add("is-seeking");
    window.clearTimeout(seekTimer);
    time = value;
    render(true);
    seekTimer = window.setTimeout(function () { demo.classList.remove("is-seeking"); }, 80);
    run();
  }

  function configure() {
    stopFrame();
    demo.classList.add("is-seeking");
    window.clearTimeout(seekTimer);
    demo.classList.toggle("is-animated", isAnimated());
    controls.hidden = reduced.matches || printing;
    render(true);
    fit();
    seekTimer = window.setTimeout(function () { demo.classList.remove("is-seeking"); }, 80);
    run();
  }

  play.addEventListener("click", function () {
    if (time >= duration) { paused = false; seek(0); }
    else { paused = !paused; stopFrame(); render(false); run(); }
  });
  seekButtons.forEach(function (button) {
    button.addEventListener("click", function () { seek(Number(button.dataset.seek)); });
  });
  [slackScroll, prScroll].forEach(function (pane) {
    function pauseForReading() { paused = true; stopFrame(); render(false); }
    pane.addEventListener("focus", pauseForReading);
    pane.addEventListener("wheel", pauseForReading, { passive: true });
    pane.addEventListener("touchstart", pauseForReading, { passive: true });
    pane.addEventListener("keydown", function (event) {
      if (["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End"].includes(event.key)) pauseForReading();
    });
  });
  // Playback follows the viewer's controls. Page scrolling never seeks or
  // rewinds the conversation while they are reading the surrounding story.
  window.addEventListener("resize", fit, { passive: true });
  document.addEventListener("visibilitychange", function () { stopFrame(); render(false); run(); });
  window.addEventListener("beforeprint", function () { printing = true; configure(); });
  window.addEventListener("afterprint", function () { printing = false; configure(); });
  reduced.addEventListener("change", configure);
  roomy.addEventListener("change", fit);
  if (document.fonts) document.fonts.ready.then(fit);
  if (window.ResizeObserver) new ResizeObserver(fit).observe(demo);
  if (window.IntersectionObserver) {
    new IntersectionObserver(function (entries) {
      visible = entries[0].isIntersecting;
      stopFrame();
      render(false);
      run();
    }, { threshold: 0 }).observe(demo.querySelector(".demo-viewport"));
  }
  configure();
})();
