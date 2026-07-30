package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/publisher"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestCustomerJourneyDraftPRPublishesOnlyReviewedEngineeringTask(t *testing.T) {
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
			Gate:            "passed",
			Patch:           []byte("+runtime-pack: enabled\n"),
			Publishable:     true,
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
		publisherClient.request.Review.CandidateTree != "candidate-tree" {
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
		strings.Contains(strings.ToLower(rendered), "has been merged") ||
		strings.Contains(strings.ToLower(rendered), "deployed to") {
		t.Fatalf("publication message = %+v", slackClient.posts[0].message)
	}
	if len(slackClient.statuses) == 0 ||
		slackClient.statuses[len(slackClient.statuses)-1].text != "" {
		t.Fatalf("publication pending status = %+v", slackClient.statuses)
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
	changes coop.Changes
	review  coop.Review
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
