package service

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
)

func TestCoopInstructionsRequireClaimBasedCrossSourceEvidence(t *testing.T) {
	instructions := CoopInstructions("Keep the response concise.")
	for _, required := range []string{
		"Choose evidence sources by the claim being answered",
		"Use the checked-out repository for declared intent and expected topology",
		"Prefer Emisar MCP for current private infrastructure state",
		"Inspect and use other available MCP servers and tools",
		"Never equate or count runner records, hosts, VMs, nodes, allocations, containers, or services",
		"When sources disagree, do not silently pick one",
		"does not prove runner, fleet, workload, or infrastructure health",
		"only after an Emisar MCP tool call fails in the current turn",
		"Emisar is the only authority for operational actions",
		"directly and explicitly asks for the exact operational change",
		"A dedicated incident or task is not required",
		"If Emisar returns pending_approval, stop the turn",
		"Do not keep polling while a human decision is pending",
		"Responder monitors an exact pending run outside the model turn",
		"never call run_action or create a replacement run",
		"standard Markdown for Slack's Block Kit `markdown` block",
		"Default to natural, plain English",
		"Use common words, contractions",
		"Answer the user's actual question first",
		"one main idea per sentence",
		"Keep exact technical terms",
		// Simplified technical English is the default register now, not an
		// opt-in. The owner asked for it directly on 2026-08-14; the old pin
		// said the opposite ("strict controlled English is only for a user who
		// explicitly asks"), so it retired with the sentence it anchored.
		"the rhythm of simplified technical English",
		"Do not repeat repository or live-system checks",
		"schedule your own check",
		"Use humor like a trusted teammate",
		"never force a joke",
		"Stay straightforward during active incidents",
		"Most messages need none; use at most one",
		"Prefer a reaction over a written reply",
		"Personality may change phrasing, never facts",
		"Evidence, memory, incident and task titles",
		"fenced code blocks with a language",
		"task lists, dividers, tables",
		"Responder owns interactive controls",
	} {
		if !strings.Contains(instructions, required) {
			t.Fatalf("Coop instructions do not contain %q:\n%s", required, instructions)
		}
	}
	if strings.Contains(instructions, "call the Emisar MCP tools before using shell commands") {
		t.Fatalf("Coop instructions still impose the old fixed tool order:\n%s", instructions)
	}
}

// The policy text below must survive every edit to the prompt. Some of it is
// conditional now, so this builds the turn that enables everything — an
// operator's scheduled occurrence, whose prompt names an alert, asks for a
// chart, and carries two instructions — and asserts the wording is intact.
// TestPromptSectionsAppearOnlyWhenTheyApply and the three block tests beside it
// own the separate question of which blocks reach which turn.
func TestWatchPromptCarriesMandatoryCrossSourceEvidencePolicy(t *testing.T) {
	cfg := serviceConfig(t)
	prompt, _ := (&Service{cfg: cfg}).watchPrompt(
		core.SlackInput{
			ChannelID: "C123ABC",
			MessageTS: "1700.001",
			UserID:    cfg.Slack.Operators[0],
			Kind:      "scheduled",
			Text: "The checkout latency alert is still firing. Chart the p99 " +
				"for the last hour and tell me whether it recovered.",
		},
		"U999BOT",
		false,
		nil,
		nil,
		core.AgentMemory{},
		nil,
		nil,
		decisionpkg.OperationalMemoryContext{},
		nil,
		nil,
		"",
		nil,
		WatchPromptBudget(0),
	)
	for _, required := range []string{
		"Consider the full set of repository, MCP, and other tools available in the turn",
		"Use the checked-out repository for declared intent and expected topology",
		"Prefer Emisar MCP for current private infrastructure state",
		"Use the MCP tools directly, not curl against the MCP endpoint",
		// The policy said this twice; this pin was on the copy. Anchored to the
		// survivor so deleting the duplicate is not mistaken for losing the rule.
		"Treat runner-list results only as runner identities and connection state",
		// Also pinned on the deleted copy. Both rules were stated twice, and both
		// pins anchored the second statement rather than the first.
		"relevant configured tool merely because Emisar is available",
		"search Emisar find_actions",
		"list_packs with availability=all",
		"completion.capability_gaps recommendation",
		"without inventing one",
		"Reconcile declared topology with observed runtime entities",
		"Use the investigation contract's conclusion kind",
		"say Emisar is unavailable merely because a local CLI",
		"This evidence policy is mandatory for current operational questions",
		"standard Markdown for Slack's Block Kit `markdown` block",
		"Default to natural, plain English",
		"Use common words, contractions",
		// The soft version of this ("a simple explanation should usually be a few
		// sentences") let a nine-word question draw a 350-word answer, because the
		// only hard length bound lived in the alert-reply block. Pin the number.
		"a one-line question gets one to three sentences",
		"Translate evidence into meaning",
		"Use humor like a trusted teammate",
		"make light of customer impact",
		"When a user asks for a chart, image, or meme",
		"do not send unsolicited visual noise",
		"Creative images and memes",
		"task lists, dividers, tables",
		"outer JSON is only the transport envelope",
		"do not send them outside Slack",
		// The prepared-fix rule survives; only its transport changed. The
		// engineering offer is an offer_task operation now, so these pins moved
		// with it rather than being dropped — the rule they guard is that a
		// repository fix is offered here, with its repository and prompt, and
		// is not handed back to the operator to start.
		"offer_task with kind=engineering",
		"its exact repository",
		"inspect the most likely configured source repository",
		"even if the broader operational assessment remains blocked by that exact defect",
		"Do not merely describe the patch",
		"omit the task offer rather than guessing",
		// The 2026-08-14 behavior batch, one pin per behavior.
		"reply with the evidence and one question",
		"the team's own names for things",
		"repeatedly signaled the same working style",
		"Configured repository bindings",
		"target_is_configured_operator must be true",
		// The stuttered twin ("A dedicated incident is not required.") next to
		// this sentence was deleted on 2026-08-14; the rule survives here.
		"A dedicated incident or task is not required",
		"include the exact pending_approval object",
		"One confirmation atomically creates up to 8 tasks",
		"one offer per distinct",
		"occurrence in the same response",
		"never ask which goes first",
		"corrections replace older variants",
		"Create, inspect, validate, publish, and execute Emisar runbooks",
		"An Emisar runbook is control-plane data, not a repository artifact",
		"complete the runbook-management steps first",
		"preferred reproducible route rather than the requested outcome",
		"read-only semantic replacement or equivalent authorized checks",
		"do not replace the runbook action with an engineering task",
		"preferred named runbook or reusable workflow is unavailable",
		"missing reusable workflow is a maintenance gap",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("watch prompt does not contain %q:\n%s", required, prompt)
		}
	}
	if strings.Contains(prompt, "call the Emisar MCP tools before using shell commands") {
		t.Fatalf("watch prompt still imposes the old fixed tool order:\n%s", prompt)
	}
}

func TestConversationPromptReusesKnownResultForSimpleExplanation(t *testing.T) {
	prompt := conversationPrompt(
		"U123ABC",
		"Can you explain the fix in simple terms?",
		true,
	)
	for _, required := range []string{
		"answer from the existing conversation in natural plain language",
		"Do not rerun tools or repeat the investigation",
		"unless the user asks for a fresh check",
		"Default to natural, plain English",
		"Use common words, contractions",
		"Stay straightforward during active incidents",
		"Most messages need none; use at most one",
		// The incident room used to get plain language and humor and nothing
		// about how a Slack message is rendered, so twenty runs guessed. It
		// carries the whole reply contract now.
		"standard Markdown for Slack's Block Kit `markdown` block",
		"a one-line question gets one to three sentences",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("conversation prompt does not contain %q:\n%s", required, prompt)
		}
	}
	if !simpleExplanationRequest("Can you explain me the fix in simple terms?") {
		t.Fatal("simple explanation request was not recognized")
	}
	if simpleExplanationRequest("Please check whether the fix is live now.") {
		t.Fatal("fresh verification request was mistaken for a simple explanation")
	}
	if got := slackui.ProgressMilestones("is explaining the earlier answer..."); len(got) != 2 || got[0] != "Reading the earlier answer" ||
		got[1] != "Writing a simpler explanation" {
		t.Fatalf("explanation progress = %v", got)
	}
}

func TestBoundedConversationUsesTheSameHumanVoicePolicy(t *testing.T) {
	prompt := (&Service{}).conversationPrompt(
		core.SlackInput{
			ChannelID: "C123ABC", MessageTS: "1700.001",
			UserID: "U123ABC", Text: "Did the formatting check finally pass?",
		},
		"U999BOT", false, nil, core.AgentMemory{}, nil, nil, decisionpkg.OperationalMemoryContext{}, "repo",
	)
	for _, required := range []string{
		"not a report generator, policy engine, or technical manual",
		"Use common words, contractions",
		"Do not force headings or bullets onto a short answer",
		"the rhythm of simplified technical English",
		"Use humor like a trusted teammate",
		"Use emoji like a teammate, not decoration",
		"Prefer a reaction over a written reply",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("bounded conversation prompt lacks %q:\n%s", required, prompt)
		}
	}
	// This prompt told the model to write mrkdwn in the same breath as the
	// formatting policy told it to write Markdown, and the delivery path — a
	// Block Kit `markdown` block, see slackui.Message.Blocks — renders the
	// second. Only one of them can be in here.
	if strings.Contains(prompt, "mrkdwn") {
		t.Fatalf("the bounded conversation prompt still asks for mrkdwn:\n%s", prompt)
	}
	if !strings.Contains(prompt, "standard Markdown for Slack's Block Kit `markdown` block") {
		t.Fatalf("the bounded conversation prompt lost the real format contract:\n%s", prompt)
	}
}

func TestProgressCopyUsesPlainOperatorLanguage(t *testing.T) {
	for _, progress := range append(slackui.WatchProgressSteps(), slackui.ProgressMilestones("investigating")...) {
		for _, jargon := range []string{"topology", "reconciling", "entities", "coverage"} {
			if strings.Contains(strings.ToLower(progress), jargon) {
				t.Fatalf("progress %q contains internal term %q", progress, jargon)
			}
		}
	}
	if got := slackui.ProgressMilestones("reviewing change"); len(got) != 4 || got[0] != "Reading the code changes" || got[3] != "Writing the review" {
		t.Fatalf("review progress = %v", got)
	}
}

func TestRepositorySetPromptExplainsPinnedReadOnlyCompanions(t *testing.T) {
	session := coop.Session{
		BaseCommit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		Companions: []coop.CompanionRepository{{
			Name:       "control-plane",
			Path:       "/coop/repositories/control-plane",
			BaseCommit: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		}, {
			Name:       "undocumented",
			Path:       "/coop/repositories/undocumented",
			BaseCommit: "cccccccccccccccccccccccccccccccccccccccc",
		}},
	}
	prompt := repositorySetPrompt(session, map[string]string{
		"control-plane": "Scheduler and runner control plane.",
	})
	for _, required := range []string{
		"Primary working copy",
		"only repository whose changes can be reviewed or published",
		"Read-only companion `control-plane`",
		"`/coop/repositories/control-plane`",
		"pinned at `bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`",
		"Scheduler and runner control plane.",
		"Reconcile across repositories",
		"never try to edit them",
		// A repository nobody has described has to say so. Silence reads as
		// "there is nothing here", and the map's only route to being filled in
		// is an agent noticing the hole while it already has the snapshot.
		"No description is recorded for `undocumented`",
		"record_repository_contents",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("repository-set prompt lacks %q:\n%s", required, prompt)
		}
	}
	// A fully described set must not carry the prompt to describe anything.
	described := repositorySetPrompt(session, map[string]string{
		"control-plane": "Scheduler and runner control plane.",
		"undocumented":  "Ad delivery service.",
	})
	if strings.Contains(described, "No description is recorded") {
		t.Fatalf("described repository set still asks for descriptions:\n%s", described)
	}
}

func TestEngineeringTaskPromptAllowsOnlyForkScopedRepositoryWork(t *testing.T) {
	task := core.Incident{
		ID: "inc_task", Route: "manual", SourceIncidentID: "task:EvTask",
		Repository: "emisar", Title: "Audit infrastructure packs",
		Status: core.IncidentActive,
	}
	prompt, err := initialPrompt("Use evidence.", task, nil, "", true)
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{
		`"kind":"engineering_task"`,
		"Complete this workspace-member-confirmed engineering task",
		"make the smallest justified repository changes",
		"Repository code and repository-owned configuration changes are allowed",
		"does not provide shared operational MCP tools or environment secrets",
		"Do not apply configuration, merge, push, deploy, sign, mutate live systems",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("engineering prompt lacks %q:\n%s", required, prompt)
		}
	}
}

// staticWatchPromptBytes is the size of the instruction block on an ordinary
// operator turn: a scheduled occurrence asking one plain question.
//
// It used to be the largest the static prompt gets, and it is not any more. As
// of 2026-08-15 three blocks are keyed on the target's text rather than on the
// lane, so "How is the health of our infrastructure?" no longer carries the
// alert-language, generated-visual or compound-request rules. The turn that
// still carries all three is measured by promptCeilings["watch-operator-alert"]
// in prompt_size_test.go; this one measures what a normal turn costs.
//
// It is pinned because the number is a budget, not a curiosity. The transport
// caps a prompt at coop.MaxPromptBytes and elides the middle of anything over,
// which cuts through the structured context. Every byte of instruction is a
// byte of conversation the model does not get to see, and instructions grow by
// accretion: nobody adds a paragraph believing it is the one that pushes a
// real thread out of the window.
//
// Measured in production on 2026-08-07: assembled prompts ran a median 3.2 KiB
// over the cap across 89 truncations in a day. Freeing 4 KiB of instruction
// would have prevented 91% of them; 8 KiB, all of them.
// Raised by 6 on 2026-08-09 to teach the feedback contract the word
// "positive". Its vocabulary was negative, suggestion and mixed, so the model
// had no way to record that an answer was right — nine days of traffic left
// the feedback table empty at zero rows, and every example of the target
// behaviour had to be inferred from complaints that never came. Nine bytes for
// the new value, three back from rewording the sibling field.
// Raised by 45 on 2026-08-09 because the operation list was lying. It said
// offer_memory, offer_preference, offer_rule and offer_schedule "carry the
// same named typed payload that their operation name describes", which reads
// as preference, rule and schedule — and every other operation in the list
// really does work that way. A model followed it and the host rejected the
// whole response with unknown field "preference". The host now also accepts
// those three names, but tolerance cannot rescue offer_memory: "memory" is
// already update_memory's payload, so the only fix for that one is to stop
// implying it. The line now names each key instead of describing it.
// Raised by a further 168 on 2026-08-09 to spell out the four offer payloads'
// fields. Naming the keys was not enough: memory_offer, preference_offer,
// rule_offer and schedule_offer were the only payloads in the list whose
// fields were never shown, and three consecutive real regression runs each
// invented a different name for one of them — topic, then event, then
// guidance. Each invention cost the whole response. The host accepts all three
// as aliases now, but a fourth was always coming, and a payload the model has
// never seen the shape of is the reason. These are the bytes that stop it.
//
// Lowered by 43 on 2026-08-09 when propose_action left the operation list. The
// host had no code left to act on a proposal — it dropped every one the model
// emitted — so the operation was 26 bytes of instruction per turn asking for
// output that went nowhere, plus the words in the surrounding sentence that
// carried it. Nothing replaced it in the prompt: the refusal that explains
// where an operational request goes instead lives in the validator, where it
// costs bytes only on the turn that needs it.
//
// Raised by 165 on 2026-08-10 for the expires_in vocabulary, because "never"
// exists now and a value the model has never been told about is a value it
// cannot offer. The prompt had never listed the durations at all — the model
// learned them only by guessing one, being rejected, and reading the error —
// and that worked while every legal answer was a number of days it could infer.
// It stopped working the moment an operator said "I don't want a deadline, do
// it forever": the honest reply was that permanence was unavailable, and it was
// wrong about the product one commit later. Three of these bytes are the enum
// and the rest are the two constraints a model cannot infer from it — which
// offers accept never, and that a permanent entry is reviewed rather than kept
// unexamined — because both are things it will be asked to explain out loud.
// Raised by 40 on 2026-08-11 to replace the obsolete instruction that forced
// multi-check requests through serial confirmations. These bytes define the
// atomic batch and make later timing corrections replace older variants.
// Raised by 321 on 2026-08-11 for the typed ambient-contribution contract. It
// lets the host reject confident but unhelpful restatements deterministically.
// Raised by 234 on 2026-08-12 for numerical fidelity: operational replies now
// preserve binary-unit conversions instead of turning 305,282 MiB into the
// materially wrong "about 305 GiB". The host also validates that explicit
// MiB/GiB conversions agree before a reply can leave the process.
// Raised by 190 on 2026-08-13 to say which scope the memory is being written
// for. Channel memory and thread memory are the same shape under two keys, so
// a turn answered outside a thread wrote its own working state as the
// channel's: #backend-ops, an alerts feed for many services, carried one
// investigation's goal as though the room existed to answer it. The host now
// drops a goal at channel scope, and these bytes stop the model spending a
// field on something that will be discarded.
// Raised by 124 on 2026-08-13 to say where a referenced transcript came from.
// A permalink to another channel was already parsed, authorized and fetched,
// and then handed to the model as "an older thread" with nothing marking it as
// belonging to a different room — while the instructions two paragraphs down
// tell it to treat the current thread as the referent of "that". A link to the
// exact thread holding the answer read as unavailable. Paid for in part: the
// same block lost its note about immutable message anchors, which described
// how the cache works rather than anything the model can act on.
// Raised by 540 on 2026-08-13 for record_repository_contents: one operation
// example and three lines saying what the repository map may hold. It replaces
// RESPONDER_WORKSPACE.md, a hand-maintained 3,092-byte index that the Coop
// instructions told every cross-repository turn to read first and that had
// drifted in both directions for two weeks. The prompt now carries a map
// derived from the session's own pins, so the bytes bought a smaller total read
// and a map that cannot go stale between deploys.
// Raised by 378 on 2026-08-14 to state the result envelope once and exactly.
// The prompt had been teaching two protocols at the same time: the operations
// list said typed operations carry the result, and a dozen sentences around it
// still told the model to "include task_title", "add incident_title", "omit
// memory_offer" — the legacy top-level fields. Those sentences now name the
// operations that carry them, and the envelope paragraph states its whole field
// set (action, reaction, title, attention, reason, task_pull_request,
// publication_updates, operations) instead of implying it. Part of the cost is
// recovered: the offer contract stopped listing eight field names to say that
// an offer is a proposal, which was the same rule stated by enumeration.
//
// task_pull_request is in that list deliberately. TaskOffer carries kind,
// title, repository and prompt and nothing else, so it is the one result-shaped
// thing with no operation to travel in, and a prompt that forbade it would
// forbid updating an exact existing PR at all.
//
// Raised by 108 net on 2026-08-14, the day the prompt stopped being a heap.
// Bought: one persona (the two role sentences disagreed — Responder in this
// lane, Emisar in the conversation lane — and the follow-up rule already spoke
// of Emisar, which is the name teammates actually see); a continuity
// instruction telling the model that structured_memory, prior context, and the
// episode-continuity ledger are its own earlier findings to build on rather
// than re-derive; a when-to-ask rule for sizable engineering offers (three
// pointed questions, each with a proposed default) against a production count
// of five request_operator_input uses ever; a final shape check at the tail
// naming the exact correction classes still firing — bare payload nouns,
// integer confidence, blocked completions missing their five fields; and the
// simplified-technical-English default the owner asked for. Paid: the memory
// rules said twice became once, the engineering-offer rules said three times
// became one block, the reply bullet stopped restating it, and the plain and
// alert style policies lost their overlap. 2,441 bytes of additions arrived
// with 2,333 bytes of deletions.
//
// Raised by 375 on 2026-08-14, the day the prompt gate ran for the first
// time. Its first real execution surfaced the format failures still firing:
// a capability_unavailable blocker without capability_gaps, a pack
// recommendation no evidence record identified, and a reply stream without
// its complete_episode. Each is now named in the final shape check, at the
// tail where it is the last thing read before answering.
//
// Raised by 951 on 2026-08-14 for four named behaviors in one batch: a
// shipped fix schedules its own scheduled_verification wait; evidence that
// contradicts a teammate's claim gets a reply with the evidence and one
// question; the team's names for things are learned and used; a repeated
// working-style signal earns one offered guidance memory. Each is pinned
// below so a future diet cannot silently eat it.
//
// Lowered by 93 on 2026-08-14, the deletion the envelope-dialect migration was
// for. The sentence "a legacy top-level result field is read, then sent back
// once to be re-emitted as operations" was the tolerance, and it undercut the
// absolute rule two lines above it — the envelope's field set is closed and
// nothing else may appear beside it. Nothing replaced it: an envelope carrying
// its result is now unreadable, and the rejection says which fields and which
// operations carry them on the one turn that needs to hear it.
// Raised by 471 on 2026-08-15 for offer_grant_promotion — the operation a model
// uses to propose that an action has earned a rung of remediation authority.
// It is the most expensive single bullet per byte in the list and the easiest
// to justify: every other operation reports what happened, and this one asks
// for permission. The bytes buy the exact action identity (id, pack and runner
// together, which is what a grant is scoped to) and one sentence saying the
// host recomputes the count, fixes the scope itself, and ends at an operator's
// confirmation — so a model cannot read the operation as a way to grant itself
// anything.
//
// Lowered by 5,391 on 2026-08-15, and no rule was removed to do it. Three
// blocks now ride the turns that can use them: the operational-alert language
// rules (2,650 bytes) when the target is an app message or carries alert text,
// the generated-visual rules (1,194) when a visual tool exists and the ask
// names a chart, image or meme, and the compound-request rules (1,543) when the
// message carries more than one instruction. Measured over the replay corpora,
// that is 66% of turns without the alert block, every turn without the visual
// block, and 75% without the compound block.
//
// The risk this trades against is a wrong predicate silently dropping a rule
// the turn needed, so each block has a table beside
// TestPromptSectionsAppearOnlyWhenTheyApply asserting both directions on real
// corpus text. Every predicate is biased toward inclusion for the same reason:
// a false positive costs the bytes back, a false negative costs a behaviour and
// shows up nowhere.
//
// 46342 on landing: the two changes above crossed — 45871 after the diet, plus
// the 471-byte offer_grant_promotion bullet — and the pin is the measured sum.
//
// 46946 on 2026-08-15 for offer_runbook_draft and offer_kb_card: 604 bytes for
// two operations, which is 302 each against the 471 the single grant bullet
// cost, because the sentence all three of them needed — these propose, the host
// recomputes, an operator confirms — was written once below the list instead of
// three times inside it. That rewrite paid for about a third of the new text.
// The hard ceiling in TestStaticPromptSizeIsBounded is the bound that actually
// refused this twice; both bullets were cut down until it passed rather than
// being allowed to spend context the conversation needs.
//
// 47144 the same day for the supersedes field, crossing the raise above: 198
// bytes, one key in the record_evidence example and one sentence saying what
// retires a record and what does not. The host has told the model to "supersede
// the losing statement" since 79445e8 and had no rule implementing it, so the
// live model wrote the retirement into its observation prose — the only place
// the vocabulary left for it — and the alert-triage episode was corrected with
// the same sentence every round until its budget ran out. The first draft cost
// 355; the hard ceiling in TestStaticPromptSizeIsBounded refused it, and the
// example key and three sentences were cut down until what remained was the
// field, its shape, and the one fact a model cannot infer.
//
// Raised on 2026-08-15 for request_record: the operation line and the one
// sentence that says the four durable reports are the host's to render and
// never the model's to write. `/responder handoff` was deleted the same day,
// and without this the model would have answered "give me a handoff summary"
// out of its own context — which is the account of the work that the record
// exists to replace. Re-measured against the merged prompt rather than added
// to the number this branch was written against: 47,144 plus the 308 bytes of
// request_record is 47,452, and this pin is two-sided, so it is the exact
// measurement and not a bound.
// 47541 after the request_record pairing rule: the first live gate run
// proved "say nothing else" and "exactly one complete_episode" fought, and
// the model obeyed the nearer sentence. 89 bytes to end the fight.
//
// 48062 on 2026-08-15 for offer_assignment, the operation that replaced
// `/responder assignments create`. 521 bytes, and they are the most expensive
// bytes in this file per operation for the same reason offer_grant_promotion's
// were: this is the model asking for AUTHORITY rather than reporting a result,
// and an offer that arrives malformed costs a correction turn while one that
// arrives believing it grants something is worse. Of the 521, roughly 90 are
// the closed change-class set, which is not compressible — a model told to
// choose from a list it cannot see is the exact shape of the worst recorded
// correction loop, 6.6 repeats on one episode picking from an empty list of
// verdicts — and the pairing clause is 9275b18's lesson applied before rather
// than after its own first live gate run.
//
// The first draft cost 629. It was cut to 521 before this number moved, by
// folding the assignment into the shared "these propose only, an operator
// confirms" sentence below the list instead of restating it, and by dropping
// the rationale key the same sentence already covers for all four offers.
//
// 48369 on 2026-08-15, the day the full gate first ran the assignment case:
// 0/2, and both failures were the prompt's, not the model's. One sample asked
// the operator instead of misclassifying terraform drift — the assignment
// line now says the offer exists only for the listed classes and that
// time-driven work is offer_schedule. The other reached for offer_schedule
// and sent recurrence as an object, because the offers row was the only line
// in the vocabulary that never showed a value's type — recurrence's five
// words and the flat-string rule cost 206 bytes, against a strict-decode
// rejection and a correction turn every time a schedule is offered from
// guesswork.
const staticWatchPromptBytes = 48369

// The static prompt must not grow without someone deciding it should.
//
// This is a two-sided bound on purpose. Over the pin means the instructions
// grew and something has to give. Under it means a compression landed and the
// pin should come down to lock the win in — a ratchet that only ever loosens
// is not a ratchet.
func TestStaticWatchPromptSizeIsPinned(t *testing.T) {
	cfg := serviceConfig(t)
	prompt, _ := (&Service{cfg: cfg}).watchPrompt(
		core.SlackInput{
			ChannelID: "C123ABC", MessageTS: "1700.001",
			UserID: cfg.Slack.Operators[0], Kind: "scheduled",
			Text: "How is the health of our infrastructure?",
		},
		"U999BOT", false, nil, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, nil, nil, "", nil, WatchPromptBudget(0),
	)
	switch {
	case len(prompt) > staticWatchPromptBytes:
		t.Fatalf(
			"static watch prompt grew to %d bytes, over its pin of %d.\n"+
				"Every byte here is a byte of conversation the model cannot see. "+
				"Compress something else out, or raise the pin deliberately.",
			len(prompt), staticWatchPromptBytes,
		)
	case len(prompt) < staticWatchPromptBytes:
		t.Fatalf(
			"static watch prompt is %d bytes, under its pin of %d — "+
				"lower staticWatchPromptBytes to %d to keep the saving.",
			len(prompt), staticWatchPromptBytes, len(prompt),
		)
	}
	// The pin is only meaningful if the prompt actually leaves room for a
	// conversation. This is the number that matters to answer quality.
	if room := coop.MaxPromptBytes - len(prompt); room < 8<<10 {
		t.Fatalf(
			"instructions leave only %d bytes for conversation and evidence",
			room,
		)
	}
}

// A channel message the host had to shorten must say so in the prompt.
//
// WatchContextTextLimit is 2,000 bytes and the cut used to be silent, so a
// model reading the transcript could not tell a message the host shortened from
// a message the person actually ended there. A real 2,559-byte instruction for
// a whole-platform health review arrived ending "Decide healthy, degraded, or",
// and two runs in three answered by asking the operator to resend the missing
// word instead of doing the assessment.
func TestOversizedChannelMessageSaysTheHostCutIt(t *testing.T) {
	svc := &Service{cfg: serviceConfig(t)}
	instruction := strings.Repeat("preserve each metric's exact window. ", 70) +
		"Decide healthy, degraded, or unhealthy."
	if len(instruction) <= WatchContextTextLimit {
		t.Fatalf("the fixture is %d bytes and does not reach the %d bound",
			len(instruction), WatchContextTextLimit)
	}
	prompt, _ := svc.watchPrompt(
		core.SlackInput{
			ChannelID: "C123ABC", MessageTS: "1700.001", Kind: "message",
			UserID: "U123ABC", Text: instruction,
		},
		"U999BOT", false, nil, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, nil, nil, "", nil, WatchPromptBudget(0),
	)
	if !strings.Contains(prompt, "the host cut the rest of this message to fit") {
		t.Fatal("an oversized channel message was cut without saying so")
	}

	// A message that fits carries no marker, or every short message in the
	// transcript would claim to have been cut.
	fitting, _ := svc.watchPrompt(
		core.SlackInput{
			ChannelID: "C123ABC", MessageTS: "1700.002", Kind: "message",
			UserID: "U123ABC", Text: "is checkout slow?",
		},
		"U999BOT", false, nil, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, nil, nil, "", nil, WatchPromptBudget(0),
	)
	if strings.Contains(fitting, "the host cut the rest of this message to fit") {
		t.Fatal("a message that fitted was marked as cut")
	}
}

// The prompt's own worked example has to be a result the host would accept.
//
// A prompt that teaches one shape and demonstrates another teaches the one it
// demonstrates. This parses every concrete envelope example the watch prompt
// shows, through the parser a real turn goes through, and holds it to the rule
// the prose states: operations carry the result, and no legacy result field
// appears beside them. An example that drifts fails here rather than in a
// channel.
func TestWatchPromptExamplesUseTheTypedResultShape(t *testing.T) {
	cfg := serviceConfig(t)
	prompt, _ := (&Service{cfg: cfg}).watchPrompt(
		core.SlackInput{
			ChannelID: "C123ABC", MessageTS: "1700.001",
			UserID: cfg.Slack.Operators[0], Kind: "scheduled",
			Text: "How is the health of our infrastructure?",
		},
		"U999BOT", false, nil, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, nil, nil, "", nil, WatchPromptBudget(0),
	)
	// The bounded conversation lane's examples are held to the same bar since
	// 2026-08-14, when its four legacy-shaped examples taught every cheap turn
	// a dialect the host then spent a correction turn translating — a 2x turn
	// tax on the lane that exists to be cheap.
	conversation := (&Service{cfg: cfg}).conversationPrompt(
		core.SlackInput{
			ChannelID: "C123ABC", MessageTS: "1700.001",
			UserID: "U123ABC", Text: "Did the check pass?",
		},
		"U999BOT", false, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, "repo",
	)
	prompt += "\n" + conversation
	// Only concrete examples. The envelope schema sketch beside them spells its
	// action as "ignore|react|reply|incident|escalate", which is documentation
	// of the field rather than a decision, and is not meant to parse.
	examples := 0
	for _, line := range strings.Split(prompt, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, `{"action":"`) {
			continue
		}
		action := strings.SplitN(strings.TrimPrefix(line, `{"action":"`), `"`, 2)[0]
		if strings.Contains(action, "|") {
			continue
		}
		examples++
		if _, err := decisionpkg.ParseWatchDecision(line, testDecodeClock); err != nil {
			t.Fatalf("the prompt shows an example the host would reject: %v\n%s", err, line)
		}
		// Checked on the raw JSON, not the parsed decision: the fold projects
		// operations back onto the same top-level fields the retired dialect
		// used, so every parsed decision looks envelope-shaped afterwards. The
		// contract this holds is the raw one — an operations key present, and
		// no result field beside it.
		var raw map[string]json.RawMessage
		if err := json.Unmarshal([]byte(line), &raw); err != nil {
			t.Fatalf("example is not one JSON object: %v\n%s", err, line)
		}
		if _, ok := raw["operations"]; !ok {
			t.Fatalf("the prompt's example has no operations array:\n%s", line)
		}
		for field := range raw {
			switch field {
			case "action", "reaction", "title", "attention", "reason",
				"task_pull_request", "publication_updates", "operations":
			default:
				t.Fatalf("the prompt's example carries the legacy result field %q "+
					"beside its operations:\n%s", field, line)
			}
		}
	}
	if examples == 0 {
		t.Fatal("the watch prompt shows no concrete envelope example; this guard " +
			"would pass on a prompt that had stopped demonstrating the shape at all")
	}
}
