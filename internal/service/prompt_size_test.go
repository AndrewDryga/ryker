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
	"watch": 42 * 1024,
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
	svc := &Service{cfg: serviceConfig(t)}
	return map[string]int{
		"watch": len(svc.unboundedWatchPrompt(
			core.SlackInput{ChannelID: "C1", Text: "check the api"},
			"U999BOT", false, nil, core.AgentMemory{}, nil, nil,
			decisionpkg.OperationalMemoryContext{}, "emisar", nil,
			nil,
		)),
	}
}

// When context does not fit, the assembler has to choose what to drop. The
// transport's fallback is to cut the middle out, which slices through the
// structured context block — so the only acceptable outcome here is a prompt
// that fits, still carries the target, and says what it lost.
func TestOversizedContextIsBudgetedNotSliced(t *testing.T) {
	svc := &Service{cfg: serviceConfig(t)}
	filler := strings.Repeat("saturated evidence detail ", 60)

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

	prompt := svc.watchPrompt(
		core.SlackInput{ChannelID: "C1", MessageTS: "1799.000", Text: "why is checkout failing"},
		"U999BOT", false, recent, core.AgentMemory{}, related, nil, prior, "emisar", nil,
	)

	if len(prompt) > maxAssembledWatchPromptBytes {
		t.Fatalf("budgeted prompt is %d bytes, over the %d bound",
			len(prompt), maxAssembledWatchPromptBytes)
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
	// The floor holds: the conversation nearest the target survives.
	if !strings.Contains(prompt, "only the 8 nearest the target remain") {
		t.Fatalf("the message floor was not applied:\n%s", omittedSection(t, prompt))
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
	prompt := svc.watchPrompt(
		core.SlackInput{ChannelID: "C1", MessageTS: "1799.000", Text: "status?"},
		"U999BOT", false, recent, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, "emisar", nil,
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
			input, "U999BOT", false, nil, core.AgentMemory{}, nil, nil,
			decisionpkg.OperationalMemoryContext{}, "emisar", nil, nil,
		)
	}

	ambient := build(core.SlackInput{ChannelID: "C1", Text: "is checkout slow?"})
	for _, absent := range []struct{ name, marker string }{
		{"scheduled occurrence", "sender_type is operator_schedule"},
		{"host recheck", "sender_type is host_recheck"},
		{"publication correlation", "trusted-active-publications"},
		{"behavior offers", "A configured operator may define typed Responder behavior"},
	} {
		if strings.Contains(ambient, absent.marker) {
			t.Errorf("the %s block was sent to a turn that cannot use it", absent.name)
		}
	}

	fromOperator := build(core.SlackInput{ChannelID: "C1", UserID: operator, Text: "remember this"})
	if !strings.Contains(fromOperator, "A configured operator may define typed Responder behavior") {
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
