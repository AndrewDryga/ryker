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

// overdueActivityGrace is how long the narration stream must be silent before
// this sweep will call an episode stalled.
//
// It sits beside EpisodeOverdueAfter (30 minutes by default) and is
// deliberately a fraction of it, because the two clocks measure different
// things. Progress prose is written when the model decides to write it, so half
// an hour without a line is ordinary inside one long turn — that is a reporting
// style, not a stall. Narration is emitted as the work happens, at up to a
// moment per second while a turn is active, so five minutes of silence from a
// stream that granular is a real signal: something stopped.
//
// A constant rather than a configurable limit, because the value follows from
// the stream's cadence rather than from anyone's policy. The knob an operator
// has for how patient the watchdog is remains episode_overdue_after.
const overdueActivityGrace = 5 * time.Minute

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
//
// Silence is the signal, and prose is only half of it. An episode whose
// narration is still arriving is skipped no matter how late its progress note
// is, and skipping is all that happens: the deadline stays in the past, so the
// next pass asks the same question again and surfaces the episode the moment
// the stream goes quiet. That deferral has no cap on purpose. A turn that
// narrates continuously for hours without writing prose is a working turn, and
// the watchdog's job is detecting silence, not enforcing prose discipline —
// the limits that stop an overlong turn are its own budget and timeout, which
// end it and report why. Capping the deferral here would only reinstate the
// alarm this rule exists to prevent, one interval later.
func (s *Service) surfaceOverdueEpisodes(ctx context.Context, now time.Time) {
	grace := s.cfg.Limits.EpisodeOverdueAfter.Duration
	if grace <= 0 {
		return
	}
	episodes, err := s.store.ListOverdueEpisodes(
		ctx, now.Add(-grace), now.Add(-overdueActivityGrace), overdueBatch,
	)
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
		slackui.CommitmentOverdueMessage(episode, overdueBy, episodeActivityAge(episode, now)),
	)
}

// episodeActivityAge is how long ago the turn last narrated anything, and zero
// when nothing was ever recorded for it — an episode from before the stream
// existed, or a turn that produced no narration at all.
//
// Zero is the honest answer to "how long has it been quiet" when there is no
// evidence either way, and the message treats it as one: it then says only what
// the progress clock knows. A stamp in the future is the same non-answer rather
// than a negative age.
func episodeActivityAge(episode core.WorkEpisode, now time.Time) time.Duration {
	if episode.LastActivityAt.IsZero() {
		return 0
	}
	return max(now.Sub(episode.LastActivityAt), 0)
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
