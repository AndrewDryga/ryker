package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/publisher"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestCustomerJourneyDraftPRPublishesReviewedEngineeringTaskWithoutConfiguredGate(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.NativeStatus = true
	repository := cfg.Repositories["repo"]
	repository.Path = t.TempDir()
	repository.GitHubRepository = "owner/repository"
	repository.GitHubBaseBranch = "main"
	cfg.Repositories["repo"] = repository

	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, created, err := st.CreateEngineeringTask(
		ctx,
		"repo",
		"EvPublishTask",
		"Update runtime packs",
		"Add the repository-required runtime pack.",
		cfg.Slack.Operators[0],
		"COPS",
		"1700.300",
		cfg.Limits.MaxOpenIncidents,
	)
	if err != nil || !created {
		t.Fatalf("create engineering task = %+v, %t, %v", task, created, err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.301"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, task.ID, "ses_publish", "task-packs", 1); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}

	baseCoop := newFakeCoop()
	baseCoop.session.ID = "ses_publish"
	baseCoop.session.ForkName = "task-packs"
	baseCoop.session.Revision = 1
	coopClient := &publicationCoop{
		fakeCoop: baseCoop,
		changes: coop.Changes{
			ParentHead: "parent-head",
			Unstaged:   []coop.Change{{Path: "infra/packs.yaml", Status: "modified"}},
			Patch:      []byte("+runtime-pack: enabled\n"),
		},
		review: coop.Review{
			OperationID:     "op_review",
			SessionID:       "ses_publish",
			SessionRevision: 1,
			ParentHead:      "parent-head",
			CandidateTree:   "candidate-tree",
			Rebase:          "clean",
			Gate:            "none",
			Patch:           []byte("+runtime-pack: enabled\n"),
			Publishable:     false,
			NotPublishableReasons: []string{
				"gate_not_configured",
			},
		},
	}
	slackClient := &fakeSlack{}
	publisherClient := &recordingPublisher{
		result: publisher.Result{
			HeadBranch: "responder/update-runtime-packs",
			CommitSHA:  "commit-sha",
			RemoteSHA:  "commit-sha",
			PRNumber:   42,
			PRURL:      "https://github.example/owner/repository/pull/42",
		},
	}
	svc := New(
		cfg,
		st,
		coopClient,
		slackClient,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	svc.SetPublisher(publisherClient)

	input := core.SlackInput{
		ID:          "slack_publish_task",
		EnvelopeID:  "env_publish_task",
		EventID:     "EvPublishTaskAction",
		Kind:        "action",
		TeamID:      cfg.Slack.TeamID,
		ChannelID:   task.ChannelID,
		MessageTS:   task.RootTS,
		ThreadTS:    task.ConversationThreadTS(),
		UserID:      cfg.Slack.Operators[0],
		ActionID:    slackui.ActionPublishPR,
		ActionValue: task.ID,
	}
	if admitted, err := st.AdmitSlackInput(ctx, input); err != nil || !admitted {
		t.Fatalf("admit publish action = %t, %v", admitted, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if publisherClient.publishCalls != 1 {
		t.Fatalf("publisher calls = %d", publisherClient.publishCalls)
	}
	if publisherClient.request.Incident.ID != task.ID ||
		publisherClient.request.Review.CandidateTree != "candidate-tree" ||
		!publisherClient.request.Review.Publishable ||
		len(publisherClient.request.Review.NotPublishableReasons) != 0 {
		t.Fatalf("publication request = %+v", publisherClient.request)
	}
	publicationRecord, err := st.GetPublication(ctx, task.ID)
	if err != nil || !publicationRecord.Published() ||
		publicationRecord.CandidateTree != "candidate-tree" ||
		publicationRecord.PRURL != publisherClient.result.PRURL {
		t.Fatalf("durable publication = %+v, %v", publicationRecord, err)
	}
	if len(slackClient.posts) != 1 ||
		slackClient.posts[0].channel != "COPS" ||
		slackClient.posts[0].thread != "1700.300" {
		t.Fatalf("publication Slack reply = %+v", slackClient.posts)
	}
	rendered := slackClient.posts[0].message.Header + "\n" +
		slackClient.posts[0].message.Text + "\n" +
		strings.Join(slackClient.posts[0].message.Sections, "\n") + "\n" +
		strings.Join(slackClient.posts[0].message.Context, "\n")
	if !strings.Contains(rendered, "Draft PR ready") ||
		!strings.Contains(rendered, publisherClient.result.PRURL) ||
		!strings.Contains(rendered, "add `gate:`") ||
		strings.Contains(strings.ToLower(rendered), "has been merged") ||
		strings.Contains(strings.ToLower(rendered), "deployed to") {
		t.Fatalf("publication message = %+v", slackClient.posts[0].message)
	}
	if len(slackClient.statuses) == 0 ||
		slackClient.statuses[len(slackClient.statuses)-1].text != "" {
		t.Fatalf("publication pending status = %+v", slackClient.statuses)
	}
}

func TestCustomerJourneySchedulesEngineeringFollowupWithoutStalePRControls(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.NativeStatus = true
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	task, created, err := st.CreateEngineeringTask(
		ctx,
		"repo",
		"EvScheduleFollowup",
		"Reduce cms-web Redis pool size",
		"Make the focused configuration change and publish a draft PR.",
		cfg.Slack.Operators[0],
		"COPS",
		"1700.300",
		cfg.Limits.MaxOpenIncidents,
	)
	if err != nil || !created {
		t.Fatalf("create engineering task = %+v, %t, %v", task, created, err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.301"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, task.ID, "ses_followup", "task-cms", 1); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}

	startAt := time.Now().UTC().Add(24 * time.Hour).Truncate(time.Second)
	coopClient := newFakeCoop()
	coopClient.session.ID = "ses_followup"
	coopClient.session.ForkName = "task-cms"
	coopClient.session.Revision = 1
	coopClient.changes = coop.Changes{
		BaseCommit: "base", ForkHead: "existing-change",
		Committed:   []coop.Change{{Path: "cms.tf", Status: "M"}},
		PatchDigest: "existing-diff", PatchBytes: 100,
	}
	coopClient.completeOnSubmit = fmt.Sprintf(`{
	  "message":"I’ll recheck cms-web in 24 hours and report the result here.",
	  "schedule_offer":{
	    "title":"Recheck cms-web after 24 hours",
	    "prompt":"Perform a fresh read-only post-deployment assessment of cms-web.",
	    "repository":"repo",
	    "recurrence":"once",
	    "start_at":%q,
	    "timezone":"UTC",
	    "catch_up":"latest",
	    "expires_in":"7d"
	  },
	  "completion":{
	    "status":"decision_ready",
	    "summary":"The follow-up is ready for confirmation.",
	    "next_action":"Confirm the one-time schedule."
	  }
	}`, startAt.Format(time.RFC3339))
	slackClient := &fakeSlack{dedupePosts: true}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "slack-schedule-followup", EnvelopeID: "env-schedule-followup",
		EventID: "EvScheduleFollowupInput", Kind: "message",
		TeamID: cfg.Slack.TeamID, ChannelID: task.ChannelID,
		ThreadTS: task.ConversationThreadTS(), MessageTS: "1700.400",
		UserID: cfg.Slack.Operators[0],
		Text:   "Check it in 24 hours and report me again",
	}
	if admitted, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !admitted {
		t.Fatalf("admit follow-up = %v, %v", admitted, admitErr)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)

	if len(slackClient.posts) != 1 {
		t.Fatalf("follow-up posts = %+v", slackClient.posts)
	}
	message := slackClient.posts[0].message
	ids := make([]string, 0, len(message.Actions))
	for _, action := range message.Actions {
		ids = append(ids, action.ID)
	}
	if !slices.Contains(ids, slackui.ActionRememberSchedule) ||
		slices.Contains(ids, slackui.ActionChanges) ||
		slices.Contains(ids, slackui.ActionPublishPR) {
		t.Fatalf("follow-up controls = %+v", message.Actions)
	}
	if !strings.HasPrefix(message.Text, "Confirm the schedule below") ||
		strings.Contains(strings.Join(message.Context, "\n"), "View the diff") {
		t.Fatalf("follow-up message = %+v", message)
	}
	if len(slackClient.statuses) != 2 ||
		slackClient.statuses[0].text != "is scheduling the follow-up..." ||
		slackClient.statuses[1].text != "" {
		t.Fatalf("follow-up status lifecycle = %+v", slackClient.statuses)
	}
	if schedules, listErr := st.ListScheduledTasksForChannel(ctx, task.ChannelID, 10); listErr != nil || len(schedules) != 0 {
		t.Fatalf("schedule was saved before confirmation = %+v, %v", schedules, listErr)
	}
}

func TestCustomerJourneyMentionOnlyPromptsOnceWithoutRetrying(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)

	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "slack-mention-only", EnvelopeID: "env-mention-only",
		EventID: "EvMentionOnly", Kind: "mention",
		TeamID: cfg.Slack.TeamID, ChannelID: incident.ChannelID,
		ThreadTS: incident.ConversationThreadTS(), MessageTS: "1700.400",
		UserID: cfg.Slack.Operators[0], Text: "<@U999BOT>",
	}
	if admitted, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !admitted {
		t.Fatalf("admit mention-only input = %v, %v", admitted, admitErr)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.posts) != 1 ||
		slackClient.posts[0].message.Text != "What should I check?" ||
		slackClient.posts[0].thread != incident.ConversationThreadTS() {
		t.Fatalf("mention-only reply = %+v", slackClient.posts)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil || stored.State != "done" || stored.Failures != 0 {
		t.Fatalf("mention-only input = %+v, %v", stored, err)
	}
	if _, err := st.GetAgentRunBySource(ctx, "slack", input.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("mention-only input created an agent run: %v", err)
	}
}

func TestCustomerJourneyMentionOnlyOutsideIncidentPromptsWithoutCoop(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "slack-channel-mention-only", EnvelopeID: "env-channel-mention-only",
		EventID: "EvChannelMentionOnly", Kind: "mention",
		TeamID: cfg.Slack.TeamID, ChannelID: "C000CHANNEL",
		MessageTS: "1700.401", UserID: cfg.Slack.Operators[0], Text: "<@U999BOT>",
	}
	if admitted, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !admitted {
		t.Fatalf("admit channel mention-only input = %v, %v", admitted, admitErr)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.posts) != 1 ||
		slackClient.posts[0].message.Text != "What should I check?" ||
		slackClient.posts[0].thread != input.MessageTS {
		t.Fatalf("channel mention-only reply = %+v", slackClient.posts)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil || stored.State != "done" || stored.Failures != 0 {
		t.Fatalf("channel mention-only input = %+v, %v", stored, err)
	}
	if _, err := st.GetAgentRunBySource(ctx, "slack", input.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("channel mention-only input created an agent run: %v", err)
	}
}

func TestCustomerJourneyIncidentCannotPublishDraftPR(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	slackClient := &fakeSlack{}
	publisherClient := &recordingPublisher{}
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		slackClient,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	svc.SetPublisher(publisherClient)

	input := core.SlackInput{
		ID:          "slack_publish_incident",
		EnvelopeID:  "env_publish_incident",
		EventID:     "EvPublishIncidentAction",
		Kind:        "action",
		TeamID:      cfg.Slack.TeamID,
		ChannelID:   incident.ChannelID,
		MessageTS:   incident.RootTS,
		ThreadTS:    incident.RootTS,
		UserID:      cfg.Slack.Operators[0],
		ActionID:    slackui.ActionPublishPR,
		ActionValue: incident.ID,
	}
	if admitted, err := st.AdmitSlackInput(ctx, input); err != nil || !admitted {
		t.Fatalf("admit incident publish action = %t, %v", admitted, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if publisherClient.publishCalls != 0 {
		t.Fatalf("incident invoked publisher %d times", publisherClient.publishCalls)
	}
	if len(slackClient.posts) != 1 {
		t.Fatalf("incident publication notice = %+v", slackClient.posts)
	}
	rendered := slackClient.posts[0].message.Text + "\n" +
		strings.Join(slackClient.posts[0].message.Sections, "\n")
	if !strings.Contains(rendered, "available for engineering tasks only") ||
		!strings.Contains(rendered, "remain read-only") {
		t.Fatalf("incident publication notice = %+v", slackClient.posts[0].message)
	}
}

func TestCustomerJourneyBehaviorControlsAreScopedAndDurable(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	operator := cfg.Slack.Operators[0]
	preference, _, err := st.UpsertPreference(
		ctx,
		core.ResponderPreference{
			ScopeKind: "channel",
			ScopeKey:  "COPS",
			Name:      "health_check_depth",
			Value:     "deep",
			Enabled:   true,
			SourceRef: "slack_preference_offer",
			ActorID:   operator,
			ExpiresAt: time.Now().UTC().Add(90 * 24 * time.Hour),
		},
		cfg.Limits.MaxPreferences,
		cfg.Limits.MaxPreferencesPerScope,
	)
	if err != nil {
		t.Fatal(err)
	}
	rule, _, err := st.UpsertStandingRule(
		ctx,
		core.StandingRule{
			ChannelID:  "COPS",
			Repository: "repo",
			Trigger:    "terraform_plan",
			Action:     "review_terraform_plan",
			SourceKind: "app",
			Enabled:    true,
			SourceRef:  "slack_rule_offer",
			ActorID:    operator,
			ExpiresAt:  time.Now().UTC().Add(30 * 24 * time.Hour),
		},
		cfg.Limits.MaxStandingRules,
		cfg.Limits.MaxRulesPerChannel,
	)
	if err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		slackClient,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	actionNumber := 0
	runAction := func(channelID, actionID, actionValue string) {
		t.Helper()
		actionNumber++
		input := core.SlackInput{
			ID:          fmt.Sprintf("slack_behavior_action_%s_%d", actionID, actionNumber),
			EnvelopeID:  fmt.Sprintf("env_behavior_action_%d", actionNumber),
			EventID:     fmt.Sprintf("EvBehaviorAction%d", actionNumber),
			Kind:        "action",
			TeamID:      cfg.Slack.TeamID,
			ChannelID:   channelID,
			MessageTS:   "1700.500",
			UserID:      operator,
			ActionID:    actionID,
			ActionValue: actionValue,
		}
		if admitted, err := st.AdmitSlackInput(ctx, input); err != nil || !admitted {
			t.Fatalf("admit %s = %t, %v", actionID, admitted, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", actionID, err)
		}
	}
	toggleValue := func(id string, enabled bool) string {
		t.Helper()
		data, err := json.Marshal(toggleBehaviorPayload{ID: id, Enabled: enabled})
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}

	runAction(
		"COPS",
		slackui.ActionTogglePreference,
		toggleValue(preference.ID, false),
	)
	preference, err = st.GetPreference(ctx, preference.ID)
	if err != nil || preference.Enabled {
		t.Fatalf("disabled preference = %+v, %v", preference, err)
	}

	runAction(
		"COTHER",
		slackui.ActionToggleRule,
		toggleValue(rule.ID, false),
	)
	rule, err = st.GetStandingRule(ctx, rule.ID)
	if err != nil || !rule.Enabled {
		t.Fatalf("cross-channel rule control changed state = %+v, %v", rule, err)
	}
	if len(slackClient.ephemerals) == 0 ||
		!strings.Contains(
			slackClient.ephemerals[len(slackClient.ephemerals)-1].message.Text,
			"different Slack channel",
		) {
		t.Fatalf("cross-channel feedback = %+v", slackClient.ephemerals)
	}

	runAction("COPS", slackui.ActionToggleRule, toggleValue(rule.ID, false))
	rule, err = st.GetStandingRule(ctx, rule.ID)
	if err != nil || rule.Enabled {
		t.Fatalf("disabled standing rule = %+v, %v", rule, err)
	}

	runAction("COPS", slackui.ActionEditPreference, preference.ID)
	preference, err = st.GetPreference(ctx, preference.ID)
	if err != nil || preference.Enabled {
		t.Fatalf("edit guidance changed preference = %+v, %v", preference, err)
	}
	if !strings.Contains(
		slackClient.ephemerals[len(slackClient.ephemerals)-1].message.Text,
		"existing value remains active until you confirm",
	) {
		t.Fatalf("edit guidance = %+v", slackClient.ephemerals)
	}

	runAction("COPS", slackui.ActionDeletePreference, preference.ID)
	if _, err := st.GetPreference(ctx, preference.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("deleted preference lookup = %v", err)
	}
	runAction("COPS", slackui.ActionDeleteRule, rule.ID)
	if _, err := st.GetStandingRule(ctx, rule.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("deleted rule lookup = %v", err)
	}
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 0 {
		t.Fatalf("behavior controls created incident work = %+v, %v", incidents, err)
	}
}

type publicationCoop struct {
	*fakeCoop
	changes  coop.Changes
	review   coop.Review
	artifact coop.ReviewPatchArtifact
}

func (f *publicationCoop) Changes(context.Context, string) (coop.Changes, error) {
	return f.changes, nil
}

func (f *publicationCoop) Review(
	context.Context,
	string,
	string,
	int64,
) (coop.Review, coop.Operation, error) {
	return f.review, coop.Operation{}, nil
}

func (f *publicationCoop) ReviewPatch(
	context.Context,
	string,
) (coop.ReviewPatchArtifact, error) {
	return f.artifact, nil
}

func TestCompleteReviewPatchFetchesAndVerifiesArtifact(t *testing.T) {
	full := []byte(strings.Repeat("+large reviewed change\n", 60000))
	digest := sha256.Sum256(full)
	digestText := hex.EncodeToString(digest[:])
	client := &publicationCoop{
		fakeCoop: newFakeCoop(),
		artifact: coop.ReviewPatchArtifact{Patch: full, Digest: digestText},
	}
	svc := &Service{coop: client}
	review, err := svc.completeReviewPatch(context.Background(), coop.Review{
		OperationID: "op_large", PatchArtifactID: "op_large",
		Patch: []byte("+large"), PatchTruncated: true,
		PatchBytes: int64(len(full)), PatchDigest: digestText,
	})
	if err != nil || review.PatchTruncated ||
		!strings.EqualFold(review.PatchDigest, digestText) ||
		len(review.Patch) != len(full) {
		t.Fatalf("complete review patch = bytes %d truncated=%t err=%v",
			len(review.Patch), review.PatchTruncated, err)
	}
	client.artifact.Patch[0] = '-'
	if _, err := svc.completeReviewPatch(context.Background(), coop.Review{
		OperationID: "op_large", PatchArtifactID: "op_large",
		Patch: []byte("+large"), PatchTruncated: true,
		PatchBytes: int64(len(full)), PatchDigest: digestText,
	}); err == nil || !strings.Contains(err.Error(), "digest") {
		t.Fatalf("tampered review patch error = %v", err)
	}
}

type recordingPublisher struct {
	request      publisher.Request
	result       publisher.Result
	publishCalls int
}

func (f *recordingPublisher) Enabled() bool {
	return true
}

func (f *recordingPublisher) HeadBranch(
	core.Incident,
	core.Publication,
) (string, error) {
	if f.result.HeadBranch != "" {
		return f.result.HeadBranch, nil
	}
	return "responder/test", nil
}

func (f *recordingPublisher) Publish(
	_ context.Context,
	request publisher.Request,
) (publisher.Result, error) {
	f.publishCalls++
	f.request = request
	return f.result, nil
}

func (f *recordingPublisher) VerifyPublication(context.Context, core.Publication) error {
	return nil
}
