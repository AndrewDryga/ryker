import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import vm from "node:vm"
import {captureReadingAnchor, restoreReadingAnchor, createHistory, readerScrolled, scrollerFor} from "../../priv/static/history.mjs"

const shellSource = readFileSync(new URL("../../priv/static/reading-state.mjs", import.meta.url), "utf8")

// The shipped shell hook with its real local helpers, so the test fails if
// reading-state.mjs goes back to restoring a pixel offset on a transcript.
async function shell(p) {
  const imports = {}
  for (const match of shellSource.matchAll(/^import \{([^}]+)\} from "\.\/([^"/]+\.mjs)"/gm)) {
    const module = await import(new URL(`../../priv/static/${match[2]}`, import.meta.url))
    for (const name of match[1].split(",")) {
      const [exported, local = exported] = name.trim().split(/\s+as\s+/)
      imports[local.trim()] = module[exported.trim()]
    }
  }
  const location = {pathname: "/conversations/conv-a", search: "", hash: "", href: "http://127.0.0.1/conversations/conv-a"}
  const root = {querySelectorAll: () => [], querySelector: selector => selector === "#lab-messages" ? p.container : null,
    addEventListener() {}, removeEventListener() {}, contains: () => false}
  const document = {...p.doc, querySelector: () => ({content: "csrf"}), addEventListener() {}}
  // The helpers read the page's globals, as they do in the browser.
  globalThis.window = p.win
  globalThis.document = document
  const hook = vm.runInNewContext(shellSource.replace(/^import .*$/gm, "").replace(/^export /gm, "") + "\ncreateReadingStateHook()",
    {...imports, document, window: p.win, location, sessionStorage: {getItem: () => null, setItem() {}, removeItem() {}}})
  return Object.assign({el: root, pushEvent() {}}, hook)
}

// A transcript laid out in a window: a header above the rows, the composer
// below, and rows of known heights. Rects are computed from that layout and
// the window's scroll position, which is exactly what the real module reads.
function page({rows = [], scrollY = 0, innerHeight = 600, state = "more", before = "cursor-1", conversation = "conv-a"} = {}) {
  const HEADER = 100, COMPOSER = 200, EDGE_TOP = 60, EDGE_HEIGHT = 40
  const listeners = new Map()
  const byId = new Map()
  const win = {
    scrollY, innerHeight,
    scrolls: [],
    scrollTo({top}) {
      this.scrollY = Math.max(0, Math.min(top, doc.documentElement.scrollHeight - this.innerHeight))
      this.scrolls.push(this.scrollY)
      listeners.get("scroll")?.()
    },
    location: {hash: ""},
    getComputedStyle: () => ({overflowY: "visible"}),
    addEventListener: (name, handler) => listeners.set(name, handler),
    removeEventListener: name => listeners.delete(name),
    setTimeout: () => 1, clearTimeout() {}
  }
  const doc = {
    body: {id: "body"},
    documentElement: {get scrollHeight() { return HEADER + container.children.reduce((sum, row) => sum + row.height, 0) + COMPOSER }},
    getElementById: id => byId.get(id) ?? null
  }
  doc.activeElement = doc.body
  const layoutTop = row => HEADER + container.children.slice(0, container.children.indexOf(row)).reduce((sum, r) => sum + r.height, 0)
  const makeRow = (id, height) => {
    const row = {id, height, parentElement: null,
      getBoundingClientRect() { const top = layoutTop(row) - win.scrollY; return {top, bottom: top + row.height} },
      get previousElementSibling() { const i = container.children.indexOf(row); return i > 0 ? container.children[i - 1] : null },
      get nextElementSibling() { const i = container.children.indexOf(row); return container.children[i + 1] ?? null }}
    byId.set(id, row)
    return row
  }
  const container = {id: "lab-messages", children: [],
    get firstElementChild() { return this.children[0] ?? null },
    get lastElementChild() { return this.children[this.children.length - 1] ?? null },
    parentElement: null}
  container.parentElement = {parentElement: null}
  byId.set("lab-messages", container)
  const edge = {id: "lab-history-edge", focused: [],
    getBoundingClientRect() { return {top: EDGE_TOP - win.scrollY, bottom: EDGE_TOP + EDGE_HEIGHT - win.scrollY} },
    contains: node => node === edge || node?.id === "load-earlier",
    focus(options) { this.focused.push(options); doc.activeElement = edge }}
  const latest = {style: {}}
  const button = {hidden: true, parentElement: latest, closest: selector => selector === ".lab-new-messages" ? button : null}
  const dock = {getBoundingClientRect: () => ({top: win.innerHeight - COMPOSER, bottom: win.innerHeight, height: COMPOSER})}
  const column = {querySelector: selector => selector === ".lab-composer-dock" ? dock : null}
  const el = {dataset: {conversation, before, historyState: state}, parentElement: column,
    querySelector(selector) {
      return {"#lab-messages": container, "#lab-history-edge": edge, ".lab-new-messages": button}[selector] ?? null
    },
    addEventListener() {}, removeEventListener() {}}
  for (const [id, height] of rows) container.children.push(makeRow(id, height))
  const pushed = []
  let resolveReply
  const io = {window: win, document: doc, ResizeObserver: class {
    constructor(callback) { this.callback = callback; page.observers.push(this) }
    observe(target) { this.target = target }
    disconnect() { this.disconnected = true }
  }, pushEvent: (event, payload) => { pushed.push([event, payload]); return new Promise(resolve => { resolveReply = resolve }) }}
  page.observers = []
  const history = createHistory(el, io)
  return {win, doc, container, edge, button, latest, el, pushed, history, makeRow,
    prepend(spec) { for (const [id, height] of spec.slice().reverse()) container.children.unshift(makeRow(id, height)) },
    append(spec) { for (const [id, height] of spec) container.children.push(makeRow(id, height)) },
    userScroll(to) { win.scrollY = to; listeners.get("scroll")?.() },
    reply() { resolveReply?.({status: "loaded"}); return new Promise(resolve => setImmediate(resolve)) },
    observers: page.observers,
    scroller: () => scrollerFor(container, win, doc)}
}

test("older rows inserted above keep the row being read at the same offset", () => {
  // Before 2026-09-13 a refresh restored window.scrollY, so fifty rows
  // arriving above the reader put fifty rows' worth of other messages under
  // their eyes. The anchor is the row, not the pixel.
  const p = page({rows: [["m1", 400], ["m2", 400], ["m3", 400], ["m4", 400]], scrollY: 520})
  const reading = captureReadingAnchor(p.container, {window: p.win, document: p.doc})
  assert.equal(reading.anchor.id, "m2")
  assert.equal(reading.anchor.offset, 500 - 520)
  assert.equal(reading.following, false)

  p.prepend([["m0a", 120], ["m0b", 90]])
  assert.equal(restoreReadingAnchor(reading, p.doc), true)
  assert.equal(p.win.scrollY, 520 + 210)
  assert.equal(p.doc.getElementById("m2").getBoundingClientRect().top, -20)
})

test("the shell hook keeps the reader's row in place across a patch that prepends history", async () => {
  // The shell restored window.scrollY after every patch. With fifty rows
  // prepended that is the same pixel over different messages.
  const p = page({rows: [["m1", 400], ["m2", 400], ["m3", 400], ["m4", 400]], scrollY: 520})
  const hook = await shell(p)
  try {
    hook.mounted()
    hook.beforeUpdate()
    p.prepend([["m0a", 120], ["m0b", 90]])
    hook.updated()
    assert.equal(p.win.scrollY, 730)
    assert.equal(p.doc.getElementById("m2").getBoundingClientRect().top, -20)

    // And at the latest edge it still follows a new reply naturally.
    p.userScroll(p.doc.documentElement.scrollHeight - 600)
    hook.beforeUpdate()
    p.append([["m5", 400]])
    hook.updated()
    assert.equal(p.win.scrollY, p.doc.documentElement.scrollHeight - 600)
  } finally {
    delete globalThis.window
    delete globalThis.document
  }
})

test("at the latest edge new messages follow; while reading earlier ones they wait behind a quiet action", () => {
  const following = page({rows: [["m1", 300], ["m2", 300], ["m3", 300]], scrollY: 600})
  const reading = captureReadingAnchor(following.container, {window: following.win, document: following.doc})
  assert.equal(reading.following, true)
  following.append([["m4", 300]])
  restoreReadingAnchor(reading, following.doc)
  assert.equal(following.win.scrollY, following.doc.documentElement.scrollHeight - 600)

  const p = page({rows: [["m1", 300], ["m2", 300], ["m3", 300], ["m4", 300]], scrollY: 320})
  p.history.mounted()
  p.win.scrollY = 320
  p.history.beforeUpdate()
  p.append([["m5", 300]])
  p.history.updated()
  assert.equal(p.button.hidden, false, "new messages below the reader are offered, not forced")
  p.userScroll(p.doc.documentElement.scrollHeight - 600)
  assert.equal(p.button.hidden, true, "reaching the bottom dismisses the offer")
})

test("the new-messages offer floats above the whole composer dock, hint line included", () => {
  // Since 2026-09-19 the composer and its hint line share one dock pinned a
  // hint's height above the window's edge. Measured from the composer alone,
  // the offer would sit on top of the composer.
  const p = page({rows: [["m1", 300], ["m2", 300], ["m3", 300], ["m4", 300]], scrollY: 320})
  p.history.mounted()
  p.win.scrollY = 320
  p.history.beforeUpdate()
  p.append([["m5", 300]])
  p.history.updated()
  assert.equal(p.button.hidden, false)
  assert.equal(p.latest.style.bottom, "216px")
})

test("a load fires once per approach and again only after the reader scrolls", async () => {
  // Scroll listeners fire many times on one gesture; a reply in flight and a
  // page that just landed are not reasons to ask for the next one.
  const p = page({rows: Array.from({length: 40}, (_, i) => [`m${i}`, 100]), scrollY: 3400})
  p.history.mounted()
  assert.deepEqual(p.pushed, [], "mounting at the latest edge loads nothing")
  p.userScroll(300)
  p.userScroll(200)
  p.userScroll(100)
  assert.equal(p.pushed.length, 1)
  assert.deepEqual(p.pushed[0], ["load-older", {conversation: "conv-a", before: "cursor-1"}])

  await p.reply()
  p.el.dataset.before = "cursor-2"
  assert.equal(p.pushed.length, 1, "the landed page does not fetch the next page by itself")
  p.userScroll(50)
  assert.equal(p.pushed.length, 2)
  assert.equal(p.pushed[1][1].before, "cursor-2")
})

test("a transcript shorter than the viewport loads one page at mount and not the whole history", async () => {
  const p = page({rows: [["m1", 60], ["m2", 60]], innerHeight: 900})
  p.history.mounted()
  assert.equal(p.pushed.length, 1)
  await p.reply()
  p.el.dataset.before = "cursor-2"
  p.history.beforeUpdate()
  p.prepend([["m0", 60]])
  p.history.updated()
  assert.equal(p.pushed.length, 1, "no recursive fetch: the next page waits for a scroll")
})

test("a failed or exhausted edge never triggers automatic loads", () => {
  for (const state of ["failed", "exhausted"]) {
    const p = page({rows: [["m1", 100]], state, before: state === "failed" ? "cursor-1" : undefined})
    p.history.mounted()
    p.userScroll(0)
    assert.deepEqual(p.pushed, [], `${state} edge stays quiet`)
  }
})

test("rows above the reader that keep growing re-seat their row until the reader scrolls", () => {
  // Images decode after the patch; the row they push down is the one being
  // read. The settle watch holds it in place and stops the moment the reader
  // takes over.
  const p = page({rows: [["m1", 400], ["m2", 400], ["m3", 400]], scrollY: 450})
  p.history.mounted()
  p.userScroll(450)
  p.history.beforeUpdate()
  p.prepend([["m0", 50]])
  restoreReadingAnchor(p.history.state.reading, p.doc)
  assert.equal(p.win.scrollY, 500)
  p.history.updated()
  assert.equal(p.observers.length, 1)
  p.doc.getElementById("m0").height = 250
  p.observers[0].callback()
  assert.equal(p.win.scrollY, 700, "the grown image above moved the reader's row back into place")
  p.userScroll(680)
  p.observers[0].callback()
  assert.equal(p.observers[0].disconnected, true)
  assert.equal(p.win.scrollY, 680, "the reader's own scroll is never undone")
})

test("changing conversation resets the hook and a stale reply cannot load into it", async () => {
  const p = page({rows: Array.from({length: 20}, (_, i) => [`m${i}`, 100]), scrollY: 1000})
  p.history.mounted()
  p.userScroll(0)
  assert.equal(p.pushed.length, 1)
  p.el.dataset.conversation = "conv-b"
  p.el.dataset.before = "cursor-b"
  p.button.hidden = false
  p.history.beforeUpdate()
  p.history.updated()
  assert.equal(p.button.hidden, true)
  assert.equal(p.win.scrollY, p.doc.documentElement.scrollHeight - 600, "a new conversation opens at its latest edge")
  await p.reply()
  p.userScroll(0)
  assert.equal(p.pushed.length, 2)
  assert.equal(p.pushed[1][1].conversation, "conv-b")
})

test("focus stays at the edge when the Load earlier button it was on disappears", () => {
  const p = page({rows: [["m1", 100]]})
  p.history.mounted()
  p.doc.activeElement = {id: "load-earlier"}
  p.history.beforeUpdate()
  p.doc.activeElement = p.doc.body
  p.history.updated()
  assert.deepEqual(p.edge.focused, [{preventScroll: true}])
})

test("the reader's own scroll is told apart from the module's", () => {
  const p = page({rows: [["m1", 1000]]})
  const scroller = p.scroller()
  assert.equal(readerScrolled(scroller), true, "nothing recorded yet reads as the reader")
  scroller.setTop(300)
  assert.equal(readerScrolled(scroller), false)
  p.win.scrollY = 320
  assert.equal(readerScrolled(scroller), true)
})
