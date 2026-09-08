const storageKey = "responder:relearn-selection:v1"
const limit = 16
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const validItem = item => item && Object.keys(item).sort().join(",") === "id,value" &&
  typeof item.id === "string" && uuid.test(item.id) && typeof item.value === "string" &&
  /^[A-Za-z0-9_-]{1,512}$/.test(item.value)

// One tab-local, bounded slot. Values are opaque host-issued source tuples,
// never source text or browser-granted authority; every POST is rechecked.
export function createRelearnPicker(root, getStorage) {
  let storage, persistent = true, scope, form, visible = new Map(), selected = new Map(), changed = false
  try { storage = getStorage(); if (!storage) persistent = false } catch (_) { persistent = false }

  function read(nextScope) {
    if (!persistent) return new Map()
    let raw
    try { raw = storage.getItem(storageKey) } catch (_) { persistent = false; return new Map() }
    try {
      if (!raw || raw.length > 10000) return new Map()
      const saved = JSON.parse(raw)
      if (!saved || Object.keys(saved).sort().join(",") !== "items,scope" || saved.scope !== nextScope ||
          !Array.isArray(saved.items) || saved.items.length > limit || !saved.items.every(validItem) ||
          new Set(saved.items.map(item => item.id)).size !== saved.items.length) return new Map()
      return new Map(saved.items.map(item => [item.id, item.value]))
    } catch (_) {
      // A malformed value carries no usable selection.
      return new Map()
    }
  }

  function save() {
    if (persistent) {
      try {
        storage.setItem(storageKey, JSON.stringify({scope, items: Array.from(selected, ([id, value]) => ({id, value}))}))
      } catch (_) { persistent = false }
    }
    if (!persistent) selected = new Map(Array.from(selected).filter(([id]) => visible.has(id)))
  }

  function render() {
    const total = selected.size
    for (const [id, input] of visible) {
      input.checked = selected.get(id) === input.value
      input.disabled = total >= limit && !input.checked
    }
    const hidden = []
    for (const [id, value] of selected) {
      if (visible.has(id)) continue
      const input = form.ownerDocument.createElement("input")
      input.type = "hidden"; input.name = "sources[]"; input.value = value
      hidden.push(input)
    }
    form.querySelector("[data-relearn-hidden]").replaceChildren(...hidden)
    const count = form.querySelector("[data-relearn-count]")
    count.hidden = false
    count.textContent =
      `${total} of ${limit} selected${hidden.length ? ` · ${hidden.length} on other pages` : ""}`
    const clear = form.querySelector("[data-relearn-clear]")
    clear.hidden = false; clear.disabled = total === 0
    form.querySelector("button[type=submit]").disabled = total === 0
    form.querySelector("[data-relearn-help]").textContent =
      (changed ? "A selected message changed and was removed. Review it before selecting again. " : "") +
      (persistent ? "Selections stay in this tab across source searches and pages. Choose messages from one execution mode." :
        "Browser storage is unavailable: selections stay on the current page only. Search before selecting messages.")
  }

  function refresh() {
    form = root.querySelector?.("form[data-relearn-scope]")
    if (!form) return
    const nextScope = form.dataset.relearnScope
    if (scope !== nextScope) { selected = read(nextScope); scope = nextScope; changed = false }
    visible = new Map(Array.from(form.querySelectorAll("input[data-relearn-source]"))
      .filter(input => validItem({id: input.dataset.relearnSource, value: input.value}))
      .map(input => [input.dataset.relearnSource, input]))
    for (const [id, input] of visible) {
      if (selected.has(id) && selected.get(id) !== input.value) { selected.delete(id); changed = true }
    }
    save(); render()
  }

  function change(event) {
    if (event.type !== "change" || !event.target.matches?.("input[data-relearn-source]")) return
    const input = event.target, checked = input.checked
    if (input.form !== form) refresh()
    if (!form || input.form !== form || visible.get(input.dataset.relearnSource) !== input) return
    const id = input.dataset.relearnSource
    if (!checked) selected.delete(id)
    else if (selected.has(id) || selected.size < limit) selected.set(id, input.value)
    changed = false
    save(); render()
  }

  function click(event) {
    const clear = event.target.closest?.("[data-relearn-clear]")
    if (!clear || clear.form !== form) return
    selected.clear(); changed = false
    save(); render()
  }

  refresh()
  return {refresh, change, click}
}
