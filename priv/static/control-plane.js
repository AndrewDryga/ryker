import {Socket} from "/assets/phoenix.mjs"
import {LiveSocket} from "/assets/phoenix_live_view.esm.js"
import {createReadingStateHook} from "/assets/reading-state.mjs"
import {createInstructionDraft} from "/assets/instruction-draft.mjs"
import {createSettingsGuard} from "/assets/settings-draft.mjs"
import {applyFilterChange} from "/assets/filter-toolbar.mjs"
import {ConversationHistory} from "/assets/history.mjs"
import {FilterMenu} from "/assets/filter-menu.mjs"

// The shell: one LiveView socket and the hooks that keep a reader's place,
// drafts and unsaved edits across patches. Each hook's behaviour lives in its
// own module; this file only wires them to the page.

// Filter toolbars are plain GET forms and work before the socket connects,
// so their dropdowns are handled at the document, not inside the hook.
document.addEventListener("change", applyFilterChange)

const PreserveReadingState = createReadingStateHook()
const InstructionDraft = {
  mounted() { this.draft = createInstructionDraft(this.el, params => this.pushEventTo(this.el, "edit", params)) },
  updated() { this.draft.sync() },
  destroyed() { this.draft.destroy() }
}
const SettingsDraft = {
  mounted() { this.guard = createSettingsGuard(this.el) },
  destroyed() { this.guard.destroy() }
}
const PrivateKeyFile = {
  mounted() {
    this.read = async () => {
      const file = this.el.files && this.el.files[0]
      const target = document.getElementById(this.el.dataset.target)
      if (!file || !target || file.size > 1024 * 1024) return
      target.value = await file.text()
      target.dispatchEvent(new Event("input", {bubbles: true}))
    }
    this.el.addEventListener("change", this.read)
  },
  destroyed() { this.el.removeEventListener("change", this.read) }
}
const RepositorySearch = {
  mounted() {
    this.filter = () => {
      const query = this.el.value.trim().toLowerCase()
      this.el.closest("form").querySelectorAll("[data-repository-name]").forEach(row => {
        row.hidden = query !== "" && !row.dataset.repositoryName.toLowerCase().includes(query)
      })
    }
    this.el.addEventListener("input", this.filter)
  },
  destroyed() { this.el.removeEventListener("input", this.filter) }
}

const csrfToken = document.querySelector("meta[name=csrf-token]").content
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {PreserveReadingState, InstructionDraft, SettingsDraft, PrivateKeyFile, RepositorySearch, ConversationHistory, FilterMenu}
})
liveSocket.connect()
