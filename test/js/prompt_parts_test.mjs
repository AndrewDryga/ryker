import {test} from "node:test"
import assert from "node:assert/strict"
import {promptPartFromEvent, selectPart} from "../../priv/static/prompt-parts.mjs"

function classList() {
  const names = new Set()
  return {
    names,
    contains: name => names.has(name),
    toggle(name, on) {
      if (on) names.add(name)
      else names.delete(name)
    }
  }
}

function element(dataset, attributes = {}) {
  return {
    dataset,
    attributes,
    classList: classList(),
    getAttribute(name) { return this.attributes[name] ?? null },
    setAttribute(name, value) { this.attributes[name] = value }
  }
}

function prompt() {
  const chips = ["Earlier messages", "Permitted actions"].map(part =>
    element({promptPart: part}, {"aria-pressed": "false"})
  )
  const fragments = [
    element({part: "Earlier messages"}),
    element({part: "Permitted actions"}),
    element({part: "Earlier messages"})
  ]
  const container = {
    classList: classList(),
    querySelectorAll: selector => (selector === ".prompt-part" ? chips : fragments),
    querySelector: () => null
  }
  for (const node of [...chips, ...fragments]) {
    node.closest = selector => {
      if (selector === ".prompt-document") return container
      if (selector === ".prompt-part") return chips.includes(node) ? node : null
      if (selector === ".prompt-fragment") return fragments.includes(node) ? node : null
      return null
    }
  }
  return {container, chips, fragments}
}

const highlighted = fragments => fragments.map(fragment => fragment.classList.contains("is-highlighted"))
const pressed = chips => chips.map(chip => chip.getAttribute("aria-pressed"))

test("choosing a part highlights only its fragments and returns the first", () => {
  const {container, chips, fragments} = prompt()

  const first = selectPart(container, "Earlier messages")

  assert.equal(first, fragments[0])
  assert.deepEqual(highlighted(fragments), [true, false, true])
  assert.deepEqual(pressed(chips), ["true", "false"])
  assert.ok(container.classList.contains("has-highlight"))
})

test("choosing another part moves the highlight instead of adding to it", () => {
  const {container, chips, fragments} = prompt()

  selectPart(container, "Earlier messages")
  selectPart(container, "Permitted actions")

  assert.deepEqual(highlighted(fragments), [false, true, false])
  assert.deepEqual(pressed(chips), ["false", "true"])
})

test("choosing the active part again returns the prompt to plain text", () => {
  const {container, chips, fragments} = prompt()

  selectPart(container, "Earlier messages")
  const first = selectPart(container, "Earlier messages")

  assert.equal(first, null)
  assert.deepEqual(highlighted(fragments), [false, false, false])
  assert.deepEqual(pressed(chips), ["false", "false"])
  assert.ok(!container.classList.contains("has-highlight"))
})

test("clicking prompt text names its part without undoing it or stealing a selection", () => {
  const {container, fragments} = prompt()
  let collapsed = true
  const root = {getSelection: () => ({isCollapsed: collapsed})}

  promptPartFromEvent({target: fragments[1]}, root)
  assert.deepEqual(highlighted(fragments), [false, true, false])

  // A second click on highlighted text keeps the highlight.
  promptPartFromEvent({target: fragments[1]}, root)
  assert.deepEqual(highlighted(fragments), [false, true, false])

  // Selecting text to copy it does not switch parts.
  collapsed = false
  promptPartFromEvent({target: fragments[0]}, root)
  assert.deepEqual(highlighted(fragments), [false, true, false])
  assert.ok(container.classList.contains("has-highlight"))
})
