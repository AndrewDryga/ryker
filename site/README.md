# Public Ryker website

This directory holds the public marketing site, documentation and walkthroughs.
It is separate from Ryker's authenticated control plane and webhook service.
Never expose the application or upload the repository root to host these pages.

The public origin is **https://ryker.emisar.dev**. GitHub Pages hosts the site
from `AndrewDryga/ryker`; Google Cloud DNS serves the `emisar.dev` zone, managed
by Emisar's `infra/dns.tf`. GitHub provisions the HTTPS certificate.

## Build and verify

Build the production artifact:

```sh
node --test test/js/marketing_site_test.mjs test/js/marketing_interactions_test.mjs
node scripts/build-site.mjs --origin https://ryker.emisar.dev --out dist/site
```

The `--origin` argument has no default. It must be a root HTTPS origin. Hosting
under a path prefix is not supported by this build. The builder copies only the
thirteen listed HTML pages and `site/assets/`, writes absolute canonical and social
URLs and structured product/breadcrumb data, and emits a sitemap, robots.txt,
llms.txt, `.nojekyll`, and a CNAME for a custom host.
It refuses unexpected output files rather than silently publishing or deleting
them. `dist/` is ignored. Upload only `dist/site/` after reviewing it.

The build rejects broken local links and fragments, duplicate titles/descriptions and
duplicate anchor IDs before writing output. Social titles and descriptions come
from each page’s metadata. New pages belong in `pages` in `scripts/build-site.mjs`,
the documentation navigation and the docs overview.

`llms.txt` is a generated documentation index for readers and agents. It makes no
claim about rankings or AI citations. Ordinary crawlable HTML remains the source.
The existing allow-all crawler policy is unchanged; training preferences are a
separate owner decision.

The Node test uses `site-build.invalid` in a disposable directory; that is test
data, never a production domain. The existing JavaScript CI gate runs this test.

The header and footer have the same markup and destinations on every page;
only relative paths and the Docs current-location attribute differ. The
marketing site test compares both regions across all thirteen pages, so update
them together. Their layout belongs in `assets/site.css`, without homepage
overrides. Copy controls live inside each code block and name what they copy.

## Deployment

`.github/workflows/pages.yml` tests, builds and deploys site changes pushed to
`main`. It can also be dispatched manually from `main`. The `github-pages`
environment accepts only that branch. Only the deploy job receives Pages and
OIDC write permissions; no cloud credentials are needed by this workflow.

Repository Settings → Pages uses **GitHub Actions**, with custom domain
`ryker.emisar.dev` and **Enforce HTTPS** enabled once the certificate is ready.
The custom domain must be configured in Pages before pointing DNS at GitHub;
the generated CNAME file alone does not configure an Actions deployment.
The DNS record is `ryker.emisar.dev. CNAME andrewdryga.github.io.` with a
300-second TTL. Manage changes through Emisar's Terraform deployment process.

To republish, rerun the `pages` workflow on the desired current `main` commit.
To roll back content, revert the site change on `main` and let Pages deploy it.
This workflow does not deploy or restart the Ryker application.

## Publication checks

After publication, check all thirteen pages, canonical URLs,
social images, sitemap and robots response on the actual host. Confirm that
unknown paths return 404. Add the verified property to Search Console and Bing
Webmaster Tools, submit the sitemap, and record indexing separately from delivery.

The primary CTA leads to the installation guide; the secondary contact link opens
an email to the builder. Track setup starts, completed setup and qualified
conversations separately when measurement is available. A click alone does not
prove that someone installed Ryker. Do not report zero conversions when inbox
or attribution data is unavailable.

## Documentation structure

The page inventory in `scripts/build-site.mjs` is also the reading order. Keep
sidebar links and Previous/Next links in that order; the site test checks them.
Every section appears in both the mobile and desktop table of contents.

Write for an engineer meeting Ryker for the first time. Start with what it does,
show a concrete request and result, then introduce configuration when the reader
needs it. Use plain verbs and name the actor. Remove repeated introductions,
marketing slogans, unsupported promises, and sentences that only describe the
page. The [Humanizer guidance](https://github.com/blader/humanizer/blob/main/SKILL.md)
is an editorial reference; product source remains the authority for claims.

Each subject has one main home:

| Page | Owns |
| --- | --- |
| What is Ryker? | Product definition and a concrete end-to-end example |
| Install Ryker | Prerequisites, initial connections, and the first delivered answer |
| Repositories and tools | Environments, repository access, and Emisar connection |
| Working in Slack | Conversation behavior, participation, files, and Slack controls |
| Your first code change | A step-by-step task and review |
| GitHub and pull requests | App setup, publication rules, CI, and reviews |
| Alerts and incidents | Investigation, Emisar approval, recovery, and incident rooms |
| Schedules and follow-ups | Recurring work, event rules, and waits |
| Memory and learning | Facts, feedback, learned knowledge, instructions, and recall |
| The console | Request records, troubleshooting, settings, cost, and working copies |
| Access and data | Trust boundaries, permissions, data destinations, and licensing |
| Running Ryker | Host lifecycle, backup, upgrades, networking, and retention |

A walkthrough can summarize a rule needed to finish its steps and link to the
full explanation. Do not copy entire reference sections into it. Keep useful
technical detail in its owning page or link to the repository reference. Give
each page a distinct title and description; all explanations must be present in
static HTML so they work without JavaScript and can be read by crawlers.
