package service

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
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
		[]conversationSituationContext{{
			ChannelID: "CDEPLOY", Repository: "emisar",
			Relationship: "same_repository",
			Summary: core.AgentMemory{
				Decisions: []string{"Keep the current release paused"},
			},
			UpdatedAt: "2026-07-30T12:00:00Z",
		}},
		operationalMemoryContext{},
		"emisar",
		nil,
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

func TestAssembleAgentContextUsesConversationSummaryAsThreadCursor(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.BindChannelSession(
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
	applied, err := st.ApplyWatchDecision(
		ctx,
		core.EvaluationDecision{
			ChannelID: "COPS", ThreadTS: "1700.000001",
			MessageTS: "1700.000020", Repository: "emisar",
			SourceInput: "prior-source", Mode: "live", Action: "reply",
		},
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
