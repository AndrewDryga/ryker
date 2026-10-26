const duration = seconds => {
  const minutes = Math.floor(seconds / 60)
  const hours = Math.floor(minutes / 60)
  const days = Math.floor(hours / 24)
  const parts = days > 0 ? [[days, "day"], [hours % 24, "hour"]]
    : hours > 0 ? [[hours, "hour"], [minutes % 60, "minute"]] : [[minutes, "minute"]]
  return parts.filter(([count]) => count > 0)
    .map(([count, unit]) => `${count} ${unit}${count === 1 ? "" : "s"}`).join(" ")
}

export const formatCountdown = seconds => {
  if (seconds > 0 && seconds < 60) return "Next run in less than a minute"
  if (seconds <= 0 && seconds > -60) return "Due now"
  return seconds < 0 ? `Overdue by ${duration(-seconds)}` : `Next run in ${duration(seconds)}`
}

export const createScheduleCountdown = (element, options = {}) => {
  const now = options.now || (() => performance.now())
  const every = options.setInterval || globalThis.setInterval
  const cancel = options.clearInterval || globalThis.clearInterval
  let remaining = 0
  let observedAt = 0
  let timer = null
  const render = () => {
    element.textContent = formatCountdown(remaining - Math.floor((now() - observedAt) / 1000))
  }
  const reset = () => {
    remaining = Number(element.dataset.remainingSeconds)
    observedAt = now()
    render()
  }
  return {
    mounted() { reset(); timer = every(render, 1000) },
    updated: reset,
    destroyed() { if (timer !== null) cancel(timer) }
  }
}

export const ScheduleCountdown = {
  mounted() { this.countdown = createScheduleCountdown(this.el); this.countdown.mounted() },
  updated() { this.countdown.updated() },
  destroyed() { this.countdown.destroyed() }
}
