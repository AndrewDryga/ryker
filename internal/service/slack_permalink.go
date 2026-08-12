package service

import (
	"context"
	"errors"
	"net/url"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackref"
	"github.com/AndrewDryga/responder/internal/store"
)

// captureSlackPermalinkReference permits cross-channel hydration only for an
// allowlisted operator linking a channel that Responder was explicitly
// configured to observe. Slack membership alone is not an audience boundary.
func (s *Service) captureSlackPermalinkReference(
	ctx context.Context,
	input core.SlackInput,
	state *decisionpkg.WatchTurnState,
) error {
	reference, ok := slackref.Parse(input.Text)
	if !ok {
		return nil
	}
	workspaceURL, err := url.Parse(s.identity.WorkspaceURL)
	if err != nil || workspaceURL.Hostname() == "" ||
		!strings.EqualFold(workspaceURL.Hostname(), reference.Host) {
		return nil
	}
	if reference.ChannelID != input.ChannelID {
		if !s.cfg.IsOperator(input.UserID) {
			return nil
		}
		_, err := s.store.GetChannelConfiguration(ctx, reference.ChannelID)
		if errors.Is(err, store.ErrNotFound) {
			if !s.cfg.IsWatchChannel(reference.ChannelID) &&
				!s.cfg.IsSummonChannel(reference.ChannelID) {
				return nil
			}
		} else if err != nil {
			return err
		}
	}
	state.ReferencedChannelID = reference.ChannelID
	state.ReferencedThreadTS = reference.ThreadTS
	state.ReferencedMessageTS = reference.MessageTS
	return nil
}
