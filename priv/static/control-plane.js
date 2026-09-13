import {Socket} from "/assets/phoenix.mjs"
import {LiveSocket} from "/assets/phoenix_live_view.esm.js"
import {draftKey as keyFor, captureDrafts, acceptDrafts, sendDraft, validateDraft, transferLegacyDraft} from "/assets/drafts.mjs"
import {createRelearnPicker} from "/assets/relearn-selection.mjs"
import {createConversationControls, followSentDraft} from "/assets/conversation.mjs"
import {createInstructionDraft} from "/assets/instruction-draft.mjs"
import {createSettingsGuard} from "/assets/settings-draft.mjs"
import {applyFilterChange} from "/assets/filter-toolbar.mjs"
import {ConversationHistory, captureReadingAnchor, restoreReadingAnchor} from "/assets/history.mjs"
const draftKey = element => element.closest?.("form[phx-change]") ? null : keyFor(element, location.pathname)

// Filter toolbars are plain GET forms and work before the socket connects,
// so their dropdowns are handled at the document, not inside the hook.
document.addEventListener("change", applyFilterChange)

const PreserveReadingState = {
  mounted() {
    this.active = true
    this.restoreDrafts()
    this.relearnPicker = createRelearnPicker(this.el, () => sessionStorage)
    this.conversation = createConversationControls(this.el, {
      storage: () => sessionStorage,
      pushEvent: (name, params) => this.pushEvent(name, params)
    })
    this.conversation.restore()
    this.onInput = event => {
      this.relearnPicker.change(event)
      this.conversation.input(event)
      if (event.target.form?.matches(".composer")) event.target.form.querySelector("textarea")?.setCustomValidity("")
      const key = draftKey(event.target)
      if (key) {
        try { sessionStorage.setItem(key, event.target.value) } catch (_) { /* Storage can be disabled. */ }
      }
    }
    this.onSubmit = async event => {
      const form = event.target
      if (this.conversation.submit(event)) return
      if (!form.matches(".composer") || event.defaultPrevented || !form.checkValidity()) return
      event.preventDefault()
      if (this.sending) return
      const message = form.querySelector("textarea[name=message]")
      const selectedFiles = Array.from(form.querySelector("input[type=file]")?.files || [])
      const validationError = validateDraft(message.value, selectedFiles)
      message.setCustomValidity(validationError)
      if (validationError) { message.reportValidity(); return }
      this.sending = true
      const drafts = captureDrafts(form, location.pathname)
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
        if (!this.active || !form.isConnected) return
        let storage
        try { storage = sessionStorage } catch (_) { storage = {removeItem() {}} }
        acceptDrafts(drafts, storage)
        if (files) files.value = ""
        status.textContent = "Message saved. Admission progress appears above."
        this.pushEvent("refresh", {})
        followSentDraft(form, (name, params) => this.pushEvent(name, params))
      } catch (error) {
        if (!this.active || !form.isConnected) return
        status.textContent = error.message.startsWith("rejected:")
          ? "The server rejected this message. Your draft is preserved. Check message and file limits, or reload the conversation if its form has expired."
          : "Acceptance was not confirmed. Your draft is preserved. Check the conversation before sending again; no automatic retry was made."
        this.pushEvent("refresh", {})
      } finally {
        this.sending = false
        button.disabled = false
        if (files) files.disabled = false
      }
    }
    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("change", this.onInput)
    this.el.addEventListener("submit", this.onSubmit)
    this.onClick = event => { this.relearnPicker.click(event); this.conversation.click(event) }
    this.el.addEventListener("click", this.onClick)
    this.onKeydown = event => {
      if (this.conversation.keydown(event)) return
      if (event.key === "Enter" && (event.metaKey || event.ctrlKey) && event.target.matches(".composer textarea")) {
        event.preventDefault()
        event.target.closest("form").requestSubmit()
      }
    }
    this.el.addEventListener("keydown", this.onKeydown)
    // Heavy bodies are not in the page until a reader opens them. `toggle` does
    // not bubble, so this listens in the capture phase from the shell.
    this.onToggle = event => {
      const node = event.target
      if (node?.tagName !== "DETAILS" || !node.open) return
      const artifact = node.dataset?.artifact
      if (artifact && !node.dataset.revoked) this.pushEvent("disclose", {artifact})
    }
    this.el.addEventListener("toggle", this.onToggle, true)
    this.onHashChange = () => {
      this.fragmentURL = null
      this.revealFragment()
    }
    window.addEventListener("hashchange", this.onHashChange)
    this.revealFragment()
  },
  beforeUpdate() {
    this.readingURL = location.href
    this.focusedID = this.el.contains(document.activeElement) ? document.activeElement.id : null
    this.expanded = Array.from(this.el.querySelectorAll("details")).map((node, index) => ({
      key: node.id || `${index}:${node.querySelector("summary")?.textContent}`, open: node.open
    }))
    this.scroll = window.scrollY
    // A conversation transcript is anchored to the row being read, not to a
    // pixel offset: pages prepend above it and late images resize under it.
    this.reading = captureReadingAnchor(this.el)
  },
  updated() {
    const expanded = new Map((this.expanded || []).map(item => [item.key, item.open]))
    this.el.querySelectorAll("details").forEach((node, index) => {
      const key = node.id || `${index}:${node.querySelector("summary")?.textContent}`
      // Privacy wins over the reader's selection. Once the server says a body
      // was revoked, expired or redacted, the disclosure it was read in closes
      // and no earlier open state reopens it.
      if (node.dataset?.revoked) { node.open = false; return }
      if (expanded.has(key)) node.open = expanded.get(key)
    })
    this.restoreDrafts()
    this.relearnPicker.refresh()
    this.conversation.refresh()
    // LiveView restores input focus, but a replaced response body is not an
    // input. Restore only a focus the patch dropped, never a newer selection.
    if (this.readingURL === location.href && this.focusedID && document.activeElement === document.body) {
      const focused = document.getElementById(this.focusedID)
      if (this.el.contains(focused)) focused.focus({preventScroll: true})
    }
    if (this.revealFragment(document.activeElement === document.body)) return
    if (restoreReadingAnchor(this.reading)) return
    if (Number.isFinite(this.scroll)) window.scrollTo({top: this.scroll, behavior: "instant"})
  },
  revealFragment(moveFocus = true) {
    if (!location.hash || this.fragmentURL === location.href) return false
    let id
    try { id = decodeURIComponent(location.hash.slice(1)) } catch (_) { return false }
    const target = document.getElementById(id)
    if (!target || !this.el.contains(target)) return false
    // A connected patch can replace the native browser's initially opened
    // disclosure. Resolve once when this exact target exists, not every refresh.
    for (let node = target; node && node !== this.el; node = node.parentElement) {
      if (node.tagName === "DETAILS") node.open = true
    }
    this.fragmentURL = location.href
    if (moveFocus) {
      target.focus({preventScroll: true})
      target.scrollIntoView({block: "start"})
    }
    return moveFocus
  },
  restoreDrafts() {
    this.el.querySelectorAll("textarea, input[type=text], input[type=search]").forEach(element => {
      const key = draftKey(element)
      if (key && element !== document.activeElement) {
        // A storage failure leaves whatever is already typed in place.
        try {
          transferLegacyDraft(key, sessionStorage)
          const value = sessionStorage.getItem(key)
          if (value !== null) element.value = value
        } catch (_) {}
      }
    })
  },
  destroyed() {
    this.active = false
    this.conversation.destroy()
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("change", this.onInput)
    this.el.removeEventListener("submit", this.onSubmit)
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("keydown", this.onKeydown)
    this.el.removeEventListener("toggle", this.onToggle, true)
    window.removeEventListener("hashchange", this.onHashChange)
  }
}

const csrfToken = document.querySelector("meta[name=csrf-token]").content
const InstructionDraft = {
  mounted() { this.draft = createInstructionDraft(this.el, params => this.pushEventTo(this.el, "edit", params)) },
  updated() { this.draft.sync() },
  destroyed() { this.draft.destroy() }
}
const SettingsDraft = {
  mounted() { this.guard = createSettingsGuard(this.el) },
  destroyed() { this.guard.destroy() }
}
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {PreserveReadingState, InstructionDraft, SettingsDraft, ConversationHistory}
})
liveSocket.connect()
