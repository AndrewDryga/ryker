import {test} from "node:test"
import assert from "node:assert/strict"
import {applyFilterChange, filterToolbar} from "../../priv/static/filter-toolbar.mjs"

function form({classes = "filter-toolbar", method = "get"} = {}) {
  const submitted = []
  return {
    method,
    submitted,
    matches: selector => selector === "form.filter-toolbar" && classes.split(" ").includes("filter-toolbar"),
    requestSubmit() { submitted.push("requestSubmit") },
    submit() { submitted.push("submit") }
  }
}

const control = (tagName, owner) => ({tagName, form: owner})

test("choosing a dropdown value submits its own filter toolbar at once", () => {
  // The approved toolbar has no Apply button: the dropdown is the action.
  const toolbar = form()
  assert.equal(applyFilterChange({target: control("SELECT", toolbar)}), true)
  assert.deepEqual(toolbar.submitted, ["requestSubmit"])
})

test("typing in the search box does not submit; Enter does that on its own", () => {
  const toolbar = form()
  assert.equal(applyFilterChange({target: control("INPUT", toolbar)}), false)
  assert.deepEqual(toolbar.submitted, [])
})

test("a change inside a lifecycle, edit, delete or settings form never submits it", () => {
  // Pause/Resume/Delete confirmations and the settings editor hold selects
  // too. A stray change there must not perform, or even open, anything.
  for (const other of [form({classes: "action-control"}), form({classes: "settings-section"}), form({classes: "filter-toolbar", method: "post"})]) {
    assert.equal(applyFilterChange({target: control("SELECT", other)}), false)
    assert.deepEqual(other.submitted, [])
  }
  assert.equal(applyFilterChange({target: {tagName: "SELECT", form: null}}), false)
  assert.equal(applyFilterChange({target: undefined}), false)
  assert.equal(filterToolbar(control("SELECT", form({classes: "search-form"}))), null)
})

test("a browser without requestSubmit still submits the toolbar", () => {
  const toolbar = form()
  delete toolbar.requestSubmit
  assert.equal(applyFilterChange({target: control("SELECT", toolbar)}), true)
  assert.deepEqual(toolbar.submitted, ["submit"])
})
