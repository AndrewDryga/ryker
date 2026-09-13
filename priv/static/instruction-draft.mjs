import {adoptRetiredKey} from "./drafts.mjs"

const normalize = text => text.trim() === "" ? "" : text.replaceAll("\r\n", "\n")

// Per-tab drafts protect back navigation and reconnection without changing browser history.
// The original revision travels with the draft so recovery cannot bypass the server's CAS.
export function createInstructionDraft(form, recover, environment = {}) {
  const doc = environment.document || document
  const win = environment.window || window
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
  function click(event) {
    const link = event.target.closest?.("a[href]")
    if (!link || event.defaultPrevented || event.button > 0 || event.metaKey || event.ctrlKey ||
        event.shiftKey || event.altKey || link.target === "_blank" || link.download || !dirty()) return
    const target = new URL(link.href, win.location.href)
    if (target.href.split("#")[0] === win.location.href.split("#")[0]) return
    if (!win.confirm("Leave without saving these instructions?")) {
      event.preventDefault()
      event.stopImmediatePropagation()
    }
  }
  function unload(event) {
    if (!dirty()) return
    sync()
    event.preventDefault()
    event.returnValue = ""
  }
  try {
    adoptRetiredKey(key, storage())
    const saved = JSON.parse(storage().getItem(key))
    if (saved && typeof saved.text === "string" && /^\d+$/.test(saved.revision)) {
      text().value = saved.text
      revision().value = saved.revision
      recover(saved)
    }
  } catch (_) { /* An unavailable or stale browser draft cannot block the editor. */ }
  form.addEventListener("input", sync)
  doc.addEventListener("click", click, true)
  win.addEventListener("beforeunload", unload)
  return {sync, destroy() {
    sync()
    form.removeEventListener("input", sync)
    doc.removeEventListener("click", click, true)
    win.removeEventListener("beforeunload", unload)
  }}
}
