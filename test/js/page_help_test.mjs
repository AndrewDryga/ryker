import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {createPageHelp, openWhenWide, wideQuery} from "../../priv/static/page-help.mjs"

// Andrew, 2026-09-25: how to use a page was one line of small print under a
// few lists. Every page now carries "How this page works": a column beside
// the page on a wide screen, open, and a closed disclosure above it on a
// narrow one, where open help used to fill a phone's whole first screen.
// CSS lays the column out; this script only decides when it starts open.

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

function hook(details, screen) {
  const kept = []
  const help = createPageHelp(details, screen, element => kept.push(element))
  help.mounted()
  return {help, kept}
}

test("the help opens on its own when the page loads on a wide screen", () => {
  const details = {open: false}
  hook(details, media(true))
  assert.equal(details.open, true)
})

test("on a narrow screen the help starts closed and stays as the reader leaves it", () => {
  const closed = {open: false}
  hook(closed, media(false))
  assert.equal(closed.open, false)

  const opened = {open: true}
  hook(opened, media(false))
  assert.equal(opened.open, true)
})

test("widening the window past the breakpoint opens the help; narrowing leaves it alone", () => {
  const details = {open: false}
  const screen = media(false)
  hook(details, screen)

  screen.change(true)
  assert.equal(details.open, true)

  screen.change(false)
  assert.equal(details.open, true, "narrowing is not the reader closing it")

  details.open = false
  screen.change(true)
  assert.equal(details.open, true)
})

test("only a wide screen opens the help; nothing here ever closes it", () => {
  const details = {open: true}
  openWhenWide(details, false)
  assert.equal(details.open, true)

  details.open = false
  openWhenWide(details, false)
  assert.equal(details.open, false)

  openWhenWide(details, true)
  assert.equal(details.open, true)
})

test("page refreshes never reset the open state the reader or the screen chose", () => {
  // LiveView re-renders the shell every few seconds from HTML with no open
  // attribute; without this the column would close under the reader.
  const details = {open: false}
  const {kept} = hook(details, media(true))
  assert.deepEqual(kept, [details])
})

test("leaving the page stops listening to the window", () => {
  const screen = media(false)
  const {help} = hook({open: false}, screen)
  assert.equal(screen.listeners.size, 1)

  help.destroyed()
  assert.equal(screen.listeners.size, 0)
})

test("the script and the stylesheet switch to the column at the same width", () => {
  const css = readFileSync(new URL("../../priv/static/workspace.css", import.meta.url), "utf8")
  assert.equal(wideQuery, "(min-width: 1600px)")
  assert.match(css, /@media \(min-width:1600px\) \{[^@]*\.page-help/)
})
