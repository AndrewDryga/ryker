import {dropDraft, keepDraft} from "./draft-store.mjs"
import {createLeaveGuard} from "./leave-guard.mjs"

// An unsaved settings form lives in its component's state on the server. The
// leave guard asks before a link or an unload discards it, but LiveView
// handles Back and server-side navigation itself, and those discarded it
// without a word (2026-10-04 review). So a changed form is also kept in the
// tab's session storage, with the revision and saved values it began from,
// and offered back to its component when the form shows again unchanged; the
// component decides whether it still fits (`Ryker.ControlPlane.FormDraft`).
// The forms report whether they are changed; this never decides it. Leaving
// through the guard's question discards, as the question says.
export function createSettingsGuard(root, push, environment = {}) {
  const storage = environment.storage || (() => sessionStorage)
  const Observer = environment.MutationObserver || globalThis.MutationObserver
  const dirty = () => root.querySelectorAll("form[data-dirty=true]").length > 0
  const drafted = () => Array.from(root.querySelectorAll("form[data-draft]"))
  const key = form => `ryker:settings-draft:${form.dataset.draft}`
  const offered = new WeakSet()

  // The fields as the form would send them; a password never leaves the page.
  const fields = form => {
    const data = new URLSearchParams()
    for (const field of Array.from(form.elements || [])) {
      if (!field.name || field.disabled || ["password", "file", "submit", "button", "reset"].includes(field.type)) continue
      if (["checkbox", "radio"].includes(field.type) && !field.checked) continue
      if (field.multiple && field.selectedOptions) {
        for (const option of Array.from(field.selectedOptions)) data.append(field.name, option.value)
      } else {
        data.append(field.name, field.value)
      }
    }
    return data.toString()
  }

  const keep = form => {
    const kept = {revision: form.dataset.revision, baseline: form.dataset.baseline, form: fields(form)}
    try { keepDraft(storage(), key(form), JSON.stringify(kept)) } catch (_) { /* The guard still asks. */ }
  }

  const drop = form => {
    try { dropDraft(storage(), key(form)) } catch (_) {}
  }

  // Once each time a form shows: a kept draft goes back to an unchanged form.
  // A draft its component did not take, because it reads the same as what is
  // saved, is dropped; one that never got an answer stays.
  const offer = form => {
    if (offered.has(form)) return
    offered.add(form)
    if (form.dataset.dirty === "true") return
    let kept = null
    try { kept = JSON.parse(storage().getItem(key(form))) } catch (_) { return }
    if (!kept || typeof kept.form !== "string") return
    Promise.resolve(push(form, "restore", kept)).then(reply => {
      if (reply?.restored === false) drop(form)
    }, () => {})
  }

  const sync = () => {
    for (const form of drafted()) {
      offer(form)
      if (form.dataset.dirty === "true") keep(form)
    }
  }

  // A changed form becoming unchanged was saved, cancelled or typed back to
  // what is saved; its draft goes.
  const observer = Observer && new Observer(records => {
    for (const record of records) {
      const form = record.target
      if (record.type === "attributes" && record.oldValue === "true" && form.dataset?.draft &&
          form.dataset.dirty !== "true") drop(form)
    }
    sync()
  })
  observer?.observe(root, {subtree: true, childList: true, attributes: true,
    attributeFilter: ["data-dirty"], attributeOldValue: true})

  // Typing changes no markup, so each keystroke in a changed form is kept here.
  const input = event => {
    const form = event.target?.form
    if (form?.dataset?.draft && form.dataset.dirty === "true") keep(form)
  }
  root.addEventListener("input", input)

  const discard = () => {
    for (const form of drafted()) if (form.dataset.dirty === "true") drop(form)
  }
  const guard = createLeaveGuard({dirty, message: "Leave without saving these settings?", discard}, environment)
  sync()

  return {dirty, sync, destroy() {
    observer?.disconnect()
    root.removeEventListener("input", input)
    guard.destroy()
  }}
}
