import {test} from "node:test"
import assert from "node:assert/strict"
import {draftKey, captureDrafts, acceptDrafts, sendDraft} from "../../priv/static/drafts.mjs"
import * as draftsModule from "../../priv/static/drafts.mjs"

const fixture = () => {
  const form = {getAttribute: () => "/lab/test/messages", matches: selector => selector === ".composer"}
  const element = {name: "message", tagName: "TEXTAREA", form, value: "Unsent investigation", isConnected: true}
  form.elements = [element]
  const drafts = captureDrafts(form, "/lab/test")
  const values = new Map([[drafts[0].key, element.value]])
  return {element, drafts, values, storage: {getItem: key => values.get(key) ?? null, removeItem: key => values.delete(key)}}
}

test("only a positive durable-acceptance receipt clears the submitted draft", async () => {
  const f = fixture()
  let request
  await sendDraft("/lab/test/messages", "body", async (_url, options) => {
    request = options
    return {status: 202, json: async () => ({accepted: true})}
  })
  acceptDrafts(f.drafts, f.storage)
  assert.equal(f.element.value, "")
  assert.equal(f.values.size, 0)
  assert.equal(request.redirect, "error")
})

test("rejections and ambiguous network outcomes preserve the draft without automatic resubmission", async () => {
  for (const result of [400, 403, 409, 422, 500, "timeout", "bad_receipt"]) {
    const f = fixture()
    let calls = 0
    await assert.rejects(async () => {
      await sendDraft("/lab/test/messages", "body", async () => {
        calls++
        if (result === "timeout") throw new Error("network failed")
        return {status: result === "bad_receipt" ? 202 : result, json: async () => ({accepted: false})}
      })
      acceptDrafts(f.drafts, f.storage)
    })
    assert.equal(calls, 1)
    assert.equal(f.element.value, "Unsent investigation")
    assert.equal(f.values.size, 1)
  }
})

test("accepting the previous message cannot erase a newer draft", () => {
  const f = fixture()
  f.element.value = "And inspect its cost"
  acceptDrafts(f.drafts, f.storage)
  assert.equal(f.element.value, "And inspect its cost")
  assert.equal(f.values.size, 1)
})

test("a delayed receipt from an unmounted composer cannot erase a remounted draft", () => {
  // Navigation must not let a completed send delete the next conversation draft.
  const f = fixture()
  f.element.isConnected = false
  f.values.set(f.drafts[0].key, "A newer draft after navigating back")
  acceptDrafts(f.drafts, f.storage)
  assert.equal(f.values.get(f.drafts[0].key), "A newer draft after navigating back")
})

test("a submitted edit cannot be restored over a newer server revision", () => {
  const f = fixture()
  f.element.form.matches = () => false
  assert.equal(draftKey(f.element, "/lab/test"), null)
})

test("invalid Lab input is rejected locally with a specific reason", () => {
  assert.match(draftsModule.validateDraft("  ", []), /Write a message/)
  assert.match(draftsModule.validateDraft("語".repeat(7000), []), /20,000/)
  assert.match(draftsModule.validateDraft("Files", [{size: 1}, {size: 1}, {size: 1}]), /at most 2/)
  assert.match(draftsModule.validateDraft("Files", [{size: 9 * 1024 * 1024}]), /8 MiB/)
  assert.equal(draftsModule.validateDraft("", [{size: 1}]), "")
  assert.equal(draftsModule.validateDraft("Please investigate", []), "")
})

test("definite HTTP validation rejections are distinguishable from uncertain transport outcomes", async () => {
  await assert.rejects(sendDraft("/lab/test/messages", "body", async () => ({status: 422})), {message: "rejected:422"})
})
