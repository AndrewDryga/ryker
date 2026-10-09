import {Socket} from "/assets/phoenix.mjs"
import {LiveSocket} from "/assets/phoenix_live_view.esm.js"
import {createReadingStateHook} from "/assets/reading-state.mjs"
import {createInstructionDraft} from "/assets/instruction-draft.mjs"
import {createSettingsGuard} from "/assets/settings-draft.mjs"
import {applyFilterChange} from "/assets/filter-toolbar.mjs"
import {ConversationHistory} from "/assets/history.mjs"
import {FilterMenu} from "/assets/filter-menu.mjs"
import {ElapsedTime} from "/assets/elapsed-time.mjs"
import {RepositoryPicker} from "/assets/repository-picker.mjs"
import {copyValueFromEvent} from "/assets/copy-value.mjs"
import {setupTooltips} from "/assets/tooltips.mjs"
import {setupPromptParts} from "/assets/prompt-parts.mjs"
import {composerDraft} from "/assets/conversation.mjs"
import {createToggleHook, setupPageHelp, wideQuery} from "/assets/page-help.mjs"

// The shell: one LiveView socket and the hooks that keep a reader's place,
// drafts and unsaved edits across patches. Each hook's behaviour lives in its
// own module; this file only wires them to the page.

// Filter toolbars are plain GET forms and work before the socket connects,
// so their dropdowns are handled at the document, not inside the hook.
document.addEventListener("change", applyFilterChange)
document.addEventListener("click", copyValueFromEvent)
setupTooltips()
setupPromptParts()
setupPageHelp(document, window.matchMedia(wideQuery), () => window.localStorage)

const PreserveReadingState = createReadingStateHook()
const InstructionDraft = {
  mounted() { this.draft = createInstructionDraft(this.el, params => this.pushEventTo(this.el, "edit", params)) },
  updated() { this.draft.sync() },
  destroyed() { this.draft.destroy() }
}
// A settings form's component answers whether it took a kept draft back.
const SettingsDraft = {
  mounted() {
    const push = (form, event, payload) => new Promise(resolve => this.pushEventTo(form, event, payload, resolve))
    this.guard = createSettingsGuard(this.el, push)
  },
  destroyed() { this.guard.destroy() }
}
const PageHelp = createToggleHook(document)
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

const csrfToken = document.querySelector("meta[name=csrf-token]").content
const liveSocket = new LiveSocket("/live", Socket, {
  params: () => ({_csrf_token: csrfToken, draft: composerDraft(document)}),
  hooks: {PreserveReadingState, InstructionDraft, SettingsDraft, PageHelp, PrivateKeyFile, RepositoryPicker, ConversationHistory, FilterMenu, ElapsedTime}
})
liveSocket.connect()
