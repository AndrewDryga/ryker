// Scroll ownership for one conversation transcript.
//
// Two things move the transcript under a reader: older pages prepended above
// the first visible row, and new rows appended below the last one. The rule
// is the same for both: the row the reader is looking at stays where it is,
// unless they are at the latest edge, where new messages follow naturally.
// Everything here is measured against a scroller, which is the window today
// and would be an overflow container if the layout ever gave the transcript
// one, so a layout change cannot silently turn anchoring off.

const FOLLOW_MARGIN = 48
const LOAD_MARGIN = 480
const SETTLE_MS = 3000
const expectedTops = new WeakMap()

const windowScroller = (win, doc) => ({
  target: win,
  top: () => win.scrollY,
  // The browser clamps; what is recorded is where the scroll actually went.
  setTop(value) {
    win.scrollTo({top: value, behavior: "instant"})
    expectedTops.set(win, win.scrollY)
  },
  viewportTop: () => 0,
  height: () => win.innerHeight,
  contentHeight: () => doc.documentElement.scrollHeight,
  atBottom: margin => win.innerHeight + win.scrollY >= doc.documentElement.scrollHeight - margin,
  listen: (name, handler, options) => win.addEventListener(name, handler, options),
  unlisten: (name, handler, options) => win.removeEventListener(name, handler, options)
})

const elementScroller = element => ({
  target: element,
  top: () => element.scrollTop,
  setTop(value) {
    element.scrollTop = value
    expectedTops.set(element, element.scrollTop)
  },
  viewportTop: () => element.getBoundingClientRect().top,
  height: () => element.clientHeight,
  contentHeight: () => element.scrollHeight,
  atBottom: margin => element.scrollTop + element.clientHeight >= element.scrollHeight - margin,
  listen: (name, handler, options) => element.addEventListener(name, handler, options),
  unlisten: (name, handler, options) => element.removeEventListener(name, handler, options)
})

export const scrollerFor = (element, win = globalThis.window, doc = globalThis.document) => {
  for (let node = element?.parentElement; node && node !== doc.body; node = node.parentElement) {
    const overflow = win.getComputedStyle?.(node)?.overflowY
    if (overflow === "auto" || overflow === "scroll") return elementScroller(node)
  }
  return windowScroller(win, doc)
}

// A scroll the reader made, as opposed to one this module made. Programmatic
// scrolls record where they went; anything else within a pixel is the reader.
export const readerScrolled = scroller => {
  const expected = expectedTops.get(scroller.target)
  return expected === undefined || Math.abs(expected - scroller.top()) > 1
}

// The first row whose bottom edge is below the top of the viewport, and how far
// its top edge sits from that line. Captured before a patch, it names what the
// reader is looking at in terms the patch cannot change.
export const captureReadingAnchor = (root, options = {}) => {
  const container = root?.id === "lab-messages" ? root : root?.querySelector?.("#lab-messages")
  if (!container) return null
  const scroller = options.scroller || scrollerFor(container, options.window, options.document)
  const viewportTop = scroller.viewportTop()
  let anchor = null
  for (const row of container.children) {
    const rect = row.getBoundingClientRect()
    if (rect.bottom > viewportTop) { anchor = {id: row.id, offset: rect.top - viewportTop}; break }
  }
  return {
    anchor, container, scroller,
    firstRowId: container.firstElementChild?.id ?? null,
    lastRowId: container.lastElementChild?.id ?? null,
    following: scroller.atBottom(FOLLOW_MARGIN),
    top: scroller.top()
  }
}

const rowsPrependedAbove = (reading, doc) => {
  if (!reading.firstRowId) return false
  const first = doc.getElementById(reading.firstRowId)
  return Boolean(first && first.previousElementSibling)
}

// Puts the anchored row back at its offset, or follows the latest edge when
// the reader was there and nothing was inserted above them. Returns whether
// it took ownership of the scroll position.
export const restoreReadingAnchor = (reading, doc = globalThis.document) => {
  if (!reading) return false
  const {scroller} = reading
  if (reading.following && !rowsPrependedAbove(reading, doc)) {
    scroller.setTop(scroller.contentHeight())
    return true
  }
  const row = reading.anchor && doc.getElementById(reading.anchor.id)
  if (row) {
    const delta = row.getBoundingClientRect().top - scroller.viewportTop() - reading.anchor.offset
    if (Math.abs(delta) > 0.5) scroller.setTop(scroller.top() + delta)
    return true
  }
  scroller.setTop(reading.top)
  return true
}

// The hook behind #lab-history. It asks the server for the page above the
// oldest loaded row when the reader nears it, keeps the reader's row in place
// while late images and cards above it finish sizing, and offers a quiet way
// down when messages arrive while they are reading earlier ones.
export const createHistory = (el, io) => {
  const doc = io.document || globalThis.document
  const win = io.window || globalThis.window
  const ResizeObserverImpl = io.ResizeObserver || win.ResizeObserver
  const state = {conversation: null, inflight: false, armed: true, reading: null, settle: null, edgeFocused: false}
  let scroller = null

  const container = () => el.querySelector("#lab-messages")
  const edge = () => el.querySelector("#lab-history-edge")
  const latest = () => el.querySelector(".lab-new-messages")

  // The composer is stuck to the bottom of the viewport; the offer floats
  // just above it, however tall the draft has grown.
  const offerLatest = () => {
    const button = latest()
    if (!button) return
    const composer = el.parentElement?.querySelector?.(".lab-native-composer")
    const clearance = composer ? composer.getBoundingClientRect().height + 16 : 20
    if (button.parentElement?.style) button.parentElement.style.bottom = `${clearance}px`
    button.hidden = false
  }
  const canLoad = () => el.dataset.historyState === "more" && Boolean(el.dataset.before) && !state.inflight
  const nearTop = () => {
    const node = edge()
    if (!node || !scroller) return false
    return node.getBoundingClientRect().bottom >= scroller.viewportTop() - LOAD_MARGIN
  }

  const load = () => {
    if (!canLoad()) return false
    state.inflight = true
    state.armed = false
    const finish = () => { state.inflight = false }
    try {
      const result = io.pushEvent("load-older", {conversation: el.dataset.conversation, before: el.dataset.before})
      if (result && typeof result.then === "function") result.then(finish, finish)
      else finish()
    } catch (_) { finish() }
    return true
  }

  const toLatest = () => {
    scroller.setTop(scroller.contentHeight())
    const button = latest()
    if (button) button.hidden = true
  }

  const stopSettling = () => {
    if (!state.settle) return
    state.settle.observer?.disconnect()
    win.clearTimeout?.(state.settle.timer)
    state.settle = null
  }

  // Older rows can keep growing after they land: an image decodes, a card
  // lays out. Until the reader scrolls, every such change re-seats the row
  // they were reading; three seconds after the prepend the transcript is
  // taken to have settled.
  const settleAfterPrepend = reading => {
    stopSettling()
    if (!ResizeObserverImpl || !reading?.anchor) return
    const observer = new ResizeObserverImpl(() => {
      if (readerScrolled(scroller)) { stopSettling(); return }
      restoreReadingAnchor(reading, doc)
    })
    observer.observe(container())
    state.settle = {observer, timer: win.setTimeout?.(stopSettling, SETTLE_MS)}
  }

  const onScroll = () => {
    if (!readerScrolled(scroller)) return
    stopSettling()
    state.armed = true
    if (scroller.atBottom(FOLLOW_MARGIN)) { const button = latest(); if (button) button.hidden = true }
    if (nearTop()) load()
  }

  const onClick = event => {
    if (event.target.closest?.(".lab-new-messages")) { event.preventDefault(); toLatest() }
  }

  const reset = () => {
    stopSettling()
    state.conversation = el.dataset.conversation
    state.inflight = false
    state.armed = true
    const button = latest()
    if (button) button.hidden = true
    if (!win.location?.hash) scroller.setTop(scroller.contentHeight())
  }

  return {
    state,
    mounted() {
      scroller = io.scroller || scrollerFor(container() || el, win, doc)
      scroller.listen("scroll", onScroll, {passive: true})
      el.addEventListener("click", onClick)
      reset()
      // A transcript shorter than the viewport has its top edge in view from
      // the start; one page comes automatically, the next needs a scroll.
      if (nearTop()) load()
    },
    beforeUpdate() {
      state.reading = captureReadingAnchor(container(), {scroller, window: win, document: doc})
      state.edgeFocused = Boolean(doc.activeElement && edge()?.contains(doc.activeElement))
    },
    updated() {
      if (el.dataset.conversation !== state.conversation) { reset(); return }
      const reading = state.reading
      state.reading = null
      if (!reading) return
      if (rowsPrependedAbove(reading, doc)) settleAfterPrepend(reading)
      const lastRow = container()?.lastElementChild
      if (!reading.following && reading.lastRowId && lastRow && lastRow.id !== reading.lastRowId) offerLatest()
      // A "Load earlier" button that just loaded the last page is gone; its
      // focus stays at the same place instead of falling to the document.
      if (state.edgeFocused && doc.activeElement === doc.body) edge()?.focus?.({preventScroll: true})
    },
    destroyed() {
      stopSettling()
      scroller?.unlisten("scroll", onScroll, {passive: true})
      el.removeEventListener("click", onClick)
    }
  }
}

export const ConversationHistory = {
  mounted() {
    this.history = createHistory(this.el, {pushEvent: (event, payload) => this.pushEvent(event, payload)})
    this.history.mounted()
  },
  beforeUpdate() { this.history.beforeUpdate() },
  updated() { this.history.updated() },
  destroyed() { this.history.destroyed() }
}
