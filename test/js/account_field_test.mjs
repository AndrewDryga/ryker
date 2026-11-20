import {test} from "node:test"
import assert from "node:assert/strict"
import {AccountField} from "../../priv/static/account-field.mjs"

test("a failed key submission keeps the edit and a confirmed save clears the replacement field", () => {
  let field = {value: "", validity: {valid: false}}
  const button = {}
  const listeners = {}
  const el = {
    dataset: {saved: "", success: ""},
    querySelector: selector => selector.startsWith("input") ? field : button,
    addEventListener: (name, fn) => {listeners[name] = fn},
    removeEventListener: name => {delete listeners[name]}
  }
  const hook = {...AccountField, el}
  hook.mounted()
  assert.equal(button.disabled, true)
  field.value = "test value"
  field.validity.valid = true
  listeners.input()
  assert.equal(button.disabled, false)
  hook.beforeUpdate()
  field = {value: "", validity: {valid: true}}
  hook.updated()
  assert.equal(field.value, "test value")
  hook.beforeUpdate()
  el.dataset.success = "1"
  hook.updated()
  assert.equal(field.value, "")
  assert.equal(button.disabled, true)
  assert.equal(hook.draft, null)
  hook.destroyed()
  assert.deepEqual(listeners, {})
})
