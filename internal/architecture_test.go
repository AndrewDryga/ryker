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
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

const modulePath = "github.com/AndrewDryga/responder/"

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
	"Store": 229,
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
	// operator watched Responder post one person's mistyped setup answer to a
	// shared channel and said never to do that again; the audit that followed
	// found three more of the same shape. A colleague who is not an operator was
	// refused in public, once per message they sent. A request Responder gave up
	// on after twelve silent attempts put its raw error in front of the room and
	// told everyone to retry a command only one person could run. And the same
	// permission refusal was private through /responder and public through
	// @Emisar, so the spelling decided who watched.
	//
	// Fifty-three lines: three routing branches, one shared helper, one extracted
	// reportAbandonedInput, and the log call that keeps a failed ephemeral from
	// being the silence this file's previous entry was written to prevent. It
	// buys back rooms that were learning to tune Responder out, which costs more
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
	"service": 21820,
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
	"store":      11382,
	"localstate": 400,
	"provider":   120,
	"recall":     400,
	// channelsetup reads what an operator is asking for about a channel.
	"channelsetup": 235,
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
	"publicationstore":     575,
	"pausecleanupstore":    70,
	"promptbudget":         60,
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
	"decision": 2440,
	// investigation owns the contract and, since the completion validators moved
	// beside it, the rules that check a result against that contract.
	"investigation": 1800,
	// These packages own policy and data transformations that used to sit in
	// the broad service, store, decision, and investigation packages. Register
	// every extraction here so moving code cannot evade the architecture ratchet.
	"agentcontext": 200,
	// agentprompt kept the turn-conduct policies and the prompt assembly; the
	// Slack reply-shape prose moved beside its measured enforcement in
	// replypolicy on 2026-08-12, and the budget follows the lines down.
	"agentprompt": 280,
	// evaluation replays recorded and live corpora through the same prompt and
	// decision paths the runtime uses, and gates releases on the result. It sits
	// above service the way app does: it may import service, and nothing imports
	// it back.
	"evaluation":            4050,
	"evidencepolicy":        100,
	"episode":               350,
	"investigationcontract": 550,
	// replypolicy owns what a Slack reply must look like. Since 2026-08-12 both
	// halves of the rule live here — the instruction text every lane carries and
	// the measured bound the host enforces — because a rule split across
	// packages is how "answer in thread" went two months unmeasured.
	"replypolicy":       270,
	"replaycontrol":     75,
	"replayinterrupt":   95,
	"replaycancelstore": 90,
	"serviceport":       65,
	"retrydelay":        40,
	"schemaassets":      1050,
	"triageoutcome":     50,
}

// forbiddenImports records the dependency direction. Each package maps to the
// internal packages it must never import, keeping the layering acyclic and
// stopping the domain and persistence layers from depending on presentation.
var forbiddenImports = map[string][]string{
	"core":                     {"config", "coop", "emisar", "publisher", "service", "slackui", "store", "webhook", "httpapi", "app"},
	"store":                    {"service", "slackui", "publisher", "httpapi", "app", "emisar"},
	"slackui":                  {"service", "store", "httpapi", "app", "publisher"},
	"coop":                     {"service", "store", "slackui", "httpapi", "app"},
	"replaycontrol":            {"service", "store", "slackui", "httpapi", "app"},
	"replayinterrupt":          {"service", "store", "slackui", "httpapi", "app"},
	"replaycancelstore":        {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "emisar"},
	"serviceport":              {"service", "store", "httpapi", "app"},
	"emisar":                   {"service", "store", "slackui", "httpapi", "app"},
	"webhook":                  {"service", "store", "slackui", "httpapi", "app"},
	"episode":                  {"service", "store", "slackui", "httpapi", "app"},
	"pausecleanupstore":        {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "emisar"},
	"promptbudget":             {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "emisar", "config", "decision", "core"},
	"repositorycapability":     {"service", "store", "slackui", "httpapi", "app", "publisher", "emisar", "decision", "investigation"},
	"investigation":            {"service", "store", "slackui", "httpapi", "app"},
	"investigationcontract":    {"service", "store", "slackui", "httpapi", "app", "decision", "investigation"},
	"decision":                 {"service", "store", "httpapi", "app", "publisher", "coop"},
	"evaluation":               {"httpapi", "app", "webhook"},
	"agentcontext":             {"service", "store", "httpapi", "app", "publisher", "coop", "config", "decision", "investigation"},
	"agentprompt":              {"service", "store", "slackui", "httpapi", "app", "publisher", "config"},
	"evidencepolicy":           {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config", "decision"},
	"replypolicy":              {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config", "decision", "investigation"},
	"retrydelay":               {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config", "decision", "investigation"},
	"schemaassets":             {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config", "decision", "investigation", "core"},
	"triageoutcome":            {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config", "investigation"},
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
	"localstate":               {"service", "store", "httpapi", "app", "publisher", "coop", "config"},
	"provider":                 {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config", "core"},
	"recall":                   {"service", "store", "slackui", "httpapi", "app", "publisher", "coop", "config"},
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
