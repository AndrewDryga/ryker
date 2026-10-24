import test from "node:test";
import assert from "node:assert/strict";
import { cp, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { build, pages, publicOrigin, render, root } from "../../scripts/build-site.mjs";

// Landing and docs had different menus and footers. Check destinations as
// well as labels so a nested page cannot silently point at a different place.
test("every public page shares the same navigation and footer", async () => {
  function chrome(html, name, relative) {
    return html.match(new RegExp(`<${name}\\b[^>]*>[\\s\\S]*?<\\/${name}>`))[0]
      .replace(/ aria-current="[^"]*"/g, "")
      .replace(/\b(href|src)="([^"]+)"/g, (_, attr, value) => {
        const url = new URL(value, `https://site-build.invalid/${relative}`);
        url.pathname = url.pathname.replace(/index\.html$/, "");
        return `${attr}="${url.href}"`;
      }).replace(/\s+/g, " ").replace(/> </g, "><");
  }
  const home = await readFile(path.join(root, "site/index.html"), "utf8");
  for (const relative of pages) {
    const html = await readFile(path.join(root, "site", relative), "utf8");
    for (const region of ["header", "footer"]) {
      assert.equal(chrome(html, region, relative), chrome(home, region, "index.html"), `${relative} ${region}`);
    }
  }
});

// Readers used to skip pages by following Next even though those pages were in
// the sidebar. Keep both routes through the docs in the same complete order.
test("documentation navigation follows one complete reading order", async () => {
  const docs = pages.filter(page => page !== "index.html");
  for (const [index, relative] of docs.entries()) {
    const html = await readFile(path.join(root, "site", relative), "utf8");
    const sidebar = html.match(/<nav aria-label="Documentation">([\s\S]*?)<\/nav>/)[1];
    const links = [...sidebar.matchAll(/<a href="([^"]+)"([^>]*)>/g)];
    const destination = href => new URL(href, `https://site-build.invalid/${relative}`).pathname.slice(1);
    assert.deepEqual(links.map(link => destination(link[1])), docs, `${relative}: sidebar order`);
    assert.deepEqual(links.filter(link => link[2].includes('aria-current="page"')).map(link => destination(link[1])), [relative]);

    const navigation = html.match(/<nav class="doc-next"[^>]*>([\s\S]*?)<\/nav>/)[1];
    const neighbors = [...navigation.matchAll(/<a\b[^>]*href="([^"]+)"[^>]*rel="(prev|next)"/g)]
      .map(link => [link[2], destination(link[1])]);
    const expected = [];
    if (index > 0) expected.push(["prev", docs[index - 1]]);
    if (index + 1 < docs.length) expected.push(["next", docs[index + 1]]);
    assert.deepEqual(neighbors, expected, `${relative}: previous and next pages`);
  }
});

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
      const schema = JSON.parse(html.match(/<script type="application\/ld\+json">(.*?)<\/script>/s)[1]);
      const page = schema["@graph"].find(item => item["@type"] === "WebPage");
      assert.equal(page.url, canonical);
      if (name !== "index.html") {
        const crumbs = schema["@graph"].find(item => item["@type"] === "BreadcrumbList");
        assert.equal(crumbs.itemListElement.at(-1).item, canonical);
      }
    }
    assert.equal((await readFile(path.join(out, "sitemap.xml"), "utf8")).match(/<loc>/g).length, pages.length);
    const index = await readFile(path.join(out, "llms.txt"), "utf8");
    for (const name of pages) assert.ok(index.includes(`https://site-build.invalid/${name.replace(/index\.html$/, "")}`));
    assert.match(await readFile(path.join(out, "robots.txt"), "utf8"), /Sitemap: https:\/\/site-build.invalid\/sitemap.xml/);
    assert.equal(await readFile(path.join(out, "CNAME"), "utf8"), "site-build.invalid\n");
    assert.deepEqual((await readdir(out)).sort(), [".nojekyll", "CNAME", "assets", "docs", "guides", "index.html", "llms.txt", "robots.txt", "sitemap.xml"]);
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

test("broken navigation and duplicate metadata fail before writing public output", async () => {
  const temporary = await mkdtemp(path.join(os.tmpdir(), "ryker-site-validation-"));
  const source = path.join(temporary, "source");
  const out = path.join(temporary, "out");
  try {
    await cp(path.join(root, "site"), source, { recursive: true });
    const target = path.join(source, "docs/getting-started.html");
    const original = await readFile(target, "utf8");
    for (const [addition, expected] of [
      ['<a href="missing.html">Missing</a>', /missing local target/],
      ['<script src="missing.js"></script>', /missing local target/],
      ['<a href="slack.html#missing-fragment">Missing section</a>', /missing fragment/],
      ['<div id="main"></div>', /duplicate anchor id/],
    ]) {
      await writeFile(target, original.replace("</main>", `${addition}</main>`));
      await assert.rejects(build({ origin: "https://site-build.invalid", out, source }), expected);
      await assert.rejects(readdir(out), { code: "ENOENT" });
    }
    const home = await readFile(path.join(source, "index.html"), "utf8");
    await writeFile(target, original.replace(/<title>[^<]+<\/title>/, home.match(/<title>[^<]+<\/title>/)[0]));
    await assert.rejects(build({ origin: "https://site-build.invalid", out, source }), /duplicate title or description/);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test("social metadata follows page metadata and JSON-LD escapes script delimiters", () => {
  const source = '<html><head><title>Ryker &amp; tools</title><meta name="description" content="A &quot;quoted&quot; &lt;/script> description"><meta property="og:title" content="Stale"></head><body><h1>Ryker</h1></body></html>';
  const html = render(source, "index.html", "https://site-build.invalid");
  assert.ok(!html.includes('content="Stale"'));
  assert.equal((html.match(/property="og:title"/g) || []).length, 1);
  assert.match(html, /property="og:title" content="Ryker &amp; tools"/);
  assert.equal((html.match(/<\/script>/g) || []).length, 1);
  assert.doesNotThrow(() => JSON.parse(html.match(/<script type="application\/ld\+json">(.*?)<\/script>/s)[1]));
  assert.equal(render(html, "index.html", "https://site-build.invalid"), html);
});
