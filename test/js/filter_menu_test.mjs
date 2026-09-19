import {test} from "node:test"
import assert from "node:assert/strict"
import {createFilterMenu} from "../../priv/static/filter-menu.mjs"

// The + Filter menu as the server renders it: a list of field buttons and one
// hidden values panel per field, each holding its choices. Real layout is
// checked in Chromium.
function menu({innerWidth = 1500, right = 900} = {}) {
  const classes = new Set()
  const focused = []
  const element = (extra = {}) => ({attributes: {}, hidden: false, focus() { focused.push(this) },
    setAttribute(name, value) { this.attributes[name] = value }, getAttribute(name) { return this.attributes[name] ?? null },
    closest(selector) { for (let node = this; node; node = node.parent) if (node.matches?.(selector)) return node; return null },
    ...extra})
  const list = element({scrollTop: 0, matches: s => s === ".filter-fields"})
  const fields = {}
  const panels = {}
  ;["state", "transport", "repository"].forEach((key, index) => {
    fields[key] = element({dataset: {field: key}, offsetTop: 6 + index * 36, parent: list, tagName: "BUTTON",
      matches: s => s === ".filter-field"})
    fields[key].setAttribute("aria-expanded", "false")
    const panel = element({dataset: {field: key}, hidden: true, style: {}, matches: s => s === ".filter-values"})
    panel.first = element({parent: panel, tagName: key === "repository" ? "INPUT" : "BUTTON", matches: () => false})
    panel.back = element({parent: panel, tagName: "BUTTON", matches: s => s === "[data-back]"})
    panel.querySelector = () => panel.first
    panels[key] = panel
  })
  const el = {
    classList: {add: (...names) => names.forEach(n => classes.add(n)), remove: (...names) => names.forEach(n => classes.delete(n)),
      toggle: (name, force) => (force ? classes.add(name) : classes.delete(name)), contains: name => classes.has(name)},
    getBoundingClientRect: () => ({right: classes.has("align-end") ? right - 300 : right}),
    querySelector(selector) {
      const match = /data-field="([^"]+)"/.exec(selector)
      if (selector.startsWith(".filter-field[")) return fields[match[1]] ?? null
      if (selector.startsWith(".filter-values[")) return panels[match[1]] ?? null
      if (selector === ".filter-fields") return list
      return null
    },
    querySelectorAll: selector => (selector === ".filter-field" ? Object.values(fields) : [])
  }
  const timers = []
  const env = {window: {innerWidth}, setTimeout: (fn) => { timers.push(fn); return timers.length }, clearTimeout: id => { if (id) timers[id - 1] = null }}
  const controls = createFilterMenu(el, env)
  const run = () => timers.splice(0).forEach(fn => fn?.())
  const event = (target, extra = {}) => ({target, key: extra.key, stopped: false, prevented: false,
    stopPropagation() { this.stopped = true }, preventDefault() { this.prevented = true }})
  return {controls, fields, panels, classes, focused, run, event}
}

test("hovering a field opens its values beside the list and closes the previous field's", () => {
  // Andrew, 2026-09-19: choosing a field replaced the whole menu with its values
  // and left no way back. The list now stays and the values open to its side.
  const m = menu()
  m.controls.pointerOver(m.event(m.fields.state))
  assert.equal(m.panels.state.hidden, false)
  assert.equal(m.fields.state.getAttribute("aria-expanded"), "true")
  assert.equal(m.panels.state.style.top, "0px")

  m.controls.pointerOver(m.event(m.fields.transport))
  assert.equal(m.panels.state.hidden, false, "a hover switch waits a moment")
  m.run()
  assert.equal(m.panels.state.hidden, true)
  assert.equal(m.fields.state.getAttribute("aria-expanded"), "false")
  assert.equal(m.panels.transport.hidden, false)
  assert.equal(m.panels.transport.style.top, "36px")
})

test("a pointer crossing the list toward the open values does not swap them", () => {
  const m = menu()
  m.controls.pointerOver(m.event(m.fields.state))
  m.controls.pointerOver(m.event(m.fields.transport))
  m.controls.pointerOver(m.event(m.panels.state.first))
  m.run()
  assert.equal(m.panels.state.hidden, false)
  assert.equal(m.panels.transport.hidden, true)
})

test("clicking or pressing ArrowRight on a field moves focus into its values", () => {
  const m = menu()
  assert.equal(m.controls.click(m.event(m.fields.transport)), true)
  assert.equal(m.panels.transport.hidden, false)
  assert.equal(m.focused.at(-1), m.panels.transport.first)

  const arrow = m.event(m.fields.repository, {key: "ArrowRight"})
  assert.equal(m.controls.keydown(arrow), true)
  assert.equal(arrow.prevented, true)
  assert.equal(m.focused.at(-1), m.panels.repository.first)
})

test("Escape or Back in the values returns to the field and keeps the menu open", () => {
  const m = menu()
  m.controls.click(m.event(m.fields.transport))
  const escape = m.event(m.panels.transport.first, {key: "Escape"})
  assert.equal(m.controls.keydown(escape), true)
  assert.equal(escape.stopped, true, "the window Escape that closes the whole menu never fires")
  assert.equal(m.panels.transport.hidden, true)
  assert.equal(m.focused.at(-1), m.fields.transport)

  m.controls.click(m.event(m.fields.state))
  assert.equal(m.controls.click(m.event(m.panels.state.back)), true)
  assert.equal(m.panels.state.hidden, true)
  assert.equal(m.focused.at(-1), m.fields.state)

  // ArrowLeft goes back too, except while typing in a text field.
  m.controls.click(m.event(m.fields.repository))
  assert.equal(m.controls.keydown(m.event(m.panels.repository.first, {key: "ArrowLeft"})), false)
  assert.equal(m.panels.repository.hidden, false)
})

test("near the right edge the values open to the left, and phones stack them over the list", () => {
  const wide = menu({innerWidth: 1500, right: 900})
  wide.controls.place()
  assert.deepEqual([...wide.classes], [])

  const edge = menu({innerWidth: 1500, right: 1400})
  edge.controls.place()
  assert.deepEqual([...edge.classes].sort(), ["opens-start"])

  const overflowing = menu({innerWidth: 1500, right: 1560})
  overflowing.controls.place()
  assert.deepEqual([...overflowing.classes].sort(), ["align-end", "opens-start"])

  const phone = menu({innerWidth: 390, right: 300})
  phone.controls.place()
  assert.ok(phone.classes.has("stacked"))
})

test("a server patch that hides every panel brings the open one back", () => {
  const m = menu()
  m.controls.click(m.event(m.fields.transport))
  m.panels.transport.hidden = true
  m.controls.restore()
  assert.equal(m.panels.transport.hidden, false)
})
