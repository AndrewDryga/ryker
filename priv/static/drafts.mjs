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
  return validateFiles(files)
}

// The attachment limits the server enforces, judged on the chosen files alone
// so the composer can explain a broken limit the moment files are picked.
export const validateFiles = files => {
  if (files.length > 2) return "Attach at most 2 files."
  if (files.reduce((total, file) => total + file.size, 0) > 8 * 1024 * 1024) return "Attachments must total at most 8 MiB."
  return ""
}
