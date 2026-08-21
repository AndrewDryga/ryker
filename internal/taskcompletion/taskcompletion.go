// Package taskcompletion owns the repository state required before an
// engineering turn can call itself complete.
package taskcompletion

import (
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/taskcard"
)

func RequestsOperatorInput(operations []investigation.ResultOperation) bool {
	for _, operation := range operations {
		if operation.Type == "request_operator_input" {
			return true
		}
	}
	return false
}

func WorkspaceCorrection(initialFingerprint string, changes coop.Changes) string {
	if !taskcard.TurnCreatedChanges(initialFingerprint, changes) ||
		(len(changes.Staged) == 0 && len(changes.Unstaged) == 0 &&
			len(changes.Untracked) == 0 && len(changes.Conflicts) == 0) {
		return ""
	}
	return "This engineering turn changed the task workspace but left intended files " +
		"uncommitted. Keep the intended changes, resolve conflicts or remove accidental " +
		"files, run the focused repository checks, and commit all intended changes on " +
		"the current bound branch. Do not push. Then return the completed structured result again."
}
