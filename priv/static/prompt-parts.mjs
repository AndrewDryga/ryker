// A prompt is read one part at a time. Choosing a part in the legend highlights
// only that part's fragments; choosing it again returns the prompt to plain
// text. Highlighting every part at once made each one impossible to find.
//
// The state lives in the DOM under the document's phx-update="ignore"
// container, so the page's LiveView patches leave the chosen part alone.

export function selectPart(container, part) {
  const chips = [...container.querySelectorAll(".prompt-part")]
  const active = chips.find(chip => chip.getAttribute("aria-pressed") === "true")
  const next = active && active.dataset.promptPart === part ? null : part
  let first = null

  for (const chip of chips) {
    chip.setAttribute("aria-pressed", String(chip.dataset.promptPart === next))
  }

  for (const fragment of container.querySelectorAll(".prompt-fragment")) {
    const chosen = fragment.dataset.part === next
    fragment.classList.toggle("is-highlighted", chosen)
    if (chosen && !first) first = fragment
  }

  container.classList.toggle("has-highlight", next !== null)
  return first
}

// Scroll the prompt box, not the page, so the legend stays where the reader
// clicked it.
export function revealFragment(container, fragment, reduceMotion = false) {
  const scroller = container.querySelector(".submitted-prompt-formatted")
  if (!scroller || !fragment) return

  const offset = fragment.getBoundingClientRect().top - scroller.getBoundingClientRect().top
  scroller.scrollTo({
    top: Math.max(0, scroller.scrollTop + offset - 24),
    behavior: reduceMotion ? "auto" : "smooth"
  })
}

export function promptPartFromEvent(event, root = document) {
  const target = event.target
  if (!target || !target.closest) return

  const chip = target.closest(".prompt-part")
  const fragment = chip ? null : target.closest(".prompt-fragment")
  const container = (chip || fragment) && (chip || fragment).closest(".prompt-document")
  if (!container) return

  if (chip) {
    const first = selectPart(container, chip.dataset.promptPart)
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    revealFragment(container, first, reduce)
    return
  }

  // Clicking text names its part, but never undoes a chosen highlight or
  // steals a text selection the reader is making.
  const selection = root.getSelection && root.getSelection()
  if (selection && !selection.isCollapsed) return
  if (!fragment.classList.contains("is-highlighted")) selectPart(container, fragment.dataset.part)
}

export function setupPromptParts(root = document) {
  root.addEventListener("click", event => promptPartFromEvent(event, root))
}
