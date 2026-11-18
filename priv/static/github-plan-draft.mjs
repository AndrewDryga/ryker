import {dropDraft, keepDraft, pruneDrafts} from "./draft-store.mjs"

// The workflow UUID scopes drafts to the repository identity, not its reusable name.
export function keepPlanDraft(plan, implement, notice, recovery, storage = () => sessionStorage) {
  const save = plan.form?.querySelector?.("[data-save-plan]")
  const key = `ryker:draft:github-plan:${plan.dataset.workflowId}`
  const saved = plan.dataset.savedPlan
  const planId = plan.dataset.planId
  let older = null
  let storageFailed = false
  const discard = () => {
    older = null
    plan.readOnly = false
    if (recovery) recovery.hidden = true
    try { dropDraft(storage(), key) } catch (_) { storageFailed = true }
  }
  const sync = () => {
    const changed = plan.value !== saved
    try {
      if (older) keepDraft(storage(), key, JSON.stringify(older))
      else if (changed) keepDraft(storage(), key, JSON.stringify({planId, text: plan.value, baseline: saved}))
      else if (!older) dropDraft(storage(), key)
    } catch (_) { storageFailed = true }
    if (implement) implement.disabled = changed || older !== null
    if (save) save.disabled = !changed || older !== null
    notice.textContent = older
      ? "Review the unsaved draft below. Use or discard it before editing the current saved plan."
      : changed ? "Save your edits as a new version before implementing them."
      : "Implement plan starts this saved version."
    if ((changed || older !== null) && storageFailed) notice.textContent += " This tab cannot retain edits across sign-in. Copy your text before leaving."
  }
  const serverDraft = recovery?.querySelector("[data-recovered-plan]").dataset?.serverDraft
  let draft = null
  try {
    pruneDrafts(storage())
    draft = JSON.parse(storage().getItem(key))
  } catch (_) { /* Storage is optional; server-side plan versions remain authoritative. */ }
  if (serverDraft && serverDraft !== saved) draft = {planId: "unreviewed", baseline: "", text: serverDraft}
  if (draft && typeof draft.text === "string" && typeof draft.planId === "string") {
    if (draft.text === saved) discard() // Acknowledged save, including its new version.
    else if (draft.planId === planId && draft.baseline === saved) plan.value = draft.text
    else {
      older = draft
      plan.readOnly = true
      if (recovery) {
        recovery.hidden = false
        recovery.querySelector("[data-recovered-plan]").textContent = draft.text
      }
    }
  }
  if (recovery) {
    recovery.querySelector("[data-use-plan-draft]").addEventListener("click", () => {
      plan.value = older.text
      discard()
      sync()
      plan.focus()
    })
    recovery.querySelector("[data-discard-plan-draft]").addEventListener("click", () => {
      discard()
      sync()
    })
  }
  plan.addEventListener("input", sync)
  plan.form?.addEventListener("submit", sync)
  sync()
}
