# Ryker identity and project naming

Approved by Andrew on 2026-09-09 for the complete project rename and redesign. This is the
durable repository rule; the rename/application rollout is still pending. The current task ID
is `2026-09-09-redesign-conversation-lab-and-testing-pages`. Do not mistake these instructions
or imported assets for proof that a deployed service/repository has already been renamed.

## Authoritative local sources

Read brand/ryker/README.md, brand/ryker/index.html and overview.png before changing identity.
Read brand/DESIGN.md for supporting typography/layout/accessibility and brand/README.md for
naming, positioning and voice. brand/IMPORT.md records source revision and import boundaries;
brand/source-manifest.sha256 fingerprints the unmodified artwork, references, fonts and licenses.

Ryker-specific rules and Andrew's approved application layouts govern Ryker. The umbrella guide
is a reference, not a complete product UI specification. Do not import Protectorate orange,
Forcefield artwork, umbrella logo minimums or marketing-sized headings/spacing as Ryker defaults.
Approved compact Conversations and Configuration hierarchies remain; identity updates must not
restore rejected headings, statistics panels, testing pages or excessive help chrome.

## Name and scope

Use Ryker in product copy, `Ryker` for the owned code namespace and `ryker`/`RYKER` in the
corresponding technical conventions. Andrew requested the FULL rename, not a display alias:
repository/checkout, modules/packages, filenames, variables, constants, test helpers, internal
symbols, app/release names, environment/config names, services, commands, docs and generated
surfaces must be audited. Do not leave owned old-name identifiers merely because they are internal.

Keep raw historical source messages, harvested fixtures, licenses, immutable receipts and audit
evidence truthful. Old database/runtime identities require explicit non-lossy migration/cutover,
not deletion or global replacement inside signed/historical blobs. Every remaining old-name
occurrence needs a specific documented reason; no broad legacy-code exemption or dual API/config
alias. Preserve data, grants, exact targets, lineage, delivery idempotency and one-writer custody.

Use plain, calm language explaining useful work and real controls. Ryker is a proactive AI
teammate working in conversations, Slack and GitHub; Emisar provides its governed external tools.
Do not promise universal incident resolution or imply every Protectorate product has the same
permissions/safety properties. Use co:op and Emisar with their own names and identities. Keep
previous names/repository migration history out of new customer-facing product copy.

## Artwork, colors and sizes

- Graphite #111315; mint #36E6A5; ivory #F2EEE5. Mint is Ryker's accent, not Protectorate orange.
  Mint artwork belongs on graphite; on white/ivory use graphite artwork. No mint body text on
  light backgrounds. Preserve separate meaningful warning/error/success states and readable
  text/icons; a brand color is not evidence of successful work or authorization.
- Use brand/ryker/lockup-color.svg for dark surfaces (mint symbol, ivory lettering), lockup.svg
  on light surfaces (graphite), and lockup-reverse.svg for dark monochrome use.
- Use mark-mint.svg, mark.svg or mark-reverse.svg for standalone symbols on appropriate surfaces.
  wordmark.svg is outlined lettering, not instructions to type the name in a font. Do not redraw,
  retype, trace, mirror, rotate, join, outline, distort or add a core/effect to the supplied logo.
  Preserve the two distinct forms, their original orientation and unequal proportions.
- Standalone mark: at least 24px. Complete lockup: at least 160px. If it does not fit, give it
  more space or use an appropriately sized standalone mark; do not compress the artwork.
  Surround visible mark with at least 1/8 its width of clear space; surround a lockup with at
  least 1/4 the wordmark lowercase height. Transparent canvas padding does not replace this.
- avatar.png/avatar.svg are the supplied 512×512 composition; preserve the full crop. banner.png
  is 1600×540, not the umbrella banner's dimensions. Do not stretch or reconstruct either.
  No approved Ryker optical 16px variant is supplied: resolve any such platform requirement
  explicitly rather than borrowing Protectorate's small mark or inventing a logo variant.

## Application design and accessibility

Use the bundled unmodified IBM Plex Sans Regular/SemiBold for supporting type and Plex Mono
for code/technical identifiers or aligned technical metadata as appropriate. Preserve both font
licenses. These supporting fonts are not the customized logo lettering. Never retype the logo.

Translate the reference into a Ryker application token/role specification: graphite/ivory
neutrals, deliberate mint accents, clear control/focus/selected/disabled states and independent
semantic statuses. Retain approved compact type sizes and 4px-based rhythm rather than copying
the umbrella website's 36–72px display text or large editorial section gaps wholesale.

Verify actual rendered contrast in every state: normal text at least 4.5:1, large text 3:1,
visible focus and control boundaries. Use at least 44×44px hit areas for primary controls/icon
buttons even if their visible glyph is small. Link meaning/status cannot rely on color alone.
Respect reduced motion; avoid ambient animation and layout-shifting entrances. Check keyboard,
320px reflow, 200% text zoom and whichever light/dark surfaces the application actually uses.
Give a meaningful logo the accessible name Ryker; avoid duplicated alt text when decorative.

## Packaging and drift checks

Assets/fonts live in this repository. Package required bytes into the application/release and
verify loading from a clean checkout/release with the brand source checkout unavailable. No
runtime developer absolute paths, sibling checkout, external logo/font fetch or missing license.
Keep brand references and asset libraries out of customer navigation/footers.

Future work must check logo hashes/geometry, exact palette, surface selection, minimum size,
clear space, font loading/licenses and rendered accessibility. Add an old-name audit that
enumerates justified historical/protocol occurrences rather than hiding whole directories.
Review web, Slack/GitHub identity, docs, CLI and release outputs, not just the page being edited.
