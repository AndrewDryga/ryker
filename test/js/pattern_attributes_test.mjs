import {test} from "node:test"
import assert from "node:assert/strict"
import {readdirSync, readFileSync} from "node:fs"

// Browsers compile an input's pattern attribute with the `v` flag, and when it
// does not compile they log a console error and drop the check. The Webhooks
// credential name shipped "[a-z0-9][a-z0-9_.:-]{0,127}", whose unescaped "-"
// at the end of a class is invalid there (QA re-test, 2026-09-26).
const root = new URL("../../lib/ryker/control_plane/", import.meta.url)

function sources(directory) {
  return readdirSync(directory, {withFileTypes: true}).flatMap(entry => {
    const url = new URL(entry.name + (entry.isDirectory() ? "/" : ""), directory)
    if (entry.isDirectory()) return sources(url)
    return /\.(ex|heex)$/.test(entry.name) ? [url] : []
  })
}

test("every pattern attribute the control plane renders compiles with the v flag", () => {
  const patterns = sources(root).flatMap(file =>
    [...readFileSync(file, "utf8").matchAll(/\bpattern="([^"]*)"/g)].map(match => [file.pathname, match[1]])
  )

  assert.ok(patterns.length > 0, "the control plane renders at least one pattern attribute")

  for (const [file, pattern] of patterns) {
    assert.doesNotThrow(() => new RegExp(`^(?:${pattern})$`, "v"), `${file}: ${pattern}`)
  }
})

// Without a title a browser refuses a mistyped value with only "Please match
// the requested format." (manual testing, 2026-09-26, on the Webhooks
// credential name). The title is what the refusal adds to say which format.
test("every pattern attribute comes with a title that names the format", () => {
  const inputs = sources(root).flatMap(file =>
    [...readFileSync(file, "utf8").matchAll(/<input\b[^>]*\bpattern="[^"]*"[^>]*>/g)].map(match => [file.pathname, match[0]])
  )

  assert.ok(inputs.length > 0, "the control plane renders at least one pattern-checked input")

  for (const [file, input] of inputs) {
    assert.match(input, /\btitle="[^"]{10,}"/, `${file}: ${input.replace(/\s+/g, " ")}`)
  }
})
