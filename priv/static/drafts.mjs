export const draftKey = (element, path) => {
  if (!element.name || !element.form?.matches(".composer")) return null
  if (element.tagName !== "TEXTAREA" && !["text", "search"].includes(element.type)) return null
  return `responder:draft:${path}:${element.form.getAttribute("action")}:${element.name}`
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
