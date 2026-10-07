import {test} from "node:test"
import assert from "node:assert/strict"
import {createSettingsGuard} from "../../priv/static/settings-draft.mjs"

function memoryStorage() {
  const map = new Map()
  return {map, getItem: key => map.has(key) ? map.get(key) : null, setItem: (key, value) => map.set(key, String(value)),
    removeItem: key => map.delete(key)}
}

// A settings form as SettingsEditor renders it: whether it is changed, where
// its draft is kept, and what the draft began from.
function settingsForm({draft = "settings:work", dirty = false, revision = "7", baseline = "began-7", elements} = {}) {
  return {
    dataset: {draft, dirty: String(dirty), revision, baseline},
    elements: elements || [
      {name: "workspace_ref", type: "select-one", value: "personal"},
      {name: "ready_routing_sessions", type: "number", value: "3"}
    ]
  }
}

function fixture({forms = [], confirm = () => false, reply = () => Promise.resolve({restored: true}), storage = memoryStorage()} = {}) {
  const handlers = new Map()
  const rootListeners = new Map()
  const root = {
    querySelectorAll: selector => ({
      "form[data-dirty=true]": forms.filter(form => form.dataset.dirty === "true"),
      "form[data-draft]": forms.filter(form => form.dataset.draft)
    })[selector] || [],
    addEventListener: (event, fn) => rootListeners.set(event, fn),
    removeEventListener: event => rootListeners.delete(event)
  }
  const document = {
    addEventListener: (event, fn) => handlers.set(event, fn),
    removeEventListener: event => handlers.delete(event)
  }
  const window = {
    location: {href: "http://localhost/integrations/slack"},
    confirm,
    addEventListener: (event, fn) => handlers.set(event, fn),
    removeEventListener: event => handlers.delete(event)
  }
  let observed = null
  class MutationObserver {
    constructor(callback) { observed = callback }
    observe() {}
    disconnect() { observed = null }
  }
  const pushed = []
  const push = (form, event, payload) => { pushed.push({form, event, payload}); return reply(form) }
  const guard = createSettingsGuard(root, push, {document, window, storage: () => storage, MutationObserver})

  function event(link) {
    return {
      target: {closest: () => link},
      defaultPrevented: false,
      button: 0,
      preventDefault() { this.defaultPrevented = true },
      stopImmediatePropagation() { this.stopped = true }
    }
  }

  return {guard, handlers, rootListeners, forms, event, window, pushed, storage,
    mutate: records => observed(records), get observing() { return observed !== null }}
}

const kept = storage => JSON.parse(storage.getItem("ryker:settings-draft:settings:work"))
const settled = () => new Promise(resolve => setImmediate(resolve))

test("leaving with an unsaved section asks, and a saved page never does", () => {
  const f = fixture()
  const clean = f.event({href: "http://localhost/channels"})
  f.handlers.get("click")(clean)
  assert.equal(clean.defaultPrevented, false)

  f.forms.push(settingsForm({dirty: true}))
  const dirty = f.event({href: "http://localhost/channels"})
  f.handlers.get("click")(dirty)
  assert.equal(dirty.defaultPrevented, true)
  assert.equal(dirty.stopped, true)

  const unload = f.event()
  f.handlers.get("beforeunload")(unload)
  assert.equal(unload.defaultPrevented, true)
})

test("an accepted confirmation, an in-page anchor and a new tab are not blocked", () => {
  const f = fixture({confirm: () => true})
  f.forms.push(settingsForm({dirty: true}))

  const accepted = f.event({href: "http://localhost/channels"})
  f.handlers.get("click")(accepted)
  assert.equal(accepted.defaultPrevented, false)

  const anchor = f.event({href: "http://localhost/integrations/slack#new-channels"})
  f.handlers.get("click")(anchor)
  assert.equal(anchor.defaultPrevented, false)

  const tab = f.event({href: "http://localhost/channels", target: "_blank"})
  f.handlers.get("click")(tab)
  assert.equal(tab.defaultPrevented, false)
})

test("the guard stops watching once the page is destroyed", () => {
  const f = fixture()
  f.forms.push(settingsForm({dirty: true}))
  f.guard.destroy()
  assert.equal(f.handlers.has("click"), false)
  assert.equal(f.handlers.has("beforeunload"), false)
  assert.equal(f.rootListeners.has("input"), false)
  assert.equal(f.observing, false)
})

// LiveView handles Back and server-side navigation itself, so the guard never
// asked before they threw a settings form's unsaved values away; those lived
// only in the form's component (2026-10-04 review).
test("a changed settings form is kept while its page is away and offered back when it shows again", async () => {
  const storage = memoryStorage()
  const form = settingsForm()
  const away = fixture({forms: [form], storage})

  // The component answers the first change by marking the form changed.
  form.dataset.dirty = "true"
  away.mutate([{type: "attributes", target: form, oldValue: "false"}])
  assert.deepEqual(kept(storage), {revision: "7", baseline: "began-7", form: "workspace_ref=personal&ready_routing_sessions=3"})

  // Typing changes no markup, so each keystroke is kept as it lands.
  form.elements[1].value = "4"
  away.rootListeners.get("input")({target: {form}})
  assert.equal(kept(storage).form, "workspace_ref=personal&ready_routing_sessions=4")
  away.guard.destroy()

  // Back again: the form shows unchanged, and its component gets the draft.
  const shown = settingsForm({revision: "9", baseline: "began-9"})
  const back = fixture({forms: [shown], storage})
  assert.equal(back.pushed.length, 1)
  assert.equal(back.pushed[0].form, shown)
  assert.equal(back.pushed[0].event, "restore")
  assert.deepEqual(back.pushed[0].payload, {revision: "7", baseline: "began-7", form: "workspace_ref=personal&ready_routing_sessions=4"})

  // Offered once per showing, not on every patch.
  back.mutate([])
  assert.equal(back.pushed.length, 1)
  await settled()
  assert.notEqual(storage.getItem("ryker:settings-draft:settings:work"), null)
})

test("a draft its form did not take back is dropped, and one that never got an answer stays", async () => {
  const storage = memoryStorage()
  storage.setItem("ryker:settings-draft:settings:work", JSON.stringify({revision: "7", baseline: "b", form: "x=1"}))

  fixture({forms: [settingsForm()], storage, reply: () => new Promise(() => {})})
  await settled()
  assert.notEqual(storage.getItem("ryker:settings-draft:settings:work"), null)

  fixture({forms: [settingsForm()], storage, reply: () => Promise.resolve({restored: false})})
  await settled()
  assert.equal(storage.getItem("ryker:settings-draft:settings:work"), null)
})

test("a changed form never offers a kept draft over what is typed in it", () => {
  const storage = memoryStorage()
  storage.setItem("ryker:settings-draft:settings:work", JSON.stringify({revision: "7", baseline: "b", form: "x=1"}))
  const f = fixture({forms: [settingsForm({dirty: true})], storage})
  assert.equal(f.pushed.length, 0)
})

test("a saved, cancelled or typed-back form drops its draft", () => {
  const storage = memoryStorage()
  const form = settingsForm({dirty: true})
  const f = fixture({forms: [form], storage})
  assert.notEqual(storage.getItem("ryker:settings-draft:settings:work"), null)

  form.dataset.dirty = "false"
  f.mutate([{type: "attributes", target: form, oldValue: "true"}])
  assert.equal(storage.getItem("ryker:settings-draft:settings:work"), null)
})

test("leaving through the guard's question discards the draft, as the question says", () => {
  const storage = memoryStorage()
  const f = fixture({forms: [settingsForm({dirty: true})], storage, confirm: () => true})
  assert.notEqual(storage.getItem("ryker:settings-draft:settings:work"), null)

  f.handlers.get("click")(f.event({href: "http://localhost/settings/prices"}))
  assert.equal(storage.getItem("ryker:settings-draft:settings:work"), null)
})

test("a kept draft holds the fields the form would send, and never a password", () => {
  const storage = memoryStorage()
  const elements = [
    {name: "name", type: "text", value: "alerts"},
    {name: "token", type: "password", value: "never-kept"},
    {name: "enabled", type: "checkbox", value: "true", checked: false},
    {name: "accepting", type: "checkbox", value: "true", checked: true},
    {name: "labels[]", type: "select-multiple", multiple: true, selectedOptions: [{value: "service"}, {value: "team"}]},
    {name: "off", type: "text", value: "x", disabled: true},
    {name: "", type: "submit", value: "Save"}
  ]
  fixture({forms: [settingsForm({dirty: true, elements})], storage})
  assert.equal(kept(storage).form, "name=alerts&accepting=true&labels%5B%5D=service&labels%5B%5D=team")
})
