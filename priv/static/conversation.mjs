// Conversation page controls that live in the browser: the narrow-screen
// directory drawer, the Examples fill-in, and following the first send of an
// index draft to the conversation it created. Nothing here submits a message,
// calls a model or discards typed text.

const conversationAction = /^\/conversations\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/messages$/i

// The identity a composer posts to, or null when its action is not a
// conversation send. The browser keeps the composer it first rendered, so the
// form's action, not the server's later assigns, says where the message went.
export const conversationFromAction = action => {
  const match = conversationAction.exec(action || "")
  return match ? match[1].toLowerCase() : null
}

// After a 202 receipt from an index draft, ask the server to open the exact
// conversation the message was accepted into. Only the index form (marked
// data-draft-action="new") navigates; an open conversation stays where it is.
export const followSentDraft = (form, pushEvent) => {
  if (!form?.dataset || form.dataset.draftAction !== "new") return null
  const id = conversationFromAction(form.getAttribute("action"))
  if (id) pushEvent("open-conversation", {id})
  return id
}

// Fills the composer with an authored example without discarding what is
// already typed, and without sending: a filled draft still needs Send.
export const fillExample = (textarea, example) => {
  if (!textarea || typeof example !== "string") return false
  const current = textarea.value || ""
  textarea.value = current.trim() === "" ? example : `${current.replace(/\s+$/, "")}\n${example}`
  textarea.dispatchEvent(new Event("input", {bubbles: true}))
  const end = textarea.value.length
  if (typeof textarea.setSelectionRange === "function") textarea.setSelectionRange(end, end)
  textarea.focus()
  return true
}

export const createConversationControls = (root, options = {}) => {
  const win = options.window || (typeof window === "undefined" ? {location: {pathname: ""}} : window)
  let open = false
  let openedAt = null

  const directory = () => root.querySelector?.("#lab-directory") || null
  const toggle = () => root.querySelector?.("[data-lab-directory-toggle]") || null

  const apply = () => {
    const panel = directory()
    const button = toggle()
    if (panel) panel.classList.toggle("is-open", open)
    if (button) button.setAttribute("aria-expanded", open ? "true" : "false")
  }

  const openDirectory = () => {
    open = true
    openedAt = win.location.pathname
    apply()
    // Focus enters the drawer so keyboard and screen-reader users land on
    // what just opened; Escape or Close returns them to the toggle.
    directory()?.querySelector("[data-lab-directory-close]")?.focus()
  }

  const closeDirectory = (returnFocus = true) => {
    if (!open) return
    open = false
    openedAt = null
    apply()
    if (returnFocus) toggle()?.focus()
  }

  return {
    get open() { return open },
    click(event) {
      const target = event.target
      if (!target?.closest) return false
      if (target.closest("[data-lab-directory-toggle]")) {
        if (open) closeDirectory(); else openDirectory()
        return true
      }
      if (target.closest("[data-lab-directory-close]")) { closeDirectory(); return true }
      const example = target.closest(".lab-example")
      if (example) {
        fillExample(root.querySelector?.("#lab-message"), example.dataset.example)
        const list = example.closest("details")
        if (list) list.open = false
        return true
      }
      if (open && !target.closest("#lab-directory")) {
        // Choosing a conversation navigates; clicking the backdrop just closes.
        closeDirectory(false)
        return true
      }
      return false
    },
    keydown(event) {
      if (event.key === "Escape" && open) { closeDirectory(); return true }
      return false
    },
    // A live patch re-renders the drawer closed; keep the operator's state
    // unless they navigated away from where they opened it.
    refresh() {
      if (open && openedAt !== win.location.pathname) open = false
      apply()
    },
    destroy() { open = false }
  }
}
