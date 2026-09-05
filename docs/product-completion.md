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
  races, and persistent pending/progress indication in Slack and the Lab.
- [ ] Scoped GCP project discovery and useful Emisar organization context;
  resolve goal authorization and citation interoperability defects.
- [ ] Rich real-data Slack task cards and Card Lab examples for every family/state;
  public progress, subtasks, native confirmations and live in-place transitions.
- [ ] Complete GitHub App integration and native GitHub replay/live workbench.
- [ ] Finish native LiveView operational pages and Conversation Lab parity.
- [ ] Configuration v2 defaults, internally resolved policy pins, migration,
  validation and explanation without capability expansion.
- [ ] Reviewed organization-isolated learning corpus and comparative evaluation.
- [ ] Focused recovery/load/security proof, qualification, exact-release deployment
  and bounded live acceptance; update the capability ledger and task state.

## Rendered page acceptance

Inspect populated and empty states, errors, keyboard focus and narrow layouts.
Browser discovery currently returns no attached browser. Screenshots supplied by
the operator establish defects, not acceptance of our changes.

- [ ] Requests and filters
- [ ] Episode and retained request detail
- [ ] Conversation Lab and all card actions
- [ ] Slack Card Lab: every family/state, especially working tasks
- [ ] Incidents and incident detail
- [ ] Failures and confirmed recovery
- [ ] Usage and cost, including drill-downs
- [ ] Audit trail
- [ ] Schedules and schedule detail
- [ ] Subscriptions
- [ ] Memory and review
- [ ] Decisions
- [ ] Findings
- [ ] Model calibration
- [ ] Configuration
- [ ] Channels and channel detail
- [ ] Repositories
- [ ] Workspaces
- [ ] Test journeys
- [ ] GitHub workbench when implemented

## Live boundaries

Slack acceptance is confined to Emisar #test. GitHub live tests require an
operator-selected test repository/issue/PR; none is selected yet. Do not use
another workspace or invent a target. Existing Coop credentials remain in use.
Do not restart or install Coop as part of Responder deployment.

Local classifier hosting/training and the one-command adoption/demo workflow
remain deferred. There is no canary/promote deployment state machine.
