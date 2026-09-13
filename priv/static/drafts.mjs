// The index composer posts to a fresh identity on every visit; keying its
// draft by that action would strand the text on the next visit. A form may
// name a stable draft scope instead (data-draft-action="new").
export const draftKey = (element, path) => {
  if (!element.name || !element.form) return null
  // The composer and each message's inline editor keep drafts; the editor's
  // key includes its own edit route, so two messages never share one.
  if (!element.form.matches(".composer") && !element.form.matches(".lab-edit-form")) return null
  if (element.tagName !== "TEXTAREA" && !["text", "search"].includes(element.type)) return null
  const action = element.form.dataset?.draftAction || element.form.getAttribute("action")
  return `ryker:draft:${path}:${action}:${element.name}`
}

// Two renames on 2026-09-13 retired the keys drafts were stored under: the
// surface moved from /lab to /conversations, and the product was renamed
// (Responder to Ryker), which changed every key's prefix. A draft under a
// retired key is carried to its current identity exactly once, every text survives a
// collision, a storage failure loses nothing, and once a key has been settled
// no retired key is read again in this session. Nothing here sends: the
// operator still has to press Send.
//
// Everything from here to captureDrafts is that one-time carry-over. Remove it,
// its callers and its tests after 2026-09-20: drafts live in sessionStorage,
// which dies with the tab, and no tab stays open that long.
const currentPrefix = "ryker:"
const retiredPrefix = "responder:"
const conversationPattern = /^draft:\/conversations\/([^:/]+):\/conversations\/([^:]+):(.+)$/
// Settled keys belong to the storage they were settled in: one tab has one
// sessionStorage, so "once per session" is once per storage object.
const settledByStorage = new WeakMap()
const settledIn = storage => {
  let keys = settledByStorage.get(storage)
  if (!keys) { keys = new Set(); settledByStorage.set(storage, keys) }
  return keys
}

// The retired keys a current key may still be stored under, newest first.
export const legacyDraftKeys = key => {
  if (!key.startsWith(`${currentPrefix}draft:`)) return []
  const rest = key.slice(currentPrefix.length)
  const keys = [retiredPrefix + rest]
  const match = conversationPattern.exec(rest)
  if (match) keys.push(`${retiredPrefix}draft:/lab/${match[1]}:/lab/${match[2]}:${match[3]}`)
  return keys
}

export const transferLegacyDraft = (key, storage) => {
  const legacyKeys = legacyDraftKeys(key)
  if (legacyKeys.length === 0) return null
  const settled = settledIn(storage)
  if (settled.has(key)) return null
  let found
  try {
    // Oldest text first, so a merged draft reads in the order it was typed.
    found = legacyKeys.map(legacyKey => [legacyKey, storage.getItem(legacyKey)]).reverse()
      .filter(([, value]) => value !== null)
  } catch (_) { return null }
  if (found.length === 0) { settled.add(key); return null }
  try {
    const current = storage.getItem(key)
    const texts = [...found.map(([, value]) => value), current]
      .filter((value, index, all) => value !== null && value !== "" && all.indexOf(value) === index)
    const merged = texts.join("\n\n")
    storage.setItem(key, merged)
    for (const [legacyKey] of found) storage.removeItem(legacyKey)
    settled.add(key)
    return merged
  } catch (_) {
    // The retired keys stay until a transfer succeeds; nothing is dropped.
    return null
  }
}

// State keys (which editor is open, an instruction draft with its revision, a
// relearn selection) are adopted whole: the retired value moves under the
// current key once, and only when nothing newer is already there.
export const adoptRetiredKey = (key, storage) => {
  if (!key.startsWith(currentPrefix)) return
  const settled = settledIn(storage)
  if (settled.has(key)) return
  const retired = retiredPrefix + key.slice(currentPrefix.length)
  try {
    const value = storage.getItem(retired)
    if (value !== null) {
      if (storage.getItem(key) === null) storage.setItem(key, value)
      storage.removeItem(retired)
    }
    settled.add(key)
  } catch (_) { /* Not settled: the next read tries again. */ }
}

export const captureDrafts = (form, path) => Array.from(form.elements).flatMap(element => {
  const key = draftKey(element, path)
  return key ? [{key, element, value: element.value}] : []
})

export const acceptDrafts = (drafts, storage) => {
  for (const draft of drafts) {
    // The operator may already be typing their next message during delivery.
    if (!draft.element.isConnected || draft.element.value !== draft.value) continue
    draft.element.value = ""
    try {
      if (storage.getItem(draft.key) === draft.value) storage.removeItem(draft.key)
    } catch (_) { /* Storage may be unavailable. */ }
  }
}

export const sendDraft = async (url, body, fetcher = fetch) => {
  const response = await fetcher(url, {
    method: "POST", body, credentials: "same-origin", redirect: "error",
    headers: {Accept: "application/json"}
  })
  if ([400, 403, 409, 413, 422].includes(response.status)) throw new Error(`rejected:${response.status}`)
  if (response.status !== 202) throw new Error("not_accepted")
  const receipt = await response.json()
  if (receipt.accepted !== true) throw new Error("unconfirmed_receipt")
}

export const validateDraft = (message, files) => {
  const bytes = new TextEncoder().encode(message).byteLength
  if (bytes > 20000) return `Message is ${bytes.toLocaleString("en-US")} bytes; maximum is 20,000.`
  if (message.includes("\u0000")) return "Remove the null character from your message."
  if (message.trim() === "" && files.length === 0) return "Write a message or attach a file."
  if (files.length > 2) return "Attach at most 2 files."
  if (files.reduce((total, file) => total + file.size, 0) > 8 * 1024 * 1024) return "Attachments must total at most 8 MiB."
  return ""
}
