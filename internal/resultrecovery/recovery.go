// Package resultrecovery preserves independently valid ledger records when an
// unrelated operation makes a model result stream unreadable.
package resultrecovery

import (
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/completionpolicy"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
)

// Records are the immutable episode-ledger rows a correction round retains.
type Records struct {
	Evidence []core.Evidence
	Coverage []core.Coverage
	Findings []investigation.FindingOperation
}

// Watch recovers valid records from an invalid watch result and merges them
// into the records already held by the run.
func Watch(message string, prior Records, now time.Time) Records {
	var result decisionpkg.WatchDecision
	if !decode(message, &result) {
		return prior
	}
	return merge(prior, recover(result.Operations), now)
}

// AgentReport recovers valid records from an invalid incident or engineering
// report. The complete result remains rejected; only ledger rows survive.
func AgentReport(message string, now time.Time) Records {
	var result decisionpkg.AgentReport
	if !decode(message, &result) {
		return Records{}
	}
	return merge(Records{}, recover(result.Operations), now)
}

func decode(message string, target any) bool {
	trimmed := strings.TrimSpace(message)
	if decisionpkg.RejectMultipleJSONObjects(trimmed) != nil {
		return false
	}
	start := strings.Index(trimmed, "{")
	if start < 0 {
		return false
	}
	object, err := decisionpkg.FirstJSONObject(trimmed[start:])
	if err != nil {
		return false
	}
	normalized, err := decisionpkg.NormalizeEmptyStructuredTimestamps(object)
	return err == nil && decisionpkg.DecodeStrictJSON(normalized, target) == nil
}

func recover(operations []investigation.ResultOperation) Records {
	if len(operations) > decisionpkg.MaxResultOperations {
		return Records{}
	}
	counts := make(map[string]int, len(operations))
	for _, operation := range operations {
		counts[strings.TrimSpace(operation.ID)]++
	}
	result := Records{}
	for _, operation := range operations {
		operation.ID = strings.TrimSpace(operation.ID)
		operation.Type = strings.TrimSpace(operation.Type)
		if operation.ID == "" || counts[operation.ID] != 1 || operation.Validate() != nil {
			continue
		}
		switch operation.Type {
		case "record_evidence":
			if investigation.ValidateEvidence(*operation.Evidence) != nil {
				continue
			}
			row := *operation.Evidence
			row.ID = operation.ID
			result.Evidence = append(result.Evidence, row)
		case "record_coverage":
			result.Coverage = append(result.Coverage, *operation.Coverage)
		case "record_finding":
			row := *operation.Finding
			row.ID = operation.ID
			if row.Key == "" {
				row.Key = investigation.FindingKeyForOperationID(operation.ID)
			}
			result.Findings = append(result.Findings, row)
		}
	}
	return result
}

func merge(prior, current Records, now time.Time) Records {
	return Records{
		Evidence: decisionpkg.CarryEvidence(prior.Evidence,
			decisionpkg.SanitizeEvidence(current.Evidence, "", "", "", now)),
		Coverage: decisionpkg.CarryCoverage(prior.Coverage,
			completionpolicy.CurrentCoverage(
				decisionpkg.SanitizeCoverage(current.Coverage, "", "", "", now), now)),
		Findings: decisionpkg.CarryFindings(prior.Findings,
			decisionpkg.SanitizeFindings(current.Findings)),
	}
}
