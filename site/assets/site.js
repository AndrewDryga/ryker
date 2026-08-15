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
        btn.textContent = "Copy";
        btn.setAttribute("aria-label", "Copy this code");
        wrap.appendChild(btn);

        var reset;
        btn.addEventListener("click", function () {
          navigator.clipboard.writeText(pre.textContent.replace(/\s+$/, "")).then(
            function () { say("Copied", true); },
            function () { say("Press ⌘C", false); }
          );
        });

        function say(text, ok) {
          btn.textContent = text;
          btn.classList.toggle("done", ok);
          window.clearTimeout(reset);
          reset = window.setTimeout(function () {
            btn.textContent = "Copy";
            btn.classList.remove("done");
          }, 1600);
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
  }, { rootMargin: "-72px 0px -60% 0px", threshold: 0 });

  targets.forEach(function (heading) { observer.observe(heading); });
  mark();
})();
