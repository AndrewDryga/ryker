import {test} from "node:test"
import assert from "node:assert/strict"
import {promptInspectorTooltipId, tooltipPosition} from "../../priv/static/prompt-inspector.mjs"

test("prompt inspector exposes the stable tooltip id used by prompt fragments", () => {
  assert.equal(promptInspectorTooltipId, "prompt-inspector-tooltip")
})

test("prompt inspector follows the pointer and stays inside the viewport", () => {
  assert.deepEqual(
    tooltipPosition(
      {x: 940, y: 124},
      {width: 320, height: 100},
      {width: 1024, height: 768}
    ),
    {mobile: false, left: 692, top: 136}
  )
})

test("prompt inspector flips above the pointer near the bottom", () => {
  assert.deepEqual(
    tooltipPosition(
      {x: 100, y: 724},
      {width: 320, height: 120},
      {width: 1024, height: 768}
    ),
    {mobile: false, left: 112, top: 592}
  )
})

test("prompt inspector becomes an inset bottom panel on narrow screens", () => {
  assert.deepEqual(
    tooltipPosition(
      {x: 8, y: 224},
      {width: 320, height: 120},
      {width: 390, height: 844}
    ),
    {mobile: true, left: 12, bottom: 12}
  )
})
