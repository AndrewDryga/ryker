import {captureDrafts, acceptDrafts, sendDraft, validateDraft, validateFiles} from "./drafts.mjs"
import {followSentDraft} from "./conversation.mjs"

// The conversation composer posts through fetch rather than a LiveView event
// so that a rejected or unconfirmed send keeps the typed draft and its files
// exactly where they were; only a confirmed 202 receipt clears them.
export function createComposer({pushEvent, active, storage, location: loc}) {
  let sending = false

  function showFeedback(feedback, message, tone) {
    if (!feedback) return
    const text = feedback.querySelector?.(".form-feedback-message")
    if (text) text.textContent = message
    else feedback.textContent = message
    const icon = feedback.querySelector?.(".form-feedback-icon")
    if (icon) icon.textContent = tone === "success" ? "✓" : tone === "info" ? "i" : "!"
    feedback.hidden = message === ""
    if (feedback.dataset) feedback.dataset.tone = tone
    feedback.setAttribute?.("role", tone === "error" ? "alert" : "status")
    if (feedback.classList) {
      feedback.classList.remove(
        "form-feedback-error",
        "form-feedback-warning",
        "form-feedback-success",
        "form-feedback-info"
      )
      feedback.classList.add(`form-feedback-${tone}`)
    }
  }

  // The attachment limits are said only when a choice breaks them, beside
  // the composer, and the reason clears as soon as the choice is fixed.
  function showFileProblem(form, problem) {
    const field = form.querySelector("input[type=file]")
    const error = form.querySelector(".composer-error")
    showFeedback(error, problem, "error")
    if (problem) field?.setAttribute("aria-invalid", "true")
    else field?.removeAttribute("aria-invalid")
  }

  function input(event) {
    const form = event.target.form
    if (!form?.matches(".composer")) return
    form.querySelector("textarea")?.setCustomValidity("")
    if (event.target.type === "file") showFileProblem(form, validateFiles(Array.from(event.target.files || [])))
  }

  // Returns true when the event was a composer submission this owns.
  function submit(event) {
    const form = event.target
    if (!form.matches(".composer") || event.defaultPrevented || !form.checkValidity()) return false
    event.preventDefault()
    if (sending) return true
    const message = form.querySelector("textarea[name=message]")
    const selectedFiles = Array.from(form.querySelector("input[type=file]")?.files || [])
    const fileProblem = validateFiles(selectedFiles)
    showFileProblem(form, fileProblem)
    if (fileProblem) return true
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
    showFeedback(status, "Saving message…", "info")
    try {
      await sendDraft(form.action, body)
      if (!active() || !form.isConnected) return
      let store
      try { store = storage() } catch (_) { store = {removeItem() {}} }
      acceptDrafts(drafts, store)
      if (files) files.value = ""
      showFeedback(status, "Message saved. Admission progress appears above.", "success")
      pushEvent("refresh", {})
      followSentDraft(form, pushEvent)
    } catch (error) {
      if (!active() || !form.isConnected) return
      showFeedback(
        status,
        error.message.startsWith("rejected:")
          ? "The server rejected this message. Your draft is preserved. Check message and file limits, or reload the conversation if its form has expired."
          : "Acceptance was not confirmed. Your draft is preserved. Check the conversation before sending again; no automatic retry was made.",
        "error"
      )
      pushEvent("refresh", {})
    } finally {
      sending = false
      button.disabled = false
      if (files) files.disabled = false
    }
  }

  return {input, submit}
}
