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

// Covers finding: 20260811T195209Z-run_cf56b495201e401bcce3f7df8004c925
func TestPinnedTaskContextKeepsItsApprovedRepository(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Repositories["incident-repo"] = cfg.Repositories["repo"]
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "COPS", Participation: "proactive",
		Repository: "repo", AlertPolicy: "reply", ActorID: "U123ABC",
	}); err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	pinned, err := svc.assembleAgentContext(ctx, agentContextRequest{
		ChannelID: "COPS", Repository: "incident-repo", RepositoryPinned: true,
		OperatorID: "U123ABC", SourceInputID: "task-input",
	})
	if err != nil || pinned.Repository != "incident-repo" {
		t.Fatalf("pinned task context = %+v, %v", pinned, err)
	}
	unpinned, err := svc.assembleAgentContext(ctx, agentContextRequest{
		ChannelID: "COPS", Repository: "incident-repo",
		OperatorID: "U123ABC", SourceInputID: "conversation-input",
	})
	if err != nil || unpinned.Repository != "repo" {
		t.Fatalf("ordinary channel context = %+v, %v", unpinned, err)
	}
}

func TestLegacyIncidentContextRepositoryIsRecapturedAndPersisted(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Repositories["channel-repo"] = cfg.Repositories["repo"]
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: incident.ChannelID, Participation: "proactive",
		Repository: "channel-repo", AlertPolicy: "reply", ActorID: "U123ABC",
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(
		ctx, incident.ID, "ses_context_recapture", "context-recapture", 1,
	); err != nil {
		t.Fatal(err)
	}
	legacyContext := []byte(`{"repository":"channel-repo","captured_at":"2026-08-01T00:00:00Z"}`)
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: incident.ChannelID, ThreadTS: incident.RootTS,
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      "signal", SourceID: "legacy-context-signal",
		Repository: incident.Repository, Prompt: "investigate", Context: legacyContext,
	})
	if err != nil || !created {
		t.Fatalf("queue legacy context run = %+v, %t, %v", run, created, err)
	}
	coopClient := newFakeCoop()
	coopClient.session.ID = "ses_context_recapture"
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	assembled, captured := decodeAssembledAgentContext(stored.Context)
	if !captured || stored.Repository != incident.Repository ||
		assembled.Repository != incident.Repository || string(stored.Context) == string(legacyContext) {
		t.Fatalf("recaptured run = repository %q context %+v captured=%t", stored.Repository, assembled, captured)
	}
}

func TestLegacyIncidentRunRepositoryIsRepairedWhenContextIsAlreadyPinned(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Repositories["channel-repo"] = cfg.Repositories["repo"]
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_repository_repair", "repository-repair", 1); err != nil {
		t.Fatal(err)
	}
	pinnedContext := []byte(`{"repository":"repo","repository_pinned":true,"captured_at":"2026-08-01T00:00:00Z"}`)
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: incident.ChannelID, ThreadTS: incident.RootTS,
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      "signal", SourceID: "legacy-run-repository",
		Repository: "channel-repo", Prompt: "investigate", Context: pinnedContext,
	})
	if err != nil || !created {
		t.Fatalf("queue legacy repository run = %+v, %t, %v", run, created, err)
	}
	coopClient := newFakeCoop()
	coopClient.session.ID = "ses_repository_repair"
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.Repository != incident.Repository {
		t.Fatalf("repaired run repository = %+v, %v", stored, err)
	}
	assembled, captured := decodeAssembledAgentContext(stored.Context)
	if !captured || assembled.Repository != incident.Repository {
		t.Fatalf("preserved pinned context = %+v captured=%t", assembled, captured)
	}
}

func TestWatchPromptExplainsCrossConversationMemoryBoundary(t *testing.T) {
	prompt, _ := (&Service{}).watchPrompt(
		core.SlackInput{
			ChannelID: "COPS", ThreadTS: "1700.1", MessageTS: "1700.2",
			UserID: "U1", Text: "What did we decide?",
		},
		"UBOT",
		false,
		nil,
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
		nil,
		nil,
		nil,
		"emisar",
		nil,
		WatchPromptBudget(0))
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
	prompt, _ := svc.watchPrompt(
		input, "UBOT", false, nil, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, nil, nil, nil, "repo", nil,
		WatchPromptBudget(0))
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
	ordinary, _ := svc.watchPrompt(
		input, "UBOT", false, nil, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, nil, nil, nil, "repo", nil,
		WatchPromptBudget(0))
	if strings.Contains(ordinary, "explicit host verification replay") {
		t.Fatalf("ordinary prompt contains replay policy:\n%s", ordinary)
	}
}

func TestWatchPromptDropsOldestContextBeforeCoopLimit(t *testing.T) {
	// Each of the twenty messages is sized so the assembled prompt exceeds
	// the watch budget however large the transport cap grows.
	messageBytes := WatchPromptBudget(0) / 12
	unit := "old-alert-00 "
	recent := make([]decisionpkg.WatchContextMessage, 0, 20)
	for index := 0; index < 20; index++ {
		recent = append(recent, decisionpkg.WatchContextMessage{
			MessageTS: fmt.Sprintf("1700.%06d", index),
			SenderID:  "B_GRAFANA", SenderType: "external_app",
			Text: strings.Repeat(fmt.Sprintf("old-alert-%02d ", index), messageBytes/len(unit)),
		})
	}
	input := core.SlackInput{
		ID: "target-alert", Kind: "bot_message", ChannelID: "CALERTS",
		MessageTS: "1700.999999", UserID: "B_GRAFANA",
		Text: "CURRENT TARGET: allocation resident memory near limit",
	}
	svc := &Service{}
	raw := svc.unboundedWatchPrompt(
		input, "UBOT", false, recent, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, nil, nil, nil, "repo", nil,
		nil)
	if len(raw) <= WatchPromptBudget(0) {
		t.Fatalf("test prompt did not exceed assembly bound: %d", len(raw))
	}
	prompt, _ := svc.watchPrompt(
		input, "UBOT", false, recent, nil, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, nil, nil, nil, "repo", nil,
		WatchPromptBudget(0))
	if len(prompt) > WatchPromptBudget(0) {
		t.Fatalf("watch prompt bytes = %d", len(prompt))
	}
	if !strings.Contains(prompt, input.Text) || strings.Contains(prompt, "old-alert-00") {
		t.Fatalf("bounded watch prompt did not preserve target and drop oldest context")
	}
	if strings.LastIndex(prompt, `"target_message"`) < strings.LastIndex(prompt, `"recent_channel_messages"`) {
		t.Fatal("current target is not serialized after disposable recent context")
	}
}

// The channel around a thread's root is the first conversation layer the budget
// takes, and it says so when it does.
//
// It is context for a reference the operator may not have made; the thread is
// the conversation actually being answered. A budget that trimmed the thread
// first to keep messages from outside it would answer a question nobody asked
// with the evidence for one they did — so the surround goes entirely, oldest
// first, before a single in-thread message is dropped, and the omission is
// recorded rather than left as a silently thinner prompt.
func TestTheChannelAroundTheRootIsDroppedBeforeAnyThreadMessage(t *testing.T) {
	fill := func(prefix string, index int, size int) string {
		unit := fmt.Sprintf("%s-%02d ", prefix, index)
		return strings.Repeat(unit, size/len(unit))
	}
	recent := make([]decisionpkg.WatchContextMessage, 0, 12)
	for index := range 12 {
		recent = append(recent, decisionpkg.WatchContextMessage{
			MessageTS: fmt.Sprintf("1700.%06d", index),
			ThreadTS:  "1700.000000",
			SenderID:  "U123ABC", SenderType: "human",
			Text: fill("in-thread", index, 200),
		})
	}
	around := make([]decisionpkg.WatchContextMessage, 0, 6)
	for index := range 6 {
		around = append(around, decisionpkg.WatchContextMessage{
			MessageTS: fmt.Sprintf("1699.%06d", index),
			SenderID:  "B_GRAFANA", SenderType: "external_app",
			Text: fill("around-root", index, 2048),
		})
	}
	input := core.SlackInput{
		ID: "target-followup", Kind: "mention", ChannelID: "CALERTS",
		ThreadTS: "1700.000000", MessageTS: "1700.999999", UserID: "U123ABC",
		Text: "CURRENT TARGET: see in the channel above",
	}
	svc := &Service{}
	assembled := func(around []decisionpkg.WatchContextMessage) int {
		return len(svc.unboundedWatchPrompt(
			input, "UBOT", false, recent, around, core.AgentMemory{}, nil, nil,
			decisionpkg.OperationalMemoryContext{}, nil, nil, nil, "repo", nil, nil))
	}
	// Budgeted so that dropping exactly the oldest channel message fits, with
	// room for the omission note the drop itself adds. Anything the assembler
	// takes beyond that one message is a layer it should not have reached.
	budget := assembled(around[1:]) + 512
	if assembled(around) <= budget {
		t.Fatalf("the fixture fits with nothing dropped: %d bytes", assembled(around))
	}
	prompt, omitted := svc.watchPrompt(
		input, "UBOT", false, recent, around, core.AgentMemory{}, nil, nil,
		decisionpkg.OperationalMemoryContext{}, nil, nil, nil, "repo", nil,
		budget)
	if len(prompt) > budget {
		t.Fatalf("watch prompt bytes = %d, budget %d", len(prompt), budget)
	}
	if strings.Contains(prompt, "around-root-00") {
		t.Fatal("the oldest channel message around the root survived the budget")
	}
	if !strings.Contains(prompt, "around-root-05") {
		t.Fatal("the channel messages nearest the root were dropped before the oldest")
	}
	if !strings.Contains(prompt, "in-thread-00") {
		t.Fatal("an in-thread message was dropped while the channel around it was still carried")
	}
	var reason string
	for _, omission := range omitted {
		if omission.Kind == "channel_around_thread_root" {
			reason = omission.Reason
		}
		if omission.Kind == "channel_history" {
			t.Fatalf("the thread transcript was trimmed too: %+v", omitted)
		}
	}
	if reason == "" {
		t.Fatalf("the channel around the root was dropped silently: %+v", omitted)
	}
	if !strings.Contains(prompt, reason) {
		t.Fatalf("the model was not told what it is missing: %q", reason)
	}
}

// A brand new thread inherits what the channel already knows.
//
// The assembler loaded the channel situation and then, twenty lines later,
// zeroed it for any target carrying a thread timestamp with no conversation
// memory of its own — which is every thread on its first reply. So the one turn
// most likely to be a follow-up to work Responder had just done in that channel
// was also the only turn that started with nothing.
func TestANewThreadKeepsTheChannelSituationItHasNoMemoryOf(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.Intelligence.BindChannelSession(
		ctx, "COPS", "emisar", "session-context", 1, 1, time.Now().UTC(),
	); err != nil {
		t.Fatal(err)
	}
	// No ThreadTS: this is the channel-level write, not a conversation.
	applied, err := st.Intelligence.ApplyWatchDecision(
		ctx,
		core.EvaluationDecision{
			ChannelID: "COPS", MessageTS: "1700.000010", Repository: "emisar",
			SourceInput: "channel-source", Mode: "live", Action: "reply",
		},
		"investigation",
		2,
		core.AgentMemory{SituationSummary: "Cassandra disk latency alerts are being tuned."},
	)
	if err != nil || !applied {
		t.Fatalf("apply channel summary = %t, %v", applied, err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	target := core.SlackInput{
		ID: "target", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COPS", ThreadTS: "1700.000099",
		MessageTS: "1700.000100", UserID: "U1",
		Text: "<@UBOT> is that still happening?",
	}
	assembled, err := svc.assembleAgentContext(ctx, agentContextRequest{
		ChannelID: "COPS", Repository: "emisar", OperatorID: "U1",
		SourceInputID: target.ID, TargetInput: &target,
	})
	if err != nil {
		t.Fatal(err)
	}
	if assembled.Situation.SituationSummary !=
		"Cassandra disk latency alerts are being tuned." {
		t.Fatalf("new thread started blind: %+v", assembled.Situation)
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
	if len(slack.historyRequests) != 2 ||
		slack.historyRequests[0].thread != target.ThreadTS ||
		slack.historyRequests[0].since != "1700.000020" ||
		slack.historyRequests[0].target != target.MessageTS {
		t.Fatalf("history request = %+v", slack.historyRequests)
	}
	// The second read is the channel around the thread's root, and the cursor
	// does not travel with it: "the last message this thread saw" says nothing
	// about the channel above it, and applying it there would return an empty
	// surround for every thread Responder has already answered in.
	surround := slack.historyRequests[1]
	if surround.thread != "" || surround.target != target.ThreadTS ||
		surround.since != "" {
		t.Fatalf("channel-around-root request = %+v", surround)
	}
}
