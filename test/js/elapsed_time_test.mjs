import {test} from "node:test"
import assert from "node:assert/strict"
import {createElapsedTime, formatElapsed} from "../../priv/static/elapsed-time.mjs"

test("elapsed time stays compact and never renders a decimal zero", () => {
  assert.equal(formatElapsed(0), "now")
  assert.equal(formatElapsed(999), "now")
  assert.equal(formatElapsed(1_000), "1s")
  assert.equal(formatElapsed(59_900), "59s")
  assert.equal(formatElapsed(60_000), "1m")
  assert.equal(formatElapsed(65_000), "1m 5s")
})

test("elapsed time advances locally and stops with its hook", () => {
  let now = 10_000
  let tick
  let cleared
  const element = {dataset: {elapsedMs: "2500"}, textContent: ""}
  const elapsed = createElapsedTime(element, {
    now: () => now,
    setInterval: callback => { tick = callback; return 42 },
    clearInterval: timer => { cleared = timer }
  })

  elapsed.mounted()
  assert.equal(element.textContent, "2s")

  now = 12_500
  tick()
  assert.equal(element.textContent, "5s")

  element.dataset.elapsedMs = "12000"
  elapsed.updated()
  assert.equal(element.textContent, "12s")

  elapsed.destroyed()
  assert.equal(cleared, 42)
})
