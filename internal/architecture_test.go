// Package internal holds the architecture invariants that no single package
// can check for itself: which packages may import which, and how large the two
// broad types are allowed to be.
//
// These are ratchets, not aspirations. The budgets are set just above today's
// counts so ordinary work is unaffected, but growing Service or Store further
// requires deliberately raising a number in this file — which is the moment to
// extract a sub-package instead. Lowering a budget after an extraction is
// always welcome and never needs discussion.
package internal_test

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
)

const modulePath = "github.com/AndrewDryga/ryker/"

// methodBudget caps the *exported* receiver-method count of the two broad
// types. Exported methods are the surface other packages depend on, and that
// surface is what makes a type hard to split. Unexported helpers are excluded
// deliberately: turning a free function into a method to give it access to the
// injected clock is a refactor, not new API, and should not trip this budget.
// See the package comment: raising an entry is a decision, not a formality.
var methodBudget = map[string]int{
	// Thirteen for ControlPlaneDiscardSession, which reclaims a fork belonging
	// to no work record. Thirty-two of thirty-eight blocked cleanups are
	// record-less, and the incident-shaped discard cannot reach any of them —
	// the page said so in its own words. It enforces the same workspace rules
	// and drops only the bookkeeping that needs an incident.
	"Service": 13,
	// 221 today, down from 300. The budget has been raised for real capability
	// before — the standing-assignment layer took it from 290 — but it now comes
	// down by extraction. Callers reach an extracted area through a field like
	// store.Memory, not a delegating method, because a passthrough still counts
	// here and would make the extraction invisible to this number.
	// 229 for GetCoopCleanup. NextCleanup answers "what should the janitor do
	// next" and filters to the states the janitor owns, so it can never return
	// the blocked row an operator is acting on.
	// 230 for HoldOffAgentRunPoll. A poll that fails leaves the run running and
	// its cursor unadvanced, so the next tick fails identically; one finished
	// result rode that loop three times a second for seventy-nine minutes. The
	// hold-off has to be durable rather than a field on Service, because the
	// error it writes to the run is also what lets a stalled episode tell an
	// operator what actually failed instead of "no progress".
	// 234 for the four ForTest hooks behind the lease fairness scenario
	// (age, mark running, set failures, touch). They exist so the starvation
	// test can shape a cycling blocker without exporting a settable clock;
	// each writes one column and nothing calls them outside _test files.
	//
	// Lowered from 234 to 225 on 2026-08-15 when standing assignments moved to
	// standingassignmentstore. Nine methods went with them and nothing was left
	// behind to delegate, which is the only way an extraction reduces this
	// number: a passthrough would still be a method on Store.
	//
	// Lowered again to 217 the same day when the eight Emisar approval methods
	// moved to store/approvalstore. Callers reach them as store.Approvals.Get
	// and store.Approvals.Record; the ninth query phase 5 needs — approvals by
	// episode rather than by incident — lands there and costs this number
	// nothing, which is the whole argument for the field.
	//
	// 219 on 2026-08-15 for the two writes escalation-on-correction needs:
	// NoteAgentRunCorrectionClass, which counts a correction against its class,
	// and SetAgentRunTargetFloor, which records the ladder rung the next turn
	// may not be answered below. Both are here rather than beside the
	// correction because both edit the run's context envelope as raw fields
	// inside a transaction — the correction paths write the round counter and
	// then requeue, so the caller's copy is already stale, and re-encoding it
	// would drop the increment that bounds the loop.
	//
	// 220 on 2026-08-15 for ReviewEpisode, the one write the episode review
	// ledger has. Measured, not rounded up. A package would be the usual answer
	// and is the wrong one for a single method: the ledger's read side is the
	// dashboard's own query, so an episodereviewstore would hold one upsert and
	// the terminal-state refusal it shares with the reducer, and the refusal is
	// the reason this belongs beside the other episode-kernel writes rather
	// than a directory away from them. Revisit at the second method.
	//
	// 221 on 2026-08-16 for ClearAgentRunCorrectionClass, the reset half of the
	// escalation ledger beside NoteAgentRunCorrectionClass and
	// SetAgentRunTargetFloor: a retry that moved up the model ladder is a
	// different model, and it starts without the previous rung's unreadable
	// tally. Same transactional raw-field edit as its siblings, for the same
	// reason. Three methods now form that ledger; they are the next cohesive
	// extraction (an escalation store) once the alert-stream work lands.
	//
	// 223 the same day for the two reads an alert stream needs, both of which
	// are SQL over rows this package owns and neither of which has a home
	// elsewhere. HasNewerSentReplyInThread replaces "a newer input was
	// admitted" with the only durable reason to withdraw a written answer — a
	// newer reply already sent in this thread — after that reading threw away
	// four finished Grafana answers in ninety minutes.
	// SumEpisodeStructuredCorrections totals what an episode actually spent,
	// because the second correction budget used to count the episode's attempt
	// number and an alert stream is now one episode across every card it
	// produces. Both are aggregates the callers cannot compute without loading
	// every row they aggregate.
	"Store": 223,
}

// lineBudget caps non-test source lines per package.
//
// internal/service is over any reasonable size and the budget only stops it
// drifting further. Every entry here is a ratchet: lower it when a package
// shrinks, in the same commit, so the number tracks reality rather than
// becoming a floor to grow into. Raising one is a decision that needs a reason
// written beside it — that has happened once, during the decision-logic
// refactors, and was earned back by extracting internal/localstate.
//
// The offline evaluation family moved to internal/evaluation on 2026-08-12.
// When the paragraph this one replaced was written, those files referenced 57
// unexported service symbols and the move was blocked; extracting
// internal/decision quietly paid most of that debt down, and the remainder
// was 16. Fourteen shared helpers are now exported where they live, two were
// wrappers whose agentprompt originals the harness calls directly, and the
// Service internals the harness replays — episode construction, the watch and
// conversation prompts, the offer preparation — are reached through the
// Evaluator seam, which exists for the harness and nothing else.
//
// The process-local coordination state moved to internal/localstate, which is
// how this budget came back to 28000 after the decision-logic refactors.
//
// A note on margin, learned twice the hard way: a budget set near the exact
// current count is a tripwire, not a ratchet. The next legitimate feature trips
// it, and the pressure to "just bump it" is highest precisely when the change
// is justified — which is how a guard becomes a rubber stamp.
//
// These numbers exist to stop DRIFT, not to tax features. The working rule:
// leave a few hundred lines of margin, tighten hard after an extraction, and
// leave it alone while features land. The guard has done its job — it forced
// internal/localstate, internal/provider and internal/recall out of this
// package rather than letting it absorb them — and it only keeps working if
// tripping it means something.
// Re-baselined when the count switched from every line to code lines only.
// Each is roughly 5% above today's count: enough that ordinary work never
// touches it, little enough that a package quietly absorbing a new
// responsibility does.
// service was raised from 24400 to 24600 for the offer-correction path: the
// host now hands a rejected offer back to the model instead of dropping it.
// The new headroom is deliberately thin — under half a percent — because this
// package has grown past the 5% the others still have, and the next thing that
// wants room here should have to answer for it. What it really needs is an
// extraction, not another raise.
// service was raised from 24620 to 24880 to make four confirmed production
// failures legible. Each was a path that could not work and said nothing: a
// Slack retry loop with no log or audit at all, an App Home interaction posting
// to a channel that does not exist, prewarming that read only static YAML and
// so did nothing on a database-configured deployment, and a configured channel
// the bot is not in that no code anywhere compared. Nearly all of the added
// lines are the saying-so — structured log calls, an audit event, and the
// skip-reason branches that used to be a bare continue.
//
// This is the raise the previous note warned about, and it does not earn the
// package any room for features. The extraction it names — the offline
// evaluation family, behind the decision domain becoming its own package — is
// still the only thing that brings this number down, and it is still next.
//
// The next thing answered for it. 24620 to 24780 for host-side reply shape:
// an audit of 244 posted replies found a median of 81 words against a stated
// bar of one to three sentences, one in five inside it, 25 messages closing on
// a caveat instead of an answer, and the word "hi" drawing 245 words. Every
// one of those rules was already in the prompt that produced them. Prose had
// stopped binding, so the bound moved into the host, which is where a rule you
// can measure belongs — and this is the trade the budget exists to make
// visible: 103 lines of enforcement bought back against instructions the model
// was free to ignore.
var lineBudget = map[string]int{
	// Raised from 24620 on 2026-08-08 for the target parser that fills
	// context_manifests.provider/model/reasoning_effort. Those columns had
	// existed since the table was created with nothing assigning them, so all
	// 57 production rows read empty and the control plane showed three blanks
	// where the model that ran should be. The package had seven lines of margin
	// and a real feature needed ten.
	// Raised again on 2026-08-08 for the Terraform lifecycle standing rule and
	// the widened thread-location phrasings. Four lines over the previous
	// entry; the alternative was compressing an unrelated block to make room,
	// which is how a budget stops measuring anything.
	// And five more on 2026-08-08 for the behavior-offer acknowledgements that
	// stop a confirmation reply from explaining rule types and catalog
	// internals — the "watery replies" complaint applied to offers.
	// Raised to 24700 on 2026-08-08 for ControlPlaneAct: the web control plane
	// gained publish/discard/close actions, and those must run through the same
	// service handlers the Slack buttons call — the Coop review, the verified
	// discard plan, and the cleanup scheduling live behind clients only this
	// package holds, and a store-side reimplementation would be a second copy
	// of the safety rules. Twenty-three lines of entrance, no new behavior.
	// And twelve more for ControlPlaneChannelSetting, which lets the dashboard
	// write a participation override through the same store call the slash
	// command uses. The alternative was the dashboard writing slack_settings
	// itself, which is a second implementation of the inherit rule.
	// And seventeen more to grade a reaction rather than only detect a bad one.
	// The map went from six negative emoji to a sentiment per emoji, gained a
	// helper that strips Slack's skin-tone suffix — which the negative half was
	// silently missing too — and the caller now picks a summary and a status
	// from the grade. Praise records as noted, not open, so it never enters the
	// queue whose only available decision would be to dismiss it.
	// Thirteen more to hand the bounded conversation lane the memory it already
	// loads: two parameters and two payload fields on conversationPrompt, plus
	// the scope choice when feedback becomes guidance. The lane had been
	// bumping recall counters for context it then dropped on the floor.
	// And a further raise for the Slack surface work: prewarming now reads the
	// channel control plane rather than only YAML, configured-but-unjoined
	// channels are reported, and a channelless interaction repaints the App
	// Home instead of addressing the empty string. Three silent failures, each
	// of which needed the code that makes its silence impossible.
	//
	// Raised to 24760 on 2026-08-09 for the episode-history retention class.
	// Four lines are the change itself — one horizon passed to Prune, and two
	// counters in the prune log so the sweep can be checked from outside rather
	// than believed. That mattered here: the symptom that started this was a log
	// line that read "agent_runs":0 every time, forever, and a counter nobody
	// prints is a counter nobody can catch lying.
	//
	// The other forty-four are margin, restored deliberately. This entry was
	// sitting at the exact current count, which the warning four paragraphs up
	// says is a tripwire rather than a ratchet: every addition to the package
	// fails, whatever its merit, and the pressure to bump it is highest exactly
	// when the change is justified. Moving off zero is what that warning asks
	// for, and it is the same reasoning that moved store off 11000.
	//
	// Raised to 25260 on 2026-08-09 to stop this package shouting at rooms. An
	// operator watched Ryker post one person's mistyped setup answer to a
	// shared channel and said never to do that again; the audit that followed
	// found three more of the same shape. A colleague who is not an operator was
	// refused in public, once per message they sent. A request Ryker gave up
	// on after twelve silent attempts put its raw error in front of the room and
	// told everyone to retry a command only one person could run. And the same
	// permission refusal was private through /responder and public through
	// @Emisar, so the spelling decided who watched.
	//
	// Fifty-three lines: three routing branches, one shared helper, one extracted
	// reportAbandonedInput, and the log call that keeps a failed ephemeral from
	// being the silence this file's previous entry was written to prevent. It
	// buys back rooms that were learning to tune Ryker out, which costs more
	// than any of the messages were worth. The extraction two entries up is still
	// the only thing that brings this number down, and it is still next.
	//
	// Raised to 25320 on 2026-08-09 so the quality judge can see the two things
	// the operator complained about. It could see neither. A reply was
	// "extremely long and watery" and the rubric's only length criterion said
	// "matches the requested depth", which is a taste; the reply "was posted in
	// the channel itself and I can't even tell why", and the judge's material
	// was a slackui.Message, which has no thread and no channel, so where a
	// message went was not merely missed but unrepresentable.
	//
	// Thirty-nine lines, of which most are the prompt: the measurement itself
	// lives in internal/decision beside the bound it reuses, and what stayed
	// here is two fields on each corpus struct, their validation, and the rubric
	// sentences that tell a judge how to read them. The prompt was not split
	// across packages to save the budget — a rubric a reader has to assemble
	// from two files is how a bound stops being checkable, which is the failure
	// this whole change is about.
	//
	// Lowered to 25100 on 2026-08-09 when the action-proposal machinery came
	// out: the Slack approve and reject handler, the proposal preparation and
	// catalog prompt, and the lifecycle sweep that force-failed rows a disabled
	// feature could not create. 295 lines, none of them reachable — the config
	// validator has refused a non-empty actions map for several releases.
	//
	// Not all 295 are taken back. This entry was sitting 44 lines under its cap,
	// which the note above calls a tripwire rather than a ratchet, and a
	// deletion is the right moment to fix that: the budget comes down by 220 and
	// the margin goes up to 119. Locking in the whole win would leave the next
	// legitimate change failing on the merits of this one.
	// Seven more to make shadow mean what its own description says. It covered
	// message and bot_message only, so an observe-only channel still answered
	// anyone who typed the bot's name — including the operator asking it to
	// stop. The mention now gets an ephemeral answer instead of a channel post,
	// which is the extra branch.
	// Raised by twenty lines for durable publication progress after the same
	// change extracted the 225-line review policy and the entire persistence
	// state machine. The remaining service code is orchestration across Coop,
	// Slack, and the publisher; moving it would duplicate those clients.
	// Lowered to 21820 on 2026-08-12 when the offline evaluation family became
	// internal/evaluation — the ~3,800 lines this file had named as the next
	// extraction three times. The margin left is a few hundred lines on purpose:
	// the change that tripped this budget at three lines of headroom is still in
	// flight, and a ratchet that re-arms at zero is the tripwire the note at the
	// top of this map warns about.
	// Raised to 21889 on 2026-08-13 for the three defects behind a finished
	// engineering task that never reported: a result operation that could not
	// apply failed the completion beside it, the poll that hit that failure
	// retried it forever, and the stall it produced was reported as "no
	// progress" when the run had already recorded the cause. The next
	// extraction here is result-operation application — recordResultOperation-
	// Events and what it now delegates to are cohesive and roughly 120 lines —
	// but it needs an interface over a dozen store methods, and rebuilding the
	// path that just failed in production is not work to bundle into its fix.
	// Raised to 21895 on 2026-08-13 for the live activity window. The cohesive
	// area did leave: the projection — which recorded moments a card shows,
	// what a reasoning payload may say in Slack, when the second read is worth
	// making — is internal/liveturn, and it took roughly 120 lines with it.
	// The six that stayed are the wiring that cannot: a throttle field, the
	// refresh call in the poll loop, and the fetch at the one place a card is
	// composed. Moving those would shuffle lines between packages without
	// moving a decision, which is the thing this number exists to notice.
	// Raised to 21904 on 2026-08-13 for the overdue watchdog's second clock.
	// Nine lines: the activity grace constant, the widened store call, and a
	// four-line predicate that turns an episode's last narrated moment into the
	// age its card states. All three are the watchdog's own policy — how long
	// silence has to last, and what "no evidence either way" means — and the
	// only other place they could live is the message constructor, which would
	// put a staleness decision inside a renderer to move six lines across a
	// package boundary.
	//
	// Raised to 21950 on 2026-08-13 for the overflow menus, which rendered and
	// could not fire. Slack reports a menu choice in `selected_option.value`
	// and this package read `value`, so every ⋯ option on every card arrived
	// carrying nothing — seven live controls, including the only route to the
	// full text of a request.
	//
	// Fifteen lines. The decision did leave: reading a block action down to the
	// control it fires, and the option-value codec that makes an overflow
	// choice routable at all, are in slackui beside the renderer that writes
	// them — seventeen lines, and the only place that knows the encoding. What
	// stayed is the wiring that cannot: a store read and its error path, the
	// enqueue that answers in the card's thread, one entry on the closed-
	// incident read-only list, and the socket's drop-and-acknowledge for a
	// selection with no action in it. Moving those would put a Slack client, a
	// store handle and a logger behind a package boundary to relocate an error
	// check.
	//
	// The other thirty-one are margin, restored deliberately. This entry has
	// been re-armed at exactly its own count three times since 2026-08-13, and
	// the note four paragraphs up calls that a tripwire rather than a ratchet:
	// the next change fails on this one's merits, and the pressure to bump it
	// is highest exactly when the change is justified. The next extraction here
	// is still result-operation application, named two entries up.
	//
	// Raised to 21965 on 2026-08-14 for the legacy-result squeeze: a watch turn
	// that answers in the pre-operations shape is now asked once to re-emit it
	// as typed operations. This entry did fail on its own merits first, and the
	// change answered by leaving as little here as it could — the rule for what
	// counts as a legacy result and the single-shot budget went to
	// internal/decision beside the WatchTurnState field that carries it, and the
	// correction's prompt block went to internal/agentprompt beside the other
	// host corrections. That is 21 of the 36 lines gone from this package.
	//
	// The fifteen that stayed are wiring that cannot leave: one correction class
	// and its entry in the list that keeps the reporting command honest, the
	// read of the model's own result before host enforcement rewrites it, the
	// rung on the correction ladder, the branch that keeps this correction out
	// of FailureDetail (which means "rejected", and this result was accepted),
	// the arm of the exhaustion switch that ships the answer instead of blocking
	// it, and the audit outcome. Every one of them touches the store handle, the
	// run record, or the ladder's local state.
	//
	// Raised to 22030 on 2026-08-14 for the live-feedback round: an operator
	// clicked the controls on a deployed card and could not tell any of them
	// from a dead button. Every ephemeral this package sends was posted with no
	// thread_ts, so on thread-scoped work each private answer — a refusal, "No
	// turn has finished here yet", the reason a press changed nothing — was
	// delivered at channel level while the operator watched the thread. Ask for
	// an update queued a real run and said nothing. Full request replied in the
	// thread instead of opening on the card.
	//
	// 120 lines landed here and 104 left, which is the shape this map keeps
	// asking for. What left is the other half of a control: reading an action's
	// value back to the work it acts on. The pager cursor codec, ActionIncidentID
	// — now the single place that knows how every control packs its target — and
	// MessageOffersControl are in slackui beside the option-value codec that went
	// there on 2026-08-13, and NewChangesNavigation went with them because it
	// mints those cursors and returns a slackui type. Putting them there also
	// fixed a live defect the split exposed: the incident lookup read the value
	// raw and special-cased one action, so every diff-pager button resolved a
	// cursor as if it were an incident id and was answered "no longer valid".
	//
	// The sixteen that stayed are wiring that cannot leave. The ask toggle's
	// handler composes a card and calls Slack's update, so it holds the store,
	// the publisher, the Coop client and the sanitizer at once; the press
	// acknowledgement holds the Slack client, the sanitizer and the logger; and
	// the thread helper reads the incident to answer where a private reply goes.
	// Moving any of them would put four clients behind a package boundary to
	// relocate a call.
	//
	// 22030 rather than 21981. This entry was sitting at exactly its own count
	// again — the fifth time — and the note at the top of this map calls that a
	// tripwire rather than a ratchet.
	//
	// Raised to 22054 on 2026-08-14 for the day the prompt stopped being a
	// heap: the episode-continuity block joins the triage suffix (a Slack
	// follow-up now sees what its earlier episode proved), and the watch
	// prompt's consolidated sections carry their own line shapes. Most of the
	// day's prompt work was rewording inside existing lines; these are the
	// lines that are genuinely new.
	//
	// 22064 for the behavior batch later the same day: the disagreement band,
	// glossary learning, the style-signal clause, and the unverifiable-alert
	// rule are prompt lines, and prompt lines live in this package.
	//
	// 22079 the same evening, for the supersession guard's sibling coverage
	// and the nudge rule — the two halves of the 2026-08-14 "What would you
	// like me to check?" failure.
	//
	// Raised to 22175 on 2026-08-14 for the weekly self report, atop the
	// evening's 22079: one call in the maintenance sweep and one function that
	// reads the schedule, the recorded send, and the configured channel. The
	// two halves that could leave did — internal/selfreport composes the
	// digest and internal/store/selfreportstore counts it, both registered
	// below — and the margin left is what stops the next honest change
	// arguing with a number instead of a reviewer.
	//
	// Raised to 22400 on 2026-08-14 for operator-question choice buttons: the
	// press handler that turns a click into the asked operator's answer, its
	// delivered-card and identity checks, and the wiring at both
	// blocked-completion sites. The two rounds of margin this entry carried
	// today were both consumed by real features within hours, which is the
	// argument for the margin, not against it.
	//
	// Raised to 22540 on 2026-08-14 for the session-rotation handoff: the
	// retirement seam both rotation lanes now share, the handoff queue and
	// its guards, and the six source-kind checks that keep a run nobody in
	// Slack is waiting for out of every Slack-facing path.
	//
	// Raised to 22580 on 2026-08-14 so a turn inside a thread can see the
	// channel around its root. A follow-up that says "see the channel above"
	// or "^" was answered from conversations.replies alone, which is the
	// thread and nothing else, so the alert the operator was pointing at was
	// never in the prompt — the model said so, correctly, and the turn was
	// spent.
	//
	// The decision left: which messages are the channel around a root rather
	// than the thread itself is agentcontext.AroundThreadRoot, beside
	// MergeSlackContext and the same-conversation rule it belongs with. What
	// stayed is the second bounded read and its own prompt section — the read
	// holds the Slack client, the history cache, the bot identity and the
	// logger at once, and the section is prompt lines, which live here.
	// Raised to 22620 on 2026-08-14 for the day's parallel landings arriving
	// together: the coop_image_unbuildable readiness veto (an unbuildable
	// image ran 75 minutes with /readyz green), and the failure cards that
	// now take the incident so a task can be told it is a task. Each branch
	// carried headroom against the budget it saw; three same-day merges spent
	// it. The real split of this package stays owned by the kernel migration's
	// Phase 9 — extracting mid-cutover would preserve the bugs the cutover
	// exists to delete.
	//
	// Raised to 22700 on 2026-08-14 for repositories Ryker keeps current.
	// There was no `git fetch` anywhere in this product — not in Go, not in a
	// script — so "current repository content", which the evidence hierarchy
	// ranks above configuration and confirmed memory, meant whatever a human
	// last remembered to pull.
	//
	// The cohesive area did leave, and took the interesting decisions with it:
	// internal/repomirror owns where a slug becomes a directory, what a fetch
	// failure means, when a clone is too old to be called current, and the
	// words a manifest uses to say so. What stayed is 64 lines of wiring that
	// cannot: the two prepare-path calls that must sit before a session forks
	// the checkout, the maintenance-lane arm that must return ErrNotFound so a
	// GitHub outage never reads as stalled work, and three path resolutions
	// (publication, closed-fork verification, policy) that each hold the
	// service's config and a client at once.
	//
	// 22700 was that raise measured against its own branch; merged beside the
	// thread-surround and readiness landings the count is 22703, so the merged
	// budget is 22740 — the same thin margin, measured once against the tree
	// that actually exists.
	//
	// Raised to 22780 on 2026-08-14 so one episode can finally inform another.
	// Ryker held hundreds of fully traced episodes and every new incident
	// still started from zero; the single highest-value senior-SRE behaviour —
	// "this is the July checkout episode, the cause was pool exhaustion, the
	// fix took ten minutes" — was structurally impossible.
	//
	// Thirteen of the two hundred are not this change: the count was already
	// 22593 against a budget of 22580 when this branch started, because the
	// thread-surround landing raised the budget to the line it had reached and
	// the next merge spent it. That is the tripwire this map warns about four
	// paragraphs up, arriving exactly as described.
	//
	// The rest is wiring, and it is wiring on purpose. The projection is in
	// internal/store/intelligencestore, the scoring in internal/recall, the DDL
	// in internal/store/migrationddl; what stayed here is the layer's prompt
	// text, its slot in the two drop orders, and the four lines that gate
	// recall on an episode's effort contract — none of which can live anywhere
	// the prompt assembler cannot see. internal/service/episode_recall.go is a
	// candidate for extraction the day a second caller needs it.
	//
	// 22780 was that raise against its own branch. Merged beside the routing
	// profiles and the day's other landings the count is 22862; the budget is
	// 22900, measured once against the tree that exists. Five same-day raises
	// is the strongest argument yet for the Phase 9 split — after the kernel
	// cutover stabilizes ownership, per the migration plan's own ordering.
	//
	// Lowered to 22860 on 2026-08-14 when the legacy result dialect stopped
	// being read: the correction rung, the audit, and the shipped-anyway arm
	// left with it. Actual is 22830; lowering after a deletion is the ratchet
	// working in the direction it was built for.
	//
	// Raised to 22930 on 2026-08-14 for the change ledger: an incident can now
	// be told what changed. It is the first question of every real outage and
	// Ryker could not answer it, while the facts went past its own hands
	// three times a day — a deploy webhook became a signal or nothing, the
	// publication follower watched its own pull requests merge without
	// ledgering the merge, and the approval watcher read mutating Emisar runs
	// to terminal state and kept only the approval row.
	//
	// Sixty-two lines, and the sixth same-day raise, so it is worth saying
	// exactly what stayed. The vocabulary, the bounds, the identity derivation,
	// the six-hour window, the scope resolution, the ranking, the prompt text
	// and the manifest references are all in internal/changeledger; the table,
	// its idempotent insert and the in-transaction publication write are in
	// internal/store/changestore. Better than four hundred lines of this
	// feature are outside this package. What is here is the store read behind
	// two configuration values, the layer's slot in the two drop orders, and
	// the six lines that ledger a supervised Emisar run — none of which can
	// live anywhere the prompt assembler and the approval watcher cannot see.
	//
	// The deletion above paid for half of it: 22830 plus this is 22892, against
	// the 22900 that stood before either landed. The margin is 38 rather than
	// zero for the reason four paragraphs up — a budget standing exactly at the
	// count is a tripwire that fails the next legitimate feature whatever its
	// merit — and it does not buy room for the Phase 9 split to keep waiting.
	//
	// RAISED to 22960 on 2026-08-15 for the delta turn: a follow-up attempt into
	// a Coop session that already holds its briefing now sends the new message,
	// the episode delta and one line saying the standing briefing applies,
	// instead of the briefing again. Measured on blitz over 2026-08-14 and the
	// first five hours of 2026-08-15, 201 follow-up attempts resubmitted
	// 30,258,462 bytes into such sessions and 99.22% of those bytes were
	// byte-identical to the message before them. Replayed through the delta,
	// those turns send 2,464,614 bytes instead — 8.35 million of 9.1 million
	// uncached input tokens never leave the host.
	//
	// The decision itself is NOT here: internal/turndelta is a pure predicate
	// over (session, attempt, standing briefing, contract) with its own table
	// tests, which is the shape this budget is supposed to force. What landed in
	// this package is the 94 lines that cannot leave — reading the attempt, the
	// previous manifest and the resolved session out of the store, and the two
	// call sites in prepareTriageAgentRun. One escalation block was deduplicated
	// into turndelta on the way, so both prompt shapes say it in the same words.
	//
	// This is a raise for real capability and it buys the package no room for
	// anything else. The extraction this note has named twice — the Phase 9
	// split, after the kernel cutover stabilizes ownership — is still the only
	// thing that brings the number down, and it is still next.
	//
	// 22960 was that raise against its own branch; merged beside the change
	// ledger's 62 lines and the interrupted-turn replay, the tree is 22995,
	// so the budget is 23030 — measured once against what exists. Every
	// same-day entry above says the same thing in different words: the split
	// this package needs is the kernel migration's Phase 9, and it is next.
	//
	// Raised to 23260 for the remediation trust ladder's host half — 208 lines
	// that grade a promotion, take a rung back on a failed run, and answer the
	// one click that grants authority. This is the largest single raise in a
	// while and it is worth saying exactly what did NOT come here, because that
	// is the argument for it: the ladder itself, the deterministic matcher, the
	// promotion arithmetic, the demotion rules, the Emisar-run-status mapping and
	// the confirmation payload are all in internal/remediation as pure functions
	// over values, with table tests and no database; the rows are in
	// internal/store/grantstore; the copy and the cards are in internal/slackui.
	// What is left in this package is what genuinely cannot leave it — reading
	// the incident to build a trigger class, recomputing the count through the
	// store, re-authorizing the operator against config and Slack, the audit
	// events, and the two deliveries. Every one of those needs four Service
	// internals at once, and putting them behind an interface would move lines
	// between packages without moving a decision, which this file already warns
	// is how a budget stops measuring anything.
	// +10 on landing: the two grant deliveries the ladder posts are bound to
	// their episode (the binding ratchet caught them the hour it landed), and
	// the resolver that finds an approval's episode is four lines here.
	//
	// LOWERED to 23260 on 2026-08-15 for the knowledge offers — the first time
	// in a while this number has gone down while a feature landed, which is the
	// only way it was allowed to land at all. The package had one line of
	// headroom, so 186 lines left first: everything in this package that decided
	// what Ryker will accept as a Slack file, how it names one and how much
	// of one it reads went to internal/slackfile, unchanged, as pure functions
	// that never needed the coordinator. The 175 that arrived are the two
	// knowledge offers' host half — post the card, read the offer back,
	// re-authorize the click, and hand the confirmed artefact to Emisar or to
	// the engineering-task path. What did NOT come here is the argument for the
	// rest: the validators, the grading against the record, the confirmation
	// payload, the Emisar runbook-definition builder and the card document are
	// in internal/knowledgeoffer as pure functions with table tests and no
	// database; the tool call is in internal/emisar; the cards are in
	// internal/slackui.
	// 23285 for wiring parallel investigation. The 307-line orchestration went
	// to internal/branching rather than here, which is what the extraction rule
	// asks for; what is left is the four call sites that cannot live anywhere
	// else — the hook after a lead's result is applied, the branch's own Coop
	// fork at prepare time, the branch's terminal that never posts, and the
	// operation filter that stops a branch completing the episode. The package
	// was at its cap to the line, so this feature could not have been added
	// inside it at all, which is the ratchet doing what it is for.
	// Raised to 23480 on 2026-08-15 for migration phase 5, once for the phase
	// rather than once per commit. Section 25's phase 5 makes an incident room
	// an optional presentation artefact, and the work that buys is host work by
	// construction: an approval whose transport rows have expired resolving its
	// destination from the episode's bound (channel, thread) instead of from a
	// Slack input and a delivery that no longer exist; a completed governed
	// mutation finishing without the card it was waiting on rather than
	// re-queueing itself once a second forever; a publication naming the episode
	// that produced it; a thread-scoped episode binding a Coop session to its
	// destination rather than to a room's root message.
	//
	// The payment is booked, not deferred: the Emisar approval ROW left for
	// internal/store/approvalstore in the same session and took eight methods
	// and 317 lines out of internal/store, and both of that package's budgets
	// came down. This package's own extraction is still owed, and the candidate
	// has not changed since the paragraph above named it — the offline
	// evaluation family behind the decision domain.
	//
	// LOWERED to 22770 on 2026-08-15 when `/responder` became the emergency
	// kit. 753 lines came out — the incident directory and its paging, the
	// commitment, memory, preference, rule and schedule readers, the turn-limit
	// writer and its blocked-work resume, the slash lifecycle controls and
	// their receipt, the slash feedback path, and the conversation_command
	// branches that gave every one of them a second spelling. The package
	// measured 23345 against the entry above and measures 22592 now; the
	// remeasure is what sets this number, not arithmetic on the old one.
	//
	// Most of the deletion is locked in and about a quarter comes back as
	// margin, the same trade the action-proposal deletion made above: the
	// record buttons and the typed operations that replace what was removed
	// still have to land, and a ratchet that re-arms at zero fails the next
	// change on the merits of this one. `assignments` did NOT go with the rest
	// — slash is that feature's only creation surface until `offer_assignment`
	// exists — so its reader is still counted here.
	//
	// Raised to 23050 on 2026-08-15 for offer_assignment, which is the last of
	// "the typed operations that replace what was removed" the paragraph above
	// reserved margin for — and the margin was already spent by the four that
	// landed first, so the package measured 22,770 to the line, which is the
	// tripwire this file warns about rather than a ratchet. What it buys is 110
	// lines of confirmation wiring: post the card, re-authorize the click,
	// re-read the recorded offer, re-normalize it, create the shadowed row.
	//
	// It stays in internal/service for the reason knowledge_offer.go does. Every
	// line of it needs the store, the Slack client, the config's operator list
	// and the clock at once, and the decisions it makes — what a bound means,
	// what a stale confirmation is — are already extracted into
	// internal/assignments, which is where they are tested. The extraction this
	// package still owes is the offline evaluation family, unchanged.
	//
	// 154 lines of margin, deliberately thin: this package should be shrinking,
	// and the same note on internal/store calls 161 on 11,000 "a small margin".
	//
	// Raised to 23230 on 2026-08-16 for the context layer that tells a turn what
	// its own channel has already opened, plus the two anchors recall now asks
	// the store with. The cost being bought back is measured: on 2026-08-13 an
	// investigation produced an engineering task that was completed and
	// committed as f804b18c in a fork and then parked unpublished, and on
	// 2026-08-16 five investigations of the same alert proposed writing that
	// change again at roughly $15 each, because nothing carried an OPEN task
	// into a later turn — recall projects finished episodes only, and a parked
	// task has not finished. related_tasks.go is 90 of the lines and is a whole
	// layer: the load, the projection, its policy text, its manifest
	// references, and the commit-id parse that makes "already written, sitting
	// in a fork" a field rather than a sentence the model has to notice.
	//
	// It stays in internal/service because every part of it needs the store
	// handle, the clock and the effort gate at once, and because it is budgeted
	// beside the recalled-episode layer it borrows its framing from — a package
	// away, the two sections' drop order would live in neither of them. The
	// seventy-three lines of margin are thinner than the note above wants;
	// the extraction this package still owes is unchanged.
	//
	// And 23314 the same day for the alert stream being one episode. Eighty-four
	// lines against the previous entry, measured: the host's own bounded wait that
	// keeps an answered but still-firing stream open, the one-wait-per-stream
	// guard that stops seven cards leaving seven timers behind, and reading the
	// correction budget from what the episode spent rather than which attempt it
	// is on. Those are the five episodes the note above priced at $15 each,
	// bought back — and two investigations dropped mid-flight the same day, 22
	// minutes and 50 tool calls, are the other half of the same bill.
	//
	// And 23523 the same day for the other half of that stream: it stayed one
	// episode and still posted five times. 209 lines, measured, for two
	// questions nobody was asking — has the decision changed since the last
	// reply on this stream, and is the task this reply wants to offer already on
	// offer. The bill is the same seven cards in ninety minutes: five replies
	// into one thread restating one unchanged assessment, two of them saying
	// only that a node had crossed back over the same line, and six identical
	// engineering offers, none accepted.
	//
	// The extraction came first this time, which is why the number is 209 rather
	// than nearer four hundred. What a reply DECIDES, how two of those compare,
	// what changed between them and the prompt section that tells a model what
	// it already said are all in internal/alertstream, which reaches nothing —
	// no store, no Slack, no clock — so a suppression is reproducible from two
	// results and a diff. The three reads behind it are in
	// internal/store/alertstreamstore, reached as store.AlertStream rather than
	// as three more methods on Store. What is left here is what cannot leave:
	// five host-side questions that need the store handle, the config and the
	// clock at once, and the six call sites that ask them.
	//
	// And 23537 the same day, fourteen lines, for the ladder having a top. Coop
	// publishes the session's current target and never the policy's list of
	// them, so the escalation floor was repeats-1 with no ceiling:
	// run_532f8d62871320dc9d0696cb334d3503 asked for rungs 10, 11 and 12 in
	// three consecutive rounds of a thirteen-round correction loop and Coop
	// refused each one, at a refused submit and an audit line per round. Nine of
	// the fourteen are reading the remembered refusal beside the floor and the
	// audit sentence that says why the same model is answering again; the other
	// five are paid for by the caller, which now takes the sentence rather than
	// composing it from a rung. It stays in internal/service because it is the
	// same file as the submission that learns the refusal.
	//
	// And 23566 on 2026-08-16 for the recovery hold, twenty-nine lines. The
	// stream episode closed the moment a reply said the alert had cleared, so a
	// re-fire thirteen minutes later — va1-nomad-oom-risk cleared 19:11Z, fired
	// again 19:24Z — opened a new episode with a fresh briefing, an empty
	// ledger and no sight of the offer the last one had already made. A stream
	// that was live now holds its episode open for one more window; a stream
	// that never was still closes on its recovery, which is the read that costs
	// most of these lines.
	//
	// 23608 the same day, forty-two lines, so a card the stream has already
	// answered costs no model turn. A1 stopped a newer card destroying the
	// investigation in flight and the flap comparator stopped its answer being
	// posted twice, but the turn was still spent — leased, briefed, submitted,
	// answered, and only then compared and suppressed, six times over on the
	// 2026-08-16 va1-nomad-oom-risk stream. The host decides it alone only from
	// what a card states about itself, its own firing and resolved counts, and
	// most of these lines are the three conditions that keep it from suppressing
	// real news.
	//
	// And 23581 the same day, forty-four lines, measured, for the offer check
	// seeing the channel rather than one episode. The sixth identical Traefik
	// offer came from the 15:00 whole-platform review in another thread — a
	// different episode, so the check that had just shipped could not see it,
	// and the operator was handed the same button a sixth time. Same split as
	// the paragraph above and the same reason the remainder is here: whether two
	// titles name one fix is in internal/alertstream and the channel-wide read is
	// in internal/store/alertstreamstore, so what this package pays for is the
	// fallback that asks the second question only when the first found nothing,
	// the openness rules both answers share, and the window — which needs the
	// config and the clock together, and is the same one that decides a card
	// continues an episode. 23652 measured against the merged tree rather than
	// the 23581 it measured alone, because the recovery hold and the fold landed
	// beside it.
	//
	// And 23600 on 2026-08-16 for the prompt archive, which is 63 lines and
	// almost all of them a list. context_manifest_texts was growing ~131 MB/week
	// on blitz — ~560 MB at the 30-day episode horizon, 426 of 428 prompts
	// unique so deduplication had nothing to work with — and most of every row
	// was the host's own instruction block, stored a hundred and forty times a
	// day. The mechanics went to internal/promptarchive, which is handed a
	// prompt and a dictionary and knows nothing else. What is left here is the
	// dictionary itself: thirty-odd lines naming the blocks this package
	// assembles, and it cannot leave, because half of them are unexported
	// constants of this package and the other half are only known to be IN a
	// prompt by the code that puts them there.
	//
	// And 23780 on 2026-08-16, forty-six lines measured, for the attachment that
	// used to end a turn. A teammate reported a payments problem in a watched
	// channel with a screenshot whose bytes were not the image/png it declared;
	// the download refused it, the refusal was one error for the whole message,
	// and both callers turned that into a failed run that posted nothing at all.
	// The words were answerable without the picture. Nearly all of these lines
	// are the difference between an error and a note: the rejection type, the
	// per-file continue where a return used to be, and the prompt section that
	// tells the model what was dropped and to say so.
	//
	// And 23990 on 2026-08-16, measured at 23897, for two changes and a warning.
	//
	// The merge state on a related engineering task: the layer had been parsing a
	// commit id out of a task's own prose and offering to publish it without ever
	// asking where that commit was, and at 21:09Z an alert investigation ended
	// blocked on "Publish and roll f804b18c through the governed reviewed
	// deployment workflow" three days after the same change reached blitz-infra
	// main as 08f8b671. What was missing was the rollout. Fifteen of its lines are
	// the policy text naming what to recommend for each state and saying that
	// merged is not deployed; the rest are two bounded git reads of the checkout
	// the repository context already points at, and the guards that make every
	// unreadable case answer unknown instead of guessing.
	//
	// And the refusals a model or an operator reads when the host drops
	// something, which now name the field, the value and what was expected —
	// longer than "invalid" was. The vocabulary itself went OUT, to
	// internal/offerreason, because the words and the classification of a stale
	// button are pure text; what stayed is the wiring, one record for a discarded
	// offer instead of four log blocks.
	//
	// The warning is the number. Three changes landed in this package on one day,
	// each measured against a tree without the other two, and all three
	// independently picked 23900 — which the combined tree then met with three
	// lines to spare. That is the tripwire this file describes four paragraphs
	// down, reached by arithmetic rather than by anyone deciding it. 23990
	// restores a 93-line margin. The next thing to land here extracts instead:
	// the offer preparation and confirmation handlers are the cohesive area, and
	// internal/offerreason is already the half of them that left.
	//
	// LOWERED to 23650 on 2026-08-17, which is that extraction rather than the
	// raise the paragraph above warned about. 438 lines went to
	// internal/behavioroffer: what a preference, a standing rule and a memory
	// offer must say before the host will store one, the phrasings that decide
	// whether an offer was invited at all, and the payload its confirmation
	// button carries. internal/scheduleoffer had already been split that way and
	// these are its three siblings; they stayed here only because each validator
	// reached the configuration for a team id and a repository list, and that is
	// now a two-method Catalog the caller hands over.
	//
	// What could not leave is the shape this map keeps asking for. The four scope
	// gates still read the operator list, rejectedOffers still resolves a
	// channel's effective repository through the store before it validates a
	// rule, and the discard record still needs the logger and the run. That is
	// thirty lines of caller against four hundred of decision — and the decision
	// is now answerable from an offer and a list of repository names, with no
	// database behind it, which is what makes a refusal the model reads
	// reproducible a week later.
	//
	// The number is measured against the tree that will exist, not against the
	// branch that produced it — which is the mistake the paragraph above is a
	// record of. This extraction measures 23456 on its own; the conversation
	// lane's offer correction landed beside it, and the two together measure
	// 23502, which is the count this 23650 is set from. The margin is 148, and it
	// is not room for a feature: three same-day raises met the old number by
	// arithmetic, and a ratchet that re-arms at zero fails the next honest change
	// on the merits of this one.
	//
	// Raised to 23664 on 2026-08-23 for closing a task when its PR merges. The
	// margin above was spent first and this is what did not fit afterwards, so
	// judge it on its own: fourteen lines, all of them seam. The sweep that
	// decides which tasks are done lives in internal/taskpublication beside the
	// publication recovery it is a sibling of; what stayed is one adapter that
	// turns "this task is delivered" into closeIncident, because releasing the
	// fork on the retention grace, the audit record, the timeline entry and the
	// notice in the thread are one sequence this package owns and a second copy
	// of it is exactly what the map exists to prevent.
	//
	// This is the raise the paragraph above warns about, and it is one raise for
	// one feature rather than three meeting a number by arithmetic. The margin is
	// now zero, which means the next change here extracts. The offer preparation
	// and confirmation handlers are still the cohesive area named two paragraphs
	// up, and they have not moved.
	"service": 23664,
	// Down from 14100 across six extractions. It has only ever moved down except
	// twice, both times because a new store operation landed rather than an
	// existing one moving: rate-limit requeueing, and now per-attempt token
	// usage. Keep lowering it as more areas land.
	//
	// Raised from 11000 to 11200 for the usage columns and
	// RecordAttemptTokenUsage. The count had reached exactly 11000 — the cap, to
	// the line — so the budget had stopped being a ratchet and become the
	// tripwire this file warns about four paragraphs up: every addition to the
	// package failed, whatever its merit. Restoring a small margin is what that
	// warning asks for.
	//
	// The margin is 161 lines, not the 5% the newer entries carry, because this
	// package should still be shrinking. What it actually needs is the schema
	// out: baselineSchema and the schemaVN constants are around 1,300 lines of
	// DDL text carrying no logic, and moving them would return more than every
	// raise so far has taken. That was not done here because rewriting the
	// migration machinery while shipping a migration is how the 9934-row
	// deletion happened, and one of those risks at a time is enough.
	//
	// Raised again for the two queries that read the channel control plane:
	// which channels an operator configured, and which of those the bot is not
	// in. Four copies of the same channel-ID scan loop collapsed into one
	// helper in the same change, so the net cost of both queries is fourteen
	// lines.
	//
	// Raised from 11200 to 11400 on 2026-08-09 to give this package a retention
	// policy at all. Two things landed together: migration 51, which deletes the
	// 5,483 per-second waiting events sitting in the deployed databases, and the
	// episode-history sweep in lifecycle.go, which is the first code anywhere
	// that expires work_episodes and the eight tables that cascade from it.
	// Before it, 22 MB of a 32 MB database was governed by no policy at all and
	// grew forever; the budget is a guard against drift, and an unbounded table
	// is a worse kind of growth than the lines that bound it.
	//
	// Still not the extraction this note has asked for twice. Both of those
	// changes are migrations and deletions against live data, and the paragraph
	// above says why moving the migration machinery in the same breath as a
	// migration is the one thing not to do here.
	//
	// Lowered to 11390 on 2026-08-09 for RetireActionProposals and the proposal
	// prune, which maintained rows for a feature the config validator forbids,
	// then set to 11400 when migration 54 dropped that feature's two tables.
	// The migration file and the dropped-table line in the migration check cost
	// 16 of the 33 lines the deletion returned; 11390 would have left 25 lines
	// of margin, which the note at the top of this map calls a tripwire rather
	// than a ratchet. The package still ends 17 lines smaller and its budget 20
	// lower than either was before.
	// Publication follow-up queries and lifecycle events moved to their own
	// repository. Lock most of that reduction into the ratchet while keeping
	// enough room for the one-time card repaint migration that accompanies it.
	// Raised to 11340 on 2026-08-12 for retained input artifact bodies: the
	// storage logic lives in store/artifactstore, but the schema migration,
	// the repository wiring, and the retention hook are irreducibly this
	// package's, and fourteen lines of them landed over a four-line margin.
	// Raised to 11342 on 2026-08-13 for ReleaseAgentRunRevision. A run that
	// lost a Coop revision race replayed the same frozen revision until its
	// attempts ran out, failing each time for the reason the previous attempt
	// had; unfreezing it is a store concern and nowhere else can do it. Paid
	// for first: the reset the three requeue paths spelled out column by
	// column is now one shared clause, which is where four of the eleven new
	// lines came from.
	// Raised to 11353 on 2026-08-13 for SlackChannelName. A cross-channel
	// permalink is parsed, authorized and fetched, and the model then has to be
	// told which room the transcript came from — an id says "elsewhere" and not
	// where, and the prompt asks it to cite the channel by name. The name lives
	// in this package's membership roster and nowhere else. The obvious payment
	// is the forty-four copies of scan-one-row-tolerate-no-rows in here, but
	// that is a refactor with its own risk and should not ride along on a
	// feature.
	// Raised to 11382 on 2026-08-13 for the agent_activity migration: what the
	// model did inside a turn, so a trace can name the operations behind a
	// conclusion instead of reporting forty seconds and a verdict. The reading
	// and writing went to internal/store/activitystore, which is the split the
	// budget is asking for; what remains here is the v71 DDL and four lines
	// attaching the repository, and schema definition cannot leave the package
	// that owns migrations.
	// Raised to 11397 on 2026-08-13 for HoldOffAgentRunPoll, the one statement
	// that stops a failing poll retrying at full speed. Fifteen lines, and it
	// belongs beside the other agent_runs state transitions: what makes it
	// correct is that it leaves state and failure_count alone, which is only
	// checkable next to the paths that do change them.
	// Raised to 11399 on 2026-08-13 for work_episodes.last_activity_at: the
	// v72 DDL and the one line that scans it. Two lines, and by the same
	// argument as the entry above them — schema definition cannot leave the
	// package that owns migrations, and a column's scan cannot leave the
	// function that reads the row. The card bump this column arrived with did
	// leave, to taskcardstore, which already owns card_version.
	// Raised to 11404 on 2026-08-13 for the overdue sweep's activity cutoff:
	// the second bound, the WHERE clause that applies it, and the formatted
	// timestamp. Five lines, and a WHERE clause cannot leave the package that
	// owns the query. Deciding it in Go instead would cost the same lines in
	// internal/service and load every long-running turn the sweep exists to
	// ignore — into a LIMIT ordered by the deadline they are all past, where
	// they would crowd out the episodes that really did stop.
	// Raised to 11420 on 2026-08-14 for the open diff and what it amounts to:
	// the v73 migration and its comment, two columns on the incident read
	// path, the FinishSlackDelivery branch that records the ts a diff landed
	// at, and the two writers that clear it and set the stat. The ts is only
	// knowable where the delivery completes and the column is only readable
	// where incidents are scanned, so neither half can live anywhere else.
	//
	// Raised to 11425 on 2026-08-14 for the one statement that releases an
	// attempt's frozen context manifest when a requeue is about to rebuild its
	// prompt. Without it context_manifests.submitted_prompt held the FIRST
	// prompt of every corrected turn while agent_runs.result_json held the
	// SECOND turn's answer, so the prompt that produced a broken production
	// result was on disk nowhere — and that pairing is what the eval fixture
	// pipeline harvests. Four lines, and they cannot leave this package: the
	// clear has to land in the same transaction as the requeue it belongs to,
	// or a crash between the two leaves an attempt that will record a prompt
	// it never sent. The extraction the notes above keep asking for is still
	// what brings this number down.
	//
	// Raised to 11440 on 2026-08-14 for the weekly self report's repository.
	// Three lines: the import, the field, and the line in attachRepositories.
	// Every query it owns went to internal/store/selfreportstore, which is the
	// split these notes keep asking for; a delegating method here would have
	// cost the same three lines and a slot in the method budget as well.
	//
	// Raised to 11470 on 2026-08-15 for the lease fairness clause and the four
	// test hooks that shape its scenario. A run cycling lease->fail->retry held
	// its channel's serialization lock for three hours while a sibling with an
	// operator waiting sat runnable behind it; the clause lets an hour-old
	// blocker with three failures stop excluding its channel. The hooks exist
	// because the scenario needs a run aged, failed, and marked running without
	// threading test clocks through the lease path itself.
	//
	// Raised to 11500 on 2026-08-14 for fixturepromotionstore's attachment:
	// the sub-repository field and its wiring in attachRepositories — five
	// lines landing beside the fairness raise measured on a different branch.
	//
	// Raised to 11520 on 2026-08-15 for the fairness clause reading a slow
	// correction loop: two lines of COALESCE, because json_extract on a key
	// that omitempty leaves absent returns NULL, and NULL through the NOT
	// EXISTS would have stopped every old healthy blocker from serializing
	// its channel — the literal spec was the bug, and the fourth scenario
	// pins the fix.
	//
	// Raised to 11540 on 2026-08-15 for grantstore's attachment beside the
	// remediation ladder: the sub-repository field and its wiring, four
	// lines, with the ladder itself in its own budgeted package.
	//
	// Lowered to 11320 the same day when standing assignments left for
	// standingassignmentstore. The package had reached its cap to the line
	// twice that day, so the shadow ledger could not have been added here at
	// all — which is the ratchet doing exactly what it is for.
	//
	// 11323 after the retry-identity landing crossed the assignment
	// extraction's lowered number; 11340 keeps the same thin margin.
	//
	// 11365 for the fourth serializer of parallel investigation. Two SQL
	// changes and a repository field: the agent-run lease stops consulting the
	// incident's active turn for a branch, because that column describes the
	// lead's Coop session and a branch runs in a fork of its own; and restart
	// recovery stops handing a branch the incident's session for the same
	// reason. The reads that go with them are in fanoutstore, not here.
	//
	// Lowered to 11050 on 2026-08-15 when the Emisar approval row left for
	// store/approvalstore. The package had reached its cap to the line for the
	// third time in two days, and phase 5 was about to ask it for an episode
	// column and an episode-scoped query in the same change — so the extraction
	// happened first and the number came down with it rather than up.
	//
	// 11160 the same day for escalation-on-correction: two writes and the
	// transactional read-modify-write they share, which edits a run's context
	// envelope as raw fields so that every key this layer has never heard of
	// survives. Ninety-six lines, all of them the reason these are SQL rather
	// than a decode beside the correction — the caller's copy of the envelope is
	// stale by the time an escalation is decided, and re-encoding it would drop
	// the correction counter that bounds the loop.
	//
	// 11226 on 2026-08-15 for the episode review ledger: one upsert, the
	// terminal-state refusal it shares with the reducer, and the transaction
	// that reads the fingerprint the review is filed against. Sixty-six lines,
	// most of them the upsert's column list, and measured rather than rounded
	// up — the note at the top of this map calls a budget set exactly at
	// today's count a tripwire, and that is what this one is meant to be. The
	// reads live in internal/webui, which is where the queue is served from.
	//
	// 11260 on 2026-08-16 for the ladder rung a context manifest was submitted
	// at: one column, its scan in the manifest readers, and the reset write for
	// the escalation ledger. Thirty-one lines, measured. Every one of them is
	// what lets a retry that moved up the model ladder be briefed again instead
	// of leaning on a briefing the new model never read; two envelope rounds on
	// 2026-08-16 were that model learning a schema the previous rung had been
	// taught.
	//
	// And one more the same day, `85: migrationddl.V85`. The migration recovers
	// the alert identity every Slack-delivered Grafana outcome was written
	// without; the DDL and the reasoning live in migrationddl, and the query
	// that reads those rows lives in intelligencestore, so this package pays
	// for the registration and nothing else. That is the shape this budget is
	// meant to encourage.
	//
	// And 11307 the same day for the two alert-stream reads named in
	// methodBudget above and the narrowing of the finalization lease, which now
	// hands an episode to a newer attempt only when the older one has no answer
	// to deliver. Forty-nine lines, measured. The lease change is three of them
	// and the rest is the two queries; the guard it replaces was the fourth
	// place a newer Grafana card destroyed a finished investigation.
	//
	// And 11310, three lines, for store.AlertStream — an import, a field and its
	// construction. The three reads behind that field are in
	// internal/store/alertstreamstore: what this stream's last reply decided,
	// whether the engineering task it offered was ever accepted, and whether the
	// message carrying that offer's button actually reached Slack. Nothing on
	// Store, no method budget spent, and the whole feature costs this package
	// the three lines it takes to reach it. That is the shape the paragraph
	// above asks for, priced.
	//
	// And 11325 the same day for the ladder's top: the refused rung is now part
	// of the same write that drops the floor Coop would not honour. Fifteen
	// lines, measured — the extra parameter, its validation, and the lowest-wins
	// merge that keeps a later refusal at a higher rung from raising a ceiling
	// already learned. No new method: SetAgentRunTargetFloor was generalized
	// from "the rung this run may not go below" to "where this run stands on the
	// ladder", because a refusal is one decision and two writes could half-apply
	// — leaving the dropped floor without the reason, which is the exact state
	// this ceiling exists to prevent.
	"store":      11325,
	"localstate": 400,
	"provider":   120,
	// branching opens the branches a fan-out was granted and closes them. It is
	// separate from fanout because fanout must stay unable to reach a database
	// — a gate that exists to refuse spending needs refusals testable without
	// one — and separate from service because service was at its cap. Every
	// rule in it is about one distinction: what a branch may do that a lead may
	// not, and the reverse.
	"branching": 380,
	// fanoutstore reads the shape of a fan-out back: the branch children of a
	// lead, and what the investigation has spent. A package rather than three
	// more methods on Store for the reason goalstore is one.
	"fanoutstore": 100,
	// Raised from 400 to 460 on 2026-08-14 for recalling past episodes into
	// triage. A new package was the obvious move and is the wrong one: the
	// scorer has to use the same stopword list and three-character rule the
	// memory ranking already uses, and a second copy of a tokenizer is a second
	// place for a projection written on Monday to drift out of scoring range of
	// a query built on Tuesday. Sharing searchTerms is the whole reason this
	// belongs here.
	"recall": 460,
	// channelsetup reads which wizard control an operator clicked.
	//
	// Lowered from 235 to 90 on 2026-08-15 with the keyword router. The table
	// that rewrote plain operator messages into slash subcommands was 70 of
	// this package's 155 lines and the largest thing in it; what is left is
	// action-id decoding and one addressed sentence. A budget left at 235 would
	// have re-admitted the router without anything failing, which is the whole
	// job of this number.
	"channelsetup": 90,
	// memory owns what may be remembered, for how long, and who may see it.
	"memory": 364,
	// schedule owns recurrence arithmetic and schedule validation.
	"schedule": 291,
	// publication tracks a published PR through checks, merge and deployment.
	"publication": 392,
	// publicationcontext recognizes trusted references to active PR work.
	"publicationcontext": 155,
	// publicationrecord defines and decodes the durable proof required by each state.
	"publicationrecord": 95,
	// publicationreview interprets one Coop readiness dossier for publication.
	"publicationreview": 245,
	// publicationfollowupstore owns post-publication status and lifecycle events.
	"publicationfollowupstore": 395,
	// publicationrecoverystore owns restart reconciliation for publication attempts.
	"publicationrecoverystore": 120,
	// publicationstore owns the complete publication-row lifecycle: reads,
	// validated writes, staleness, attempt claims, duplicate coalescing, and
	// atomic publication/close exclusion. Keeping both claim directions here is
	// what prevents a close and a publication from starting concurrently; the
	// independent receipt decoder and restart recovery live elsewhere.
	"publicationstore":  575,
	"pausecleanupstore": 70,
	// fixturepromotionstore holds the receipts the automatic promotion drain
	// writes: whether a kept correction reached the corpus, whether it was held
	// back, and how many reached it inside the week. They are audit rows because
	// every automatic act here has to be auditable anyway, and two records of
	// one event can disagree.
	"fixturepromotionstore": 110,
	"promptbudget":          60,
	// promptscope answers which conditional instruction blocks a turn carries.
	// It came out of watch.go on 2026-08-15 rather than going into agentprompt,
	// which had nineteen lines of headroom: the predicates are a cohesive area
	// and this file says to split one rather than raise a budget for it. They
	// are pure functions of a sender type and a Slack message, which is what
	// lets their table be a list of real corpus strings and no Service at all.
	"promptscope": 145,
	// operationalscope owns the typed boundary around an alert conclusion, its
	// evidence-backed exhaustive check, and the host rendering. Extracting it
	// keeps both the broad decision and investigation packages below their
	// ratchets while leaving one cohesive policy rather than wrappers and types
	// split across them. 338 measured; 375 keeps ordinary edit margin.
	"operationalscope":     375,
	"repositorycapability": 105,
	// decision owns the shapes a model result arrives in and the rules for
	// reading one, so the evaluation family can reach them without the runtime.
	//
	// Raised from 2161 to 2300 for two rules that had to stop being prose: how
	// long a reply may be for the message it answers, and whether it may end on
	// a caveat. They live here rather than in the service because the offline
	// evaluation harness has to check the same bound the runtime enforces, and
	// because a phrase list that only the runtime can see is how the
	// conversation-location matcher went two months missing "answer in thread".
	//
	// Raised from 2300 to 2450 on 2026-08-09 for ReplyJudgement, which is that
	// last sentence coming true. The bound and the closing rule shipped here so
	// the evaluation harness could reach them, and then the quality judge went
	// on scoring length by eye anyway — it had no way to ask. The judgement
	// packages the three facts a judge needs (words against bound, the closing
	// phrase, thread against channel) out of functions that already existed, so
	// the two bars are one bar by construction.
	//
	// The package was sitting at exactly 2300, which the note at the top of this
	// map calls a tripwire rather than a ratchet: every addition fails whatever
	// its merit, and the pressure to bump is highest when the change is right.
	// 2450 is the fifty-two lines this needed plus room to be wrong once.
	//
	// Lowered to 2440 on 2026-08-09 when the proposals target came out of the
	// result-operation fold.
	// 2441 after the consumer landing declared the escalation envelope keys
	// (DisallowUnknownFields makes undeclared keys a poll-killer, so the two
	// fields had to live here); 2470 keeps a real margin.
	//
	// Raised to 2620 on 2026-08-15 for root cause by default, and this is the
	// entry to read sceptically: 115 lines, on a package that stood at its cap to
	// the line, which is the tripwire this file warns about and not a ratchet.
	//
	// What it buys is the rule that an unexplained failure in scope means the
	// episode is not done. On 2026-08-11 the 12:16 Zot triage
	// (episode_run_ebbee0227d72743cc4aee48ef01113ba) closed decision_ready with
	// verdict succeeded on a Terraform Run-Applied event while its own reply said
	// VA1 pyke "did not deploy: its rollout missed the progress deadline and
	// automatically rolled back". Every contract passed, because the failure the
	// turn had found was prose. Three human nudges and 88 minutes later a deep
	// dive found the root cause in four.
	//
	// The extraction this file asks for was considered and refused, on this
	// file's own grounds. The finding's SHAPE did leave — the payload, its status
	// set, its validator and its prompt bullet are in internal/investigation
	// beside the contract they belong to. What stayed is three corrections that
	// read a WatchDecision and a WatchTurnState field, and they stayed because a
	// package holding them would hold three function signatures and no decision:
	// "moving lines between packages without moving a decision" is what the note
	// on the service entry calls the way a budget stops measuring anything. They
	// also have to be read beside WatchDecisionCorrection and
	// AlertAssessmentCorrection, which fire in the same chain on the same shapes,
	// and internal/replypolicy's entry below records what splitting one rule
	// across packages cost the last time: "answer in thread" went two months
	// unmeasured.
	//
	// 2585 measured; 2620 is 35 lines of margin, deliberately more than the 13
	// and 14 the entries below settled for, because those are the numbers that
	// made this a tripwire.
	//
	// Raised to 2700 on 2026-08-16 for two more rules in the same chain, on the
	// same reasoning: they read a WatchDecision and nothing else, and a package
	// holding them would hold two signatures and no decision. The cost that
	// bought them is one alert. VA1 traefik memory saturated its cap, the
	// investigation recorded finding-1 "explained" and named evidence-impact-growth
	// as ruling out a pure in-process leak, and that observation's own last
	// sentence is "a leak component on top of the load-driven growth is not
	// excluded". The assessment's cause went out bounded, the completion closed
	// decision_ready with a material gap saying the split was unresolved, and the
	// operator read "Memory tracks load ... raise the cap and roll the job". The
	// same alert had been diagnosed three days earlier and the same follow-up
	// written down and never done.
	//
	// 2659 measured; 2700 keeps the 40-odd lines of margin that made this entry
	// a tripwire rather than a ratchet.
	//
	// 2790 on 2026-08-16 for the two ways an unexplained finding was unanswerable.
	// One is a matcher: carried findings are keyed on their own text, so a
	// finding the model RECLASSIFIED under new words was still judged by the
	// old copy — run_532f8d62871320dc9d0696cb334d3503 was told thirteen times
	// over twenty-three minutes to explain a finding it had already marked
	// out_of_scope with a reason. The other is an exit: a finding whose
	// discriminating check exists but is unavailable had nowhere honest to
	// rest, and two corpus cases failed on exactly that. Both belong here
	// because both are what the host will accept from a result, which is this
	// package's whole subject; the eighty-four lines are the matcher, its
	// word-overlap scoring, and the not_checkable clause.
	//
	// 3020 on 2026-08-16 for the other half of the carry: a correction round now
	// returns only the records it is changing, and partial_round.go is what puts
	// the rest back. It belongs beside CarryEvidence and sameFinding because it
	// has to agree with them exactly — restore keyed on the text where the carry
	// keys on sameFinding put the unexplained copy of a finding back beside the
	// round that had just reclassified it, which is the twelve-round loop the
	// entry above describes, reinstated by its own fix. A package holding it
	// would hold one function and half a decision.
	//
	// The cost that bought it is measured rather than argued.
	// episode_run_956b7644b6fbef89b17aa3a9c6df8da8 ran sixteen turns for $8.84,
	// and 116,385 of its 233,398 result bytes — 56.8% of everything its
	// correction rounds emitted — were record_evidence, record_coverage and
	// record_finding operations the host was already carrying in the run's own
	// context envelope. 2978 measured; 3020 keeps the 40-odd lines of margin the
	// entries above are written to.
	"decision": 3020,
	// investigation owns the contract and, since the completion validators moved
	// beside it, the rules that check a result against that contract.
	//
	// Raised to 1880 on 2026-08-15 for the open-goal completion check. The
	// kernel refuses to complete an episode over a required goal that is still
	// planned; asked only at finalization, the refusal was a store error nobody
	// relayed and a sound answer retried finalization forty times over three
	// hours. The same invariant asked at staging is a correction the model can
	// act on, and it belongs beside the other completion validators.
	//
	// Raised to 1890 the same day for offer_runbook_draft and offer_kb_card:
	// two payload fields, two entries in the exactly-one-payload list, two
	// validator entries and two prompt bullets. Thirteen lines, and the reason
	// it is only thirteen is that neither validator is here — both delegate to
	// internal/knowledgeoffer, so the rule a model reads in a correction is
	// literally the rule the operator's confirmation click is measured against.
	// Two copies of a slug pattern would have been an offer accepted at result
	// time and refused at confirm time for a reason nobody was ever told.
	//
	// Raised to 1970 on 2026-08-15 for supersession, crossing the raise above.
	// Since 79445e8 the contradiction correction has told the model to
	// "supersede the losing statement with a record observed AFTER the record
	// it retires" and the ledger had no rule implementing it — `grep supersed
	// ledger.go` matched the correction string and nothing else. The live model
	// obeyed exactly, in the only place the vocabulary allowed, by opening two
	// observations with "Supersedes evidence-change-repo."; the host re-read
	// both retired records back as live conflicts every round until the
	// episode's budget was gone. What landed here is the rule (a retirement is
	// explicit, typed and named, never inferred from order), the refusals it
	// will not honour, and the operation validator for the shapes one operation
	// can judge alone. 44 of the 108 lines were paid for by deleting
	// firstObservation, which lost its last caller when 79445e8 replaced it
	// with quotedStatements.
	//
	// Raised to 2010 on 2026-08-15 for request_record, the operation by which
	// asking for a handoff in words reaches the same renderer the card's Record
	// menu reaches. Twelve lines: the kind list, the payload, its slot in the
	// exactly-one-payload rule, a validator that quotes the four kinds back at
	// an unrecognised one, and a prompt bullet. The entry above stood at the
	// measurement of the change that set it, which is the tripwire the note at
	// the top of this map describes: this landed two lines over a number that
	// had no margin at all, so the raise restores one.
	//
	// Raised to 2030 on 2026-08-15 for the two rules the completion validators
	// had been holding separately. Whether a bounded unknown may sit under a
	// decision_ready verdict was answered one way by the envelope check and
	// another by the correction loop; whether an unknown coverage row answers a
	// required claim was answered one way for a claim with supporting evidence
	// and another for the same claim without it. Both are now one named
	// predicate the two callers ask, at 2017 measured — the second rule cost
	// more in the comment that says why operational_health is not on its list
	// than in the switch, which is the right ratio for a rule whose last
	// version was two lists nobody could see at once.
	//
	// Raised to 2080 the same day for the unknown-field answer. 79445e8 sent no
	// schema with a parse error on the reasoning that "an unknown field has no
	// schema by definition"; true of the field, false of the answer, and blitz
	// run_a162e8457a76089aa94ea5264cc1e61c paid for the difference with five
	// correction rounds in two minutes guessing the name of a recurrence —
	// frequency, schedule_type, cadence, schedule, daily — each round throwing
	// the whole envelope away to hand back the name of the guess. 49 lines
	// measured at 2066: the name-to-operation table, the offer_schedule
	// fragment nothing had yet, and the sentence that tells an unmapped field
	// it exists nowhere. The table is the expensive half and it is data, so the
	// next recorded guess is one line rather than a function.
	//
	// Raised to 2190 on 2026-08-15 for record_finding, the operation that makes a
	// discovered failure machine-readable at all. 87 lines: the payload and its
	// alternatives, the four-value status set, the validator, its slot in the
	// exactly-one-payload rule, a prompt bullet and a schema fragment.
	//
	// The validator is the expensive half and it is the half worth having. Each
	// of its rules closes one way a finding could be recorded while saying less
	// than the prose it replaces — explained with no evidence id, expected with
	// no reason, an alternative listed with neither the evidence that rules it
	// out nor a word about why nothing can. That last one is the whole
	// adversarial-residue check: the deep prompt tells the model to attack its
	// own conclusion, prompts drift, and the only thing a host can verify is what
	// came back.
	//
	// The status set is quoted back verbatim on rejection for the reason the
	// assignment change classes are: the worst correction loop on record, 6.6
	// repeats on one episode, was a model asked to choose from a list it could
	// not see. 2153 measured; 2190 keeps a real margin rather than the 13 the
	// entry above settled for.
	"investigation": 2190,
	// These packages own policy and data transformations that used to sit in
	// the broad service, store, decision, and investigation packages. Register
	// every extraction here so moving code cannot evade the architecture ratchet.
	"agentcontext": 200,
	// fanout owns whether an investigation has earned parallel branches, and the
	// identities that stop the queue from serializing the branches it grants.
	// Every decision in it is a pure function over the claims ledger, which is
	// deliberate: the gate exists to refuse spending, and a gate that needs a
	// database and a Coop session to test is a gate whose refusals go untested.
	"fanout": 385,
	// agentprompt kept the turn-conduct policies and the prompt assembly; the
	// Slack reply-shape prose moved beside its measured enforcement in
	// replypolicy on 2026-08-12, and the budget follows the lines down.
	"agentprompt": 280,
	// evaluation replays recorded and live corpora through the same prompt and
	// decision paths the runtime uses, and gates releases on the result. It sits
	// above service the way app does: it may import service, and nothing imports
	// it back.
	"evaluation": 4050,
	// wakeuppolicy guards recorded wakeup identities and the lifetime of exact
	// Terraform wait chains. Keeping it below service prevents persistence-backed
	// lifecycle correction from consuming the service package's remaining budget.
	"wakeuppolicy": 140,
	// 130 on 2026-08-16, from 100. The cause-binding rule is unchanged and its
	// branches are the same three; what grew is what each one says. Naming the
	// offending evidence id, the claim it actually carries, and the ids the
	// model may choose from instead costs about forty lines here, against eight
	// correction rounds in one day — five of them after that day's deploys —
	// that the generic sentence bought at 6,000 to 20,000 output tokens each.
	// There is no sub-package to extract: this is one function's vocabulary.
	//
	// 150 on 2026-08-16, from 130, measured at 134. The two diagnosis
	// corrections moved here from internal/decision so they can name what they
	// saw: "the active issue has no actionable cause boundary" and "no fresh
	// verification plan" were the whole message, and a model that had just
	// written cause_status: bounded could not tell which of the two fields the
	// host was reading. They belong beside the cause-binding rule above for the
	// same reason its branches belong together — one vocabulary, one voice, and
	// a correction that quotes a field is only safe if it bounds it the same
	// way its neighbour does.
	"evidencepolicy": 150,
	"episode":        350,
	// offerreason owns the words the host owes when it refuses an offer or a
	// confirmation button. 145 on 2026-08-16, measured at 131 — a new package
	// rather than a corner of internal/service, because every function in it is
	// pure text and the whole vocabulary has to be readable in one sitting to
	// stay consistent. It is also what pays for the service raise above.
	"offerreason":           145,
	"investigationcontract": 550,
	// replypolicy owns what a Slack reply must look like. Since 2026-08-12 both
	// halves of the rule live here — the instruction text every lane carries and
	// the measured bound the host enforces — because a rule split across
	// packages is how "answer in thread" went two months unmeasured.
	"replypolicy": 270,
	// selfreport composes the weekly digest, and selfreportstore counts it.
	// They are two packages rather than one because the counting needs the
	// database and the wording needs nothing at all: the wording is where the
	// interesting mistakes are, and a test for it should not have to migrate a
	// schema to run.
	"selfreport":        260,
	"selfreportstore":   275,
	"replaycontrol":     75,
	"replayinterrupt":   95,
	"replaycancelstore": 90,
	// preparationstore owns the one durable blocker-to-retirement epoch. It is
	// below service and store so an accepted model turn and the removal intent
	// can share a transaction without teaching either broad package the state
	// machine for pending, sending and uncertain Slack posts.
	"preparationstore": 280,
	// preparationnotice translates one typed workspace-preparation state into
	// its bounded Slack text and durable post/retirement intent.
	"preparationnotice": 160,
	// deliveryretrystore owns the transactional question behind every failed
	// Slack write: retry it, fail it, or supersede it because a newer coalesced
	// intent became authoritative while the request was in flight.
	"deliveryretrystore": 160,
	"serviceport":        65,
	"retrydelay":         40,
	"schemaassets":       1050,
	// Raised from 50 to 70 on 2026-08-16, eleven lines measured. A failure now
	// asks a second question before it chooses silence — did this message say
	// Ryker's name, whatever kind of event Slack called it — because a
	// payments report that typed "@Emisar" produced no app_mention, read as room
	// chatter, and was audited failed_silent with nothing posted. Both halves of
	// the rule live here so there is one place to read what earns an answer.
	"triageoutcome": 70,
	// turndelta is the lease-time predicate for a follow-up turn: may this
	// attempt speak into the session that already holds its briefing, or must it
	// restate one. 135 today. It is deliberately a pile of veto clauses over a
	// pure input, so it grows by one clause when a new doubt is found, not by
	// gaining the ability to look one up.
	"turndelta": 160,
	// hermeticgit is the git-subprocess discipline internal/publisher grew
	// around the only GitHub push credential Ryker has, extracted the day
	// it gained a second caller. It should stay this size: a second copy of an
	// environment scrub is a second place for one of its rules to stop
	// applying, and that is the whole reason it is a package.
	"hermeticgit": 110,
	// repomirror owns every Ryker-managed clone: where a slug becomes a
	// directory, what a fetch failure means, and when a clone is too old to be
	// called current. It is a package rather than a corner of the service
	// because none of that needs a database, a Slack client or a Coop session,
	// and its tests run against real git against local fixtures.
	"repomirror": 520,
	// changeledger owns what counts as a change, how an ingested one is made
	// safe to store, and which recorded changes a turn is shown. It is a
	// package because three unrelated adapters — a webhook route, the
	// publication follower and the Emisar approval watcher — have to agree on
	// the answer, and a second copy of "is this kind valid" is a second place
	// for one of them to start recording something the prompt has no words for.
	"changeledger": 380,
	// changestore owns the change_events table. Its insert is a free function
	// over an exec handle as well as a repository method, because a publication
	// lifecycle transition and the change event it implies have to be one
	// transaction.
	"changestore": 175,
	// remediation owns the trust ladder: which exact Emisar action may be
	// offered for which exact alert, what a rung costs, and what takes one away.
	// It is a package rather than a corner of the service for the reason
	// authority decisions in particular deserve — every function here is pure
	// over values, so the questions that matter ("can this offer widen a grant",
	// "does a denied run demote") are answered by table tests with no database,
	// no Slack client and no model. Keep it that way: anything here that needs
	// to read a row belongs in grantstore, and anything that needs to render
	// belongs in slackui.
	"remediation": 400,
	// knowledgeoffer decides what a verified remediation may become, and it
	// decides it from values alone: the offer's shape, whether the episode
	// verified anything, and whether the action it names is one the host
	// recorded running. The Emisar runbook-definition builder is here for the
	// same reason the promotion arithmetic is in remediation — a payload that
	// will be executed by somebody else's control plane deserves a table test,
	// not an integration test.
	"knowledgeoffer": 420,
	// behavioroffer owns what a preference, a standing rule or a memory offer
	// must say before the host will store one, and what the confirmation button
	// that offer becomes may carry. Extracted from internal/service on
	// 2026-08-17, where the three validators had stayed because each reached the
	// configuration for a team id and a repository list; that arrives as a
	// two-method Catalog now, so a refusal is reproducible from an offer and a
	// list of repository names rather than from a running deployment.
	//
	// 560 against 528 measured, and 528 against the 438 that left internal/service
	// — the difference is the seam, and it is worth naming. A Context, a Catalog,
	// an Envelope shared by the three payloads and six encode and decode
	// entrances are all lines the service never had to write down, because it had
	// the whole of Service to reach through instead.
	"behavioroffer": 560,
	// slackfile owns what Ryker will accept as a Slack file, what it will
	// call one, and how much of one it will read. Extracted whole from
	// internal/service on 2026-08-15; every rule in it is a refusal about bytes
	// somebody else controls, and none of them ever needed the coordinator.
	"slackfile": 230,
	// grantstore owns the remediation_grants table and the one query a promotion
	// is graded on. It decides nothing — see the package comment.
	"grantstore": 210,
	// assignments owns what a standing assignment means — the bounds an offer
	// must name, the normalized grant an operator confirms, the brief an
	// unattended task works from, the verdict its gate produced. None of it
	// needs a database, a Slack client or a Coop session, and all of it is the
	// part worth testing; internal/service keeps only the wiring.
	//
	// Raised to 440 on 2026-08-15 for offer_assignment. It is a net addition of
	// 74 lines against a retired `key=value` parser it replaced, and the trade
	// is the point: the parser turned an operator's typing into a row, and this
	// turns a model's proposal into the grant a card shows and a click stores.
	// The same size as knowledgeoffer, and for the same reason — a payload
	// somebody will later trust enough to act on deserves table tests, not an
	// integration test.
	"assignments": 440,
	// standingassignmentstore owns scoped authority to open a pull request
	// without a per-action click: the grant, the claim that spends its budget,
	// and the ledger of what the gate decided about each signal. It came out of
	// internal/store, which was at its cap to the line.
	"standingassignmentstore": 470,
	// approvalstore owns the emisar_approvals row: what governed mutation was
	// requested, for which work, and what Emisar finally said about the run. It
	// came out of internal/store on 2026-08-15, which was again at its cap to
	// the line, and which phase 5 was about to ask for a new column and a new
	// query at once.
	"approvalstore": 350,
}

// forbiddenImports records the dependency direction. Each package maps to the
// internal packages it must never import, keeping the layering acyclic and
// stopping the domain and persistence layers from depending on presentation.
var forbiddenImports = map[string][]string{
	"core":               {"config", "coop", "emisar", "publisher", "service", "slackui", "store", "webhook", "httpapi", "app"},
	"store":              {"service", "slackui", "publisher", "httpapi", "app", "emisar"},
	"slackui":            {"service", "store", "httpapi", "app", "publisher"},
	"coop":               {"service", "store", "slackui", "httpapi", "app"},
	"replaycontrol":      {"service", "store", "slackui", "httpapi", "app"},
	"replayinterrupt":    {"service", "store", "slackui", "httpapi", "app"},
	"replaycancelstore":  {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "emisar"},
	"preparationstore":   {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "emisar", "config", "decision"},
	"preparationnotice":  {"service", "store", "httpapi", "app", "publisher", "emisar", "config", "decision"},
	"deliveryretrystore": {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "emisar", "config", "decision"},
	"serviceport":        {"service", "store", "httpapi", "app"},
	"emisar":             {"service", "store", "slackui", "httpapi", "app"},
	"webhook":            {"service", "store", "slackui", "httpapi", "app"},
	"episode":            {"service", "store", "slackui", "httpapi", "app"},
	"wakeuppolicy":       {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "emisar", "config", "decision", "evaluation"},
	"pausecleanupstore":  {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "emisar"},
	// The receipts are rows. Which correction deserves promoting, what a fixture
	// is, and where the corpus lives are decisions that belong to the caller —
	// this package must never learn how to build one, or the drain and the
	// promote-fixtures command would have two answers.
	"fixturepromotionstore": {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "emisar", "config", "evaluation"},
	"promptbudget":          {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "emisar", "config", "decision", "core"},
	// promptarchive is handed a prompt and a list of instruction texts and
	// returns the copy that outlives the turn. It must stay unable to look
	// anything up: the caller owns which blocks exist, and a package that could
	// reach the service or the store would be one that decides for itself what
	// counts as an instruction — which is how an archive starts deleting the
	// conversation. It imports nothing outside the standard library today, and
	// this is the list that keeps it a function of its arguments.
	"promptarchive": {
		"service", "store", "slackui", "httpapi", "app", "publisher", "coop",
		"emisar", "config", "decision", "investigation", "core", "webui",
	},
	// promptscope reads a sender type and a message and returns which blocks
	// apply. It takes decision for the alert vocabulary the host corrections
	// already use — the block and the correction that enforces it must agree on
	// what an alert is — and replypolicy for the two reply policies it chooses
	// between. Nothing else: a predicate that could reach the store or the
	// config is a predicate whose answer depends on where it ran.
	"promptscope":           {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "emisar", "config", "investigation"},
	"operationalscope":      {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "emisar", "config", "decision", "investigation", "evaluation"},
	"repositorycapability":  {"service", "store", "slackui", "httpapi", "app", "publisher", "emisar", "decision", "investigation"},
	"investigation":         {"service", "store", "slackui", "httpapi", "app"},
	"investigationcontract": {"service", "store", "slackui", "httpapi", "app", "decision", "investigation"},
	// assignments is imported BY internal/investigation, which is what this
	// entry is protecting. offer_assignment's operation validator is
	// assignments.ValidateOffer, so the rule a model reads in a correction is
	// the rule the operator's confirmation click is measured against — and the
	// price of that is that everything this package can reach, the operation
	// contract can reach too.
	//
	// slackui and decision are the two it lost to get here. The card lived in
	// this package until 2026-08-15 and the eligibility struct was a parameter
	// on Evaluation; the first would have put Slack rendering behind the
	// contract, and the second was an outright import cycle, because decision
	// reaches investigation through the evidence policy. Neither may come back:
	// Result carries values for the caller to render, and Evaluation takes the
	// gate's bool and string.
	"assignments": {
		"service", "slackui", "httpapi", "app", "publisher", "coop", "emisar",
		"decision", "investigation", "evaluation",
	},
	"decision": {"service", "store", "httpapi", "app", "publisher", "coop"},
	// alertstream answers "has this stream's decision changed since the last
	// time we said something". It takes a decision and returns what that
	// decision decides, and it must stay unable to reach anything that would
	// make a suppression depend on where it ran: no store, no Slack, no config
	// and no clock. A reply Ryker did not send is exactly the kind of thing
	// an operator asks about a day later, and the answer has to be reproducible
	// from the two results alone.
	"alertstream": {
		"service", "store", "slackui", "httpapi", "app", "publisher", "coop",
		"emisar", "config", "webhook", "evaluation",
	},
	"evaluation":   {"httpapi", "app", "webhook"},
	"agentcontext": {"service", "store", "httpapi", "app", "publisher", "coop", "config", "decision", "investigation"},
	// fanout answers "has this investigation earned a second turn running beside
	// the first". It reads the ledger and returns a decision; it starts nothing,
	// stores nothing, and posts nothing, and the direction is stated here so it
	// stays that way. A gate that could reach the store would be a gate whose
	// refusals are only reproducible against a database.
	"fanout": {
		"service", "store", "slackui", "httpapi", "app", "publisher", "coop",
		"emisar", "config", "webhook",
	},
	// branching may reach the store and Coop — opening a branch is a write and
	// a session — but never Slack or the service. A branch does not post, and
	// the whole reason it is a package is that "a branch never posts" is a rule
	// the compiler can hold rather than one the incident path has to remember.
	"branching": {"service", "slackui", "httpapi", "app", "publisher", "webui"},
	// audition counts what already happened and returns a report. It reads a
	// database handle it was given and never opens one, and it must stay unable
	// to promote, route or demote anything: the whole design of this report is
	// that a person reads it and decides. A package that could reach the store
	// or the service is one turn away from being asked to act on its own
	// findings, which is the autopilot this deliberately is not.
	"audition":       {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "emisar", "webui"},
	"agentprompt":    {"service", "store", "slackui", "httpapi", "app", "publisher", "config"},
	"evidencepolicy": {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config", "decision"},
	// offerreason is text and nothing else. It may reach core for the bounding
	// helpers and no further: a refusal that had to load something would be a
	// refusal that can fail, which is how the silence it replaces started.
	"offerreason": {
		"service", "store", "slackui", "httpapi", "app", "publisher", "coop",
		"emisar", "config", "decision", "investigation", "schedule", "memory",
	},
	// behavioroffer is the other half of offerreason: that package owns the
	// words a refusal uses, this one owns the checks that produce them. config
	// is on this list beside the usual outward-facing packages, and it is the
	// entry that matters. The two questions this package asks of a deployment's
	// repositories arrive as a Catalog; the moment it could read a config
	// itself, a refusal would stop being reproducible from the offer that caused
	// it, and reproducing those is the whole reason the vocabulary was split out
	// in the first place. It reaches decision, memory and schedule for the same
	// reason internal/scheduleoffer does — the rule a model is corrected against
	// has to be the rule its confirmation click is measured by.
	"behavioroffer": {
		"service", "store", "slackui", "httpapi", "app", "publisher", "coop",
		"emisar", "config", "webhook", "evaluation", "investigation",
	},
	"replypolicy": {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config", "decision", "investigation"},
	// The digest reads the database and writes into Slack, so the direction has
	// to be stated or it will drift back into one package that does both. The
	// composer knows nothing about either: give it a counted week and it
	// returns Markdown, which is what lets its tests be a table of strings.
	"selfreport":      {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "emisar", "config", "decision", "investigation"},
	"selfreportstore": {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "emisar", "config", "decision", "investigation"},
	"retrydelay":      {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config", "decision", "investigation"},
	"schemaassets":    {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config", "decision", "investigation", "core"},
	"triageoutcome":   {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config", "investigation"},
	// turndelta decides whether a follow-up may lean on the briefing already in
	// its Coop session. It must stay unable to look anything up: the decision is
	// only trustworthy if every fact it used was handed to it, because the one
	// way it can do harm is by answering "delta" about a session it guessed at.
	// It imports nothing but strings today, and this is the list that keeps it
	// that way.
	"turndelta": {
		"service", "store", "slackui", "httpapi", "app", "publisher", "coop",
		"emisar", "config", "decision", "investigation", "core",
	},
	"publication":              {"service", "httpapi", "app", "coop", "decision"},
	"publicationcontext":       {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config", "decision"},
	"publicationrecord":        {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config", "decision"},
	"publicationreview":        {"service", "store", "slackui", "httpapi", "app", "publisher", "decision"},
	"publicationfollowupstore": {"service", "slackui", "httpapi", "app", "publisher", "coop", "config", "decision"},
	"publicationrecoverystore": {"service", "slackui", "httpapi", "app", "publisher", "coop", "config", "decision"},
	"publicationstore":         {"service", "slackui", "httpapi", "app", "publisher", "coop", "config"},
	"schedule":                 {"service", "store", "httpapi", "app", "coop", "publisher", "slackui"},
	"memory":                   {"service", "httpapi", "app", "coop", "publisher", "slackui"},
	"channelsetup":             {"service", "store", "httpapi", "app", "coop", "publisher"},
	"publisher":                {"service", "store", "slackui", "httpapi", "app"},
	// hermeticgit knows about git and nothing else. It must not learn about
	// configuration either: the moment it can read a config it can grow a rule
	// about which repositories it will run for, and that rule belongs where the
	// paths are decided.
	"hermeticgit": {
		"service", "store", "slackui", "httpapi", "app", "publisher", "coop",
		"emisar", "config", "core", "decision", "investigation",
	},
	// repomirror may read configuration — a slug and a state directory come
	// from there and nowhere else — and must never reach the database, Slack,
	// Coop, or the publisher. It is below all of them.
	"repomirror": {
		"service", "store", "slackui", "httpapi", "app", "publisher", "coop",
		"emisar", "decision", "investigation",
	},
	"localstate": {"service", "store", "httpapi", "app", "publisher", "coop", "config"},
	"provider":   {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config", "core"},
	"recall":     {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config"},
	// changeledger sits below everything that ingests into it or reads it. It
	// must never reach the database: the store read it needs is one method, and
	// it takes that as an interface so the package stays testable without one.
	// config is excluded too — the window and the cap are handed to it by the
	// caller, because a domain package that can read configuration grows a rule
	// about which deployments it applies to.
	"changeledger": {
		"service", "store", "slackui", "httpapi", "app", "publisher", "coop",
		"emisar", "config", "webhook",
	},
	// changestore is a store repository and answers to the same direction as
	// its siblings.
	"changestore": {
		"service", "slackui", "httpapi", "app", "publisher", "coop", "emisar",
		"config", "decision",
	},
	// grantstore is a store repository and answers to the same direction as its
	// siblings.
	"grantstore": {
		"service", "slackui", "httpapi", "app", "publisher", "coop", "emisar",
		"config", "decision",
	},
	// approvalstore is a store repository and answers to the same direction as
	// its siblings.
	"approvalstore": {
		"service", "slackui", "httpapi", "app", "publisher", "coop", "emisar",
		"config", "decision",
	},
	// remediation decides what authority a grant carries, and it decides it from
	// values alone. The store is on this list beside the usual outward-facing
	// packages: the moment this one can read a row, the ladder stops being
	// answerable by a table test, which is the only reason it is a package.
	"remediation": {
		"service", "slackui", "httpapi", "app", "publisher", "coop", "emisar",
		"config", "decision", "store", "grantstore",
	},
}

// unboundSlackDeliveryBudget caps how many places may enqueue a Slack delivery
// without naming the episode it belongs to.
//
// The episode binding is only enforced where there is an episode to enforce it
// against. EnqueueSlackDelivery refuses a delivery whose channel, thread, or
// expected revision disagrees with the episode, and LeaseSlackDelivery
// supersedes a queued one when the binding moves under it — but both clauses
// begin at an episode id, so a delivery enqueued without one is checked by
// neither. It posts wherever its caller decided, including to a surface the
// episode has since left.
//
// That is migration phase 2's second exit criterion, "acknowledgement and
// subsequent work never split across surfaces accidentally", and it is failing
// in the shape the criterion names. The number is here rather than in prose
// because prose drifts: the design document said seven, the AST said eight, and
// the difference was a status delivery that is exempt on purpose.
//
// Status and reaction deliveries are excluded below, not counted and forgiven.
// They are exempt in the store for a reason that is written there — a native
// status belongs to the conversation the operator is looking at, not to the
// episode's bound destination — so counting them would make this number
// unreachable and therefore meaningless.
//
// Lower it as call sites gain an episode. Do not raise it.
const unboundSlackDeliveryBudget = 7

// enqueuesWithoutAnEpisode returns "file:line kind" for every EnqueueSlackDelivery
// call whose delivery literal names no EpisodeID, skipping the status and
// reaction operations the store exempts by design.
func enqueuesWithoutAnEpisode(t *testing.T) []string {
	t.Helper()
	var unbound []string
	for _, files := range goPackages(t) {
		for _, path := range files {
			fileSet := token.NewFileSet()
			parsed, err := parser.ParseFile(fileSet, path, nil, 0)
			if err != nil {
				t.Fatal(err)
			}
			ast.Inspect(parsed, func(node ast.Node) bool {
				call, ok := node.(*ast.CallExpr)
				if !ok {
					return true
				}
				selector, ok := call.Fun.(*ast.SelectorExpr)
				if !ok || selector.Sel.Name != "EnqueueSlackDelivery" || len(call.Args) < 2 {
					return true
				}
				literal, ok := call.Args[1].(*ast.CompositeLit)
				if !ok {
					return true
				}
				episode, operation, kind := false, "", ""
				for _, element := range literal.Elts {
					pair, ok := element.(*ast.KeyValueExpr)
					if !ok {
						continue
					}
					key, ok := pair.Key.(*ast.Ident)
					if !ok {
						continue
					}
					value := ""
					if basic, ok := pair.Value.(*ast.BasicLit); ok {
						value = strings.Trim(basic.Value, `"`)
					}
					switch key.Name {
					case "EpisodeID":
						episode = true
					case "Operation":
						operation = value
					case "Kind":
						kind = value
					}
				}
				if episode || operation == "status" || operation == "reaction" {
					return true
				}
				position := fileSet.Position(call.Pos())
				relative, err := filepath.Rel(repoRoot(t), position.Filename)
				if err != nil {
					relative = position.Filename
				}
				if kind == "" {
					kind = "?"
				}
				unbound = append(unbound, fmt.Sprintf("%s:%d %s", relative, position.Line, kind))
				return true
			})
		}
	}
	sort.Strings(unbound)
	return unbound
}

// A Slack delivery that names no episode escapes the destination binding.
//
// Counted rather than described. The episode-kernel migration's phase 2 is
// otherwise landed — the binding is stored, enforced at enqueue, and superseded
// at lease when it moves — and this is the hole left in it, so the honest
// measure of that phase is how many callers still post without saying whose work
// they are posting. A new one is a regression against an exit criterion, and
// would otherwise arrive looking like an ordinary delivery.
func TestASlackDeliveryWithoutAnEpisodeEscapesTheDestinationBinding(t *testing.T) {
	unbound := enqueuesWithoutAnEpisode(t)
	if len(unbound) > unboundSlackDeliveryBudget {
		t.Errorf(
			"%d Slack deliveries are enqueued with no episode, over the budget of %d:\n  %s\n"+
				"Pass the episode that owns the message, so the destination binding can "+
				"correct it when the episode moves.",
			len(unbound), unboundSlackDeliveryBudget, strings.Join(unbound, "\n  "),
		)
	}
	if len(unbound) < unboundSlackDeliveryBudget {
		t.Errorf(
			"only %d Slack deliveries are enqueued with no episode, under the budget of %d:\n  %s\n"+
				"Lower unboundSlackDeliveryBudget to %d in this commit; a budget above its own "+
				"count stops measuring the thing it was written for.",
			len(unbound), unboundSlackDeliveryBudget, strings.Join(unbound, "\n  "), len(unbound),
		)
	}
}

func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

// goPackages walks internal/ and returns each package's non-test files.
func goPackages(t *testing.T) map[string][]string {
	t.Helper()
	root := filepath.Join(repoRoot(t), "internal")
	packages := make(map[string][]string)
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		name := filepath.Base(filepath.Dir(path))
		packages[name] = append(packages[name], path)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return packages
}

func TestPackageDependencyDirection(t *testing.T) {
	packages := goPackages(t)
	for name, forbidden := range forbiddenImports {
		files, ok := packages[name]
		if !ok {
			t.Fatalf("package %q named in forbiddenImports no longer exists; update this test", name)
		}
		banned := make(map[string]bool, len(forbidden))
		for _, item := range forbidden {
			banned[item] = true
		}
		for _, path := range files {
			file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ImportsOnly)
			if err != nil {
				t.Fatal(err)
			}
			for _, spec := range file.Imports {
				value, err := strconv.Unquote(spec.Path.Value)
				if err != nil {
					t.Fatal(err)
				}
				if !strings.HasPrefix(value, modulePath+"internal/") {
					continue
				}
				imported := strings.TrimPrefix(value, modulePath+"internal/")
				if banned[imported] {
					t.Errorf(
						"%s imports internal/%s: %s must not depend on it",
						strings.TrimPrefix(path, repoRoot(t)+"/"), imported, name,
					)
				}
			}
		}
	}
}

func TestBroadTypeMethodBudget(t *testing.T) {
	packages := goPackages(t)
	counts := make(map[string]int)
	for _, files := range packages {
		for _, path := range files {
			file, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
			if err != nil {
				t.Fatal(err)
			}
			for _, decl := range file.Decls {
				fn, ok := decl.(*ast.FuncDecl)
				if !ok || fn.Recv == nil || len(fn.Recv.List) == 0 {
					continue
				}
				expr := fn.Recv.List[0].Type
				if star, isStar := expr.(*ast.StarExpr); isStar {
					expr = star.X
				}
				ident, isIdent := expr.(*ast.Ident)
				if !isIdent {
					continue
				}
				if _, tracked := methodBudget[ident.Name]; tracked && fn.Name.IsExported() {
					counts[ident.Name]++
				}
			}
		}
	}
	for name, budget := range methodBudget {
		count := counts[name]
		if count == 0 {
			t.Fatalf("type %q named in methodBudget was not found; update this test", name)
		}
		if count > budget {
			t.Errorf(
				"%s has %d methods, over its budget of %d.\n"+
					"Extract a cohesive area into its own type or package rather than raising this.",
				name, count, budget,
			)
		}
	}
}

// codeLines counts lines that carry code, skipping blanks and comments.
//
// The budget exists to stop a package absorbing responsibility, and comments
// are not responsibility. Counting them meant that naming and explaining an
// extracted phase — the exact change the budget is supposed to encourage —
// pushed the package toward its limit, which is backwards.
func codeLines(source string) int {
	count := 0
	inBlockComment := false
	for _, line := range strings.Split(source, "\n") {
		trimmed := strings.TrimSpace(line)
		switch {
		case inBlockComment:
			if strings.Contains(trimmed, "*/") {
				inBlockComment = false
			}
		case trimmed == "" || strings.HasPrefix(trimmed, "//"):
		case strings.HasPrefix(trimmed, "/*"):
			inBlockComment = !strings.Contains(trimmed, "*/")
		default:
			count++
		}
	}
	return count
}

func TestPackageLineBudget(t *testing.T) {
	packages := goPackages(t)
	for name, budget := range lineBudget {
		files, ok := packages[name]
		if !ok {
			t.Fatalf("package %q named in lineBudget no longer exists; update this test", name)
		}
		total := 0
		for _, path := range files {
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			total += codeLines(string(data))
		}
		if total > budget {
			t.Errorf(
				"package internal/%s has %d non-test lines, over its budget of %d.\n"+
					"Split a cohesive area into its own package rather than raising this.",
				name, total, budget,
			)
		}
	}
}

// stringSliceAllowlist names the few places a raw byte slice over a string is
// correct: fixed-width hex digests and identifiers whose alphabet is ASCII by
// construction. Everything else must go through core.TruncateUTF8.
var stringSliceAllowlist = map[string]bool{
	"internal/publisher/github.go":           true, // slug is ASCII by regex construction
	"internal/publicationcontext/context.go": true, // ASCII SHA prefixes and reference-token byte boundaries
	"internal/slackui/message.go":            true, // hex digest + ShortID over an ASCII id
	"internal/core/text.go":                  true, // the safe truncation helper itself
	"internal/coop/client.go":                true, // prompt elision walks rune boundaries itself
}

// Slicing a string on a byte boundary splits multi-byte runes, which reaches
// operators as a replacement character and corrupts anything that re-encodes
// the value as JSON. The whole codebase was cleaned of this once and it came
// back in new code, so it is now a build-time rule rather than a convention.
func TestNoRawStringSlicing(t *testing.T) {
	packages := goPackages(t)
	root := repoRoot(t)
	for _, files := range packages {
		for _, path := range files {
			relative := strings.TrimPrefix(path, root+"/")
			if stringSliceAllowlist[relative] {
				continue
			}
			fset := token.NewFileSet()
			file, err := parser.ParseFile(fset, path, nil, 0)
			if err != nil {
				t.Fatal(err)
			}
			info := stringTypedLocals(file)
			ast.Inspect(file, func(node ast.Node) bool {
				slice, ok := node.(*ast.SliceExpr)
				if !ok {
					return true
				}
				ident, isIdent := slice.X.(*ast.Ident)
				if !isIdent || !info[ident.Name] || !truncatingBound(slice) {
					return true
				}
				t.Errorf(
					"%s:%d: %s is a string sliced on a byte boundary; use core.TruncateUTF8 "+
						"(or add the file to stringSliceAllowlist with a reason)",
					relative, fset.Position(slice.Pos()).Line, ident.Name,
				)
				return true
			})
		}
	}
}

// truncatingBound reports whether a slice expression is a truncation — no low
// bound, and a high bound that is a size rather than an offset found inside the
// string. Slicing at a strings.Index result is rune-aligned and safe; slicing
// at a byte count is not.
func truncatingBound(slice *ast.SliceExpr) bool {
	if slice.Low != nil || slice.High == nil || slice.Slice3 {
		return false
	}
	var literal func(ast.Expr) bool
	literal = func(expr ast.Expr) bool {
		switch value := expr.(type) {
		case *ast.BasicLit:
			return value.Kind == token.INT
		case *ast.BinaryExpr:
			return literal(value.X) && literal(value.Y)
		case *ast.ParenExpr:
			return literal(value.X)
		case *ast.Ident:
			name := strings.ToLower(value.Name)
			return strings.HasPrefix(name, "max") || strings.HasPrefix(name, "limit") ||
				strings.HasSuffix(name, "bytes") || strings.HasSuffix(name, "limit") ||
				strings.HasSuffix(name, "max")
		}
		return false
	}
	return literal(slice.High)
}

// stringTypedLocals reports identifiers declared as string in this file, which
// is enough to catch the pattern without full type checking.
func stringTypedLocals(file *ast.File) map[string]bool {
	names := map[string]bool{}
	record := func(name string, typ ast.Expr) {
		if ident, ok := typ.(*ast.Ident); ok && ident.Name == "string" {
			names[name] = true
		}
	}
	ast.Inspect(file, func(node ast.Node) bool {
		switch decl := node.(type) {
		case *ast.ValueSpec:
			for _, name := range decl.Names {
				if decl.Type != nil {
					record(name.Name, decl.Type)
				}
			}
		case *ast.Field:
			for _, name := range decl.Names {
				record(name.Name, decl.Type)
			}
		case *ast.AssignStmt:
			for index, lhs := range decl.Lhs {
				ident, ok := lhs.(*ast.Ident)
				if !ok || index >= len(decl.Rhs) {
					continue
				}
				if literal, isLiteral := decl.Rhs[index].(*ast.BasicLit); isLiteral &&
					literal.Kind == token.STRING {
					names[ident.Name] = true
				}
				if call, isCall := decl.Rhs[index].(*ast.CallExpr); isCall {
					if fn, isSelector := call.Fun.(*ast.SelectorExpr); isSelector {
						if pkg, isPkg := fn.X.(*ast.Ident); isPkg && pkg.Name == "strings" {
							names[ident.Name] = true
						}
					}
				}
			}
		}
		return true
	})
	return names
}

// A shipped launch agent may not export a setting its script stopped reading.
//
// The quality watcher's plist was installed by hand and lived nowhere in the
// repository, so its only copy was the file under ~/Library/LaunchAgents. That
// copy drifted: it still exported RESPONDER_QUALITY_RESTART_LABELS long after
// scripts/quality-watch.sh stopped reading it, and an inert setting looks
// exactly like a working one. Now that the plist is versioned, the two can be
// compared — an exported RESPONDER_QUALITY_* key that the script never reads is
// either a typo or a rule that has quietly stopped applying.
func TestShippedLaunchAgentsOnlyExportSettingsTheScriptReads(t *testing.T) {
	root := repoRoot(t)
	script, err := os.ReadFile(filepath.Join(root, "scripts", "quality-watch.sh"))
	if err != nil {
		t.Fatal(err)
	}
	plist, err := os.ReadFile(filepath.Join(
		root, "deploy", "launchd", "ai.emisar.responder.quality-watch.plist",
	))
	if err != nil {
		t.Fatal(err)
	}
	// Only the keys, not the surrounding comment: the comment explains the
	// variable that was removed, and naming it there must stay allowed.
	body := string(plist)
	if start := strings.Index(body, "<key>EnvironmentVariables</key>"); start >= 0 {
		body = body[start:]
	}
	for _, line := range strings.Split(body, "\n") {
		name := strings.TrimSpace(line)
		if !strings.HasPrefix(name, "<key>RESPONDER_QUALITY_") {
			continue
		}
		name = strings.TrimSuffix(strings.TrimPrefix(name, "<key>"), "</key>")
		if !strings.Contains(string(script), name) {
			t.Errorf(
				"the quality-watch launch agent exports %s, which scripts/quality-watch.sh never reads",
				name,
			)
		}
	}
}
