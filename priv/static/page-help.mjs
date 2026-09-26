// "How this page works" sits beside the page as a column on a wide screen and
// above it as a closed disclosure on a narrow one; the stylesheet does the
// layout at the same width. This decides only when the disclosure starts
// open: when the page loads wide, and when the window is widened past the
// breakpoint. Everything else is the reader's choice, so nothing here closes
// it, and narrowing the window leaves it as it is.

export const wideQuery = "(min-width: 1600px)"

export function openWhenWide(details, wide) {
  if (wide && !details.open) details.open = true
}

// `keepOpenState` tells LiveView to leave the element's open attribute alone:
// the shell re-renders from HTML that never carries it, and the column would
// otherwise close under the reader on the next refresh.
export function createPageHelp(details, media, keepOpenState) {
  const onChange = event => openWhenWide(details, event.matches)

  return {
    mounted() {
      keepOpenState(details)
      openWhenWide(details, media.matches)
      media.addEventListener("change", onChange)
    },
    destroyed() {
      media.removeEventListener("change", onChange)
    }
  }
}
