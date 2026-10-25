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

export async function promptPartFromEvent(event, root = document) {
  const target = event.target
  if (!target || !target.closest) return

  const source = target.closest("[data-prompt-highlight]")
  if (source) {
    event.preventDefault?.()
    event.stopPropagation?.()
    if (source.getAttribute?.("aria-disabled") === "true") return
    const disclosure = root.getElementById(source.dataset.promptDisclosure)
    if (!disclosure || disclosure.dataset?.revoked) return unavailableSource(source)
    disclosure.open = true

    // Opening the original disclosure uses the existing lazy-artifact path.
    // Wait only for that retained document; never rebuild it from source rows.
    let container = root.getElementById(source.dataset.promptDocument)
    if (!container) {
      container = await new Promise(resolve => {
        const observer = new MutationObserver(() => {
          const found = root.getElementById(source.dataset.promptDocument)
          if (disclosure.dataset?.revoked) finish(null)
          else if (found || !source.isConnected) finish(found)
        })
        const timeout = setTimeout(() => finish(null), 10000)
        function finish(found) {
          observer.disconnect()
          clearTimeout(timeout)
          resolve(found)
        }
        observer.observe(disclosure, {childList: true, subtree: true, attributes: true, attributeFilter: ["data-revoked"]})
      })
    }
    const current = root.getElementById(source.dataset.promptDisclosure)
    if (!container || !current || current.dataset?.revoked || source.isConnected === false) return unavailableSource(source)
    const first = [...container.querySelectorAll(".prompt-fragment")]
      .find(fragment => fragment.dataset.part === source.dataset.promptHighlight)
    if (!first) return unavailableSource(source, "This section is not in the retained prompt.")
    // A source button always selects, rather than toggling an existing choice.
    const active = container.querySelector('.prompt-part[aria-pressed="true"]')
    if (active?.dataset.promptPart !== source.dataset.promptHighlight) {
      selectPart(container, source.dataset.promptHighlight)
    }
    container.scrollIntoView({block: "nearest"})
    first?.focus({preventScroll: true})
    revealFragment(container, first, true)
    return
  }

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

function unavailableSource(source, message = "The retained prompt is not available.") {
  const status = source.querySelector("[data-highlight-status]")
  if (status) status.textContent = message
  source.disabled = true
  source.setAttribute?.("aria-disabled", "true")
  source.removeAttribute?.("href")
}

export function setupPromptParts(root = document) {
  root.addEventListener("click", event => promptPartFromEvent(event, root))
}
