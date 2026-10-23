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
  "docs/github.html", "docs/security.html",
  "guides/first-code-change.html", "guides/investigate-an-alert.html",
];

const entities = { amp: "&", quot: '"', apos: "'", lt: "<", gt: ">", nbsp: " " };
const plain = value => value.replace(/<[^>]*>/g, "").replace(/&(#x[\da-f]+|#\d+|amp|quot|apos|lt|gt|nbsp);/gi, (entity, code) => {
  if (!code.startsWith("#")) return entities[code.toLowerCase()];
  const point = code[1].toLowerCase() === "x" ? parseInt(code.slice(2), 16) : Number(code.slice(1));
  return point > 0 && point <= 0x10ffff ? String.fromCodePoint(point) : entity;
});
const attribute = value => value.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const pageURL = (relative, origin) => `${origin}/${relative.replace(/index\.html$/, "")}`;

export function publicOrigin(value) {
  const url = new URL(value);
  if (url.protocol !== "https:" || url.username || url.password || url.port ||
      url.pathname !== "/" || url.search || url.hash) {
    throw new Error("--origin must be an HTTPS origin, without credentials, path, port, query or fragment");
  }
  return url.origin;
}

export function render(source, relative, origin) {
  const canonical = pageURL(relative, origin);
  if ((source.match(/<h1(?:\s|>)/g) || []).length !== 1) {
    throw new Error(`${relative}: expected one h1`);
  }
  for (const pattern of [/<title>[^<]+<\/title>/g, /<meta name="description" content="[^"]+">/g]) {
    if ((source.match(pattern) || []).length !== 1) throw new Error(`${relative}: missing or duplicate metadata`);
  }
  const title = plain(source.match(/<title>([^<]+)<\/title>/)[1]);
  const description = plain(source.match(/<meta name="description" content="([^"]+)">/)[1]);
  const heading = plain(source.match(/<h1(?:\s[^>]*)?>([\s\S]*?)<\/h1>/)[1]).trim();
  const graph = [{
    "@type": "WebSite", "@id": `${origin}/#website`, url: `${origin}/`, name: "Ryker",
    description: "A self-hosted AI teammate for Slack and GitHub.", inLanguage: "en",
  }, {
    "@type": "WebPage", "@id": canonical, url: canonical, name: title, description,
    isPartOf: { "@id": `${origin}/#website` }, inLanguage: "en",
  }];
  if (relative === "index.html") {
    graph.push({ "@type": "SoftwareApplication", "@id": `${origin}/#ryker`, name: "Ryker",
      url: `${origin}/`, description, applicationCategory: "DeveloperApplication",
      license: "https://github.com/AndrewDryga/ryker/blob/main/LICENSE",
      sameAs: ["https://github.com/AndrewDryga/ryker"] });
    graph[1].about = { "@id": `${origin}/#ryker` };
  } else {
    const crumbs = [{ name: "Ryker", item: `${origin}/` }];
    if (relative !== "docs/index.html") crumbs.push({ name: "Docs", item: `${origin}/docs/` });
    crumbs.push({ name: heading, item: canonical });
    graph.push({ "@type": "BreadcrumbList", "@id": `${canonical}#breadcrumb`,
      itemListElement: crumbs.map((crumb, index) => ({ "@type": "ListItem", position: index + 1, ...crumb })) });
    graph[1].breadcrumb = { "@id": `${canonical}#breadcrumb` };
  }
  const metadata = [
    `<link rel="canonical" href="${canonical}">`,
    `<meta property="og:url" content="${canonical}">`,
    `<meta property="og:image" content="${origin}/assets/og.png">`,
    `<meta name="twitter:image" content="${origin}/assets/og.png">`,
    `<meta property="og:title" content="${attribute(title)}">`,
    `<meta property="og:description" content="${attribute(description)}">`,
    `<meta name="twitter:title" content="${attribute(title)}">`,
    `<meta name="twitter:description" content="${attribute(description)}">`,
    `<script type="application/ld+json">${JSON.stringify({ "@context": "https://schema.org", "@graph": graph }).replace(/</g, "\\u003c")}</script>`,
  ].join("\n");
  return source
    .replace(/<!-- Unfurl metadata\.[\s\S]*?-->\s*/g, "")
    .replace(/<link rel="canonical"[^>]*>\s*/g, "")
    .replace(/<meta (?:property="og:(?:url|image|title|description)"|name="twitter:(?:image|title|description)")[^>]*>\s*/g, "")
    .replace(/<script type="application\/ld\+json">[\s\S]*?<\/script>\s*/g, "")
    .replace("</head>", `${metadata}\n</head>`);
}

// The public sources use quoted HTML attributes. Validate references before any
// output is written, including fragment links between documentation pages.
export function validatePages(outputs, origin) {
  const titles = new Set();
  const descriptions = new Set();
  const ids = new Map();
  for (const relative of pages) {
    const html = outputs.get(relative);
    const title = plain(html.match(/<title>([^<]+)<\/title>/)[1]);
    const description = plain(html.match(/<meta name="description" content="([^"]+)">/)[1]);
    if (titles.has(title) || descriptions.has(description)) throw new Error(`${relative}: duplicate title or description`);
    titles.add(title); descriptions.add(description);
    const anchors = [...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]);
    if (new Set(anchors).size !== anchors.length) throw new Error(`${relative}: duplicate anchor id`);
    ids.set(relative, new Set(anchors));
  }
  for (const relative of pages) {
    const html = outputs.get(relative).replace(/(<script\b[^>]*>)[\s\S]*?(<\/script>)/g, "$1$2");
    for (const [, reference] of html.matchAll(/\b(?:href|src)="([^"]+)"/g)) {
      const url = new URL(plain(reference), pageURL(relative, origin));
      if (url.origin !== origin) continue;
      let target = decodeURIComponent(url.pathname).slice(1);
      if (!target || target.endsWith("/")) target += "index.html";
      if (!outputs.has(target)) throw new Error(`${relative}: missing local target ${reference}`);
      if (url.hash && ids.has(target) && !ids.get(target).has(decodeURIComponent(url.hash.slice(1)))) {
        throw new Error(`${relative}: missing fragment ${reference}`);
      }
    }
  }
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
  validatePages(outputs, origin);
  const index = pages.map(relative => {
    const html = outputs.get(relative);
    const title = plain(html.match(/<title>([^<]+)<\/title>/)[1]);
    const description = plain(html.match(/<meta name="description" content="([^"]+)">/)[1]);
    return `- [${title}](${pageURL(relative, origin)}): ${description}`;
  }).join("\n");
  outputs.set("llms.txt", `# Ryker\n\n> A self-hosted AI teammate for Slack and GitHub.\n\nRyker coordinates the work, co:op runs model sessions in containers, and Emisar governs access to running systems. The linked pages explain the available controls and setup.\n\n## Documentation\n\n${index}\n`);
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
