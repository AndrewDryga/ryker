// The page's help ("How this page works") is a column beside the page on a
// wide screen and a panel over it on a narrow one, and one quiet button at
// the top right shows or hides it (Andrew, 2026-09-26: "a button that will
// open/hide that side bar completely ... browser should remember if docs are
// open or hidden"). The state is data-page-help on <html>, which LiveView
// never patches, so it holds across live navigation; page-help-early.js sets
// it before the first paint and the stylesheet does the rest.
//
// The choice is kept per layout: hiding the column beside a laptop's page
// says nothing about a phone, where open help covers the page. A first
// visit shows the column on a wide screen and keeps the panel closed on a
// narrow one.

export const wideQuery = "(min-width: 1280px)"

const attribute = "data-page-help"
const toggleSelector = "[data-page-help-toggle]"

export function storageKey(wide) {
  return wide ? "ryker:page-help:wide" : "ryker:page-help:narrow"
}

// What a page shows for this layout: the reader's last choice, else the
// first-visit default. A browser that refuses storage gets the default.
export function initialState(storage, wide) {
  let stored = null
  try { stored = storage().getItem(storageKey(wide)) } catch (_) { stored = null }
  if (stored === "open" || stored === "closed") return stored
  return wide ? "open" : "closed"
}

function shownState(doc) {
  return doc.documentElement.getAttribute(attribute) === "open" ? "open" : "closed"
}

// The button says what it will do next. It has no hover hint: hints are
// built when the pointer arrives, so a tap left "Show help" on a phone's
// screen over help that had just opened.
function describe(button, state) {
  const open = state === "open"
  button.setAttribute("aria-expanded", open ? "true" : "false")
  button.setAttribute("aria-label", open ? "Hide help" : "Show help")
}

function show(doc, state) {
  doc.documentElement.setAttribute(attribute, state)
  for (const button of doc.querySelectorAll(toggleSelector)) describe(button, state)
}

function choose(doc, storage, wide, state) {
  show(doc, state)
  try { storage().setItem(storageKey(wide), state) } catch (_) { /* The page still shows the choice. */ }
}

// Wires the button for the whole document, so it works before the socket
// connects; returns what stops it.
export function setupPageHelp(doc, media, storage) {
  show(doc, doc.documentElement.hasAttribute(attribute) ? shownState(doc) : initialState(storage, media.matches))

  const onClick = event => {
    if (!event.target?.closest?.(toggleSelector)) return
    choose(doc, storage, media.matches, shownState(doc) === "open" ? "closed" : "open")
  }
  // Over a narrow page the panel covers what the reader was doing, so Escape
  // closes it; the column beside a wide page never is in the way.
  const onKeydown = event => {
    if (event.key === "Escape" && !media.matches && shownState(doc) === "open") {
      choose(doc, storage, false, "closed")
    }
  }
  const onChange = event => show(doc, initialState(storage, event.matches))

  doc.addEventListener("click", onClick)
  doc.addEventListener("keydown", onKeydown)
  media.addEventListener("change", onChange)

  return () => {
    doc.removeEventListener("click", onClick)
    doc.removeEventListener("keydown", onKeydown)
    media.removeEventListener("change", onChange)
  }
}

// The shell renders the button closed on every patch; the hook keeps what
// the browser set, so a refresh never reads "Show help" over open help.
export function createToggleHook(doc) {
  return {
    mounted() {
      this.js().ignoreAttributes(this.el, ["aria-expanded", "aria-label"])
      describe(this.el, shownState(doc))
    }
  }
}
