import {createLeaveGuard} from "./leave-guard.mjs"

// An unsaved settings section lives in server-side component state, so leaving
// the page discards it silently. The forms themselves report dirtiness; this
// never decides it.
export function createSettingsGuard(root, environment = {}) {
  const dirty = () => root.querySelectorAll("form[data-dirty=true]").length > 0
  const guard = createLeaveGuard({dirty, message: "Leave without saving these settings?"}, environment)
  return {dirty, destroy: guard.destroy}
}
