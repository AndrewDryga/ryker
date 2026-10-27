import {Socket} from "./phoenix.mjs"
import {LiveSocket} from "./phoenix_live_view.esm.js"
import {createReadingStateHook} from "./reading-state.mjs"
import {createInstructionDraft} from "./instruction-draft.mjs"
import {createSettingsGuard} from "./settings-draft.mjs"
import {applyFilterChange} from "./filter-toolbar.mjs"
import {ConversationHistory} from "./history.mjs"
import {FilterMenu} from "./filter-menu.mjs"
import {ScheduleCountdown} from "./schedule-countdown.mjs"
import {ElapsedTime} from "./elapsed-time.mjs"
import {RepositoryPicker} from "./repository-picker.mjs"
import {copyValueFromEvent} from "./copy-value.mjs"
import {markOutboundFromEvent} from "./outbound-links.mjs"
import {setupTooltips} from "./tooltips.mjs"
import {setupPromptParts} from "./prompt-parts.mjs"
import {composerDraft} from "./conversation.mjs"
import {createToggleHook, setupPageHelp, wideQuery} from "./page-help.mjs"
import {createPendingForms} from "./pending.mjs"

// The shell: one LiveView socket and the hooks that keep a reader's place,
// drafts and unsaved edits across patches. Each hook's behaviour lives in its
// own module; this file only wires them to the page.

// Filter toolbars are plain GET forms and work before the socket connects,
// so their dropdowns are handled at the document, not inside the hook.
document.addEventListener("change", applyFilterChange)
document.addEventListener("click", copyValueFromEvent)
document.addEventListener("click", event => markOutboundFromEvent(event))
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
  params: () => ({_csrf_token: csrfToken, asset_bundle: new URL(import.meta.url).pathname, draft: composerDraft(document)}),
  hooks: {PreserveReadingState, InstructionDraft, SettingsDraft, PageHelp, PrivateKeyFile, RepositoryPicker, ConversationHistory, FilterMenu, ElapsedTime, ScheduleCountdown}
})
liveSocket.connect()
// After connect, so LiveView sees a submit first and its own forms stay its own.
createPendingForms().start()
