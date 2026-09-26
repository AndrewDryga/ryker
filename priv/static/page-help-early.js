// Before the first paint: whether the page's help shows, as this browser
// last chose for this layout, or on a first visit open beside a wide page and
// closed on a narrow one. A classic script in <head> runs before the body is
// parsed, so the page never flashes the other way; page-help.mjs owns the
// button and decides the same way (test/js/page_help_test.mjs holds the two
// to one answer).
(function () {
  var wide = window.matchMedia("(min-width: 1280px)").matches
  var state = null
  try {
    state = window.localStorage.getItem(wide ? "ryker:page-help:wide" : "ryker:page-help:narrow")
  } catch (_) {
    // A browser that refuses storage still gets the first-visit layout.
  }
  if (state !== "open" && state !== "closed") state = wide ? "open" : "closed"
  document.documentElement.setAttribute("data-page-help", state)
})()
