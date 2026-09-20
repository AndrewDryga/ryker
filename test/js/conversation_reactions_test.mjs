import {test} from "node:test"
import assert from "node:assert/strict"
import {createConversationControls, normalizeEmojiName} from "../../priv/static/conversation.mjs"

// A reply's reactions row, as the server renders it: the pills, then the
// add-reaction trigger and its anchored picker at the end of the same row.
// Real layout is checked in Chromium.
function node(selectors, extra = {}) {
  const value = {selectors, attributes: {}, dataset: {}, disabled: false, focused: 0, hidden: false, children: [],
    getAttribute(n) { return this.attributes[n] ?? null }, setAttribute(n, v) { this.attributes[n] = v },
    removeAttribute(n) { delete this.attributes[n] }, focus() { this.focused++ },
    matches(s) { return this.selectors.includes(s) },
    closest(selector) {
      for (let current = this; current; current = current.parent) if (current.selectors?.includes(selector)) return current
      return null
    },
    querySelector(s) { return this.lookup?.[s] || null },
    querySelectorAll(s) { return this.lookupAll?.[s] || [] },
    ...extra}
  return value
}

function form(selectors, action, emoji, {parent, extra = {}} = {}) {
  const f = node(selectors, {isConnected: true, ...extra})
  const actionField = {name: "action", value: action}
  const emojiField = node(["input[name=emoji]"], {name: "emoji", value: emoji, tagName: "INPUT"})
  emojiField.form = f; emojiField.parent = f
  const token = {name: "_token", value: "tok"}
  const button = node(["button"], {tagName: "BUTTON", type: "submit"})
  button.parent = f
  f.elements = [token, actionField, emojiField, button]
  f.lookup = {"input[name=emoji]": emojiField, "input[name=action]": actionField, "button[type=submit]": button}
  f.lookupAll = {button: [button]}
  f.parent = parent
  return Object.assign(f, {emojiField, actionField, button})
}

function reply(reactions = []) {
  const path = "/conversations/c/replies/control-plane-message%3Ar/reactions"
  const article = node(["article", ".lab-chat-message"], {path, id: "lab-message-r"})
  const row = node([".lab-reactions"]); row.parent = article
  const pills = node([".lab-reaction-pills"], {path}); pills.parent = row
  const pillForms = reactions.map(([emoji, mine]) => {
    const f = form([".lab-reaction-form", ".lab-reaction-pill", "form"], mine ? "remove" : "add", emoji, {parent: pills})
    f.button.selectors.push(".lab-reaction-pill-button"); f.button.setAttribute("aria-pressed", mine ? "true" : "false")
    return f
  })
  const toggle = node([".lab-reaction-toggle", "button"], {tagName: "BUTTON"}); toggle.parent = row
  toggle.setAttribute("aria-controls", "lab-reaction-picker-r"); toggle.setAttribute("aria-expanded", "false")
  row.lookup = {".lab-reaction-toggle": toggle}
  const picker = node([".lab-reaction-picker"], {id: "lab-reaction-picker-r", hidden: true, path}); picker.parent = row
  const quick = form([".lab-reaction-form", ".lab-reaction-quick", "form"], "add", "+1", {parent: picker})
  const custom = form([".lab-reaction-form", ".lab-reaction-custom", "form"], "add", "", {parent: picker})
  custom.emojiField.selectors.push("input"); custom.emojiField.value = ""
  const error = node([".lab-reaction-error"], {hidden: true, textContent: "", id: "lab-reaction-picker-r-error"}); error.parent = custom
  custom.lookup[".lab-reaction-error"] = error
  custom.lookupAll = {button: [custom.button]}
  picker.lookup = {".lab-reaction-quick button, .lab-reaction-custom input[name=emoji]": quick.button, "button": quick.button, ".lab-reaction-custom": custom, ".lab-reaction-error": error}
  return {article, row, pills, pillForms, toggle, picker, quick, custom, error, path}
}

function page(r, {response = {status: 202, json: async () => ({accepted: true})}} = {}) {
  const byId = new Map([[r.picker.id, r.picker], [r.article.id, r.article]])
  const notices = {children: [], textContent: "", appendChild(n) { this.children.push(n); this.textContent += n.textContent }}
  const composer = {value: "composer draft", form: {}}
  const root = {querySelector: s => ({"#lab-notices": notices, "#lab-message": composer})[s] || null}
  const documentStub = {getElementById: id => byId.get(id) || null, activeElement: null, body: {},
    createElement: () => ({children: [], className: "", textContent: "", attributes: {}, setAttribute(n, v) { this.attributes[n] = v }, appendChild(c) { this.children.push(c); this.textContent += c.textContent }, addEventListener() {}})}
  const fetches = []
  let current = response
  const fetcher = async (url, options) => { fetches.push({url, options}); if (current instanceof Error) throw current; return current }
  const pushed = []
  const store = new Map()
  const storage = {getItem: k => store.has(k) ? store.get(k) : null, setItem: (k, v) => store.set(k, v), removeItem: k => store.delete(k)}
  const controls = createConversationControls(root, {window: {location: {pathname: "/conversations/c"}}, document: documentStub, storage: () => storage, fetcher, pushEvent: (n, p) => pushed.push([n, p])})
  return {controls, fetches, pushed, notices, composer, setResponse(v) { current = v }}
}

test("the add-reaction control opens one anchored picker with focus inside; Escape and outside clicks close it and return focus", () => {
  // The previous UI showed five permanent emoji buttons and a Custom emoji
  // disclosure under every reply. The picker now opens on demand from one
  // labelled control and keyboard users can get in and back out of it.
  const r = reply()
  const f = page(r)
  assert.equal(f.controls.click({target: r.toggle}), true)
  assert.equal(r.picker.hidden, false)
  assert.equal(r.toggle.getAttribute("aria-expanded"), "true")
  assert.equal(r.quick.button.focused, 1)
  assert.equal(f.controls.keydown({key: "Escape", target: r.quick.button}), true)
  assert.equal(r.picker.hidden, true)
  assert.equal(r.toggle.getAttribute("aria-expanded"), "false")
  assert.equal(r.toggle.focused, 1)

  f.controls.click({target: r.toggle})
  assert.equal(f.controls.click({target: node(["div"], {parent: null})}), true)
  assert.equal(r.picker.hidden, true)
  f.controls.click({target: r.toggle}); f.controls.click({target: r.toggle})
  assert.equal(r.picker.hidden, true)
  assert.equal(f.composer.value, "composer draft")
  assert.equal(f.fetches.length, 0)
})

test("clicking a pill leaves the exact add/remove mutation to LiveView, once", () => {
  const r = reply([["heart", true], ["+1", false]])
  const f = page(r)
  const [mine, theirs] = r.pillForms
  assert.equal(f.controls.submit({target: mine, preventDefault() {}}), false)
  const duplicate = {target: mine, preventDefault() { this.prevented = true }}
  assert.equal(f.controls.submit(duplicate), true)
  assert.equal(duplicate.prevented, true)
  assert.equal(mine.dataset.pending, "true")
  assert.equal(mine.actionField.value, "remove")
  f.controls.accept({kind: "reaction", id: "control-plane-message:r"})
  assert.equal(mine.dataset.pending, undefined)
  assert.equal(f.fetches.length, 0)
  assert.deepEqual(f.pushed, [])

  assert.equal(f.controls.submit({target: theirs, preventDefault() {}}), false)
  assert.equal(theirs.actionField.value, "add")
  assert.equal(theirs.emojiField.value, "+1")
  assert.equal(f.composer.value, "composer draft")
})

test("a quick choice closes the picker only on LiveView acceptance", () => {
  const r = reply()
  const f = page(r)
  f.controls.click({target: r.toggle})
  assert.equal(f.controls.submit({target: r.quick, preventDefault() {}}), false)
  assert.equal(r.picker.hidden, false)
  f.controls.accept({kind: "reaction", id: "control-plane-message:r"})
  assert.equal(r.picker.hidden, true)
  assert.equal(r.toggle.focused, 1)
  assert.equal(f.fetches.length, 0)

  const denied = reply()
  const g = page(denied)
  g.controls.click({target: denied.toggle})
  assert.equal(g.controls.submit({target: denied.quick, preventDefault() {}}), false)
  g.controls.reject({kind: "reaction", id: "control-plane-message:r", reason: "conflict"})
  assert.equal(denied.picker.hidden, false, "a denied reaction does not pretend to succeed")
  assert.equal(denied.error.hidden, false)
  assert.match(denied.error.textContent, /no longer|not accept/)
  assert.equal(g.pushed.length, 0)
})

test("a custom name is normalized, validated beside its field, and keeps what was typed on denial", () => {
  assert.equal(normalizeEmojiName(" :White_Check_Mark: "), "white_check_mark")
  assert.equal(normalizeEmojiName("+1"), "+1")
  assert.equal(normalizeEmojiName(""), "")

  const r = reply()
  const f = page(r)
  f.controls.click({target: r.toggle})
  r.custom.emojiField.value = "not valid!"
  f.controls.submit({target: r.custom, preventDefault() {}})
  assert.equal(f.fetches.length, 0)
  assert.equal(r.error.hidden, false)
  assert.match(r.error.textContent, /letters, digits/)
  assert.equal(r.custom.emojiField.getAttribute("aria-invalid"), "true")

  r.custom.emojiField.value = ":Rocket_Launch:"
  assert.equal(f.controls.submit({target: r.custom, preventDefault() {}}), false)
  assert.equal(f.fetches.length, 0)
  f.controls.accept({kind: "reaction", id: "control-plane-message:r"})
  assert.equal(r.custom.emojiField.value, "", "an accepted custom name clears the field")
  assert.equal(r.picker.hidden, true)

  const denied = reply()
  const g = page(denied)
  g.controls.click({target: denied.toggle})
  denied.custom.emojiField.value = "unknown_name"
  assert.equal(g.controls.submit({target: denied.custom, preventDefault() {}}), false)
  g.controls.reject({kind: "reaction", id: "control-plane-message:r", reason: "invalid"})
  assert.equal(denied.custom.emojiField.value, "unknown_name")
  assert.equal(denied.error.hidden, false)
  assert.match(denied.error.textContent, /not accept/)
  assert.equal(denied.picker.hidden, false)
  assert.equal(g.pushed.length, 0)
})

test("a live patch keeps an open picker open and a navigation closes it", () => {
  const r = reply()
  const f = page(r)
  f.controls.click({target: r.toggle})
  r.picker.hidden = true; r.toggle.setAttribute("aria-expanded", "false")
  f.controls.refresh()
  assert.equal(r.picker.hidden, false)
  assert.equal(r.toggle.getAttribute("aria-expanded"), "true")
  f.controls.destroy()
  assert.equal(r.picker.hidden, true)
})
