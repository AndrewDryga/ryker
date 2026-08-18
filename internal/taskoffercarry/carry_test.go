package taskoffercarry

import (
	"testing"

	"github.com/AndrewDryga/responder/internal/investigation"
)

func TestATitleOnlyEngineeringOfferStillUsesTheOfferContract(t *testing.T) {
	operations := []investigation.ResultOperation{{
		ID: "offer", Type: "offer_task",
		Task: &investigation.TaskOffer{Kind: "engineering", Title: "Inspect the change"},
	}}
	if !Present(operations) {
		t.Fatal("valid title-only engineering offer fell through the future-outcome contract")
	}
}

// A correction that restates the same task but omits the optional PR binding
// must not retarget the operator's eventual confirmation to the default branch.
func TestARepeatedTaskOfferDoesNotDropItsPullRequestBinding(t *testing.T) {
	prior := &Offer{Operation: investigation.ResultOperation{
		ID: "offer", Type: "offer_task",
		Task: &investigation.TaskOffer{Kind: "engineering", Title: "Fix it", Repository: "repo"},
	}, PullRequest: "123"}
	current := []investigation.ResultOperation{{
		ID: "offer", Type: "offer_task",
		Task: &investigation.TaskOffer{Kind: "engineering", Title: "Fix it", Repository: "repo"},
	}}
	carried := Carry(prior, current, "")
	if carried == nil || carried.PullRequest != "123" {
		t.Fatalf("correction dropped PR binding: %+v", carried)
	}
}

// Operation IDs are stable across corrections, but repository identity is
// part of the governed target. Carrying repo-a's PR into a corrected repo-b
// offer makes persistence reject the control after the model already repaired
// it.
func TestACorrectedTaskRepositoryDoesNotInheritAnotherRepositoriesPullRequest(t *testing.T) {
	prior := &Offer{Operation: investigation.ResultOperation{
		ID: "offer", Type: "offer_task",
		Task: &investigation.TaskOffer{Kind: "engineering", Title: "Fix it", Repository: "repo-a"},
	}, PullRequest: "123"}
	current := []investigation.ResultOperation{{
		ID: "offer", Type: "offer_task",
		Task: &investigation.TaskOffer{Kind: "engineering", Title: "Fix it", Repository: "repo-b"},
	}}
	carried := Carry(prior, current, "")
	if carried == nil || carried.PullRequest != "" {
		t.Fatalf("cross-repository PR binding was retained: %+v", carried)
	}
}

func TestATaskOfferKeepsItsPullRequestAcrossAnIDOnlyCorrection(t *testing.T) {
	prior := &Offer{Operation: investigation.ResultOperation{
		ID: "draft-one", Type: "offer_task",
		Task: &investigation.TaskOffer{Kind: "engineering", Title: "Fix it", Repository: "repo", Prompt: "Patch and test."},
	}, PullRequest: "123"}
	current := []investigation.ResultOperation{{
		ID: "corrected-two", Type: "offer_task",
		Task: &investigation.TaskOffer{Kind: "engineering", Title: "Fix it", Repository: "repo", Prompt: "Patch and test."},
	}}
	if carried := Carry(prior, current, ""); carried == nil || carried.PullRequest != "123" {
		t.Fatalf("ID-only correction dropped PR authority: %+v", carried)
	}
}

func TestASemanticallyChangedTaskOfferDropsItsPullRequestAuthority(t *testing.T) {
	prior := &Offer{Operation: investigation.ResultOperation{
		ID: "offer", Type: "offer_task",
		Task: &investigation.TaskOffer{Kind: "engineering", Title: "Fix it", Repository: "repo", Prompt: "Patch the parser."},
	}, PullRequest: "123"}
	current := []investigation.ResultOperation{{
		ID: "offer", Type: "offer_task",
		Task: &investigation.TaskOffer{Kind: "engineering", Title: "Fix it", Repository: "repo", Prompt: "Replace the database."},
	}}
	if carried := Carry(prior, current, ""); carried == nil || carried.PullRequest != "" {
		t.Fatalf("changed task retained stale PR authority: %+v", carried)
	}
}
