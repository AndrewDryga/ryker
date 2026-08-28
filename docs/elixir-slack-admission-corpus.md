# Slack admission corpus review

This review was taken read-only from the stopped Blitz and Emisar Responder databases on
2026-08-27. It exists to turn legacy behavior into replacement tests without copying the legacy
architecture.

## Corpus shape

| Record | Blitz | Emisar | Total |
|---|---:|---:|---:|
| Work episodes | 1,515 | 193 | 1,708 |
| Agent runs | 2,383 | 429 | 2,812 |
| Watch-source runs | 2,300 | 421 | 2,721 |
| Direct Slack-source runs | 47 | 1 | 48 |
| Handoff runs | 36 | 6 | 42 |

The retained Blitz Slack inbox had 148 inputs: 88 app messages, 11 human messages, 43 synthetic
rechecks, four actions, one schedule event, and one mention. Fifty-nine were thread replies and 89 were
top-level messages. Emisar's short-lived Slack inbox had already expired, so its durable episode/run
records and the Stage 1 Emisar question-answer fixture supply that side of the corpus.

Blitz had 391 reviewed quality findings: 356 confirmed, including 146 high and 200 medium severity.
There were 190 objectives repeated across multiple episodes; the largest repeated objective had 36
episodes. That is strong evidence that correlation and continuation were not merely edge cases.

## Repeated failure shapes

The confirmed findings and exact retained Slack rows repeatedly showed:

- a newer lifecycle update causing useful prior work or its delivery to be silently discarded;
- separate external runs being merged because their cards shared an app, repository, or nearby time;
- one lifecycle being split because wording, counts, transient links, or displayed members changed;
- a new cycle inheriting an old Slack thread when only its history should have been linked;
- a later human message superseding an answer that had not yet been delivered;
- broad nearby-app context leaking an unrelated incident into another card's reply; and
- provider-specific phrase/signature rules treating material changes as duplicates.

The corpus also includes normal human thread continuation, direct questions, deployment cards,
Terraform lifecycle cards, firing/resolved alert cards, Better Stack incidents, scheduled checks,
engineering feedback, and unknown app messages. A replacement must handle all of them through the
same boundary.

## Design consequences

1. **Keep provider meaning out of the host.** Slack content is bounded data. A model judges whether two
   inputs describe the same work. The host never parses app names, alert words, run IDs, counts, or URLs.
2. **Persist before deciding.** An exact Slack event owns one durable inbox slot, so retries and crashes
   cannot duplicate or lose the decision.
3. **Offer bounded choices.** The model may select only opaque episodes from the same Slack conversation.
   It cannot invent an episode or destination.
4. **Keep routing immutable.** Continuing work keeps its bound thread. Starting new work always uses the
   current card/thread. Historical linkage never donates an old destination.
5. **Queue context; do not suppress it.** A newer input is admitted behind active work. It does not cancel
   an attempted turn or an undelivered answer. Later runtime and delivery modules must preserve this.
6. **Make silence explicit.** `ignore` is a durable model decision with a factual reason, not an implicit
   host filter. Explicit requests directed at Responder are forbidden from being ignored by the prompt.
7. **Keep model and host tests separate.** Deterministic tests prove that a chosen decision is stored and
   applied safely. Model evaluations prove that models choose the right decision from arbitrary content.

## Deterministic cases now checked in

The Stage 2 replay corpus uses exact retained production inputs for:

- an unknown deployment app starting work;
- firing and resolved cards continuing one active episode and original thread;
- two cards for one external run continuing one episode;
- two different external runs remaining separate;
- a later human reply reopening the same thread; and
- a new alert cycle using its new card while linking the prior cycle only as history.

Unit and PostgreSQL tests additionally cover exact Slack retry reconciliation, changed-retry conflict,
message edits, direct replies, explicit reactions, ignore decisions, delayed inputs that cannot satisfy a
newer wait, atomic wait resumption, decision-write rollback, and simultaneous model-decision races.

## Model evaluation cases for the runtime stage

These cases should reuse recorded context and expected decisions without adding host string matching:

- equivalent lifecycle updates whose wording, counts, or transient dashboard links change;
- distinct runs from one app/repository arriving close together;
- a genuine new cycle after a recovered/expired episode;
- an explicit request versus nearby human conversation that needs no Responder action;
- a material scope, deployment SHA, impact, or recommended-action change that must not be ignored;
- aggregate alerts whose displayed member changes while the underlying work remains the same; and
- unknown future app/block payloads that still produce a useful decision.

The later delivery suite must separately prove that a newer input cannot erase an accepted answer, that
an obsolete answer cannot outlive a newer terminal fact for the same work, and that Slack response-loss
reconciliation produces one visible result in the bound thread.
