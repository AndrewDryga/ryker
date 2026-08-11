package service

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestReviewSummaryTreatsMissingGateAsRecommendation(t *testing.T) {
	summary := reviewSummary(coop.Review{
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
	review := publicationReview(coop.Review{
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

	review = publicationReview(coop.Review{
		Gate: "none", Rebase: "clean",
		NotPublishableReasons: []string{"gate_not_configured"},
		PolicyFindings:        []string{"generated file is not allowed"},
	})
	if review.Publishable {
		t.Fatalf("ungated review ignored policy finding = %+v", review)
	}

	review = publicationReview(coop.Review{
		Gate: "failed", Rebase: "clean", GateError: "missing tflint",
		NotPublishableReasons: []string{"gate_failed", "gate_modified_candidate"},
	})
	if !review.Publishable || len(review.NotPublishableReasons) != 0 ||
		review.GateError != "missing tflint" {
		t.Fatalf("gate environment failure blocked draft review = %+v", review)
	}

	review = publicationReview(coop.Review{
		Gate: "startup_error", Rebase: "clean", GateError: "tflint not installed",
	})
	if !review.Publishable || len(review.NotPublishableReasons) != 0 {
		t.Fatalf("gate state without a reason code blocked draft review = %+v", review)
	}

	review = publicationReview(coop.Review{
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
	review := publicationReview(coop.Review{
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
	summary := reviewSummary(coop.Review{
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
	review = publicationReview(coop.Review{
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

	review = publicationReview(coop.Review{Gate: "passed", Rebase: "clean"})
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
