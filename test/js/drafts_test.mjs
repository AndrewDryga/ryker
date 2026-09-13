import {test} from "node:test"
import assert from "node:assert/strict"
import {draftKey, captureDrafts, acceptDrafts, sendDraft, legacyDraftKeys, transferLegacyDraft, adoptRetiredKey} from "../../priv/static/drafts.mjs"
import * as draftsModule from "../../priv/static/drafts.mjs"

const fixture = () => {
  const form = {getAttribute: () => "/conversations/test/messages", matches: selector => selector === ".composer"}
  const element = {name: "message", tagName: "TEXTAREA", form, value: "Unsent investigation", isConnected: true}
  form.elements = [element]
  const drafts = captureDrafts(form, "/conversations/test")
  const values = new Map([[drafts[0].key, element.value]])
  return {element, drafts, values, storage: {getItem: key => values.get(key) ?? null, removeItem: key => values.delete(key)}}
}

test("only a positive durable-acceptance receipt clears the submitted draft", async () => {
  const f = fixture()
  let request
  await sendDraft("/conversations/test/messages", "body", async (_url, options) => {
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
      await sendDraft("/conversations/test/messages", "body", async () => {
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
  assert.equal(draftKey(f.element, "/conversations/test"), null)
})

test("invalid conversation input is rejected locally with a specific reason", () => {
  assert.match(draftsModule.validateDraft("  ", []), /Write a message/)
  assert.match(draftsModule.validateDraft("語".repeat(7000), []), /20,000/)
  assert.match(draftsModule.validateDraft("Files", [{size: 1}, {size: 1}, {size: 1}]), /at most 2/)
  assert.match(draftsModule.validateDraft("Files", [{size: 9 * 1024 * 1024}]), /8 MiB/)
  assert.equal(draftsModule.validateDraft("", [{size: 1}]), "")
  assert.equal(draftsModule.validateDraft("Please investigate", []), "")
})

test("definite HTTP validation rejections are distinguishable from uncertain transport outcomes", async () => {
  await assert.rejects(sendDraft("/conversations/test/messages", "body", async () => ({status: 422})), {message: "rejected:422"})
})

// Two renames on 2026-09-13 left unsent drafts under keys no page reads again:
// the surface moved from /lab/<id> to /conversations/<id>, and the product was
// renamed from Responder to Ryker, so every sessionStorage key changed prefix.
// Drafts are keyed by pathname and form action, so a message typed and not sent
// before either rename sat under a retired key. These tests hold the one-time
// transfer to the canonical key: nothing is auto-sent, every text survives a
// collision, a storage failure loses nothing, and a retired key is read at most
// once. Each case owns one conversation identity: a key is settled once per
// session, exactly as it is in the browser, so cases must not share one.
const identity = suffix => {
  const conversation = `018f3ef7-1f62-7ee0-a83c-0c12f21d83${suffix}`
  return {
    conversation,
    canonical: `ryker:draft:/conversations/${conversation}:/conversations/${conversation}/messages:message`,
    retired: `responder:draft:/conversations/${conversation}:/conversations/${conversation}/messages:message`,
    oldest: `responder:draft:/lab/${conversation}:/lab/${conversation}/messages:message`
  }
}

const memoryStorage = (entries = {}) => {
  const values = new Map(Object.entries(entries))
  const reads = []
  return {
    values, reads,
    getItem: key => { reads.push(key); return values.has(key) ? values.get(key) : null },
    setItem: (key, value) => { values.set(key, value) },
    removeItem: key => { values.delete(key) }
  }
}

test("the canonical draft key carries the product prefix and maps back to its retired keys, newest first", () => {
  const {conversation, canonical, retired, oldest} = identity("a1")
  const form = {getAttribute: () => `/conversations/${conversation}/messages`, matches: selector => selector === ".composer"}
  const element = {name: "message", tagName: "TEXTAREA", form, value: "", isConnected: true}
  assert.equal(draftKey(element, `/conversations/${conversation}`), canonical)
  assert.deepEqual(legacyDraftKeys(canonical), [retired, oldest])
  assert.deepEqual(legacyDraftKeys("ryker:draft:/conversations:new:message"), ["responder:draft:/conversations:new:message"])
  assert.deepEqual(legacyDraftKeys(retired), [])
  assert.deepEqual(legacyDraftKeys(oldest), [])
})

test("a draft left under the retired product prefix is carried once to its canonical key without sending", () => {
  const {canonical, retired} = identity("a2")
  const storage = memoryStorage({[retired]: "Unsent investigation"})
  const originalFetch = globalThis.fetch
  let sends = 0
  globalThis.fetch = () => { sends++; throw new Error("a transfer must never send") }
  try {
    assert.equal(transferLegacyDraft(canonical, storage), "Unsent investigation")
  } finally {
    globalThis.fetch = originalFetch
  }
  assert.equal(storage.values.get(canonical), "Unsent investigation")
  assert.equal(storage.values.has(retired), false)
  assert.equal(sends, 0)
})

test("a draft that survived both renames under the retired /lab key is carried too", () => {
  const {canonical, oldest} = identity("a7")
  const storage = memoryStorage({[oldest]: "Typed before both renames"})
  assert.equal(transferLegacyDraft(canonical, storage), "Typed before both renames")
  assert.equal(storage.values.get(canonical), "Typed before both renames")
  assert.equal(storage.values.has(oldest), false)
})

test("a draft under every identity keeps each text, oldest first, and never drops one", () => {
  const {canonical, retired, oldest} = identity("a3")
  const storage = memoryStorage({[oldest]: "Typed under /lab", [retired]: "Typed before the rename", [canonical]: "Typed after the rename"})
  const merged = transferLegacyDraft(canonical, storage)
  assert.equal(merged, "Typed under /lab\n\nTyped before the rename\n\nTyped after the rename")
  assert.equal(storage.values.get(canonical), merged)
  assert.equal(storage.values.has(retired), false)
  assert.equal(storage.values.has(oldest), false)
})

test("an identical draft under several identities is kept once", () => {
  const {canonical, retired, oldest} = identity("a4")
  const storage = memoryStorage({[oldest]: "Same words", [retired]: "Same words", [canonical]: "Same words"})
  assert.equal(transferLegacyDraft(canonical, storage), "Same words")
  assert.equal(storage.values.get(canonical), "Same words")
  assert.equal(storage.values.has(retired), false)
  assert.equal(storage.values.has(oldest), false)
})

test("a browser-storage failure during the transfer discards nothing", () => {
  const {canonical, retired} = identity("a5")
  const broken = memoryStorage({[retired]: "Unsent investigation"})
  broken.setItem = () => { throw new Error("QuotaExceededError") }
  assert.equal(transferLegacyDraft(canonical, broken), null)
  assert.equal(broken.values.get(retired), "Unsent investigation")
  assert.equal(broken.values.has(canonical), false)

  const unavailable = {getItem: () => { throw new Error("SecurityError") }, setItem() {}, removeItem() {}}
  assert.equal(transferLegacyDraft(canonical, unavailable), null)

  // A failed attempt is not settled: the next restore tries the transfer again.
  const recovered = memoryStorage({[retired]: "Unsent investigation"})
  assert.equal(transferLegacyDraft(canonical, recovered), "Unsent investigation")
  assert.equal(recovered.values.has(retired), false)
})

test("after the transfer no retired key is consulted again", () => {
  const {canonical, retired, oldest} = identity("a6")
  const storage = memoryStorage({[retired]: "Unsent investigation"})
  transferLegacyDraft(canonical, storage)
  storage.reads.length = 0
  storage.values.set(retired, "A key that reappeared later")
  storage.values.set(oldest, "Another that reappeared later")
  assert.equal(transferLegacyDraft(canonical, storage), null)
  assert.deepEqual(storage.reads, [])
  assert.equal(storage.values.get(canonical), "Unsent investigation")
})

test("keys outside the current product prefix are never transferred", () => {
  const storage = memoryStorage({"responder:draft:/lab/other:/lab/other/messages:message": "Elsewhere"})
  assert.equal(transferLegacyDraft("responder:draft:/lab/other:/lab/other/messages:message", storage), null)
  assert.equal(transferLegacyDraft("other:draft:/conversations:new:message", storage), null)
  assert.deepEqual(storage.reads, [])
})

// Keys that hold state rather than text (which editor is open, an instruction
// draft with its revision, a relearn selection) are adopted whole: the retired
// value moves under the current key once, and only when nothing newer is there.
test("a value under the retired prefix is adopted once under the current key and never overwrites a newer one", () => {
  const storage = memoryStorage({"responder:editing:/conversations/x1": "018f-old"})
  adoptRetiredKey("ryker:editing:/conversations/x1", storage)
  assert.equal(storage.values.get("ryker:editing:/conversations/x1"), "018f-old")
  assert.equal(storage.values.has("responder:editing:/conversations/x1"), false)

  const newer = memoryStorage({"responder:editing:/conversations/x2": "018f-old", "ryker:editing:/conversations/x2": "018f-new"})
  adoptRetiredKey("ryker:editing:/conversations/x2", newer)
  assert.equal(newer.values.get("ryker:editing:/conversations/x2"), "018f-new")
  assert.equal(newer.values.has("responder:editing:/conversations/x2"), false)

  storage.reads.length = 0
  storage.values.set("responder:editing:/conversations/x1", "reappeared")
  adoptRetiredKey("ryker:editing:/conversations/x1", storage)
  assert.deepEqual(storage.reads, [])

  const foreign = memoryStorage({"responder:editing:/conversations/x3": "018f-old"})
  adoptRetiredKey("responder:editing:/conversations/x3", foreign)
  assert.deepEqual(foreign.reads, [])
})
