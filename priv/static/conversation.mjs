import {transferLegacyDraft, adoptRetiredKey} from "./drafts.mjs"

// Conversation page controls that live in the browser: the narrow-screen
// directory drawer, the Examples fill-in, following the first send of an
// index draft to the conversation it created, and the inline message editor.
// Nothing here rewrites the transcript: every change is posted to the exact
// message's own route and comes back through the live stream.

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

// The same limits the server enforces for an edit, checked before anything
// leaves the browser so a rejection never costs the typed text.
export const validateEdit = text => {
  const bytes = new TextEncoder().encode(text).byteLength
  if (bytes > 20000) return `Message is ${bytes.toLocaleString("en-US")} bytes; maximum is 20,000.`
  if (text.includes("\u0000")) return "Remove the null character from your message."
  if (text.trim() === "") return "The message cannot be empty."
  return ""
}

// A custom emoji name the way the server accepts it: lower-case, no
// surrounding colons or whitespace. Validation happens beside the field.
export const normalizeEmojiName = value =>
  String(value ?? "").trim().replace(/^:+|:+$/g, "").trim().toLowerCase()

const emojiNamePattern = /^[a-z0-9_+-]{1,100}$/

const reactionFailureText = error => {
  switch (error?.message) {
    case "rejected:404": return "This reply is no longer available to react to. Reload the conversation to see its current state."
    case "rejected:422": return "The server did not accept that emoji name. Use letters, digits, _, + or -."
    case "rejected:403": return "This reaction could not be confirmed. Reload the conversation and try again."
    default: return "The reaction was not confirmed. Check the conversation before trying again; nothing was retried."
  }
}

const failureText = error => {
  switch (error?.message) {
    case "rejected:409": return "This message was deleted or changed while you were editing. Reload the conversation to see its current state; your text is kept here."
    case "rejected:422": return "The edit was rejected: the message must be plain text, not empty, and under 20,000 bytes."
    case "rejected:403": return "This edit could not be confirmed. Reload the conversation and try again; your text is kept here."
    default: return "The edit was not confirmed. Your text is kept; check the conversation before saving again."
  }
}

// Posts a form the way the composer does and resolves only on a positive
// 202 receipt; every other answer, including a lost connection, throws.
const receipt = async (form, fetcher) => {
  const body = new URLSearchParams()
  for (const field of form.elements || []) if (field.name && !field.disabled) body.append(field.name, field.value)
  // A field named "action" shadows form.action, so read the attribute.
  const response = await fetcher(form.getAttribute("action"), {
    method: "POST", body, credentials: "same-origin", redirect: "error",
    headers: {Accept: "application/json"}
  })
  if ([400, 403, 404, 409, 413, 422].includes(response.status)) throw new Error(`rejected:${response.status}`)
  if (response.status !== 202) throw new Error("not_accepted")
  const data = await response.json()
  if (data.accepted !== true) throw new Error("unconfirmed_receipt")
}

export const createConversationControls = (root, options = {}) => {
  const win = options.window || (typeof window === "undefined" ? {location: {pathname: ""}} : window)
  const doc = options.document || (typeof document === "undefined" ? null : document)
  const storage = options.storage || (() => sessionStorage)
  const fetcher = options.fetcher || ((...args) => fetch(...args))
  const pushEvent = options.pushEvent || (() => {})
  const path = () => win.location.pathname
  let open = false
  let openedAt = null
  let editing = null
  let saving = false

  const store = {
    // A key written before the 2026-09-13 rename is carried over on first read.
    get(key) {
      try {
        if (key.startsWith("ryker:draft:")) transferLegacyDraft(key, storage()); else adoptRetiredKey(key, storage())
        return storage().getItem(key)
      } catch (_) { return null }
    },
    set(key, value) { try { storage().setItem(key, value) } catch (_) { /* A storage failure loses nothing typed. */ } },
    remove(key) { try { storage().removeItem(key) } catch (_) {} }
  }

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
    openedAt = path()
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

  // Inline editing. The editor is the hidden form the server renders under
  // each editable message; its open state and unsaved text live here and in
  // session storage, so a live patch or a reconnect puts them back.
  const editingKey = () => `ryker:editing:${path()}`
  const editDraftKey = id => `ryker:draft:${path()}:${path()}/messages/${id}/edit:message`
  const editorFor = id => (doc && id) ? doc.getElementById(`lab-edit-${id}`) : null
  const fieldOf = form => form.querySelector("textarea[name=message]")
  const toggleFor = form => form.closest("article")?.querySelector(".lab-edit-toggle") || null
  const autosize = field => { if (field?.style) { field.style.height = "auto"; field.style.height = `${field.scrollHeight}px` } }

  const showError = (form, message) => {
    const error = form.querySelector(".lab-edit-error")
    if (!error) return
    error.textContent = message
    error.hidden = false
    fieldOf(form)?.setAttribute?.("aria-describedby", error.id)
  }

  const clearError = form => {
    const error = form.querySelector(".lab-edit-error")
    if (!error) return
    error.hidden = true
    error.textContent = ""
    fieldOf(form)?.removeAttribute?.("aria-describedby")
  }

  const showEditor = (form, {focus = true, value} = {}) => {
    const field = fieldOf(form)
    form.hidden = false
    form.closest("article")?.classList.add("is-editing")
    toggleFor(form)?.setAttribute("aria-expanded", "true")
    if (typeof value === "string" && field.value !== value) field.value = value
    autosize(field)
    if (focus) {
      field.focus()
      const end = field.value.length
      if (typeof field.setSelectionRange === "function") field.setSelectionRange(end, end)
    }
  }

  const hideEditor = (form, {restore = false} = {}) => {
    const field = fieldOf(form)
    if (restore && field) field.value = field.defaultValue
    form.hidden = true
    form.closest("article")?.classList.remove("is-editing")
    toggleFor(form)?.setAttribute("aria-expanded", "false")
    clearError(form)
  }

  const openEdit = button => {
    const id = (button.getAttribute("aria-controls") || "").replace(/^lab-edit-/, "")
    const form = editorFor(id)
    if (!form) return false
    if (editing && editing.id === id) { cancelEdit(form); return true }
    if (editing && editing.id !== id) { const other = editorFor(editing.id); if (other) hideEditor(other) }
    editing = {id}
    store.set(editingKey(), id)
    const draft = store.get(editDraftKey(id))
    showEditor(form, {value: draft === null ? undefined : draft})
    return true
  }

  const cancelEdit = form => {
    const id = form.dataset?.labEdit
    if (id) store.remove(editDraftKey(id))
    store.remove(editingKey())
    editing = null
    hideEditor(form, {restore: true})
    toggleFor(form)?.focus()
  }

  const saveEdit = async form => {
    const field = fieldOf(form)
    const problem = validateEdit(field.value)
    if (problem) { showError(form, problem); field.focus(); return }
    clearError(form)
    saving = true
    const save = form.querySelector(".lab-edit-save")
    if (save) { save.disabled = true; save.setAttribute("aria-busy", "true") }
    try {
      await receipt(form, fetcher)
      const id = form.dataset?.labEdit
      if (id) store.remove(editDraftKey(id))
      store.remove(editingKey())
      editing = null
      // The saved text stays in the field until the live stream renders the
      // accepted revision; the transcript is never rewritten from here.
      hideEditor(form)
      pushEvent("refresh", {})
    } catch (error) {
      showError(form, failureText(error))
    } finally {
      saving = false
      if (save) { save.disabled = false; save.removeAttribute("aria-busy") }
    }
  }

  // A message that vanished while its editor was open is said out loud, with
  // the unsaved text kept on screen, instead of the editor silently closing.
  const reportLostEditor = () => {
    const id = editing.id
    const text = store.get(editDraftKey(id)) || ""
    const notices = root.querySelector?.("#lab-notices")
    if (notices && doc) {
      const notice = doc.createElement("div")
      notice.className = "lab-notice"
      notice.setAttribute("role", "alert")
      const message = doc.createElement("p")
      message.textContent = "The message you were editing is no longer available to edit. Your unsaved text is kept here:"
      const kept = doc.createElement("pre")
      kept.textContent = text
      const dismiss = doc.createElement("button")
      dismiss.type = "button"
      dismiss.className = "lab-notice-dismiss"
      dismiss.textContent = "Dismiss"
      dismiss.addEventListener("click", () => notice.remove())
      notice.appendChild(message)
      notice.appendChild(kept)
      notice.appendChild(dismiss)
      notices.appendChild(notice)
    }
    store.remove(editDraftKey(id))
    store.remove(editingKey())
    editing = null
  }

  // Reactions. Pills and the picker post the real add/remove contract to the
  // exact reply; nothing changes on screen until the live stream reflects the
  // accepted event. The picker is ignored by live patches, so its open state
  // here is what a refresh has to put back.
  let picker = null

  const pickerFor = button => doc?.getElementById(button.getAttribute("aria-controls") || "") || null
  const pickerToggle = panel => panel.closest(".lab-message-actions")?.querySelector(".lab-reaction-toggle") || null

  const setPicker = (panel, shown) => {
    panel.hidden = !shown
    pickerToggle(panel)?.setAttribute("aria-expanded", shown ? "true" : "false")
  }

  const openPicker = button => {
    const panel = pickerFor(button)
    if (!panel) return false
    if (picker && picker.id !== panel.id) { const other = doc.getElementById(picker.id); if (other) setPicker(other, false) }
    picker = {id: panel.id}
    setPicker(panel, true)
    panel.querySelector(".lab-reaction-quick button, .lab-reaction-custom input[name=emoji]")?.focus()
    return true
  }

  const closePicker = (returnFocus = true) => {
    if (!picker) return
    const panel = doc?.getElementById(picker.id)
    picker = null
    if (!panel) return
    setPicker(panel, false)
    if (returnFocus) pickerToggle(panel)?.focus()
  }

  const reactionError = (form, message) => {
    const error = form.querySelector(".lab-reaction-error")
    const field = form.querySelector("input[name=emoji]")
    if (error) { error.textContent = message; error.hidden = false }
    if (message && field?.matches?.("input")) field.setAttribute("aria-invalid", "true")
    if (!message && field?.removeAttribute) field.removeAttribute("aria-invalid")
  }

  const clearReactionError = form => {
    const error = form.querySelector(".lab-reaction-error") || form.closest(".lab-reaction-picker")?.querySelector(".lab-reaction-error")
    if (error) { error.hidden = true; error.textContent = "" }
    form.querySelector("input[name=emoji]")?.removeAttribute?.("aria-invalid")
  }

  const sendReaction = async form => {
    if (form.dataset?.pending) return
    const custom = form.matches(".lab-reaction-custom")
    const field = form.querySelector("input[name=emoji]")
    if (custom) {
      const name = normalizeEmojiName(field.value)
      if (!emojiNamePattern.test(name)) {
        reactionError(form, "Use an emoji name made of letters, digits, _, + or -, up to 100 characters.")
        field.focus()
        return
      }
      field.value = name
    }
    clearReactionError(form)
    form.dataset.pending = "true"
    const buttons = Array.from(form.querySelectorAll?.("button") || [])
    buttons.forEach(button => { button.disabled = true; button.setAttribute?.("aria-busy", "true") })
    try {
      await receipt(form, fetcher)
      if (custom) field.value = ""
      if (form.closest(".lab-reaction-picker")) closePicker()
      pushEvent("refresh", {})
    } catch (error) {
      const inPicker = form.closest(".lab-reaction-picker")
      const slot = custom ? form : inPicker?.querySelector(".lab-reaction-custom")
      if (slot) reactionError(slot, reactionFailureText(error))
      else {
        const notices = root.querySelector?.("#lab-notices")
        if (notices && doc) {
          const notice = doc.createElement("p")
          notice.className = "lab-notice"
          notice.setAttribute("role", "alert")
          notice.textContent = reactionFailureText(error)
          notices.appendChild(notice)
        }
      }
    } finally {
      delete form.dataset.pending
      buttons.forEach(button => { button.disabled = false; button.removeAttribute?.("aria-busy") })
    }
  }

  const performAction = async form => {
    if (form.dataset?.pending) return
    form.dataset.pending = "true"
    const buttons = Array.from(form.querySelectorAll?.("button") || [])
    buttons.forEach(button => { button.disabled = true })
    try {
      await receipt(form, fetcher)
      pushEvent("refresh", {})
    } catch (error) {
      const notices = root.querySelector?.("#lab-notices")
      if (notices && doc) {
        const notice = doc.createElement("p")
        notice.className = "lab-notice"
        notice.setAttribute("role", "alert")
        notice.textContent = error?.message?.startsWith("rejected:")
          ? "The server did not accept this action. Reload the conversation to see its current state."
          : "This action was not confirmed. Check the conversation before trying again; nothing was retried."
        notices.appendChild(notice)
      }
    } finally {
      delete form.dataset.pending
      buttons.forEach(button => { button.disabled = false })
    }
  }

  return {
    get open() { return open },
    get editing() { return editing },
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
      const edit = target.closest(".lab-edit-toggle")
      if (edit) return openEdit(edit)
      const cancel = target.closest(".lab-edit-cancel")
      if (cancel) { const form = cancel.closest(".lab-edit-form"); if (form) cancelEdit(form); return true }
      const react = target.closest(".lab-reaction-toggle")
      if (react) {
        const panel = pickerFor(react)
        if (panel && picker && picker.id === panel.id) { closePicker(); return true }
        return openPicker(react)
      }
      if (picker && !target.closest(".lab-reaction-picker")) { closePicker(false); return true }
      if (open && !target.closest("#lab-directory")) {
        // Choosing a conversation navigates; clicking the backdrop just closes.
        closeDirectory(false)
        return true
      }
      return false
    },
    keydown(event) {
      const form = event.target?.closest?.(".lab-edit-form")
      if (form && event.target.tagName === "TEXTAREA") {
        if (event.key === "Escape") { cancelEdit(form); return true }
        if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
          event.preventDefault()
          if (!saving) saveEdit(form)
          return true
        }
        return false
      }
      if (event.key === "Escape" && picker) { closePicker(); return true }
      if (event.key === "Escape" && open) { closeDirectory(); return true }
      return false
    },
    input(event) {
      const form = event.target?.closest?.(".lab-edit-form")
      if (!form || event.target.tagName !== "TEXTAREA") return false
      const id = form.dataset?.labEdit
      if (id) store.set(editDraftKey(id), event.target.value)
      autosize(event.target)
      return true
    },
    // Returns a promise while a save is running, true when the event was
    // handled without a request (a second submit during a save), false when
    // the form is not ours.
    submit(event) {
      const form = event.target
      if (!form?.matches) return false
      if (form.matches(".lab-edit-form")) {
        event.preventDefault()
        if (saving) return true
        return saveEdit(form)
      }
      if (form.matches(".lab-reaction-form")) {
        event.preventDefault()
        return sendReaction(form)
      }
      if (form.matches(".lab-action-form")) {
        event.preventDefault()
        return performAction(form)
      }
      return false
    },
    // After a reconnect the server renders every editor closed; an editor the
    // operator had open comes back with its draft, without stealing focus.
    restore() {
      const id = store.get(editingKey())
      if (!id) return false
      const form = editorFor(id)
      if (!form) { store.remove(editingKey()); return false }
      editing = {id}
      const draft = store.get(editDraftKey(id))
      showEditor(form, {focus: false, value: draft === null ? undefined : draft})
      return true
    },
    // A live patch re-renders the drawer and every editor closed; keep the
    // operator's state unless they navigated away from where they opened it.
    refresh() {
      if (open && openedAt !== path()) open = false
      apply()
      if (editing) {
        const form = editorFor(editing.id)
        if (!form) {
          reportLostEditor()
        } else {
          const draft = store.get(editDraftKey(editing.id))
          showEditor(form, {focus: false, value: draft === null ? undefined : draft})
        }
      }
      if (picker) {
        const panel = doc?.getElementById(picker.id)
        if (panel) setPicker(panel, true); else picker = null
      }
    },
    destroy() {
      closePicker(false)
      open = false
      editing = null
    }
  }
}
