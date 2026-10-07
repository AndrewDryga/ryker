import {test} from "node:test"
import assert from "node:assert/strict"
import {claimTitle, hintFor, setupTooltips, tooltipId, tooltipPosition} from "../../priv/static/tooltips.mjs"

function element({
  title = null,
  text = "",
  attributes = {},
  classes = [],
  dataset = {},
  children = [],
  width = 100,
  fullWidth = width
} = {}) {
  const attrs = {...attributes}
  if (title !== null) attrs.title = title
  const node = {
    dataset: {...dataset},
    textContent: children.length ? children.map(child => child.textContent).join("") : text,
    classList: {contains: name => classes.includes(name)},
    getAttribute: name => (name in attrs ? attrs[name] : null),
    hasAttribute: name => name in attrs,
    setAttribute: (name, value) => { attrs[name] = value },
    removeAttribute: name => { delete attrs[name] },
    querySelectorAll: () => children,
    clientWidth: width,
    scrollWidth: fullWidth,
    clientHeight: 20,
    scrollHeight: 20,
    attributes: attrs
  }
  node.closest = () => node
  return node
}

// A Chat conversation row: its title, time and state, the title repeated as the row's hint.
function chatRow(title, {titleWidth = 180, titleFullWidth = titleWidth} = {}) {
  return element({
    title,
    children: [
      element({text: title, width: titleWidth, fullWidth: titleFullWidth}),
      element({text: "10:51 UTC"}),
      element({text: "Replied · No environment"})
    ]
  })
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

test("a hint that repeats text shown in full is not shown again under the pointer", () => {
  // A Chat row's title appeared a second time under the pointer, as a box saying "hi" under a
  // row titled "hi" (Andrew, 2026-10-04: "why i see second hi below?").
  assert.equal(hintFor(chatRow("hi")), null)

  const choice = element({
    title: "Andrew Dryga",
    children: [element({text: "Andrew Dryga"}), element({text: "3"})]
  })
  assert.equal(hintFor(choice), null)

  const own = element({title: "Retry", text: "Retry"})
  assert.equal(hintFor(own), null)
})

test("a hint that repeats text cut off by an ellipsis still shows it in full", () => {
  const long = "Why did the checkout deploy stop halfway through the second region"
  const row = chatRow(long, {titleWidth: 180, titleFullWidth: 460})

  assert.deepEqual(hintFor(row).lines, [["ryker-tooltip-text", long]])
})

// A patch or live navigation removed the element under the pointer; it sent
// no pointerout, and its hint stayed on screen, described by a node no
// longer there (2026-10-04 review).
test("a hint whose element a patch removed goes at the next pointer or focus event", () => {
  const listeners = {}
  const node = () => ({dataset: {}, style: {}, children: [], hidden: false, offsetWidth: 120, offsetHeight: 20,
    setAttribute() {}, replaceChildren() { this.children = [] }, appendChild(child) { this.children.push(child) }})
  const root = {body: node(), createElement: node, addEventListener: (name, listener) => { listeners[name] = listener }}
  const previousWindow = globalThis.window
  globalThis.window = {innerWidth: 1200, innerHeight: 800, addEventListener() {}}

  try {
    const tooltip = setupTooltips(root)
    const nowhere = {closest: () => null}

    for (const next of ["pointerover", "pointermove", "focusin"]) {
      const row = element({title: "Deploy the checkout service"})
      Object.assign(row, {isConnected: true, contains: target => target === row, getBoundingClientRect: () => ({left: 0, bottom: 20})})

      listeners.pointerover({target: row, clientX: 4, clientY: 4})
      assert.equal(tooltip.hidden, false)
      assert.equal(row.getAttribute("aria-describedby"), tooltipId)

      row.isConnected = false
      listeners[next]({target: nowhere, clientX: 8, clientY: 8})
      assert.equal(tooltip.hidden, true, next)
      assert.equal(row.getAttribute("aria-describedby"), null, next)
    }
  } finally {
    globalThis.window = previousWindow
  }
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
