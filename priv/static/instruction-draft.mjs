import {adoptRetiredKey} from "./drafts.mjs"
import {createLeaveGuard} from "./leave-guard.mjs"

const normalize = text => text.trim() === "" ? "" : text.replaceAll("\r\n", "\n")

// Per-tab drafts protect back navigation and reconnection without changing browser history.
// The original revision travels with the draft so recovery cannot bypass the server's CAS.
export function createInstructionDraft(form, recover, environment = {}) {
  const storage = environment.storage || (() => sessionStorage)
  const key = `ryker:instruction-draft:${form.dataset.scope}`
  const text = () => form.querySelector("textarea")
  const revision = () => form.querySelector("input[name=revision]")
  const dirty = () => normalize(text().value) !== form.dataset.savedText
  function sync() {
    try {
      if (dirty()) storage().setItem(key, JSON.stringify({text: text().value, revision: revision().value}))
      else storage().removeItem(key)
    } catch (_) { /* Saving remains possible when browser storage is disabled. */ }
  }
  try {
    // Remove after 2026-09-20: carries a draft stored under the pre-rename
    // key (2026-09-13); a tab open since before then has closed by that date.
    adoptRetiredKey(key, storage())
    const saved = JSON.parse(storage().getItem(key))
    if (saved && typeof saved.text === "string" && /^\d+$/.test(saved.revision)) {
      text().value = saved.text
      revision().value = saved.revision
      recover(saved)
    }
  } catch (_) { /* An unavailable or stale browser draft cannot block the editor. */ }
  form.addEventListener("input", sync)
  const guard = createLeaveGuard({dirty, message: "Leave without saving these instructions?", beforeUnload: sync}, environment)
  return {sync, destroy() {
    sync()
    form.removeEventListener("input", sync)
    guard.destroy()
  }}
}
