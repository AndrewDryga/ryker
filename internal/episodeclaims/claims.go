// Package episodeclaims validates a candidate result against the current and
// historical evidence ledger for its work episode.
package episodeclaims

import (
	"context"
	"time"

	"github.com/AndrewDryga/ryker/internal/completionpolicy"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/investigation"
	"github.com/AndrewDryga/ryker/internal/taskoffercarry"
	"github.com/AndrewDryga/ryker/internal/taskofferclaims"
	"github.com/AndrewDryga/ryker/internal/wakeuppolicy"
)

type HistorySource interface {
	ListEpisodeEvidence(context.Context, string, int) ([]core.Evidence, error)
	ListEpisodeCoverage(context.Context, string, int) ([]core.Coverage, error)
}

func Correction(
	ctx context.Context,
	wakeups wakeuppolicy.Source,
	history HistorySource,
	episode core.WorkEpisode,
	action string,
	evidence []core.Evidence,
	coverage []core.Coverage,
	completion *investigation.CompletionAssessment,
	now time.Time,
	chainStartedAt time.Time,
	operations []investigation.ResultOperation,
	optionalOffer *bool,
) (string, error) {
	if correction, err := wakeuppolicy.Correction(
		ctx, wakeups, episode.ID, operations, now,
	); correction != "" || err != nil {
		return correction, err
	}
	completionStatus, completionVerdict := taskofferclaims.CompletionIdentity(completion)
	if correction := completionpolicy.CurrentCandidateCorrection(
		episode.CompletionCriteria, episode.Effort, evidence, coverage,
		completionStatus, completionVerdict, now,
	); correction != "" {
		return correction, nil
	}
	if action == "reply" && completion != nil && taskoffercarry.Present(operations) {
		correction := taskofferclaims.Correction(
			episode, evidence, coverage, taskoffercarry.TargetRepository(operations),
			now, chainStartedAt,
		)
		if correction != "" && optionalOffer != nil {
			*optionalOffer = true
		}
		return correction, nil
	}
	priorEvidence, err := history.ListEpisodeEvidence(ctx, episode.ID, 200)
	if err != nil {
		return "", err
	}
	priorCoverage, err := history.ListEpisodeCoverage(ctx, episode.ID, 200)
	if err != nil {
		return "", err
	}
	return investigation.ClaimCorrection(
		episode,
		action,
		append(priorEvidence, evidence...),
		append(priorCoverage, completionpolicy.CurrentCoverage(coverage, now)...),
		completion,
		now,
		chainStartedAt,
		len(operations) > 0,
	), nil
}
