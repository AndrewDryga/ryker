import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import vm from "node:vm"
import {keepPlanDraft} from "../../priv/static/github-plan-draft.mjs"

const source = readFileSync(new URL("../../priv/static/github-actions.mjs", import.meta.url), "utf8").replace(/^import .*\n/gm, "")

test("review selection refuses zero and oversized runs, then recovers when reduced", () => {
  let selected = 21
  const listeners = new Map()
  const button = {}, count = {}
  const form = {
    dataset: {prNumber: "42", selectionLimit: "20"},
    querySelector: selector => selector === "[data-fix-selected]" ? button : count,
    querySelectorAll: () => Array.from({length: selected}),
    addEventListener: (event, callback) => listeners.set(event, callback)
  }
  vm.runInNewContext(source, {keepPlanDraft, document: {querySelectorAll: () => [form], querySelector: () => null}})
  assert.equal(button.disabled, true)
  assert.match(count.textContent, /Choose at most 20/)
  selected = 20
  listeners.get("change")()
  assert.equal(button.disabled, false)
  assert.equal(button.textContent, "Fix 20 findings in PR #42")
  selected = 0
  listeners.get("change")()
  assert.equal(button.disabled, true)
})

test("editing a saved plan while work runs does not require an implement button", () => {
  const listeners = new Map()
  const notice = {}
  const plan = {value: "Saved plan", dataset: {savedPlan: "Saved plan"},
    addEventListener: (event, callback) => listeners.set(event, callback)}
  vm.runInNewContext(source, {keepPlanDraft, document: {querySelectorAll: () => [], querySelector: selector =>
    ({"textarea[data-saved-plan]": plan, "[data-plan-edit-notice]": notice, "[data-implement-plan]": null})[selector]}})
  plan.value = "Edited plan"
  listeners.get("input")()
  assert.match(notice.textContent, /Save your edits/)
})

function draftPage(store, {id = "plan-one", saved = "Saved plan", workflow = "workflow-one", serverDraft = ""} = {}) {
  const listeners = new Map(), clicks = new Map(), submit = new Map()
  const notice = {}, implement = {}, recovered = {dataset: {serverDraft}}
  const recovery = {hidden: true, querySelector: selector => selector === "[data-recovered-plan]" ? recovered : {
    addEventListener: (_, callback) => clicks.set(selector, callback)
  }}
  const plan = {value: saved, dataset: {savedPlan: saved, planId: id, workflowId: workflow},
    focus() {}, form: {addEventListener: (event, callback) => submit.set(event, callback)},
    addEventListener: (event, callback) => listeners.set(event, callback)}
  keepPlanDraft(plan, implement, notice, recovery, () => store)
  return {plan, implement, notice, recovery, recovered, edit(value) {
    plan.value = value; listeners.get("input")()
  }, submit() {submit.get("submit")()}, click(selector) {clicks.get(selector)()}}
}
function draftStorage() {
  const values = new Map()
  return {get length() {return values.size}, key(index) {return [...values.keys()][index]},
    getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value),
    removeItem: key => values.delete(key)}
}

test("plan edits survive an expired sign-in and disappear only after acknowledged save", () => {
  const store = draftStorage()
  const first = draftPage(store)
  first.edit("My edited plan")
  first.submit()
  const signedInAgain = draftPage(store)
  assert.equal(signedInAgain.plan.value, "My edited plan")
  assert.equal(signedInAgain.implement.disabled, true)
  const saved = draftPage(store, {id: "plan-two", saved: "My edited plan"})
  assert.equal(saved.implement.disabled, false)
  assert.equal(store.getItem("ryker:draft:github-plan:workflow-one"), null)
})

test("a newer saved plan stays intact until the earlier draft is explicitly recovered", () => {
  const store = draftStorage()
  draftPage(store).edit("Older unsaved edits")
  const updated = draftPage(store, {id: "plan-two", saved: "New saved plan"})
  assert.equal(updated.plan.value, "New saved plan")
  assert.equal(updated.recovered.textContent, "Older unsaved edits")
  assert.equal(updated.recovery.hidden, false)
  assert.equal(updated.implement.disabled, true)
  updated.click("[data-use-plan-draft]")
  assert.equal(updated.plan.value, "Older unsaved edits")
  assert.equal(updated.implement.disabled, true)
  assert.match(updated.notice.textContent, /Save your edits/)
  assert.equal(draftPage(store, {workflow: "other-repository"}).plan.value, "Saved plan")
})

test("discarding a stale draft restores the current plan action without losing the saved plan", () => {
  const store = draftStorage()
  draftPage(store).edit("Old edits")
  const updated = draftPage(store, {id: "plan-two", saved: "New plan"})
  updated.click("[data-discard-plan-draft]")
  assert.equal(updated.plan.value, "New plan")
  assert.equal(updated.implement.disabled, false)
  assert.equal(updated.recovery.hidden, true)
})


test("a rejected POST keeps stale submitted text separate from the current saved plan", () => {
  const store = draftStorage()
  draftPage(store).edit("Earlier edits")
  const rejected = draftPage(store, {id: "plan-two", saved: "New saved plan", serverDraft: "Submitted old edits"})
  assert.equal(rejected.plan.value, "New saved plan")
  assert.equal(rejected.plan.readOnly, true)
  assert.equal(rejected.recovered.textContent, "Submitted old edits")
  // Even a synthetic input cannot overwrite an unresolved recovery draft.
  rejected.edit("Unreviewed replacement")
  const refreshed = draftPage(store, {id: "plan-two", saved: "New saved plan"})
  assert.equal(refreshed.recovered.textContent, "Submitted old edits")
  assert.equal(refreshed.plan.value, "New saved plan")
  refreshed.click("[data-use-plan-draft]")
  assert.equal(refreshed.plan.readOnly, false)
  assert.equal(refreshed.plan.value, "Submitted old edits")
})


test("unavailable tab storage warns before a recovery draft can be lost", () => {
  const denied = {getItem() {throw Error("denied")}, setItem() {throw Error("denied")}}
  const page = draftPage(denied, {id: "plan-two", saved: "Current plan", serverDraft: "Recover me"})
  assert.match(page.notice.textContent, /Copy your text before leaving/)
  assert.equal(page.recovered.textContent, "Recover me")
})
