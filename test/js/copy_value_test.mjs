import {test} from "node:test"
import assert from "node:assert/strict"
import {copyValue} from "../../priv/static/copy-value.mjs"

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
