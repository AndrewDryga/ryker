#!/usr/bin/env node
// Build only the public marketing inventory. Never publish the application tree.
import { readFile, readdir, mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const pages = [
  "index.html", "docs/index.html", "docs/getting-started.html",
  "docs/slack.html", "docs/actions.html", "docs/memory.html",
  "docs/control-plane.html", "docs/operations.html",
];

export function publicOrigin(value) {
  const url = new URL(value);
  if (url.protocol !== "https:" || url.username || url.password || url.port ||
      url.pathname !== "/" || url.search || url.hash) {
    throw new Error("--origin must be an HTTPS origin, without credentials, path, port, query or fragment");
  }
  return url.origin;
}

export function render(source, relative, origin) {
  const canonical = `${origin}/${relative.replace(/index\.html$/, "")}`;
  if ((source.match(/<h1(?:\s|>)/g) || []).length !== 1) {
    throw new Error(`${relative}: expected one h1`);
  }
  for (const pattern of [/<title>[^<]+<\/title>/g, /<meta name="description" content="[^"]+">/g]) {
    if ((source.match(pattern) || []).length !== 1) throw new Error(`${relative}: missing or duplicate metadata`);
  }
  const metadata = [
    `<link rel="canonical" href="${canonical}">`,
    `<meta property="og:url" content="${canonical}">`,
    `<meta property="og:image" content="${origin}/assets/og.png">`,
    `<meta name="twitter:image" content="${origin}/assets/og.png">`,
  ].join("\n");
  return source
    .replace(/<!-- Unfurl metadata\.[\s\S]*?-->\s*/g, "")
    .replace(/<link rel="canonical"[^>]*>\s*/g, "")
    .replace(/<meta (?:property="og:(?:url|image)"|name="twitter:image")[^>]*>\s*/g, "")
    .replace("</head>", `${metadata}\n</head>`);
}

async function filesBelow(directory, prefix = "") {
  const result = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const name = path.posix.join(prefix, entry.name);
    if (entry.isSymbolicLink()) throw new Error(`Symlink is not a public asset: ${name}`);
    if (entry.isDirectory()) result.push(...await filesBelow(path.join(directory, entry.name), name));
    else if (entry.isFile()) result.push(name);
  }
  return result;
}

export async function build({ origin, out, source = path.join(root, "site") }) {
  origin = publicOrigin(origin);
  out = path.resolve(out);
  source = path.resolve(source);
  if (source === out || source.startsWith(out + path.sep) || out.startsWith(source + path.sep)) {
    throw new Error("Build output must be separate from site sources");
  }
  const outputs = new Map();
  const urls = [];
  for (const relative of pages) {
    outputs.set(relative, render(await readFile(path.join(source, relative), "utf8"), relative, origin));
    urls.push(`${origin}/${relative.replace(/index\.html$/, "")}`);
  }
  for (const asset of await filesBelow(path.join(source, "assets"))) {
    outputs.set(`assets/${asset}`, await readFile(path.join(source, "assets", asset)));
  }
  outputs.set("sitemap.xml", `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.map(url => `  <url><loc>${url}</loc></url>`).join("\n")}\n</urlset>\n`);
  outputs.set("robots.txt", `User-agent: *\nAllow: /\nSitemap: ${origin}/sitemap.xml\n`);
  outputs.set(".nojekyll", "");
  // The caller must verify domain ownership/hosting before publishing this output.
  if (!new URL(origin).hostname.endsWith(".github.io")) {
    outputs.set("CNAME", `${new URL(origin).hostname}\n`);
  }
  let existing = [];
  try { existing = await filesBelow(out); } catch (error) { if (error.code !== "ENOENT") throw error; }
  const unexpected = existing.filter(name => !outputs.has(name));
  if (unexpected.length) throw new Error(`Output contains unexpected files; refusing to overwrite: ${unexpected.join(", ")}`);
  for (const [relative, content] of outputs) {
    const target = path.join(out, relative);
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, content);
  }
  return { origin, out, pages: pages.length, files: outputs.size };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args.length !== 4 || args[0] !== "--origin" || args[2] !== "--out") {
      throw new Error("Usage: node scripts/build-site.mjs --origin https://YOUR-VERIFIED-HOST --out dist/site");
    }
    console.log(JSON.stringify(await build({ origin: args[1], out: args[3] })));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
