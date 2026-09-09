# Ryker brand import

Imported unchanged on 2026-09-09 from the user-designated brand repository:
`/Users/andrewdryga/Projects/os/protectorate-github`, commit
`bcbfdebe1e54117a68ca3dfb2bca0c9ef3250d99`. The imported source paths had no local changes.
The absolute path records provenance only; nothing in the application may depend on it.

The twenty imported files are enumerated in source-manifest.sha256. Verify from the repository
root with `shasum -a 256 -c brand/source-manifest.sha256`. Keep logo/font bytes and licenses intact;
future approved upstream updates must update the source revision, manifest and visual checks.

Read in order:

1. [Ryker usage rules](ryker/README.md).
2. [Local visual reference](ryker/index.html) and [overview](ryker/overview.png).
3. [Umbrella design reference](DESIGN.md).
4. [Umbrella naming, positioning and voice](README.md).
5. [Repository Ryker rules](../.agent/kb/rules/ryker-brand.md).

Ryker's mint is #36E6A5, with graphite #111315 and ivory #F2EEE5. The umbrella's orange,
Forcefield artwork, product-specific dimensions and marketing layout are not Ryker UI rules.
The logo uses supplied outlines; IBM Plex font files are for supporting UI typography, not
recreating the logo. See ryker/FONT-LICENSE.txt and assets/fonts/LICENSE.txt.

This is the complete supplied Ryker bundle, plus the two umbrella reference documents and
three bundled supporting fonts with their license. The Ryker HTML preview is self-contained.
Umbrella-only art, tokens and profile resources linked from the unchanged reference documents
are not vendored or used by the app. Their relative references describe the original source
repository; consult the source if those separate umbrella resources are actually needed.

The files are imported for the redesign handoff; application/release asset wiring is pending.
Package needed files from this repository at implementation time. Do not load developer-local
paths, external font CDNs or the sibling brand checkout at runtime. Do not expose internal brand
guides in customer navigation or assume an import proves the deployed UI uses the brand.
