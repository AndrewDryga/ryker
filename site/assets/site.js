/* Five small jobs, and nothing else runs on this site.
   1. The sticky header earns its hairline once the page has moved.
   2. The mobile disclosures close when you pick something out of them.
   3. The "on this page" rail marks the heading you are actually reading.
   4. Code blocks get a copy button.
   5. Docs headings get a link to themselves.
   Everything degrades: with this file absent, the nav still navigates, both
   menus still open as native <details>, the rail is still a list of working
   links, and the code is still selectable — 4 and 5 are built here rather
   than written into the HTML precisely so that a page with no script never
   shows a control that does nothing. */
(function () {
  "use strict";

  /* 1. Header ------------------------------------------------------------ */
  var nav = document.querySelector(".nav");
  if (nav) {
    var stuck = false;
    var sync = function () {
      var next = window.scrollY > 8;
      if (next !== stuck) {
        stuck = next;
        nav.classList.toggle("is-stuck", stuck);
      }
    };
    sync();
    window.addEventListener("scroll", sync, { passive: true });
  }

  /* 2. Disclosures ------------------------------------------------------- */
  var menus = document.querySelectorAll("details.nav-menu, .docs-nav > details");
  Array.prototype.forEach.call(menus, function (menu) {
    menu.addEventListener("click", function (event) {
      var link = event.target.closest ? event.target.closest("a") : null;
      if (link && menu.contains(link)) menu.open = false;
    });
    menu.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && menu.open) {
        menu.open = false;
        var summary = menu.querySelector("summary");
        if (summary) summary.focus();
      }
    });
  });

  /* Close the top menu when the layout stops needing it, so a rotation never
     leaves an open drawer over desktop content. */
  var topMenu = document.querySelector("details.nav-menu");
  if (topMenu) {
    document.addEventListener("pointerdown", function (event) {
      if (topMenu.open && !topMenu.contains(event.target)) topMenu.open = false;
    });
    topMenu.addEventListener("focusout", function (event) {
      if (event.relatedTarget && !topMenu.contains(event.relatedTarget)) topMenu.open = false;
    });
  }
  if (topMenu && window.matchMedia) {
    var wide = window.matchMedia("(min-width: 781px)");
    var onWide = function (event) { if (event.matches) topMenu.open = false; };
    if (wide.addEventListener) wide.addEventListener("change", onWide);
    else if (wide.addListener) wide.addListener(onWide);
  }

  /* 4. Copy buttons ------------------------------------------------------ */
  var canCopy = navigator.clipboard && navigator.clipboard.writeText;
  if (canCopy) {
    Array.prototype.forEach.call(
      document.querySelectorAll(".doc pre, .install pre"),
      function (pre) {
        var wrap = document.createElement("div");
        wrap.className = "copy-wrap";
        pre.parentNode.insertBefore(wrap, pre);

        wrap.appendChild(pre);
        var btn = document.createElement("button");
        btn.type = "button";
        btn.className = "copy";
        var buttonDescription = pre.getAttribute("data-copy-button") || "Copy this code";
        btn.setAttribute("aria-label", buttonDescription);
        btn.title = buttonDescription;
        btn.innerHTML = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><g class="copy-symbol"><rect x="8" y="8" width="12" height="13" rx="2"/><path d="M16 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3"/></g><path class="copy-check" d="m5 12 4 4L19 6"/></svg>';
        wrap.appendChild(btn);

        var status = document.createElement("span");
        status.className = "copy-status vh";
        status.setAttribute("role", "status");
        wrap.appendChild(status);

        var reset;
        btn.addEventListener("click", function () {
          status.textContent = "";
          navigator.clipboard.writeText(pre.textContent.replace(/\s+$/, "")).then(
            function () { say("Code copied.", true); },
            function () {
              var selection = window.getSelection();
              if (selection) {
                var range = document.createRange();
                range.selectNodeContents(pre);
                selection.removeAllRanges();
                selection.addRange(range);
              }
              say(selection ? "Code selected. Use your browser’s Copy command." : "Select the code and use your browser’s Copy command.", false);
            }
          );
        });

        function say(message, ok) {
          btn.setAttribute("aria-label", message);
          btn.title = message;
          status.textContent = message;
          status.classList.toggle("vh", ok);
          btn.classList.toggle("done", ok);
          window.clearTimeout(reset);
          reset = window.setTimeout(function () {
            btn.setAttribute("aria-label", buttonDescription);
            btn.title = buttonDescription;
            status.textContent = "";
            status.classList.add("vh");
            btn.classList.remove("done");
          }, ok ? 1600 : 4000);
        }
      }
    );
  }

  /* 5. Heading anchors --------------------------------------------------- */
  Array.prototype.forEach.call(
    document.querySelectorAll(".doc h2[id], .doc h3[id]"),
    function (heading) {
      var a = document.createElement("a");
      a.className = "anchor";
      a.href = "#" + heading.id;
      a.textContent = "#";
      a.setAttribute("aria-label", "Link to this section");
      heading.appendChild(a);
    }
  );

  /* 3. On this page ------------------------------------------------------ */
  var toc = document.querySelector(".toc");
  if (!toc || !window.IntersectionObserver) return;

  var links = {};
  var targets = [];
  Array.prototype.forEach.call(toc.querySelectorAll("a[href^='#']"), function (link) {
    var id = decodeURIComponent(link.getAttribute("href").slice(1));
    var heading = id && document.getElementById(id);
    if (!heading) return;
    links[id] = link;
    targets.push(heading);
  });
  if (!targets.length) return;

  var seen = Object.create(null);
  var mark = function () {
    var current = null;
    for (var i = 0; i < targets.length; i++) {
      if (seen[targets[i].id]) { current = targets[i].id; break; }
    }
    /* Nothing is on screen: keep the last heading scrolled past, so the rail
       never blanks out in the middle of a long section. */
    if (!current) {
      for (var j = targets.length - 1; j >= 0; j--) {
        if (targets[j].getBoundingClientRect().top < 120) { current = targets[j].id; break; }
      }
    }
    for (var id in links) links[id].classList.toggle("on", id === current);
  };

  var observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) { seen[entry.target.id] = entry.isIntersecting; });
    mark();
  }, { rootMargin: "-88px 0px -60% 0px", threshold: 0 });

  targets.forEach(function (heading) { observer.observe(heading); });
  mark();
})();
