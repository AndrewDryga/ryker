import {test} from "node:test"
import assert from "node:assert/strict"
import {createComposer} from "../../priv/static/composer.mjs"

// The composer form as the server renders it: the message, the file field
// described by its error slot, the status line and Send. Real layout is
// checked in Chromium.
function composer() {
  const attributes = {}
  const error = {hidden: true, textContent: ""}
  const status = {hidden: true, textContent: ""}
  const button = {disabled: false}
  const textarea = {value: "", validity: "", reported: 0,
    setCustomValidity(message) { this.validity = message }, reportValidity() { this.reported++ }}
  const files = {type: "file", files: [], disabled: false,
    setAttribute(name, value) { attributes[name] = value }, removeAttribute(name) { delete attributes[name] }}
  const form = {
    matches: selector => selector === ".composer",
    checkValidity: () => true,
    querySelector: selector => ({
      "textarea": textarea, "textarea[name=message]": textarea, "input[type=file]": files,
      ".composer-error": error, ".composer-status": status, "button[type=submit]": button
    })[selector] ?? null
  }
  textarea.form = form
  files.form = form
  const controls = createComposer({pushEvent() {}, active: () => true, storage: () => ({}), location: {pathname: "/conversations"}})
  return {controls, form, textarea, files, error, status, button, attributes}
}

test("a file choice that breaks a limit is explained beside the composer at once and cleared once fixed", () => {
  // Andrew, 2026-09-19: the composer printed "Up to 2 files · 8 MiB" under
  // every draft and only complained on Send. Now nothing is printed until a
  // choice breaks a limit, and then the reason appears as the files are picked.
  const c = composer()
  c.files.files = [{size: 1}, {size: 1}, {size: 1}]
  c.controls.input({target: c.files})
  assert.equal(c.error.hidden, false)
  assert.match(c.error.textContent, /at most 2/)
  assert.equal(c.attributes["aria-invalid"], "true")

  c.files.files = [{size: 1}]
  c.controls.input({target: c.files})
  assert.equal(c.error.hidden, true)
  assert.equal(c.error.textContent, "")
  assert.equal(c.attributes["aria-invalid"], undefined)
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
  assert.equal(c.button.disabled, false, "no send started")
  assert.equal(c.status.hidden, true)
  assert.equal(c.textarea.reported, 0, "the file problem is not reported on the message field")
})
