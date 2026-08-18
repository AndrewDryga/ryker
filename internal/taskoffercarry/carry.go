// Package taskoffercarry preserves a governed engineering offer across partial
// model correction rounds.
package taskoffercarry

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"

	"github.com/AndrewDryga/responder/internal/investigation"
)

// Offer is the governed action retained from an earlier correction round.
type Offer struct {
	Operation   investigation.ResultOperation `json:"operation"`
	PullRequest string                        `json:"pull_request,omitempty"`
}

// Projection carries an offer's top-level decision fields.
type Projection struct {
	Title       string
	Repository  string
	Prompt      string
	PullRequest string
}

// Round points at the operation stream and projections being reconciled.
type Round struct {
	Operations  *[]investigation.ResultOperation
	Applied     *[]investigation.ResultOperation
	Title       *string
	Repository  *string
	Prompt      *string
	PullRequest *string
}

// Reconcile restores an omitted prior offer, then carries the current offer.
func Reconcile(prior *Offer, round Round) *Offer {
	if round.Operations == nil || round.Applied == nil || round.Title == nil ||
		round.Repository == nil || round.Prompt == nil || round.PullRequest == nil {
		return prior
	}
	operations, applied, projection, restored := Restore(
		prior, *round.Operations, *round.Applied, *round.Title,
	)
	if restored {
		*round.Operations, *round.Applied = operations, applied
		*round.Title, *round.Repository = projection.Title, projection.Repository
		*round.Prompt, *round.PullRequest = projection.Prompt, projection.PullRequest
	}
	return Carry(prior, *round.Operations, *round.PullRequest)
}

// Carry keeps the newest engineering offer. Omission means unchanged; the
// result protocol has no operation that withdraws an offer.
func Carry(prior *Offer, operations []investigation.ResultOperation, pullRequest string) *Offer {
	for _, operation := range operations {
		if !engineering(operation) {
			continue
		}
		copy := operation
		task := *operation.Task
		copy.Task = &task
		if pullRequest == "" && prior != nil && prior.Operation.Task != nil &&
			offerFingerprint(*prior.Operation.Task) == offerFingerprint(*operation.Task) {
			pullRequest = prior.PullRequest
		}
		return &Offer{Operation: copy, PullRequest: pullRequest}
	}
	return prior
}

// offerFingerprint binds publication authority to the work's host-observable
// semantics, never the model-chosen operation ID. A correction may rename an
// operation without changing the governed task; changing repository, title,
// or prompt is new work and must not inherit the prior pull request.
func offerFingerprint(task investigation.TaskOffer) string {
	value := strings.Join([]string{
		strings.TrimSpace(task.Repository),
		strings.TrimSpace(task.Title),
		strings.TrimSpace(task.Prompt),
	}, "\x00")
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

// Restore puts an omitted offer back into the typed streams. It does not
// overwrite a current offer or turn an operation-free ignore into a reply.
func Restore(
	carried *Offer,
	operations, applied []investigation.ResultOperation,
	currentTitle string,
) ([]investigation.ResultOperation, []investigation.ResultOperation, Projection, bool) {
	if carried == nil || currentTitle != "" || len(operations) == 0 ||
		!engineering(carried.Operation) || carried.Operation.Validate() != nil {
		return operations, applied, Projection{}, false
	}
	operation := carried.Operation
	task := *carried.Operation.Task
	operation.Task = &task
	used := make(map[string]bool, len(operations))
	for _, item := range operations {
		used[item.ID] = true
	}
	for index := 1; used[operation.ID]; index++ {
		operation.ID = "carried-task-offer-" + strconv.Itoa(index)
	}
	operations = insertBeforeCompletion(operations, operation)
	if len(applied) > 0 {
		applied = insertBeforeCompletion(applied, operation)
	}
	return operations, applied, Projection{
		Title: task.Title, Repository: task.Repository, Prompt: task.Prompt,
		PullRequest: carried.PullRequest,
	}, true
}

// Present reports whether the current operation stream offers engineering work.
func Present(operations []investigation.ResultOperation) bool {
	for _, operation := range operations {
		if engineering(operation) {
			return true
		}
	}
	return false
}

// TargetRepository returns the repository governed by the current engineering
// offer. Only the current operation stream may authorize a new Slack control.
func TargetRepository(operations []investigation.ResultOperation) string {
	for _, operation := range operations {
		if engineering(operation) {
			return strings.TrimSpace(operation.Task.Repository)
		}
	}
	return ""
}

func engineering(operation investigation.ResultOperation) bool {
	return operation.Type == "offer_task" && operation.Task != nil &&
		operation.Task.Kind == "engineering"
}

func insertBeforeCompletion(
	operations []investigation.ResultOperation,
	operation investigation.ResultOperation,
) []investigation.ResultOperation {
	at := len(operations)
	for index, current := range operations {
		if current.Type == "complete_episode" {
			at = index
			break
		}
	}
	result := make([]investigation.ResultOperation, 0, len(operations)+1)
	result = append(result, operations[:at]...)
	result = append(result, operation)
	return append(result, operations[at:]...)
}
