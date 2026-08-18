// Package taskofferclaims validates the current evidence that authorizes a
// confirmable engineering-task offer.
package taskofferclaims

import (
	"slices"
	"time"

	"github.com/AndrewDryga/responder/internal/completionpolicy"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
)

func CompletionIdentity(completion *investigation.CompletionAssessment) (string, string) {
	if completion == nil {
		return "", ""
	}
	return completion.Status, completion.Verdict
}

func Correction(
	episode core.WorkEpisode,
	evidence []core.Evidence,
	coverage []core.Coverage,
	now time.Time,
	chainStartedAt time.Time,
) string {
	contract := investigation.Compile(episode)
	contract.Claims = slices.DeleteFunc(
		slices.Clone(contract.Claims),
		func(requirement investigation.ClaimRequirement) bool {
			return requirement.ID == "task.requested_outcome"
		},
	)
	if len(contract.Claims) == 0 {
		return ""
	}
	if correction := investigation.ClaimShapeCorrectionForContract(
		contract, evidence, coverage, true,
	); correction != "" {
		return correction
	}
	ledger := investigation.BuildLedgerForChain(
		contract, evidence, completionpolicy.CurrentCoverage(coverage, now),
		now.UTC(), chainStartedAt.UTC(),
	)
	// A negative verdict can explain why work is useful, but it cannot waive a
	// contradiction in the evidence that authorizes the Slack control.
	return ledger.CompletionCorrectionFor("decision_ready", "")
}
