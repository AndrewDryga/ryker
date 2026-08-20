package service

import (
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/resultrecovery"
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
