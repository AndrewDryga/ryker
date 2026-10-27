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

function confirmationPage(storage = new Map(), path = "/working-copies") {
  const opener = element("BUTTON", {type: "submit"}, "Discard unmerged")
  opener.focus = options => { opener.focusOptions = options }
  const opening = form([opener], {action: "/actions/retention/workspace:unmerged/discard"})
  opening.matches = selector => selector === ".action-control"
  opening.querySelector = () => opener
  const row = element("ARTICLE", {id: "copy-unmerged", tabindex: "-1"})
  row.id = "copy-unmerged"
  row.focus = options => { row.focusOptions = options }
  opening.closest = selector => selector === ".entity-row" ? row : null
  const confirm = element("BUTTON", {type: "submit"}, "Discard unmerged")
  const modal = form([confirm], {action: "/actions/retention/workspace:unmerged/discard", method: "post"})
  modal.matches = selector => selector === ".kit-modal-form"
  const env = environment([opening, modal])
  const scrolled = []
  env.window.location = new URL(`http://127.0.0.1:4321${path}`)
  env.window.scrollY = 1800
  env.window.scrollX = 0
  env.window.scrollTo = options => scrolled.push(options)
  env.window.sessionStorage = {getItem: key => storage.get(key) ?? null,
    setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key)}
  env.document.querySelectorAll = selector => selector === ".action-control" ? [opening] : selector === ".entity-row" ? [row] : []
  env.document.querySelector = () => null
  return {env, storage, opening, opener, row, modal, confirm, scrolled}
}

// October 27: every confirmed cleanup navigated back to the top of a long
// working-copy list. The live patch scroll guard cannot see a native POST/303.
test("confirming a modal keeps the reader's position and initiating control after the redirect", () => {
  const before = confirmationPage()
  const pending = createPendingForms(before.env)
  pending.onSubmit(submit(before.opening, before.opener, true))
  const confirmed = submit(before.modal, before.confirm)
  pending.onSubmit(confirmed)
  assert.equal(confirmed.defaultPrevented, false, "the protected form still goes to its original owner")
  assert.equal(before.storage.size, 1)

  const after = confirmationPage(before.storage)
  createPendingForms(after.env).start()
  assert.deepEqual(after.scrolled, [{left: 0, top: 1800, behavior: "instant"}])
  assert.deepEqual(after.opener.focusOptions, {preventScroll: true})
  assert.equal(after.storage.size, 0, "the restore is consumed once, not on later visits")
})

// Cleanup removes its button before it removes the row. Without a fallback,
// the next Tab started at the sidebar and jumped right back to the top.
test("a cleanup whose button disappears restores keyboard focus to its non-destructive row", () => {
  const before = confirmationPage()
  const pending = createPendingForms(before.env)
  pending.onSubmit(submit(before.opening, before.opener, true))
  pending.onSubmit(submit(before.modal, before.confirm))
  const after = confirmationPage(before.storage)
  after.env.document.querySelectorAll = selector => selector === ".entity-row" ? [after.row] : []
  createPendingForms(after.env).start()
  assert.equal(after.scrolled[0].top, 1800)
  assert.equal(after.opener.focusOptions, undefined)
  assert.deepEqual(after.row.focusOptions, {preventScroll: true})
})

test("a removed working copy restores focus to the neighboring row, never its destructive control", () => {
  const before = confirmationPage()
  const pending = createPendingForms(before.env)
  pending.onSubmit(submit(before.opening, before.opener, true))
  pending.onSubmit(submit(before.modal, before.confirm))
  const after = confirmationPage(before.storage)
  after.row.id = "copy-next"
  after.env.document.querySelectorAll = selector => selector === ".entity-row" ? [after.row] : []
  createPendingForms(after.env).start()
  assert.equal(after.scrolled[0].top, 1800)
  assert.equal(after.opener.focusOptions, undefined)
  assert.deepEqual(after.row.focusOptions, {preventScroll: true})
})

test("a row without an id restores by its place, not the first idless row", () => {
  const before = confirmationPage()
  before.row.id = ""
  const first = {id: ""}
  first.focus = options => { first.focusOptions = options }
  before.env.document.querySelectorAll = () => [first, before.row]
  const pending = createPendingForms(before.env)
  pending.onSubmit(submit(before.opening, before.opener, true))
  pending.onSubmit(submit(before.modal, before.confirm))
  const after = confirmationPage(before.storage)
  after.row.id = ""
  after.env.document.querySelectorAll = selector => selector === ".entity-row" ? [first, after.row] : []
  createPendingForms(after.env).start()
  assert.deepEqual(after.row.focusOptions, {preventScroll: true})
  assert.equal(first.focusOptions, undefined)
})

test("cancelling a modal never leaves a scroll restore for a later visit", () => {
  const page = confirmationPage()
  createPendingForms(page.env).onSubmit(submit(page.opening, page.opener, true))
  assert.equal(page.storage.size, 0)
})

test("a different live page consumes a confirmation position without scrolling", () => {
  for (const path of ["/activity", "/working-copies?view=removed"]) {
    const before = confirmationPage()
    createPendingForms(before.env).onSubmit(submit(before.modal, before.confirm))
    const after = confirmationPage(before.storage, path)
    createPendingForms(after.env).start()
    assert.deepEqual(after.scrolled, [])
    assert.equal(after.storage.size, 0, "a different live page must not leave a position for a later visit")
  }
})

test("returning from a static refusal keeps the original list position without scrolling the refusal", () => {
  const before = confirmationPage()
  createPendingForms(before.env).onSubmit(submit(before.modal, before.confirm))
  // Layouts.static/sign_in have no browser script. Do not pretend they start
  // this listener: the saved position stays until the next live page or expiry.
  const refusal = confirmationPage(before.storage, "/actions/retention/workspace:unmerged/discard")
  assert.deepEqual(refusal.scrolled, [])
  assert.equal(refusal.storage.size, 1)
  const returned = confirmationPage(refusal.storage)
  createPendingForms(returned.env).start()
  assert.equal(returned.scrolled[0].top, 1800)
  assert.equal(returned.storage.size, 0)
})

test("unavailable browser storage never stops a confirmed action", () => {
  const page = confirmationPage()
  page.env.window.sessionStorage = {getItem() { throw Error("blocked") }, setItem() { throw Error("blocked") }}
  const pending = createPendingForms(page.env)
  pending.start()
  const confirmed = submit(page.modal, page.confirm)
  pending.onSubmit(confirmed)
  assert.equal(confirmed.defaultPrevented, false)
  assert.equal(page.modal.dataset.pending, "true")
})

test("expired, malformed and different-filter positions are discarded without scrolling", () => {
  for (const invalid of ["{", "null", JSON.stringify({page: "/working-copies", top: 1800, left: 0, at: 0}),
    JSON.stringify({page: "/working-copies", top: "1800", left: 0, at: Date.now()}),
    JSON.stringify({page: "/working-copies?q=old", top: 1800, left: 0, at: Date.now()})]) {
    const page = confirmationPage()
    createPendingForms(page.env).onSubmit(submit(page.modal, page.confirm))
    const [key] = page.storage.keys()
    page.storage.set(key, invalid)
    createPendingForms(page.env).start()
    assert.deepEqual(page.scrolled, [])
    assert.equal(page.storage.size, 0)
  }
})
