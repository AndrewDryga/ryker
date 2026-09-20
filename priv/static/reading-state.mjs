import {draftKey as keyFor} from "./drafts.mjs"
import {createRelearnPicker} from "./relearn-selection.mjs"
import {createConversationControls} from "./conversation.mjs"
import {createComposer} from "./composer.mjs"
import {captureReadingAnchor, restoreReadingAnchor} from "./history.mjs"

// The shell hook: what a reader had open, typed, focused and scrolled to
// survives every LiveView patch, and a fragment in the URL is revealed once.
// The environment is the page's globals unless a test supplies its own.
export function createReadingStateHook(environment = {}) {
  const doc = environment.document || document
  const win = environment.window || window
  const loc = environment.location || location
  const storage = environment.storage || (() => sessionStorage)
  const draftKey = element => element.closest?.("form[phx-change]") ? null : keyFor(element, loc.pathname)

  return {
    mounted() {
      this.active = true
      this.restoreDrafts()
      this.relearnPicker = createRelearnPicker(this.el, storage)
      const pushEvent = (name, params) => this.pushEvent(name, params)
      this.conversation = createConversationControls(this.el, {storage, pushEvent})
      this.conversation.restore()
      this.handleEvent?.("lab-action-accepted", detail => this.conversation.accept(detail))
      this.handleEvent?.("lab-action-rejected", detail => this.conversation.reject(detail))
      this.composer = createComposer({pushEvent, active: () => this.active, storage, location: loc})
      this.onInput = event => {
        this.relearnPicker.change(event)
        this.conversation.input(event)
        this.composer.input(event)
        const key = draftKey(event.target)
        if (key) {
          try { storage().setItem(key, event.target.value) } catch (_) { /* Storage can be disabled. */ }
        }
      }
      this.onSubmit = event => {
        if (this.conversation.submit(event)) return
        this.composer.submit(event)
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
      win.addEventListener("hashchange", this.onHashChange)
      this.revealFragment()
    },
    beforeUpdate() {
      this.readingURL = loc.href
      this.focusedID = this.el.contains(doc.activeElement) ? doc.activeElement.id : null
      this.expanded = Array.from(this.el.querySelectorAll("details")).map((node, index) => ({
        key: node.id || `${index}:${node.querySelector("summary")?.textContent}`, open: node.open
      }))
      this.scroll = win.scrollY
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
      if (this.readingURL === loc.href && this.focusedID && doc.activeElement === doc.body) {
        const focused = doc.getElementById(this.focusedID)
        if (this.el.contains(focused)) focused.focus({preventScroll: true})
      }
      if (this.revealFragment(doc.activeElement === doc.body)) return
      if (restoreReadingAnchor(this.reading)) return
      if (Number.isFinite(this.scroll)) win.scrollTo({top: this.scroll, behavior: "instant"})
    },
    revealFragment(moveFocus = true) {
      if (!loc.hash || this.fragmentURL === loc.href) return false
      let id
      try { id = decodeURIComponent(loc.hash.slice(1)) } catch (_) { return false }
      const target = doc.getElementById(id)
      if (!target || !this.el.contains(target)) return false
      // A connected patch can replace the native browser's initially opened
      // disclosure. Resolve once when this exact target exists, not every refresh.
      for (let node = target; node && node !== this.el; node = node.parentElement) {
        if (node.tagName === "DETAILS") node.open = true
      }
      this.fragmentURL = loc.href
      if (moveFocus) {
        target.focus({preventScroll: true})
        target.scrollIntoView({block: "start"})
      }
      return moveFocus
    },
    restoreDrafts() {
      this.el.querySelectorAll("textarea, input[type=text], input[type=search]").forEach(element => {
        const key = draftKey(element)
        if (key && element !== doc.activeElement) {
          // A storage failure leaves whatever is already typed in place.
          try {
            const value = storage().getItem(key)
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
      win.removeEventListener("hashchange", this.onHashChange)
    }
  }
}
