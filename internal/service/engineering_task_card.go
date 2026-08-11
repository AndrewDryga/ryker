package service

import (
	"context"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/taskcard"
)

func (s *Service) updateEngineeringTaskCard(
	ctx context.Context,
	incident core.Incident,
	message slackui.Message,
	replyParts []string,
) error {
	return s.store.TaskCards.SetUpdate(
		ctx,
		incident.ID,
		taskcard.Update(message, replyParts, s.sanitizeText),
	)
}
