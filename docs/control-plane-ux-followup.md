# Control-plane usability pass — 5 September 2026

## Implemented

- Compact accessible search, a quiet live indicator with optional controls, a
  wider Conversation Lab directory, and no persistent live-tools banner.
- Follow-up chapters are labelled and visually separated in the single execution
  timeline. Retained instructions and context remain grouped by their source;
  refreshed pages preserve expanded inspection sections and live-control menus.
- Failure lists and detail pages explain the interrupted operation and expose
  confirmed retry actions. IDs and error records remain in secondary inspection.
- Human-readable audit events and routing decisions link to their owning request
  or input. Repository cards and working-copy rows lead with useful work context.
- Workspace-scoped, bounded asynchronous Slack name lookup. Channels, actors,
  mentions and destinations use names when available; IDs remain inspectable.
  Directory outages and rate limits cannot block page rendering or processing.
- Usage shows channel and per-person attribution, a daily graph with missing-day
  spacing and accessible values, and an optional individual-execution ledger.
  Person attribution uses the exact triggering input, never the first speaker in
  an episode. Lab conversations aggregate into one destination.
- Missing provider costs use clearly labelled standard-context API-equivalent
  estimates for known Codex Sol/Terra/Luna measurements. Reported money wins,
  including reported zero. Unknown/unmeasured executions remain explicitly unknown.
  Estimates also appear in request summaries and Model performance.
- Model performance explains which accepted executions it covers and what the
  measurements mean; it does not claim to measure answer quality or all failures.
- Card Lab has a labelled state picker, compact/wide previews, native-style
  overflow menus, and no inline Slack confirmation objects. Task updates use
  readable times and explain unpublished, blocked and published PR states. An
  Open PR action requires an actual validated publication URL.

## Accounting limits

Estimates use the rate card verified on 2026-09-05, not historical invoices or
subscription charges. Codex ACP fresh input excludes cache reads; output already
includes reasoning, so reasoning is not charged again. Per-call context lengths,
service tiers, cache writes and tool fees are unavailable. Raw token counters may
overlap and must not be read as normalized billable tokens. Existing persisted
measurements are not rewritten.

- Rates: https://developers.openai.com/api/docs/pricing
- Counter semantics: https://github.com/agentclientprotocol/codex-acp/blob/main/src/TokenCount.ts

## Validation evidence

Focused regression tests were observed red before their fixes, then green for
pricing, attribution, naming, URL escaping, failure presentation, card controls,
and refreshed disclosure state. The final fast repository gate passes: 1,864 Elixir
tests, 80 script-unit tests, static analysis and offline legacy checks.

Playwright captured 132 card states and all populated console routes at desktop
and mobile widths: 316 viewport checks with no layout or browser errors. A later
52-view page pass also passed the interactive state-picker, payload, preview-width,
refresh and pause checks. Screenshots were visually inspected, not just asserted;
this caught a dark inherited repository header, raw channel headings, duplicate
Lab usage rows and a failure-detail page that still led with opaque references.

The user's multi-attempt episode was checked at 1440, 900 and 390 pixels: aligned
rails, source-labelled context and refresh/pause preserving expanded instructions.
Read-only live Slack checks resolve the existing Emisar workspace, #test channel
and user display name without requesting new credentials or scopes.

Screenshots and logs contain organization data and stay outside the repository.
Representative evidence directories:

- `/private/tmp/responder-ux-iteration-two-1XKI0T` — all card states.
- `/private/tmp/responder-ux-final-preview-5qAbkL` — page and interaction pass.
- `/private/tmp/responder-multi-attempt-final-XsYdLs` — the exact user timeline.

The preview on port 44321 uses PostgreSQL read-only transactions and starts no
runtime workers or operator actions. Preview evidence is not deployment evidence.

## Release and remaining boundaries

Run the shared-contract gate once, complete the read-only review board, commit
the owned files, qualify the exact immutable release, install and verify its
version, health, readiness and real browser behavior on port 4321. Do not restart
or install Coop as part of a Responder release.

Review-board findings were closed with regressions: only actual distinct received
messages advance conversation parts; fetched directory labels are redacted before
caching; audit/workspace links show sanitized request titles; all estimate surfaces
explain their meaning; sparse multi-year charts are capped at 366 displayed days.

The one-time full gate did not finish green. Its parallel Elixir leg hit four
database/local-request timeouts; all four passed isolated with unchanged timeouts,
and the complete Elixir suite subsequently passed in the final serial dev gate.
The legacy Go race gate passed the other-packages and first service shards, but
the second service shard exceeded its 20-minute aggregate budget (its current test
had run only four seconds). No race report was emitted. This is an incomplete
legacy qualification, not a passing full gate; it was not repeatedly rerun for
these Elixir-only changes. Local Elixir release proof is recorded separately.

OrbStack and the existing database were restored with operator approval; no data
was deleted. The earlier Responder shutdown followed database-pool failures and
a supervisor cascade. That proves the application shutdown path, not why the
database became unavailable. The canonical Linux service already restarts on
failure; a manually started macOS daemon is not equivalent OS-level supervision.

This pass does not claim historical provider request capture, a fully normalized
per-call billing ledger, real data for states never retained by the old product,
or production acceptance of unrelated GitHub/model/fleet boundaries. Card Lab
labels harvested records separately from state simulations and layout studies.
