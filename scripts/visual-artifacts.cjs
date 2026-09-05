const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');

async function createCaptureDirectory(requested, repository) {
  const checkout = await fs.realpath(repository);
  const parent = await fs.realpath(path.dirname(path.resolve(requested)));
  assert(parent !== checkout && !parent.startsWith(checkout + path.sep), 'Do not commit organization screenshots');
  // Never chmod/reuse caller-selected paths or existing artifact symlinks.
  // mkdtemp creates a fresh unpredictable directory with owner-only access.
  return fs.mkdtemp(path.join(parent, path.basename(requested) + '-'));
}

module.exports = {createCaptureDirectory};
