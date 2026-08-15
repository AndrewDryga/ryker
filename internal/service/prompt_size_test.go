package service

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
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
	"watch": 43 * 1024,

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
	"watch-operator": 49*1024 + 256,
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
		{"behaviorOfferPolicy", len(behaviorOfferPolicy)},
		{"compoundRequestPolicy", len(compoundRequestPolicy)},
		{"emisarGovernedActionPolicy", len(emisarGovernedActionPolicy)},
		{"slackReplyFormattingPolicy", len(slackReplyFormattingPolicy)},
		{"investigation.ResultOperationsPrompt", len(investigation.ResultOperationsPrompt())},
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
}

func staticPromptSizes(t *testing.T) map[string]int {
	t.Helper()
	cfg := serviceConfig(t)
	svc := &Service{cfg: cfg}
	measure := func(userID string) int {
		return len(svc.unboundedWatchPrompt(
			core.SlackInput{ChannelID: "C1", Text: "check the api", UserID: userID},
			"U999BOT", false, nil, nil, core.AgentMemory{}, nil, nil,
			decisionpkg.OperationalMemoryContext{}, "emisar", nil,
			nil,
		))
	}
	return map[string]int{
		"watch":          measure(""),
		"watch-operator": measure(cfg.Slack.Operators[0]),
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
		"U999BOT", false, recent, nil, core.AgentMemory{}, related, nil, prior, "emisar", nil,
		WatchPromptBudget(0),
	)

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
		decisionpkg.OperationalMemoryContext{}, "emisar", nil,
		WatchPromptBudget(0),
	)
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
		return svc.unboundedWatchPrompt(
			input, "U999BOT", false, nil, nil, core.AgentMemory{}, nil, nil,
			decisionpkg.OperationalMemoryContext{}, "emisar", nil, nil,
		)
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
