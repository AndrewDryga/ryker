import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../../priv/static/control-plane.js", import.meta.url), "utf8")
const imports = {}
// Load the actual shipped local helpers, while keeping Phoenix transport inert.
for (const match of source.matchAll(/^import \{([^}]+)\} from "\/assets\/([^"/]+\.mjs)"/gm)) {
  if (match[2] === "phoenix.mjs") continue
  const module = await import(new URL(`../../priv/static/${match[2]}`, import.meta.url))
  for (const name of match[1].split(",")) {
    const [original, local = original] = name.trim().split(/\s+as\s+/)
    imports[local] = module[original]
  }
}

const scope = "knowledge:relearn:11111111-1111-4111-8111-111111111111:1:1"
function item(index, revision = 1) {
  // Structural host-owned source tuples, not invented conversation content.
  const id = `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`
  const value = Buffer.from(JSON.stringify({fingerprint: "a".repeat(64), revision, source_input_id: id})).toString("base64url")
  return {id, value}
}

function storage() {
  const values = new Map()
  return {values, getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value), removeItem: key => values.delete(key)}
}

function fixture(items, store = storage(), target = scope) {
  let hook, form
  const listeners = new Map()
  const document = {body: {}, documentElement: {scrollHeight: 1000},
    querySelector: () => ({content: "host-test-csrf"}), getElementById: () => null,
    addEventListener() {}, removeEventListener() {},
    createElement: tagName => ({tagName: tagName.toUpperCase(), dataset: {}, type: "", name: "", value: ""})}
  document.activeElement = document.body
  const location = {pathname: "/memory", hash: "", search: "?rebuild_page=1"}
  Object.defineProperty(location, "href", {get() { return `http://127.0.0.1${this.pathname}${this.search}` }})
  const window = {scrollY: 0, innerHeight: 800, scrollTo() {}, addEventListener() {}, removeEventListener() {}}
  const root = {ownerDocument: document, querySelectorAll: () => [],
    querySelector: selector => selector === "form[data-relearn-scope]" ? form : null,
    contains: node => node === root || node === form || node?.form === form,
    addEventListener: (name, fn) => listeners.set(name, fn), removeEventListener: name => listeners.delete(name)}

  function page(entries, resource) {
    const hidden = {children: [], replaceChildren(...nodes) { this.children = nodes }, appendChild(node) { this.children.push(node) }}
    const count = {textContent: ""}, help = {textContent: "Selections stay on the current page only."}
    const submit = {disabled: false}
    const next = {dataset: {relearnScope: resource}, ownerDocument: document, isConnected: true,
      matches: selector => selector === "form[data-relearn-scope]", querySelectorAll: () => next.inputs,
      querySelector: selector => ({"[data-relearn-hidden]": hidden, "[data-relearn-count]": count,
        "[data-relearn-help]": help, "[data-relearn-clear]": clear, "button[type=submit]": submit})[selector]}
    const clear = {form: next, hidden: true, disabled: false,
      closest: selector => selector === "[data-relearn-clear]" ? clear : selector === "form[data-relearn-scope]" ? next : null}
    next.inputs = entries.map(entry => ({...entry, dataset: {relearnSource: entry.id}, type: "checkbox",
      tagName: "INPUT", name: "sources[]", checked: false, disabled: false, form: next,
      matches: selector => selector === "input[data-relearn-source]",
      closest: selector => selector === "form[data-relearn-scope]" ? next : null}))
    return Object.assign(next, {hidden, count, help, submit, clear})
  }
  form = page(items, target)
  vm.runInNewContext(source.replace(/^import .*$/gm, ""), {...imports, document, window, location,
    sessionStorage: store, Socket: class {},
    LiveSocket: class { constructor(_path, _socket, options) { hook = options.hooks.PreserveReadingState } connect() {} }})
  const mounted = Object.assign({el: root}, hook)
  mounted.mounted()
  function emit(type, element) {
    const event = {type, target: element, defaultPrevented: false,
      preventDefault() { this.defaultPrevented = true }}
    listeners.get(type)?.(event)
    return event
  }
  return {store, hook: mounted, get form() { return form },
    choose(index, checked = true) { const input = form.inputs[index]; input.checked = checked; emit("change", input) },
    clear() { emit("click", form.clear) },
    submit() { return emit("submit", form) },
    values() { return [...form.inputs.filter(input => input.checked && !input.disabled), ...form.hidden.children].map(input => input.value).sort() },
    patch(entries, resource = target) {
      mounted.beforeUpdate(); form = page(entries, resource); mounted.updated()
    },
    navigate(entries, resource = target) {
      location.search = "?rebuild_q=decision&rebuild_page=2"
      mounted.beforeUpdate(); form = page(entries, resource); mounted.updated()
    }}
}

test("source selection starts empty and never stores message prose", () => {
  const f = fixture([item(1)])
  assert.deepEqual(f.values(), [])
  assert.equal(f.form.submit.disabled, true)
  f.choose(0)
  assert.equal(f.store.values.size, 1)
  const saved = JSON.parse([...f.store.values.values()][0])
  assert.deepEqual(Object.keys(saved).sort(), ["items", "scope"])
  assert.deepEqual(saved.items, [item(1)])
})

test("a selection saved before the 2026-09-13 rename is adopted once under the current key", () => {
  const store = storage()
  store.values.set("responder:relearn-selection:v1", JSON.stringify({items: [item(1)], scope}))
  const f = fixture([item(1)], store)
  assert.deepEqual(f.values(), [item(1).value])
  assert.equal(store.values.has("responder:relearn-selection:v1"), false)
  assert.equal(store.values.has("ryker:relearn-selection:v1"), true)
})

test("explicit selections span source pages and searches without intercepting native POST", async () => {
  // The previous picker discarded the first page's decision when an operator
  // navigated to the correction. The actual reading-state hook is exercised.
  const f = fixture([item(1)])
  f.choose(0); f.navigate([item(2)]); f.choose(0)
  assert.deepEqual(f.values(), [item(1).value, item(2).value].sort())
  assert.match(f.form.count.textContent, /2 of 16/)
  assert.match(f.form.count.textContent, /1 on other pages/)
  assert.equal(f.submit().defaultPrevented, false)
  const reloaded = fixture([item(2)], f.store)
  assert.deepEqual(reloaded.values(), f.values())
})

test("the sixteen-source limit includes selections on other pages", () => {
  const f = fixture(Array.from({length: 16}, (_, index) => item(index + 1)))
  for (let index = 0; index < 16; index++) f.choose(index)
  f.navigate([item(17)])
  assert.equal(f.form.inputs[0].disabled, true)
  f.choose(0)
  assert.equal(f.form.inputs[0].checked, false)
  assert.equal(f.values().length, 16)
})

test("a newly visible revision invalidates selection rather than silently selecting changed text", () => {
  const f = fixture([item(1)])
  f.choose(0); f.patch([item(1, 2)])
  assert.deepEqual(f.values(), [])
  assert.match(f.form.help.textContent, /changed/)
  f.patch([item(1)])
  assert.deepEqual(f.values(), [])
})

test("target versions and retry budgets never inherit another request's selection", () => {
  for (const next of [scope + ":new-version", "learning:reselect:batch:1:2:2"]) {
    const f = fixture([item(1)])
    f.choose(0); f.navigate([item(1)], next)
    assert.deepEqual(f.values(), [])
    assert.equal(f.store.values.size, 1)
    assert.equal(JSON.parse([...f.store.values.values()][0]).scope, next)
  }
})

test("live patches restore exact checkboxes and include off-page tuples only once", () => {
  const f = fixture([item(1)])
  f.choose(0); f.navigate([item(2)]); f.choose(0)
  for (let index = 0; index < 3; index++) f.patch([item(2)])
  assert.deepEqual(f.values(), [item(1).value, item(2).value].sort())
  assert.equal(f.form.inputs[0].checked, true)
  assert.equal(f.form.hidden.children.length, 1)
})

test("clear removes both visible and off-page explicit selections", () => {
  const f = fixture([item(1)])
  f.choose(0); f.navigate([item(2)]); f.choose(0); f.clear()
  assert.deepEqual(f.values(), [])
  assert.equal(f.form.submit.disabled, true)
  f.navigate([item(1)])
  assert.deepEqual(f.values(), [])
})

test("disabled storage retains a usable current-page-only picker", () => {
  for (const failing of ["getItem", "setItem"]) {
    const store = storage()
    store[failing] = () => { throw new Error("storage disabled") }
    const f = fixture([item(1)], store)
    f.choose(0)
    assert.deepEqual(f.values(), [item(1).value])
    assert.match(f.form.help.textContent, /current page only/)
    f.navigate([item(2)]); f.choose(0)
    assert.deepEqual(f.values(), [item(2).value])
  }
})

test("malformed or oversized stored selections cannot populate hidden submissions", () => {
  const f = fixture([item(1)])
  f.choose(0)
  const key = [...f.store.values.keys()][0]
  for (const bad of ["not-json", "x".repeat(20000), JSON.stringify({scope, items: Array.from({length: 17}, (_, i) => item(i + 1))}),
    JSON.stringify({scope, items: [{...item(1), text: "Do not store source prose"}]})]) {
    f.store.values.set(key, bad)
    assert.deepEqual(fixture([item(2)], f.store).values(), [])
  }
})
