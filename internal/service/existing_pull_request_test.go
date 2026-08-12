package service

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/publisher"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/taskpr"
)

func (s *Service) engineeringTaskPullRequestTarget(
	ctx context.Context,
	incident core.Incident,
) (core.PullRequestTarget, bool, error) {
	repository, ok := s.cfg.RepositoryContext(incident.Repository)
	if !ok {
		return core.PullRequestTarget{}, false, nil
	}
	client, _ := s.publisher.(taskpr.Inspector)
	return s.taskPullRequestResolver(client).Resolve(ctx, incident, repository)
}

func TestWatchTaskOfferPersistsAuthenticatedExistingPullRequest(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	repository := cfg.Repositories["repo"]
	repository.GitHubRepository = "owner/repo"
	repository.GitHubBaseBranch = "main"
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "COPS", ConversationKey: "channel:COPS",
		SourceKind: "watch", SourceID: "slack-offer", Repository: "repo",
		Prompt: "offer task", Context: []byte(`{}`),
	})
	if err != nil || !created {
		t.Fatalf("queue watch run = %+v, %t, %v", run, created, err)
	}
	head := strings.Repeat("a", 40)
	github := &pullRequestTestPublisher{context: publisher.PullRequestContext{
		Repository: "owner/repo", Number: 514,
		URL: "https://github.com/owner/repo/pull/514", State: "open",
		BaseRef: "main", BaseRepository: "owner/repo",
		HeadRef: "feature", HeadSHA: head, HeadRepository: "owner/repo",
	}}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.SetPublisher(github)
	if err := svc.persistWatchTaskOffer(
		ctx, "slack-offer", "Update PR", "repo", "Make the approved change.",
		"https://github.com/owner/repo/pull/514",
	); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(stored)
	if err != nil || state.OfferedTaskPullRequest == nil ||
		state.OfferedTaskPullRequest.Number != 514 ||
		state.OfferedTaskPullRequest.HeadCommit != head {
		t.Fatalf("stored PR task offer = %+v, %v", state, err)
	}
}

func TestPublicationReviewMustMatchAdmittedPullRequestHead(t *testing.T) {
	target := core.PullRequestTarget{Number: 514, HeadCommit: strings.Repeat("a", 40)}
	matching := coop.Review{PullRequest: &coop.PullRequestBinding{
		Number: 514, Ref: "refs/pull/514/head", HeadCommit: target.HeadCommit,
	}}
	if err := taskpr.ValidateReview(matching, target, true); err != nil {
		t.Fatal(err)
	}
	matching.PullRequest.HeadCommit = strings.Repeat("b", 40)
	if err := taskpr.ValidateReview(matching, target, true); err == nil {
		t.Fatal("moved Coop pull request binding was accepted")
	}
	if err := taskpr.ValidateReview(coop.Review{}, core.PullRequestTarget{}, false); err != nil {
		t.Fatal(err)
	}
}

func TestUntouchedExistingPullRequestHasNothingToPublish(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	repository := cfg.Repositories["repo"]
	repository.Path = t.TempDir()
	repository.GitHubRepository = "owner/repo"
	repository.GitHubBaseBranch = "main"
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	target := core.PullRequestTarget{
		Repository: "owner/repo", Number: 514,
		URL:        "https://github.com/owner/repo/pull/514",
		BaseBranch: "main", HeadBranch: "feature", HeadCommit: strings.Repeat("a", 40),
	}
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-untouched-pr", "Inspect PR", "summary",
		cfg.Slack.Operators[0], "COPS", "1700.100", 100, target,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.101"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, task.ID, "session-untouched-pr", "fork", 1); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	coopClient := &publicationCoop{
		fakeCoop: newFakeCoop(),
		changes: coop.Changes{
			BaseCommit: "merge-base", ForkHead: "empty-commit",
			ForkTree: "unchanged-tree", PullRequestTree: "unchanged-tree",
			Committed: []coop.Change{{Path: "original-pr.go", Status: "modified"}},
		},
	}
	coopClient.session.PullRequest = &coop.PullRequestBinding{
		Number: target.Number, Ref: "refs/pull/514/head", HeadCommit: target.HeadCommit,
	}
	publisherClient := &recordingPublisher{}
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.SetPublisher(publisherClient)
	card, err := svc.incidentCard(ctx, task)
	if err != nil {
		t.Fatal(err)
	}
	if slices.ContainsFunc(card.Actions, func(action slackui.Action) bool {
		return action.ID == slackui.ActionPublishPR || action.ID == slackui.ActionReview
	}) {
		t.Fatalf("untouched existing PR offered review/publication: %+v", card.Actions)
	}
	err = svc.publishDraftPR(ctx, core.SlackInput{
		ID: "publish-untouched-pr", Kind: controlPlaneInput, ChannelID: "COPS",
		UserID: cfg.Slack.Operators[0], ActionID: slackui.ActionPublishPR,
		ActionValue: task.ID,
	}, task)
	if err == nil || !strings.Contains(err.Error(), "nothing to publish") {
		t.Fatalf("untouched existing PR publication = %v, want refusal", err)
	}
	publication, err := st.GetPublication(ctx, task.ID)
	if err != nil || publication.FailureCode != core.PublicationFailureNoChanges ||
		publisherClient.publishCalls != 0 || coopClient.reviewCalls != 0 {
		t.Fatalf(
			"untouched existing PR side effects: publication=%+v publish=%d review=%d err=%v",
			publication, publisherClient.publishCalls, coopClient.reviewCalls, err,
		)
	}
}

func TestLegacySessionCannotOfferOrRunExistingPullRequestUpdate(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	repository := cfg.Repositories["repo"]
	repository.Path = t.TempDir()
	repository.GitHubRepository = "owner/repo"
	repository.GitHubBaseBranch = "main"
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	target := core.PullRequestTarget{
		Repository: "owner/repo", Number: 514,
		URL:        "https://github.com/owner/repo/pull/514",
		BaseBranch: "main", HeadBranch: "feature", HeadCommit: strings.Repeat("a", 40),
	}
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-legacy-session", "Update PR", "summary",
		cfg.Slack.Operators[0], "COPS", "1700.100", 100, target,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.101"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, task.ID, "session-legacy", "fork", 1); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	coopClient := &publicationCoop{
		fakeCoop: newFakeCoop(),
		changes:  coop.Changes{Unstaged: []coop.Change{{Path: "change.go", Status: "modified"}}},
	}
	publisherClient := &recordingPublisher{}
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.SetPublisher(publisherClient)
	card, err := svc.incidentCard(ctx, task)
	if err != nil {
		t.Fatal(err)
	}
	if slices.ContainsFunc(card.Actions, func(action slackui.Action) bool {
		return action.ID == slackui.ActionPublishPR || action.ID == slackui.ActionReview
	}) || !strings.Contains(strings.Join(card.Sections, "\n"), "fresh task") {
		t.Fatalf("legacy session card = %+v", card)
	}
	publication, err := st.GetPublication(ctx, task.ID)
	if err != nil || publication.State != core.PublicationFailed ||
		publication.FailureCode != core.PublicationFailureSessionBinding {
		t.Fatalf("persisted legacy-session failure = %+v, %v", publication, err)
	}
	versioned, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := svc.incidentCard(ctx, versioned); err != nil {
		t.Fatal(err)
	}
	converged, err := st.GetIncident(ctx, task.ID)
	if err != nil || converged.CardVersion != versioned.CardVersion {
		t.Fatalf(
			"stable binding-failure render changed card version %d -> %d: %v",
			versioned.CardVersion, converged.CardVersion, err,
		)
	}
	err = svc.publishDraftPR(ctx, core.SlackInput{
		ID: "publish-legacy-session", Kind: controlPlaneInput, ChannelID: "COPS",
		UserID: cfg.Slack.Operators[0], ActionID: slackui.ActionPublishPR,
		ActionValue: task.ID,
	}, task)
	var permanent *taskpr.PermanentError
	if !errors.As(err, &permanent) || publisherClient.publishCalls != 0 ||
		coopClient.reviewCalls != 0 {
		t.Fatalf(
			"legacy session publication = %v publish=%d review=%d",
			err, publisherClient.publishCalls, coopClient.reviewCalls,
		)
	}
	err = svc.reviewFix(ctx, core.SlackInput{
		ID: "review-legacy-session", Kind: controlPlaneInput, ChannelID: "COPS",
		UserID: cfg.Slack.Operators[0], ActionID: slackui.ActionReview,
		ActionValue: task.ID,
	}, task)
	if !errors.As(err, &permanent) || coopClient.reviewCalls != 0 {
		t.Fatalf("legacy session readiness review = %v review=%d", err, coopClient.reviewCalls)
	}
}

func TestStoredPullRequestBindingRejectsRepositoryConfigurationDrift(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	repository := cfg.Repositories["repo"]
	repository.GitHubRepository = "owner/repo"
	repository.GitHubBaseBranch = "main"
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	target := core.PullRequestTarget{
		Repository: "owner/repo", Number: 514,
		URL:        "https://github.com/owner/repo/pull/514",
		BaseBranch: "main", HeadBranch: "feature", HeadCommit: strings.Repeat("a", 40),
	}
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-config-drift", "Update PR", "summary",
		cfg.Slack.Operators[0], "COPS", "1700.100", 100, target,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.101"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, task.ID, "session-config-drift", "fork", 1); err != nil {
		t.Fatal(err)
	}
	prior := taskpr.PendingPublication(task.ID, target)
	prior.State = core.PublicationFailed
	prior.LastError = "temporary publication error"
	if err := st.SavePublication(ctx, prior); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	repository.GitHubBaseBranch = "release"
	cfg.Repositories["repo"] = repository
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if _, _, err := svc.engineeringTaskPullRequestTarget(ctx, task); err == nil {
		t.Fatal("repository configuration drift did not reject the stored PR binding")
	} else {
		var permanent *taskpr.PermanentError
		if !errors.As(err, &permanent) || !strings.Contains(err.Error(), "configuration") {
			t.Fatalf("repository configuration drift = %v", err)
		}
	}
	card, err := svc.incidentCard(ctx, task)
	if err != nil {
		t.Fatal(err)
	}
	if slices.ContainsFunc(card.Actions, func(action slackui.Action) bool {
		return action.ID == slackui.ActionPublishPR || action.ID == slackui.ActionReview
	}) {
		t.Fatalf("configuration-drift card retained unsafe controls: %+v", card.Actions)
	}
	publication, err := st.GetPublication(ctx, task.ID)
	if err != nil || publication.State != core.PublicationFailed ||
		publication.FailureCode != core.PublicationFailureSessionBinding {
		t.Fatalf("persisted configuration-drift failure = %+v, %v", publication, err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	st, err = store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	repository.GitHubBaseBranch = "main"
	cfg.Repositories["repo"] = repository
	unavailable := newFakeCoop()
	unavailable.getSessionErr = errors.New("Coop unavailable")
	svc = New(
		cfg, st, unavailable, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.SetPublisher(&recordingPublisher{})
	card, err = svc.incidentCard(ctx, task)
	if err != nil {
		t.Fatal(err)
	}
	if slices.ContainsFunc(card.Actions, func(action slackui.Action) bool {
		return action.ID == slackui.ActionPublishPR || action.ID == slackui.ActionReview
	}) || !strings.Contains(strings.Join(card.Sections, "\n"), "fresh task") {
		t.Fatalf("restarted binding-failure card = %+v", card)
	}
}

func TestMergedPullRequestRemainsAuthoritativeAcrossFollowupAndStaleControls(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	repository := cfg.Repositories["repo"]
	repository.GitHubRepository = "owner/repo"
	repository.GitHubBaseBranch = "main"
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	target := core.PullRequestTarget{
		Repository: "owner/repo", Number: 529,
		URL:        "https://github.com/owner/repo/pull/529",
		BaseBranch: "main", HeadBranch: "feature",
		HeadCommit: strings.Repeat("a", 40),
	}
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-merged-pr", "Merged PR follow-up", "stage TLS",
		cfg.Slack.Operators[0], "COPS", "1700.900", 100, target,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.901"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, task.ID, "ses_merged", "merged-task", 1); err != nil {
		t.Fatal(err)
	}
	publication := core.Publication{
		IncidentID: task.ID, Repository: target.Repository, BaseBranch: target.BaseBranch,
		HeadBranch: target.HeadBranch, ParentHead: "parent", CandidateTree: "tree",
		CommitSHA: "commit", RemoteSHA: target.HeadCommit, PRNumber: target.Number,
		PRURL: target.URL, State: core.PublicationPublished, PublishedAt: time.Now().UTC(),
	}
	if err := st.SavePublication(ctx, publication); err != nil {
		t.Fatal(err)
	}
	if err := st.PublicationFollowups.Ensure(ctx, task.ID, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	followup, err := st.PublicationFollowups.Get(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	followup.PRState = "merged"
	followup.ChecksState = "passing"
	followup.MergeSHA = "b3b6bb4e50119ba6"
	followup.MergedAt = time.Now().UTC()
	followup.NextCheckAt = time.Now().UTC().Add(24 * time.Hour)
	if err := st.PublicationFollowups.Save(ctx, followup); err != nil {
		t.Fatal(err)
	}
	if _, err := st.PublicationFollowups.RecordLifecycleEvent(ctx, core.PublicationLifecycleEvent{
		ID: "merged-event", IncidentID: task.ID, Kind: "merged", State: "succeeded",
		Summary: "PR #529 was merged.",
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.TaskCards.SetUpdate(
		ctx, task.ID, "The follow-up apply exposed one more hostname to stage.",
	); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	baseCoop := newFakeCoop()
	baseCoop.session.ID = "ses_merged"
	coopClient := &publicationCoop{
		fakeCoop: baseCoop,
		changes:  coop.Changes{Unstaged: []coop.Change{{Path: "tls.tf", Status: "modified"}}},
	}
	publisherClient := &recordingPublisher{}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.SetPublisher(publisherClient)

	card, err := svc.incidentCard(ctx, task)
	if err != nil {
		t.Fatal(err)
	}
	rendered := card.Text + "\n" + strings.Join(card.Sections, "\n")
	if !strings.Contains(rendered, "PR merged") ||
		!strings.Contains(rendered, task.LatestUpdate) ||
		slices.ContainsFunc(card.Actions, func(action slackui.Action) bool {
			return action.ID == slackui.ActionReview || action.ID == slackui.ActionPublishPR
		}) {
		t.Fatalf("merged follow-up card = %+v", card)
	}
	for _, control := range []struct {
		name string
		run  func() error
	}{
		{name: "publish", run: func() error {
			return svc.publishDraftPR(ctx, core.SlackInput{
				ID: "stale-publish", Kind: controlPlaneInput, ActionID: slackui.ActionPublishPR,
				ActionValue: task.ID,
			}, task)
		}},
		{name: "review", run: func() error {
			return svc.reviewFix(ctx, core.SlackInput{
				ID: "stale-review", Kind: controlPlaneInput, ActionID: slackui.ActionReview,
				ActionValue: task.ID,
			}, task)
		}},
	} {
		err := control.run()
		if err == nil || !strings.Contains(err.Error(), "already merged") {
			t.Fatalf("stale %s control = %v", control.name, err)
		}
	}
	if coopClient.reviewCalls != 0 || publisherClient.publishCalls != 0 {
		t.Fatalf("terminal controls reached review=%d publish=%d", coopClient.reviewCalls, publisherClient.publishCalls)
	}
	stored, err := st.GetPublication(ctx, task.ID)
	if err != nil || !stored.Published() || stored.PRNumber != 529 {
		t.Fatalf("merged publication after stale controls = %+v, %v", stored, err)
	}
}

func TestPublishedPullRequestReceiptSurvivesRepositoryConfigurationDrift(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	repository := cfg.Repositories["repo"]
	repository.GitHubRepository = "owner/repo"
	repository.GitHubBaseBranch = "main"
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	target := core.PullRequestTarget{
		Repository: "owner/repo", Number: 514,
		URL:        "https://github.com/owner/repo/pull/514",
		BaseBranch: "main", HeadBranch: "feature", HeadCommit: strings.Repeat("a", 40),
	}
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-published-config-drift", "Update PR", "summary",
		cfg.Slack.Operators[0], "COPS", "1700.100", 100, target,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.101"); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	publication := core.Publication{
		IncidentID: task.ID, Repository: target.Repository, BaseBranch: target.BaseBranch,
		HeadBranch: target.HeadBranch, ParentHead: target.HeadCommit,
		CandidateTree: "tree", CommitSHA: "commit", RemoteSHA: "commit",
		PRNumber: target.Number, PRURL: target.URL, State: core.PublicationPublished,
		PublishedAt: time.Now().UTC(),
	}
	if err := st.SavePublication(ctx, publication); err != nil {
		t.Fatal(err)
	}
	if err := st.PublicationFollowups.Reset(ctx, task.ID, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	repository.GitHubBaseBranch = "release"
	cfg.Repositories["repo"] = repository
	unavailable := newFakeCoop()
	unavailable.getSessionErr = errors.New("Coop unavailable")
	svc := New(
		cfg, st, unavailable, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	card, err := svc.incidentCard(ctx, task)
	if err != nil || !slices.ContainsFunc(card.Actions, func(action slackui.Action) bool {
		return action.ID == slackui.ActionViewPR
	}) {
		t.Fatalf("published config-drift card = %+v, %v", card, err)
	}
	stored, err := st.GetPublication(ctx, task.ID)
	if err != nil || !stored.Published() || stored.RemoteSHA != publication.RemoteSHA {
		t.Fatalf("published receipt after config drift = %+v, %v", stored, err)
	}
	followup, followed, err := st.PublicationFollowups.Next(
		ctx, time.Now().UTC().Add(time.Hour),
	)
	if err != nil || followup.IncidentID != task.ID || followed.IncidentID != task.ID {
		t.Fatalf("published follow-up after config drift = %+v, %+v, %v", followup, followed, err)
	}
}

func TestLegacyExactPullRequestTaskRecoversOnlyUnmovedAuthenticatedHead(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	repository := cfg.Repositories["repo"]
	repository.GitHubRepository = "owner/repo"
	repository.GitHubBaseBranch = "main"
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	head := strings.Repeat("b", 40)
	source := core.SlackInput{
		ID: "slack-legacy-pr", EnvelopeID: "env-legacy-pr", EventID: "EvLegacyPR",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.200", UserID: cfg.Slack.Operators[0],
		Text: "Please edit https://github.com/owner/repo/pull/514",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %t, %v", created, err)
	}
	stateJSON, err := json.Marshal(decisionpkg.WatchTurnState{
		OfferedTaskTitle: "Update PR", OfferedTaskRepository: "repo",
		OfferedTaskPrompt: "Edit the exact PR #514 head revision " + head + ". Make the requested change.",
	})
	if err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: source.ChannelID,
		ConversationKey: "channel:" + source.ChannelID,
		SourceKind:      "watch", SourceID: source.ID, Repository: "repo",
		Prompt: "offer task", Context: stateJSON,
	})
	if err != nil || !created {
		t.Fatalf("queue watch run = %t, %v", created, err)
	}
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", source.EventID, "Update PR", "summary", cfg.Slack.Operators[0],
		source.ChannelID, source.MessageTS, cfg.Limits.MaxOpenIncidents,
	)
	if err != nil {
		t.Fatal(err)
	}
	github := &pullRequestTestPublisher{context: publisher.PullRequestContext{
		Repository: "owner/repo", Number: 514,
		URL: "https://github.com/owner/repo/pull/514", State: "open",
		BaseRef: "main", BaseRepository: "owner/repo",
		HeadRef: "feature", HeadSHA: head, HeadRepository: "owner/repo",
	}}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.SetPublisher(github)
	target, targeted, err := svc.engineeringTaskPullRequestTarget(ctx, task)
	if err != nil || !targeted || target.Number != 514 || target.HeadCommit != head {
		t.Fatalf("legacy target = %+v, %t, %v", target, targeted, err)
	}
	storedTask, err := st.GetIncident(ctx, task.ID)
	if err != nil || storedTask.TaskPullRequest == nil || *storedTask.TaskPullRequest != target {
		t.Fatalf("backfilled legacy target = %+v, %v", storedTask, err)
	}
	leasedInput, err := st.LeaseSlackInput(ctx)
	if err != nil || leasedInput.ID != source.ID {
		t.Fatalf("lease legacy source = %+v, %v", leasedInput, err)
	}
	if err := st.FinishSlackInput(ctx, source.ID); err != nil {
		t.Fatal(err)
	}
	leasedRun, err := st.LeaseAgentRun(ctx)
	if err != nil || leasedRun.ID != run.ID {
		t.Fatalf("lease legacy watch run = %+v, %v", leasedRun, err)
	}
	if err := st.BindAgentRunSession(
		ctx, run.ID, "session-legacy", 0, "repo", 0, run.Context,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(ctx, run.ID, "turn-legacy", 1, 0); err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(ctx, run.ID, "completed", nil, "", 1); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BeginAgentRunFinalization(ctx, run.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.FinishAgentRun(ctx, run.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Prune(
		ctx, time.Now().Add(time.Hour), time.Time{}, time.Time{}, time.Time{}, time.Time{},
	); err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	st, err = store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	storedTask, err = st.GetIncident(ctx, task.ID)
	if err != nil || storedTask.TaskPullRequest == nil || *storedTask.TaskPullRequest != target {
		t.Fatalf("restarted legacy target = %+v, %v", storedTask, err)
	}
	github.context.HeadSHA = strings.Repeat("c", 40)
	svc = New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.SetPublisher(github)
	recovered, targeted, err := svc.engineeringTaskPullRequestTarget(ctx, storedTask)
	if err != nil || !targeted || recovered != target {
		t.Fatalf("pruned legacy target = %+v, %t, %v", recovered, targeted, err)
	}
}

func TestEngineeringTaskSessionUsesApprovedExistingPullRequestHead(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	repository := cfg.Repositories["repo"]
	repository.GitHubRepository = "owner/repo"
	repository.GitHubBaseBranch = "main"
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	source := core.SlackInput{
		ID: "slack-pr-task", EnvelopeID: "env-pr-task", EventID: "EvPRTask",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.100", UserID: cfg.Slack.Operators[0],
		Text: "Update https://github.com/owner/repo/pull/514",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %t, %v", created, err)
	}
	target := core.PullRequestTarget{
		Repository: "owner/repo", Number: 514,
		URL:        "https://github.com/owner/repo/pull/514",
		BaseBranch: "main", HeadBranch: "feature", HeadCommit: strings.Repeat("a", 40),
	}
	stateJSON, err := json.Marshal(decisionpkg.WatchTurnState{
		OfferedTaskTitle: "Update existing PR", OfferedTaskRepository: "repo",
		OfferedTaskPrompt: "Make the approved change.", OfferedTaskPullRequest: &target,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: source.ChannelID,
		ConversationKey: "channel:" + source.ChannelID,
		SourceKind:      "watch", SourceID: source.ID, Repository: "repo",
		Prompt: "offer task", Context: stateJSON,
	}); err != nil || !created {
		t.Fatalf("queue watch run = %t, %v", created, err)
	}
	task, created, err := st.CreateEngineeringTask(
		ctx, "repo", source.EventID, "Update existing PR", "Make the approved change.",
		cfg.Slack.Operators[0], source.ChannelID, source.MessageTS,
		cfg.Limits.MaxOpenIncidents, target,
	)
	if err != nil || !created {
		t.Fatalf("create task = %+v, %t, %v", task, created, err)
	}
	if err := st.BindThreadWork(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, task.ID, "1700.101"); err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseSlackInput(ctx)
	if err != nil || leased.ID != source.ID {
		t.Fatalf("lease source Slack input = %+v, %v", leased, err)
	}
	if err := st.FinishSlackInput(ctx, source.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Prune(
		ctx, time.Now().Add(time.Hour), time.Time{}, time.Time{}, time.Time{}, time.Time{},
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.GetSlackInput(ctx, source.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("source Slack input survived prune: %v", err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	st, err = store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil || task.TaskPullRequest == nil || *task.TaskPullRequest != target {
		t.Fatalf("restarted task PR binding = %+v, %v", task, err)
	}

	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processSessionIncident(ctx, task.ID); err != nil {
		t.Fatal(err)
	}
	if len(coopClient.createSources) != 1 ||
		coopClient.createSources[0].PullRequestNumber != target.Number ||
		coopClient.createSources[0].HeadCommit != target.HeadCommit {
		t.Fatalf("Coop session sources = %+v", coopClient.createSources)
	}
	initial, err := st.GetAgentRunBySource(ctx, "initial", task.ID)
	if err != nil || !strings.Contains(initial.Prompt, "Keep the bound branch checked out") ||
		!strings.Contains(initial.Prompt, target.HeadCommit) {
		t.Fatalf("bound PR task prompt = %q, %v", initial.Prompt, err)
	}
}
