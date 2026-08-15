package service

import (
	"context"
	"time"

	"github.com/AndrewDryga/responder/internal/assignments"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
)

// proactiveRecurrenceWindow is how far back a signal counts as recurring.
//
// Long enough that a weekly pattern is visible, short enough that something
// fixed a month ago does not still look live.
const proactiveRecurrenceWindow = 14 * 24 * time.Hour

// considerProactiveWork opens an engineering task when a standing assignment
// covers a recurring, evidence-backed problem.
//
// It runs after an investigation concludes rather than when the signal arrives,
// because the decision needs the conclusion: whether Responder actually
// understood the problem is the difference between a useful pull request and a
// guess in someone's review queue.
//
// Every refusal is silent to the channel and recorded. An operator who granted
// this authority should be able to see why it did not fire; everyone else
// should not have to read about work that did not happen.
//
// The shadow check sits between the gate and the action, and nowhere else.
// There is deliberately no second eligibility path for shadowed assignments:
// the entire value of the record is that the decisions in it are the ones the
// live feature would have made, and a cheaper gate for the rehearsal would
// produce evidence about a feature nobody is going to ship.
func (s *Service) considerProactiveWork(
	ctx context.Context,
	input core.SlackInput,
	episodeID string,
	completion *investigation.CompletionAssessment,
	evidence []core.Evidence,
) error {
	if input.ChannelID == "" {
		return nil
	}
	now := s.now().UTC()
	live, err := s.store.StandingAssignments.ListLive(ctx, input.ChannelID, now)
	if err != nil || len(live) == 0 {
		return err
	}
	conversationKey := watchConversationKey(input)
	recurrences, err := s.store.StandingAssignments.CountCorrelatedEpisodes(
		ctx, conversationKey, now.Add(-proactiveRecurrenceWindow),
	)
	if err != nil {
		return err
	}
	for _, assignment := range live {
		eligibility := decisionpkg.ProactiveEligible(
			assignment, input, recurrences, completion, evidence, now,
		)
		s.recordProactiveEvaluation(ctx, assignment, input, episodeID, eligibility)
		if !eligibility.Eligible || assignment.Shadow {
			continue
		}
		if err := s.startProactiveWork(ctx, assignment, input, conversationKey, completion); err != nil {
			return err
		}
	}
	return nil
}

// startProactiveWork claims the right to act, then acts.
//
// The claim is what makes "one pull request per issue" and the daily budget
// real; both are enforced by the store rather than checked here, so this cannot
// forget them. Claiming first also means a crash between the claim and the task
// leaves the issue handled rather than handled twice.
func (s *Service) startProactiveWork(
	ctx context.Context,
	assignment core.StandingAssignment,
	input core.SlackInput,
	conversationKey string,
	completion *investigation.CompletionAssessment,
) error {
	actionID, err := s.store.StandingAssignments.ClaimAction(
		ctx, assignment.ID, conversationKey, s.now().UTC(),
	)
	if refusal := assignments.ClaimRefusal(err); refusal != "" {
		s.audit(ctx, assignments.AuditEvent(assignment.ID, input.ID, "declined", refusal))
		return nil
	}
	if err != nil {
		return err
	}
	title, objective := assignments.Task(assignment, completion.Summary)
	if err := s.createWatchedEngineeringTask(
		ctx, input, input, title, assignment.Repository, objective, nil,
	); err != nil {
		// The claim stays. Releasing it on failure would let the next
		// occurrence try again immediately, and a task that fails to start
		// twice in a row is a reason to look, not to retry harder.
		s.audit(ctx, assignments.AuditEvent(assignment.ID, input.ID, "failed", trimError(err)))
		return err
	}
	s.audit(ctx, assignments.AuditEvent(assignment.ID, input.ID, "started", "opened a task"))
	return s.store.StandingAssignments.CompleteAction(ctx, actionID, "", "started")
}

// recordProactiveEvaluation writes what the gate decided, twice over.
//
// The durable row is the shadow period's evidence and outlives the audit
// horizon; the audit event is where an operator already looks when Responder
// did nothing. The reason is stored exactly as the gate produced it, not
// annotated with the shadow state, because the tally groups refusals by that
// string to find the one that repeats — and a reason decorated per assignment
// would split one recurring refusal into two rarer-looking ones.
//
// A failure here does not stop the turn: this runs after the answer has been
// delivered, and losing the record of work that did not happen must not lose
// the reply that did.
func (s *Service) recordProactiveEvaluation(
	ctx context.Context, assignment core.StandingAssignment, input core.SlackInput,
	episodeID string, eligibility decisionpkg.ProactiveEligibility,
) {
	evaluation := assignments.Evaluation(assignment, input.ID, episodeID, input.Text, eligibility)
	if _, err := s.store.StandingAssignments.RecordEvaluation(
		ctx, evaluation,
	); err != nil && ctx.Err() == nil && s.log != nil {
		s.log.Warn(
			"record standing assignment evaluation", "assignment", assignment.ID,
			"input", input.ID, "verdict", evaluation.Verdict, "error", err,
		)
	}
	if episodeID != "" {
		// Best effort, and after the row: the ledger is the durable evidence
		// and the event is what makes it harvestable into a replay fixture.
		// Losing the second must not cost the first, and neither may cost the
		// reply this turn already delivered.
		_, _ = s.store.AppendEpisodeEvent(ctx, episodeID, assignments.EpisodeEvent(evaluation))
	}
	s.audit(ctx, assignments.AuditEvent(
		assignment.ID, input.ID, evaluation.Verdict,
		assignments.AuditDetail(assignment, evaluation.Reason),
	))
}
