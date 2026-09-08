import {Socket} from "/assets/phoenix.mjs"
import {LiveSocket} from "/assets/phoenix_live_view.esm.js"
import {draftKey as keyFor, captureDrafts, acceptDrafts, sendDraft, validateDraft} from "/assets/drafts.mjs"
import {createRelearnPicker} from "/assets/relearn-selection.mjs"
const draftKey = element => element.closest?.("form[phx-change]") ? null : keyFor(element, location.pathname)

const PreserveReadingState = {
  mounted() {
    this.active = true
    this.restoreDrafts()
    this.relearnPicker = createRelearnPicker(this.el, () => sessionStorage)
    this.onInput = event => {
      this.relearnPicker.change(event)
      if (event.target.form?.matches(".composer")) event.target.form.querySelector("textarea")?.setCustomValidity("")
      const key = draftKey(event.target)
      if (key) {
        try { sessionStorage.setItem(key, event.target.value) } catch (_) { /* Storage can be disabled. */ }
      }
    }
    this.onSubmit = async event => {
      const form = event.target
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
    this.onClick = event => {
      this.relearnPicker.click(event)
      const choice = event.target.closest?.("#card-state-picker a")
      if (choice) choice.closest("details").open = false
    }
    this.el.addEventListener("click", this.onClick)
    this.onKeydown = event => {
      if (event.key === "Enter" && (event.metaKey || event.ctrlKey) && event.target.matches(".composer textarea")) {
        event.preventDefault()
        event.target.closest("form").requestSubmit()
      }
    }
    this.el.addEventListener("keydown", this.onKeydown)
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
    this.following = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 48
  },
  updated() {
    const expanded = new Map((this.expanded || []).map(item => [item.key, item.open]))
    this.el.querySelectorAll("details").forEach((node, index) => {
      const key = node.id || `${index}:${node.querySelector("summary")?.textContent}`
      if (expanded.has(key)) node.open = expanded.get(key)
    })
    this.restoreDrafts()
    this.relearnPicker.refresh()
    // LiveView restores input focus, but a replaced response body is not an
    // input. Restore only a focus the patch dropped, never a newer selection.
    if (this.readingURL === location.href && this.focusedID && document.activeElement === document.body) {
      const focused = document.getElementById(this.focusedID)
      if (this.el.contains(focused)) focused.focus({preventScroll: true})
    }
    if (this.revealFragment(document.activeElement === document.body)) return
    if (this.following && location.pathname.startsWith("/lab/")) {
      window.scrollTo({top: document.documentElement.scrollHeight, behavior: "instant"})
    } else if (Number.isFinite(this.scroll)) {
      window.scrollTo({top: this.scroll, behavior: "instant"})
    }
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
        try {
          const value = sessionStorage.getItem(key)
          if (value !== null) element.value = value
        } catch (_) {}
      }
    })
  },
  destroyed() {
    this.active = false
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("change", this.onInput)
    this.el.removeEventListener("submit", this.onSubmit)
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("keydown", this.onKeydown)
    window.removeEventListener("hashchange", this.onHashChange)
  }
}

const csrfToken = document.querySelector("meta[name=csrf-token]").content
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {PreserveReadingState}
})
liveSocket.connect()
