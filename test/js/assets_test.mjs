import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"

// The shell is served from an allowlist in Ryker.ControlPlane.Assets. A module
// split out of control-plane.js and forgotten there answers 404 in the
// browser, and a failed import takes the whole shell down with it: no hooks,
// no drafts, no reading position. This walks the import graph the browser
// will walk and checks every file against that list.
const staticRoot = new URL("../../priv/static/", import.meta.url)
const allowlist = readFileSync(new URL("../../lib/ryker/control_plane/assets.ex", import.meta.url), "utf8")
const served = new Set([...allowlist.matchAll(/^\s*"([^"]+\.m?js)" =>/gm)].map(match => match[1]))

function imports(file) {
  const source = readFileSync(new URL(file, staticRoot), "utf8")
  return [...source.matchAll(/^import .* from "(?:\/assets\/|\.\/)([^"/]+\.m?js)"/gm)].map(match => match[1])
}

test("every module the shell imports is on the served allowlist", () => {
  const seen = new Set()
  const queue = ["control-plane.js"]
  while (queue.length > 0) {
    const file = queue.shift()
    if (seen.has(file)) continue
    seen.add(file)
    assert.ok(served.has(file), `${file} is imported but not served by Ryker.ControlPlane.Assets`)
    if (file.startsWith("phoenix")) continue
    queue.push(...imports(file))
  }
  // The local modules that exist to be imported are all reachable from the shell.
  for (const file of ["reading-state.mjs", "copy-value.mjs", "composer.mjs", "leave-guard.mjs", "drafts.mjs", "history.mjs", "filter-menu.mjs"]) {
    assert.ok(seen.has(file), `${file} is served but nothing imports it`)
  }
})
