package taskpr

import (
	"testing"

	"github.com/AndrewDryga/responder/internal/coop"
)

func TestChangesPresentRejectsEmptyCommitOnExistingPullRequest(t *testing.T) {
	changes := coop.Changes{
		ForkHead: "empty-commit", ForkTree: "same-tree", PullRequestTree: "same-tree",
		Committed: []coop.Change{{Path: "original-pr.go", Status: "M"}},
	}
	if ChangesPresent(changes, "admitted-head") {
		t.Fatal("empty commit was treated as new pull request content")
	}
}

func TestChangesPresentRejectsCommitThenRevertOnExistingPullRequest(t *testing.T) {
	changes := coop.Changes{
		ForkHead: "revert-commit", ForkTree: "original-tree", PullRequestTree: "original-tree",
		Committed: []coop.Change{{Path: "original-pr.go", Status: "M"}},
	}
	if ChangesPresent(changes, "admitted-head") {
		t.Fatal("commit and revert was treated as new pull request content")
	}
	changes.ForkTree = "changed-tree"
	if !ChangesPresent(changes, "admitted-head") {
		t.Fatal("changed workspace tree was not detected")
	}
}
