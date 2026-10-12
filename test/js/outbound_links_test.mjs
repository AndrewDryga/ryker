import {test} from "node:test"
import assert from "node:assert/strict"
import {markOutbound, markOutboundFromEvent} from "../../priv/static/outbound-links.mjs"

// Andrew, 2026-10-12, of a Chat card's "Open run" link to emisar.dev: "buttons
// in ui that lead to third party websites should always open in new window".
// The link replaced the console with the other site.
const origin = "http://127.0.0.1:4321"
const link = href => ({href: new URL(href, origin).href, target: "", rel: ""})

test("a link to another site opens in a new window, and a link inside Ryker stays", () => {
  const run = link("https://emisar.dev/app/emisar/runs/01a12ecd")
  assert.equal(markOutbound(run, origin), true)
  assert.equal(run.target, "_blank")
  assert.equal(run.rel, "noopener noreferrer")

  const page = link("/conversations/827c84b1")
  assert.equal(markOutbound(page, origin), false)
  assert.equal(page.target, "")

  assert.equal(markOutbound(link("mailto:someone@example.com"), origin), false)
})

test("a click anywhere inside an outbound link marks it before the browser follows it", () => {
  const pull = link("https://github.com/AndrewDryga/test/pull/21")
  const label = {closest: selector => (selector === "a[href]" ? pull : null)}

  markOutboundFromEvent({target: label}, origin)

  assert.equal(pull.target, "_blank")
  assert.equal(pull.rel, "noopener noreferrer")
})
