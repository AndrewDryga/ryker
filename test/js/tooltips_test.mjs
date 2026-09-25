import {test} from "node:test"
import assert from "node:assert/strict"
import {claimTitle, hintFor, tooltipId, tooltipPosition} from "../../priv/static/tooltips.mjs"

function element({title = null, text = "", attributes = {}, classes = [], dataset = {}} = {}) {
  const attrs = {...attributes}
  if (title !== null) attrs.title = title
  const node = {
    dataset: {...dataset},
    textContent: text,
    classList: {contains: name => classes.includes(name)},
    getAttribute: name => (name in attrs ? attrs[name] : null),
    hasAttribute: name => name in attrs,
    setAttribute: (name, value) => { attrs[name] = value },
    removeAttribute: name => { delete attrs[name] },
    attributes: attrs
  }
  node.closest = () => node
  return node
}

test("the tooltip keeps the stable id prompt fragments describe themselves with", () => {
  assert.equal(tooltipId, "ryker-tooltip")
})

test("a title becomes an instant hint and no longer triggers the browser's delayed one", () => {
  // Native title tooltips wait about a second after the pointer arrives; the
  // permitted-action hints read as broken while they were waiting.
  const chip = element({title: "Start new work for this message", text: "Start work"})

  assert.deepEqual(hintFor(chip).lines, [["ryker-tooltip-text", "Start new work for this message"]])
  assert.equal(chip.getAttribute("title"), null)
  assert.equal(chip.dataset.tooltip, "Start new work for this message")
  // Its visible text still names it, so no label is added.
  assert.equal(chip.getAttribute("aria-label"), null)
})

test("a title that was an element's only name becomes its accessible name", () => {
  const icon = element({title: "Link to this card"})
  claimTitle(icon)
  assert.equal(icon.getAttribute("aria-label"), "Link to this card")

  const labelled = element({title: "Copy", attributes: {"aria-label": "Copy formatted prompt"}})
  claimTitle(labelled)
  assert.equal(labelled.getAttribute("aria-label"), "Copy formatted prompt")
})

test("a prompt fragment names its section, context and path", () => {
  const fragment = element({
    classes: ["prompt-fragment"],
    dataset: {sourceTitle: "Earlier messages", sourceContext: "Messages", sourcePath: "$.context.messages"}
  })

  assert.deepEqual(hintFor(fragment), {
    element: fragment,
    kind: "source",
    lines: [
      ["ryker-tooltip-title", "Earlier messages"],
      ["ryker-tooltip-context", "Messages"],
      ["ryker-tooltip-path", "$.context.messages"]
    ]
  })
})

test("an empty title shows nothing", () => {
  const blank = element({title: "  "})
  assert.equal(hintFor(blank), null)
  assert.equal(blank.getAttribute("title"), null)
})

test("the tooltip follows the pointer and stays inside the viewport", () => {
  assert.deepEqual(
    tooltipPosition({x: 940, y: 124}, {width: 320, height: 100}, {width: 1024, height: 768}),
    {mobile: false, left: 692, top: 136}
  )
})

test("the tooltip flips above the pointer near the bottom", () => {
  assert.deepEqual(
    tooltipPosition({x: 100, y: 724}, {width: 320, height: 120}, {width: 1024, height: 768}),
    {mobile: false, left: 112, top: 592}
  )
})

test("the tooltip becomes an inset bottom panel on narrow screens", () => {
  assert.deepEqual(
    tooltipPosition({x: 8, y: 224}, {width: 320, height: 120}, {width: 390, height: 844}),
    {mobile: true, left: 12, bottom: 12}
  )
})
