export const tooltipId = "ryker-tooltip"

export function tooltipPosition(point, size, viewport, margin = 12, gap = 12) {
  if (viewport.width < 600) return {mobile: true, left: margin, bottom: margin}

  const left = Math.max(margin, Math.min(point.x + gap, viewport.width - size.width - margin))
  const below = point.y + gap
  const top = below + size.height <= viewport.height - margin
    ? below
    : Math.max(margin, point.y - size.height - gap)

  return {mobile: false, left, top}
}

// A hint shows the moment the pointer or focus reaches its element. The
// browser's own title tooltip waits about a second and cannot be styled, so a
// title moves to data-tooltip the first time its element is reached, and the
// native tooltip never doubles ours. A title that was the element's only name
// becomes its aria-label, so assistive technology still reads it.
export function claimTitle(element) {
  const title = element.getAttribute("title")
  if (title === null) return

  element.removeAttribute("title")
  if (title.trim() === "") return

  element.dataset.tooltip = title
  const named =
    element.hasAttribute("aria-label") ||
    element.hasAttribute("aria-labelledby") ||
    (element.textContent || "").trim() !== ""
  if (!named) element.setAttribute("aria-label", title)
}

// What a target shows: a prompt fragment names its section, context and path;
// any other element shows its hint, one line per line of text.
export function hintFor(target) {
  const element = target && target.closest && target.closest(".prompt-fragment, [data-tooltip], [title]")
  if (!element) return null

  if (element.classList.contains("prompt-fragment")) {
    return {
      element,
      kind: "source",
      lines: [
        ["ryker-tooltip-title", element.dataset.sourceTitle],
        ["ryker-tooltip-context", element.dataset.sourceContext],
        ["ryker-tooltip-path", element.dataset.sourcePath]
      ]
    }
  }

  claimTitle(element)
  const text = element.dataset.tooltip
  if (!text) return null

  return {element, kind: "hint", lines: text.split("\n").map(line => ["ryker-tooltip-text", line])}
}

export function setupTooltips(root = document) {
  const tooltip = root.createElement("aside")
  tooltip.id = tooltipId
  tooltip.className = "ryker-tooltip"
  tooltip.setAttribute("role", "tooltip")
  tooltip.hidden = true
  root.body.appendChild(tooltip)

  let active = null
  let pointer = null

  const place = (target, point = null) => {
    const rect = target.getBoundingClientRect()
    const anchor = point || {x: rect.left, y: rect.bottom}
    const position = tooltipPosition(
      anchor,
      {width: tooltip.offsetWidth, height: tooltip.offsetHeight},
      {width: window.innerWidth, height: window.innerHeight}
    )

    tooltip.style.left = `${position.left}px`

    if (position.mobile) {
      tooltip.style.top = "auto"
      tooltip.style.right = "12px"
      tooltip.style.bottom = `${position.bottom}px`
    } else {
      tooltip.style.top = `${position.top}px`
      tooltip.style.right = "auto"
      tooltip.style.bottom = "auto"
    }
  }

  // A prompt fragment is a large block, so its tooltip follows the pointer;
  // a hint sits under the element it describes.
  const show = (hint, point = null) => {
    active = hint.element
    pointer = hint.kind === "source" ? point : null
    tooltip.dataset.kind = hint.kind
    tooltip.replaceChildren()

    for (const [className, value] of hint.lines) {
      const line = root.createElement("span")
      line.className = className
      line.textContent = value || ""
      tooltip.appendChild(line)
    }

    if (hint.kind === "hint") active.setAttribute("aria-describedby", tooltipId)
    tooltip.hidden = false
    place(active, pointer)
  }

  const hide = () => {
    if (active && tooltip.dataset.kind === "hint") active.removeAttribute("aria-describedby")
    active = null
    pointer = null
    tooltip.hidden = true
  }

  root.addEventListener("pointerover", event => {
    const hint = hintFor(event.target)
    if (hint && hint.element !== active) show(hint, {x: event.clientX, y: event.clientY})
  })

  root.addEventListener("pointermove", event => {
    if (active && pointer && active.contains(event.target)) {
      pointer = {x: event.clientX, y: event.clientY}
      place(active, pointer)
    }
  })

  root.addEventListener("pointerout", event => {
    if (active && active.contains(event.target) && !active.contains(event.relatedTarget)) hide()
  })

  root.addEventListener("focusin", event => {
    const hint = hintFor(event.target)
    if (hint) show(hint)
  })

  root.addEventListener("focusout", event => {
    if (active && active.contains(event.target) && !active.contains(event.relatedTarget)) hide()
  })

  root.addEventListener("keydown", event => {
    if (event.key === "Escape" && active) {
      const target = active
      hide()
      target.focus?.()
    }
  })

  window.addEventListener("resize", () => {
    if (active && !tooltip.hidden) place(active, pointer)
  })

  return tooltip
}
