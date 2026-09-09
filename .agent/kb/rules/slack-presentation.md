# Slack presentation patterns

Approved product patterns from Andrew's Slack-card review, 2026-09-09. These guide future
implementation; they are not a claim that the current renderer implements them. The task
`2026-09-09-redesign-all-slack-cards-and-states-for-consolid` contains examples and source gaps.
Ryker naming and identity follow [ryker-brand.md](ryker-brand.md). Apply that queued full rename
to current authored product/command copy during cutover; retain native Slack constraints and
truthful historical source messages. The presentation patterns below are not an old-name exemption.

For the repeatable design, test and review-link process, read
[slack-card-design-workflow.md](slack-card-design-workflow.md). This file remains the canonical
pattern reference; the workflow points here rather than defining a second design system.

## One message per purpose

Use native Slack components. Distinguish new messages, updates to an original message, private
feedback, native typing, and history-only events. Do not turn every backend status into a card.
Questions and human answers stay separate. Execution telemetry belongs in the episode, not a
stream of generic “tool_call,” queued, ACK, or repaint-success notifications.

No nested debug trees, boilerplate disclaimers, redundant status sentences, or repeated Next/
Changes/Checks summaries. Preserve useful values and complete authorized details or exact links.
Diff reading is web/PR-only. Do not recreate Slack diff paging.

Use linked repository names when the trusted repository record supplies a destination. Do not
guess a URL from a display label or turn arbitrary message text into clickable Slack markup.
Use “← 🙋 your turn” for a human handoff, next to the item needing attention. Keep “your turn”
lowercase; the left-pointing arrow is separate from the current-stage glyph at the start of a row.
For status families, use a consistent icon vocabulary: ✓ complete/granted, ✕ failed/denied,
◷ waiting/expired (with its explicit label), ■ stopped/cancelled, ⚠ override/unavailable.
Keep the label where an icon alone would be ambiguous. Do not decorate every ordinary sentence
or rewrite historical source messages to force this presentation style.

All owned structural headings are colonless: Status, Reason, Evidence, Action, Runner and metadata
labels follow one shared heading renderer, across every state and card family. Inline prose such
as “Reason: …,” times, code and retained source text keep their punctuation. Test this as a shared
invariant, not a per-card string replacement.

## Welcome and settings

Write like a helpful teammate in simple, natural English. Use “I” and “you,” contractions,
and a clear next step when one is needed. Be warm without padding the message. Avoid system
requirements dressed up as conversation: say “I don’t have access to any repos, so please
connect one (or more) if you want me to work on coding tasks,” not “Repository tasks need a
connected repository.” Apply this voice to all card content, not just the welcome.

At every setup step, explain each option before asking the user to choose. Pair the exact
button label in bold with a short, natural explanation of what I will do, where and when.
Explain important differences: reading vs replying, alert threads vs new rooms, invitations,
default repo vs access, and saving vs cancelling. Don’t merely repeat the button labels in a
sentence or make the user click to discover the consequences. Keep the explanations visible
in the Slack message, not just in catalog notes. Adapt them to the actual available choices.

Generate the entire friendly welcome from effective saved settings: repository access,
conversation participation, alert handling, observation mode and incident invitations.
Explain the actual alert behavior; never say only “alerts are handled separately.”

Useful defaults require no setup click. Optional Q&A ends by re-rendering the same original
welcome from the saved configuration. Retire the wizard; do not create a second introduction or
leave contradictory old policy text. Failed saves must not change the displayed effective state.
Changing participation must preserve unrelated repository/alert/audience settings.

Later natural-language questions about settings and `/responder status` use the same structured
effective-settings view, with Configure channel and relevant list controls. Preserve their
different delivery audiences (conversation reply vs private command response). Reading settings
must never silently mutate them; all configuration controls recheck actor, channel and revision.

## saved-entity: one detail pattern for created and updated items

Use one reusable detail projection for schedules, standing rules, preferences, guidance and
memories, not separately handwritten “saved” and “updated” cards:

1. Stable, specific entity title and readable full purpose/instructions.
2. Compact metadata with real scope/destination, matching criteria, time/timezone or expiration,
   repository binding and source where relevant. “Until disabled” is a meaningful value;
   “unknown,” “not retained” and “no fixed binding” must not be confused.
3. A brief event notice such as Schedule saved or Schedule has been updated.
4. Exact-item view/manage controls and a direct removal control after creation.

Updated schedules look like saved schedules with new values and the update notice. Do not throw
away time, destination, expiry or task description in favor of a short acknowledgement.
Preference and guidance cards keep their text, scope, applicability, expiry and source after save.
Standing rules need source/trigger/filter, destination, expiration, catch-up behavior and any
failure-notification target. Translate raw IDs and enum values to meaningful labels, but never
invent a friendly name, a restrictive filter, a repository binding or a saved outcome.

Use the correct lifecycle operation: Delete schedule/rule/preference/guidance, Forget memory,
Close task/incident. Closing an incident is not deleting its Slack room. Removing a schedule or
rule stops future work; existing work and history remain. Forgetting memory does not erase
already-delivered messages or original sources. Destructive controls have native consequence
dialogs naming the exact resource; confirmations do not replace backend authorization/fencing.

## Collections

When asked for active schedules, rules or saved knowledge, send a separate message for each item
in the same requested thread. Each card owns its full readable purpose, metadata, view and removal
controls. Update only that item's message when it changes. Reuse the saved-entity projection;
never combine unrelated items and their delete controls into one large message. Remove internal
copy like “authorized scope.” The App Home remains one native Home view with distinct item sections.

For long lists, use a bounded page (normally up to five items) and a complete authorized list link
or explicit continuation. Do not flood a channel with unsolicited cards. Only show exact counts
from successful scoped queries. Empty, partial and unavailable results are different; a failed
query is never “no rules/schedules.” Do not expose inaccessible titles, counts or destinations.

## Task progress

Keep Workspace setup, Planning, Implementation, Self-review and checks, Draft PR, CI, and Review
and merge visible through the code-task lifecycle. Subtasks belong beneath their stage. Bold
the current stage and current subtask; completed and future work stay normal weight. Currentness
comes from lifecycle state, not arbitrary prose. Put detailed current activity on the active
subtask, not duplicated after its parent stage name. Counts/timings stay where they add information.

The agent self-corrects and creates/updates an authorized draft PR without normal manual readiness/
publication clicks. Human decisions, publication authority, merge and deployment remain distinct.
Use exact host evidence for checks, revision and PR status; never fabricate historical subtask counts.

## Governed review

One Emisar pending-review message updates on the authoritative review outcome. Review in Emisar
is an accented primary URL button, not a Slack approval mutation. At the top, show operator-facing
Reason, Evidence and Expected outcome if present; omit absent fields. These are dispatch metadata,
not private model reasoning. Then show the action call or trusted command preview as a native
code block, with runner(s). Full immutable refs and safe full arguments are one authorized link away.
Place omitted-argument notes directly under the Action code block, before Runner, not as a
disconnected footer. Do not put explanatory prose inside the executable-looking command text.

Use a Status section for the review outcome, without “I’ll continue the investigation.” Name the
reviewer and show their reason only when retained and attributable to that exact decision. Partial
review stays pending and shows N of M distinct reviews once, with no redundant “Waiting for N
more reviewers” sentence.
One denial is terminal even when earlier approvals exist. Preserve those earlier decisions.
An admin/owner override is conspicuous, names its actor and reason, and retains the real N of M;
it is not a vote, must not manufacture missing reviewers or change the snapshotted requirement.
Show an override only from its explicit authoritative event, never infer it from a short tally.
Expired, cancelled, unavailable and unknown identity/reason cases must not become fabricated
approval or denial. A review decision is not execution success. Keep review controls in Emisar.
Separate approval requests keep separate identities; never combine votes from different runners
or requests to satisfy a single request's quorum.

Use one shared current-status/history projection. Put the current status first, then one blank
line, then the decision history oldest first, one event per line. Do not move a denial to the top
of that history. If a single terminal decision is the whole history, show its actor and optional
reason once, with no duplicate summary/event. Omit the empty history and its gap.
For an ordinary multi-reviewer grant, credit the full quorum in the summary; the history names
each reviewer. A terminal denial needs its actor/outcome, not an approval-only counter mislabeled
as received reviews. Keep previous grants and the denial in history.

An override's current summary uses ✓ because review is granted: actor; actual N of M received;
remaining reviews were overridden. Its chronological audit event uses ⚠ and explicitly names the
admin override and reason. Earlier votes remain above that override event. Do not repeat the reason
in the summary or imply that the override supplied a missing vote. Keep all authoritative decisions;
only use retained timestamps and identities, never invented ones.

## Implementation questions

Keep the full question and every offered answer readable. For up to five choices, use short,
distinct button labels. When choices are long, show each complete answer above the controls,
paired with that exact label; never truncate away a condition or replace the durable answer with
the shorter label. A short label is presentation, not different permission or scope.

For six to ten choices, use one visible native radio group and an explicit Submit answer button.
Nothing is preselected. Selecting only stages a choice; only submission accepts it and resumes
work. Long choices still have their full text above the selector. A thread reply remains an
alternative. Do not split a single-choice question into independently submitted button batches.
Above ten, ask a useful narrowing question or offer a full supported form, never drop choices.
The catalog's preview-state controls remain buttons; they are unrelated to these Slack controls.

Bind the submitted selection to the exact question, option identity/index, revision, actor and
current wait. Reject missing/stale/cross-actor selections; resolve the full original answer
server-side. After a successful answer, retire all selection/submit controls and preserve question
context. Keep the human answer separate. Preview widgets do not prove the host supports this flow.

Before execution say Command to run only when a trusted, secret-masked preview exists. Executed
command is an actual run receipt, never a label for a pending action or reconstructed shell guess.
Preserve truncation/masking indicators and exact runner associations. Approval is not execution
success; polling failure is not denial or expiry. Do not add execution-status notification cards.

## In-place investigation vs incident room

For noncritical work offer Investigate alongside Create incident room. The first creates
durable read-only work in the existing thread without a room or invitations. The second uses the
configured incident policy/audience. One offer/choice owns both paths: concurrent choices must not
start both. Neither button grants new mutation, repository or cross-channel authority. Use
Open incident room only as a link after the room exists; “Open” must not hide room creation.

## Model-authored briefs

Lead with the user-visible problem and intended outcome, then the proposed change, scope and
checks. Do not paste a dense forensic trace, function/line inventory or old error transcript as
the work request. Preserve full original scope and source links. Distinguish the repository being
edited from read-only references; say what cannot be verified. Do not quietly broaden scope while
rewriting. A readable preview is not evidence that model prompts or runtime behavior were fixed.

## Preview and proof

Use state buttons in the catalog, not a dropdown or one specimen per enum. Selected state controls
its native Builder link, JSON copy/download and exact schema receipt. Native JSON validation is
not visual, mobile, interaction or delivery proof. Label recorded outcomes vs proposed examples;
do not modify harvested source data to make a design appear historically complete.

Every card-design handoff must include fresh direct Slack Block Kit Builder links in the reply,
covering each requested change and its materially different states. A catalog/file link alone is
not enough. Builder URLs contain a JSON snapshot, not a live reference: earlier links and open
tabs do not pick up catalog edits. Generate links from the current exact validated payloads, not
by reusing an earlier reply. The task's preview-links.mjs prints selected links after checking
their full-envelope receipts. Link each separate item message independently. If a payload exceeds
the usable URL limit, explicitly provide its JSON and the empty Builder instead of a stale link.
