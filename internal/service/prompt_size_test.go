package service

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"testing"

	"github.com/AndrewDryga/ryker/internal/coop"
	"github.com/AndrewDryga/ryker/internal/core"
	decisionpkg "github.com/AndrewDryga/ryker/internal/decision"
	"github.com/AndrewDryga/ryker/internal/investigation"
)

// promptCeilings caps the static instruction size of each prompt with empty
// context.
//
// A Coop turn is capped at 64 KiB. Whatever the instructions do not use is what
// the model gets to see of the actual conversation — so this is not a style
// budget, it is the context budget. Lower an entry when a diet phase lands;
// raising one means every future turn sees less of its channel, which needs a
// reason written here.
var promptCeilings = map[string]int{
	// Lowered from 50 KiB when conditional inclusion landed: an ambient channel
	// message no longer carries the scheduled-occurrence, host-recheck,
	// publication-correlation or durable-behavior rules, none of which it can
	// use.
	//
	// Raised to 43 KiB on 2026-08-14 for four behaviors bought as one batch,
	// each a thing operators asked for by name: post-fix verification (a fix
	// that ships schedules its own scheduled_verification wait instead of
	// handing "monitor it" back), the disagreement middle band (evidence that
	// contradicts a teammate's claim gets a reply with the evidence and one
	// question, not silence and not agreement), glossary learning (the team's
	// names for things become knowledge and get used), and the
	// unverifiable-alert rule rides the standing-rule block. ~950 bytes for
	// four behaviors, with margin left so the ceiling stays a ratchet rather
	// than a tripwire.
	// And to 43 KiB + 256 on 2026-08-15 for offer_grant_promotion, the one
	// operation by which a model can ask for AUTHORITY rather than report a
	// result. 170 bytes, and they are the bytes that keep the ask well-formed:
	// the payload names the exact action identity a grant is scoped to, and the
	// clause after it says plainly that the host recomputes the count, sets the
	// scope itself, and ends at an operator's confirmation. An offer that
	// arrives malformed is refused, which costs a correction turn; an offer that
	// arrives believing it grants something is worse.
	//
	// Lowered to 39 KiB on 2026-08-15 when the alert-language, generated-visual
	// and compound-request blocks became conditional. This turn — "check the
	// api", from nobody in particular — is not an alert, asks for nothing to
	// look at, and carries one instruction, so it now carries none of the three
	// and measures 38,340 bytes against the 43,731 it carried the day before.
	// It had 301 bytes of headroom under the old number; a ceiling that close
	// is the tripwire this file warns about, so the margin is deliberately
	// about 1 KiB.
	// Merged 2026-08-15: 39 KiB after the diet plus the 471-byte grant bullet
	// measures 38,811; 39 KiB + 256 keeps roughly 1 KiB of ratchet room.
	//
	// Raised again on 2026-08-15 for request_record. The four durable reports
	// lost their `/responder` spelling, and the obvious replacement — let the
	// model write the summary when somebody asks for one — is the expensive
	// mistake: a handoff is exactly the document an operator reads instead of
	// the record, and a model writing one writes its own account of what it
	// remembers. The bullet and its one instruction line buy back every one of
	// those, and the alternative was cheaper only in bytes.
	//
	// Re-measured on the merged tree rather than added to the old number: the
	// entry above was written against 38,811 and the tree it lands on carries
	// the knowledge offers and the supersedes field as well, so the variant is
	// 39,921 bytes. 40 KiB restores the roughly 1 KiB of margin the paragraph
	// above says this entry wants; 39 KiB + 256 would have left 271 bytes,
	// which is the tripwire that note is about.
	//
	// And again on 2026-08-15 for offer_assignment, which replaced
	// `/responder assignments create` — the last slash verb that GRANTED
	// authority, and one an operator had to compose as nine key=value bounds
	// without ever seeing what they would produce. 521 bytes buys the
	// conversational path and the closed change-class set the model has to
	// choose from; the operation list is inside the policy block every variant
	// carries, so all three entries here pay for it. Measured 40,531, which
	// left the previous 40 KiB with 429 bytes — the tripwire again. 40 KiB +
	// 512 restores the roughly 1 KiB this entry says it wants.
	//
	// And on 2026-08-15 for root cause by default: the record_finding bullet and
	// the depth paragraph, 970 bytes across every variant. This is the largest
	// single raise since the four-behavior batch, and it is bought against a
	// measured 88 minutes. The 12:16 Zot triage closed decision_ready/succeeded
	// on a Run-Applied event while its own reply said VA1 pyke "did not deploy:
	// its rollout missed the progress deadline and automatically rolled back",
	// and handed the readers "avoid retrying until the failed allocation or
	// health check is identified". The failure it had found lived in prose, no
	// contract could see it, and three human nudges bought a root cause a deep
	// dive then found in four minutes. The bullet is what makes that rollback
	// machine-readable; the paragraph is what stops the next one ending in advice
	// to investigate. Measured 42,137, which left 40 KiB + 512 nothing at all;
	// 42 KiB restores the roughly 1 KiB this entry says it wants.
	//
	// And 244 bytes on 2026-08-16 for the partial correction round, in the same
	// shared operation list, so all three entries below pay it once. This is the
	// cheapest raise in the file per byte returned: a correction used to make the
	// model re-emit the entire envelope, and on the worst recorded episode —
	// episode_run_956b7644b6fbef89b17aa3a9c6df8da8, sixteen turns for $8.84 —
	// 116,385 of 233,398 result bytes were record operations the host was already
	// holding, 56.8% of everything its correction rounds emitted. The host
	// restores what a round omits; these bytes are what tell the model it may
	// omit them, which is the half no validator can supply. Measured 43,227,
	// which left 42 KiB nothing; 43 KiB + 256 is 1,061.
	// Raised to 44 KiB on 2026-08-20 for the exact jv self-validation command
	// and the corrected conditional schedule shape it validates.
	"watch": 44 * 1024,

	// The ambient measurement above is the cheap case, and for a while it was
	// the only one — so this test reported "37% left for context" while an
	// operator turn, which additionally carries the behavior-offer and governed
	// action policies, actually left 27%. That is the turn where context is
	// scarcest and where losing it costs the most, so it gets its own ceiling.
	// This entry is not a loosening of the one above: it is the first time the
	// expensive case was measured at all.
	//
	// Raised from 46 KiB on 2026-08-08, deliberately. Two rules that stop real
	// defects were scoped to alert replies only — the length bound and "finish
	// the diagnosis yourself" — so a reply to a human question was governed by
	// neither. A nine-word question drew a 350-word answer, and a status report
	// ended by telling the operator to go look up the image tag themselves.
	// Generalising both cost 959 bytes, against 1072 bytes the compression
	// slices had just saved. Net for the day is 113 bytes; the budget bought
	// two behaviours instead of context, which is the right way round when the
	// context was being spent on unreadable answers.
	//
	// Raised to 48 KiB on 2026-08-13 for record_repository_contents and the
	// repository map it maintains. This is a rare raise that buys context back
	// rather than spending it: the map it replaces was a 3,092-byte file in a
	// business repository that the instructions told every cross-repository
	// turn to open first, so the old arrangement cost more than this and was
	// wrong besides — it named nine repositories Coop never mounted and omitted
	// six it did. 231 bytes of contract, against a file read that no longer
	// happens and a map that can no longer disagree with the pins.
	//
	// Raised by 64 bytes on 2026-08-14, after the first real run of the prompt
	// gate. The overhaul that unified the persona, merged every rule said twice
	// or three times, and added the continuity, when-to-ask, and final-shape
	// instructions landed 43 bytes over this ceiling once the gate's surviving
	// correction classes were named in the final check. The known trims — a
	// stuttered sentence in the governed-action policy among them — are already
	// taken; the remainder buys the format checks that the gate's first
	// execution showed still firing, on a transport whose cap now leaves this
	// variant 81% of the turn for context.
	// And to 49 KiB + 256 in the same batch: the operator variant carries the
	// same four behaviors plus the style-signal clause on the offer_memory
	// gate (an operator who asks for brevity twice gets offered a guidance
	// memory capturing it, instead of asking a third time).
	// And to 49 KiB + 640 on 2026-08-15 for the same offer_grant_promotion
	// entry, which lands in both variants.
	//
	// Lowered to 45 KiB on 2026-08-15 by the same three conditional blocks:
	// 50,335 bytes to 44,944. This entry had 97 bytes of headroom, which is a
	// ceiling that fails the next honest sentence rather than the next
	// unjustified paragraph.
	//
	// Which is what happened, the same day: the knowledge-offer bullets left
	// this variant 59 bytes clear, and the next honest sentence was the
	// supersedes field — 196 bytes for the one operation payload that lets a
	// model retire a contradicted statement at all. The host had prescribed
	// that move since 79445e8 with no field behind it, and the live model
	// answered in prose, which retires nothing; an alert-triage episode spent
	// every correction turn it had being told to do it again. Cut first, then
	// raised: the field's own text went from 355 bytes to 196 before this
	// number moved, by shortening the example key and folding three sentences
	// into one. 45 KiB + 512 leaves 375 bytes of headroom, so the entry is a
	// ratchet again rather than a tripwire.
	//
	// And again on 2026-08-15 for request_record — see the watch entry above.
	// The operator variant pays for the same contract, because the operation
	// list is inside the policy block both variants carry; it is the same
	// instruction either way. Measured 46,525 on the merged tree, which left
	// the previous 45 KiB + 512 with 67 bytes; 46 KiB + 512 is a ratchet again.
	//
	// And once more the same day for offer_assignment, again the same 521 bytes
	// in the same shared block. Measured 47,135, leaving 46 KiB + 512 with 481
	// bytes; 47 KiB is 993, which is the margin these entries are written to.
	//
	// And once more the same day for root cause by default — see the watch entry
	// above; the operation list and the depth paragraph are both in blocks every
	// variant carries, so all three entries pay the same 970 bytes. Measured
	// 48,741, which left 47 KiB with nothing. 48 KiB + 512 is 923.
	//
	// And 244 bytes on 2026-08-16 for the partial correction round — the same
	// shared operation list again, measured against the same recorded episode.
	// Measured 49,831, which left 48 KiB + 512 nothing; 49 KiB + 512 is 857.
	// Raised to 50 KiB + 512 on 2026-08-20 for the attached JSON Schema's exact
	// jv self-validation command. The model now checks the whole candidate once
	// before return instead of learning one host rejection per correction turn.
	"watch-operator": 50*1024 + 512,

	// The expensive turn, kept measured on purpose. Conditional inclusion means
	// the two entries above now describe turns that skip 5,391 bytes of rules,
	// so on their own they would ratchet the cheap case and leave the case that
	// actually runs out of context unbounded — which is the mistake that made
	// the watch-operator entry necessary in the first place. This one asks for
	// all three back.
	// Measured 49,357 on landing with the grant bullet aboard; 49 KiB + 512,
	// and re-measured here with request_record aboard as well: 50,467, which
	// left the old number 221 bytes. 50 KiB + 512 on 2026-08-15.
	// And 51,077 with offer_assignment aboard the same day, which left that
	// number 635 bytes. 51 KiB is 1,147 — the margin the entries above are
	// written to, on the variant that has the least of it to spare.
	// And 52,683 with root cause by default aboard, which left 51 KiB with 541.
	// 52 KiB + 512 is 1,077 — the margin these entries are written to, on the
	// variant that has the least of it to spare. This is also the variant that
	// most needs what the raise buys: the alert turns are where a discovered
	// failure actually turns up.
	// And 53,896 on 2026-08-16 with the partial correction round aboard — 244
	// bytes, the same shared operation list. The alert variant is also where the
	// saving lands: the recorded sixteen-turn episode this was measured on was an
	// alert-lane run notification. 52 KiB + 512 had 136 left; 53 KiB + 512 is 888.
	// Raised to 54 KiB + 512 on 2026-08-20 for that same validator instruction.
	// Alert turns need it most: the production regression spent fifteen rejected
	// turns and never delivered the answer it had already written.
	"watch-operator-alert": 54*1024 + 512,
}

func TestStaticPromptSizeIsBounded(t *testing.T) {
	sizes := staticPromptSizes(t)
	for name, ceiling := range promptCeilings {
		size, ok := sizes[name]
		if !ok {
			t.Fatalf("no measurement for the %q prompt; update this test", name)
		}
		remaining := coop.MaxPromptBytes - size
		t.Logf(
			"%s prompt: %d bytes of instructions, %d bytes (%d%%) left for context",
			name, size, remaining, remaining*100/coop.MaxPromptBytes,
		)
		if size > ceiling {
			t.Errorf(
				"the %s prompt is %d bytes of static instructions, over its %d ceiling; "+
					"that is %d bytes taken from what the model sees of the conversation",
				name, size, ceiling, size-ceiling,
			)
		}
	}
}

// TestStaticPromptSectionSizes reports where the budget actually goes, so a
// diet targets the expensive blocks instead of the obvious ones.
func TestStaticPromptSectionSizes(t *testing.T) {
	type section struct {
		name  string
		bytes int
	}
	sections := []section{
		{"operationalMemoryPolicy", len(operationalMemoryPolicy)},
		{"slackReplyShapePolicy", len(slackReplyShapePolicy)},
		{"investigation.ResultOperationsPrompt", len(investigation.ResultOperationsPrompt())},
	}
	// What the measured turn does not carry. Two of these have been conditional
	// for a while and were being counted against a prompt that never held them,
	// which overstated the named blocks by 6.5 KiB and understated the inline
	// scaffolding by the same amount; the last three joined them on 2026-08-15.
	// A diet reads this table to choose a target, so it has to say which side of
	// the line each block is on.
	conditional := []section{
		{"behaviorOfferPolicy", len(behaviorOfferPolicy)},
		{"emisarGovernedActionPolicy", len(emisarGovernedActionPolicy)},
		{"slackOperationalAlertLanguagePolicy",
			len(slackReplyFormattingPolicy) - len(slackReplyShapePolicy)},
		{"compoundRequestPolicy", len(compoundRequestPolicy)},
		{"generatedVisualPolicyText", len(generatedVisualPolicyText)},
	}
	total := staticPromptSizes(t)["watch"]
	accounted := 0
	sort.Slice(sections, func(i, j int) bool { return sections[i].bytes > sections[j].bytes })
	for _, item := range sections {
		accounted += item.bytes
		t.Logf("%-40s %6d bytes (%2d%% of the watch prompt)",
			item.name, item.bytes, item.bytes*100/total)
	}
	t.Logf("%-40s %6d bytes", "named policy blocks, total", accounted)
	t.Logf("%-40s %6d bytes", "inline instructions and scaffolding", total-accounted)
	sort.Slice(conditional, func(i, j int) bool { return conditional[i].bytes > conditional[j].bytes })
	for _, item := range conditional {
		t.Logf("%-40s %6d bytes (conditional; not in this turn)", item.name, item.bytes)
	}
}

func staticPromptSizes(t *testing.T) map[string]int {
	t.Helper()
	cfg := serviceConfig(t)
	svc := &Service{cfg: cfg}
	measure := func(input core.SlackInput) int {
		return len(svc.unboundedWatchPrompt(
			input,
			"U999BOT", false, nil, nil, core.AgentMemory{}, nil, nil,
			decisionpkg.OperationalMemoryContext{}, nil, nil, nil, "emisar", nil,
			nil))
	}
	return map[string]int{
		"watch": measure(core.SlackInput{ChannelID: "C1", Text: "check the api"}),
		"watch-operator": measure(core.SlackInput{
			ChannelID: "C1", Text: "check the api", UserID: cfg.Slack.Operators[0],
		}),
		// The turn that switches every text-keyed block on at once: an operator
		// asking, about an alert, for a chart, in two instructions. Without it
		// the ceilings above would measure only the turns the diet made cheap,
		// which is exactly the hole this file already fell into once — see the
		// watch-operator entry, added because the ambient measurement was
		// reporting 37% left for context while the expensive turn had 27%.
		"watch-operator-alert": measure(core.SlackInput{
			ChannelID: "C1", UserID: cfg.Slack.Operators[0],
			Text: "The checkout latency alert is still firing. Chart the p99 " +
				"for the last hour and tell me whether it recovered.",
		}),
	}
}

// When context does not fit, the assembler has to choose what to drop. The
// transport's fallback is to cut the middle out, which slices through the
// structured context block — so the only acceptable outcome here is a prompt
// that fits, still carries the target, and says what it lost.
func TestOversizedContextIsBudgetedNotSliced(t *testing.T) {
	svc := &Service{cfg: serviceConfig(t)}
	// Filler scales with the budget so assembly overflows it however large
	// the transport cap grows: forty messages of budget/50 bytes each are
	// alone most of a budget, before memory and related summaries pile on.
	filler := strings.Repeat("saturated evidence detail ", WatchPromptBudget(0)/50/len("saturated evidence detail ")+1)

	recent := make([]decisionpkg.WatchContextMessage, 0, 40)
	for index := range 40 {
		recent = append(recent, decisionpkg.WatchContextMessage{
			MessageTS: fmt.Sprintf("170%02d.000", index),
			SenderID:  "U123ABC",
			Text:      fmt.Sprintf("message %02d %s", index, filler),
		})
	}
	related := make([]decisionpkg.ConversationSituationContext, 0, 6)
	for index := range 6 {
		related = append(related, decisionpkg.ConversationSituationContext{
			ChannelID: fmt.Sprintf("CREL%02d", index), Repository: "emisar",
			Relationship: "workspace",
			Summary:      core.AgentMemory{SituationSummary: filler},
		})
	}
	prior := decisionpkg.OperationalMemoryContext{}
	for index := range 10 {
		prior.RecentEvidence = append(prior.RecentEvidence, decisionpkg.EvidencePromptEntry{
			ID: fmt.Sprintf("ev_%02d", index), Claim: filler, Observation: filler,
		})
		prior.ConfirmedMemory = append(prior.ConfirmedMemory, decisionpkg.MemoryPromptEntry{
			Scope: "channel:C1", Subject: fmt.Sprintf("subject-%02d", index),
			Predicate: "guidance", Value: filler,
		})
	}

	prompt, _ := svc.watchPrompt(
		core.SlackInput{ChannelID: "C1", MessageTS: "1799.000", Text: "why is checkout failing"},
		"U999BOT", false, recent, nil, core.AgentMemory{}, related, nil, prior, nil, nil, nil, "emisar", nil,
		WatchPromptBudget(0))

	if len(prompt) > WatchPromptBudget(0) {
		t.Fatalf("budgeted prompt is %d bytes, over the %d bound",
			len(prompt), WatchPromptBudget(0))
	}
	if !strings.Contains(prompt, "why is checkout failing") {
		t.Fatal("budgeting dropped the target message")
	}
	if !strings.Contains(prompt, "context_omitted") {
		t.Fatal("the model was not told what had been omitted")
	}
	// Prior context goes before the conversation, and operator-confirmed
	// memory goes after it: someone put that there deliberately, so it is the
	// last remembered layer to give up its place.
	evidenceAt := strings.Index(prompt, "evidence records from this channel were omitted")
	relatedAt := strings.Index(prompt, "summaries of related conversations were omitted")
	messagesAt := strings.Index(prompt, "older channel messages were omitted")
	confirmedAt := strings.Index(prompt, "operator-confirmed memory was omitted")
	if evidenceAt < 0 {
		t.Fatalf("evidence was never dropped:\n%s", omittedSection(t, prompt))
	}
	for _, step := range []struct {
		name    string
		earlier int
		later   int
	}{
		{"evidence before related", evidenceAt, relatedAt},
		{"related before messages", relatedAt, messagesAt},
		{"messages before confirmed memory", messagesAt, confirmedAt},
	} {
		if step.later >= 0 && step.earlier > step.later {
			t.Fatalf("drop order violated (%s):\n%s", step.name, omittedSection(t, prompt))
		}
	}
	// The floor holds: the conversation nearest the target survives. Asserted
	// against the messages themselves rather than against the sentence that
	// announces them, because the sentence is prose that may be reworded and
	// the surviving transcript is the thing the floor exists to protect.
	for index := 40 - minimumWatchMessages; index < 40; index++ {
		if !strings.Contains(prompt, fmt.Sprintf("message %02d ", index)) {
			t.Fatalf(
				"the message floor was not applied; message %02d was dropped:\n%s",
				index, omittedSection(t, prompt),
			)
		}
	}
	if messagesAt < 0 {
		t.Fatalf("the transcript was cut without saying so:\n%s", omittedSection(t, prompt))
	}
}

// The structured context block must remain parseable after budgeting — that is
// the whole point of budgeting rather than letting the transport elide.
func TestBudgetedContextRemainsValidJSON(t *testing.T) {
	svc := &Service{cfg: serviceConfig(t)}
	filler := strings.Repeat("detail ", 400)
	recent := make([]decisionpkg.WatchContextMessage, 0, 30)
	for index := range 30 {
		recent = append(recent, decisionpkg.WatchContextMessage{
			MessageTS: fmt.Sprintf("170%02d.000", index), Text: filler,
		})
	}
	prompt, _ := svc.watchPrompt(
		core.SlackInput{ChannelID: "C1", MessageTS: "1799.000", Text: "status?"},
		"U999BOT", false, recent, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, nil, nil, nil, "emisar", nil,
		WatchPromptBudget(0))
	start := strings.Index(prompt, `{"channel_id"`)
	if start < 0 {
		t.Fatal("no structured context block in the prompt")
	}
	var decoded map[string]any
	decoder := json.NewDecoder(strings.NewReader(prompt[start:]))
	if err := decoder.Decode(&decoded); err != nil {
		t.Fatalf("structured context is not valid JSON after budgeting: %v", err)
	}
	if _, ok := decoded["target_message"]; !ok {
		t.Fatal("the target message did not survive budgeting")
	}
}

func omittedSection(t *testing.T, prompt string) string {
	t.Helper()
	index := strings.Index(prompt, "context_omitted")
	if index < 0 {
		return "(no context_omitted section)"
	}
	end := min(index+400, len(prompt))
	return prompt[index:end]
}

// Every byte of instruction is a byte the model cannot spend on the
// conversation, so a rule that cannot apply to this turn should not be sent.
// Each block must appear exactly when its precondition holds.
func TestPromptSectionsAppearOnlyWhenTheyApply(t *testing.T) {
	cfg := serviceConfig(t)
	svc := &Service{cfg: cfg}
	operator := cfg.Slack.Operators[0]

	build := func(input core.SlackInput) string {
		return watchPromptFor(svc, input) + includeWhen(input.Kind == "recheck", hostRecheckPolicyText)
	}

	ambient := build(core.SlackInput{ChannelID: "C1", Text: "is checkout slow?"})
	for _, absent := range []struct{ name, marker string }{
		{"scheduled occurrence", "sender_type is operator_schedule"},
		{"host recheck", "sender_type is host_recheck"},
		{"publication correlation", "trusted-active-publications"},
		{"behavior offers", "Configured operators may request typed lasting behavior"},
	} {
		if strings.Contains(ambient, absent.marker) {
			t.Errorf("the %s block was sent to a turn that cannot use it", absent.name)
		}
	}

	fromOperator := build(core.SlackInput{ChannelID: "C1", UserID: operator, Text: "remember this"})
	if !strings.Contains(fromOperator, "Configured operators may request typed lasting behavior") {
		t.Error("an operator turn did not carry the behavior offer rules")
	}

	scheduled := build(core.SlackInput{ChannelID: "C1", Kind: "scheduled", Text: "daily check"})
	if !strings.Contains(scheduled, "sender_type is operator_schedule") {
		t.Error("a scheduled occurrence did not carry its own handling rules")
	}
	if strings.Contains(scheduled, "sender_type is host_recheck") {
		t.Error("a scheduled occurrence carried the recheck rules")
	}

	recheck := build(core.SlackInput{ChannelID: "C1", Kind: "recheck", Text: "recheck"})
	if !strings.Contains(recheck, "sender_type is host_recheck") {
		t.Error("a recheck did not carry its own handling rules")
	}

	// An ambient turn is the common case, so its saving is the one that matters.
	if len(ambient) >= len(fromOperator) {
		t.Errorf("an ambient turn (%d bytes) was not cheaper than an operator turn (%d bytes)",
			len(ambient), len(fromOperator))
	}
	t.Logf("ambient turn %d bytes, operator turn %d bytes, saving %d",
		len(ambient), len(fromOperator), len(fromOperator)-len(ambient))
}

// A production structured-result recheck was told both to choose ignore when
// operational evidence was unchanged and to replace the result the host had
// rejected. It chose ignore, spent every correction round being rejected, and
// posted a failure fallback instead of the completed investigation.
func TestRejectedStructuredResultNeverReceivesQuietRecheckInstruction(t *testing.T) {
	cfg := serviceConfig(t)
	svc := &Service{cfg: cfg}
	input := core.SlackInput{ChannelID: "C1", Kind: "recheck", Text: "retry rejected result"}
	failure := "the prior structured result omitted its completion verdict"

	prompt := watchPromptFor(svc, input) +
		includeWhen(input.Kind == "recheck" && strings.TrimSpace(failure) == "", hostRecheckPolicyText) +
		watchDecisionCorrectionPrompt(failure)
	if strings.Contains(prompt, "result are unchanged, choose action=ignore") {
		t.Fatal("a structured-result retry was also told to ignore unchanged evidence")
	}
	if !strings.Contains(prompt, "do not silently ignore") {
		t.Fatal("the structured-result retry did not require a corrected answer")
	}
}

// watchPromptFor builds the static watch prompt for one target message.
func watchPromptFor(svc *Service, input core.SlackInput) string {
	return svc.unboundedWatchPrompt(
		input, "U999BOT", false, nil, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, nil, nil, nil, "emisar", nil, nil)
}

// The three tables below guard the blocks that became conditional on
// 2026-08-15, and they exist because those blocks are gated on the target's
// TEXT rather than on its lane.
//
// The four blocks in the test above key on sender_type or on a host fact, so
// their predicate is either right or obviously wrong. These read a Slack message
// and decide. A predicate that is wrong in the present direction costs the bytes
// back on one turn; a predicate that is wrong in the absent direction removes a
// rule the turn needed and appears in no diff, no gate, and no log — the model
// simply answers an alert without ever having been told that a RESOLVED card is
// not a recovery. 5,391 bytes came off an ordinary turn for this, which is why
// both directions are asserted, on text harvested from the replay corpora rather
// than on sentences written to pass.
//
// The reply shape rules are checked as present throughout. They are not
// conditional, and a turn that lost them has lost the reply contract rather than
// saved 2,650 bytes.
const replyShapeMarker = "Default to natural, plain English"

func TestAlertLanguageRulesRideAnAppOrAlertTurn(t *testing.T) {
	const marker = "separate the app's notification state from the actual service state"
	svc := &Service{cfg: serviceConfig(t)}
	for _, testCase := range []struct {
		name  string
		input core.SlackInput
		want  bool
	}{
		{
			name: "monitoring alert posted by an app",
			input: core.SlackInput{
				ChannelID: "C1", Kind: "bot_message", UserID: "U0APP",
				Text: "*<https://console.cloud.google.com/monitoring/alerting/alerts/" +
					"0.obeaujx8bfxn|Emisar: Load Balancer 5xx Ratio High>*\n" +
					"Alert status\nAlert open\nNo severity",
			},
			want: true,
		},
		{
			// An app message with no alert vocabulary at all. The block's first
			// bullet is about acknowledgement and lifecycle cards, so it belongs
			// to every app message, not only to the ones that say "firing".
			name: "terraform run notification posted by an app",
			input: core.SlackInput{
				ChannelID: "C1", Kind: "bot_message", UserID: "U0APP",
				Text: "Run notification for SME-Blitz/blitz-infra\n" +
					"Run run-UBwFpsiiVMtXwtbi\nRun Planned - Needs Confirmation",
			},
			want: true,
		},
		{
			// Both of these arrive as human messages in the replay corpus: a
			// person forwards the card into the channel. The rules apply to the
			// reply, not to the transport that carried the alert.
			name: "person pastes a firing card",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "[VA1 FIRING:1] WARNING | Cassandra Reaper schedule unfulfilled"},
			want: true,
		},
		{
			name: "person pastes a resolution",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "Automatically resolved Grafana: VA1: Cloud SQL slot watcher " +
					"expired for tolgee"},
			want: true,
		},
		{
			name: "plain operational question",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "What is the disk usage on nomad-hvn03 right now?"},
			want: false,
		},
		{
			name: "repository change request",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "The retry backoff in the worker looks wrong to me — can you fix it?"},
			want: false,
		},
		{
			name: "runbook request",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "Create reusable deep infrastructure health review runbook"},
			want: false,
		},
		{
			name: "health question",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "Is production infrastructure healthy right now?"},
			want: false,
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			prompt := watchPromptFor(svc, testCase.input)
			if got := strings.Contains(prompt, marker); got != testCase.want {
				t.Errorf("alert-language rules present = %t, want %t", got, testCase.want)
			}
			if !strings.Contains(prompt, replyShapeMarker) {
				t.Error("the turn lost the reply shape rules, which are not conditional")
			}
		})
	}
}

func TestGeneratedVisualRulesRideATurnThatAskedForOne(t *testing.T) {
	const marker = "When a user asks for a chart, image, or meme"
	cfg := serviceConfig(t)
	if cfg.Limits.MaxGeneratedVisuals <= 0 {
		t.Fatal("the test config grants no visual tool; this test would prove nothing")
	}
	withoutTool := cfg
	withoutTool.Limits.MaxGeneratedVisuals = 0
	for _, testCase := range []struct {
		name   string
		input  core.SlackInput
		noTool bool
		want   bool
	}{
		{
			name: "asks for a chart",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "Chart the checkout p99 for the last hour."},
			want: true,
		},
		{
			name: "asks for a graph",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "Can you make a graph of the error rate since the rollout?"},
			want: true,
		},
		{
			name: "asks for a meme",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "post a meme, we survived the migration"},
			want: true,
		},
		{
			// The capability gate is the older half of this predicate and still
			// wins: a deployment with no visual tool must not be told how to
			// label axes.
			name: "asks for a chart with no visual tool configured",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "Chart the checkout p99 for the last hour."},
			noTool: true,
			want:   false,
		},
		{
			name: "plain operational question",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "What is the disk usage on nomad-hvn03 right now?"},
			want: false,
		},
		{
			name: "compound read-only request",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "Check whether the latest emisar terraform change applied and " +
					"tell me what changed."},
			want: false,
		},
		{
			name: "recurring health check",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "Every morning, check production health for me."},
			want: false,
		},
		{
			name: "app alert",
			input: core.SlackInput{ChannelID: "C1", Kind: "bot_message", UserID: "U0APP",
				Text: "FIRING: production API returns HTTP 503 for 38% of requests"},
			want: false,
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			svc := &Service{cfg: cfg}
			if testCase.noTool {
				svc = &Service{cfg: withoutTool}
			}
			prompt := watchPromptFor(svc, testCase.input)
			if got := strings.Contains(prompt, marker); got != testCase.want {
				t.Errorf("generated-visual rules present = %t, want %t", got, testCase.want)
			}
		})
	}
}

func TestCompoundRequestRulesRideAMessageWithMoreThanOneInstruction(t *testing.T) {
	const marker = "Handle every explicit instruction in the current user message."
	svc := &Service{cfg: serviceConfig(t)}
	for _, testCase := range []struct {
		name  string
		input core.SlackInput
		want  bool
	}{
		{
			name: "two outcomes joined by and",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "Check whether the latest emisar terraform change applied and " +
					"tell me what changed."},
			want: true,
		},
		{
			name: "verify then record",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "Confirm the current uptime of nomad-hvn03 and record what you observed."},
			want: true,
		},
		{
			name: "fix and open a pull request",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "Fix one genuine typo in this repository and open a focused draft PR."},
			want: true,
		},
		{
			// Two questions sharing one question mark, and neither half is
			// imperative. This is why the auxiliary that opens a question counts
			// as an instruction opener.
			name: "two questions in one sentence",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "Did the GitHub Actions restart finish, and was the earlier failure " +
					"a Docker push networking timeout?"},
			want: true,
		},
		{
			// The production feedback message. Numbered items carry the compound
			// ask that no verb test finds: neither clause opens with a verb.
			name: "numbered list of corrections",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "feedback: 1. i told you to answer in thread; 2. i told you to " +
					"update channel memory so you do it next time"},
			want: true,
		},
		{
			name: "single question",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "What is the disk usage on nomad-hvn03 right now?"},
			want: false,
		},
		{
			name: "single explicit instruction",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "Open an incident for the recurring checkout 503 reports."},
			want: false,
		},
		{
			name: "single instruction with no verb repetition",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "Create reusable deep infrastructure health review runbook"},
			want: false,
		},
		{
			name: "recurring single instruction",
			input: core.SlackInput{ChannelID: "C1", UserID: "U123ABC",
				Text: "Every morning, check production health for me."},
			want: false,
		},
		{
			// An app issues no instructions, and this card would otherwise read
			// as three: every one of its lines opens with the verb `Run`. The
			// sender check is what keeps a Terraform notification from paying
			// 1,543 bytes to be told how to handle a compound request.
			name: "terraform run notification posted by an app",
			input: core.SlackInput{
				ChannelID: "C1", Kind: "bot_message", UserID: "U0APP",
				Text: "Run notification for SME-Blitz/blitz-infra\n" +
					"Run run-UBwFpsiiVMtXwtbi\nRun Planned - Needs Confirmation",
			},
			want: false,
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			prompt := watchPromptFor(svc, testCase.input)
			if got := strings.Contains(prompt, marker); got != testCase.want {
				t.Errorf("compound-request rules present = %t, want %t", got, testCase.want)
			}
		})
	}
}

// The watch section is budgeted against what follows it, not a fixed guess.
//
// This is the bug that was truncating production prompts. The section reserved
// a flat 8 KiB for its suffix; the real suffix reached about 14 KiB, so the
// assembled prompt exceeded Coop's cap and the transport cut the tail — which
// is where the episode contract, the tool rules and the decision correction
// live. The model was being corrected for failing a contract it had not been
// shown, by a correction at risk of being cut itself.
func TestWatchBudgetLeavesRoomForWhatFollowsIt(t *testing.T) {
	// A suffix and a section that together must fit under the transport cap.
	for _, suffix := range []int{0, 8 << 10, 14 << 10, 20 << 10} {
		budget := WatchPromptBudget(suffix)
		if budget+suffix > coop.MaxPromptBytes {
			t.Errorf("a %d byte suffix leaves a %d byte budget: %d total, over the %d cap",
				suffix, budget, budget+suffix, coop.MaxPromptBytes)
		}
	}

	// A suffix large enough to squeeze the section out entirely still leaves a
	// floor. Below it the context is too thin to answer from, and a turn that
	// cannot see the conversation should fail visibly rather than answer badly.
	if got := WatchPromptBudget(coop.MaxPromptBytes * 2); got != minimumWatchPromptBytes {
		t.Errorf("an oversized suffix gave budget %d, want the %d floor",
			got, minimumWatchPromptBytes)
	}

	// The old behaviour, stated so a regression is recognisable: against the
	// 64 KiB cap of the day, a fixed 56 KiB section plus the observed 14 KiB
	// suffix was 71,680 bytes — which is what production was actually
	// sending. The cap has since been raised, so the arithmetic is pinned to
	// the historical constant rather than the current one.
	const oldCap = 64 << 10
	const oldFixedBudget = 56 << 10
	if oldFixedBudget+(14<<10) <= oldCap {
		t.Fatal("this test no longer describes the bug it was written for")
	}
}
