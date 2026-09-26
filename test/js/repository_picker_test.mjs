import {test} from "node:test"
import assert from "node:assert/strict"
import {createRepositoryPicker} from "../../priv/static/repository-picker.mjs"

// Andrew, 2026-09-26: 37 repositories started ticked, so choosing 5 meant
// unticking 32 one by one, and the only count on screen was "Add all 37"
// beside his 5, which read as a wrong count. Nothing starts ticked, Select
// all shown and Select none act on the rows the search shows, and the add
// button counts the selection.
function fixture(names, present = []) {
  const listeners = {}
  const rows = names.map(name => {
    const box = {checked: false, value: name, disabled: present.includes(name), matches: selector => selector === "input[type=checkbox]"}
    return {dataset: {repositoryName: name}, hidden: false, querySelector: () => box, box}
  })
  const search = {value: "", matches: selector => selector === "[data-repository-search]"}
  const addSelected = {textContent: "", disabled: false}
  const form = {
    querySelectorAll: () => rows,
    querySelector: selector =>
      selector === "[data-repository-add-selected]" ? addSelected :
      selector === "[data-repository-search]" ? search : null,
    addEventListener: (type, handler) => { listeners[type] = handler },
    removeEventListener: type => { delete listeners[type] }
  }
  const click = select => listeners.click({preventDefault() {}, target: {closest: () => ({dataset: {repositorySelect: select}})}})
  return {form, rows, search, addSelected, listeners, click}
}

test("the add button counts the selection and is off with nothing chosen", () => {
  const page = fixture(["acme/api", "acme/web", "acme/docs"])
  const picker = createRepositoryPicker(page.form)
  picker.mounted()
  assert.equal(page.addSelected.textContent, "Add 0 selected")
  assert.equal(page.addSelected.disabled, true)

  page.rows[0].box.checked = true
  page.listeners.change({target: page.rows[0].box})
  assert.equal(page.addSelected.textContent, "Add 1 selected")
  assert.equal(page.addSelected.disabled, false)
})

test("select all and none act on the rows the search shows, never on ones already added", () => {
  const page = fixture(["acme/api", "acme/web", "other/docs"], ["acme/web"])
  const picker = createRepositoryPicker(page.form)
  picker.mounted()

  page.search.value = "acme"
  page.listeners.input({target: page.search})
  assert.deepEqual(page.rows.map(row => row.hidden), [false, false, true])

  page.click("all")
  assert.deepEqual(page.rows.map(row => row.box.checked), [true, false, false])
  assert.equal(page.addSelected.textContent, "Add 1 selected")

  page.search.value = ""
  page.listeners.input({target: page.search})
  page.click("all")
  assert.deepEqual(page.rows.map(row => row.box.checked), [true, false, true])
  assert.equal(page.addSelected.textContent, "Add 2 selected")

  page.click("none")
  assert.deepEqual(page.rows.map(row => row.box.checked), [false, false, false])
  assert.equal(page.addSelected.disabled, true)

  picker.destroyed()
  assert.deepEqual(Object.keys(page.listeners), [])
})

test("a page update keeps what the person chose", () => {
  const page = fixture(["acme/api", "acme/web"])
  const picker = createRepositoryPicker(page.form)
  picker.mounted()
  page.rows[1].box.checked = true
  page.listeners.change({target: page.rows[1].box})

  // A LiveView patch redraws the rows from the server, which ticks nothing.
  page.rows.forEach(row => { row.box.checked = false })
  picker.updated()

  assert.deepEqual(page.rows.map(row => row.box.checked), [false, true])
  assert.equal(page.addSelected.textContent, "Add 1 selected")
})
