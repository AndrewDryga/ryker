package service

import (
	decisionpkg "github.com/AndrewDryga/ryker/internal/decision"
	"github.com/AndrewDryga/ryker/internal/resultrecovery"
)

func terminalStructuredCorrection(attempt, episodeCorrections, maximum int) bool {
	return resultrecovery.CorrectionSpent(attempt, episodeCorrections, maximum)
}

func consumeWatchStructuredCorrection(
	state *decisionpkg.WatchTurnState,
	episodeCorrections, maximum int,
) bool {
	return resultrecovery.ConsumeWatchCorrection(state, episodeCorrections, maximum)
}
