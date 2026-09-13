// A filter toolbar has no Apply button: choosing a dropdown value submits
// that toolbar's own GET form at once, so the URL stays shareable and the
// browser history stays honest. Only a form marked as a filter toolbar
// qualifies. Pause/Resume/Delete confirmations, the settings editor and the
// memory relearn picker hold selects too, and a stray change there must not
// perform, or even open, anything.
export const filterToolbar = control => {
  const form = control?.form
  if (!form || control.tagName !== "SELECT") return null
  if (!form.matches?.("form.filter-toolbar")) return null
  if ((form.method || "get").toLowerCase() !== "get") return null
  return form
}

export const applyFilterChange = event => {
  const form = filterToolbar(event?.target)
  if (!form) return false
  if (typeof form.requestSubmit === "function") form.requestSubmit()
  else form.submit()
  return true
}
