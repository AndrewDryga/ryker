// A form the browser itself submits, rather than through a LiveView event,
// says at once that it is on its way (Andrew, 2026-10-15: a confirmed rating
// looked as if the click had not registered). Its submit buttons read as
// unavailable, the one pressed says what it is doing in the words of its
// phx-disable-with, the same words LiveView shows on a live page, and a
// second submit, by click, Enter or Space, is refused until the next page
// loads. Nothing is disabled, so the button pressed still sends its name and
// value with the form. LiveView's forms, and forms another script took over
// (Chat's composer), stay with their owners: the listener runs after theirs
// and leaves an event they prevented alone. A form that opens elsewhere
// leaves this page as it was. A page the browser restores from its
// back/forward cache shows its forms as they were before the submit.

const SUBMITTERS = "button:not([type]), button[type=submit], input[type=submit]"
const POSITION_KEY = "ryker:confirmation-position"

// A modal is in-place, but its protected POST returns through a new document.
// Keep only that tab's position, for one return to the same page, never form
// values or authority. Static refusals/sign-in pages do not run this module;
// returning from them can keep the reader's place too. Any other live page
// consumes the saved position without scrolling, and old positions expire.
function restorePosition(win, doc) {
  try {
    const value = win.sessionStorage.getItem(POSITION_KEY)
    win.sessionStorage.removeItem(POSITION_KEY)
    const saved = JSON.parse(value)
    if (!saved || saved.page !== win.location.pathname + win.location.search ||
        !Number.isFinite(saved.at) || Date.now() - saved.at < 0 || Date.now() - saved.at > 300_000 ||
        !Number.isFinite(saved.top) || saved.top < 0 || !Number.isFinite(saved.left) || saved.left < 0) return
    const opener = [...doc.querySelectorAll(".action-control")].find(form => form.getAttribute("action") === saved.action)
    const rows = [...doc.querySelectorAll(".entity-row")]
    const row = (saved.row && rows.find(node => node.id === saved.row)) ||
      (Number.isInteger(saved.rowIndex) && saved.rowIndex >= 0 ? rows[Math.min(saved.rowIndex, rows.length - 1)] : null)
    // Cleanup can remove its action or its row. Keep the keyboard in this part
    // of the list, without focusing a different destructive action.
    const destination = opener?.querySelector(SUBMITTERS) || row
    destination?.focus({preventScroll: true})
    win.scrollTo({left: saved.left, top: saved.top, behavior: "instant"})
  } catch (_) { /* Storage can be unavailable or contain an old, malformed value. */ }
}

export function markPending(form, submitter) {
  form.dataset.pending = "true"
  form.setAttribute("aria-busy", "true")
  for (const button of form.querySelectorAll(SUBMITTERS)) {
    if (button.hasAttribute("aria-disabled")) button.dataset.pendingAriaDisabled = button.getAttribute("aria-disabled")
    button.setAttribute("aria-disabled", "true")
  }
  const words = submitter?.getAttribute?.("phx-disable-with")
  if (words && submitter.tagName === "BUTTON") {
    submitter.dataset.pendingRestore = submitter.textContent
    submitter.textContent = words
  }
}

export function restorePending(form) {
  delete form.dataset.pending
  form.removeAttribute("aria-busy")
  for (const button of form.querySelectorAll(SUBMITTERS)) {
    if ("pendingAriaDisabled" in button.dataset) {
      button.setAttribute("aria-disabled", button.dataset.pendingAriaDisabled)
      delete button.dataset.pendingAriaDisabled
    } else {
      button.removeAttribute("aria-disabled")
    }
    if ("pendingRestore" in button.dataset) {
      button.textContent = button.dataset.pendingRestore
      delete button.dataset.pendingRestore
    }
  }
}

export function createPendingForms(environment = {}) {
  const win = environment.window || window
  const doc = environment.document || document
  let openingAction = null
  let openingRow = null

  const onSubmit = event => {
    const form = event.target
    if (!form || form.tagName !== "FORM") return
    // LiveView has already handled opening the question, but the same form's
    // action identifies its original control on the document we return to.
    if (form.matches?.(".action-control")) {
      openingAction = form.getAttribute("action")
      openingRow = form.closest?.(".entity-row")
    }
    if (form.dataset.pending === "true") {
      event.preventDefault()
      return
    }
    if (event.defaultPrevented) return
    const target = form.getAttribute("target")
    if (target && target !== "_self") return
    if (form.matches?.(".kit-modal-form")) {
      try {
        win.sessionStorage.setItem(POSITION_KEY, JSON.stringify({
          page: win.location.pathname + win.location.search, action: openingAction,
          row: openingRow?.id, rowIndex: [...doc.querySelectorAll(".entity-row")].indexOf(openingRow),
          top: win.scrollY, left: win.scrollX, at: Date.now()
        }))
      } catch (_) { /* Saving a position must never stop the confirmed action. */ }
    }
    markPending(form, event.submitter)
  }

  const onPageShow = event => {
    if (!event.persisted) return
    for (const form of doc.querySelectorAll("form[data-pending=true]")) restorePending(form)
  }

  return {
    onSubmit,
    onPageShow,
    start() {
      restorePosition(win, doc)
      win.addEventListener("submit", onSubmit)
      win.addEventListener("pageshow", onPageShow)
    },
    stop() {
      win.removeEventListener("submit", onSubmit)
      win.removeEventListener("pageshow", onPageShow)
    }
  }
}
