package service

import (
	"context"
	"encoding/json"

	"github.com/AndrewDryga/responder/internal/assignments"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/slackui"
)

// offerStandingAssignment posts a confirmation card for each standing
// assignment a finished turn proposed, and says nothing when the bounds cannot
// be normalized.
//
// Silence on refusal is the same choice the knowledge offers make and matters
// more here: an operator who did not ask for standing authority should never
// see a card offering it, and a model that proposed bounds this host cannot
// grant has produced a prompt problem rather than an operator decision. The log
// line is the only evidence of that, which is why it names the reason.
//
// Failures are logged rather than returned. An offer is an addition to a report
// that has already been produced, and losing the card must not strand a
// finished answer.
func (s *Service) offerStandingAssignment(
	ctx context.Context, run core.AgentRun, incidentID, channelID string,
	operations []investigation.ResultOperation,
) {
	for _, operation := range operations {
		if operation.Type != "offer_assignment" || operation.AssignmentOffer == nil {
			continue
		}
		if channelID == "" || run.EpisodeID == "" {
			continue
		}
		if err := s.postAssignmentOffer(
			ctx, run, incidentID, channelID, operation,
		); err != nil && ctx.Err() == nil {
			s.log.Warn(
				"offer standing assignment",
				"run", run.ID, "operation", operation.ID, "error", err,
			)
		}
	}
}

func (s *Service) postAssignmentOffer(
	ctx context.Context, run core.AgentRun, incidentID, channelID string,
	operation investigation.ResultOperation,
) error {
	assignment, err := assignments.Normalize(
		*operation.AssignmentOffer, channelID, s.now().UTC(),
	)
	if err != nil {
		s.log.Info(
			"standing assignment not offered",
			"run", run.ID, "operation", operation.ID, "reason", err,
		)
		return nil
	}
	payload, err := json.Marshal(assignments.NewConfirmation(
		run.EpisodeID, operation.ID, channelID, s.now().UTC(),
	))
	if err != nil || len(payload) > 1900 {
		return err
	}
	body, err := slackui.Encode(s.sanitizeMessage(slackui.WithAssignmentOffer(
		slackui.Message{}, assignment, assignments.ExpiryDays(*operation.AssignmentOffer),
		string(payload),
		s.cleanStructuredField(operation.AssignmentOffer.Rationale, 200),
	)))
	if err != nil {
		return err
	}
	_, err = s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID:         "assignment_offer_" + run.ID + "_" + operation.ID,
		IncidentID: incidentID, EpisodeID: run.EpisodeID, Operation: "post",
		Kind: "assignment_offer", ChannelID: channelID, Body: body,
		CoalesceKey: "assignment_offer:" + run.EpisodeID,
	})
	return err
}

// handleConfirmAssignmentOffer is the operator's click, and the only way a
// standing assignment is ever created.
//
// Everything the card said is recomputed here rather than trusted. The button
// value carries an identity and nothing else; the offer is read back out of the
// episode's own event stream, re-validated through the same validator that
// accepted it, and normalized again — so a payload edited in transit can change
// which offer is confirmed at most, and never what it grants. That is the
// memory confirmation's discipline applied to the widest authority in the
// product: an assignment lets Responder open pull requests without anyone
// clicking again.
func (s *Service) handleConfirmAssignmentOffer(ctx context.Context, input core.SlackInput) error {
	if !s.cfg.IsOperator(input.UserID) {
		return s.finishSlashInput(ctx, input, slackui.AssignmentOperatorOnly)
	}
	allowed, err := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
	if err != nil {
		return err
	}
	if !allowed {
		return s.finishSlashInput(ctx, input, slackui.AssignmentMembershipRequired)
	}
	var payload assignments.Confirmation
	if err := decisionpkg.DecodeStrictJSON([]byte(input.ActionValue), &payload); err != nil {
		return s.finishSlashInput(ctx, input, slackui.AssignmentConfirmationStale)
	}
	if err := payload.Resolve(input.ChannelID, s.now().UTC()); err != nil {
		return s.finishSlashInput(ctx, input, slackui.AssignmentConfirmationStale)
	}
	offer, err := s.recordedAssignmentOffer(ctx, payload)
	if err != nil {
		return s.finishSlashInput(ctx, input, slackui.AssignmentConfirmationStale)
	}
	assignment, err := assignments.Normalize(offer, input.ChannelID, s.now().UTC())
	if err != nil {
		return s.finishSlashInput(ctx, input, slackui.AssignmentRefusedNotice)
	}
	// The one field Normalize will not fill: an assignment records who
	// confirmed it, and until this click nobody had.
	assignment.ActorID = input.UserID
	saved, err := s.store.StandingAssignments.Create(ctx, assignment)
	if err != nil {
		return s.finishSlashInput(ctx, input, slackui.AssignmentGrantFailed+err.Error())
	}
	s.audit(ctx, assignments.CreatedAudit(saved, input.UserID))
	return s.finishSlashMessage(ctx, input, slackui.AssignmentSavedMessage(saved))
}

// recordedAssignmentOffer reads the offer back and re-validates it.
//
// Re-validating a payload the host itself wrote looks redundant and is not: the
// row was written by an older binary in every case that matters, and an offer
// this build would refuse — a change class since removed from the allowlist, a
// budget over a range since tightened — must not become a standing grant
// because a previous one accepted it.
func (s *Service) recordedAssignmentOffer(
	ctx context.Context, payload assignments.Confirmation,
) (core.StandingAssignmentOffer, error) {
	kind, recorded, err := s.store.Intelligence.EpisodeOfferedOperation(
		ctx, payload.EpisodeID, payload.OperationID,
	)
	if err != nil {
		return core.StandingAssignmentOffer{}, err
	}
	if kind != episodepkg.EventAssignmentOffered {
		return core.StandingAssignmentOffer{}, assignments.ErrNotOffered
	}
	var operation investigation.ResultOperation
	if err := decisionpkg.DecodeStrictJSON(recorded, &operation); err != nil {
		return core.StandingAssignmentOffer{}, err
	}
	if err := operation.Validate(); err != nil {
		return core.StandingAssignmentOffer{}, err
	}
	if operation.Type != "offer_assignment" || operation.AssignmentOffer == nil {
		return core.StandingAssignmentOffer{}, assignments.ErrNotOffered
	}
	return *operation.AssignmentOffer, nil
}
