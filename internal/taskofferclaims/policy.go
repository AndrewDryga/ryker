// Package taskofferclaims validates the current evidence that authorizes a
// confirmable engineering-task offer.
package taskofferclaims

import (
	"slices"
	"strings"
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
	targetRepository string,
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
	if correction := RepositoryCorrection(evidence, targetRepository); correction != "" {
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

// RepositoryCorrection binds the evidence authorizing a governed task to the
// repository that task will change. Evidence that merely came from some other
// checkout proves neither the proposed diagnosis nor the safety of offering a
// writable action here.
func RepositoryCorrection(evidence []core.Evidence, targetRepository string) string {
	targetRepository = strings.TrimSpace(targetRepository)
	if targetRepository == "" {
		return ""
	}
	for _, item := range evidence {
		if item.SourceType == "repository" && strings.EqualFold(
			strings.TrimSpace(item.Dimensions["repository"]), targetRepository,
		) {
			return ""
		}
	}
	return "suggested engineering task requires current repository evidence for its target repository `" +
		targetRepository + "`"
}
