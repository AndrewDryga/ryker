# Product completion

Approved scope: operator request of 2026-09-05. This checklist supersedes claims
that backend capability coverage alone establishes complete product parity.
An unchecked item is not done. Source, offline proof, rendered acceptance and
running-release proof are separate boundaries.

## Implemented increments

The first source increment fixes the shared secondary-text contrast, removes
dark introductory banners, separates usage coverage from execution timing, and
keeps traffic/date filters together without resetting scope. The native episode
now groups its continuous chronology into explained chapters and measures their
offsets from input receipt, including admission before episode creation. Exact
retained artifacts and deep links remain available. These are foundations, not
completion of the page audit or typed timeline components below.

Regression tests were observed failing before each fix. The gate also exposed
an unrelated sandbox collision: state-tool authorization fixtures reused a Slack
membership row held by channel-configuration tests. A suite-specific workspace
removes that collision without changing production locks or serializing tests.

The next task-card increment adds bounded chronological progress and current
subtasks to the shared Slack renderer. Durable subtask changes refresh the same
message during a pending turn, with no duplicate post or unchanged-state write.
Product feedback is excluded from public progress and does not refresh the card.
The harvested task-card records (three retained progress checkpoints from the
old Emisar runner task) remain the shared test fixture in
`testdata/slack/legacy_task_records.json`; the runtime Card Lab that displayed
them was retired on 2026-09-13. Other card families still need real examples,
and public streaming model output still requires Coop capture; private thoughts
are not a substitute.

The Playwright increment exposes provenance on demand,
labels the usage chart with dates, counters and measurement coverage, and fixes
the mobile overflow and composer overlapping the conversation. Browser
interaction tests also exposed malformed pause-state ARIA and raw UUID bytes in
the usage ledger; the latter prevented the populated Usage LiveView from connecting.
Both have failing-before regression tests. The screenshot harness is documented
in [control-plane-visual-testing.md](control-plane-visual-testing.md).

The timeline follow-up fixes the inherited message margins that displaced the
rail and restores source-labelled retained instructions/context. This increment
does not mark the broader typed timeline item complete.

## Ordered implementation

- [ ] Shared page readability: consistent surfaces, contrast, typography, spacing,
  tables, filters, empty states and actionable errors across every route.
- [ ] Explained execution chapters and typed request, tool, goal, evidence,
  validation, approval and delivery components; preserve exact retained artifacts.
- [ ] Safe tool-detail capture across Coop and Responder, without secrets or
  private reasoning; absent historical bodies remain explicitly unavailable.
- [ ] Cost estimates with versioned rates, separate reported cost, all attempts,
  own/descendant attribution and idempotent invocation accounting.
- [ ] Fast admission and Work startup with existing credentials; warm/cold/load
  measurements, preserved authority, abstention, escalation and recovery.
- [ ] One active conversation: durable follow-up steering, ordering, cancellation
  races, and persistent pending/progress indication in Slack and direct conversations.
- [ ] Scoped GCP project discovery and useful Emisar organization context;
  resolve goal authorization and citation interoperability defects.
- [ ] Rich real-data Slack task cards for every family/state;
  public progress, subtasks, native confirmations and live in-place transitions.
- [ ] Complete GitHub App integration and native GitHub replay/live workbench.
- [ ] Finish native LiveView operational pages and direct-conversation parity.
- [ ] Configuration v2 defaults, internally resolved policy pins, migration,
  validation and explanation without capability expansion.
- [ ] Reviewed organization-isolated learning corpus and comparative evaluation.
- [ ] Focused recovery/load/security proof, qualification, exact-release deployment
  and bounded live acceptance; update the capability ledger and task state.

## Rendered page acceptance

Inspect populated and empty states, errors, keyboard focus and narrow layouts.
Standalone Playwright is available even though in-app browser discovery has no
attached browser. The first actual desktop/phone pass captured 26 page/detail
routes plus all 132 card states. Missing populated incident/schedule records are
explicitly reported; no synthetic production rows are inserted for screenshots.
This is visual evidence, not completion of every page's information architecture:
decision/failure/workspace views still expose too many raw identifiers, and
the unchecked product items below remain open.

- [ ] Requests and filters
- [ ] Episode and retained request detail
- [ ] Conversations and all card actions
- [ ] Incident rooms and room detail
- [ ] Failures and confirmed recovery
- [ ] Usage and cost, including drill-downs
- [ ] Schedules and schedule detail
- [ ] Subscriptions
- [ ] Memory and review
- [ ] Routing decisions and response checks within episode detail
- [ ] Findings
- [ ] Work-class and model performance comparisons in Usage
- [ ] Configuration
- [ ] Channels and channel detail
- [ ] Repositories
- [ ] Workspaces
- [ ] GitHub workbench when implemented

The standalone Audit page was removed at operator request. Durable audit records
and their retention remain; per-request execution history stays in the timeline.

## Live boundaries

Slack acceptance is confined to Emisar #test. GitHub live tests require an
operator-selected test repository/issue/PR; none is selected yet. Do not use
another workspace or invent a target. Existing Coop credentials remain in use.
Do not restart or install Coop as part of Responder deployment.

Local classifier hosting/training and the one-command adoption/demo workflow
remain deferred. There is no canary/promote deployment state machine.
