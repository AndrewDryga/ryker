package store

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
)

// publishedTask sets up an incident with a published pull request and a
// follow-up ready to observe, which is the state every lifecycle transition
// below starts from.
func publishedTask(t *testing.T, st *Store, now time.Time) (core.Incident, core.PublicationFollowup) {
	t.Helper()
	ctx := context.Background()
	incident, _, err := st.CreateEngineeringTask(
		ctx, "blitz-infra", "source-1", "Reduce Redis pool", "summary", "UOP",
		"COPS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SavePublication(ctx, core.Publication{
		IncidentID: incident.ID, Repository: "owner/blitz-infra", BaseBranch: "main",
		HeadBranch: "ryker/reduce-redis", ParentHead: "parent", CandidateTree: "tree",
		CommitSHA: "commit", RemoteSHA: "0123456789abcdef", PRNumber: 493,
		PRURL: "https://github.example/owner/blitz-infra/pull/493",
		State: "published", PublishedAt: now,
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.PublicationFollowups.Ensure(ctx, incident.ID, now); err != nil {
		t.Fatal(err)
	}
	followup, _, err := st.PublicationFollowups.Next(ctx, now.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	return incident, followup
}

// A merge Ryker itself published is a change, and it is ledgered by the
// transaction that records the merge rather than by a caller remembering to.
//
// Written afterwards the change event could simply be absent, and that failure
// is invisible in the worst possible way: the task card says the PR merged, the
// ledger says nothing shipped, and the next incident in that repository is told
// there were no recent changes. A missing answer is recoverable; a confident
// wrong one is what sends somebody looking in the wrong place.
func TestAMergedPublicationLedgersItsChangeInTheSameTransaction(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	incident, followup := publishedTask(t, st, now)

	merged := followup
	merged.PRState = "merged"
	merged.ChecksState = "passing"
	merged.MergeSHA = "abcdefabcdef"
	merged.MergedAt = now
	merged.NextCheckAt = now.Add(24 * time.Hour)
	event := core.PublicationLifecycleEvent{
		ID: "followup-merged-1", IncidentID: incident.ID, Kind: "merged",
		State: "succeeded", Summary: "PR #493 was merged.",
	}
	inserted, err := st.PublicationFollowups.SaveTransition(ctx, followup, merged, &event)
	if err != nil || !inserted {
		t.Fatalf("merge transition = %v, %v", inserted, err)
	}
	changes, err := st.Changes.Recent(ctx, now.Add(-time.Hour), 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(changes) != 1 {
		t.Fatalf("a merged publication recorded %d changes", len(changes))
	}
	change := changes[0]
	if change.Kind != "merge" {
		t.Errorf("kind = %q, want merge", change.Kind)
	}
	if len(change.Repositories) != 1 || change.Repositories[0] != "owner/blitz-infra" {
		t.Errorf("repositories = %v, want the published repository", change.Repositories)
	}
	if change.Revision != "abcdefabcdef" {
		t.Errorf("revision = %q, want the merge commit", change.Revision)
	}
	if change.SourceRef != "https://github.example/owner/blitz-infra/pull/493" {
		t.Errorf("source_ref = %q, want the pull request an operator can open", change.SourceRef)
	}

	// A re-observed merge is the same merge. The follower's poll cursor rewinds
	// on restart recovery, so this is a real path rather than a hypothetical.
	current, err := st.PublicationFollowups.Get(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.PublicationFollowups.SaveTransition(ctx, current, current, &event); err != nil {
		t.Fatal(err)
	}
	changes, err = st.Changes.Recent(ctx, now.Add(-time.Hour), 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(changes) != 1 {
		t.Fatalf("a re-observed merge recorded %d changes", len(changes))
	}
}

// The deployment a merged change actually reaches is the change an incident
// most wants to know about, and it arrives on the correlation path rather than
// the poll. Both writers of publication_lifecycle_events therefore ledger, and
// both do it in their own transaction.
func TestACorrelatedDeploymentAndApplyReachTheLedger(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	incident, _ := publishedTask(t, st, now)

	for _, item := range []core.PublicationLifecycleEvent{
		{
			ID: "deploy-1", IncidentID: incident.ID, Kind: "deployment",
			State: "succeeded", Summary: "Production rollout completed.",
		},
		{
			ID: "apply-1", IncidentID: incident.ID, Kind: "terraform",
			State: "succeeded", Summary: "Terraform apply completed.",
		},
		// Neither of these changed anything that is running, so neither is a
		// change. A section that lists "checks passed" among what changed is a
		// section an operator stops reading.
		{
			ID: "checks-1", IncidentID: incident.ID, Kind: "checks",
			State: "succeeded", Summary: "GitHub checks passed.",
		},
		{
			ID: "closed-1", IncidentID: incident.ID, Kind: "closed",
			State: "stopped", Summary: "PR closed without merging.",
		},
		{
			ID: "deploy-failed-1", IncidentID: incident.ID, Kind: "deployment",
			State: "failed", Summary: "Rollout failed.",
		},
	} {
		if _, err := st.PublicationFollowups.RecordLifecycleEvent(ctx, item); err != nil {
			t.Fatalf("record %s: %v", item.ID, err)
		}
	}
	changes, err := st.Changes.Recent(ctx, now.Add(-time.Hour), 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(changes) != 2 {
		t.Fatalf("the ledger holds %d changes, want the deployment and the apply: %+v",
			len(changes), changes)
	}
	kinds := map[string]bool{}
	for _, change := range changes {
		kinds[change.Kind] = true
		if change.Source != "publication" {
			t.Errorf("source = %q, want publication", change.Source)
		}
	}
	if !kinds["deploy"] || !kinds["infra_apply"] {
		t.Fatalf("recorded kinds = %v", kinds)
	}

	// Redelivery of the same correlated update writes nothing new.
	if _, err := st.PublicationFollowups.RecordLifecycleEvent(ctx, core.PublicationLifecycleEvent{
		ID: "deploy-1", IncidentID: incident.ID, Kind: "deployment",
		State: "succeeded", Summary: "Production rollout completed.",
	}); err != nil {
		t.Fatal(err)
	}
	changes, err = st.Changes.Recent(ctx, now.Add(-time.Hour), 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(changes) != 2 {
		t.Fatalf("a redelivered deployment recorded %d changes", len(changes))
	}
}
