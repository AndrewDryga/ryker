package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/agentprompt"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/retrydelay"
	"github.com/AndrewDryga/responder/internal/store"
)

// handoffSourceKind marks the one agent run nobody in Slack is waiting for.
//
// It rides the triage lane's transport because that is where the watch dialect
// and its apply seam already live, and it is told apart by its source kind
// rather than a mode so that agent_runs.mode keeps the three values its CHECK
// constraint allows. Every triage path that reaches for a Slack input, a
// pending status, or the channel's session cursor asks this first: a handoff
// has no input, nothing to say, and runs in a session the channel has already
// let go of.
const handoffSourceKind = "handoff"

// outgoingSession is what the rotation seam knows about the session it is about
// to leave behind.
type outgoingSession struct {
	// memoryChannelID is the channel_memories key this session's turns write
	// through, which is the key its successor reads back.
	memoryChannelID string
	repository      string
	lane            string
	turnCount       int
	// repositoryChanged rotates for a reason that also moves the conversation
	// key, so anything the old session summarized would land under a key
	// nothing reads.
	repositoryChanged bool
}

func isSessionHandoffRun(run core.AgentRun) bool {
	return run.SourceKind == handoffSourceKind
}

// retireRotatedSession closes the Coop session a rotation is leaving behind and
// queues its fork for cleanup — unless a memory handoff turn was admitted into
// it first, in which case the handoff owns the retirement, because the turn it
// is about to submit needs the session open to run in.
//
// Both lanes rotate identically and used to say so twice. Extracting it is what
// makes "and sometimes we leave it open" a single decision rather than a
// divergence waiting to happen.
func (s *Service) retireRotatedSession(
	ctx context.Context,
	sessionID string,
	closeKey string,
	reason string,
	outgoing outgoingSession,
) error {
	session, err := s.coop.GetSession(ctx, sessionID)
	// Unchanged from the two copies this replaces: a session Coop cannot
	// describe is neither closed nor scheduled, and that is not an error worth
	// failing the rotation over.
	if err != nil || session.ActiveTurnID != "" {
		return nil
	}
	if s.queueSessionHandoff(ctx, sessionID, outgoing) {
		return nil
	}
	if !watchSessionTerminal(session.State) {
		if _, _, closeErr := s.coop.Close(
			ctx, closeKey, session.ID, session.Revision,
		); closeErr != nil {
			return closeErr
		}
	}
	return s.store.ScheduleCleanup(ctx, sessionID, "", reason, false, s.now().UTC())
}

// queueSessionHandoff admits one bounded turn against the outgoing session and
// reports whether that session must therefore stay open.
//
// Nothing waits on it. The turn that triggered the rotation proceeds on the new
// session immediately; this one lands for the turns after it.
//
// Failing to queue is not a failure of the rotation. The handoff is an
// improvement on what happens by default, and the default — a fresh session
// reading whatever memory was last written — is exactly what a caller gets when
// this returns false.
func (s *Service) queueSessionHandoff(
	ctx context.Context,
	sessionID string,
	outgoing outgoingSession,
) bool {
	if sessionID == "" || outgoing.memoryChannelID == "" ||
		outgoing.turnCount < 1 || outgoing.repositoryChanged {
		return false
	}
	memory, err := s.store.Intelligence.GetChannelMemory(ctx, outgoing.memoryChannelID)
	// The freshness check, and the only one that stops this costing a model
	// turn per rotation on a channel whose turns already remember themselves.
	if err != nil || memory.TurnsSinceMemory < 1 {
		return false
	}
	// One in flight per channel falls out of the guards above rather than out of
	// a lock: a second rotation cannot reach here until its own session has
	// taken a turn, and QueueAgentRun is idempotent on the source pair, so the
	// same retiring session can never be handed off twice.
	_, created, err := s.store.QueueAgentRun(ctx, core.AgentRun{
		Mode:            core.AgentRunTriage,
		ChannelID:       outgoing.memoryChannelID,
		ConversationKey: "handoff:" + outgoing.memoryChannelID,
		SourceKind:      handoffSourceKind,
		SourceID:        handoffSourceKind + ":" + sessionID,
		Repository:      outgoing.repository,
		Prompt:          agentprompt.SessionHandoff(),
		SessionID:       sessionID,
		CommitmentTitle: "Carry the retiring session's context into channel memory",
		Episode: &core.WorkEpisode{
			Mode: core.EpisodeConversation, Effort: core.EffortConversational,
			Authority: core.AuthorityReadOnly, Activity: core.ActivityExplaining,
		},
	})
	if err != nil {
		s.log.Warn(
			"could not hand a rotating session's memory forward",
			"channel", outgoing.memoryChannelID, "session", sessionID,
			"lane", outgoing.lane, "error", trimError(err),
		)
		return false
	}
	if created {
		s.audit(ctx, core.AuditEvent{
			Kind: "slack.watch", ActorID: "responder", ObjectID: sessionID,
			Outcome: "memory_handoff_queued",
			Detail: fmt.Sprintf(
				"the %s session retiring after %d turns will summarize itself first",
				outgoing.lane, outgoing.turnCount,
			),
		})
	}
	return true
}

// prepareSessionHandoffTurn submits the handoff into the session it is about,
// which is the session the channel has already stopped using.
//
// It never retries. A handoff is worth one turn and no more: the fallback is
// the memory already on disk, and spending a run's whole attempt budget
// re-asking a session that is meant to be gone would hold its fork open for as
// long as the ladder allows.
func (s *Service) prepareSessionHandoffTurn(ctx context.Context, run core.AgentRun) error {
	session, err := s.coop.GetSession(ctx, run.SessionID)
	if err != nil {
		return s.abandonSessionHandoff(ctx, run, err)
	}
	if session.ActiveTurnID != "" {
		now := s.now()
		return s.store.DeferAgentRun(
			ctx, run.ID, "waiting for the retiring session's last turn",
			now.Add(retrydelay.DependencyWait(now.Sub(run.CreatedAt))),
		)
	}
	if session.State != "open" {
		return s.abandonSessionHandoff(
			ctx, run, fmt.Errorf("the retiring Coop session is %q", session.State),
		)
	}
	revision, err := s.store.FreezeAgentRunRevision(ctx, run.ID, session.Revision)
	if err != nil {
		return s.abandonSessionHandoff(ctx, run, err)
	}
	if _, err := s.ensureAttemptContextManifest(
		ctx, run, session, run.Prompt, nil, nil,
	); err != nil {
		return s.abandonSessionHandoff(ctx, run, err)
	}
	turn, _, err := s.coop.SubmitTurn(
		ctx, run.IdempotencyKey, run.SessionID, revision, run.Prompt,
	)
	if err != nil {
		return s.abandonSessionHandoff(ctx, run, err)
	}
	if turn.ID == "" {
		return s.abandonSessionHandoff(
			ctx, run, errors.New("Coop returned an empty handoff turn ID"),
		)
	}
	session, err = s.coop.GetSession(ctx, run.SessionID)
	if err != nil {
		return s.abandonSessionHandoff(ctx, run, err)
	}
	return s.store.MarkAgentRunSubmitted(
		ctx, run.ID, turn.ID, session.Revision, run.CoopEventSequence,
	)
}

// finalizeSessionHandoffTurn stores what the retiring session said about itself
// and then retires it.
//
// The retirement happens on every path, including the ones where the turn said
// nothing usable. Rotation skipped it on the promise that this would do it, and
// a promise kept only on success leaves a fork open forever.
func (s *Service) finalizeSessionHandoffTurn(ctx context.Context, run core.AgentRun) error {
	status := "The retiring session did not summarize itself"
	if run.TerminalState == "completed" {
		decision, err := decisionpkg.ParseWatchDecision(string(run.Result), s.now())
		switch {
		case err != nil:
			s.log.Warn(
				"a retiring session did not summarize itself in the watch dialect",
				"run", run.ID, "session", run.SessionID, "error", trimError(err),
			)
		default:
			if err := s.store.Intelligence.ApplyHandoffMemory(
				ctx, run.ChannelID, decision.Memory.WithoutThreadScope(),
			); err != nil {
				return err
			}
			status = "Carried the retiring session's context forward"
		}
	}
	if err := s.store.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeCompleted, "finished", status, "", time.Time{},
	); err != nil {
		return err
	}
	if err := s.store.FinishAgentRun(ctx, run.ID); err != nil {
		return err
	}
	return s.retireHandedOffSession(ctx, run)
}

// abandonSessionHandoff gives up on the handoff without spending an attempt and
// puts the session back on the path rotation would have taken.
func (s *Service) abandonSessionHandoff(
	ctx context.Context,
	run core.AgentRun,
	cause error,
) error {
	receiptCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	s.log.Warn(
		"a rotating session could not hand its memory forward",
		"run", run.ID, "session", run.SessionID, "error", trimError(cause),
	)
	if _, _, err := s.store.FinishAgentRunFailure(
		receiptCtx, run.ID, trimError(cause), nil, store.AgentRunFailureEffects{},
	); err != nil {
		return err
	}
	return s.retireHandedOffSession(receiptCtx, run)
}

// retireHandedOffSession performs the close and cleanup that rotation deferred.
func (s *Service) retireHandedOffSession(ctx context.Context, run core.AgentRun) error {
	session, err := s.coop.GetSession(ctx, run.SessionID)
	if err != nil {
		// The same tolerance rotation itself has, for the same reason: the
		// orphan sweep in maintainLifecycle is the backstop for a session Coop
		// will not describe, and failing here would only replay this turn.
		return nil
	}
	if !watchSessionTerminal(session.State) && session.ActiveTurnID == "" {
		if _, _, closeErr := s.coop.Close(
			ctx, "responder:handoff-close:"+run.SessionID, session.ID, session.Revision,
		); closeErr != nil {
			return closeErr
		}
	}
	return s.store.ScheduleCleanup(
		ctx, run.SessionID, "", "session retired after its memory handoff",
		false, s.now().UTC(),
	)
}

// handoffTurnResult records what the handoff turn asked the host to apply and
// reports whether the staged result is usable.
//
// It runs the same operation applier every other watch result goes through, so
// an operation the host cannot apply is dropped with a trace here exactly as it
// is there — and it deliberately runs none of the correction ladder above it.
// Every rung of that ladder sends the result back to the model for another
// turn, which is the one thing a handoff must never do.
func (s *Service) handoffTurnResult(
	ctx context.Context,
	run core.AgentRun,
	turn coop.Turn,
	staged *stagedTurn,
) (bool, error) {
	decision, err := decisionpkg.ParseWatchDecision(turn.AssistantMessage, s.now())
	if err != nil {
		return false, nil
	}
	if err := s.recordResultOperationEvents(
		ctx, run.ID, decision.AppliedOperations,
	); err != nil {
		return true, err
	}
	return false, staged.setResult(decisionpkg.MarshalWatchDecisionResult(decision))
}
