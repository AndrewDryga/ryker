# Public Ryker website

This directory is the public marketing site and its seven documentation pages.
It is separate from Ryker's authenticated control plane and webhook service.
Never expose the application or upload the repository root to host these pages.

The launch hostname and hosting ownership have not been established in this
checkout. Do not infer them from an application endpoint or a repository name.
The source HTML deliberately has no guessed canonical origin.

## Build and verify

After verifying the intended hostname and its hosting account, build with that
exact HTTPS origin:

```sh
node --test test/js/marketing_site_test.mjs
node scripts/build-site.mjs --origin "$RYKER_PUBLIC_ORIGIN" --out dist/site
```

`RYKER_PUBLIC_ORIGIN` has no default. It must be a root HTTPS origin. Hosting
under a path prefix is not supported by this build. The builder copies only the
eight listed HTML pages and `site/assets/`, writes absolute canonical and social
URLs, and emits a sitemap, robots.txt, `.nojekyll`, and a CNAME for a custom host.
It refuses unexpected output files rather than silently publishing or deleting
them. `dist/` is ignored. Upload only `dist/site/` after reviewing it.

The Node test uses `site-build.invalid` in a disposable directory; that is test
data, never a production domain. The existing JavaScript CI gate runs this test.

## Release evidence

Before publication, verify DNS ownership, the HTTPS host, the hosting project,
and the responsible owner. Choose a static host; no application credentials,
database, private conversations or customer evidence belong in this artifact.
No new automatic deployment workflow is enabled by this change.

After publication, check the home page and all seven docs, canonical URLs,
social images, sitemap and robots response on the actual host. Confirm that
unknown paths return 404. Add the verified property to Search Console and Bing
Webmaster Tools, submit the sitemap, and record indexing separately from delivery.

The current CTA is a design-partner email. A click expresses interest; only an
actual qualified conversation is a conversion. Do not report zero conversions
when the inbox or attribution data is unavailable.
