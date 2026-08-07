package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/store"
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
// Every refusal is silent to the channel and recorded in the audit log. An
// operator who granted this authority should be able to see why it did not
// fire; everyone else should not have to read about work that did not happen.
func (s *Service) considerProactiveWork(
	ctx context.Context,
	input core.SlackInput,
	completion *investigation.CompletionAssessment,
	evidence []core.Evidence,
) error {
	if input.ChannelID == "" {
		return nil
	}
	now := s.now().UTC()
	assignments, err := s.store.ListLiveStandingAssignments(ctx, input.ChannelID, now)
	if err != nil || len(assignments) == 0 {
		return err
	}
	conversationKey := watchConversationKey(input)
	recurrences, err := s.store.CountCorrelatedEpisodes(
		ctx, conversationKey, now.Add(-proactiveRecurrenceWindow),
	)
	if err != nil {
		return err
	}
	for _, assignment := range assignments {
		eligibility := decisionpkg.ProactiveEligible(
			assignment, input, recurrences, completion, evidence, now,
		)
		if !eligibility.Eligible {
			s.auditProactive(ctx, assignment, input, "declined", eligibility.Reason)
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
	actionID, err := s.store.ClaimStandingAssignmentAction(
		ctx, assignment.ID, conversationKey, s.now().UTC(),
	)
	switch {
	case errors.Is(err, store.ErrAssignmentAlreadyActed):
		s.auditProactive(ctx, assignment, input, "declined", "already acted on this signal")
		return nil
	case errors.Is(err, store.ErrAssignmentBudgetSpent):
		s.auditProactive(ctx, assignment, input, "declined", "daily budget spent")
		return nil
	case err != nil:
		return err
	}

	title := core.BoundedText("Recurring: "+completion.Summary, 200)
	objective := proactiveObjective(assignment, completion)
	if err := s.createWatchedEngineeringTask(
		ctx, input, input, title, assignment.Repository, objective,
	); err != nil {
		// The claim stays. Releasing it on failure would let the next
		// occurrence try again immediately, and a task that fails to start
		// twice in a row is a reason to look, not to retry harder.
		s.auditProactive(ctx, assignment, input, "failed", trimError(err))
		return err
	}
	s.auditProactive(ctx, assignment, input, "started", "opened an engineering task")
	return s.store.CompleteStandingAssignmentAction(ctx, actionID, "", "started")
}

// proactiveObjective is the brief the engineering task works from.
//
// It states the change class as a boundary rather than a suggestion, because
// this task runs without anyone watching it start, and the scope the operator
// agreed to is the only thing standing between a narrow fix and a rewrite.
func proactiveObjective(
	assignment core.StandingAssignment,
	completion *investigation.CompletionAssessment,
) string {
	objective := fmt.Sprintf(
		"A recurring problem in %s was investigated and reached this conclusion:\n\n%s\n\n"+
			"Open a draft pull request that addresses it, limited to a %s change. "+
			"Do not change behaviour beyond that class. If the fix requires anything "+
			"broader, stop and say so instead of widening the change.",
		assignment.Repository, completion.Summary, assignment.ChangeClass,
	)
	if len(assignment.PathGlobs) > 0 {
		objective += fmt.Sprintf(
			"\n\nOnly these paths are in scope: %v. Touching anything else is out of scope "+
				"for this assignment, however reasonable it looks.",
			assignment.PathGlobs,
		)
	}
	return objective
}

func (s *Service) auditProactive(
	ctx context.Context,
	assignment core.StandingAssignment,
	input core.SlackInput,
	outcome string,
	detail string,
) {
	s.audit(ctx, core.AuditEvent{
		Kind: "proactive.assignment", ActorID: "responder",
		ObjectID: assignment.ID, Outcome: outcome,
		Detail: decisionpkg.BoundedField(detail+" · input="+input.ID, 500),
	})
}
