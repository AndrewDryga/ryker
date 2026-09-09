# Slack-card design and review workflow

Use this whenever creating, redesigning or reviewing Slack cards, messages, Home views, modals
or their states. Saved from Andrew's approved review process on 2026-09-09.

Read [slack-presentation.md](slack-presentation.md) for the canonical product patterns. This file
owns the method, artifact structure, testing and handoff; do not maintain competing copies of
the pattern rules. For identity work, read [ryker-brand.md](ryker-brand.md) and its local sources.
Slack owns native typography, spacing and button colors; brand guidance does not make arbitrary
web styling possible inside a Slack message. The approved Ryker rename is a separate cutover.

## 1. Start with purpose and the real lifecycle

Determine whether the user wants design collection, preview iteration or production implementation.
An approved mock is not a request to send messages, approve actions or mutate live settings.

For each message family, identify:

- Who reads it, in which channel/thread/private surface, and what they need to understand or do.
- What creates it, which events update the same message, and what retires its controls.
- Which outcomes need a separate message, native typing/status, private feedback or history only.
- What data is retained now, what can be derived safely, and what requires a new backend contract.

Inspect the actual renderer, state owner, model tool schema, interaction handler and delivery
path. Check integration source when it owns a field or decision. Do not assume a native widget
means the model can produce its data or the host can accept its interaction. The five-choice
model limit versus ten-choice storage and missing radio-submit handler was a concrete example.
Refresh such source findings before implementation; old task notes are not runtime truth.

Map every existing state to a useful presentation or an explicit reason for no card. Group
variants by purpose, not one specimen per backend enum. Do not skip failure, missing-data,
partial, stale or cancelled paths just because the happy-path mock looks good.

## 2. Use real evidence, with explicit proposed variants

Reuse the sanitized Blitz corpus and prior sent Go card in the reference task below. They contain
real requests, repositories, goals, observations, tool calls and publication failures. Choose
representative cases; do not copy irrelevant follow-ups or old progress labels into a new design.

When additional evidence is needed, inspect the real store read-only and use an allowlisted
extraction. The existing harvest-blitz.mjs is a historical SQLite extractor with exact selected
episode IDs, not a generic current-production database client. Read it before running it; do not
rehash/reharvest a stable corpus just to change layout. Verify the current schema/location first.

Keep source identity, timestamp/cutoff, provenance and hashes. Preserve full selected source text
locally with clear included/total counts where sampling occurred. A recorded PR/check snapshot is
not its current live state. Do not combine measurements from different times into a false snapshot.

Keep harvested inputs immutable. Put proposed compositions and hypothetical lifecycle variants in
separate design data, labelled as proposed in the catalog. Missing reviewer names, reasons, subtasks,
timings and checks stay missing; illustrative placeholders are not historical facts. Proposed
UI copy is allowed, but it is never a harvested production fixture or live acceptance evidence.

Only send sanitized displayed fields to Builder. Keep raw prompts, credentials, private reasoning,
unneeded raw tool output, operational action values and sensitive source records out of preview
URLs/exports. Redaction needs inspection as well as an automated filter. Use inert preview action
IDs and reserved example.invalid operational destinations. Known safe repository links can remain
real navigation links. Do not use Builder's send/Preview in Slack action without authorization.

## 3. Compose shared patterns, then exercise realistic extremes

Use the existing shared projections. A correction to headings, status, actions or spacing belongs
in the shared rule and renderer, with tests across its consumers, not in one photographed state.
Plain, natural sentences; useful values; no boilerplate or repeated status/Next summaries.

The canonical presentation rules cover:

- Stable task stages and stage-local subtasks; bold current work; linked repos; lowercase
  “← 🙋 your turn”; web/PR-only diffs; exact controls for the task state.
- Settings-derived friendly welcome, explained setup choices and structured requested settings.
- One governed-review message; optional rationale/evidence/outcome; code-formatted Action and
  runner; current status plus spaced chronological decisions; real quorum and explicit override.
- Shared saved/updated entity detail and direct removal controls; separate requested item messages.
- Separate question/answer messages; full long choices, short controls, many-choice radio selection
  plus explicit submit, no preselection and complete control retirement after an answer.
- Colonless structural headings, consistent status icons, exact scope/source metadata, and
  create-versus-open action wording.

Test constraints together, not just separately: seven choices where every answer is long;
partial reviews followed by denial/override; multi-repo work with missing historical telemetry;
long entity instructions and expired/stale controls. Use realistic proposed copy grounded in the
source request. Do not pad a card to fill a state matrix or simplify away the actual hard case.

## 4. Reuse the native-payload catalog

Reference task ID: 2026-09-09-redesign-all-slack-cards-and-states-for-consolid.
Locate its current folder rather than assuming it will always stay in 00_todo:

~~~sh
rg --files --hidden --no-ignore .agent/tasks | rg '/2026-09-09-redesign-all-slack-cards-and-states-for-consolid/review.html$'
~~~

The reusable pieces in that folder are:

| File | Responsibility |
| --- | --- |
| review-data.js / blitz-design.js | Purpose-based families, alternate states, shared compositions, source-backed/proposed labels |
| blitz-records.js | Immutable sanitized historical corpus |
| block-kit.js | Task-only native Block Kit compiler, full source-preserving fallback, exact Builder envelope |
| review.html / review-ui.js | Search/navigation, state buttons, per-item links/exports and full local source details |
| slack-validation.js | Successful exact-envelope hashes, message/view scope and check timestamps |
| preview-links.mjs | Fresh receipt-checked Markdown links for selected payload keys |
| presentation-patterns.md / structured-task-progress.md | Source gaps, approved implementation contracts and acceptance cases |

Extend this catalog instead of making another preview stack. Its compiler is design-only; do not
import it into the production renderer. Do not rebuild the retired runtime /card-lab route.

Use buttons for preview states, never a dropdown. A state replaces its specimen and updates its
Builder URL, copy/download JSON, receipt and deep link together. Requested collections have one
native envelope and one preview/export per entity. Keep full source details available locally.
Do not hand-render fake Slack HTML/CSS and present it as native proof.

Builder, JSON copy/download and validation must use the exact same full payload. Message Builder
envelopes contain blocks, not chat.postMessage's top-level notification text. Keep that fallback
separate. Home/modal envelopes use their actual view type. The original first-card rejection
came from validating blocks alone while embedding an invalid extra top-level text property.

## 5. Validate in layers, without repeating expensive work

For a reported regression, add the invariant first and see it fail on the old behavior. Confirm
the failure names the actual problem, then fix it. Never weaken a test to hide an unrelated failure.
For a new stress variant, require the actual case: all seven long answers visible in the native
sections, not merely present in notification fallback. Preserve existing receipts and raw sources.

Run the narrow owning artifact test after each edit. Before handoff run the quick offline set.
Set this task-specific variable to the folder found above; this is its location at authoring time:

~~~sh
slack_catalog_dir='.agent/tasks/00_todo/2026-09-09-redesign-all-slack-cards-and-states-for-consolid'
node "$slack_catalog_dir/validate-review-status-and-questions.mjs"
node "$slack_catalog_dir/validate-review-polish.mjs"
node "$slack_catalog_dir/validate-patterns.mjs"
node "$slack_catalog_dir/validate-curation.mjs"
node "$slack_catalog_dir/validate-design.mjs"
node "$slack_catalog_dir/validate-block-kit.mjs"
node "$slack_catalog_dir/validate-preview-links.mjs"
coop tasks --tasks .agent/tasks lint
~~~

The tests cover source/state dispositions, full text, bounds/escaping, exact URL round trips,
per-item targeting, selection identities, retirement, stale receipts and catalog state controls.
validate-design.mjs uses a DOM double: it is not browser layout or interaction acceptance.
Counts must follow actual families/states/envelopes; those are different quantities.

For changed/new payloads, run the existing no-post schema check once the copy is ready:

~~~sh
node "$slack_catalog_dir/validate-block-kit.mjs" --official --pending-only
~~~

It submits the exact message or view envelope to Slack's public blocks.validate endpoint, paces
requests and stops on errors/rate limits. It prints receipts, not files. Preserve Retry-After;
do not hammer the endpoint or claim unchecked payloads passed. If its contract changes, verify
the current official API/Builder behavior before changing the script.

Merge only returned successful receipts into slack-validation.js using the allowed file-edit
tool. Preserve unchanged matching receipts; archive superseded manifests when appropriate.
Match the current payload key, SHA-256 of JSON.stringify(payload), message/view scope and check
time. Every current preview needs its own matching receipt; a blocks-only hash or old same-name
receipt is insufficient. Rerun offline checks and the direct-link check after recording receipts.
Never hand-invent a validation success.

When browser access is available, use the active browser skill's supported Playwright/browser
workflow to open the exact Builder URL, inspect native rendering and iterate. Check desktop/mobile,
long wrapping, dark/light where available, code blocks, controls, keyboard and real interactions
that the authorized preview environment supports. A screenshot must come from an actual render.
If browser access is absent, follow its documented recovery/discovery once and state that visual
QA remains unverified. A previous session's missing browser is not a permanent assumption.

Keep four proof levels separate: offline tests, Slack schema acceptance, native visual review,
and authorized real integration/delivery acceptance. None implies the next. Product implementation
later follows the current AGENTS.md owning-package, repository, prompt-contract and deployment
gates. Do not deploy unrelated WIP or post to Slack merely to qualify a design-only change.

## 6. Hand off fresh direct links and retain every decision

Every card-design reply to Andrew must contain direct Block Kit Builder links for each requested
change and its materially different states. A local catalog link alone is not enough. Generate
them from current receipt-checked payloads, for example:

~~~sh
node "$slack_catalog_dir/preview-links.mjs" governed-action__partial governed-action__override question__many-long-options
~~~

Use the emitted URL byte-for-byte with a concise descriptive label. Builder URLs embed JSON
snapshots; earlier links and already-open tabs never pick up local edits. Do not reuse an earlier
reply's link, shorten it through a third-party service or blame a cache without evidence. When
a link exceeds the catalog's supported size, explicitly give the full JSON and empty Builder
instead. Treat links containing historical content as private.

Keep the reply short: what changed, the specific preview links, any backend gap, and the exact
verification boundary. Do not claim “tested in Slack” when only schema validation ran. For a
pure KB/task update with no card changes, link the changed documentation; no unrelated preview
link is needed.

Convert each requested change into a visible checklist item, update all affected variants and
caller/export paths, add the regression, and review every item before replying. Record new
approvals in the task, shared pattern changes in the KB, and missing backend work with source
owners and acceptance cases. Keep historical logs append-only; update current docs/counts and
supersede conflicting old mocks explicitly. Do not silently skip a request or reopen decisions
Andrew already approved.

An “lgtm” on a preview approves that design. It does not by itself implement the model contract,
wire controls, grant an Emisar action, rename the runtime or prove delivery. Keep that boundary
clear while making the next design iteration easy to review.
