import {test} from "node:test"
import assert from "node:assert/strict"
import {draftKey} from "../../priv/static/drafts.mjs"
import {createConversationControls, validateEdit} from "../../priv/static/conversation.mjs"

// A message article with its hidden inline editor, as the server renders it.
function editableMessage(id, body) {
  const article = {id: `lab-message-${id}`, classes: new Set(), selectors: ["article", ".lab-chat-message"],
    classList: {add(n) { article.classes.add(n) }, remove(n) { article.classes.delete(n) }, toggle(n, f) { f ? article.classes.add(n) : article.classes.delete(n) }, contains(n) { return article.classes.has(n) }}}
  const toggle = {attributes: {"aria-controls": `lab-edit-${id}`, "aria-expanded": "false"}, focused: 0, selectors: [".lab-edit-toggle", "button"], parent: article,
    getAttribute(n) { return this.attributes[n] ?? null }, setAttribute(n, v) { this.attributes[n] = v }, focus() { this.focused++ }}
  const textarea = {name: "message", tagName: "TEXTAREA", value: body, defaultValue: body, focused: 0, scrollHeight: 48, style: {}, selection: null, selectors: ["textarea"], attributes: {},
    setAttribute(n, v) { this.attributes[n] = v }, removeAttribute(n) { delete this.attributes[n] },
    focus() { this.focused++ }, setSelectionRange(a, b) { this.selection = [a, b] }, setCustomValidity() {}, reportValidity() {}}
  const error = {hidden: true, textContent: "", id: `lab-edit-${id}-error`, attributes: {}, setAttribute(n, v) { this.attributes[n] = v }, removeAttribute(n) { delete this.attributes[n] }}
  const save = {disabled: false, attributes: {}, setAttribute(n, v) { this.attributes[n] = v }, removeAttribute(n) { delete this.attributes[n] }}
  const form = {id: `lab-edit-${id}`, hidden: true, dataset: {labEdit: id}, parent: article, selectors: [".lab-edit-form", "form"], isConnected: true,
    action: `http://127.0.0.1/conversations/c/messages/${id}/edit`,
    getAttribute(n) { return n === "action" ? `/conversations/c/messages/${id}/edit` : null },
    matches(s) { return this.selectors.includes(s) },
    querySelector(s) { return ({"textarea": textarea, "textarea[name=message]": textarea, ".lab-edit-error": error, ".lab-edit-save": save})[s] || null },
    elements: [textarea], checkValidity() { return true }}
  textarea.form = form; textarea.parent = form; error.parent = form; save.parent = form
  const cancel = {selectors: [".lab-edit-cancel", "button"], parent: form}
  for (const node of [toggle, textarea, cancel, form, article]) {
    node.closest = function (selector) {
      for (let current = this; current; current = current.parent) if (current.selectors?.includes(selector)) return current
      return null
    }
  }
  article.querySelector = s => s === ".lab-edit-toggle" ? toggle : null
  return {article, toggle, textarea, error, save, form, cancel}
}

function page(messages, {pathname = "/conversations/c"} = {}) {
  const byId = new Map()
  for (const m of messages) { byId.set(m.form.id, m.form); byId.set(m.article.id, m.article) }
  const notices = {children: [], appendChild(n) { this.children.push(n) }, querySelector() { return null }}
  const composer = {name: "message", tagName: "TEXTAREA", value: "composer draft", form: {getAttribute: () => "/conversations/c/messages", matches: s => s === ".composer", dataset: {}}}
  const root = {querySelector: s => s === "#lab-notices" ? notices : s === "#lab-message" ? composer : null,
    contains: () => true}
  const documentStub = {getElementById: id => byId.get(id) || null, activeElement: null, body: {},
    createElement: tag => ({tag, children: [], className: "", textContent: "", attributes: {}, setAttribute(n, v) { this.attributes[n] = v }, appendChild(c) { this.children.push(c); this.textContent += c.textContent }, remove() { this.removed = true }, querySelector: () => null, addEventListener() {}})}
  const store = new Map()
  const storage = {getItem: k => store.has(k) ? store.get(k) : null, setItem: (k, v) => store.set(k, v), removeItem: k => store.delete(k)}
  const fetches = []
  let response = {status: 202, json: async () => ({accepted: true})}
  const fetcher = async (url, options) => { fetches.push({url, options}); if (response instanceof Error) throw response; return response }
  const pushed = []
  const controls = createConversationControls(root, {window: {location: {pathname}}, document: documentStub, storage: () => storage, fetcher, pushEvent: (n, p) => pushed.push([n, p])})
  return {controls, root, documentStub, store, storage, fetches, pushed, notices, composer, byId,
    setResponse(r) { response = r }}
}

const uuid = "0f9e8d7c-1234-4abc-8def-0123456789ab"

test("Edit opens the stored body in place with the caret at the end; Cancel restores it, sends nothing and returns focus", () => {
  // The previous Edit was a <details> disclosure with a second textarea and a
  // "Save edit" button under a duplicated body. Opening must be a local state
  // change only; cancelling must not leave a stale draft or a stray request.
  const m = editableMessage(uuid, "Stored body")
  const f = page([m])
  assert.equal(f.controls.click({target: m.toggle}), true)
  assert.equal(m.form.hidden, false)
  assert.equal(m.article.classList.contains("is-editing"), true)
  assert.equal(m.toggle.getAttribute("aria-expanded"), "true")
  assert.equal(m.textarea.focused, 1)
  assert.deepEqual(m.textarea.selection, ["Stored body".length, "Stored body".length])
  assert.equal(f.store.get("responder:editing:/conversations/c"), uuid)
  assert.equal(f.fetches.length, 0)

  m.textarea.value = "Stored body, changed"
  assert.equal(f.controls.click({target: m.cancel}), true)
  assert.equal(m.form.hidden, true)
  assert.equal(m.textarea.value, "Stored body")
  assert.equal(m.article.classList.contains("is-editing"), false)
  assert.equal(m.toggle.getAttribute("aria-expanded"), "false")
  assert.equal(m.toggle.focused, 1)
  assert.equal(f.store.size, 0)
  assert.equal(f.fetches.length, 0)
  assert.equal(f.pushed.length, 0)
})

test("Escape cancels, Cmd/Ctrl+Enter saves, plain Enter is a newline", async () => {
  const m = editableMessage(uuid, "Body")
  const f = page([m])
  f.controls.click({target: m.toggle})
  let prevented = 0
  const enter = {key: "Enter", target: m.textarea, preventDefault() { prevented++ }}
  assert.equal(f.controls.keydown(enter), false)
  assert.equal(prevented, 0)
  m.textarea.value = "Body changed"
  const save = {key: "Enter", metaKey: true, target: m.textarea, preventDefault() { prevented++ }}
  assert.equal(f.controls.keydown(save), true)
  assert.equal(prevented, 1)
  await new Promise(resolve => setTimeout(resolve, 0))
  assert.equal(f.fetches.length, 1)
  const again = editableMessage(uuid, "Body")
  const g = page([again])
  g.controls.click({target: again.toggle})
  assert.equal(g.controls.keydown({key: "Escape", target: again.textarea}), true)
  assert.equal(again.form.hidden, true)
  assert.equal(again.toggle.focused, 1)
})

test("saving posts one revision to that message's own route and exits only on acceptance", async () => {
  // A second click while the first save is in flight must not create a second
  // revision. Acceptance exits the editor and reconciles through the normal
  // live refresh; the browser never rewrites the transcript itself.
  const m = editableMessage(uuid, "Body")
  const f = page([m])
  f.controls.click({target: m.toggle})
  m.textarea.value = "Body, corrected"
  const event = {target: m.form, preventDefault() { this.prevented = true }}
  const first = f.controls.submit(event)
  const second = f.controls.submit({target: m.form, preventDefault() {}})
  assert.equal(event.prevented, true)
  assert.equal(second, true)
  assert.equal(m.save.disabled, true)
  await first
  assert.equal(f.fetches.length, 1)
  assert.equal(f.fetches[0].url, m.form.getAttribute("action"))
  assert.equal(f.fetches[0].options.method, "POST")
  assert.equal(f.fetches[0].options.headers.Accept, "application/json")
  assert.equal(m.form.hidden, true)
  assert.equal(m.article.classList.contains("is-editing"), false)
  assert.equal(m.save.disabled, false)
  assert.deepEqual(f.pushed, [["refresh", {}]])
  assert.equal(f.store.size, 0)
  assert.equal(m.error.hidden, true)
})

test("a rejected or unconfirmed save keeps the editor open with an actionable error beside the text", async () => {
  for (const [response, expected] of [
    [{status: 409, json: async () => ({})}, /deleted or changed/],
    [{status: 422, json: async () => ({})}, /too long|empty|plain text/],
    [{status: 403, json: async () => ({})}, /could not be confirmed/],
    [new Error("network failed"), /not confirmed/]
  ]) {
    const m = editableMessage(uuid, "Body")
    const f = page([m])
    f.setResponse(response)
    f.controls.click({target: m.toggle})
    m.textarea.value = "Body, corrected"
    await f.controls.submit({target: m.form, preventDefault() {}})
    assert.equal(m.form.hidden, false, "editor stays open")
    assert.equal(m.textarea.value, "Body, corrected", "unsaved text is kept")
    assert.equal(m.error.hidden, false)
    assert.match(m.error.textContent, expected)
    assert.equal(m.textarea.attributes["aria-describedby"], m.error.id)
    assert.equal(m.save.disabled, false)
    assert.equal(f.pushed.length, 0)
  }
})

test("invalid text never leaves the browser", async () => {
  for (const [value, reason] of [["   ", /empty/i], ["x".repeat(20001), /20,000/], ["bad\u0000byte", /null/i]]) {
    const m = editableMessage(uuid, "Body")
    const f = page([m])
    f.controls.click({target: m.toggle})
    m.textarea.value = value
    await f.controls.submit({target: m.form, preventDefault() {}})
    assert.equal(f.fetches.length, 0)
    assert.equal(m.error.hidden, false)
    assert.match(m.error.textContent, reason)
    assert.equal(m.form.hidden, false)
  }
  assert.equal(validateEdit("fine"), "")
})

test("a live patch keeps the open editor and its unsaved text, and a deleted target is reported, not discarded", () => {
  // Every reconcile re-renders the message row. The editor state lives in the
  // browser, so a patch must put it back exactly, and a message that vanished
  // under the operator's cursor must say so and keep what they typed.
  const m = editableMessage(uuid, "Body")
  const f = page([m])
  f.controls.click({target: m.toggle})
  m.textarea.value = "Body, half typed"
  f.controls.input({target: m.textarea})
  // The patch re-rendered the row closed and reset the field to the server text.
  m.form.hidden = true; m.article.classes.clear(); m.toggle.setAttribute("aria-expanded", "false"); m.textarea.value = "Body"
  f.controls.refresh()
  assert.equal(m.form.hidden, false)
  assert.equal(m.article.classList.contains("is-editing"), true)
  assert.equal(m.textarea.value, "Body, half typed")
  assert.equal(m.toggle.getAttribute("aria-expanded"), "true")

  f.byId.delete(m.form.id)
  f.controls.refresh()
  assert.equal(f.notices.children.length, 1)
  assert.match(f.notices.children[0].textContent, /no longer/)
  assert.match(f.notices.children[0].textContent, /Body, half typed/)
  assert.equal(f.store.has("responder:editing:/conversations/c"), false)
  assert.equal(f.controls.editing, null)
})

test("an editor reopens with its draft after a reconnect, without stealing focus", () => {
  const m = editableMessage(uuid, "Body")
  const f = page([m])
  f.store.set("responder:editing:/conversations/c", uuid)
  f.store.set(`responder:draft:/conversations/c:/conversations/c/messages/${uuid}/edit:message`, "Body, from before the reconnect")
  f.controls.restore()
  assert.equal(m.form.hidden, false)
  assert.equal(m.textarea.value, "Body, from before the reconnect")
  assert.equal(m.textarea.focused, 0)
})

test("edit drafts are keyed by message and never share the composer's key", () => {
  const m = editableMessage(uuid, "Body")
  assert.equal(draftKey(m.textarea, "/conversations/c"), `responder:draft:/conversations/c:/conversations/c/messages/${uuid}/edit:message`)
  const other = editableMessage("11111111-2222-4333-8444-555555555555", "Other")
  assert.notEqual(draftKey(other.textarea, "/conversations/c"), draftKey(m.textarea, "/conversations/c"))
  const composer = {name: "message", tagName: "TEXTAREA", form: {getAttribute: () => "/conversations/c/messages", matches: s => s === ".composer", dataset: {}}}
  assert.notEqual(draftKey(composer, "/conversations/c"), draftKey(m.textarea, "/conversations/c"))
})
