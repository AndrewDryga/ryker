import {test} from "node:test"
import assert from "node:assert/strict"
import {createSettingsGuard} from "../../priv/static/settings-draft.mjs"

function fixture({confirm = () => false} = {}) {
  const handlers = new Map()
  const forms = []
  const root = {querySelectorAll: () => forms.filter(form => form.dirty)}
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
  const guard = createSettingsGuard(root, {document, window})

  function event(link) {
    return {
      target: {closest: () => link},
      defaultPrevented: false,
      button: 0,
      preventDefault() { this.defaultPrevented = true },
      stopImmediatePropagation() { this.stopped = true }
    }
  }

  return {guard, handlers, forms, event, window}
}

test("leaving with an unsaved section asks, and a saved page never does", () => {
  const f = fixture()
  const clean = f.event({href: "http://localhost/channels"})
  f.handlers.get("click")(clean)
  assert.equal(clean.defaultPrevented, false)

  f.forms.push({dirty: true})
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
  f.forms.push({dirty: true})

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
  f.forms.push({dirty: true})
  f.guard.destroy()
  assert.equal(f.handlers.has("click"), false)
  assert.equal(f.handlers.has("beforeunload"), false)
})
