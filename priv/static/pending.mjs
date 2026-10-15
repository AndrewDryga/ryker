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

  const onSubmit = event => {
    const form = event.target
    if (!form || form.tagName !== "FORM") return
    if (form.dataset.pending === "true") {
      event.preventDefault()
      return
    }
    if (event.defaultPrevented) return
    const target = form.getAttribute("target")
    if (target && target !== "_self") return
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
      win.addEventListener("submit", onSubmit)
      win.addEventListener("pageshow", onPageShow)
    },
    stop() {
      win.removeEventListener("submit", onSubmit)
      win.removeEventListener("pageshow", onPageShow)
    }
  }
}
