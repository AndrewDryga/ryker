package service

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestMergeSlackContextCentersTargetAndExcludesOtherThreads(t *testing.T) {
	target := core.SlackInput{
		ID: "target", ChannelID: "COPS", ThreadTS: "1700.000001",
		MessageTS: "1700.000026", UserID: "U1", Text: "target",
	}
	history := []slackui.HistoryMessage{{
		Timestamp: target.ThreadTS, UserID: "UROOT", Text: "thread root",
	}}
	for index := 2; index <= 30; index++ {
		history = append(history, slackui.HistoryMessage{
			Timestamp: fmt.Sprintf("1700.%06d", index),
			ThreadTS:  target.ThreadTS,
			UserID:    "U1",
			Text:      fmt.Sprintf("reply %d", index),
		})
	}
	admitted := []core.SlackInput{
		{
			ID: "following", ChannelID: target.ChannelID, ThreadTS: target.ThreadTS,
			MessageTS: "1700.000027", UserID: "U2", Text: "following reply",
		},
		{
			ID: "unrelated", ChannelID: target.ChannelID, ThreadTS: "1700.900000",
			MessageTS: "1700.900001", UserID: "U3", Text: "unrelated thread",
		},
	}
	context := mergeSlackContext(admitted, history, target, 6)
	if len(context) != 6 {
		t.Fatalf("context length = %d: %+v", len(context), context)
	}
	if context[0].Text != "thread root" || context[len(context)-1].Text != "reply 29" {
		t.Fatalf("target-centered context = %+v", context)
	}
	foundTarget := false
	foundFollowing := false
	for _, input := range context {
		if input.Text == "unrelated thread" {
			t.Fatalf("unrelated thread leaked into context: %+v", context)
		}
		foundTarget = foundTarget || input.ID == target.ID
		foundFollowing = foundFollowing || input.Text == "following reply"
	}
	if !foundTarget || !foundFollowing {
		t.Fatalf("target or immediate following reply missing: %+v", context)
	}
}

func TestWatchPromptExplainsCrossConversationMemoryBoundary(t *testing.T) {
	prompt := (&Service{}).watchPrompt(
		core.SlackInput{
			ChannelID: "COPS", ThreadTS: "1700.1", MessageTS: "1700.2",
			UserID: "U1", Text: "What did we decide?",
		},
		"UBOT",
		false,
		nil,
		core.AgentMemory{SituationSummary: "Current thread summary"},
		[]decisionpkg.ConversationSituationContext{{
			ChannelID: "CDEPLOY", Repository: "emisar",
			Relationship: "same_repository",
			Summary: core.AgentMemory{
				Decisions: []string{"Keep the current release paused"},
			},
			UpdatedAt: "2026-07-30T12:00:00Z",
		}},
		nil,
		decisionpkg.OperationalMemoryContext{},
		"emisar",
		nil,
		watchPromptBudget(0),
	)
	for _, required := range []string{
		"compact summary of this exact Slack conversation",
		"compact summaries from other recent conversations",
		"same_repository",
		"Keep the current release paused",
		"without pretending they are fresh operational proof",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("prompt missing %q:\n%s", required, prompt)
		}
	}
}

func TestWatchPromptMakesVerificationReplayExecuteOriginalRequest(t *testing.T) {
	svc := &Service{}
	input := core.SlackInput{
		EnvelopeID: "replay:slack_replay_1", ChannelID: "COPS",
		MessageTS: "1700.2", UserID: "U1", Text: "Check production health",
	}
	prompt := svc.watchPrompt(
		input, "UBOT", false, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, "repo", nil,
		watchPromptBudget(0),
	)
	for _, required := range []string{
		"explicit host verification replay",
		"Re-execute the",
		"original target request now with fresh evidence",
		"must not cause action=ignore",
	} {
		if !strings.Contains(prompt, required) {
			t.Fatalf("replay prompt missing %q:\n%s", required, prompt)
		}
	}

	input.EnvelopeID = "env:ordinary"
	ordinary := svc.watchPrompt(
		input, "UBOT", false, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, "repo", nil,
		watchPromptBudget(0),
	)
	if strings.Contains(ordinary, "explicit host verification replay") {
		t.Fatalf("ordinary prompt contains replay policy:\n%s", ordinary)
	}
}

func TestWatchPromptDropsOldestContextBeforeCoopLimit(t *testing.T) {
	recent := make([]decisionpkg.WatchContextMessage, 0, 20)
	for index := 0; index < 20; index++ {
		recent = append(recent, decisionpkg.WatchContextMessage{
			MessageTS: fmt.Sprintf("1700.%06d", index),
			SenderID:  "B_GRAFANA", SenderType: "external_app",
			Text: strings.Repeat(fmt.Sprintf("old-alert-%02d ", index), 260),
		})
	}
	input := core.SlackInput{
		ID: "target-alert", Kind: "bot_message", ChannelID: "CALERTS",
		MessageTS: "1700.999999", UserID: "B_GRAFANA",
		Text: "CURRENT TARGET: allocation resident memory near limit",
	}
	svc := &Service{}
	raw := svc.unboundedWatchPrompt(
		input, "UBOT", false, recent, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, "repo", nil,
		nil,
	)
	if len(raw) <= watchPromptBudget(0) {
		t.Fatalf("test prompt did not exceed assembly bound: %d", len(raw))
	}
	prompt := svc.watchPrompt(
		input, "UBOT", false, recent, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, "repo", nil,
		watchPromptBudget(0),
	)
	if len(prompt) > watchPromptBudget(0) {
		t.Fatalf("watch prompt bytes = %d", len(prompt))
	}
	if !strings.Contains(prompt, input.Text) || strings.Contains(prompt, "old-alert-00") {
		t.Fatalf("bounded watch prompt did not preserve target and drop oldest context")
	}
	if strings.LastIndex(prompt, `"target_message"`) < strings.LastIndex(prompt, `"recent_channel_messages"`) {
		t.Fatal("current target is not serialized after disposable recent context")
	}
}

func TestAssembleAgentContextUsesConversationSummaryAsThreadCursor(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.Intelligence.BindChannelSession(
		ctx,
		"COPS",
		"emisar",
		"session-context",
		1,
		1,
		time.Now().UTC(),
	); err != nil {
		t.Fatal(err)
	}
	applied, err := st.Intelligence.ApplyWatchDecision(
		ctx,
		core.EvaluationDecision{
			ChannelID: "COPS", ThreadTS: "1700.000001",
			MessageTS: "1700.000020", Repository: "emisar",
			SourceInput: "prior-source", Mode: "live", Action: "reply",
		},
		"investigation",
		2,
		core.AgentMemory{
			SituationSummary: "The deploy is paused pending database verification.",
		},
	)
	if err != nil || !applied {
		t.Fatalf("apply prior summary = %t, %v", applied, err)
	}
	slack := &fakeSlack{history: []slackui.HistoryMessage{{
		Timestamp: "1700.000021", ThreadTS: "1700.000001",
		UserID: "U1", Text: "What happened with the database?",
	}}}
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		slack,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	target := core.SlackInput{
		ID: "target", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", ThreadTS: "1700.000001",
		MessageTS: "1700.000021", UserID: "U1",
		Text: "<@UBOT> What happened with the database?",
	}
	assembled, err := svc.assembleAgentContext(
		ctx,
		agentContextRequest{
			ChannelID: "COPS", Repository: "emisar", OperatorID: "U1",
			SourceInputID: target.ID, TargetInput: &target, IncludeRecent: true,
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if assembled.Situation.SituationSummary !=
		"The deploy is paused pending database verification." {
		t.Fatalf("conversation summary = %+v", assembled.Situation)
	}
	if len(slack.historyRequests) != 1 ||
		slack.historyRequests[0].since != "1700.000020" ||
		slack.historyRequests[0].target != target.MessageTS {
		t.Fatalf("history request = %+v", slack.historyRequests)
	}
}
