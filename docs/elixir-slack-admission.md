# Elixir Slack admission

This is the second isolated module of the replacement Responder. It accepts any bounded Slack event,
gives its content and a small set of related episode candidates to a model, validates the model's
structured decision, and commits that decision with the episode transition in PostgreSQL.

It is not wired to the live Slack socket or Coop yet. No running Responder uses it.

## Boundary

The trusted Slack adapter supplies event, message, actor, workspace, channel, thread, revision, and
time identities. Arbitrary message text, blocks, attachments, and app metadata remain bounded JSON.
They cannot choose an episode, owner, destination, or database identity.

The host does not look for `Grafana`, `Terraform`, alert status words, run IDs, or any other provider
syntax. The model interprets whatever a user or app posted. The host only:

- deduplicates the exact Slack event and rejects changed retries;
- binds top-level work to its message thread and replies to their existing thread;
- offers opaque candidates from the same Slack conversation;
- limits whether a candidate may be continued or used only as history;
- validates one exact structured decision;
- serializes concurrent decisions; and
- commits the inbox decision, input admission, and optional wait resumption atomically.

## Model input

`Responder.Slack.Admission.Prompt.build/1` returns provider-neutral instructions, the exact response
schema, and a context from `Responder.Slack.Admission.Context.for_model/1` containing:

- the current generic Slack content, actor kind, event kind, time, and whether it is a thread reply;
- up to eight candidate episodes with opaque references, active/complete/cancelled state, same-thread
  status, allowed relationships, and compact chronological first/latest input previews.

Database IDs, episode keys, raw destinations, and Slack routing timestamps are not exposed as choices.
The entire encoded prompt is bounded to 64 KiB. Full Slack content stays durable, while unusually large
content and candidate inputs are represented to the admission model by bounded previews.

## Model decision

`Responder.Slack.Admission.Decision.json_schema/0` is the exact schema. The model chooses one action:

- `start_episode`: new work, optionally linked to older history;
- `continue_episode`: another turn in existing work;
- `reply`: a direct answer, either new or related to an offered episode;
- `react`: one Slack emoji name and no message;
- `ignore`: no user-visible action, with an audited factual reason.

The model may only use an opaque candidate reference supplied in this context. It cannot provide a
channel or thread. A `history_only` choice always creates a new episode under the current Slack card;
the older destination remains history, never the new reply destination.

## Persistence and failure behavior

The inbox is the durable natural slot for one Slack event. An exact Slack retry returns the original
row. A retry of the same host-owned logical decision reference, action, candidate, relation, and
reaction returns the original result even if its explanatory reason is paraphrased. A new decision
reference or materially changed decision is an explicit conflict.

Admission locks the inbox row, then applies all related episode commands under the episode lock in the
same database transaction. If the decision row, episode projection, input event, or wait resumption
fails, the entire operation rolls back. No external Slack or model call occurs inside that transaction.
The host snapshots candidates and the conversation's episode generation under one short lock. Before
creating new work, it checks that generation again under the same lock. If any new episode appeared,
the still-pending input is reconsidered with that candidate visible; this prevents two separate cards
for one lifecycle from being split merely because their decisions ran concurrently.
Continuations use the selected episode's locked reducer state, so newer inputs queue and a newly started
wait can be resumed without spending another model turn.

## Historical proof

The broader [corpus review](elixir-slack-admission-corpus.md) records the database counts, recurring
failure shapes, design consequences, and next model-evaluation cases.

The replay corpus contains exact recent production inputs for:

- an unknown deployment app starting work without a provider parser;
- a firing and resolved card continuing one active episode and original thread;
- two cards for one Terraform run continuing one episode;
- two different Terraform runs staying separate;
- a later human reply reopening the same Slack thread; and
- a new alert cycle starting under its new card while linking old history.

These deterministic tests execute the real inbox, admission validator, episode kernel, and PostgreSQL
transactions. They do not call an LLM. They prove that a recorded decision is applied safely; the next
runtime stage must separately replay these contexts against supported models to evaluate whether the
model makes the right generic decision.

## Next boundary

The next module should connect the real Slack adapter and Coop admission turn to this API. That adapter
will enrich trusted IDs with resolved user and channel names for model context, while retaining IDs for
authority and routing. Slack delivery, full reasoning sessions, memory, automations, and GitHub work
remain separate later modules.
