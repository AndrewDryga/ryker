import {test} from "node:test"
import assert from "node:assert/strict"
import {dropDraft, keepDraft, pruneDrafts} from "../../priv/static/draft-store.mjs"

function memoryStorage(entries = {}) {
  const map = new Map(Object.entries(entries))
  return {map, get length() { return map.size }, key: index => [...map.keys()][index] ?? null,
    getItem: key => map.has(key) ? map.get(key) : null, setItem: (key, value) => map.set(key, String(value)),
    removeItem: key => map.delete(key)}
}

const hour = 60 * 60 * 1000
const now = Date.UTC(2026, 9, 7, 12)

// Drafts went only on a confirmed send, a confirmed edit or a cancel:
// abandoned text, a pasted credential among it, stayed readable to any script
// on the origin for the life of the tab, and keys of up to 20 KB piled up
// until the quota made saves fail without a word (2026-10-04 review).
test("a page drops the drafts nobody touched for a day, and those written before stamps", () => {
  const storage = memoryStorage({"ryker:draft:/conversations/old:message": "abandoned", "ryker:editing:/conversations/c": "id"})
  keepDraft(storage, "ryker:draft:/conversations/old:message", "abandoned", now - 25 * hour)
  keepDraft(storage, "ryker:instruction-draft:global", "{}", now - 2 * hour)
  storage.setItem("ryker:settings-draft:settings:work", "unstamped")
  storage.setItem("ryker:page-help:wide", "open")

  pruneDrafts(storage, now)

  assert.deepEqual([...storage.map.keys()].sort(),
    ["ryker:drafts", "ryker:instruction-draft:global", "ryker:page-help:wide"])
  assert.deepEqual(JSON.parse(storage.getItem("ryker:drafts")), {"ryker:instruction-draft:global": now - 2 * hour})
})

test("past fifty drafts, the oldest go first", () => {
  const storage = memoryStorage()
  for (let n = 0; n < 53; n++) keepDraft(storage, `ryker:draft:/conversations/${n}:message`, "text", now - (60 - n) * 1000)

  pruneDrafts(storage, now)

  const drafts = [...storage.map.keys()].filter(key => key.startsWith("ryker:draft:"))
  assert.equal(drafts.length, 50)
  for (const gone of [0, 1, 2]) assert.equal(storage.getItem(`ryker:draft:/conversations/${gone}:message`), null)
  assert.equal(storage.getItem("ryker:draft:/conversations/52:message"), "text")
})

test("a dropped draft takes its stamp with it, and the last one the index", () => {
  const storage = memoryStorage()
  keepDraft(storage, "ryker:draft:a", "one", now)
  keepDraft(storage, "ryker:draft:b", "two", now)
  dropDraft(storage, "ryker:draft:a")
  assert.deepEqual(JSON.parse(storage.getItem("ryker:drafts")), {"ryker:draft:b": now})
  dropDraft(storage, "ryker:draft:b")
  assert.equal(storage.map.size, 0)
})

test("a refused write throws, as the storage did, and an unreadable index is started again", () => {
  const full = memoryStorage()
  full.setItem = () => { throw new Error("QuotaExceededError") }
  assert.throws(() => keepDraft(full, "ryker:draft:a", "text", now), /Quota/)

  const storage = memoryStorage({"ryker:drafts": "not json", "ryker:draft:a": "text"})
  keepDraft(storage, "ryker:draft:b", "kept", now)
  pruneDrafts(storage, now)
  assert.deepEqual([...storage.map.keys()].sort(), ["ryker:draft:b", "ryker:drafts"])
})
