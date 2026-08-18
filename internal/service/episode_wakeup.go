package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/terraformwakeup"
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

	// A wakeup must never widen the audience the episode was working in.
	//
	// The destination thread is normally bound when the episode is created, but
	// it can be empty — one Terraform lifecycle episode reached its wakeup with
	// destination_thread_ts unset while every sibling episode in the same
	// channel had one. The timer then faithfully propagated "no thread", and a
	// reply that belonged under a run notification went to the whole channel
	// instead. Nothing was wrong with the wakeup; it was told nothing and said
	// nothing.
	//
	// The attempt that scheduled the wait knows where it was talking, so that
	// is the fallback. Posting at channel level is the one outcome a resumed
	// wait should never choose on its own: it is the loudest possible reading
	// of missing information.
	threadTS := episode.Destination.ThreadTS
	if threadTS == "" {
		threadTS = previous.ThreadTS
	}
	state, err := decodeWatchRunContext(previous)
	if err != nil {
		return s.retryEpisodeWakeup(ctx, wakeup, err)
	}
	state.ResponseThreadTS = threadTS
	state.ConversationFollowup = true
	frozen, err := json.Marshal(state)
	if err != nil {
		return s.retryEpisodeWakeup(ctx, wakeup, err)
	}

	// An alert stream resumes on different terms from a GitHub check. The
	// question was already answered in this thread, so the useful turn is a
	// re-check that speaks only if the answer changed — otherwise the operator
	// gets the same assessment posted again every window.
	preface := ""
	if wakeup.Kind == alertStreamWaitKind {
		preface = "This alert stream was answered earlier in this thread; " +
			"re-check the alert's current state, reply only if the verdict, " +
			"impact or recommended action changed, and otherwise stay silent " +
			"and emit a new bounded wait_external of the same kind. "
	}
	sourceID := "episode_wakeup_" + wakeup.ID
	input := core.SlackInput{
		ID: sourceID, EnvelopeID: sourceID, EventID: sourceID, Kind: "recheck",
		TeamID: episode.WorkspaceID, ChannelID: episode.Destination.ChannelID,
		ThreadTS: threadTS, UserID: previous.UserID,
		Text: preface + fmt.Sprintf(
			"Resume the accepted work after the %s wait. Match this exact external object: %s. The promised success check is: %s. Re-check its state with fresh evidence, continue every open required goal, and report only when the result is decision-ready or an exact blocker remains. If it is still nonterminal, stay silent and emit a new bounded wait_external operation.",
			wakeup.Kind, string(wakeup.EventMatcher), core.FirstNonempty(wakeup.Verification, "the matched object reaches its required terminal state"),
		),
		Frozen: frozen, ReceivedAt: s.now().UTC(),
	}
	input = terraformwakeup.RestoreSourceLink(ctx, s.store, episode, input)
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
		ThreadTS:        threadTS,
		ConversationKey: previous.ConversationKey,
		SourceKind:      "watch", SourceID: input.ID, UserID: previous.UserID,
		Repository: previous.Repository, Prompt: input.Text, Context: frozen,
		CommitmentTitle: previous.CommitmentTitle,
	})
	if err != nil {
		return s.retryEpisodeWakeup(ctx, wakeup, err)
	}
	if err := s.store.FinishSlackInput(ctx, input.ID); err != nil {
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
