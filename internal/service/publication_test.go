package service

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	publicationreview "github.com/AndrewDryga/responder/internal/publicationreview"
	"github.com/AndrewDryga/responder/internal/publisher"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestReviewSummaryTreatsMissingGateAsRecommendation(t *testing.T) {
	summary := publicationreview.ReviewSummary(coop.Review{
		Gate:   "none",
		Rebase: "clean",
		NotPublishableReasons: []string{
			"gate_not_configured",
			"gate_modified_candidate",
		},
	})
	for _, want := range []string{
		"Repository gate: not configured (recommended)",
		"can still open a draft PR",
		"Validation changed tracked files",
	} {
		if !strings.Contains(summary, want) {
			t.Fatalf("summary does not explain %q:\n%s", want, summary)
		}
	}
	for _, raw := range []string{"gate_not_configured", "gate_modified_candidate"} {
		if strings.Contains(summary, raw) {
			t.Fatalf("summary leaked machine reason %q:\n%s", raw, summary)
		}
	}
}

func TestPublicationReviewDoesNotHideRealBlockers(t *testing.T) {
	review := publicationreview.NormalizeReview(coop.Review{
		Gate:      "none",
		Rebase:    "conflict",
		GateError: "",
		NotPublishableReasons: []string{
			"gate_not_configured",
			"rebase_conflict",
		},
	})
	if review.Publishable || len(review.NotPublishableReasons) != 1 ||
		review.NotPublishableReasons[0] != "rebase_conflict" {
		t.Fatalf("ungated review hid blocker = %+v", review)
	}

	review = publicationreview.NormalizeReview(coop.Review{
		Gate: "none", Rebase: "clean",
		NotPublishableReasons: []string{"gate_not_configured"},
		PolicyFindings:        []string{"generated file is not allowed"},
	})
	if review.Publishable {
		t.Fatalf("ungated review ignored policy finding = %+v", review)
	}

	review = publicationreview.NormalizeReview(coop.Review{
		Gate: "failed", Rebase: "clean", GateError: "missing tflint",
		NotPublishableReasons: []string{"gate_failed", "gate_modified_candidate"},
	})
	if !review.Publishable || len(review.NotPublishableReasons) != 0 ||
		review.GateError != "missing tflint" {
		t.Fatalf("gate environment failure blocked draft review = %+v", review)
	}

	review = publicationreview.NormalizeReview(coop.Review{
		Gate: "startup_error", Rebase: "clean", GateError: "tflint not installed",
	})
	if !review.Publishable || len(review.NotPublishableReasons) != 0 {
		t.Fatalf("gate state without a reason code blocked draft review = %+v", review)
	}

	review = publicationreview.NormalizeReview(coop.Review{
		Gate: "failed", Rebase: "conflict", GateError: "missing tflint",
		NotPublishableReasons: []string{"gate_failed", "rebase_conflict"},
	})
	if review.Publishable || len(review.NotPublishableReasons) != 1 ||
		review.NotPublishableReasons[0] != "rebase_conflict" {
		t.Fatalf("gate warning hid rebase blocker = %+v", review)
	}
}

func TestPublicationReviewIgnoresOnlyPreExistingPolicyFindings(t *testing.T) {
	patch := []byte("" +
		"diff --git a/tools/test.go b/tools/test.go\n" +
		"--- a/tools/test.go\n" +
		"+++ b/tools/test.go\n" +
		"@@ -1,3 +1,4 @@\n" +
		" package tools\n" +
		"+const mode = \"balanced\"\n" +
		" const database = \"postgres://user:password@example.test/db\"\n" +
		" const safe = true\n")
	review := publicationreview.NormalizeReview(coop.Review{
		Gate: "failed", Rebase: "clean", Patch: patch,
		PolicyFindings: []string{
			"possible secret in tools/test.go:3 (password in a connection-string URL)",
		},
		NotPublishableReasons: []string{"gate_failed", "policy_findings"},
	})
	if !review.Publishable || len(review.PolicyFindings) != 0 ||
		len(review.NotPublishableReasons) != 0 {
		t.Fatalf("pre-existing policy finding blocked draft = %+v", review)
	}
	summary := publicationreview.ReviewSummary(coop.Review{
		Gate: "failed", Rebase: "clean", Patch: patch,
		PolicyFindings: []string{
			"possible secret in tools/test.go:3 (password in a connection-string URL)",
		},
		NotPublishableReasons: []string{"gate_failed", "policy_findings"},
	})
	if !strings.Contains(summary, "outside the lines changed by this task") {
		t.Fatalf("summary omitted baseline policy note:\n%s", summary)
	}

	patch = []byte(strings.Replace(
		string(patch),
		"+const mode = \"balanced\"",
		"+const database = \"postgres://user:password@example.test/db\"",
		1,
	))
	review = publicationreview.NormalizeReview(coop.Review{
		Gate: "passed", Rebase: "clean", Patch: patch,
		PolicyFindings: []string{
			"possible secret in tools/test.go:2 (password in a connection-string URL)",
		},
		NotPublishableReasons: []string{"policy_findings"},
	})
	if review.Publishable || len(review.PolicyFindings) != 1 ||
		len(review.NotPublishableReasons) != 1 {
		t.Fatalf("new policy finding did not block draft = %+v", review)
	}

	review = publicationreview.NormalizeReview(coop.Review{Gate: "passed", Rebase: "clean"})
	if review.Publishable {
		t.Fatalf("normalization overrode an unexplained non-publishable review = %+v", review)
	}
}

func TestPublicationReferenceMatchingIsExact(t *testing.T) {
	context := core.PublicationContext{
		PRNumber: 493, PRURL: "https://github.com/org/repo/pull/493",
		HeadBranch: "responder/reduce-redis", HeadSHA: "0123456789abcdef",
		MergeSHA: "abcdef0123456789",
	}
	if !publicationReferenceMatches(
		"Deployed commit abcdef0 to production", "abcdef0", context,
	) {
		t.Fatal("exact merge SHA prefix was not accepted")
	}
	if publicationReferenceMatches(
		"A deploy happened in org/repo", "org/repo", context,
	) {
		t.Fatal("repository-only correlation was accepted")
	}
	if publicationReferenceMatches(
		"Deployed a different commit", "0123456", context,
	) {
		t.Fatal("reference absent from the source message was accepted")
	}
	if !publicationContextAppearsInText(
		"Terraform applied main at abcdef0123456789", context,
	) {
		t.Fatal("exact merge SHA did not activate delivery correlation")
	}
	if publicationContextAppearsInText("Terraform applied org/repo", context) {
		t.Fatal("repository-only text activated delivery correlation")
	}
}

func TestChangedEngineeringTaskInvalidatesPublishedDraftPR(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-stale-pr", "Change Terraform", "summary",
		cfg.Slack.Operators[0], "CTASK", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	publication := core.Publication{
		IncidentID: task.ID, Repository: "owner/repo", BaseBranch: "main",
		HeadBranch: "responder/change-terraform", ParentHead: "parent",
		CandidateTree: "old-tree", CommitSHA: "old-commit", RemoteSHA: "old-commit",
		PRNumber: 29, PRURL: "https://github.com/owner/repo/pull/29",
		State: "published", PublishedAt: time.Now().UTC(),
	}
	if err := st.SavePublication(ctx, publication); err != nil {
		t.Fatal(err)
	}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	got, err := svc.markTaskPublicationStale(ctx, task)
	if err != nil || !got.NeedsUpdate() || got.PRNumber != publication.PRNumber {
		t.Fatalf("stale task publication = %+v, %v", got, err)
	}
	stored, err := st.GetPublication(ctx, task.ID)
	if err != nil || !stored.NeedsUpdate() || stored.Published() {
		t.Fatalf("stored stale task publication = %+v, %v", stored, err)
	}
}

func TestDraftPRInputFailureRecordsRetryingState(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-publication-retry", "Publish task", "summary",
		cfg.Slack.Operators[0], "COPS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	const secret = "super-secret-token"
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000, secret), nil,
	)
	admit := func(id, kind, actionID, actionValue string) core.SlackInput {
		t.Helper()
		input := core.SlackInput{
			ID: id, EnvelopeID: "env_" + id, EventID: "event_" + id,
			Kind: kind, TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
			MessageTS: "1700.101", UserID: cfg.Slack.Operators[0],
			ActionID: actionID, ActionValue: actionValue,
		}
		admitted, admitErr := st.AdmitSlackInput(ctx, input)
		if admitErr != nil || !admitted {
			t.Fatalf("admit publication input = %t, %v", admitted, admitErr)
		}
		leased, leaseErr := st.LeaseSlackInput(ctx)
		if leaseErr != nil {
			t.Fatal(leaseErr)
		}
		return leased
	}

	temporary := &coop.APIError{
		Status: 500, Code: "internal_error", Detail: secret + strings.Repeat("x", 1400),
	}
	first := admit("publication_retry", "action", slackui.ActionPublishPR, task.ID)
	if _, err := st.Publications.BeginReview(
		ctx, first.ID, first.ID, task.ID, "owner/repo", "main", nil,
	); err != nil {
		t.Fatal(err)
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if err := svc.retrySlackInput(cancelled, first, temporary); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetPublication(ctx, task.ID)
	if err != nil || stored.State != "retrying" ||
		!strings.Contains(stored.LastError, "internal_error") ||
		strings.Contains(stored.LastError, secret) || len(stored.LastError) > 1000 {
		t.Fatalf("retrying publication = %+v, %v", stored, err)
	}

}

func TestDraftPRSlashInputFailureRecordsTerminalState(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-publication-terminal", "Publish task", "summary",
		cfg.Slack.Operators[0], "COPS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	const secret = "super-secret-token"
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000, secret), nil,
	)
	input := core.SlackInput{
		ID: "publication_terminal", EnvelopeID: "env_publication_terminal",
		EventID: "event_publication_terminal", Kind: "slash",
		TeamID: cfg.Slack.TeamID, ChannelID: "COPS", MessageTS: "1700.101",
		UserID: cfg.Slack.Operators[0], ActionID: "/responder",
	}
	admitted, err := st.AdmitSlackInput(ctx, input)
	if err != nil || !admitted {
		t.Fatalf("admit terminal publication input = %t, %v", admitted, err)
	}
	leased, err := st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	// A slash or text route does not initially carry the publication action ID.
	// BeginReview binds it durably, and retrySlackInput reloads that binding.
	if _, err := st.Publications.BeginReview(
		ctx, leased.ID, leased.ID, task.ID, "owner/repo", "main", nil,
	); err != nil {
		t.Fatal(err)
	}
	leased.Failures = cfg.Limits.MaxSlackInputAttempts - 1
	temporary := &coop.APIError{
		Status: 500, Code: "internal_error", Detail: secret + strings.Repeat("x", 1400),
	}
	if err := svc.retrySlackInput(ctx, leased, temporary); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetPublication(ctx, task.ID)
	if err != nil || stored.State != core.PublicationFailed ||
		!strings.Contains(stored.LastError, "internal_error") ||
		strings.Contains(stored.LastError, secret) || len(stored.LastError) > 1000 {
		t.Fatalf("terminal publication = %+v, %v", stored, err)
	}
}

func TestButtonPublicationRetryRetainsAttemptOwnership(t *testing.T) {
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
	now := time.Now().UTC()
	st.SetClock(func() time.Time { return now })
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-button-retry", "Publish task", "summary",
		cfg.Slack.Operators[0], "COPS", "1700.100", 100,
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
	if err := st.SetCoopSession(ctx, task.ID, "session-button-retry", "fork", 1); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	baseCoop := newFakeCoop()
	baseCoop.session.ID = task.CoopSessionID
	baseCoop.session.Revision = 1
	coopClient := &publicationCoop{
		fakeCoop: baseCoop,
		changesErr: &coop.APIError{
			Status: 500, Code: "internal_error", Detail: "temporary review dependency",
		},
		changes: coop.Changes{
			ParentHead: "parent", Patch: []byte("+retry\n"),
			Unstaged: []coop.Change{{Path: "service.go", Status: "modified"}},
		},
		review: coop.Review{
			SessionID: task.CoopSessionID, SessionRevision: 1,
			ParentHead: "parent", CandidateTree: "tree", Rebase: "clean",
			Gate: "passed", Patch: []byte("+retry\n"), Publishable: true,
		},
	}
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.SetClock(func() time.Time { return now })
	svc.SetPublisher(&recordingPublisher{result: publisher.Result{
		HeadBranch: "responder/button-retry", CommitSHA: "commit",
		RemoteSHA: "commit", PRNumber: 43,
		PRURL: "https://github.example/owner/repo/pull/43",
	}})
	input := core.SlackInput{
		ID: "button-publication-retry", EnvelopeID: "env-button-publication-retry",
		EventID: "event-button-publication-retry", Kind: "action",
		TeamID: cfg.Slack.TeamID, ChannelID: task.ChannelID, MessageTS: task.RootTS,
		UserID: cfg.Slack.Operators[0], ActionID: slackui.ActionPublishPR,
		ActionValue: slackui.PublicationActionValue(task.ID, 0), ReceivedAt: now,
	}
	if admitted, err := st.AdmitSlackInput(ctx, input); err != nil || !admitted {
		t.Fatalf("admit publication button = %t, %v", admitted, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	retrying, err := st.GetPublication(ctx, task.ID)
	if err != nil || retrying.State != core.PublicationRetrying ||
		retrying.AttemptInputID != input.ID {
		t.Fatalf("retrying publication = %+v, %v", retrying, err)
	}
	storedInput, err := st.GetSlackInput(ctx, input.ID)
	if err != nil || storedInput.State != "retry" || storedInput.ActionValue != task.ID {
		t.Fatalf("bound retry input = %+v, %v", storedInput, err)
	}

	now = now.Add(3 * time.Second)
	coopClient.changesErr = nil
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	published, err := st.GetPublication(ctx, task.ID)
	if err != nil || !published.Published() || published.AttemptInputID != input.ID {
		t.Fatalf("retried publication = %+v, %v", published, err)
	}
	storedInput, err = st.GetSlackInput(ctx, input.ID)
	if err != nil || storedInput.State != "done" {
		t.Fatalf("completed publication input = %+v, %v", storedInput, err)
	}
}

func TestPublicationPersistsRemoteReceiptAfterWorkerCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
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
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-cancelled-receipt", "Publish task", "summary",
		cfg.Slack.Operators[0], "COPS", "1700.100", 100,
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
	if err := st.SetCoopSession(ctx, task.ID, "session-receipt", "fork", 1); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	coopClient := &publicationCoop{
		fakeCoop: newFakeCoop(),
		changes:  coop.Changes{Unstaged: []coop.Change{{Path: "service.go", Status: "modified"}}},
		review: coop.Review{
			SessionID: task.CoopSessionID, SessionRevision: 1,
			ParentHead: "parent", CandidateTree: "tree", Rebase: "clean",
			Gate: "passed", Patch: []byte("+change\n"), Publishable: true,
		},
	}
	publisherClient := &recordingPublisher{
		result: publisher.Result{
			HeadBranch: "responder/receipt", CommitSHA: "commit",
			RemoteSHA: "remote-after-push", PRNumber: 91,
			PRURL: "https://github.com/owner/repo/pull/91",
		},
		afterPublish: cancel,
	}
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.SetPublisher(publisherClient)
	if err := svc.publishDraftPR(ctx, core.SlackInput{
		ID: "publish-cancelled-receipt", Kind: controlPlaneInput,
		ChannelID: "COPS", UserID: cfg.Slack.Operators[0],
	}, task); err != nil {
		t.Fatal(err)
	}
	record, err := st.GetPublication(context.Background(), task.ID)
	if err != nil || !record.Published() || record.RemoteSHA != "remote-after-push" ||
		record.PRNumber != 91 {
		t.Fatalf("publication after cancellation = %+v, %v", record, err)
	}
	followup, followedPublication, err := st.NextPublicationFollowup(
		context.Background(), time.Now().UTC().Add(24*time.Hour),
	)
	if err != nil || followup.IncidentID != task.ID ||
		followedPublication.IncidentID != task.ID {
		t.Fatalf(
			"publication follow-up after cancellation = %+v, %+v, %v",
			followup, followedPublication, err,
		)
	}
}

func TestDraftPRRetryRefusalDoesNotLeaveProgressStuck(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-publication-refusal", "Publish task", "summary",
		cfg.Slack.Operators[0], "COPS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SavePublication(ctx, core.Publication{
		IncidentID: task.ID, Repository: "owner/repo", BaseBranch: "main",
		State: "retrying", LastError: "temporary Coop failure",
	}); err != nil {
		t.Fatal(err)
	}
	task.ActiveTurnID = "turn_now_running"
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.SetPublisher(&recordingPublisher{})
	err = svc.publishDraftPR(ctx, core.SlackInput{
		ID: "publication_retry_refusal", Kind: "action", ChannelID: "COPS",
		UserID: cfg.Slack.Operators[0], ActionID: slackui.ActionPublishPR,
		ActionValue: task.ID,
	}, task)
	if !errors.Is(err, errControlRefused) {
		t.Fatalf("publish retry with active turn = %v, want refusal", err)
	}
	publication, err := st.GetPublication(ctx, task.ID)
	if err != nil || publication.State != "failed" ||
		!strings.Contains(publication.LastError, "agent is still changing") {
		t.Fatalf("refused retry publication = %+v, %v", publication, err)
	}
}

func TestTerminalPublicationCardsUseDurableStateWithoutCoop(t *testing.T) {
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
	createTask := func(source, session string) core.Incident {
		t.Helper()
		task, _, createErr := st.CreateEngineeringTask(
			ctx, "repo", source, "Publish task", "summary",
			cfg.Slack.Operators[0], "COPS", "1700."+source, 100,
		)
		if createErr != nil {
			t.Fatal(createErr)
		}
		if createErr = st.BindThreadWork(ctx, task.ID); createErr != nil {
			t.Fatal(createErr)
		}
		if createErr = st.SetRoot(ctx, task.ID, "1800."+source); createErr != nil {
			t.Fatal(createErr)
		}
		if createErr = st.SetCoopSession(ctx, task.ID, session, "fork-"+source, 1); createErr != nil {
			t.Fatal(createErr)
		}
		task, createErr = st.GetIncident(ctx, task.ID)
		if createErr != nil {
			t.Fatal(createErr)
		}
		return task
	}

	empty := createTask("empty-terminal", "session-empty")
	coopClient := &publicationCoop{fakeCoop: newFakeCoop()}
	coopClient.session.ID = empty.CoopSessionID
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.SetPublisher(&recordingPublisher{})
	err = svc.publishDraftPR(ctx, core.SlackInput{
		ID: "empty-publication", Kind: controlPlaneInput, ChannelID: empty.ChannelID,
		UserID: cfg.Slack.Operators[0], ActionID: slackui.ActionPublishPR,
		ActionValue: empty.ID,
	}, empty)
	if err == nil || !strings.Contains(err.Error(), "nothing to publish") {
		t.Fatalf("empty publication = %v, want no-change refusal", err)
	}
	stored, err := st.GetPublication(ctx, empty.ID)
	if err != nil || stored.FailureCode != core.PublicationFailureNoChanges {
		t.Fatalf("durable empty publication = %+v, %v", stored, err)
	}

	stale := createTask("stale-terminal", "session-stale")
	publication := core.Publication{
		IncidentID: stale.ID, Generation: 1, Repository: "owner/repo", BaseBranch: "main",
		HeadBranch: "responder/stale", ParentHead: "parent", CandidateTree: "tree",
		CommitSHA: "commit", RemoteSHA: "commit", PRNumber: 42,
		PRURL: "https://github.example/owner/repo/pull/42",
		State: core.PublicationPublished, PublishedAt: time.Now().UTC(),
	}
	if err := st.SavePublication(ctx, publication); err != nil {
		t.Fatal(err)
	}
	if changed, err := st.MarkPublicationStale(ctx, stale.ID, "task changed"); err != nil || !changed {
		t.Fatalf("mark stale = %t, %v", changed, err)
	}

	blockedChanges := make(chan struct{})
	coopClient.releaseChanges = blockedChanges
	t.Cleanup(func() { close(blockedChanges) })
	assertImmediate := func(task core.Incident) slackui.Message {
		t.Helper()
		result := make(chan struct {
			message slackui.Message
			err     error
		}, 1)
		go func() {
			message, cardErr := svc.incidentCard(ctx, task)
			result <- struct {
				message slackui.Message
				err     error
			}{message: message, err: cardErr}
		}()
		select {
		case rendered := <-result:
			if rendered.err != nil {
				t.Fatal(rendered.err)
			}
			return rendered.message
		case <-time.After(500 * time.Millisecond):
			t.Fatalf("%s terminal card waited for Coop", task.ID)
			return slackui.Message{}
		}
	}
	emptyCard := assertImmediate(empty)
	if slices.ContainsFunc(emptyCard.Actions, func(action slackui.Action) bool {
		return action.ID == slackui.ActionPublishPR || action.ID == slackui.ActionChanges
	}) {
		t.Fatalf("empty failure offered impossible controls: %+v", emptyCard.Actions)
	}
	staleCard := assertImmediate(stale)
	for _, actionID := range []string{slackui.ActionChanges, slackui.ActionPublishPR, slackui.ActionViewPR} {
		if !slices.ContainsFunc(staleCard.Actions, func(action slackui.Action) bool {
			return action.ID == actionID
		}) {
			t.Fatalf("stale card lacks %s: %+v", actionID, staleCard.Actions)
		}
	}
}

func TestControlPlanePublicationFailureOnlyEndsItsOwnClaim(t *testing.T) {
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
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-control-publication", "Publish task", "summary",
		cfg.Slack.Operators[0], "COPS", "1700.100", 100,
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
	if err := st.SetCoopSession(ctx, task.ID, "session-control", "fork-control", 1); err != nil {
		t.Fatal(err)
	}
	baseCoop := newFakeCoop()
	baseCoop.session.ID = "session-control"
	baseCoop.session.Revision = 1
	coopClient := &publicationCoop{
		fakeCoop:  baseCoop,
		changes:   coop.Changes{Unstaged: []coop.Change{{Path: "main.go", Status: "modified"}}},
		reviewErr: errors.New("Coop review stopped"),
	}
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.SetPublisher(&recordingPublisher{})
	if err := svc.ControlPlaneAct(
		ctx, "publish", task.ID, "control-plane@localhost",
	); err == nil {
		t.Fatal("control-plane publication failure was hidden")
	}
	publication, err := st.GetPublication(ctx, task.ID)
	if err != nil || publication.State != "failed" ||
		!strings.Contains(publication.LastError, "Coop review stopped") {
		t.Fatalf("failed control-plane publication = %+v, %v", publication, err)
	}

	if _, err := st.Publications.BeginReview(
		ctx, "other-control-owner", "", task.ID, "owner/repo", "main", nil,
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.ControlPlaneAct(
		ctx, "publish", task.ID, "control-plane@localhost",
	); err == nil || !strings.Contains(err.Error(), "already in progress") {
		t.Fatalf("overlapping control-plane publication = %v", err)
	}
	publication, err = st.GetPublication(ctx, task.ID)
	if err != nil || publication.State != "reviewing" {
		t.Fatalf("overlap ended another publication claim = %+v, %v", publication, err)
	}
}

func TestCloseRefusesWhileDraftPRWorkOwnsTask(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-close-publication", "Publish task", "summary",
		cfg.Slack.Operators[0], "COPS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Publications.BeginReview(
		ctx, "publication-owner", "", task.ID, "owner/repo", "main", nil,
	); err != nil {
		t.Fatal(err)
	}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	err = svc.ControlPlaneAct(ctx, "close", task.ID, "control-plane@localhost")
	if err == nil || !strings.Contains(err.Error(), "draft PR work is still active") {
		t.Fatalf("close during publication = %v", err)
	}
	stored, err := st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.Status == core.IncidentClosed || stored.Workflow == core.WorkflowClosing {
		t.Fatalf("close raced publication: %+v", stored)
	}
	publication, err := st.GetPublication(ctx, task.ID)
	if err != nil || publication.State != core.PublicationReviewing {
		t.Fatalf("publication after refused close = %+v, %v", publication, err)
	}
}

func TestPublicationBindingDriftEndsAutomaticRetryWithoutCrossWiringPR(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	repository := cfg.Repositories["repo"]
	repository.Path = t.TempDir()
	repository.GitHubRepository = "new-owner/new-repo"
	repository.GitHubBaseBranch = "release"
	cfg.Repositories["repo"] = repository
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-binding-drift", "Publish task", "summary",
		cfg.Slack.Operators[0], "COPS", "1700.100", 100,
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
	if err := st.SetCoopSession(ctx, task.ID, "session-binding", "fork-binding", 1); err != nil {
		t.Fatal(err)
	}
	task, err = st.GetIncident(ctx, task.ID)
	if err != nil {
		t.Fatal(err)
	}
	publication := core.Publication{
		IncidentID: task.ID, Repository: "old-owner/old-repo", BaseBranch: "main",
		HeadBranch: "responder/task", ParentHead: "parent", CandidateTree: "tree",
		CommitSHA: "commit", RemoteSHA: "commit", PRNumber: 42,
		PRURL: "https://github.example/old-owner/old-repo/pull/42",
		State: "retrying", PublishedAt: time.Now().UTC(),
	}
	if err := st.SavePublication(ctx, publication); err != nil {
		t.Fatal(err)
	}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.SetPublisher(&recordingPublisher{})
	err = svc.publishDraftPR(ctx, core.SlackInput{
		ID: "binding-drift", Kind: "action", ChannelID: "COPS",
		UserID: cfg.Slack.Operators[0], ActionID: slackui.ActionPublishPR,
		ActionValue: task.ID,
	}, task)
	if !errors.Is(err, errControlRefused) {
		t.Fatalf("binding drift retry = %v, want refusal", err)
	}
	stored, err := st.GetPublication(ctx, task.ID)
	if err != nil || stored.State != "failed" ||
		stored.Repository != publication.Repository || stored.BaseBranch != publication.BaseBranch ||
		stored.PRNumber != publication.PRNumber {
		t.Fatalf("failed binding-drift retry = %+v, %v", stored, err)
	}
}

func TestPublicationUpdateReturnsToOriginalTaskThreadAndDeduplicates(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-publication", "Reduce Redis pool", "summary",
		"U123ABC", "CTASKS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindThreadWork(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incident.ID, "1700.101"); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	publication := core.Publication{
		IncidentID: incident.ID, Repository: "owner/repository", BaseBranch: "main",
		HeadBranch: "responder/reduce-redis", ParentHead: "parent", CandidateTree: "tree",
		CommitSHA: "commit", RemoteSHA: "0123456789abcdef", PRNumber: 493,
		PRURL: "https://github.com/owner/repository/pull/493", State: "published",
		PublishedAt: time.Now().UTC(),
	}
	if err := st.SavePublication(ctx, publication); err != nil {
		t.Fatal(err)
	}
	if err := st.EnsurePublicationFollowup(ctx, incident.ID, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	input := core.SlackInput{
		ID: "input-deploy-1", Kind: "bot_message", ChannelID: "CDEPLOY",
		MessageTS: "1700.200", Text: "Run run-abc\nRevision 0123456\nRun Planning",
	}
	state := decisionpkg.WatchTurnState{ActivePublications: []core.PublicationContext{{
		IncidentID: incident.ID, PRNumber: 493, PRURL: publication.PRURL,
		HeadBranch: publication.HeadBranch, HeadSHA: publication.RemoteSHA,
	}}}
	for index, summary := range []string{
		"The run is planning.",
		"The run is applying.",
		"The visible notification is still nonterminal.",
	} {
		input.ID = fmt.Sprintf("input-deploy-pending-%d", index)
		input.MessageTS = fmt.Sprintf("1700.20%d", index)
		input.Text = "Run run-abc\nRevision 0123456\n" + summary
		if err := svc.applyPublicationUpdates(ctx, input, state, []decisionpkg.PublicationUpdate{{
			IncidentID: incident.ID, Kind: "terraform", State: "pending",
			Reference: "0123456", Summary: summary,
		}}); err != nil {
			t.Fatal(err)
		}
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.posts) != 0 {
		t.Fatalf("pending publication update posts = %d, want 0", len(slackClient.posts))
	}

	input.ID = "input-deploy-terminal-1"
	input.MessageTS = "1700.300"
	input.Text = "Run run-abc\nRevision 0123456\nRun Applied"
	if err := svc.applyPublicationUpdates(ctx, input, state, []decisionpkg.PublicationUpdate{{
		IncidentID: incident.ID, Kind: "terraform", State: "succeeded",
		Reference: "0123456", Summary: "Production apply completed successfully.",
	}}); err != nil {
		t.Fatal(err)
	}
	input.ID = "input-deploy-terminal-2"
	input.MessageTS = "1700.400"
	input.Text = "Run run-abc\nRevision 0123456789abcdef\nRun Applied"
	if err := svc.applyPublicationUpdates(ctx, input, state, []decisionpkg.PublicationUpdate{{
		IncidentID: incident.ID, Kind: "deployment", State: "succeeded",
		Reference: "0123456789abcdef", Summary: "HCP reports the exact run as applied.",
	}}); err != nil {
		t.Fatal(err)
	}
	if err := svc.processCard(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.posts) != 0 || len(slackClient.updates) != 1 {
		t.Fatalf("publication update delivery = posts %d, updates %d", len(slackClient.posts), len(slackClient.updates))
	}
	update := slackClient.updates[0]
	rendered := update.message.Text + "\n" + strings.Join(update.message.Sections, "\n")
	if update.channel != "CTASKS" || update.ts != incident.RootTS ||
		!strings.Contains(rendered, "HCP reports the exact run as applied") {
		t.Fatalf("publication update card = %+v", update)
	}
}

func TestPinnedScheduledSessionUsesTaskRepositoryWithoutReplacingChannelSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Repositories["infra"] = config.Repository{
		DisplayName: "Infrastructure",
		CoopPolicy:  "infra-observe",
	}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.Intelligence.BindChannelSession(
		ctx, "CREPORT", "repo", "ses_channel", 1, 1, time.Now().UTC(),
	); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	memory, _, err := svc.ensureWatchSessionForRepositoryAtGeneration(
		ctx, "scheduled:health", "infra", 1,
	)
	if err != nil {
		t.Fatal(err)
	}
	if memory.Repository != "infra" || memory.ChannelID != "scheduled:health" {
		t.Fatalf("scheduled memory = %+v", memory)
	}
	if !slices.Equal(coopClient.createPolicies, []string{"infra-observe"}) {
		t.Fatalf("Coop create policies = %v", coopClient.createPolicies)
	}
	channel, err := st.Intelligence.GetChannelMemory(ctx, "CREPORT")
	if err != nil {
		t.Fatal(err)
	}
	if channel.Repository != "repo" || channel.SessionID != "ses_channel" {
		t.Fatalf("delivery channel session was replaced: %+v", channel)
	}
}
