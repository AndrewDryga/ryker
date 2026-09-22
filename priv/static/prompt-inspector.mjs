export const promptInspectorTooltipId = "prompt-inspector-tooltip"

export function tooltipPosition(point, size, viewport, margin = 12, gap = 12) {
  if (viewport.width < 600) return {mobile: true, left: margin, bottom: margin}

  const left = Math.max(margin, Math.min(point.x + gap, viewport.width - size.width - margin))
  const below = point.y + gap
  const top = below + size.height <= viewport.height - margin
    ? below
    : Math.max(margin, point.y - size.height - gap)

  return {mobile: false, left, top}
}

export function setupPromptInspector(root = document) {
  const tooltip = root.createElement("aside")
  tooltip.id = promptInspectorTooltipId
  tooltip.className = "prompt-inspector-tooltip"
  tooltip.setAttribute("role", "tooltip")
  tooltip.hidden = true
  root.body.appendChild(tooltip)

  let active = null
  let pointer = null

  const fragment = target => target.closest && target.closest(".prompt-fragment")

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

  const show = (target, point = null) => {
    active = target
    pointer = point
    tooltip.replaceChildren()

    for (const [className, value] of [
      ["prompt-inspector-title", target.dataset.sourceTitle],
      ["prompt-inspector-context", target.dataset.sourceContext],
      ["prompt-inspector-path", target.dataset.sourcePath]
    ]) {
      const line = root.createElement("span")
      line.className = className
      line.textContent = value || ""
      tooltip.appendChild(line)
    }

    tooltip.hidden = false
    place(target, point)
  }

  const hide = () => {
    active = null
    pointer = null
    tooltip.hidden = true
  }

  root.addEventListener("pointerover", event => {
    const target = fragment(event.target)
    if (target) show(target, {x: event.clientX, y: event.clientY})
  })

  root.addEventListener("pointermove", event => {
    const target = fragment(event.target)
    if (target && target === active) {
      pointer = {x: event.clientX, y: event.clientY}
      place(target, pointer)
    }
  })

  root.addEventListener("pointerout", event => {
    const target = fragment(event.target)
    if (target && !target.contains(event.relatedTarget)) hide()
  })

  root.addEventListener("focusin", event => {
    const target = fragment(event.target)
    if (target) show(target)
  })

  root.addEventListener("focusout", event => {
    const target = fragment(event.target)
    if (target && !target.contains(event.relatedTarget)) hide()
  })

  root.addEventListener("keydown", event => {
    if (event.key === "Escape" && active) {
      const target = active
      hide()
      target?.focus()
    }
  })

  window.addEventListener("resize", () => {
    if (active && !tooltip.hidden) place(active, pointer)
  })

  return tooltip
}
