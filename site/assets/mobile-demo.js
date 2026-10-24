/* A compact preview on small screens; the existing conversation opens in a
   viewport-sized player. Moving the original nodes keeps one timeline/card. */
(function () {
  "use strict";
  if (!window.HTMLDialogElement || !window.HTMLDialogElement.prototype.showModal || !window.matchMedia || !window.requestAnimationFrame) return;
  var compact = window.matchMedia("(max-width: 959px)");
  var demos = Array.from(document.querySelectorAll(".product-demo, .everyday-demo"));
  var dialog = document.createElement("dialog");
  dialog.className = "demo-player";
  dialog.setAttribute("aria-labelledby", "demo-player-title");
  dialog.innerHTML = '<header class="demo-player-heading"><h2 id="demo-player-title"></h2><button type="button" class="demo-player-close" aria-label="Close example" autofocus><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><path d="m6 6 12 12M18 6 6 18"/></svg></button></header>';
  document.body.appendChild(dialog);
  var title = dialog.querySelector("h2");
  var close = dialog.querySelector("button");
  var active = null;
  var slot = null;
  var opener = null;

  function notify(demo, reset) {
    demo.dispatchEvent(new CustomEvent("demomodechange", { detail: { reset: Boolean(reset) } }));
  }
  function restore() {
    if (!active) return;
    var demo = active;
    active = null;
    slot.replaceWith(demo);
    document.documentElement.classList.remove("demo-player-open");
    document.body.classList.remove("demo-player-open");
    demo.dataset.mobileState = compact.matches ? "preview" : "";
    demo.querySelector(".demo-viewport").inert = compact.matches;
    notify(demo, true);
    if (compact.matches) opener.focus({ preventScroll: true });
  }
  close.addEventListener("click", function () { dialog.close(); });
  dialog.addEventListener("close", restore);
  window.addEventListener("beforeprint", function () { if (active) { dialog.close(); restore(); } });

  demos.forEach(function (demo) {
    var button = document.createElement("button");
    var label = demo.dataset.demoTitle;
    button.type = "button";
    button.className = "demo-watch";
    button.setAttribute("aria-label", "Watch it happen: " + label);
    button.setAttribute("aria-haspopup", "dialog");
    button.innerHTML = '<span class="demo-watch-icon" aria-hidden="true"><svg width="18" height="18" viewBox="0 0 24 24"><path d="M8 5v14l11-7Z" fill="currentColor"/></svg></span><span>Watch it happen</span><span class="demo-watch-length">' + Math.floor(Number(demo.dataset.duration) / 60) + ':' + String(Number(demo.dataset.duration) % 60).padStart(2, "0") + '</span>';
    demo.appendChild(button);
    button.addEventListener("click", function () {
      if (!compact.matches || active) return;
      active = demo;
      opener = button;
      slot = document.createElement("div");
      slot.className = demo.className + " demo-slot";
      slot.style.height = demo.offsetHeight + "px";
      demo.parentNode.insertBefore(slot, demo);
      title.textContent = label;
      dialog.appendChild(demo);
      demo.dataset.mobileState = "playing";
      demo.querySelector(".demo-viewport").inert = false;
      document.documentElement.classList.add("demo-player-open");
      document.body.classList.add("demo-player-open");
      dialog.showModal();
      close.focus({ preventScroll: true });
      notify(demo, false);
    });
  });

  function configure() {
    if (!compact.matches && active) { dialog.close(); restore(); }
    demos.forEach(function (demo) {
      if (demo === active) return;
      demo.dataset.mobileState = compact.matches ? "preview" : "";
      demo.querySelector(".demo-viewport").inert = compact.matches;
      notify(demo, compact.matches);
    });
  }
  compact.addEventListener("change", configure);
  configure();
})();
