// An unsaved settings section lives in server-side component state, so leaving
// the page discards it silently. Ask first — and only when something is
// actually unsaved, because a confirm on every navigation is a confirm nobody
// reads. The forms themselves report dirtiness; this never decides it.
export function createSettingsGuard(root, environment = {}) {
  const doc = environment.document || document
  const win = environment.window || window
  const dirty = () => root.querySelectorAll("form[data-dirty=true]").length > 0

  function click(event) {
    const link = event.target.closest?.("a[href]")
    if (!link || event.defaultPrevented || event.button > 0 || event.metaKey || event.ctrlKey ||
        event.shiftKey || event.altKey || link.target === "_blank" || link.download || !dirty()) return
    const target = new URL(link.href, win.location.href)
    if (target.href.split("#")[0] === win.location.href.split("#")[0]) return
    if (!win.confirm("Leave without saving these settings?")) {
      event.preventDefault()
      event.stopImmediatePropagation()
    }
  }

  function unload(event) {
    if (!dirty()) return
    event.preventDefault()
    event.returnValue = ""
  }

  doc.addEventListener("click", click, true)
  win.addEventListener("beforeunload", unload)

  return {
    dirty,
    destroy() {
      doc.removeEventListener("click", click, true)
      win.removeEventListener("beforeunload", unload)
    }
  }
}
