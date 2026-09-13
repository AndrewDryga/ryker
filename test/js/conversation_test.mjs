import {test} from "node:test"
import assert from "node:assert/strict"
import {draftKey} from "../../priv/static/drafts.mjs"
import {conversationFromAction, followSentDraft, fillExample, createConversationControls} from "../../priv/static/conversation.mjs"

// A tiny DOM: enough for closest()/querySelector() on the few controls the
// conversation page has, without a browser. Real rendering is checked in Chromium.
function element(attributes = {}) {
  const node = {
    attributes: {...attributes}, classes: new Set(), dataset: attributes.dataset || {}, children: [],
    focused: 0, open: true, value: "", events: [],
    matches(selector) { return node.selectors?.includes(selector) },
    closest(selector) {
      for (let current = node; current; current = current.parent) if (current.selectors?.includes(selector)) return current
      return null
    },
    setAttribute(name, value) { node.attributes[name] = value },
    getAttribute(name) { return node.attributes[name] ?? null },
    focus() { node.focused++ },
    dispatchEvent(event) { node.events.push(event.type) },
    setSelectionRange(start, end) { node.selection = [start, end] },
    classList: {toggle(name, force) { force ? node.classes.add(name) : node.classes.delete(name) }, contains(name) { return node.classes.has(name) }}
  }
  return node
}

function page(pathname = "/conversations") {
  const root = element(); root.selectors = ["#responder-shell"]
  const directory = element(); directory.selectors = ["#lab-directory"]; directory.parent = root
  const close = element(); close.selectors = ["[data-lab-directory-close]"]; close.parent = directory
  const link = element(); link.selectors = ["a"]; link.parent = directory
  const toggle = element({"aria-expanded": "false"}); toggle.selectors = ["[data-lab-directory-toggle]"]; toggle.parent = root
  const textarea = element(); textarea.selectors = ["#lab-message"]; textarea.parent = root
  const examples = element(); examples.selectors = ["details"]; examples.parent = root
  const example = element({dataset: {example: "Investigate why this service keeps restarting."}})
  example.selectors = [".lab-example"]; example.parent = examples
  const chat = element(); chat.selectors = [".lab-chat"]; chat.parent = root
  const byId = {"#lab-directory": directory, "[data-lab-directory-toggle]": toggle, "#lab-message": textarea}
  root.querySelector = selector => byId[selector] || null
  directory.querySelector = selector => selector === "[data-lab-directory-close]" ? close : null
  const window = {location: {pathname}}
  const controls = createConversationControls(root, {window})
  return {controls, root, directory, close, link, toggle, textarea, examples, example, chat, window}
}

test("the index composer's draft key is stable while its send target changes every visit", () => {
  // The index posts to a fresh identity each time it is opened. Keyed by that
  // action, a draft typed on Monday was unreachable on Tuesday. The form names
  // a stable scope instead; an open conversation still keys by its own action.
  const draft = {getAttribute: () => "/conversations/0f9e8d7c-1234-4abc-8def-0123456789ab/messages", matches: s => s === ".composer", dataset: {draftAction: "new"}}
  const field = {name: "message", tagName: "TEXTAREA", form: draft}
  assert.equal(draftKey(field, "/conversations"), "responder:draft:/conversations:new:message")
  draft.getAttribute = () => "/conversations/ffffffff-1234-4abc-8def-0123456789ab/messages"
  assert.equal(draftKey(field, "/conversations"), "responder:draft:/conversations:new:message")

  const open = {getAttribute: () => "/conversations/0f9e8d7c-1234-4abc-8def-0123456789ab/messages", matches: s => s === ".composer", dataset: {}}
  assert.equal(draftKey({name: "message", tagName: "TEXTAREA", form: open}, "/conversations/0f9e8d7c-1234-4abc-8def-0123456789ab"),
    "responder:draft:/conversations/0f9e8d7c-1234-4abc-8def-0123456789ab:/conversations/0f9e8d7c-1234-4abc-8def-0123456789ab/messages:message")
})

test("only an index draft follows its first accepted send, to the identity its form posted to", () => {
  // The browser keeps the composer it first rendered, so after a reconnect the
  // server's idea of the draft identity is not the one the message went to.
  // Navigation must come from the form's own action, and never from a form
  // that already belongs to an open conversation.
  const pushed = []
  const push = (name, params) => pushed.push([name, params])
  const index = {dataset: {draftAction: "new"}, getAttribute: () => "/conversations/0F9E8D7C-1234-4ABC-8DEF-0123456789AB/messages"}
  assert.equal(followSentDraft(index, push), "0f9e8d7c-1234-4abc-8def-0123456789ab")
  assert.deepEqual(pushed, [["open-conversation", {id: "0f9e8d7c-1234-4abc-8def-0123456789ab"}]])

  const open = {dataset: {}, getAttribute: () => "/conversations/0f9e8d7c-1234-4abc-8def-0123456789ab/messages"}
  assert.equal(followSentDraft(open, push), null)
  const malformed = {dataset: {draftAction: "new"}, getAttribute: () => "/conversations/new/messages"}
  assert.equal(followSentDraft(malformed, push), null)
  assert.equal(pushed.length, 1)
  assert.equal(conversationFromAction("/conversations/../etc/messages"), null)
  assert.equal(conversationFromAction(null), null)
})

test("an example fills an editable draft, keeps typed text, and never sends", () => {
  const f = page()
  assert.equal(f.controls.click({target: f.example}), true)
  assert.equal(f.textarea.value, "Investigate why this service keeps restarting.")
  assert.deepEqual(f.textarea.events, ["input"])
  assert.equal(f.textarea.focused, 1)
  assert.equal(f.examples.open, false)
  assert.deepEqual(f.textarea.selection, [f.textarea.value.length, f.textarea.value.length])

  // Typed text is kept; the example joins it on its own line.
  f.textarea.value = "Context first.  "
  fillExample(f.textarea, "Then the example.")
  assert.equal(f.textarea.value, "Context first.\nThen the example.")
  assert.equal(fillExample(null, "x"), false)
  assert.equal(fillExample(f.textarea, undefined), false)
})

test("the narrow-screen directory opens as a drawer with focus inside, closes on Escape and returns focus", () => {
  // At 390px the old page rendered history as a strip of truncated cards above
  // the chat. The directory is now opened on demand; keyboard users must land
  // inside it and get back to the toggle when it closes.
  const f = page()
  assert.equal(f.controls.click({target: f.toggle}), true)
  assert.equal(f.controls.open, true)
  assert.equal(f.directory.classList.contains("is-open"), true)
  assert.equal(f.toggle.getAttribute("aria-expanded"), "true")
  assert.equal(f.close.focused, 1)

  assert.equal(f.controls.keydown({key: "Escape"}), true)
  assert.equal(f.controls.open, false)
  assert.equal(f.directory.classList.contains("is-open"), false)
  assert.equal(f.toggle.getAttribute("aria-expanded"), "false")
  assert.equal(f.toggle.focused, 1)
  assert.equal(f.controls.keydown({key: "Escape"}), false)

  // The Close button and a click on the backdrop close it too.
  f.controls.click({target: f.toggle}); f.controls.click({target: f.close})
  assert.equal(f.controls.open, false)
  assert.equal(f.toggle.focused, 2)
  f.controls.click({target: f.toggle}); f.controls.click({target: f.chat})
  assert.equal(f.controls.open, false)
  // A click inside the drawer that is not a control keeps it open.
  f.controls.click({target: f.toggle}); f.controls.click({target: f.link})
  assert.equal(f.controls.open, true)
})

test("a live patch keeps the drawer open on the same page and closes it after navigating", () => {
  const f = page("/conversations")
  f.controls.click({target: f.toggle})
  f.directory.classList.toggle("is-open", false)
  f.toggle.setAttribute("aria-expanded", "false")
  f.controls.refresh()
  assert.equal(f.directory.classList.contains("is-open"), true)
  assert.equal(f.toggle.getAttribute("aria-expanded"), "true")

  f.window.location.pathname = "/conversations/0f9e8d7c-1234-4abc-8def-0123456789ab"
  f.controls.refresh()
  assert.equal(f.controls.open, false)
  assert.equal(f.directory.classList.contains("is-open"), false)
  f.controls.destroy()
  assert.equal(f.controls.open, false)
})
