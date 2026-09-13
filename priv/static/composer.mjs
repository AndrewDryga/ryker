import {captureDrafts, acceptDrafts, sendDraft, validateDraft} from "./drafts.mjs"
import {followSentDraft} from "./conversation.mjs"

// The conversation composer posts through fetch rather than a LiveView event
// so that a rejected or unconfirmed send keeps the typed draft and its files
// exactly where they were; only a confirmed 202 receipt clears them.
export function createComposer({pushEvent, active, storage, location: loc}) {
  let sending = false

  function input(event) {
    if (event.target.form?.matches(".composer")) event.target.form.querySelector("textarea")?.setCustomValidity("")
  }

  // Returns true when the event was a composer submission this owns.
  function submit(event) {
    const form = event.target
    if (!form.matches(".composer") || event.defaultPrevented || !form.checkValidity()) return false
    event.preventDefault()
    if (sending) return true
    const message = form.querySelector("textarea[name=message]")
    const selectedFiles = Array.from(form.querySelector("input[type=file]")?.files || [])
    const validationError = validateDraft(message.value, selectedFiles)
    message.setCustomValidity(validationError)
    if (validationError) { message.reportValidity(); return true }
    send(form)
    return true
  }

  async function send(form) {
    sending = true
    const drafts = captureDrafts(form, loc.pathname)
    const body = new FormData(form)
    const button = form.querySelector("button[type=submit]")
    const files = form.querySelector("input[type=file]")
    const status = form.querySelector(".composer-status")
    button.disabled = true
    if (files) files.disabled = true
    status.hidden = false
    status.textContent = "Saving message…"
    try {
      await sendDraft(form.action, body)
      if (!active() || !form.isConnected) return
      let store
      try { store = storage() } catch (_) { store = {removeItem() {}} }
      acceptDrafts(drafts, store)
      if (files) files.value = ""
      status.textContent = "Message saved. Admission progress appears above."
      pushEvent("refresh", {})
      followSentDraft(form, pushEvent)
    } catch (error) {
      if (!active() || !form.isConnected) return
      status.textContent = error.message.startsWith("rejected:")
        ? "The server rejected this message. Your draft is preserved. Check message and file limits, or reload the conversation if its form has expired."
        : "Acceptance was not confirmed. Your draft is preserved. Check the conversation before sending again; no automatic retry was made."
      pushEvent("refresh", {})
    } finally {
      sending = false
      button.disabled = false
      if (files) files.disabled = false
    }
  }

  return {input, submit}
}
