// The control-plane routes the screenshot harness visits, read from the router
// so the list cannot drift from what the product serves. Routes with a
// `:param` segment are discovered from real rows by the harness instead.
const fs = require('node:fs');
const path = require('node:path');

const router = path.join(__dirname, '..', 'lib', 'ryker', 'control_plane', 'web_router.ex');

// Every `live("/literal", …)` route, plus each `for x <- ~w(a b) do live("/prefix/#{x}", …)`
// expansion, in the order the router declares them.
function liveRoutes(source = fs.readFileSync(router, 'utf8')) {
  const routes = new Set();
  for (const [, literal] of source.matchAll(/live\("(\/|(?:\/[A-Za-z0-9_-]+)+)"/g)) routes.add(literal);
  for (const [, variable, words, template] of source.matchAll(/for\s+(\w+)\s+<-\s*~w\(([^)]*)\)\s+do\s+live\("([^"]*)"/g)) {
    for (const word of words.trim().split(/\s+/)) routes.add(template.replace(`#{${variable}}`, word));
  }
  return [...routes];
}

module.exports = {liveRoutes};
