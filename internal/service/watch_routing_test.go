package service

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestWatchedEngineeringRequestRequiresRepositoryWhenSeveralAreConfigured(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Repositories["backend"] = config.Repository{
		DisplayName: "Backend",
		CoopPolicy:  "backend-observe",
	}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{dedupePosts: true}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
			"action":"reply",
			"attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3},
			"message":"I can make that repository change.",
		"task_title":"Update deployment packs"
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID: "slack-ambiguous-repository", EnvelopeID: "env-ambiguous-repository",
		EventID: "event-ambiguous-repository", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.950", UserID: "U123ABC",
		Text: "Update the deployment packs.",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 ||
		len(slackClient.posts[0].message.Actions) != 0 ||
		!strings.Contains(slackClient.posts[0].message.Text, "Which configured repository") ||
		!strings.Contains(slackClient.posts[0].message.Text, "Backend (`backend`)") ||
		!strings.Contains(slackClient.posts[0].message.Text, "Repository (`repo`)") {
		t.Fatalf("ambiguous repository response = %+v", slackClient.posts)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", source.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(run)
	if err != nil {
		t.Fatal(err)
	}
	if state.OfferedTaskTitle != "" || state.OfferedTaskRepository != "" {
		t.Fatalf("ambiguous task offer was persisted: %+v", state)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("ambiguous task started work: %+v, %v", incidents, err)
	}
}

func TestWatchedDecisionReceivesFreshChronologicalChannelContext(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	inputs := []core.SlackInput{
		{
			ID: "slack-context-3", EnvelopeID: "env-context-3", EventID: "EvContext3",
			Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
			MessageTS: "1700000000.000003", UserID: "U333",
			Text: "Yes, I am checking it now.",
		},
		{
			ID: "slack-context-1", EnvelopeID: "env-context-1", EventID: "EvContext1",
			Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
			MessageTS: "1700000000.000001", UserID: "U111",
			Text: "Can someone review the deploy?",
		},
		{
			ID: "slack-context-2", EnvelopeID: "env-context-2", EventID: "EvContext2",
			Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
			MessageTS: "1700000000.000002", UserID: "U222",
			Text: "<@U333> do you know what changed?",
		},
	}
	for _, input := range inputs {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", input.ID, created, err)
		}
	}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{"action":"ignore"}`
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(coopClient.submitPrompts) != 1 {
		t.Fatalf("submitted prompts = %d", len(coopClient.submitPrompts))
	}
	prompt := coopClient.submitPrompts[0]
	start := strings.Index(prompt, "<untrusted-slack-context>\n")
	end := strings.Index(prompt, "\n</untrusted-slack-context>")
	if start < 0 || end <= start {
		t.Fatalf("prompt has no bounded context: %s", prompt)
	}
	var evidence struct {
		TargetMessage  decisionpkg.WatchContextMessage   `json:"target_message"`
		RecentMessages []decisionpkg.WatchContextMessage `json:"recent_channel_messages"`
	}
	start += len("<untrusted-slack-context>\n")
	if err := json.Unmarshal([]byte(prompt[start:end]), &evidence); err != nil {
		t.Fatal(err)
	}
	if evidence.TargetMessage.Text != inputs[1].Text ||
		len(evidence.RecentMessages) != 3 {
		t.Fatalf("watch evidence = %+v", evidence)
	}
	wantTexts := []string{inputs[1].Text, inputs[2].Text, inputs[0].Text}
	for i, want := range wantTexts {
		if evidence.RecentMessages[i].Text != want {
			t.Fatalf("recent message %d = %+v, want %q",
				i, evidence.RecentMessages[i], want)
		}
	}
	if !evidence.RecentMessages[0].Target ||
		evidence.RecentMessages[1].MentionsResponder ||
		!strings.Contains(prompt, "people are talking to each other") ||
		!strings.Contains(prompt, "newer human message already answers the target") {
		t.Fatalf("conversation targeting guidance = %+v", evidence)
	}
	first, err := st.GetSlackInput(ctx, "slack-context-1")
	if err != nil || first.State != "done" {
		t.Fatalf("oldest source message was not processed first: %+v, %v", first, err)
	}
	for _, id := range []string{"slack-context-2", "slack-context-3"} {
		item, err := st.GetSlackInput(ctx, id)
		if err != nil || item.State != "pending" {
			t.Fatalf("later source message %s overtook target: %+v, %v", id, item, err)
		}
	}
}

func TestProactiveAttentionCanAcknowledgeWithoutPosting(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-react", EnvelopeID: "env-react", EventID: "EvReact",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700000000.000010", UserID: "U123ABC",
		Text: "The production rollout is complete and all checks passed.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit message = %v, %v", created, err)
	}
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
		"action":"react",
		"reaction":"tada",
		"attention":{
			"addressee":"channel",
			"urgency":1,
			"confidence":3,
			"novelty":1,
			"ownership":1
		},
		"reason":"Acknowledge the completed handoff without interrupting the channel."
	}`
	svc := New(
		cfg,
		st,
		coopClient,
		slackClient,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.reactions) != 1 ||
		slackClient.reactions[0].channel != input.ChannelID ||
		slackClient.reactions[0].timestamp != input.MessageTS ||
		slackClient.reactions[0].name != "tada" {
		t.Fatalf("reactions = %+v", slackClient.reactions)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("reaction-only decision posted a message: %+v", slackClient.posts)
	}
}

func TestWatchedDecisionWaitsForNearbyConversation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Slack.WatchSettleDelay.Duration = 5 * time.Second
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-settle", EnvelopeID: "env-settle", EventID: "EvSettle",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700000000.000001", UserID: "U111", Text: "Is the deploy okay?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	run, runErr := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || stored.State != "done" || runErr != nil ||
		run.State != core.AgentRunPending ||
		!run.NextAttemptAt.After(time.Now()) ||
		len(coopClient.createKeys) != 0 {
		t.Fatalf("settling input = %+v, Coop creates=%v, error=%v",
			stored, coopClient.createKeys, err)
	}
}

func TestLateWatchedMessageCannotRespondAfterNewerDecision(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	newer := core.SlackInput{
		ID: "slack-late-new", EnvelopeID: "env-late-new", EventID: "EvLateNew",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700000000.000002", UserID: "U222", Text: "Newer event",
	}
	if created, err := st.AdmitSlackInput(ctx, newer); err != nil || !created {
		t.Fatalf("admit newer = %v, %v", created, err)
	}
	leased, err := st.LeaseSlackInput(ctx)
	if err != nil || leased.ID != newer.ID {
		t.Fatalf("lease newer = %+v, %v", leased, err)
	}
	if err := st.Audit(ctx, core.AuditEvent{
		Kind: "slack.watch", ObjectID: "slack-late-new", Outcome: "ignored",
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackInput(ctx, newer.ID); err != nil {
		t.Fatal(err)
	}
	older := core.SlackInput{
		ID: "slack-late-old", EnvelopeID: "env-late-old", EventID: "EvLateOld",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700000000.000001", UserID: "U111", Text: "Old delayed event",
	}
	if created, err := st.AdmitSlackInput(ctx, older); err != nil || !created {
		t.Fatalf("admit older = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetSlackInput(ctx, "slack-late-old")
	if err != nil || stored.State != "done" || len(coopClient.createKeys) != 0 {
		t.Fatalf("late input = %+v, Coop creates=%v, error=%v",
			stored, coopClient.createKeys, err)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", older.ID)
	if err != nil || run.State != core.AgentRunSuperseded {
		t.Fatalf("late run = %+v, %v", run, err)
	}
}

func TestWatchedTurnResumesFromDurableState(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.submitState = "starting"
	input := core.SlackInput{
		ID: "slack-watch-resume", EnvelopeID: "env-watch-resume", EventID: "EvWatchResume",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.600", UserID: "U123ABC", Text: "Did the deploy recover?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	firstSlack := &fakeSlack{}
	svc := New(cfg, st, coopClient, firstSlack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	run, runErr := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || stored.State != "done" || runErr != nil ||
		run.State != core.AgentRunRunning || len(run.Context) == 0 {
		t.Fatalf("running watch input = %+v, %v", stored, err)
	}
	if len(firstSlack.statuses) != 0 {
		t.Fatalf("ambient triage exposed a thread status: %+v", firstSlack.statuses)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}

	coopClient.complete(`{"action":"reply","attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3},"message":"Yes, the deploy recovered."}`)
	st, err = store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc = New(cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	stored, err = st.GetSlackInput(ctx, input.ID)
	if err != nil || stored.State != "done" || len(slack.posts) != 1 {
		t.Fatalf("resumed watch input = %+v, posts=%+v, %v", stored, slack.posts, err)
	}
	if len(slack.statuses) != 0 {
		t.Fatalf("resumed ambient triage exposed a thread status: %+v", slack.statuses)
	}
	if len(coopClient.createKeys) != 1 || len(coopClient.submitKeys) != 1 {
		t.Fatalf("durable state replayed Coop mutations: create=%v submit=%v",
			coopClient.createKeys, coopClient.submitKeys)
	}
}

func TestLongWatchedRunDoesNotConsumeInputRetriesOrBlockLaterContext(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.submitState = "running"
	svc := New(
		cfg,
		st,
		coopClient,
		&fakeSlack{},
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT",
	}
	first := core.SlackInput{
		ID: "slack-long-first", EnvelopeID: "env-long-first",
		EventID: "EvLongFirst", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.100", UserID: "U111",
		Text: "The deploy started.",
	}
	second := core.SlackInput{
		ID: "slack-long-second", EnvelopeID: "env-long-second",
		EventID: "EvLongSecond", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.200", UserID: "U222",
		Text: "It completed successfully.",
	}
	for _, input := range []core.SlackInput{first, second} {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %t, %v", input.ID, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", input.ID, err)
		}
		if input.ID == first.ID {
			if err := svc.processAgentRun(ctx); err != nil {
				t.Fatal(err)
			}
		}
	}
	for range cfg.Limits.MaxSlackInputAttempts + 5 {
		svc.pollAgentRuns(ctx)
	}
	storedFirst, err := st.GetSlackInput(ctx, first.ID)
	if err != nil || storedFirst.State != "done" || storedFirst.Failures != 0 {
		t.Fatalf("long-running source input = %+v, %v", storedFirst, err)
	}
	firstRun, err := st.GetAgentRunBySource(ctx, "watch", first.ID)
	if err != nil || firstRun.State != core.AgentRunRunning ||
		firstRun.Failures != 0 {
		t.Fatalf("long-running agent run = %+v, %v", firstRun, err)
	}
	secondRun, err := st.GetAgentRunBySource(ctx, "watch", second.ID)
	if err != nil || secondRun.State != core.AgentRunPending {
		t.Fatalf("later message run = %+v, %v", secondRun, err)
	}
	if err := svc.processAgentRun(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("later run bypassed per-conversation serialization: %v", err)
	}

	coopClient.complete(`{"action":"ignore","reason":"superseded by the successful completion"}`)
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	secondRun, err = st.GetAgentRunBySource(ctx, "watch", second.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(secondRun)
	if err != nil {
		t.Fatal(err)
	}
	if len(state.RecentMessages) < 2 ||
		state.RecentMessages[len(state.RecentMessages)-2].Text != first.Text ||
		state.RecentMessages[len(state.RecentMessages)-1].Text != second.Text {
		t.Fatalf("later run context is not ordered and fresh: %+v", state.RecentMessages)
	}
}

func TestWatchedRunRepairsStaleRotatedEventCursor(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT",
	}
	input := core.SlackInput{
		ID: "slack-stale-cursor", EnvelopeID: "env-stale-cursor",
		EventID: "EvStaleCursor", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", ThreadTS: "1700.001", MessageTS: "1700.002",
		UserID: "U123ABC", Text: "<@U999BOT> can you review it?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.AdvanceAgentRunEvents(ctx, run.ID, 13); err != nil {
		t.Fatal(err)
	}
	if err := st.AdvanceChannelEvents(
		ctx, input.ChannelID, run.SessionID, 13,
	); err != nil {
		t.Fatal(err)
	}
	coopClient.complete(`{"action":"reply","attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":3},"message":"The Terraform plan is safe to apply."}`)
	coopClient.session.LastEventSequence = 1
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	run, err = st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || run.State != core.AgentRunCompleted ||
		run.CoopEventSequence != 1 {
		t.Fatalf("recovered run = %+v, %v", run, err)
	}
	memory, err := st.GetChannelMemory(ctx, input.ChannelID)
	if err != nil || memory.CoopEventSequence != 1 {
		t.Fatalf("repaired channel memory = %+v, %v", memory, err)
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "Terraform plan") {
		t.Fatalf("recovered Slack posts = %+v", slackClient.posts)
	}
}

func TestParseWatchDecisionIsStrict(t *testing.T) {
	valid := []string{
		`{"action":"ignore"}`,
		"```json\n{\"action\":\"ignore\"}\n```",
		`{"action":"ignore","publication_updates":[{"incident_id":"inc_123","kind":"deployment","state":"succeeded","reference":"0123456","summary":"Production rollout completed."}]}`,
		`{"action":"react","reaction":"eyes","attention":{"addressee":"channel","urgency":1,"confidence":3,"novelty":1,"ownership":1}}`,
		`{"action":"react","reaction":"thumbsup"}`,
		`{"action":"react","reaction":"wave::skin-tone-3"}`,
		`{"action":"react","reaction":":deployment_parrot:"}`,
		`{"action":"reply","message":"I am looking at it."}`,
		`{"action":"reply","message":"Waiting for Emisar approval.","pending_approval":{"request_id":"apr_1","run_id":"run_1","operation_id":"op_1","action_id":"service.enable","pack_ref":"service@1#sha256:abc","runner_ref":"prod~abc","status":"pending_approval","approval_url":"https://emisar.dev/app/acme/approvals/apr_1","expires_at":"2099-08-01T00:00:00Z"}}`,
		`{"action":"reply","message":"Two runners are offline.","incident_title":"Two runners offline"}`,
		`{"action":"reply","message":"I can make that change.","task_title":"Audit infrastructure packs","task_repository":"repo","memory":{"topology":{"portal_hosts_declared":2,"runner_mapping":"Two current runners"}}}`,
		`{"action":"reply","message":"The issue is bounded.","incident_title":"Coordinate API degradation","task_title":"Fix API decoder","task_repository":"repo","task_prompt":"Update the decoder to fail soft on unknown values and run focused tests.","alert_assessment":{"verdict":"confirmed_issue","impact":"API requests fail.","cause_status":"identified","cause":"The decoder rejects a new upstream value.","immediate_action":"Fail soft on the new value.","verification":"Confirm the exact error disappears.","long_term_solution":"Use forward-compatible decoding."},"completion":{"status":"decision_ready","summary":"The failure is bounded."},"evidence":[{"claim":"the decoder is strict","observation":"the repository decoder enumerates rank values","source_type":"repository","source_name":"lib/rank.ex"}]}`,
		`{"action":"incident","title":"API unavailable"}`,
	}
	for _, input := range valid {
		if _, err := decisionpkg.ParseWatchDecision(input, testDecodeClock); err != nil {
			t.Fatalf("valid decision %s: %v", input, err)
		}
	}
	invalid := []string{
		`{"action":"ignore","message":"no"}`,
		`{"action":"reply","message":""}`,
		`{"action":"incident"}`,
		`{"action":"incident","title":"API unavailable","incident_title":"duplicate"}`,
		`{"action":"reply","message":"Choose a repository.","task_repository":"repo"}`,
		`{"action":"reply","message":"Prepare it.","task_title":"Fix it","task_repository":"repo","task_prompt":"Change the code."}`,
		`{"action":"reply","message":"Prepare it.","task_prompt":"Change the code."}`,
		`{"action":"reply","message":"Prepare it.","task_title":"Fix it","task_repository":"repo","task_prompt":"Change the code.","alert_assessment":{"verdict":"confirmed_issue","impact":"Requests fail.","cause_status":"identified","cause":"The decoder rejects a value.","immediate_action":"Fail soft.","verification":"Confirm errors stop.","long_term_solution":"Use forward-compatible decoding."},"completion":{"status":"decision_ready","summary":"The failure is bounded."},"evidence":[{"claim":"requests fail","observation":"fresh logs contain failures","source_type":"emisar","source_name":"logs"}]}`,
		`{"action":"ignore","unknown":true}`,
		`{"action":"ignore","publication_updates":[{"incident_id":"inc_123","kind":"build","state":"succeeded","reference":"0123456","summary":"Build completed."}]}`,
		`{"action":"ignore","publication_updates":[{"incident_id":"inc_123","kind":"terraform","state":"maybe","reference":"0123456","summary":"Plan changed."}]}`,
		`{"action":"ignore","publication_updates":[{"incident_id":"inc_123","kind":"terraform","state":"pending","reference":"repo","summary":""}]}`,
		`{"action":"react","reaction":"✅"}`,
		`{"action":"react","reaction":"wave::skin-tone-9"}`,
		`{"action":"react","reaction":"not/an/emoji"}`,
		`{"action":"react","reaction":"eyes","message":"also replying"}`,
		`{"action":"ignore","pending_approval":{"request_id":"apr_1"}}`,
		`{"action":"reply","message":"Waiting.","incident_title":"Open it","pending_approval":{"request_id":"apr_1"}}`,
		`{"action":"ignore","attention":{"addressee":"team","urgency":1,"confidence":1,"novelty":1,"ownership":1}}`,
		`{"action":"ignore","attention":{"addressee":"channel","urgency":4,"confidence":1,"novelty":1,"ownership":1}}`,
		`{"action":"ignore"} {"action":"ignore"}`,
	}
	for _, input := range invalid {
		if _, err := decisionpkg.ParseWatchDecision(input, testDecodeClock); err == nil {
			t.Fatalf("invalid decision accepted: %s", input)
		}
	}
}

func TestParseWatchDecisionAcceptsEmptyOptionalObservationTimestamps(t *testing.T) {
	decision, err := decisionpkg.ParseWatchDecision(`{
		"action":"reply",
		"message":"The live layer is healthy; the declared layer has no source timestamp.",
		"attention":{"addressee":"responder","confidence":3,"ownership":3},
		"evidence":[
			{
				"claim":"Topology is declared",
				"observation":"Two instances",
				"source_type":"repository",
				"source_name":"infra/main.tf",
				"observed_at":""
			},
			{
				"claim":"Two runners are connected",
				"observation":"Both responded",
				"source_type":"emisar",
				"source_name":"Emisar list_runners",
				"observed_at":"2026-07-30T07:00:00Z"
			}
		],
		"coverage":[
			{"layer":"change","status":"unknown","observed_at":""},
			{"layer":"runtime","status":"healthy","observed_at":"2026-07-30T07:00:00Z"}
		],
		"memory":{}
	}`, testDecodeClock)
	if err != nil {
		t.Fatal(err)
	}
	if len(decision.Evidence) != 2 || !decision.Evidence[0].ObservedAt.IsZero() ||
		len(decision.Coverage) != 2 || !decision.Coverage[0].ObservedAt.IsZero() {
		t.Fatalf("empty optional timestamps were not normalized: %+v", decision)
	}
}

func TestSlackReactionNameNormalization(t *testing.T) {
	valid := map[string]string{
		" TADA ":               "tada",
		":white_check_mark:":   "white_check_mark",
		"+1":                   "+1",
		"wave::skin-tone-6":    "wave::skin-tone-6",
		":deployment_parrot:":  "deployment_parrot",
		"custom-release-ready": "custom-release-ready",
	}
	for input, want := range valid {
		got, err := decisionpkg.NormalizeSlackReactionName(input)
		if err != nil {
			t.Fatalf("normalize %q: %v", input, err)
		}
		if got != want {
			t.Fatalf("normalize %q = %q, want %q", input, got, want)
		}
	}

	invalid := []string{
		"",
		"✅",
		"wave::skin-tone-1",
		"wave::skin-tone-7",
		"not/an/emoji",
		strings.Repeat("a", 256),
	}
	for _, input := range invalid {
		if got, err := decisionpkg.NormalizeSlackReactionName(input); err == nil {
			t.Fatalf("normalize %q = %q, want error", input, got)
		}
	}
}

func TestAttentionPolicySuppressesLowValueAmbientInterruptions(t *testing.T) {
	input := core.SlackInput{Kind: "message", ChannelID: "CINFRA"}
	decision := decisionpkg.WatchDecision{
		Action:  "reply",
		Message: "I can add something.",
		Attention: decisionpkg.AttentionAssessment{
			Addressee: "human", Urgency: 1, Confidence: 3, Novelty: 1, Ownership: 1,
		},
	}
	filtered := decisionpkg.EnforceAttentionPolicy(input, decisionpkg.WatchTurnState{}, decision, 7, 4)
	if filtered.Action != "ignore" || filtered.Message != "" ||
		!strings.Contains(filtered.Reason, "suppressed") {
		t.Fatalf("filtered decision = %+v", filtered)
	}

	input.Kind = "mention"
	filtered = decisionpkg.EnforceAttentionPolicy(input, decisionpkg.WatchTurnState{}, decision, 7, 4)
	if filtered.Action != "reply" || filtered.Message == "" {
		t.Fatalf("explicit mention was suppressed: %+v", filtered)
	}

	input.Kind = "message"
	decision.Attention = decisionpkg.AttentionAssessment{}
	filtered = decisionpkg.EnforceAttentionPolicy(input, decisionpkg.WatchTurnState{}, decision, 7, 4)
	if filtered.Action != "ignore" {
		t.Fatalf("ambient action without assessment = %q, want ignore", filtered.Action)
	}

	decision.Action = "react"
	decision.Reaction = "eyes"
	filtered = decisionpkg.EnforceAttentionPolicy(input, decisionpkg.WatchTurnState{}, decision, 7, 4)
	if filtered.Action != "ignore" || filtered.Reaction != "" {
		t.Fatalf("reaction without assessment = %+v, want suppressed", filtered)
	}

	decision.Action = "reply"
	decision.Message = "I will interrupt them."
	decision.Attention = decisionpkg.AttentionAssessment{
		Addressee: "human", Urgency: 2, Confidence: 3, Novelty: 2, Ownership: 2,
	}
	filtered = decisionpkg.EnforceAttentionPolicy(
		input,
		decisionpkg.WatchTurnState{ConversationFollowup: true},
		decision,
		7,
		4,
	)
	if filtered.Action != "ignore" {
		t.Fatalf("human-directed continuation was not suppressed: %+v", filtered)
	}
}

func TestParseWatchDecisionNormalizesStructuredMemoryTopology(t *testing.T) {
	decision, err := decisionpkg.ParseWatchDecision(`{
		"action":"reply",
		"message":"I can make that change.",
		"task_title":"Audit infrastructure packs",
		"memory":{
			"topology":{
				"runner_mapping":"Two current runners",
				"portal_hosts_declared":2
			}
		}
	}`, testDecodeClock)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"portal_hosts_declared: 2",
		"runner_mapping: Two current runners",
	}
	if !slices.Equal(decision.Memory.Topology, want) {
		t.Fatalf("normalized topology = %#v, want %#v", decision.Memory.Topology, want)
	}

	decision, err = decisionpkg.ParseWatchDecision(`{
		"action":"reply",
		"message":"I can make that change.",
		"task_title":"Audit infrastructure packs",
		"memory":{
			"topology":[
				{"service":"portal","declared_instances":2},
				{"service":"database","kind":"cloud-sql"}
			]
		}
	}`, testDecodeClock)
	if err != nil {
		t.Fatal(err)
	}
	want = []string{
		"declared_instances: 2; service: portal",
		"kind: cloud-sql; service: database",
	}
	if !slices.Equal(decision.Memory.Topology, want) {
		t.Fatalf("normalized topology array = %#v, want %#v", decision.Memory.Topology, want)
	}
}

func TestParseWatchDecisionExtractsFinalEnvelopeAfterCoopProgress(t *testing.T) {
	output := "I’m checking the repository and current infrastructure state." +
		"The evidence is sufficient; I’m preparing the answer." +
		`{"action":"reply","reason":"The operator asked for a health assessment.",` +
		`"message":"Production is healthy within the checked scope.",` +
		`"evidence":[{"claim":"Both hosts are connected","observation":"Two of two runners are connected",` +
		`"source_type":"emisar","source_name":"list_runners"}],` +
		`"coverage":[{"layer":"host","status":"healthy"}],"memory":{}}`
	decision, err := decisionpkg.ParseWatchDecision(output, testDecodeClock)
	if err != nil {
		t.Fatal(err)
	}
	if decision.Action != "reply" ||
		decision.Message != "Production is healthy within the checked scope." ||
		len(decision.Evidence) != 1 || len(decision.Coverage) != 1 {
		t.Fatalf("extracted decision = %+v", decision)
	}
}

func TestWatchRepositorySetSelectsItsCoopPolicy(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.RepositorySets = map[string]config.RepositorySet{
		"platform": {
			DisplayName: "Platform",
			Primary:     "repo",
			CoopPolicy:  "platform-observe",
		},
	}
	cfg.Slack.DefaultRepository = "platform"
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	memory, _, err := svc.ensureWatchSession(ctx, "CREPOSET")
	if err != nil {
		t.Fatal(err)
	}
	if memory.Repository != "platform" {
		t.Fatalf("watch memory repository = %q", memory.Repository)
	}
	if !slices.Equal(coopClient.createPolicies, []string{"platform-observe"}) {
		t.Fatalf("Coop create policies = %v", coopClient.createPolicies)
	}
}
