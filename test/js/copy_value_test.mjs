import {test} from "node:test"
import assert from "node:assert/strict"
import {blockText, copyValue, copyValueFromEvent} from "../../priv/static/copy-value.mjs"

test("copyValue copies the exact hidden value and exposes a brief accessible confirmation", async () => {
  const writes = []
  const status = {textContent: ""}
  const button = {
    dataset: {copyValue: "ingress-input:complete-value"},
    querySelector(selector) {
      return selector === "[data-copy-status]" ? status : null
    }
  }

  await copyValue(button, {writeText: async value => writes.push(value)}, () => {})

  assert.deepEqual(writes, ["ingress-input:complete-value"])
  assert.equal(button.dataset.copyState, "copied")
  assert.equal(status.textContent, "Copied")
})

function copyBlock(pre) {
  const status = {textContent: ""}
  const button = {
    dataset: {},
    querySelector: selector => (selector === "[data-copy-status]" ? status : null)
  }
  const block = {querySelector: selector => (selector === "pre" ? pre : null)}
  button.closest = selector => {
    if (selector === "[data-copy-block]") return button
    if (selector === ".copy-block") return block
    return null
  }
  return {block, button, status}
}

test("a formatted prompt block copies its rows as lines, the way it is shown", () => {
  // Rows are block elements with no newline characters between them, so the
  // block's plain text would run every line of the JSON together.
  const rows = ["{", '  "context": {}', "}"].map(textContent => ({textContent}))
  const pre = {textContent: rows.map(row => row.textContent).join(""), querySelectorAll: () => rows}

  assert.equal(blockText({querySelector: () => pre}), '{\n  "context": {}\n}')
})

test("a plain block copies its exact text", () => {
  const pre = {textContent: '{"exact":"bytes"}', querySelectorAll: () => []}
  assert.equal(blockText({querySelector: () => pre}), '{"exact":"bytes"}')
})

test("the copy button in a block's corner copies that block", async () => {
  const writes = []
  const pre = {textContent: '{"raw":true}', querySelectorAll: () => []}
  const {button, status} = copyBlock(pre)
  const original = globalThis.navigator
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: {clipboard: {writeText: async text => writes.push(text)}}
  })

  try {
    await copyValueFromEvent({target: button})
  } finally {
    Object.defineProperty(globalThis, "navigator", {configurable: true, value: original})
  }

  assert.deepEqual(writes, ['{"raw":true}'])
  assert.equal(button.dataset.copyState, "copied")
  assert.equal(status.textContent, "Copied")
})
