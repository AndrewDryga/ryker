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
  return `responder:draft:${path}:${action}:${element.name}`
}

// Drafts typed before 2026-09-13 were keyed by the retired /lab URLs. A draft
// under that key is carried to its /conversations identity exactly once, both
// texts survive a collision, a storage failure loses nothing, and once a key
// has been settled the retired key is never read again in this session.
// Nothing here sends: the operator still has to press Send.
const legacyPattern = /^responder:draft:\/conversations\/([^:/]+):\/conversations\/([^:]+):(.+)$/
const settled = new Set()

export const legacyDraftKey = key => {
  const match = legacyPattern.exec(key)
  return match ? `responder:draft:/lab/${match[1]}:/lab/${match[2]}:${match[3]}` : null
}

export const transferLegacyDraft = (key, storage) => {
  const legacyKey = legacyDraftKey(key)
  if (!legacyKey || settled.has(key)) return null
  let legacy
  try { legacy = storage.getItem(legacyKey) } catch (_) { return null }
  if (legacy === null) { settled.add(key); return null }
  try {
    const current = storage.getItem(key)
    const merged = current === null || current === "" || current === legacy ? legacy : `${legacy}\n\n${current}`
    storage.setItem(key, merged)
    storage.removeItem(legacyKey)
    settled.add(key)
    return merged
  } catch (_) {
    // The retired key stays until a transfer succeeds; nothing is dropped.
    return null
  }
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
