// What a person typed and has not saved is kept in the tab's session storage,
// so a live patch, a reconnect or Back gives it back: the composer and message
// editor drafts, the open editor, instruction and settings drafts. Each one is
// stamped when it is written, and when a page mounts the drafts older than a
// day, or past the newest fifty, go. Nothing pruned them: abandoned text, a
// pasted credential among it, stayed readable to any script on the origin for
// the life of the tab and filled the quota until saves failed silently
// (2026-10-04 review).

const indexKey = "ryker:drafts"
const families = ["ryker:draft:", "ryker:editing:", "ryker:instruction-draft:", "ryker:settings-draft:"]
const maxAgeMs = 24 * 60 * 60 * 1000
const maxDrafts = 50

const readIndex = store => {
  try {
    const index = JSON.parse(store.getItem(indexKey))
    return index && typeof index === "object" && !Array.isArray(index) ? index : {}
  } catch (_) {
    return {}
  }
}

const writeIndex = (store, index) => {
  try {
    if (Object.keys(index).length) store.setItem(indexKey, JSON.stringify(index))
    else store.removeItem(indexKey)
  } catch (_) { /* Pruning catches up later. */ }
}

// Writes a draft and stamps it. A storage that refuses throws, as setItem does.
export const keepDraft = (store, key, value, now = Date.now()) => {
  store.setItem(key, value)
  const index = readIndex(store)
  index[key] = now
  writeIndex(store, index)
}

export const dropDraft = (store, key) => {
  store.removeItem(key)
  const index = readIndex(store)
  if (key in index) {
    delete index[key]
    writeIndex(store, index)
  }
}

// Removes every draft not written in the last day, then all but the newest
// fifty. A draft with no stamp was written before stamps existed, and goes.
export const pruneDrafts = (store, now = Date.now()) => {
  const index = readIndex(store)
  const drafts = []
  for (let position = 0; position < store.length; position++) {
    const key = store.key(position)
    if (key && families.some(prefix => key.startsWith(prefix))) drafts.push(key)
  }

  const kept = drafts
    .filter(key => Number.isFinite(index[key]) && now - index[key] <= maxAgeMs)
    .sort((left, right) => index[right] - index[left])
    .slice(0, maxDrafts)

  const keep = new Set(kept)
  for (const key of drafts) if (!keep.has(key)) store.removeItem(key)
  writeIndex(store, Object.fromEntries(kept.map(key => [key, index[key]])))
}
