export async function copyText(button, text, clipboard = navigator.clipboard, schedule = setTimeout) {
  const status = button.querySelector("[data-copy-status]")

  try {
    await clipboard.writeText(text)
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

export function copyValue(button, clipboard = navigator.clipboard, schedule = setTimeout) {
  return copyText(button, button.dataset.copyValue, clipboard, schedule)
}

// A block copies the text it shows. The formatted prompt is drawn one row per
// line, so its line breaks live in the rows rather than in its text; joining
// the rows gives back the document as displayed.
export function blockText(block) {
  const pre = block && block.querySelector("pre")
  if (!pre) return ""

  const rows = pre.querySelectorAll(".prompt-row")
  return rows.length > 0 ? Array.from(rows, row => row.textContent).join("\n") : pre.textContent
}

export function copyValueFromEvent(event) {
  const target = event.target
  if (!target || !target.closest) return

  const button = target.closest("[data-copy-value]")
  if (button) return copyValue(button)

  const blockButton = target.closest("[data-copy-block]")
  if (blockButton) return copyText(blockButton, blockText(blockButton.closest(".copy-block")))
}
