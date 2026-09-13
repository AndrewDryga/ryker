package store

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/store/publicationstore"
)

func TestPublicationCanRecoverBeforeBranchIdentityIsKnown(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	incidents, err := st.ApplySignals(ctx, testWebhookEvent(), time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incident = %+v, %v", incidents, err)
	}
	publication := core.Publication{
		IncidentID: incidents[0].ID, Repository: "owner/repository", BaseBranch: "main",
		State: "reviewing",
	}
	if err := st.SavePublication(ctx, publication); err != nil {
		t.Fatalf("save readiness-review publication: %v", err)
	}
	stored, err := st.GetPublication(ctx, incidents[0].ID)
	if err != nil || stored.ParentHead != "" || stored.State != "reviewing" {
		t.Fatalf("stored publication = %+v, %v", stored, err)
	}
	publication.State = "publishing"
	if err := st.SavePublication(ctx, publication); err == nil {
		t.Fatal("publishing record without a reviewed tree was accepted")
	}
	publication.ParentHead = "parent"
	publication.CandidateTree = "tree"
	if err := st.SavePublication(ctx, publication); err != nil {
		t.Fatalf("save pre-side-effect publication: %v", err)
	}

	publication.State = "published"
	if err := st.SavePublication(ctx, publication); err == nil {
		t.Fatal("published record without remote proof was accepted")
	}
	publication.HeadBranch = "ryker/fix"
	publication.CommitSHA = "commit"
	publication.RemoteSHA = "commit"
	publication.PRNumber = 12
	publication.PRURL = "https://github.com/owner/repository/pull/12"
	publication.PublishedAt = time.Now().UTC()
	if err := st.SavePublication(ctx, publication); err != nil {
		t.Fatalf("save proved publication: %v", err)
	}
	changed, err := st.MarkPublicationStale(
		ctx,
		publication.IncidentID,
		"The task changed after publication.",
	)
	if err != nil || !changed {
		t.Fatalf("mark publication stale = %t, %v", changed, err)
	}
	stored, err = st.GetPublication(ctx, publication.IncidentID)
	if err != nil || !stored.NeedsUpdate() || stored.Published() ||
		stored.PRNumber != publication.PRNumber {
		t.Fatalf("stale publication = %+v, %v", stored, err)
	}
	changed, err = st.MarkPublicationStale(
		ctx,
		publication.IncidentID,
		"Repeated invalidation.",
	)
	if err != nil || changed {
		t.Fatalf("repeated stale mark = %t, %v", changed, err)
	}
}

func TestPublicationReviewClaimIsExclusiveAndKeepsPRBinding(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "publication-claim", "Publish task", "summary",
		"UOP", "COPS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	claimed, err := st.Publications.BeginReview(
		ctx, "claim-first", "", task.ID, "owner/repo", "main", nil,
	)
	if err != nil || claimed.State != "reviewing" {
		t.Fatalf("first review claim = %+v, %v", claimed, err)
	}
	if _, err := st.Publications.BeginReview(
		ctx, "claim-second", "", task.ID, "owner/repo", "main", nil,
	); !errors.Is(err, publicationstore.ErrInProgress) {
		t.Fatalf("concurrent review claim = %v, want in-progress conflict", err)
	}
	claimed.ParentHead = "parent"
	claimed.CandidateTree = "tree"
	claimed.State = core.PublicationPublishing
	if err := st.SavePublication(ctx, claimed); err != nil {
		t.Fatal(err)
	}
	claimed.State = core.PublicationPublished
	claimed.HeadBranch = "ryker/task"
	claimed.CommitSHA = "commit"
	claimed.RemoteSHA = "commit"
	claimed.PRNumber = 42
	claimed.PRURL = "https://github.example/owner/repo/pull/42"
	claimed.PublishedAt = time.Now().UTC()
	if err := st.SavePublication(ctx, claimed); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Publications.BeginReview(
		ctx, "claim-rebind", "", task.ID, "other/repo", "main", nil,
	); !errors.Is(err, publicationstore.ErrBindingChanged) {
		t.Fatalf("changed repository claim = %v, want binding refusal", err)
	}
	stored, err := st.GetPublication(ctx, task.ID)
	if err != nil || stored.Repository != "owner/repo" || stored.PRNumber != 42 ||
		!stored.Published() {
		t.Fatalf("publication after rejected rebind = %+v, %v", stored, err)
	}
}

func TestPublicationReviewClaimSeedsExistingPullRequestLease(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "publication-existing-pr", "Update PR", "summary",
		"UOP", "COPS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	target := core.PullRequestTarget{
		Repository: "owner/repo", Number: 514,
		URL:        "https://github.com/owner/repo/pull/514",
		BaseBranch: "main", HeadBranch: "feature", HeadCommit: strings.Repeat("a", 40),
	}
	claimed, err := st.Publications.BeginReview(
		ctx, "claim-existing", "", task.ID, "owner/repo", "main", &target,
	)
	if err != nil || claimed.PRNumber != 514 || claimed.PRURL != target.URL ||
		claimed.HeadBranch != target.HeadBranch || claimed.RemoteSHA != target.HeadCommit {
		t.Fatalf("existing PR claim = %+v, %v", claimed, err)
	}
	claimed.State = core.PublicationFailed
	claimed.LastError = "retry"
	if err := st.SavePublication(ctx, claimed); err != nil {
		t.Fatal(err)
	}
	reclaimed, err := st.Publications.BeginReview(
		ctx, "claim-existing-again", "", task.ID, "owner/repo", "main", &target,
	)
	if err != nil || reclaimed.PRNumber != target.Number ||
		reclaimed.RemoteSHA != target.HeadCommit {
		t.Fatalf("existing PR reclaim = %+v, %v", reclaimed, err)
	}
	reclaimed.State = core.PublicationFailed
	reclaimed.LastError = "retry"
	if err := st.SavePublication(ctx, reclaimed); err != nil {
		t.Fatal(err)
	}
	changed := target
	changed.Number = 515
	changed.URL = "https://github.com/owner/repo/pull/515"
	if _, err := st.Publications.BeginReview(
		ctx, "claim-other-pr", "", task.ID, "owner/repo", "main", &changed,
	); !errors.Is(err, publicationstore.ErrBindingChanged) {
		t.Fatalf("changed PR claim = %v, want binding refusal", err)
	}
}

func TestPublicationReviewClaimPreservesPushedBranchWithoutPullRequestReceipt(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "publication-pushed-branch", "Create PR", "summary",
		"UOP", "COPS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	claimed, err := st.Publications.BeginReview(
		ctx, "claim-pushed", "", task.ID, "owner/repo", "main", nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	claimed.State = core.PublicationFailed
	claimed.HeadBranch = "ryker/pushed"
	claimed.RemoteSHA = strings.Repeat("b", 40)
	claimed.LastError = "GitHub response was lost after the push"
	if err := st.SavePublication(ctx, claimed); err != nil {
		t.Fatal(err)
	}
	reclaimed, err := st.Publications.BeginReview(
		ctx, "claim-pushed-again", "", task.ID, "owner/repo", "main", nil,
	)
	if err != nil || reclaimed.HeadBranch != claimed.HeadBranch ||
		reclaimed.RemoteSHA != claimed.RemoteSHA || reclaimed.PRNumber != 0 {
		t.Fatalf("reclaimed pushed branch = %+v, %v", reclaimed, err)
	}
}

func TestPublicationReviewClaimCoalescesQueuedDuplicateClick(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "publication-coalesce", "Publish task", "summary",
		"UOP", "COPS", "1700.101", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	for index, id := range []string{"slack-publish-first", "slack-publish-second"} {
		input := core.SlackInput{
			ID: id, EnvelopeID: "envelope-" + id, EventID: "event-" + id,
			Kind: "action", TeamID: "T1", ChannelID: "COPS", UserID: "UOP",
			ActionID: "responder_publish_pr", ActionValue: task.ID,
			ReceivedAt: time.Now().UTC().Add(time.Duration(index) * time.Second),
		}
		if created, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !created {
			t.Fatalf("admit duplicate publication click = %t, %v", created, admitErr)
		}
	}
	first, err := st.LeaseSlackInput(ctx)
	if err != nil || first.ID != "slack-publish-first" {
		t.Fatalf("first publication click = %+v, %v", first, err)
	}
	if _, err := st.Publications.BeginReview(
		ctx, first.ID, first.ID, task.ID, "owner/repo", "main", nil,
	); err != nil {
		t.Fatal(err)
	}
	second, err := st.GetSlackInput(ctx, "slack-publish-second")
	if err != nil || second.State != "done" {
		t.Fatalf("coalesced publication click = %+v, %v", second, err)
	}
	if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, ErrNotFound) {
		t.Fatalf("duplicate publication click remained runnable: %v", err)
	}
}

func TestPublicationLateDuplicateCoalescesAndOldAttemptCannotOverwriteNewerClaim(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	task, _, err := st.CreateEngineeringTask(
		ctx, "repo", "publication-late-coalesce", "Publish task", "summary",
		"UOP", "COPS", "1700.102", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	admit := func(id string, received time.Time) core.SlackInput {
		t.Helper()
		input := core.SlackInput{
			ID: id, EnvelopeID: "envelope-" + id, EventID: "event-" + id,
			Kind: "action", TeamID: "T1", ChannelID: "COPS", UserID: "UOP",
			ActionID: "responder_publish_pr", ActionValue: task.ID, ReceivedAt: received,
		}
		if created, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !created {
			t.Fatalf("admit publication input = %t, %v", created, admitErr)
		}
		return input
	}
	first := admit("slack-late-first", time.Now().Add(-2*time.Second))
	leased, err := st.LeaseSlackInput(ctx)
	if err != nil || leased.ID != first.ID {
		t.Fatalf("lease first publication = %+v, %v", leased, err)
	}
	claimed, err := st.Publications.BeginReview(
		ctx, first.ID, first.ID, task.ID, "owner/repo", "main", nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	second := admit("slack-late-second", time.Now().Add(-time.Second))
	claimed.ParentHead = "parent"
	claimed.CandidateTree = "tree"
	claimed.HeadBranch = "ryker/task"
	claimed.CommitSHA = "commit"
	claimed.RemoteSHA = "commit"
	claimed.PRNumber = 42
	claimed.PRURL = "https://github.example/owner/repo/pull/42"
	claimed.PublishedAt = time.Now().UTC()
	claimed.State = core.PublicationPublishing
	if err := st.SavePublication(ctx, claimed); err != nil {
		t.Fatal(err)
	}
	claimed.State = core.PublicationPublished
	if err := st.SavePublication(ctx, claimed); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Publications.BeginReview(
		ctx, "click-from-pre-success-card", "", task.ID, "owner/repo", "main", nil, 0,
	); !errors.Is(err, publicationstore.ErrCoalesced) {
		t.Fatalf("pre-success button after terminal save = %v, want coalesced", err)
	}
	if err := st.FinishSlackInput(ctx, first.ID); err != nil {
		t.Fatal(err)
	}
	leased, err = st.LeaseSlackInput(ctx)
	if err != nil || leased.ID != second.ID {
		t.Fatalf("lease late publication = %+v, %v", leased, err)
	}
	if _, err := st.Publications.BeginReview(
		ctx, second.ID, second.ID, task.ID, "owner/repo", "main", nil,
	); !errors.Is(err, publicationstore.ErrCoalesced) {
		t.Fatalf("late duplicate claim = %v, want coalesced", err)
	}
	if err := st.FinishSlackInput(ctx, second.ID); err != nil {
		t.Fatal(err)
	}

	third := admit("slack-fresh-third", time.Now().Add(time.Minute))
	leased, err = st.LeaseSlackInput(ctx)
	if err != nil || leased.ID != third.ID {
		t.Fatalf("lease fresh publication = %+v, %v", leased, err)
	}
	newClaim, err := st.Publications.BeginReview(
		ctx, third.ID, third.ID, task.ID, "owner/repo", "main", nil,
	)
	if err != nil || newClaim.AttemptInputID != third.ID {
		t.Fatalf("fresh publication claim = %+v, %v", newClaim, err)
	}
	stale := claimed
	stale.State = core.PublicationFailed
	stale.LastError = "late failure from old worker"
	if err := st.SavePublication(ctx, stale); !errors.Is(err, publicationstore.ErrAttemptLost) {
		t.Fatalf("stale attempt write = %v, want ownership refusal", err)
	}
	stored, err := st.GetPublication(ctx, task.ID)
	if err != nil || stored.State != core.PublicationReviewing ||
		stored.AttemptInputID != third.ID {
		t.Fatalf("publication after stale write = %+v, %v", stored, err)
	}
}

func TestPublicationClaimAndIncidentCloseAreMutuallyExclusive(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	create := func(source string) core.Incident {
		t.Helper()
		task, _, createErr := st.CreateEngineeringTask(
			ctx, "repo", source, "Publish task", "summary",
			"UOP", "COPS", "1700."+source, 100,
		)
		if createErr != nil {
			t.Fatal(createErr)
		}
		return task
	}

	publishing := create("close-after-publish")
	if _, err := st.Publications.BeginReview(
		ctx, "publish-owner", "", publishing.ID, "owner/repo", "main", nil,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Publications.BeginClose(
		ctx, publishing.ID,
	); !errors.Is(err, publicationstore.ErrCloseConflict) {
		t.Fatalf("close during publication = %v, want conflict", err)
	}

	closing := create("publish-after-close")
	previous, err := st.Publications.BeginClose(ctx, closing.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Publications.BeginReview(
		ctx, "late-publish", "", closing.ID, "owner/repo", "main", nil,
	); !errors.Is(err, publicationstore.ErrWorkUnavailable) {
		t.Fatalf("publication during close = %v, want unavailable", err)
	}
	if err := st.Publications.RestoreClose(ctx, closing.ID, previous); err != nil {
		t.Fatal(err)
	}
}

func TestRecoverInterruptedPublicationProgressUpdatesTaskCards(t *testing.T) {
	ctx := context.Background()
	stateDir := filepath.Join(t.TempDir(), "state")
	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	type createdPublication struct {
		task  core.Incident
		input core.SlackInput
	}
	create := func(source, state string, withPR, boundInput bool) createdPublication {
		t.Helper()
		task, _, createErr := st.CreateEngineeringTask(
			ctx, "repo", source, "Publish task", "summary", "UOP", "COPS",
			"1700."+source, 100,
		)
		if createErr != nil {
			t.Fatal(createErr)
		}
		if err := st.BindThreadWork(ctx, task.ID); err != nil {
			t.Fatal(err)
		}
		if err := st.SetRoot(ctx, task.ID, "1800."+source); err != nil {
			t.Fatal(err)
		}
		publication := core.Publication{IncidentID: task.ID, Repository: "owner/repo", BaseBranch: "main"}
		var input core.SlackInput
		if boundInput {
			input = core.SlackInput{
				ID: "slack-" + source, EnvelopeID: "envelope-" + source,
				EventID: "event-" + source, Kind: "slash", TeamID: "T1", ChannelID: "COPS",
				UserID: "UOP", Text: "publish", ReceivedAt: time.Now().UTC(),
			}
			if created, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !created {
				t.Fatalf("admit publication input = %t, %v", created, admitErr)
			}
			leased, leaseErr := st.LeaseSlackInput(ctx)
			if leaseErr != nil || leased.ID != input.ID {
				t.Fatalf("lease publication input = %+v, %v", leased, leaseErr)
			}
			publication, err = st.Publications.BeginReview(
				ctx, input.ID, input.ID, task.ID, "owner/repo", "main", nil,
			)
			if err != nil {
				t.Fatal(err)
			}
		} else {
			publication.State = core.PublicationState(state)
		}
		if state == "publishing" || state == "published" {
			publication.ParentHead = "parent"
			publication.CandidateTree = "tree"
		}
		if withPR {
			publication.HeadBranch = "ryker/existing"
			publication.CommitSHA = "commit"
			publication.RemoteSHA = "commit"
			publication.PRNumber = 42
			publication.PRURL = "https://github.example/owner/repo/pull/42"
			publication.PublishedAt = time.Now().UTC()
		}
		if publication.State != core.PublicationState(state) || withPR {
			if state == "published" {
				publication.State = core.PublicationPublishing
				if err := st.SavePublication(ctx, publication); err != nil {
					t.Fatal(err)
				}
			}
			publication.State = core.PublicationState(state)
			if err := st.SavePublication(ctx, publication); err != nil {
				t.Fatal(err)
			}
		} else if !boundInput {
			if err := st.SavePublication(ctx, publication); err != nil {
				t.Fatal(err)
			}
		}
		task, err = st.GetIncident(ctx, task.ID)
		if err != nil {
			t.Fatal(err)
		}
		if err := st.MarkCardRendered(ctx, task.ID, task.CardVersion); err != nil {
			t.Fatal(err)
		}
		return createdPublication{task: task, input: input}
	}
	reviewing := create("reviewing", "reviewing", false, true)
	publishing := create("publishing", "publishing", true, true)
	failedBeforeFinish := create("failed", "failed", false, true)
	publishedBeforeFinish := create("published", "published", true, true)
	orphaned := create("orphaned", "publishing", true, false)
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	st, err = Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.RecoverInterrupted(ctx); err != nil {
		t.Fatal(err)
	}

	recoveredReview, err := st.GetPublication(ctx, reviewing.task.ID)
	if err != nil || recoveredReview.State != "retrying" ||
		!strings.Contains(recoveredReview.LastError, "retry is scheduled") {
		t.Fatalf("recovered readiness review = %+v, %v", recoveredReview, err)
	}
	recoveredPublish, err := st.GetPublication(ctx, publishing.task.ID)
	if err != nil || recoveredPublish.State != "retrying" || !recoveredPublish.HasPR() ||
		!strings.Contains(recoveredPublish.LastError, "retry is scheduled") {
		t.Fatalf("recovered publication = %+v, %v", recoveredPublish, err)
	}
	recoveredFailure, err := st.GetPublication(ctx, failedBeforeFinish.task.ID)
	if err != nil || recoveredFailure.State != "failed" {
		t.Fatalf("recovered failure before input completion = %+v, %v", recoveredFailure, err)
	}
	recoveredOrphan, err := st.GetPublication(ctx, orphaned.task.ID)
	if err != nil || recoveredOrphan.State != "failed" || !recoveredOrphan.HasPR() ||
		!strings.Contains(recoveredOrphan.LastError, "retry it from the task card") {
		t.Fatalf("recovered orphaned publication = %+v, %v", recoveredOrphan, err)
	}
	for _, item := range []createdPublication{reviewing, publishing} {
		input, inputErr := st.GetSlackInput(ctx, item.input.ID)
		if inputErr != nil || input.State != "retry" ||
			input.ActionID != "responder_publish_pr" || input.ActionValue != item.task.ID {
			t.Fatalf("recovered publication input = %+v, %v", input, inputErr)
		}
	}
	failedInput, err := st.GetSlackInput(ctx, failedBeforeFinish.input.ID)
	if err != nil || failedInput.State != "done" {
		t.Fatalf("terminal publication input was replayed = %+v, %v", failedInput, err)
	}
	publishedInput, err := st.GetSlackInput(ctx, publishedBeforeFinish.input.ID)
	if err != nil || publishedInput.State != "done" {
		t.Fatalf("published input was replayed = %+v, %v", publishedInput, err)
	}
	if _, err := st.PublicationFollowups.Get(ctx, publishedBeforeFinish.task.ID); err != nil {
		t.Fatalf("published restart did not restore follow-up: %v", err)
	}
	dirty, err := st.ListDirtyCards(ctx, 10)
	if err != nil || len(dirty) != 3 {
		t.Fatalf("dirty recovered task cards = %+v, %v", dirty, err)
	}
}

func TestEngineeringTaskKeepsRestartSafeWorkCard(t *testing.T) {
	ctx := context.Background()
	stateDir := filepath.Join(t.TempDir(), "state")
	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	incident, created, err := st.CreateEngineeringTask(
		ctx, "repo", "source-1", "Fix credential propagation", "Prepare a focused fix.",
		"UOP", "COPS", "1700.100", 100,
	)
	if err != nil || !created {
		t.Fatalf("create task = %+v, %t, %v", incident, created, err)
	}
	// The card is a message of its own, posted into the source thread — not the
	// offer message rewritten in place. This is that sequence: bind the thread,
	// then record the timestamp the posted card came back with.
	if err := st.BindThreadWork(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incident.ID, "1700.101"); err != nil {
		t.Fatal(err)
	}
	if err := st.TaskCards.SetUpdate(ctx, incident.ID, "", "Draft PR #526 is ready."); err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}

	st, err = Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if incident.ChannelID != "COPS" || incident.RootTS != "1700.101" ||
		incident.Workflow != core.WorkflowProvisioningSession ||
		incident.LatestUpdate != "Draft PR #526 is ready." {
		t.Fatalf("restart-safe task card = %+v", incident)
	}
}

func TestIdenticalTaskUpdateFromNewRunRepaintsAndPersistsOwner(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-identical", "Keep ownership exact", "summary",
		"UOP", "COPS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.TaskCards.SetUpdate(ctx, incident.ID, "run-first", "Checks passed."); err != nil {
		t.Fatal(err)
	}
	first, err := st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.TaskCards.SetUpdate(ctx, incident.ID, "run-second", "Checks passed."); err != nil {
		t.Fatal(err)
	}
	second, err := st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if second.LatestUpdateRunID != "run-second" || second.CardVersion != first.CardVersion+1 {
		t.Fatalf("second identical update = %+v; first version %d", second, first.CardVersion)
	}
}

func TestIdenticalTaskUpdateFromRetriedRunRepaintsForNewExecution(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-retried", "Keep retry ownership exact", "summary",
		"UOP", "COPS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID, ChannelID: "COPS",
		ConversationKey: "incident:" + incident.ID, SourceKind: "incident", SourceID: incident.ID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.db.ExecContext(ctx, `UPDATE agent_runs SET state = 'preparing' WHERE id = ?`, run.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.TaskCards.SetUpdate(ctx, incident.ID, run.ID, "Checks passed."); err != nil {
		t.Fatal(err)
	}
	first, err := st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, applied, err := st.FinishAgentRunFailure(ctx, run.ID, "failed", nil, AgentRunFailureEffects{}); err != nil || !applied {
		t.Fatalf("fail first execution = %t, %v", applied, err)
	}
	if err := st.RequeueFailedAgentRun(ctx, run.ID, "retry"); err != nil {
		t.Fatal(err)
	}
	beforeUpdate, err := st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.TaskCards.SetUpdate(ctx, incident.ID, run.ID, "Checks passed."); err != nil {
		t.Fatal(err)
	}
	second, err := st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if second.LatestUpdateRunKey == first.LatestUpdateRunKey || second.CardVersion != beforeUpdate.CardVersion+1 {
		t.Fatalf("retry update = %+v; first key %q pre-update version %d", second, first.LatestUpdateRunKey, beforeUpdate.CardVersion)
	}
}

func TestPublicationFollowupPersistsLifecycleAndActiveContext(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident, _, err := st.CreateEngineeringTask(
		ctx, "blitz-infra", "source-1", "Reduce Redis pool", "summary", "UOP",
		"COPS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	publication := core.Publication{
		IncidentID: incident.ID, Repository: "owner/blitz-infra", BaseBranch: "main",
		HeadBranch: "ryker/reduce-redis", ParentHead: "parent", CandidateTree: "tree",
		CommitSHA: "commit", RemoteSHA: "0123456789abcdef", PRNumber: 493,
		PRURL: "https://github.example/owner/blitz-infra/pull/493",
		State: "published", PublishedAt: now,
	}
	if err := st.SavePublication(ctx, publication); err != nil {
		t.Fatal(err)
	}
	if err := st.PublicationFollowups.Ensure(ctx, incident.ID, now); err != nil {
		t.Fatal(err)
	}
	followup, gotPublication, err := st.PublicationFollowups.Next(ctx, now.Add(time.Second))
	if err != nil || followup.IncidentID != incident.ID || gotPublication.PRNumber != 493 {
		t.Fatalf("due follow-up = %+v, %+v, %v", followup, gotPublication, err)
	}
	followup.PRState = "merged"
	followup.ChecksState = "passing"
	followup.ChecksTotal = 2
	followup.ChecksPassed = 2
	followup.ChecksURL = "https://github.com/owner/blitz-infra/actions/runs/991"
	followup.MergeSHA = "abcdefabcdef"
	followup.MergedAt = now
	followup.NextCheckAt = now.Add(24 * time.Hour)
	if err := st.PublicationFollowups.Save(ctx, followup); err != nil {
		t.Fatal(err)
	}
	mergedCard, err := st.GetIncident(ctx, incident.ID)
	if err != nil || mergedCard.CardVersion <= incident.CardVersion {
		t.Fatalf("merged follow-up card version = %d after %d, %v", mergedCard.CardVersion, incident.CardVersion, err)
	}
	contexts, err := st.PublicationFollowups.ListActiveContexts(ctx, now.Add(-time.Hour), 10)
	if err != nil || len(contexts) != 1 || contexts[0].ThreadTS != "1700.100" ||
		contexts[0].RepositoryKey != "blitz-infra" || contexts[0].MergeSHA == "" {
		t.Fatalf("active publication contexts = %+v, %v", contexts, err)
	}
	if err := st.PublicationFollowups.Reset(ctx, incident.ID, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	reset, err := st.PublicationFollowups.Get(ctx, incident.ID)
	if err != nil || reset.PRState != "merged" || reset.ChecksState != "passing" ||
		reset.ChecksTotal != 2 || reset.ChecksPassed != 2 || reset.ChecksFailed != 0 ||
		reset.ChecksURL != "https://github.com/owner/blitz-infra/actions/runs/991" ||
		reset.MergeSHA != "abcdefabcdef" {
		t.Fatalf("terminal publication follow-up reopened by reset = %+v, %v", reset, err)
	}
	event := core.PublicationLifecycleEvent{
		ID: "event-1", IncidentID: incident.ID, Kind: "deployment",
		State: "succeeded", Summary: "Production rollout completed.",
	}
	inserted, err := st.PublicationFollowups.RecordLifecycleEvent(ctx, event)
	if err != nil || !inserted {
		t.Fatalf("first lifecycle event = %v, %v", inserted, err)
	}
	latest, err := st.PublicationFollowups.LatestLifecycleEvent(ctx, incident.ID)
	if err != nil || latest.ID != event.ID || latest.Summary != event.Summary {
		t.Fatalf("latest lifecycle event = %+v, %v", latest, err)
	}
	eventCard, err := st.GetIncident(ctx, incident.ID)
	if err != nil || eventCard.CardVersion <= mergedCard.CardVersion {
		t.Fatalf("event card version = %d after %d, %v", eventCard.CardVersion, mergedCard.CardVersion, err)
	}
	inserted, err = st.PublicationFollowups.RecordLifecycleEvent(ctx, event)
	if err != nil || inserted {
		t.Fatalf("duplicate lifecycle event = %v, %v", inserted, err)
	}
	duplicateCard, err := st.GetIncident(ctx, incident.ID)
	if err != nil || duplicateCard.CardVersion != eventCard.CardVersion {
		t.Fatalf("duplicate event card version = %d, want %d, %v", duplicateCard.CardVersion, eventCard.CardVersion, err)
	}
}

func TestTerminalPublicationFollowupRejectsReviewAndStaleness(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-terminal-pr", "Merged task", "summary", "UOP",
		"COPS", "1700.500", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	publication := core.Publication{
		IncidentID: incident.ID, Repository: "owner/repo", BaseBranch: "main",
		HeadBranch: "ryker/task", ParentHead: "parent", CandidateTree: "tree",
		CommitSHA: "commit", RemoteSHA: "remote", PRNumber: 529,
		PRURL: "https://github.example/owner/repo/pull/529",
		State: core.PublicationPublished, PublishedAt: now,
	}
	if err := st.SavePublication(ctx, publication); err != nil {
		t.Fatal(err)
	}
	if err := st.PublicationFollowups.Ensure(ctx, incident.ID, now); err != nil {
		t.Fatal(err)
	}
	followup, err := st.PublicationFollowups.Get(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	newer := followup
	newer.ChecksState = "passing"
	newer.FailureCount = 0
	newer.LastError = ""
	newer.NextCheckAt = now.Add(5 * time.Minute)
	if _, err := st.PublicationFollowups.SaveTransition(ctx, followup, newer, nil); err != nil {
		t.Fatal(err)
	}
	delayed := followup
	delayed.FailureCount++
	delayed.LastError = "delayed poll failed"
	delayed.NextCheckAt = now.Add(time.Minute)
	if _, err := st.PublicationFollowups.SaveTransition(ctx, followup, delayed, nil); !errors.Is(err, core.ErrConflict) {
		t.Fatalf("delayed follow-up write = %v, want conflict", err)
	}
	followup, err = st.PublicationFollowups.Get(ctx, incident.ID)
	if err != nil || followup.ChecksState != "passing" || followup.FailureCount != 0 ||
		followup.LastError != "" || !followup.NextCheckAt.Equal(newer.NextCheckAt) {
		t.Fatalf("newer follow-up overwritten = %+v, %v", followup, err)
	}
	staleOpen := followup
	followup.PRState = "merged"
	followup.ChecksState = "passing"
	followup.MergeSHA = "merge"
	followup.MergedAt = now
	followup.NextCheckAt = now.Add(24 * time.Hour)
	if err := st.PublicationFollowups.Save(ctx, followup); err != nil {
		t.Fatal(err)
	}
	staleOpen.ChecksState = "failing"
	staleOpen.LastError = "delayed open poll"
	if err := st.PublicationFollowups.Save(ctx, staleOpen); err != nil {
		t.Fatal(err)
	}
	if err := st.PublicationFollowups.Reset(ctx, incident.ID, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	absorbing, err := st.PublicationFollowups.Get(ctx, incident.ID)
	if err != nil || absorbing.PRState != "merged" || absorbing.MergeSHA != "merge" {
		t.Fatalf("absorbing terminal follow-up = %+v, %v", absorbing, err)
	}
	if _, err := st.Publications.BeginReview(
		ctx, "stale-control", "", incident.ID, "owner/repo", "main", nil,
	); !errors.Is(err, publicationstore.ErrPRTerminal) {
		t.Fatalf("terminal PR review = %v", err)
	}
	if changed, err := st.Publications.MarkStale(ctx, incident.ID, "new task changes"); err != nil || changed {
		t.Fatalf("terminal PR stale = %t, %v", changed, err)
	}
	stored, err := st.GetPublication(ctx, incident.ID)
	if err != nil || !stored.Published() || stored.PRNumber != 529 {
		t.Fatalf("terminal publication receipt = %+v, %v", stored, err)
	}
	failed := stored
	failed.State = core.PublicationFailed
	failed.LastError = "review failed after merge"
	if err := st.SavePublication(ctx, failed); !errors.Is(err, publicationstore.ErrAttemptLost) {
		t.Fatalf("terminal publication failure overwrite = %v", err)
	}
	if _, err := st.db.ExecContext(ctx, `
		UPDATE publications SET state = 'reviewing', last_error = 'interrupted'
		WHERE incident_id = ?`, incident.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.RecoverInterrupted(ctx); err != nil {
		t.Fatal(err)
	}
	recovered, err := st.GetPublication(ctx, incident.ID)
	if err != nil || !recovered.Published() || recovered.LastError != "" {
		t.Fatalf("terminal publication recovery = %+v, %v", recovered, err)
	}
}

func TestLoadRemediationRecordAssemblesCanonicalIncidentState(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	incidents, err := st.ApplySignals(ctx, testWebhookEvent(), time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incident = %+v, %v", incidents, err)
	}
	incident := incidents[0]
	if err := st.SetChannel(ctx, incident.ID, "CINCIDENT", "ems-api"); err != nil {
		t.Fatal(err)
	}
	run, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: "CINCIDENT", ConversationKey: "incident:" + incident.ID,
		SourceKind: "webhook", SourceID: "delivery-1", Repository: "repo",
		Prompt: "investigate",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.RecordEvidence(ctx, []core.Evidence{{
		IncidentID: incident.ID, ChannelID: "CINCIDENT", SourceInput: run.ID,
		Claim: "API returned errors", Observation: "Probe observed HTTP 500",
		SourceType: "emisar", SourceName: "http probe", Target: "api",
	}}); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	if _, _, err := st.Approvals.Record(ctx, core.EmisarApproval{
		RequestID: "req_1", IncidentID: incident.ID, ChannelID: "CINCIDENT",
		SourceInput: run.ID, RequestedBy: "UOP", RunID: "emisar_run_1",
		OperationID: "op_1", ActionID: "service.restart", PackRef: "service@1",
		RunnerRef: "runner_1", Status: "pending_approval",
		ApprovalURL: "https://emisar.example/approvals/req_1",
		ExpiresAt:   now.Add(time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.SavePublication(ctx, core.Publication{
		IncidentID: incident.ID, Repository: "owner/repo", BaseBranch: "main",
		ParentHead: "parent", CandidateTree: "tree", State: "publishing",
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.Intelligence.RecordTimeline(ctx, core.TimelineEvent{
		ID: "operator_1", IncidentID: incident.ID, ChannelID: "CINCIDENT",
		Kind: "operator.message", Title: "Operator requested a restart", CreatedAt: now,
	}); err != nil {
		t.Fatal(err)
	}

	record, err := st.LoadRemediationRecord(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(record.Signals) != 1 || len(record.AgentRuns) != 1 ||
		len(record.Evidence) != 1 || len(record.Events) != 1 ||
		len(record.Approvals) != 1 ||
		record.Publication.State != "publishing" {
		t.Fatalf("record = %+v", record)
	}
	// Closing is intentionally excluded while publication owns the task. End
	// the fixture's synthetic publication attempt before exercising the
	// unrelated canonical-record close behavior below.
	record.Publication.State = core.PublicationFailed
	if err := st.SavePublication(ctx, record.Publication); err != nil {
		t.Fatal(err)
	}
	if err := st.CloseIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	latest, err := st.FindLatestIncidentByChannel(ctx, "CINCIDENT")
	if err != nil || latest.ID != incident.ID || latest.Status != core.IncidentClosed {
		t.Fatalf("latest closed incident = %+v, %v", latest, err)
	}
}

func TestExpiredChannelMemoryIsOwnedBeforeItIsPruned(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	started := time.Now().UTC().Add(-2 * time.Hour)
	if err := st.Intelligence.BindChannelSession(ctx, "COPS", "repo", "session-old", 3, 1, started); err != nil {
		t.Fatal(err)
	}
	count, err := st.ScheduleExpiredChannelMemoryCleanup(
		ctx, started.Add(time.Minute), time.Now().Add(-time.Minute),
	)
	if err != nil || count != 1 {
		t.Fatalf("scheduled = %d, %v", count, err)
	}
	item, err := st.NextCleanup(ctx, time.Now())
	if err != nil || item.SessionID != "session-old" || item.IncidentID != "" {
		t.Fatalf("cleanup = %+v, %v", item, err)
	}
	if err := st.SetCleanupState(
		ctx, item.SessionID, "done", "discard-plan", "", time.Now(),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Prune(
		ctx,
		time.Now().Add(time.Hour),
		time.Now().Add(time.Hour),
		time.Now().Add(time.Hour),
		time.Now().Add(-time.Hour),
		time.Now().Add(-time.Hour),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Intelligence.GetChannelMemory(ctx, "COPS"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expired channel memory remained after owned cleanup: %v", err)
	}
}

func TestIncidentCardRevisionInvalidatesRenderedCardsOnce(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incidents, err := st.ApplySignals(ctx, testWebhookEvent(), time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incident = %+v, %v", incidents, err)
	}
	if err := st.SetChannel(ctx, incidents[0].ID, "CINCIDENT", "ems-test"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incidents[0].ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	incident, err := st.GetIncident(ctx, incidents[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.MarkCardRendered(ctx, incident.ID, incident.CardVersion); err != nil {
		t.Fatal(err)
	}
	changed, err := st.EnsureIncidentCardRevision(ctx, "revision-1")
	if err != nil || !changed {
		t.Fatalf("first revision = %v, %v", changed, err)
	}
	dirty, err := st.ListDirtyCards(ctx, 10)
	if err != nil || len(dirty) != 1 || dirty[0].ID != incident.ID {
		t.Fatalf("dirty after UI upgrade = %+v, %v", dirty, err)
	}
	if err := st.MarkCardRendered(ctx, dirty[0].ID, dirty[0].CardVersion); err != nil {
		t.Fatal(err)
	}
	changed, err = st.EnsureIncidentCardRevision(ctx, "revision-1")
	if err != nil || changed {
		t.Fatalf("same revision = %v, %v", changed, err)
	}
	dirty, err = st.ListDirtyCards(ctx, 10)
	if err != nil || len(dirty) != 0 {
		t.Fatalf("same revision dirtied cards = %+v, %v", dirty, err)
	}
	changed, err = st.EnsureIncidentCardRevision(ctx, "revision-2")
	if err != nil || !changed {
		t.Fatalf("second revision = %v, %v", changed, err)
	}
}

func TestResolvedDeletedWorkIsClosedAndQueuedForSafeCleanup(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	event := testWebhookEvent()
	incidents, err := st.ApplySignals(ctx, event, time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incident = %+v, %v", incidents, err)
	}
	incident := incidents[0]
	if err := st.SetChannel(ctx, incident.ID, "CDELETED", "ems-deleted"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incident.ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, incident.ID, "session-deleted", "fork-deleted", 1); err != nil {
		t.Fatal(err)
	}
	resolved := event
	resolved.DedupeKey = "delivery-resolved"
	resolved.BodyDigest = "resolved-digest"
	resolved.Signals = append([]core.Signal(nil), event.Signals...)
	resolved.Signals[0].EventID = "event-resolved"
	resolved.Signals[0].Status = core.SignalResolved
	resolved.Signals[0].ReceivedAt = time.Now().UTC()
	if _, err := st.ApplySignals(ctx, resolved, time.Hour, 0, 100); err != nil {
		t.Fatal(err)
	}
	deletedAt := time.Now().UTC()
	if _, err := st.SetIncidentChannelState(
		ctx,
		"CDELETED",
		core.ChannelDeleted,
		deletedAt,
	); err != nil {
		t.Fatal(err)
	}

	retired, err := st.RetireResolvedDeletedWork(
		ctx,
		deletedAt.Add(time.Hour),
	)
	if err != nil || retired != 1 {
		t.Fatalf("retired = %d, %v", retired, err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.Status != core.IncidentClosed ||
		incident.Workflow != core.WorkflowClosed {
		t.Fatalf("retired incident = %+v, %v", incident, err)
	}
	askedAt := time.Now().UTC()
	cleanup, err := st.NextCleanup(ctx, askedAt)
	if err != nil || cleanup.SessionID != "session-deleted" ||
		cleanup.IncidentID != incident.ID || cleanup.AllowUnmerged {
		// This assertion has failed intermittently and never reproduced: roughly
		// forty attempts across isolated runs, -count repetition, -shuffle,
		// -race, and full-tree runs at -p 8. Rather than guess at a fix, the
		// failure explains itself when it next happens.
		t.Fatalf(
			"cleanup ownership = %+v, %v\n"+
				"asked at:   %s\n"+
				"deleted at: %s\n"+
				"rows in coop_cleanup:\n%s",
			cleanup, err,
			askedAt.Format(timestampFormat),
			deletedAt.Format(timestampFormat),
			dumpCleanupRows(t, st),
		)
	}
}

// dumpCleanupRows renders the cleanup queue for a failure message. The
// intermittent failure above reports "no row found" without saying whether the
// row is absent, in the wrong state, or merely not yet eligible — and those
// have three different causes.
func dumpCleanupRows(t *testing.T, st *Store) string {
	t.Helper()
	rows, err := st.db.Query(`
		SELECT session_id, incident_id, state, eligible_at, next_attempt_at, created_at
		FROM coop_cleanup ORDER BY created_at`)
	if err != nil {
		return "  (query failed: " + err.Error() + ")"
	}
	defer rows.Close()
	var out strings.Builder
	for rows.Next() {
		var session, incident, state, eligible, next, created string
		if err := rows.Scan(&session, &incident, &state, &eligible, &next, &created); err != nil {
			return "  (scan failed: " + err.Error() + ")"
		}
		fmt.Fprintf(&out, "  session=%s incident=%s state=%s eligible_at=%s next_attempt_at=%s created_at=%s\n",
			session, incident, state, eligible, next, created)
	}
	if out.Len() == 0 {
		return "  (none — the row was never inserted)"
	}
	return out.String()
}
