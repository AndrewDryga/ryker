import {test} from "node:test"
import assert from "node:assert/strict"
import {createPendingForms} from "../../priv/static/pending.mjs"

// A minimal DOM: elements with attributes, a dataset and text, a form that
// finds its submit buttons, and a window that records its listeners.
function element(tagName, attributes = {}, text = "") {
  const attrs = new Map(Object.entries(attributes))
  return {
    tagName, textContent: text, dataset: {}, disabled: false,
    getAttribute: name => attrs.has(name) ? attrs.get(name) : null,
    setAttribute: (name, value) => attrs.set(name, String(value)),
    removeAttribute: name => attrs.delete(name),
    hasAttribute: name => attrs.has(name),
    attrs
  }
}

function form(buttons, attributes = {}) {
  const node = element("FORM", attributes)
  node.querySelectorAll = () => buttons
  return node
}

function submit(target, submitter, defaultPrevented = false) {
  return {target, submitter, defaultPrevented, preventDefault() { this.defaultPrevented = true }}
}

function environment(forms = []) {
  const listeners = {}
  return {
    window: {addEventListener: (name, fn) => { listeners[name] = fn }, removeEventListener: name => delete listeners[name]},
    document: {querySelectorAll: () => forms.filter(node => node.dataset.pending === "true")},
    listeners
  }
}

// Andrew, 2026-10-15: confirming Went well left the page looking as if the
// click had not registered while the request was on its way.
test("a form the browser submits says at once that it is on its way, and refuses a second submit", () => {
  const confirm = element("BUTTON", {type: "submit", "phx-disable-with": "Working…"}, "Went well")
  const other = element("BUTTON", {type: "submit"}, "Needs work")
  const node = form([confirm, other])
  const pending = createPendingForms(environment([node]))

  const first = submit(node, confirm)
  pending.onSubmit(first)

  assert.equal(first.defaultPrevented, false, "the first submit goes to the server")
  assert.equal(node.dataset.pending, "true")
  assert.equal(node.getAttribute("aria-busy"), "true")
  assert.equal(confirm.textContent, "Working…")
  assert.equal(confirm.getAttribute("aria-disabled"), "true")
  assert.equal(other.getAttribute("aria-disabled"), "true", "a competing button cannot start another")

  for (const again of [submit(node, confirm), submit(node, other), submit(node, null)]) {
    pending.onSubmit(again)
    assert.equal(again.defaultPrevented, true, "a second click, Enter or Space sends nothing")
  }
})

// The browser builds what a form sends after its submit event: a disabled
// button would leave out its own name and value.
test("the button pressed still goes with the form: nothing is disabled", () => {
  const confirm = element("BUTTON", {type: "submit", name: "choice", value: "good", "phx-disable-with": "Saving…"}, "Save")
  const node = form([confirm])

  createPendingForms(environment([node])).onSubmit(submit(node, confirm))

  assert.equal(confirm.disabled, false)
  assert.equal(confirm.getAttribute("name"), "choice")
  assert.equal(confirm.getAttribute("value"), "good")
})

test("a LiveView form, or one another script took, is left to its owner", () => {
  const button = element("BUTTON", {type: "submit", "phx-disable-with": "Saving…"}, "Save")
  const node = form([button])

  createPendingForms(environment([node])).onSubmit(submit(node, button, true))

  assert.equal(node.dataset.pending, undefined)
  assert.equal(button.textContent, "Save")
  assert.equal(button.hasAttribute("aria-disabled"), false)
})

test("a form that opens in another tab leaves this page as it was", () => {
  const button = element("BUTTON", {type: "submit"}, "Export")
  const node = form([button], {target: "_blank"})

  createPendingForms(environment([node])).onSubmit(submit(node, button))

  assert.equal(node.dataset.pending, undefined)
})

// Back and forward restore the page from the browser's cache exactly as it
// was left, pending buttons and all; it shows its forms as before the submit.
test("a page restored from the back/forward cache shows its forms as they were", () => {
  const confirm = element("BUTTON", {type: "submit", "phx-disable-with": "Working…"}, "Confirm")
  const unavailable = element("BUTTON", {type: "submit", "aria-disabled": "true"}, "Not yet")
  const node = form([confirm, unavailable])
  const env = environment([node])
  const pending = createPendingForms(env)
  pending.onSubmit(submit(node, confirm))

  pending.onPageShow({persisted: false})
  assert.equal(node.dataset.pending, "true", "a fresh load leaves a page alone")

  pending.onPageShow({persisted: true})
  assert.equal(node.dataset.pending, undefined)
  assert.equal(node.hasAttribute("aria-busy"), false)
  assert.equal(confirm.textContent, "Confirm")
  assert.equal(confirm.hasAttribute("aria-disabled"), false)
  assert.equal(unavailable.getAttribute("aria-disabled"), "true", "a button that was unavailable stays so")

  const again = submit(node, confirm)
  pending.onSubmit(again)
  assert.equal(again.defaultPrevented, false, "and it can be submitted again")
})

test("starting listens for submits and page restores on the window; stopping lets go", () => {
  const env = environment()
  const pending = createPendingForms(env)

  pending.start()
  assert.deepEqual(Object.keys(env.listeners).sort(), ["pageshow", "submit"])

  pending.stop()
  assert.deepEqual(Object.keys(env.listeners), [])
})
