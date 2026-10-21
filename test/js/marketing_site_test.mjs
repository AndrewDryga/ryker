import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { build, pages, publicOrigin, render } from "../../scripts/build-site.mjs";

test("public site build emits one consistent origin and only the public inventory", async () => {
  const out = await mkdtemp(path.join(os.tmpdir(), "ryker-site-"));
  try {
    await build({ origin: "https://site-build.invalid", out });
    for (const name of pages) {
      const html = await readFile(path.join(out, name), "utf8");
      const canonical = `https://site-build.invalid/${name.replace(/index\.html$/, "")}`;
      assert.ok(html.includes(`<link rel="canonical" href="${canonical}">`));
      assert.ok(html.includes(`<meta property="og:url" content="${canonical}">`));
      assert.ok(html.includes('content="https://site-build.invalid/assets/og.png"'));
      assert.equal((html.match(/rel="canonical"/g) || []).length, 1);
      assert.equal((html.match(/property="og:image"/g) || []).length, 1);
    }
    assert.equal((await readFile(path.join(out, "sitemap.xml"), "utf8")).match(/<loc>/g).length, 8);
    assert.match(await readFile(path.join(out, "robots.txt"), "utf8"), /Sitemap: https:\/\/site-build.invalid\/sitemap.xml/);
    assert.equal(await readFile(path.join(out, "CNAME"), "utf8"), "site-build.invalid\n");
    assert.deepEqual((await readdir(out)).sort(), [".nojekyll", "CNAME", "assets", "docs", "index.html", "robots.txt", "sitemap.xml"]);
    await writeFile(path.join(out, "private.txt"), "must not be deleted or published");
    await assert.rejects(build({ origin: "https://site-build.invalid", out }), /unexpected files/);
    assert.equal(await readFile(path.join(out, "private.txt"), "utf8"), "must not be deleted or published");
  } finally {
    await rm(out, { recursive: true, force: true });
  }
});

test("a launch requires an explicit clean HTTPS origin", () => {
  for (const value of ["http://example.com", "https://user:secret@example.com", "https://example.com/path", "https://example.com/?q=x", "https://example.com/#x", "https://example.com:8443"]) {
    assert.throws(() => publicOrigin(value));
  }
  assert.equal(publicOrigin("https://example.com/"), "https://example.com");
});

test("metadata generation rejects a page without its visible main heading", () => {
  assert.throws(() => render("<title>Ryker</title>", "index.html", "https://site-build.invalid"), /one h1/);
});
