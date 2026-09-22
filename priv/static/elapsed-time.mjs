export const formatElapsed = milliseconds => {
  const seconds = Math.max(0, Math.floor(Number(milliseconds) / 1000) || 0)
  if (seconds === 0) return "now"
  if (seconds < 60) return `${seconds}s`

  const minutes = Math.floor(seconds / 60)
  const remainder = seconds % 60
  return remainder === 0 ? `${minutes}m` : `${minutes}m ${remainder}s`
}

export const createElapsedTime = (element, options = {}) => {
  const now = options.now || (() => performance.now())
  const every = options.setInterval || globalThis.setInterval
  const cancel = options.clearInterval || globalThis.clearInterval
  let baseline = 0
  let observedAt = 0
  let timer = null

  const render = () => {
    element.textContent = formatElapsed(baseline + now() - observedAt)
  }

  const reset = () => {
    baseline = Number(element.dataset.elapsedMs) || 0
    observedAt = now()
    render()
  }

  return {
    mounted() {
      reset()
      timer = every(render, 1_000)
    },
    updated: reset,
    destroyed() {
      if (timer !== null) cancel(timer)
    }
  }
}

export const ElapsedTime = {
  mounted() {
    this.elapsedTime = createElapsedTime(this.el)
    this.elapsedTime.mounted()
  },
  updated() { this.elapsedTime.updated() },
  destroyed() { this.elapsedTime.destroyed() }
}
