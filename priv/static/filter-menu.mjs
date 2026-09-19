// The + Filter menu cascades: the field list stays put and each field's values
// open beside it on hover, click or ArrowRight, so choosing a field never
// replaces the list without a way back. Focus alone opens nothing: the menu
// focuses its first field on opening, and on a phone that would cover the list. The server owns whether the menu is open and
// renders every field's values as a hidden panel; this owns which panel shows,
// where it sits, and the keys that move between the list and its values.

const PANEL_WIDTH = 248
const SWITCH_DELAY = 120

export const createFilterMenu = (el, env = {}) => {
  const win = env.window || window
  const setTimer = env.setTimeout || ((fn, ms) => win.setTimeout(fn, ms))
  const clearTimer = env.clearTimeout || (id => win.clearTimeout(id))
  let active = null
  let pending = null

  const fieldFor = key => el.querySelector(`.filter-field[data-field="${key}"]`)
  const panelFor = key => el.querySelector(`.filter-values[data-field="${key}"]`)

  const cancel = () => {
    clearTimer(pending)
    pending = null
  }

  // The panel lines up with its field; phones cover the list with it instead.
  const align = (panel, field) => {
    if (el.classList.contains("stacked")) return
    const list = el.querySelector(".filter-fields")
    panel.style.top = `${Math.max(0, field.offsetTop - (list?.scrollTop || 0) - 6)}px`
  }

  const hide = () => {
    cancel()
    if (!active) return
    const panel = panelFor(active)
    if (panel) panel.hidden = true
    fieldFor(active)?.setAttribute("aria-expanded", "false")
    active = null
  }

  const show = (key, {focus = false} = {}) => {
    cancel()
    const panel = panelFor(key)
    const field = fieldFor(key)
    if (!panel || !field) return false
    if (active !== key) hide()
    active = key
    panel.hidden = false
    field.setAttribute("aria-expanded", "true")
    align(panel, field)
    if (focus) panel.querySelector("button:not([data-back]), input:not([type=hidden])")?.focus()
    return true
  }

  const back = () => {
    const key = active
    hide()
    if (key) fieldFor(key)?.focus()
  }

  // While one panel is open, a hover over another field switches only after a
  // short pause, so a pointer crossing the list toward the open panel keeps it.
  const hover = key => {
    if (!active) return show(key)
    if (key === active) return cancel()
    cancel()
    pending = setTimer(() => show(key), SWITCH_DELAY)
  }

  const place = () => {
    el.classList.remove("align-end", "opens-start")
    el.classList.toggle("stacked", win.innerWidth <= 800)
    if (el.classList.contains("stacked")) return
    if (el.getBoundingClientRect().right > win.innerWidth - 8) el.classList.add("align-end")
    if (win.innerWidth - el.getBoundingClientRect().right < PANEL_WIDTH + 12) el.classList.add("opens-start")
  }

  return {
    get active() { return active },
    show, hide, back, place,
    pointerOver(event) {
      const field = event.target?.closest?.(".filter-field")
      if (field) { hover(field.dataset.field); return true }
      if (event.target?.closest?.(".filter-values")) cancel()
      return false
    },
    click(event) {
      if (event.target?.closest?.("[data-back]")) { back(); return true }
      const field = event.target?.closest?.(".filter-field")
      return field ? show(field.dataset.field, {focus: true}) : false
    },
    keydown(event) {
      const field = event.target?.closest?.(".filter-field")
      if (field) {
        if (event.key === "ArrowRight") {
          event.preventDefault()
          return show(field.dataset.field, {focus: true})
        }
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
          event.preventDefault()
          const fields = Array.from(el.querySelectorAll(".filter-field"))
          const step = event.key === "ArrowDown" ? 1 : fields.length - 1
          fields[(fields.indexOf(field) + step) % fields.length]?.focus()
          return true
        }
        return false
      }
      // Escape or ArrowLeft inside the values steps back to the field; the
      // window Escape that closes the whole menu must not also fire.
      const typing = event.target?.tagName === "INPUT"
      if (event.target?.closest?.(".filter-values") && (event.key === "Escape" || (event.key === "ArrowLeft" && !typing))) {
        event.preventDefault()
        event.stopPropagation()
        back()
        return true
      }
      return false
    },
    // A server patch renders every panel hidden again; the open one comes back.
    restore() {
      const key = active
      active = null
      place()
      if (key) show(key)
    }
  }
}

export const FilterMenu = {
  mounted() {
    this.menu = createFilterMenu(this.el)
    this.listeners = {
      mouseover: event => this.menu.pointerOver(event),
      click: event => this.menu.click(event),
      keydown: event => this.menu.keydown(event)
    }
    for (const [name, listener] of Object.entries(this.listeners)) this.el.addEventListener(name, listener)
    this.menu.place()
    this.el.querySelector(".filter-field")?.focus()
  },
  updated() { this.menu.restore() },
  destroyed() { this.menu.hide() }
}
