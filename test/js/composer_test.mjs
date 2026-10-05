import {test} from "node:test"
import assert from "node:assert/strict"
import {createComposer} from "../../priv/static/composer.mjs"

// The composer form as the server renders it: the message, the file field
// described by its error slot, the status line and Send. Real layout is
// checked in Chromium.
function composer(options = {}) {
  const attributes = {}
  const error = {hidden: true, textContent: "", dataset: {}}
  const status = {hidden: true, textContent: "", dataset: {}}
  const button = {disabled: false}
  const attached = {textContent: ""}
  const textarea = {value: "", validity: "", reported: 0,
    setCustomValidity(message) { this.validity = message }, reportValidity() { this.reported++ }}
  const files = {type: "file", files: [], disabled: false,
    setAttribute(name, value) { attributes[name] = value }, removeAttribute(name) { delete attributes[name] }}
  const form = {
    action: "/conversations/00000000-0000-0000-0000-000000000000/messages",
    dataset: {},
    elements: [],
    isConnected: true,
    matches: selector => selector === ".composer",
    checkValidity: () => true,
    querySelector: selector => ({
      "textarea": textarea, "textarea[name=message]": textarea, "input[type=file]": files,
      ".composer-error": error, ".composer-status": status, "button[type=submit]": button,
      ".lab-attached": attached
    })[selector] ?? null
  }
  const root = {querySelectorAll: selector => selector === "form.composer" ? [form] : []}
  textarea.form = form
  files.form = form
  const controls = createComposer({
    pushEvent() {}, active: () => true, storage: () => ({}),
    location: {pathname: "/conversations"}, ...options
  })
  return {controls, form, root, textarea, files, error, status, button, attributes, attached}
}

test("Send is off until there is something to send, and back off once it is sent", async () => {
  // QA 2026-09-25: Send looked ready over an empty box, so the only answer to
  // pressing it was a validation bubble.
  const c = composer()
  c.controls.refresh(c.root)
  assert.equal(c.button.disabled, true)

  c.textarea.value = "  "
  c.controls.input({target: c.textarea})
  assert.equal(c.button.disabled, true)

  c.textarea.value = "Why is checkout slow?"
  c.controls.input({target: c.textarea})
  assert.equal(c.button.disabled, false)

  c.textarea.value = ""
  c.files.files = [{name: "trace.log", size: 1}]
  c.controls.input({target: c.files})
  assert.equal(c.button.disabled, false)

  // A draft restored from storage after a patch counts as something to send.
  c.files.files = []
  c.textarea.value = "Restored draft"
  c.controls.refresh(c.root)
  assert.equal(c.button.disabled, false)

  const OriginalFormData = globalThis.FormData
  const originalFetch = globalThis.fetch
  globalThis.FormData = class FormData {}
  globalThis.fetch = async () => ({status: 202, json: async () => ({accepted: true})})

  try {
    c.controls.submit({target: c.form, defaultPrevented: false, preventDefault() {}})
    await new Promise(resolve => setTimeout(resolve, 0))
    // The accepted draft left the box, so Send is off again rather than on.
    c.textarea.value = ""
    c.controls.refresh(c.root)
    assert.equal(c.button.disabled, true)
  } finally {
    globalThis.FormData = OriginalFormData
    globalThis.fetch = originalFetch
  }
})

test("chosen files are named beside Attach files instead of the browser's own label", () => {
  // QA 2026-09-25: the browser's "No file chosen" sat beside Attach files. The
  // native field is hidden; the composer names what was chosen, and nothing
  // when nothing was.
  const c = composer()
  c.files.files = [{name: "trace.log", size: 1}, {name: "graph.png", size: 1}]
  c.controls.input({target: c.files})
  assert.equal(c.attached.textContent, "trace.log, graph.png")

  c.files.files = []
  c.controls.input({target: c.files})
  assert.equal(c.attached.textContent, "")
})

test("a file choice that breaks a limit is explained beside the composer at once and cleared once fixed", () => {
  // Andrew, 2026-09-19: the composer printed "Up to 2 files · 8 MiB" under
  // every draft and only complained on Send. Now nothing is printed until a
  // choice breaks a limit, and then the reason appears as the files are picked.
  const c = composer()
  c.files.files = [{size: 1}, {size: 1}, {size: 1}]
  c.controls.input({target: c.files})
  assert.equal(c.error.hidden, false)
  assert.match(c.error.textContent, /at most 2/)
  assert.equal(c.error.dataset.tone, "error")
  assert.equal(c.attributes["aria-invalid"], "true")

  c.files.files = [{size: 1}]
  c.controls.input({target: c.files})
  assert.equal(c.error.hidden, true)
  assert.equal(c.error.textContent, "")
  assert.equal(c.attributes["aria-invalid"], undefined)
})

test("a confirmed message clears transient status instead of congratulating the sender", async () => {
  // Andrew, 2026-09-20: the accepted message already appears in the transcript.
  // A second green "Message saved" banner duplicated that proof and pushed the
  // composer around after every normal send.
  const OriginalFormData = globalThis.FormData
  const originalFetch = globalThis.fetch
  globalThis.FormData = class FormData {}
  globalThis.fetch = async () => ({status: 202, json: async () => ({accepted: true})})

  try {
    const c = composer()
    c.textarea.value = "Hello"
    c.controls.submit({target: c.form, defaultPrevented: false, preventDefault() {}})

    await new Promise(resolve => setTimeout(resolve, 0))

    assert.equal(c.status.hidden, true)
    assert.equal(c.status.textContent, "")
  } finally {
    globalThis.FormData = OriginalFormData
    globalThis.fetch = originalFetch
  }
})

test("sending files over the limit is refused in place with the same reason and no request", () => {
  const c = composer()
  c.textarea.value = "Please look at these"
  c.files.files = [{size: 9 * 1024 * 1024}]
  let prevented = false
  const handled = c.controls.submit({target: c.form, defaultPrevented: false, preventDefault() { prevented = true }})
  assert.equal(handled, true)
  assert.equal(prevented, true)
  assert.equal(c.error.hidden, false)
  assert.match(c.error.textContent, /8 MiB/)
  assert.equal(c.error.dataset.tone, "error")
  assert.equal(c.button.disabled, false, "no send started")
  assert.equal(c.status.hidden, true)
  assert.equal(c.textarea.reported, 0, "the file problem is not reported on the message field")
})

// A message sent with files takes a moment to save. Opening another
// conversation meanwhile detached the form, the confirmed send then cleared
// nothing, and coming back restored the sent message as a draft that Send
// posted a second time (2026-10-04 review).
test("a send confirmed after the page was left clears its stored draft", async () => {
  const stored = new Map()
  const store = {
    getItem: key => stored.get(key) ?? null,
    setItem: (key, value) => stored.set(key, value),
    removeItem: key => stored.delete(key)
  }
  const c = composer({storage: () => store})
  c.textarea.name = "message"
  c.textarea.tagName = "TEXTAREA"
  c.textarea.value = "Deploy the fix"
  c.form.elements = [c.textarea]
  c.form.getAttribute = () => c.form.action
  const key = `ryker:draft:/conversations:${c.form.action}:message`
  stored.set(key, "Deploy the fix")

  const OriginalFormData = globalThis.FormData
  const originalFetch = globalThis.fetch
  let answer
  globalThis.FormData = class FormData {}
  globalThis.fetch = () => new Promise(resolve => { answer = resolve })

  try {
    c.controls.submit({target: c.form, defaultPrevented: false, preventDefault() {}})
    await new Promise(resolve => setTimeout(resolve, 0))
    // The person opens another conversation while it saves.
    c.form.isConnected = false
    c.textarea.isConnected = false
    answer({status: 202, json: async () => ({accepted: true})})
    await new Promise(resolve => setTimeout(resolve, 0))
    assert.equal(stored.has(key), false)
  } finally {
    globalThis.FormData = OriginalFormData
    globalThis.fetch = originalFetch
  }
})
