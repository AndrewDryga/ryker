// Andrew, 2026-10-12: a button that leads to another site always opens in a
// new window, so the console stays where it was. A link is marked as it is
// clicked, which covers every page and every LiveView patch alike, however
// the link was drawn.
export function markOutbound(link, origin) {
  let url
  try {
    url = new URL(link.href, origin)
  } catch (_error) {
    return false
  }
  if ((url.protocol !== "https:" && url.protocol !== "http:") || url.origin === origin) return false
  link.target = "_blank"
  link.rel = "noopener noreferrer"
  return true
}

export function markOutboundFromEvent(event, origin = window.location.origin) {
  const target = event.target
  const link = target && typeof target.closest === "function" ? target.closest("a[href]") : null
  if (link) markOutbound(link, origin)
}
