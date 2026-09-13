package service

import (
	"context"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/taskcard"
)

func (s *Service) updateEngineeringTaskCard(
	ctx context.Context,
	runID string,
	incident core.Incident,
	message slackui.Message,
	replyParts []string,
) error {
	return s.store.TaskCards.SetUpdate(
		ctx,
		incident.ID,
		runID,
		taskcard.Update(message, replyParts, s.sanitizeText),
	)
}
