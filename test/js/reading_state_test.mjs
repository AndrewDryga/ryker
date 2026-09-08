import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import vm from "node:vm"
import {createRelearnPicker} from "../../priv/static/relearn-selection.mjs"

const source = readFileSync(new URL("../../priv/static/control-plane.js", import.meta.url), "utf8")
const retained = JSON.parse(readFileSync(new URL("../responder/work/fixtures/airflow_candidate_responses.json", import.meta.url), "utf8"))

function fixture(hash = "") {
  let hook
  const listeners = new Map(), nodes = new Map(), scrolled = []
  const location = {pathname: "/episodes/candidate-ui/requests", search: "?responses_page=1", hash}
  Object.defineProperty(location, "href", {get() { return `http://127.0.0.1:45459${this.pathname}${this.search}${this.hash}` }})
  const document = {body: {id: ""}, documentElement: {scrollHeight: 2000},
    querySelector: () => ({content: "host-test-csrf"}), getElementById: id => nodes.get(id)}
  document.activeElement = document.body
  const window = {scrollY: 100, innerHeight: 800, scrollTo: value => scrolled.push(value),
    addEventListener: (name, handler) => listeners.set(name, handler), removeEventListener: name => listeners.delete(name)}
  const root = {querySelectorAll: selector => selector === "details" ? [outer, response] : [],
    addEventListener() {}, removeEventListener() {}, contains(node) {
      for (let current = node; current; current = current.parentElement) if (current === this) return true
      return false
    }}
  function node(id, tagName, parentElement) {
    const value = {id, tagName, parentElement, isConnected: true, open: false,
      querySelector: () => ({textContent: "Response for attempt 1"}),
      focus(options) { document.activeElement = this; this.focusOptions = options },
      scrollIntoView(options) { this.scrollOptions = options },
      closest(selector) {
        for (let current = this; current && current !== root; current = current.parentElement) {
          if (selector === "details" && current.tagName === "DETAILS") return current
        }
        return null
      }}
    nodes.set(id, value)
    return value
  }
  const outer = node("validation", "DETAILS", root)
  const response = node("response-1", "DETAILS", outer)
  let body = node("response-1-body", "DIV", response)
  body.textContent = retained.responses[0].body
  // Evaluate the shipped hook itself; browser asset imports and the transport
  // are stubbed. Real LiveView patches are qualified separately in Chromium.
  vm.runInNewContext(source.replace(/^import .*$/gm, ""), {document, window, location,
    sessionStorage: {getItem() { return null }}, Socket: class {}, keyFor: () => null, createRelearnPicker,
    LiveSocket: class { constructor(_path, _socket, options) { hook = options.hooks.PreserveReadingState } connect() {} }})
  const mounted = Object.assign({el: root}, hook)
  return {hook: mounted, document, window, location, root, outer, response, nodes, listeners, scrolled,
    get body() { return body }, replaceFocusedBody() {
      body.isConnected = false
      body = node("response-1-body", "DIV", response)
      body.textContent = retained.responses[0].body
      document.activeElement = document.body
    }}
}

test("a new validation attempt preserves focus on the same retained response", () => {
  // The real 11th-attempt browser append preserved disclosure but dropped focus
  // to <body>. No-change refresh tests had missed this changed-DOM regression.
  const f = fixture()
  f.hook.mounted(); f.outer.open = true; f.response.open = true; f.body.focus()
  f.hook.beforeUpdate(); f.replaceFocusedBody(); f.outer.open = false; f.response.open = false
  f.hook.updated()
  assert.equal(f.response.open, true)
  assert.equal(f.document.activeElement, f.body)
  assert.equal(f.body.focusOptions.preventScroll, true)
})

test("a deep link opens and focuses its response after the connected view mounts", () => {
  // Real phone page-2 navigation arrived with response 11 closed after LiveView
  // connected. Native hash scrolling does not guarantee disclosure restoration.
  const f = fixture("#response-1-body")
  f.hook.mounted()
  assert.equal(f.outer.open, true)
  assert.equal(f.response.open, true)
  assert.equal(f.document.activeElement, f.body)
  assert.equal(f.body.scrollOptions.block, "start")
})

test("a fragment absent during mount is resolved when its exact body arrives", () => {
  const f = fixture("#response-1-body")
  f.nodes.delete(f.body.id); f.hook.mounted()
  f.hook.beforeUpdate(); f.nodes.set(f.body.id, f.body); f.hook.updated()
  assert.equal(f.response.open, true)
  assert.equal(f.document.activeElement, f.body)
})

test("a pending fragment never displaces the reader's newer focus", () => {
  const f = fixture("#response-1-body")
  f.nodes.delete(f.body.id); f.hook.mounted(); f.hook.beforeUpdate()
  const newer = {id: "reader-selected-control"}
  f.document.activeElement = newer
  f.nodes.set(f.body.id, f.body); f.hook.updated()
  assert.equal(f.document.activeElement, newer)
  assert.equal(f.body.scrollOptions, undefined)
})

test("refresh does not reopen a fragment disclosure the reader closed", () => {
  const f = fixture("#response-1-body")
  f.hook.mounted(); f.response.open = false; f.document.activeElement = f.document.body
  f.hook.beforeUpdate(); f.hook.updated()
  assert.equal(f.response.open, false)
})

test("focus is never restored across request-page changes or over a newer focus", () => {
  for (const changedPage of [true, false]) {
    const f = fixture()
    f.hook.mounted(); f.body.focus(); f.hook.beforeUpdate(); f.replaceFocusedBody()
    const newer = {id: "reader-selected-control"}
    if (changedPage) f.location.search = "?responses_page=2"
    else f.document.activeElement = newer
    f.hook.updated()
    assert.equal(f.document.activeElement, changedPage ? f.document.body : newer)
  }
})

test("malformed, missing and out-of-scope fragments do not alter focus", () => {
  for (const hash of ["#%not-encoding", "#missing", "#outside"]) {
    const f = fixture(hash)
    f.nodes.set("outside", {id: "outside", parentElement: null})
    f.hook.mounted(); f.hook.beforeUpdate(); f.hook.updated()
    assert.equal(f.response.open, false)
    assert.equal(f.document.activeElement, f.document.body)
  }
})

test("new local fragment navigation is handled and its listener is removed on unmount", () => {
  const f = fixture()
  f.hook.mounted(); f.location.hash = "#response-1-body"
  assert.equal(typeof f.listeners.get("hashchange"), "function")
  f.listeners.get("hashchange")()
  assert.equal(f.response.open, true)
  f.location.hash = ""; f.listeners.get("hashchange")()
  f.response.open = false
  f.location.hash = "#response%2D1%2Dbody"; f.listeners.get("hashchange")()
  assert.equal(f.response.open, true)
  f.hook.destroyed()
  assert.equal(f.listeners.has("hashchange"), false)
})
