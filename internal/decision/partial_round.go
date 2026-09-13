package decision

import (
	"slices"
	"strconv"
	"strings"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/investigation"
)

// A correction round returns what it is changing. This file puts the rest back.
//
// Every correction used to make the model re-emit the whole result envelope,
// and the host already held every accepted row — see CarryEvidence for the
// ledger side of it. Measured on episode_run_956b7644b6fbef89b17aa3a9c6df8da8,
// the 2026-08-16 Terraform notification that ran sixteen turns for $8.84,
// 116,385 of 233,398 result bytes were record_evidence, record_coverage and
// record_finding operations the host was already carrying: 56.8% of everything
// its correction rounds emitted, re-typed at 6,500 to 20,000 output tokens a
// round to tell the host what it had just told the model.
//
// So a correction round may now send only the records it is changing. The rows
// it leaves out are restored here, as operations, before anything reads the
// result — which is the whole point of doing it at the operation stream rather
// than at the projected fields. The result the host stages is re-parsed at
// finalization, the reply's evidence is rendered from it, and the episode
// ledger is written from it, so a merge that only fed the validators would hand
// the operator an answer whose evidence had been silently thrown away.

// CarriedRecords is what the host puts back into a round that returned only
// what it changed: the operations to splice into the stream, and the same rows
// projected for the fields that are read directly.
type CarriedRecords struct {
	Operations []investigation.ResultOperation
	Evidence   []core.Evidence
	Coverage   []core.Coverage
	Findings   []investigation.FindingOperation
}

// RestoreCarriedRecords works out which accepted records this round left out.
//
// Identity is the carry's identity, because the two have to agree: evidence by
// the operation id it was recorded under, coverage by layer, a finding by the
// failure state it names. A round that re-sends any of those is changing it,
// and the host keeps what came back rather than what it held.
func RestoreCarriedRecords(
	operations []investigation.ResultOperation,
	evidence []core.Evidence,
	coverage []core.Coverage,
	findings []investigation.FindingOperation,
) CarriedRecords {
	// Never into an empty stream. A bare envelope is an ignore, a react or a
	// refusal, and giving one an operation stream would rewrite it into a reply
	// nobody wrote; the correction for an empty correction round says so in
	// words instead.
	if len(operations) == 0 {
		return CarriedRecords{}
	}
	used := make(map[string]bool, len(operations))
	sentEvidence := make(map[string]bool, len(operations))
	sentCoverage := make(map[string]bool, len(operations))
	var sentFindings []investigation.FindingOperation
	for _, operation := range operations {
		used[operation.ID] = true
		switch operation.Type {
		case "record_evidence":
			sentEvidence[operation.ID] = true
			if operation.Evidence != nil && operation.Evidence.ID != "" {
				sentEvidence[operation.Evidence.ID] = true
			}
		case "record_coverage":
			if operation.Coverage != nil {
				sentCoverage[coverageIdentity(operation.Coverage.Layer)] = true
			}
		case "record_finding":
			if operation.Finding != nil {
				finding := *operation.Finding
				finding.ID = operation.ID
				if finding.Key == "" {
					finding.Key = investigation.FindingKeyForOperationID(operation.ID)
				}
				sentFindings = append(sentFindings, finding)
			}
		case "complete_episode":
			// A completion may carry coverage of its own, and the fold projects
			// it exactly like a record_coverage operation. Restoring a layer the
			// completion already assesses would file the same layer twice.
			if operation.Completion != nil {
				for _, item := range operation.Completion.Coverage {
					sentCoverage[coverageIdentity(item.Layer)] = true
				}
			}
		}
	}
	restored := CarriedRecords{}
	room := MaxResultOperations - len(operations)
	add := func(operation investigation.ResultOperation) bool {
		// Dropped rather than refused, on the same reasoning as the fold's
		// unknown payloads: a carried row that cannot be expressed as a valid
		// operation is a row the host still holds for validation, and failing
		// the whole result over it would cost the operator the answer.
		if room <= 0 || used[operation.ID] || operation.Validate() != nil {
			return false
		}
		used[operation.ID] = true
		room--
		restored.Operations = append(restored.Operations, operation)
		return true
	}
	for _, item := range evidence {
		if item.ID == "" || sentEvidence[item.ID] {
			continue
		}
		row := item
		// The operation id IS the evidence id after the fold, so the restored
		// operation has to carry the id the round's own cause_evidence and
		// evidence_refs name.
		if add(investigation.ResultOperation{
			ID: row.ID, Type: "record_evidence", Evidence: &row,
		}) {
			restored.Evidence = append(restored.Evidence, row)
		}
	}
	for index, item := range coverage {
		if sentCoverage[coverageIdentity(item.Layer)] {
			continue
		}
		row := item
		if add(investigation.ResultOperation{
			ID:   carriedOperationID("carried-coverage-", row.Layer, index),
			Type: "record_coverage", Coverage: &row,
		}) {
			restored.Coverage = append(restored.Coverage, row)
		}
	}
	for index, item := range findings {
		// sameFinding rather than the exact words, because CarryFindings uses
		// sameFinding: a model that reclassifies a finding rewrites the sentence
		// in the same breath, and restoring the old wording beside the new one
		// would put the unexplained copy back that the round had just settled.
		// The recorded pair is the calibration — "The blitz-infra refresh
		// reports 121 resources changed outside Terraform" against "The refresh
		// observed 121 resources changed outside Terraform" — and keying on the
		// text alone reinstated the finding twelve rounds had been spent on.
		if slices.ContainsFunc(sentFindings, func(sent investigation.FindingOperation) bool {
			return sameFinding(item, sent)
		}) {
			continue
		}
		row := item
		if row.Key == "" {
			row.Key = investigation.FindingKeyForOperationID(row.ID)
		}
		// A finding read back out of a context envelope has no operation id —
		// the field is deliberately off the JSON contract. Its host-authored key
		// is the original canonical operation id, so restore under that id. Using
		// a fresh carried-finding id here would make validation overwrite the key
		// and a later correction could no longer replace the same failure state.
		id := row.ID
		if id == "" {
			id = row.Key
		}
		if id == "" || used[id] || len(id) > 80 {
			id = carriedOperationID("carried-finding-", row.What, index)
		}
		if add(investigation.ResultOperation{
			ID: id, Type: "record_finding", Finding: &row,
		}) {
			restored.Findings = append(restored.Findings, row)
		}
	}
	return restored
}

// ApplyTo folds the restored records into a watch decision.
func (records CarriedRecords) ApplyTo(decision *WatchDecision) {
	if len(records.Operations) == 0 {
		return
	}
	decision.Operations = InsertBeforeCompletion(decision.Operations, records.Operations)
	// Only when the round has an applied stream at all: that slice is what the
	// host records as this turn's operations, and a decision that never folded
	// one is not a decision whose records were applied.
	if len(decision.AppliedOperations) > 0 {
		decision.AppliedOperations = InsertBeforeCompletion(
			decision.AppliedOperations, records.Operations,
		)
	}
	decision.Evidence = prependRecords(records.Evidence, decision.Evidence)
	decision.Coverage = prependRecords(records.Coverage, decision.Coverage)
	decision.Findings = prependRecords(records.Findings, decision.Findings)
}

// ApplyToReport does the same for an incident or engineering-task report.
func (records CarriedRecords) ApplyToReport(report *AgentReport) {
	if len(records.Operations) == 0 {
		return
	}
	report.Operations = InsertBeforeCompletion(report.Operations, records.Operations)
	if len(report.AppliedOperations) > 0 {
		report.AppliedOperations = InsertBeforeCompletion(
			report.AppliedOperations, records.Operations,
		)
	}
	report.Evidence = prependRecords(records.Evidence, report.Evidence)
	report.Coverage = prependRecords(records.Coverage, report.Coverage)
	report.Findings = prependRecords(records.Findings, report.Findings)
}

// InsertBeforeCompletion splices operations in ahead of complete_episode, which
// stays last: it is the conclusion, and several readers take the first one they
// find as the end of the stream.
func InsertBeforeCompletion(
	operations, insert []investigation.ResultOperation,
) []investigation.ResultOperation {
	if len(insert) == 0 {
		return operations
	}
	at := len(operations)
	for index, operation := range operations {
		if operation.Type == "complete_episode" {
			at = index
			break
		}
	}
	result := make([]investigation.ResultOperation, 0, len(operations)+len(insert))
	result = append(result, operations[:at]...)
	result = append(result, insert...)
	return append(result, operations[at:]...)
}

// PartialRoundCorrection refuses a correction round that changed nothing.
//
// A round may leave out the records it is not touching. It may not leave out
// everything: the completion and its message are the conclusion, they are
// usually what the correction was about, and a round carrying neither has
// answered no question. Accepted, it would turn a corrected turn silent — the
// answer someone is waiting for replaced by the model declining to speak — and
// under an inheritance contract that silence reads as agreement.
//
// A synthetic recheck is exempt for the reason WatchDecisionCorrectionAt exempts
// it: the host set that timer itself, told the model to stay quiet when nothing
// changed, and nobody is waiting on the other end of it.
func PartialRoundCorrection(
	input core.SlackInput,
	state WatchTurnState,
	decision WatchDecision,
) string {
	if strings.TrimSpace(state.FailureDetail) == "" || input.Kind == "recheck" {
		return ""
	}
	if len(decision.Operations) > 0 || decision.Completion != nil {
		return ""
	}
	return "this correction round returned no operations at all: a round may leave out the " +
		"record_evidence, record_coverage and record_finding operations it is not changing — the " +
		"host still holds those — but it always returns its one complete_episode with the reply " +
		"message, beside every operation it is changing"
}

func coverageIdentity(layer string) string {
	return strings.ToLower(strings.TrimSpace(layer))
}

// carriedOperationID names a restored record the host is re-sending on the
// model's behalf. Bounded because a result operation id is, and suffixed with
// the row's position so two layers that slug the same still differ.
func carriedOperationID(prefix, subject string, index int) string {
	slug := strings.Map(func(symbol rune) rune {
		switch {
		case symbol >= 'a' && symbol <= 'z', symbol >= '0' && symbol <= '9':
			return symbol
		case symbol >= 'A' && symbol <= 'Z':
			return symbol + ('a' - 'A')
		}
		return '-'
	}, strings.TrimSpace(subject))
	return prefix + core.TruncateUTF8(slug, 40) + "-" + strconv.Itoa(index+1)
}

func prependRecords[T any](restored, current []T) []T {
	if len(restored) == 0 {
		return current
	}
	result := make([]T, 0, len(restored)+len(current))
	result = append(result, restored...)
	return append(result, current...)
}
