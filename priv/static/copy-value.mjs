export async function copyValue(button, clipboard = navigator.clipboard, schedule = setTimeout) {
  const status = button.querySelector("[data-copy-status]")

  try {
    await clipboard.writeText(button.dataset.copyValue)
    button.dataset.copyState = "copied"
    if (status) status.textContent = "Copied"

    schedule(() => {
      delete button.dataset.copyState
      if (status) status.textContent = ""
    }, 1600)
  } catch (_error) {
    button.dataset.copyState = "failed"
    if (status) status.textContent = "Copy failed"
  }
}

export function copyValueFromEvent(event) {
  const button = event.target.closest && event.target.closest("[data-copy-value]")
  if (button) copyValue(button)
}
