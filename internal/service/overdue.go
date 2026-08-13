package service

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/slackui"
)

// overdueBatch bounds one maintenance pass. Surfacing is cheap, but a backlog
// after an outage should not turn into a burst of Slack writes.
const overdueBatch = 20

// surfaceOverdueEpisodes tells operators about accepted work that stopped
// making progress.
//
// Accepting a request is a promise, and the thing that most distinguishes a
// teammate from a request/response bot is what happens when a promise cannot be
// kept: a teammate says so. Without this an episode that stalls simply goes
// quiet, which reads as an answer still coming rather than as work that needs
// attention.
//
// Each episode is surfaced once per generation. A second overdue interval with
// no progress moves it to blocked rather than posting again — repeating
// "still nothing" is noise, and a blocked episode carries an operator-facing
// reason and its existing controls.
func (s *Service) surfaceOverdueEpisodes(ctx context.Context, now time.Time) {
	grace := s.cfg.Limits.EpisodeOverdueAfter.Duration
	if grace <= 0 {
		return
	}
	episodes, err := s.store.ListOverdueEpisodes(ctx, now.Add(-grace), overdueBatch)
	if err != nil {
		if ctx.Err() == nil {
			s.log.Warn("list overdue episodes", "error", err)
		}
		return
	}
	for _, episode := range episodes {
		if err := s.surfaceOverdueEpisode(ctx, episode, now, grace); err != nil {
			if ctx.Err() != nil {
				return
			}
			s.log.Warn(
				"surface overdue commitment",
				"episode", episode.ID,
				"error", err,
			)
		}
	}
}

func (s *Service) surfaceOverdueEpisode(
	ctx context.Context,
	episode core.WorkEpisode,
	now time.Time,
	grace time.Duration,
) error {
	dueAt := episode.ProgressDueAt
	if dueAt.IsZero() {
		dueAt = episode.UpdatedAt
	}
	overdueBy := now.Sub(dueAt)
	// One notice per progress generation. The generation advances whenever the
	// episode reports progress, so a stalled episode keeps the same key and a
	// resumed one gets a fresh chance to be surfaced later.
	key := fmt.Sprintf("commitment-overdue:%s:%d", episode.ID, episode.ProgressSequence)
	// Appending is idempotent: a repeat returns the original event rather than
	// failing, so its timestamp is what distinguishes "first time we noticed"
	// from "we already said this".
	event, err := s.store.AppendWorkEpisodeEvent(ctx, episode.AgentRunID, core.WorkEpisodeEvent{
		Kind:           episodepkg.EventCommitmentOverdue,
		Actor:          "host",
		IdempotencyKey: key,
	})
	if err != nil {
		return err
	}
	if event.CreatedAt.Before(now) {
		// Already surfaced for this generation. Once it has been overdue for a
		// further full interval, stop repeating and change state instead: an
		// operator should see a blocked episode, not a second reminder.
		if now.Sub(event.CreatedAt) >= grace {
			return s.blockStalledEpisode(ctx, episode, overdueBy)
		}
		return nil
	}
	// "No progress" is what silence looks like from here, but it is not always
	// what happened. A run can be wedged on a failure it has already recorded,
	// and saying only that nothing moved sends an operator looking for a slow
	// agent when the agent finished long ago. The message renders NextAction,
	// so naming the cause here puts it in front of them.
	episode.NextAction = stalledEpisodeNextAction(
		episode.NextAction, s.stalledRunDetail(ctx, episode),
	)
	destination := episode.Destination
	if destination.ChannelID == "" {
		destination.ChannelID = episode.Conversation.ChannelID
		destination.ThreadTS = episode.Conversation.ThreadTS
	}
	if destination.ChannelID == "" {
		// Nothing to post to; the event above still records the fact.
		return nil
	}
	s.audit(ctx, core.AuditEvent{
		Kind: "episode.commitment.overdue", ActorID: "responder",
		ObjectID: episode.ID, Outcome: "surfaced",
		Detail: fmt.Sprintf("overdue by %s in phase %q", overdueBy.Round(time.Minute), episode.Phase),
	})
	return s.postInputMessageAtEpisode(
		ctx,
		"overdue_"+episode.ID+"_"+fmt.Sprint(episode.ProgressSequence),
		episode.ID,
		destination.ChannelID,
		destination.ThreadTS,
		slackui.CommitmentOverdueMessage(episode, overdueBy),
	)
}

// blockStalledEpisode stops an episode that has been silent for two full
// intervals. A blocked episode is honest about its state; one that keeps
// receiving reminders is not.
func (s *Service) blockStalledEpisode(
	ctx context.Context,
	episode core.WorkEpisode,
	overdueBy time.Duration,
) error {
	if episode.State == core.EpisodeBlocked {
		return nil
	}
	s.audit(ctx, core.AuditEvent{
		Kind: "episode.commitment.stalled", ActorID: "responder",
		ObjectID: episode.ID, Outcome: "blocked",
		Detail: fmt.Sprintf("no progress for %s", overdueBy.Round(time.Minute)),
	})
	// No further progress deadline: a blocked episode is waiting on a person,
	// not on itself, so it should not keep re-arming this check.
	return s.store.SetWorkEpisodePhase(
		ctx,
		episode.AgentRunID,
		core.EpisodeBlocked,
		"blocked",
		"Stalled",
		stalledEpisodeNextAction(
			"An operator needs to retry or close this work",
			s.stalledRunDetail(ctx, episode),
		),
		time.Time{},
	)
}

// stalledRunDetail returns what the episode's run last failed on, if it
// recorded anything. An empty string means the run is simply quiet, which is
// its own answer and should not be dressed up as a cause.
func (s *Service) stalledRunDetail(ctx context.Context, episode core.WorkEpisode) string {
	if episode.AgentRunID == "" {
		return ""
	}
	run, err := s.store.GetAgentRun(ctx, episode.AgentRunID)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(run.LastError)
}

func stalledEpisodeNextAction(base, detail string) string {
	if detail == "" {
		return base
	}
	return base + "; Responder could not advance it: " + detail
}
