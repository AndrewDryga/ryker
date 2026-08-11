package taskcard

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"

	"github.com/AndrewDryga/responder/internal/coop"
)

type changesFingerprint struct {
	BaseCommit  string        `json:"base_commit"`
	ForkHead    string        `json:"fork_head"`
	ParentHead  string        `json:"parent_head"`
	Committed   []coop.Change `json:"committed,omitempty"`
	Staged      []coop.Change `json:"staged,omitempty"`
	Unstaged    []coop.Change `json:"unstaged,omitempty"`
	Untracked   []coop.Change `json:"untracked,omitempty"`
	Conflicts   []coop.Change `json:"conflicts,omitempty"`
	PatchDigest string        `json:"patch_digest,omitempty"`
	PatchBytes  int64         `json:"patch_bytes"`
}

// ChangesFingerprint identifies the exact reviewed task tree.
func ChangesFingerprint(changes coop.Changes) string {
	data, _ := json.Marshal(changesFingerprint{
		BaseCommit: changes.BaseCommit, ForkHead: changes.ForkHead,
		ParentHead: changes.ParentHead, Committed: changes.Committed,
		Staged: changes.Staged, Unstaged: changes.Unstaged,
		Untracked: changes.Untracked, Conflicts: changes.Conflicts,
		PatchDigest: changes.PatchDigest, PatchBytes: changes.PatchBytes,
	})
	return fmt.Sprintf("%x", sha256.Sum256(data))
}

// TurnCreatedChanges reports whether a turn changed an initially clean or dirty tree.
func TurnCreatedChanges(initialFingerprint string, changes coop.Changes) bool {
	return initialFingerprint != "" && initialFingerprint != "unavailable" &&
		changesPresent(changes) && initialFingerprint != ChangesFingerprint(changes)
}

func changesPresent(changes coop.Changes) bool {
	return len(changes.Committed) > 0 || len(changes.Staged) > 0 ||
		len(changes.Unstaged) > 0 || len(changes.Untracked) > 0 ||
		len(changes.Conflicts) > 0
}
