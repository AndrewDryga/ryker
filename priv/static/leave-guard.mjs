// Ask before an in-page link or a page unload discards unsaved work, and only
// when something is actually unsaved: a confirm on every navigation is a
// confirm nobody reads. The caller decides dirtiness; this never does, and
// `discard` runs when the person agrees to leave a link's way. Shared by the
// instruction editor and the settings page, which had the same two listeners
// each.
export function createLeaveGuard({dirty, message, beforeUnload = () => {}, discard = () => {}}, environment = {}) {
  const doc = environment.document || document
  const win = environment.window || window

  function click(event) {
    const link = event.target.closest?.("a[href]")
    if (!link || event.defaultPrevented || event.button > 0 || event.metaKey || event.ctrlKey ||
        event.shiftKey || event.altKey || link.target === "_blank" || link.download || !dirty()) return
    const target = new URL(link.href, win.location.href)
    if (target.href.split("#")[0] === win.location.href.split("#")[0]) return
    if (win.confirm(message)) discard()
    else {
      event.preventDefault()
      event.stopImmediatePropagation()
    }
  }

  function unload(event) {
    if (!dirty()) return
    beforeUnload()
    event.preventDefault()
    event.returnValue = ""
  }

  doc.addEventListener("click", click, true)
  win.addEventListener("beforeunload", unload)

  return {
    destroy() {
      doc.removeEventListener("click", click, true)
      win.removeEventListener("beforeunload", unload)
    }
  }
}
