package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/store"
)

const episodeWakeupLeaseOwner = "responder:episode-wakeup"

func (s *Service) processEpisodeWakeup(ctx context.Context) error {
	wakeup, err := s.store.LeaseDueEpisodeWakeup(
		ctx, episodeWakeupLeaseOwner, s.cfg.Limits.WorkLease.Duration,
	)
	if err != nil {
		return err
	}
	episode, err := s.store.GetWorkEpisode(ctx, wakeup.EpisodeID)
	if err != nil {
		return s.retryEpisodeWakeup(ctx, wakeup, err)
	}
	if episodepkg.Terminal(episode.State) {
		return s.store.ResolveEpisodeWakeup(
			ctx, wakeup.ID, episodeWakeupLeaseOwner, wakeup.FencingToken,
			[]byte(`{"outcome":"episode_already_terminal"}`),
		)
	}
	latestAttempt, err := s.store.GetEpisodeAttempt(ctx, episode.LatestAttemptID)
	if err != nil {
		return s.retryEpisodeWakeup(ctx, wakeup, err)
	}
	previous, err := s.store.GetAgentRun(ctx, latestAttempt.AgentRunID)
	if err != nil {
		return s.retryEpisodeWakeup(ctx, wakeup, err)
	}

	sourceID := "episode_wakeup_" + wakeup.ID
	input := core.SlackInput{
		ID: sourceID, EnvelopeID: sourceID, EventID: sourceID, Kind: "recheck",
		TeamID: episode.WorkspaceID, ChannelID: episode.Destination.ChannelID,
		ThreadTS: episode.Destination.ThreadTS, UserID: previous.UserID,
		Text: fmt.Sprintf(
			"Resume the accepted work after the %s wait. Re-check the external state with fresh evidence, continue every open required goal, and report only when the result is decision-ready or an exact blocker remains.",
			wakeup.Kind,
		),
		Frozen: previous.Context, ReceivedAt: s.now().UTC(),
	}
	admitted, err := s.store.AdmitSyntheticSlackInput(ctx, input)
	if err != nil {
		return s.retryEpisodeWakeup(ctx, wakeup, err)
	}
	if admitted && len(input.Frozen) > 0 {
		if err := s.store.SetSlackInputFrozen(ctx, input.ID, input.Frozen); err != nil {
			return s.retryEpisodeWakeup(ctx, wakeup, err)
		}
	}
	queued, _, err := s.store.QueueEpisodeAttempt(ctx, episode.ID, core.AgentRun{
		Mode: previous.Mode, IncidentID: previous.IncidentID,
		ChannelID:       episode.Destination.ChannelID,
		ThreadTS:        episode.Destination.ThreadTS,
		ConversationKey: previous.ConversationKey,
		SourceKind:      "watch", SourceID: input.ID, UserID: previous.UserID,
		Repository: previous.Repository, Prompt: input.Text,
		CommitmentTitle: previous.CommitmentTitle,
	})
	if err != nil {
		return s.retryEpisodeWakeup(ctx, wakeup, err)
	}
	observation, _ := json.Marshal(map[string]string{
		"outcome": "resume_queued", "agent_run_id": queued.ID,
	})
	return s.store.ResolveEpisodeWakeup(
		ctx, wakeup.ID, episodeWakeupLeaseOwner, wakeup.FencingToken, observation,
	)
}

func (s *Service) retryEpisodeWakeup(
	ctx context.Context,
	wakeup core.EpisodeWakeup,
	cause error,
) error {
	observation, _ := json.Marshal(map[string]string{"error": trimError(cause)})
	retryErr := s.store.RetryEpisodeWakeup(
		ctx, wakeup.ID, episodeWakeupLeaseOwner, wakeup.FencingToken,
		s.queueDelay(1), observation,
	)
	if retryErr != nil && !errors.Is(retryErr, store.ErrConflict) {
		return retryErr
	}
	return cause
}
