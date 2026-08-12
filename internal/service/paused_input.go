package service

import (
	"context"
	"errors"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

// pausedReaction remains so a successful reply can clear marks left by older
// deployed builds. Terminal work now gets a bounded failure reply instead.
const pausedReaction = "double_vertical_bar"

// clearInputPaused removes a legacy pause once the work is answered.
func (s *Service) clearInputPaused(ctx context.Context, input core.SlackInput) {
	if s.store == nil || input.ID == "" || input.ChannelID == "" || input.MessageTS == "" {
		return
	}
	queued, err := s.store.PauseCleanup.Queued(ctx, input.ID)
	if err != nil {
		if s.log != nil {
			s.log.Warn("could not inspect legacy pause", "input", input.ID, "error", err)
		}
		return
	}
	if !queued {
		return
	}
	client, ok := unpacedSlack(s.slack).(interface {
		Unreact(context.Context, string, string, string) error
	})
	if !ok {
		return
	}
	if err := client.Unreact(
		ctx, input.ChannelID, input.MessageTS, pausedReaction,
	); err != nil && s.log != nil {
		s.log.Warn(
			"could not clear the paused mark",
			"channel", input.ChannelID,
			"message", input.MessageTS,
			"error", err,
		)
	} else if err == nil {
		if auditErr := s.store.PauseCleanup.MarkCleared(ctx, input.ID, time.Now()); auditErr != nil && s.log != nil {
			s.log.Warn("could not record cleared legacy pause", "input", input.ID, "error", auditErr)
		}
	}
}

// processLegacyPauseCleanup reconciles the visible pause contract used by old
// binaries with the terminal lifecycle now stored for those inputs. A durable
// audit receipt makes the Slack write idempotent; the recurring scheduler keeps
// a transient failure queued across restarts.
func (s *Service) processLegacyPauseCleanup(ctx context.Context) error {
	input, err := s.store.PauseCleanup.Next(ctx)
	if errors.Is(err, core.ErrNotFound) {
		return store.ErrNotFound
	}
	if err != nil {
		return err
	}
	client, ok := unpacedSlack(s.slack).(interface {
		Unreact(context.Context, string, string, string) error
	})
	if !ok {
		return errors.New("Slack reaction cleanup is unavailable")
	}
	if err := client.Unreact(ctx, input.ChannelID, input.MessageTS, pausedReaction); err != nil {
		return err
	}
	return s.store.PauseCleanup.MarkCleared(ctx, input.ID, time.Now())
}
