// Package recheckcontext carries unfinished evidence into a later attempt of
// the same work episode without promoting correlated history to current proof.
package recheckcontext

import (
	"context"
	"time"

	"github.com/AndrewDryga/responder/internal/completionpolicy"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
)

type Source interface {
	ListCurrentEpisodeEvidence(context.Context, string, int) ([]core.Evidence, error)
	ListCurrentEpisodeCoverage(context.Context, string, int) ([]core.Coverage, error)
}

func Carry(
	ctx context.Context,
	source Source,
	episodeID string,
	state decisionpkg.WatchTurnState,
	now time.Time,
) (decisionpkg.WatchTurnState, error) {
	evidence, err := source.ListCurrentEpisodeEvidence(ctx, episodeID, 30)
	if err != nil {
		return state, err
	}
	coverage, err := source.ListCurrentEpisodeCoverage(ctx, episodeID, 20)
	if err != nil {
		return state, err
	}
	state.CarriedEvidence = decisionpkg.CarryEvidence(state.CarriedEvidence, evidence)
	state.CarriedCoverage = decisionpkg.CarryCoverage(
		state.CarriedCoverage, completionpolicy.CurrentCoverage(coverage, now),
	)
	return state, nil
}
