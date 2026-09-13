import {test} from "node:test"
import assert from "node:assert/strict"
import {createInstructionDraft} from "../../priv/static/instruction-draft.mjs"

function fixture(store = new Map(), scope = "global", saved = "Saved", revision = "1") {
  const handlers = new Map(), recovered = []
  const input = {value: saved}, version = {value: revision}
  const form = {dataset: {savedText: saved, scope},
    querySelector: selector => selector === "textarea" ? input : version,
    addEventListener: (event, fn) => handlers.set(`form:${event}`, fn),
    removeEventListener: event => handlers.delete(`form:${event}`)}
  const document = {addEventListener: (event, fn) => handlers.set(event, fn), removeEventListener: event => handlers.delete(event)}
  const window = {location: {href: "http://localhost/instructions"}, confirm: () => false,
    addEventListener: (event, fn) => handlers.set(event, fn), removeEventListener: event => handlers.delete(event)}
  const storage = {getItem: key => store.get(key) ?? null, setItem: (key, value) => store.set(key, value), removeItem: key => store.delete(key)}
  const guard = createInstructionDraft(form, params => recovered.push(params), {document, window, storage: () => storage})
  function event(link) {
    return {target: {closest: () => link}, defaultPrevented: false, button: 0,
      preventDefault() { this.defaultPrevented = true }, stopImmediatePropagation() { this.stopped = true }}
  }
  return {guard, input, version, form, handlers, recovered, store, event,
    type(text) { input.value = text; handlers.get("form:input")() }}
}

test("unsaved navigation and unload are guarded until a save or cancel is acknowledged", () => {
  const f = fixture()
  const clean = f.event({href: "http://localhost/channels"})
  f.handlers.get("click")(clean)
  assert.equal(clean.defaultPrevented, false)
  f.type("Unsaved")
  const dirty = f.event({href: "http://localhost/channels"})
  f.handlers.get("click")(dirty)
  assert.equal(dirty.defaultPrevented, true)
  assert.equal(dirty.stopped, true)
  const unload = f.event()
  f.handlers.get("beforeunload")(unload)
  assert.equal(unload.defaultPrevented, true)
  f.form.dataset.savedText = "Unsaved"
  f.guard.sync()
  assert.equal(f.store.size, 0)
  const saved = f.event({href: "http://localhost/channels"})
  f.handlers.get("click")(saved)
  assert.equal(saved.defaultPrevented, false)
  f.guard.destroy()
  assert.equal(f.handlers.size, 0)
})

// The product was renamed on 2026-09-13; an instruction draft typed before the
// rename sits under the retired key and must come back exactly once, with its
// original revision, so the server's CAS still applies to it.
test("an instruction draft saved before the rename is restored once under the current key", () => {
  const store = new Map([["responder:instruction-draft:global", JSON.stringify({text: "Typed before the rename", revision: "1"})]])
  const f = fixture(store, "global", "A newer saved version", "2")
  assert.deepEqual(f.recovered, [{text: "Typed before the rename", revision: "1"}])
  assert.equal(f.input.value, "Typed before the rename")
  assert.equal(store.has("responder:instruction-draft:global"), false)
  assert.equal(store.has("ryker:instruction-draft:global"), true)
  f.input.value = "A newer saved version"
  f.guard.sync()
  assert.equal(store.size, 0)
})

test("returning after back navigation or reconnect restores the draft with its original revision", () => {
  const f = fixture()
  f.type("My original draft")
  f.guard.destroy()
  const anotherScope = fixture(f.store, "slack:T:C")
  assert.equal(anotherScope.recovered.length, 0)
  const reopened = fixture(f.store, "global", "A newer saved version", "2")
  assert.deepEqual(reopened.recovered, [{text: "My original draft", revision: "1"}])
  assert.equal(reopened.input.value, "My original draft")
  assert.equal(reopened.version.value, "1")
  reopened.input.value = "A newer saved version"
  reopened.guard.sync()
  assert.equal(f.store.size, 0)
})
