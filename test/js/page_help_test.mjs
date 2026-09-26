import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import vm from "node:vm"
import {createToggleHook, initialState, setupPageHelp, storageKey, wideQuery} from "../../priv/static/page-help.mjs"

// Andrew, 2026-09-26: "side docs are nice but they should not be collapsible
// like that. Instead we need a button that will open/hide that side bar
// completely (letting more space for main content or showing help docs) ...
// And browser should remember if docs are open or hidden." "How this page
// works" was a disclosure above every page (a column from 1600px) that opened
// itself on each wide load. One quiet button now shows or hides the help; the
// state lives on <html>, where LiveView never patches, and the browser keeps
// the reader's choice for each layout.

const earlyScript = readFileSync(new URL("../../priv/static/page-help-early.js", import.meta.url), "utf8")
const css = readFileSync(new URL("../../priv/static/workspace.css", import.meta.url), "utf8")

function memoryStorage(entries = {}) {
  const values = new Map(Object.entries(entries))
  return {
    values,
    getItem: key => (values.has(key) ? values.get(key) : null),
    setItem: (key, value) => values.set(key, String(value))
  }
}

function media(matches) {
  const listeners = new Set()
  return {
    matches,
    listeners,
    addEventListener(type, listener) { if (type === "change") listeners.add(listener) },
    removeEventListener(type, listener) { if (type === "change") listeners.delete(listener) },
    change(next) {
      this.matches = next
      for (const listener of listeners) listener({matches: next})
    }
  }
}

function attributes() {
  const values = new Map()
  return {
    values,
    getAttribute: name => (values.has(name) ? values.get(name) : null),
    setAttribute: (name, value) => values.set(name, String(value)),
    hasAttribute: name => values.has(name)
  }
}

// A page as the shell renders it: <html>, and the toggle button rendered closed.
function page() {
  const button = {
    ...attributes(),
    closest(selector) { return selector === "[data-page-help-toggle]" ? this : null }
  }
  button.setAttribute("aria-expanded", "false")
  button.setAttribute("aria-label", "Show help")
  const other = {closest: () => null}
  const listeners = new Map()
  const doc = {
    documentElement: attributes(),
    querySelectorAll: selector => (selector === "[data-page-help-toggle]" ? [button] : []),
    addEventListener(type, listener) {
      if (!listeners.has(type)) listeners.set(type, new Set())
      listeners.get(type).add(listener)
    },
    removeEventListener(type, listener) { listeners.get(type)?.delete(listener) },
    dispatch(type, event) { for (const listener of listeners.get(type) || []) listener(event) }
  }
  return {doc, button, other, listeners, state: () => doc.documentElement.getAttribute("data-page-help")}
}

function open(storage, wide) {
  const screen = media(wide)
  const shown = page()
  const teardown = setupPageHelp(shown.doc, screen, () => storage)
  return {...shown, screen, teardown, click: target => shown.doc.dispatch("click", {target})}
}

// What page-help-early.js leaves on <html> when it runs in <head>.
function early(storage, wide) {
  const root = attributes()
  const context = {
    window: {matchMedia: query => ({matches: query === wideQuery && wide}), localStorage: storage},
    document: {documentElement: root}
  }
  vm.runInNewContext(earlyScript, context)
  return root.getAttribute("data-page-help")
}

test("a first visit shows the help beside the page on a wide screen and keeps it off a phone's page", () => {
  assert.equal(initialState(() => memoryStorage(), true), "open")
  assert.equal(initialState(() => memoryStorage(), false), "closed")

  const wide = open(memoryStorage(), true)
  assert.equal(wide.state(), "open")
  const narrow = open(memoryStorage(), false)
  assert.equal(narrow.state(), "closed")
})

test("the one button hides the help and shows it again, and says which it will do", () => {
  const shown = open(memoryStorage(), true)
  assert.equal(shown.button.getAttribute("aria-expanded"), "true")
  assert.equal(shown.button.getAttribute("aria-label"), "Hide help")

  shown.click(shown.button)
  assert.equal(shown.state(), "closed")
  assert.equal(shown.button.getAttribute("aria-expanded"), "false")
  assert.equal(shown.button.getAttribute("aria-label"), "Show help")
  // No hover hint: the app's hints are built when the pointer arrives, so a
  // tap left "Show help" on a phone's screen over help that had just opened.
  assert.equal(shown.button.getAttribute("data-tooltip"), null)
  assert.equal(shown.button.getAttribute("title"), null)

  shown.click(shown.button)
  assert.equal(shown.state(), "open")

  // A click anywhere else is not the reader asking for help.
  shown.click(shown.other)
  assert.equal(shown.state(), "open")
})

test("the browser remembers the choice across reloads and pages, before the page paints", () => {
  const storage = memoryStorage()
  const first = open(storage, true)
  first.click(first.button)
  assert.equal(storage.values.get(storageKey(true)), "closed")

  // The next page, and a reload: <html> is set in <head>, before anything
  // renders, so the help never flashes open first.
  assert.equal(early(storage, true), "closed")
  assert.equal(open(storage, true).state(), "closed")

  const again = open(storage, true)
  again.click(again.button)
  assert.equal(early(storage, true), "open")
})

test("the early script decides exactly what the module would", () => {
  for (const stored of [undefined, "open", "closed", "sideways"]) {
    for (const wide of [true, false]) {
      const storage = memoryStorage(stored === undefined ? {} : {[storageKey(wide)]: stored})
      assert.equal(early(storage, wide), initialState(() => storage, wide), `${stored} ${wide}`)
    }
  }

  // A browser that refuses storage (a private window, a blocked site) still
  // shows the first-visit layout rather than an error.
  const refusing = {getItem() { throw new Error("SecurityError") }, setItem() { throw new Error("SecurityError") }}
  assert.equal(early(refusing, true), "open")
  assert.equal(early(refusing, false), "closed")
})

test("a choice made beside a wide page never opens the panel over a phone's page", () => {
  const storage = memoryStorage({[storageKey(true)]: "open"})
  assert.equal(open(storage, false).state(), "closed")
  assert.equal(early(storage, false), "closed")

  const narrow = open(storage, false)
  narrow.click(narrow.button)
  narrow.click(narrow.button)
  assert.equal(storage.values.get(storageKey(false)), "closed")
  assert.equal(storage.values.get(storageKey(true)), "open")
})

test("resizing across the breakpoint shows that layout's own choice", () => {
  const storage = memoryStorage()
  const shown = open(storage, true)
  shown.screen.change(false)
  assert.equal(shown.state(), "closed", "the column does not become a panel over the page")
  assert.equal(shown.button.getAttribute("aria-label"), "Show help")

  shown.screen.change(true)
  assert.equal(shown.state(), "open")
})

test("Escape closes the panel over a narrow page, never the column beside a wide one", () => {
  const storage = memoryStorage()
  const narrow = open(storage, false)
  narrow.click(narrow.button)
  assert.equal(narrow.state(), "open")
  narrow.doc.dispatch("keydown", {key: "Escape"})
  assert.equal(narrow.state(), "closed")
  assert.equal(storage.values.get(storageKey(false)), "closed")

  const wide = open(memoryStorage(), true)
  wide.doc.dispatch("keydown", {key: "Escape"})
  assert.equal(wide.state(), "open")
})

test("the page still shows and hides help when the browser refuses storage", () => {
  const refusing = {getItem() { throw new Error("SecurityError") }, setItem() { throw new Error("SecurityError") }}
  const shown = open(refusing, true)
  assert.equal(shown.state(), "open")
  shown.click(shown.button)
  assert.equal(shown.state(), "closed")
})

test("LiveView refreshes never reset what the button says", () => {
  // The shell renders the button closed on every patch; without this, the
  // next refresh would read "Show help" over help that is open.
  const shown = open(memoryStorage(), true)
  const ignored = []
  const button = page().button
  const hook = {...createToggleHook(shown.doc), el: button, js: () => ({ignoreAttributes: (el, names) => ignored.push([el, names])})}
  hook.mounted()

  assert.deepEqual(ignored, [[button, ["aria-expanded", "aria-label"]]])
  assert.equal(button.getAttribute("aria-expanded"), "true")
  assert.equal(button.getAttribute("aria-label"), "Hide help")
})

test("leaving the shell stops listening", () => {
  const shown = open(memoryStorage(), true)
  assert.equal(shown.screen.listeners.size, 1)
  shown.teardown()
  assert.equal(shown.screen.listeners.size, 0)
  for (const listeners of shown.listeners.values()) assert.equal(listeners.size, 0)
})

test("on a phone the open panel takes the page behind it out of reach", () => {
  // Over a phone's whole screen the panel hid the page but not from the
  // keyboard: Tab from the button landed on "Add an environment" beneath it.
  const phone = css.match(/@media \(max-width:800px\) \{[^@]*/g).join("\n")
  assert.match(phone, /html\[data-page-help=open\] \.ryker-app main > :not\(\.page-help, \.page-help-toggle\)[^{]*\{ visibility:hidden; \}/)
  assert.match(phone, /html\[data-page-help=open\] \.ryker-app > \.app-sidebar[^{]*\{ visibility:hidden; \}/)
})

test("the scripts and the stylesheet switch layouts at the same width", () => {
  assert.equal(wideQuery, "(min-width: 1280px)")
  assert.ok(earlyScript.includes(`"${wideQuery}"`), "page-help-early.js reads another width")
  assert.ok(earlyScript.includes(storageKey(true)) && earlyScript.includes(storageKey(false)))
  assert.match(css, /@media \(min-width:1280px\) \{[^@]*\.page-help/)
  assert.match(css, /@media \(max-width:1279px\) \{[^@]*\.page-help/)
})
