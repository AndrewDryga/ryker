package service

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	attentionpkg "github.com/AndrewDryga/ryker/internal/attention"
	"github.com/AndrewDryga/ryker/internal/config"
	"github.com/AndrewDryga/ryker/internal/core"
	decisionpkg "github.com/AndrewDryga/ryker/internal/decision"
	"github.com/AndrewDryga/ryker/internal/investigation"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
	"github.com/AndrewDryga/ryker/internal/taskaccess"
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
			"attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},
			"operations":[
				{"id":"off-task","type":"offer_task","task":{"kind":"engineering","title":"Update deployment packs"}},
				{"id":"complete","type":"complete_episode","completion":{"message":"I can make that repository change.","completion":{"status":"decision_ready","summary":"Offered the deployment pack change."}}}
			]
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

// A workspace member cannot choose a writable repository until the channel has
// an explicit contributor boundary. Falling back to the deployment default
// rendered a button that the click handler would later refuse, while asking a
// repository question implied the member could broaden their own authority.
// Covers: TestUnconfiguredChannelExplainsContributorBoundaryInsteadOfAskingForRepository
func TestUnconfiguredChannelExplainsContributorBoundaryInsteadOfAskingForRepository(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	slackClient := &fakeSlack{dedupePosts: true}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
		"action":"reply",
		"attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},
		"operations":[
			{"id":"off-task","type":"offer_task","task":{"kind":"engineering","title":"Update deployment packs"}},
			{"id":"complete","type":"complete_episode","completion":{"message":"I can make that repository change.","completion":{"status":"decision_ready","summary":"Offered the deployment pack change."}}}
		]
	}`
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID: "slack-unconfigured-contributor", EnvelopeID: "env-unconfigured-contributor",
		EventID: "event-unconfigured-contributor", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.955", UserID: "UMEMBER",
		Text: "<@U999BOT> update the deployment packs.",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 {
		t.Fatalf("unconfigured contributor response = %+v", slackClient.posts)
	}
	message := slackClient.posts[0].message
	rendered := renderedSlackMessage(message)
	if !strings.Contains(rendered, "not configured for contributor repository work") ||
		!strings.Contains(rendered, "No writable task has started") {
		t.Fatalf("contributor boundary was not explained: %q", rendered)
	}
	if strings.Contains(rendered, "Which configured repository") || len(message.Actions) != 0 {
		t.Fatalf("unconfigured member was offered a repository choice: %+v", message)
	}
}

// A question with one answer is not a question.
//
// On 2026-08-16 Ryker answered five alert investigations with "Which
// configured repository should I use for this engineering task: All Blitz
// repositories (`blitz-platform`)?" — a list of one, addressed to a Grafana
// bot. Nobody could answer it and no task button was rendered all day. When the
// configuration leaves exactly one repository the offer could mean, take it.
func TestSingleRepositoryChoiceIsTakenNotAsked(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{dedupePosts: true}
	coopClient := newFakeCoop()
	// The model named a repository this deployment does not configure, which is
	// the same dead end as naming none: there is exactly one place the work
	// could run.
	coopClient.completeOnSubmit = `{
			"action":"reply",
			"attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},
			"operations":[
				{"id":"off-task","type":"offer_task","task":{"kind":"engineering","title":"Update deployment packs","repository":"blitz-infra"}},
				{"id":"complete","type":"complete_episode","completion":{"message":"I can make that repository change.","completion":{"status":"decision_ready","summary":"Offered the deployment pack change."}}}
			]
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID: "slack-single-repository", EnvelopeID: "env-single-repository",
		EventID: "event-single-repository", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.960", UserID: "U123ABC",
		Text: "Update the deployment packs.",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 {
		t.Fatalf("single repository choice response = %+v", slackClient.posts)
	}
	message := slackClient.posts[0].message
	if strings.Contains(renderedSlackMessage(message), "Which configured repository") {
		t.Fatalf("single repository choice was asked as a question = %+v", message)
	}
	if len(message.Actions) != 1 || message.Actions[0].ID != slackui.ActionStartTask ||
		message.Actions[0].Value != source.ID {
		t.Fatalf("single repository choice offer actions = %+v", message.Actions)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", source.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(run)
	if err != nil ||
		state.OfferedTaskTitle != "Update deployment packs" ||
		state.OfferedTaskRepository != "repo" {
		t.Fatalf("persisted task offer = %+v, %v", state, err)
	}
}

func TestMemberTaskRepositoryCatalogIsBoundToTheChannelRepository(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Repositories["backend"] = config.Repository{
		DisplayName:       "Sensitive backend",
		CoopPolicy:        "backend-operator",
		ContributorPolicy: "backend-contributor",
	}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "CPUBLIC", Participation: "mentions", Repository: "repo",
		AlertPolicy: "reply", ActorID: cfg.Slack.Operators[0],
	}); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		TeamID: cfg.Slack.TeamID, ChannelID: "CPUBLIC", UserID: "UMEMBER",
	}
	resolved, err := taskaccess.ResolveOfferRepository(ctx, cfg, st, input, "")
	if err != nil || resolved != "repo" {
		t.Fatalf("member default task repository = %q, err=%v", resolved, err)
	}
	if _, err := taskaccess.ResolveOfferRepository(ctx, cfg, st, input, "backend"); err == nil ||
		!strings.Contains(err.Error(), "not authorized for this channel") {
		t.Fatalf("cross-repository member offer = %v", err)
	}
	catalog := taskaccess.Repositories(cfg, false, resolved)
	if len(catalog) != 1 || catalog[0].Key != "repo" ||
		strings.Contains(string(mustJSON(t, catalog)), "backend") {
		t.Fatalf("member task repository catalog = %+v", catalog)
	}
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestOperatorCreatedTaskKeepsEachParticipantsOwnAuthority(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "operator-task", "Operator task", "summary",
		cfg.Slack.Operators[0], "COPS", "1700.600", cfg.Limits.MaxOpenIncidents,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.601"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, task.ID, "ses_operator", "operator-task", 1); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)

	member := core.SlackInput{
		ID: "member-operator-task", EnvelopeID: "env-member-operator-task",
		EventID: "event-member-operator-task", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: task.ChannelID, ThreadTS: task.ConversationThreadTS(), MessageTS: "1700.602",
		UserID: "UMEMBER", Text: "Run the deployment now.",
	}
	if created, err := st.AdmitSlackInput(ctx, member); err != nil || !created {
		t.Fatalf("admit member follow-up = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	memberRun, err := st.GetAgentRunBySource(ctx, "slack", member.ID)
	if err != nil ||
		!strings.Contains(memberRun.Prompt, "active full workspace members") ||
		!strings.Contains(memberRun.Prompt, "does not authorize applying configuration") ||
		strings.Contains(memberRun.Prompt, "one exact governed action") {
		t.Fatalf("member task authority = %q, err=%v", memberRun.Prompt, err)
	}

	operator := member
	operator.ID = "operator-operator-task"
	operator.EnvelopeID = "env-operator-operator-task"
	operator.EventID = "event-operator-operator-task"
	operator.MessageTS = "1700.603"
	operator.UserID = cfg.Slack.Operators[0]
	operator.Text = "Inspect the code and report readiness."
	if created, err := st.AdmitSlackInput(ctx, operator); err != nil || !created {
		t.Fatalf("admit operator follow-up = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	run, err := st.GetAgentRunBySource(ctx, "slack", operator.ID)
	if err != nil || !strings.Contains(run.Prompt, "configured operators") ||
		!strings.Contains(run.Prompt, "one exact governed action") ||
		strings.Contains(run.Prompt, "contributor session") {
		t.Fatalf("operator task prompt = %q, err=%v", run.Prompt, err)
	}
}

// Bruno's ordinary review request was rejected solely because Andrew created
// the task. Code feedback in an isolated fork must use the current teammate's
// contributor authority instead of inheriting or requiring the creator's role.
func TestWorkspaceMemberCanSteerOperatorCreatedTaskWithContributorAuthority(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "operator-task-feedback", "Add bounded context", "summary",
		cfg.Slack.Operators[0], "COPS", "1700.700", cfg.Limits.MaxOpenIncidents,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.701"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, task.ID, "ses_operator", "operator-task", 1); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{dedupePosts: true}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)

	input := core.SlackInput{
		ID: "bruno-feedback", EnvelopeID: "env-bruno-feedback", EventID: "event-bruno-feedback",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: task.ChannelID,
		ThreadTS: task.ConversationThreadTS(), MessageTS: "1700.702", UserID: "UBRUNO",
		Text: "<@U999BOT> Modify API failure logging to aggregate failures by request parameters.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Bruno feedback = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	run, err := st.GetAgentRunBySource(ctx, "slack", input.ID)
	if err != nil {
		t.Fatalf("Bruno feedback did not queue: %v", err)
	}
	if !strings.Contains(run.Prompt, "active full workspace members") ||
		!strings.Contains(run.Prompt, "does not authorize applying configuration") ||
		strings.Contains(run.Prompt, "configured operators") ||
		strings.Contains(run.Prompt, "one exact governed action") {
		t.Fatalf("Bruno feedback authority = %q", run.Prompt)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.posts) != 0 || len(slackClient.ephemerals) != 0 {
		t.Fatalf("accepted feedback produced a refusal: posts=%+v ephemerals=%+v",
			slackClient.posts, slackClient.ephemerals)
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
		evidence.RecentMessages[1].MentionsRyker ||
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

	coopClient.complete(`{"action":"reply","attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},"operations":[{"id":"complete","type":"complete_episode","completion":{"message":"Yes, the deploy recovered.","completion":{"status":"decision_ready","summary":"The deploy recovered."}}}]}`)
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

func TestOperatorAnswerResumesWaitingEpisode(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
		"action":"reply",
		"attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},
		"operations":[
			{"id":"ask-environment","type":"request_operator_input","operator_input":{"question":"Which environment should I inspect?","choices":["Production","Staging"]}},
			{"id":"complete-question","type":"complete_episode","completion":{"message":"Which environment should I inspect?","completion":{"status":"blocked","summary":"The target environment is required.","material_gaps":["target environment"],"blocker_kind":"operator_input_required","attempts":["Checked the request for an environment name."],"next_action":"Name the environment to inspect."}}}
		]
	}`
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	question := core.SlackInput{
		ID: "slack-question", EnvelopeID: "env-question", EventID: "EvQuestion",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.100", UserID: "U123ABC",
		Text: "<@U999BOT> Which environment should I inspect?",
	}
	if created, err := st.AdmitSlackInput(ctx, question); err != nil || !created {
		t.Fatalf("admit question = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	first, err := st.GetAgentRunBySource(ctx, "watch", question.ID)
	if err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	before, err := st.GetWorkEpisodeByRun(ctx, first.ID)
	if err != nil || before.State != core.EpisodeWaitingOperator ||
		before.Destination.ThreadTS == "" {
		t.Fatalf("waiting episode = %+v, %v", before, err)
	}
	// An unrelated, newer channel conversation must not hide the episode whose
	// exact thread is waiting for this answer.
	unrelated, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "CWATCH", ThreadTS: "1800.100",
		ConversationKey: "channel:CWATCH", SourceKind: "watch",
		SourceID: "unrelated-newer-thread", UserID: "U456DEF",
		CreatedAt: time.Now().UTC().Add(time.Minute), Context: []byte(`{}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if unrelated.EpisodeID == first.EpisodeID {
		t.Fatalf("unrelated run reused waiting episode: %+v", unrelated)
	}

	answer := core.SlackInput{
		ID: "slack-answer", EnvelopeID: "env-answer", EventID: "EvAnswer",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		ThreadTS: before.Destination.ThreadTS, MessageTS: "1700.200", UserID: "U123ABC",
		Text: "Production.",
	}
	if created, err := st.AdmitSlackInput(ctx, answer); err != nil || !created {
		t.Fatalf("admit answer = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	resumed, err := st.GetAgentRunBySource(ctx, "watch", answer.ID)
	if err != nil {
		t.Fatal(err)
	}
	if resumed.EpisodeID != first.EpisodeID || resumed.AttemptNumber != 2 {
		t.Fatalf("answer started new work instead of attempt 2: first=%+v answer=%+v", first, resumed)
	}
	after, err := st.GetWorkEpisodeByRun(ctx, resumed.ID)
	if err != nil || after.State != core.EpisodeRetrying || after.ParentEpisodeID != "" {
		t.Fatalf("resumed episode = %+v, %v", after, err)
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
	if err := st.Intelligence.AdvanceChannelEvents(
		ctx, input.ChannelID, run.SessionID, 13,
	); err != nil {
		t.Fatal(err)
	}
	coopClient.complete(`{"action":"reply","attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":3,"contribution":"decision","material":true},"operations":[{"id":"complete","type":"complete_episode","completion":{"message":"The Terraform plan is safe to apply.","completion":{"status":"decision_ready","summary":"The plan is safe to apply."}}}]}`)
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
	memory, err := st.Intelligence.GetChannelMemory(ctx, input.ChannelID)
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
		`{"action":"reply","message":"Prepare it.","task_prompt":"Change the code."}`,
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
		"attention":{"addressee":"responder","confidence":3,"ownership":3,"contribution":"decision","material":true},
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
	filtered := attentionpkg.Enforce(input, decisionpkg.WatchTurnState{}, decision, 7, 4)
	if filtered.Action != "ignore" || filtered.Message != "" ||
		!strings.Contains(filtered.Reason, "suppressed") {
		t.Fatalf("filtered decision = %+v", filtered)
	}

	input.Kind = "mention"
	filtered = attentionpkg.Enforce(input, decisionpkg.WatchTurnState{}, decision, 7, 4)
	if filtered.Action != "reply" || filtered.Message == "" {
		t.Fatalf("explicit mention was suppressed: %+v", filtered)
	}

	input.Kind = "message"
	decision.Attention = decisionpkg.AttentionAssessment{}
	filtered = attentionpkg.Enforce(input, decisionpkg.WatchTurnState{}, decision, 7, 4)
	if filtered.Action != "ignore" {
		t.Fatalf("ambient action without assessment = %q, want ignore", filtered.Action)
	}

	decision.Action = "react"
	decision.Reaction = "eyes"
	filtered = attentionpkg.Enforce(input, decisionpkg.WatchTurnState{}, decision, 7, 4)
	if filtered.Action != "ignore" || filtered.Reaction != "" {
		t.Fatalf("reaction without assessment = %+v, want suppressed", filtered)
	}

	decision.Action = "reply"
	decision.Message = "I will interrupt them."
	decision.Attention = decisionpkg.AttentionAssessment{
		Addressee: "human", Urgency: 2, Confidence: 3, Novelty: 2, Ownership: 2,
	}
	filtered = attentionpkg.Enforce(
		input,
		decisionpkg.WatchTurnState{ConversationFollowup: true},
		decision,
		7,
		4,
	)
	if filtered.Action != "ignore" {
		t.Fatalf("human-directed continuation was not suppressed: %+v", filtered)
	}

	decision.Attention = decisionpkg.AttentionAssessment{
		Addressee: "channel", Urgency: 1, Confidence: 3, Novelty: 2, Ownership: 2,
		Contribution: "none", Material: false,
	}
	filtered = attentionpkg.Enforce(input, decisionpkg.WatchTurnState{}, decision, 7, 4)
	if filtered.Action != "ignore" {
		t.Fatalf("high-scoring ambient restatement was not suppressed: %+v", filtered)
	}

	decision.Attention.Contribution = "new_evidence"
	decision.Attention.Material = true
	filtered = attentionpkg.Enforce(input, decisionpkg.WatchTurnState{}, decision, 7, 4)
	if filtered.Action != "reply" {
		t.Fatalf("material ambient contribution was suppressed: %+v", filtered)
	}
}

func TestAttentionPolicySuppressesAmbientReplyInHumanDirectedThread(t *testing.T) {
	input := core.SlackInput{
		Kind:      "message",
		ChannelID: "CASKDEVOPS",
		ThreadTS:  "1786478872.467239",
		Text:      "I don't have permission to create apps",
	}
	state := decisionpkg.WatchTurnState{
		// The existing continuity heuristic may recognize a recent Ryker
		// session in the thread. The human-addressed root still wins unless the
		// current message explicitly addresses Ryker.
		ConversationFollowup: true,
		RecentMessages: []decisionpkg.WatchContextMessage{
			{
				MessageTS:  "1786478872.467239",
				SenderType: "human",
				Text:       "<@U089UCBNT38> do you have full permissions on Cloudflare?",
			},
			{
				MessageTS:  "1786479075.100000",
				ThreadTS:   "1786478872.467239",
				SenderType: "human",
				Text:       "Could you please help? Repository is github.com/theblitzapp/blitzapp.gg",
			},
		},
	}
	result := decisionpkg.WatchDecision{
		Action: "reply",
		Message: "The screenshot shows Astro, master, npm run build, and dist. " +
			"Repository access and Cloudflare permissions are the blockers.",
		Attention: decisionpkg.AttentionAssessment{
			Addressee: "channel", Urgency: 1, Confidence: 3, Novelty: 2, Ownership: 2,
			Contribution: "none", Material: false,
		},
	}

	filtered := attentionpkg.Enforce(input, state, result, 7, 4)
	if filtered.Action != "ignore" || filtered.Message != "" {
		t.Fatalf("human-directed thread reply was not suppressed: %+v", filtered)
	}

	result.Action = "react"
	result.Message = ""
	result.Reaction = "eyes"
	filtered = attentionpkg.Enforce(input, state, result, 7, 4)
	if filtered.Action != "ignore" || filtered.Reaction != "" {
		t.Fatalf("human-directed thread reaction was not suppressed: %+v", filtered)
	}

	result.Action = "reply"
	result.Message = "I cannot inspect the project because repository access is unavailable."
	result.Attention.Contribution = "new_evidence"
	result.Attention.Material = true
	result.Completion = &investigation.CompletionAssessment{
		Status:      "blocked",
		Summary:     "Repository access is unavailable.",
		BlockerKind: "access_denied",
		Blocker:     "The connected GitHub app cannot read the repository.",
		NextAction:  "Grant repository access.",
	}
	filtered = attentionpkg.Enforce(input, state, result, 7, 4)
	if filtered.Action != "ignore" {
		t.Fatalf("blocked evidence interrupted a human-directed thread: %+v", filtered)
	}

	state.MatchedRules = []core.StandingRule{{
		ID: "rule_review_repository_links", Enabled: true,
	}}
	filtered = attentionpkg.Enforce(input, state, result, 7, 4)
	if filtered.Action != "ignore" {
		t.Fatalf("standing rule bypassed human-thread usefulness policy: %+v", filtered)
	}

	result.Message = "The live Cloudflare project uses different build settings."
	result.Completion = &investigation.CompletionAssessment{
		Status:  "decision_ready",
		Summary: "The live project settings differ from the screenshot.",
	}
	filtered = attentionpkg.Enforce(input, state, result, 7, 4)
	if filtered.Action != "reply" {
		t.Fatalf("decision-ready evidence in a human-directed thread was suppressed: %+v", filtered)
	}

	input.Kind = "mention"
	result.Attention.Contribution = "none"
	result.Attention.Material = false
	filtered = attentionpkg.Enforce(input, state, result, 7, 4)
	if filtered.Action != "reply" {
		t.Fatalf("explicit mention in human-directed thread was suppressed: %+v", filtered)
	}
}

func TestEvidenceBackedConversationReplyCorrectsHumanAddressee(t *testing.T) {
	now := time.Date(2026, 8, 11, 19, 0, 0, 0, time.UTC)
	input := core.SlackInput{
		Kind:      "message",
		ChannelID: "COPS",
		Text:      "The build passed; static analysis failed in a different job.",
	}
	state := decisionpkg.WatchTurnState{ConversationFollowup: true}
	decision := decisionpkg.WatchDecision{
		Action:  "reply",
		Message: "The build passed. The missing image points to publication or promotion instead.",
		Attention: decisionpkg.AttentionAssessment{
			Addressee: "human", Urgency: 1, Confidence: 3, Novelty: 3, Ownership: 2,
		},
		Evidence: []core.Evidence{{
			Claim:       "the build job passed",
			Observation: "CI reported the build job successful",
			SourceType:  "ci",
			SourceName:  "GitHub Actions",
			ObservedAt:  now,
		}},
		Completion: &CompletionAssessment{
			Status: "decision_ready", Summary: "The build passed; image publication remains suspect.",
		},
	}

	correction := decisionpkg.WatchDecisionCorrectionAt(
		input, state, decision, now, OperationalCorrelationKey,
	)
	if correction == "" || !strings.Contains(correction, "attention.addressee=ryker") {
		t.Fatalf("correction = %q, want ryker-addressee correction", correction)
	}

	decision.Attention.Addressee = "responder"
	if correction := decisionpkg.WatchDecisionCorrectionAt(
		input, state, decision, now, OperationalCorrelationKey,
	); correction != "" {
		t.Fatalf("corrected decision was rejected: %s", correction)
	}
	filtered := attentionpkg.Enforce(input, state, decision, 7, 4)
	if filtered.Action != "reply" || filtered.Message == "" {
		t.Fatalf("corrected decision was suppressed: %+v", filtered)
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

// A safety-relevant correction addressed to a person was suppressed for no
// reason beyond the addressee being a person, which is true of most safety
// corrections. The policy already defines the exception — material_correction
// may interrupt a human-directed thread — and the addressee clause was
// overriding it.
func TestAttentionPolicyDeliversMaterialCorrectionInHumanDirectedThread(t *testing.T) {
	input := core.SlackInput{
		ID: "slack-ambient-correction", Kind: "message", ChannelID: "C1",
		ThreadTS: "1700.100", MessageTS: "1700.140", UserID: "U111",
		Text: "so we can go ahead and drop the replica tonight",
	}
	// A thread one person opened by addressing another. Ambient by every
	// signal Ryker has.
	state := decisionpkg.WatchTurnState{RecentMessages: []decisionpkg.WatchContextMessage{{
		MessageTS: "1700.100", SenderID: "U111", SenderType: "human",
		Text: "<@U222> can you confirm the replica is idle?",
	}}}
	correction := decisionpkg.WatchDecision{
		Action:  "reply",
		Message: "That replica still serves read traffic; dropping it tonight will take reads down.",
		Attention: decisionpkg.AttentionAssessment{
			Addressee: "human", Urgency: 3, Confidence: 3, Novelty: 3, Ownership: 2,
			Contribution: "material_correction", Material: true,
		},
	}
	filtered := attentionpkg.Enforce(input, state, correction, 7, 4)
	if filtered.Action != "reply" || filtered.Message == "" {
		t.Fatalf("material correction to a human-directed thread was suppressed: %+v", filtered)
	}

	// Ordinary chatter addressed to a person stays suppressed. The exception is
	// for the one contribution the policy already decided is worth an
	// interruption, not for anything the model labels human.
	chatter := correction
	chatter.Attention.Contribution = "none"
	chatter.Attention.Material = false
	if filtered := attentionpkg.Enforce(input, state, chatter, 7, 4); filtered.Action != "ignore" {
		t.Fatalf("ambient chatter addressed to a human was delivered: %+v", filtered)
	}

	// New evidence that has not reached a decision is not an interruption
	// either: it may be new to Ryker and useless to the people talking.
	evidence := correction
	evidence.Attention.Contribution = "new_evidence"
	if filtered := attentionpkg.Enforce(input, state, evidence, 7, 4); filtered.Action != "ignore" {
		t.Fatalf("undecided new evidence interrupted a human thread: %+v", filtered)
	}
}
