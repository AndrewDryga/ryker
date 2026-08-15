package service

import (
	"context"
	"encoding/json"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/knowledgeoffer"
	"github.com/AndrewDryga/responder/internal/slackui"
)

// offerEpisodeKnowledge posts a confirmation card for each artefact a finished
// turn proposed keeping, and says nothing at all when the record does not back
// the proposal.
//
// Silence is the common case and the right one. Most episodes verify nothing,
// most verified ones have nothing worth generalizing, and a card on every
// completion — "this could be a runbook" — is how a confirmation click stops
// being a decision. Failures are logged rather than returned: an offer is an
// addition to a report that has already been produced, and losing one must not
// strand a finished answer.
func (s *Service) offerEpisodeKnowledge(
	ctx context.Context, run core.AgentRun, incidentID, channelID string,
	operations []investigation.ResultOperation,
) {
	var episode knowledgeoffer.Episode
	read := false
	for _, operation := range operations {
		kind, ok := knowledgeoffer.Kind(operation.Type)
		if !ok || channelID == "" || run.EpisodeID == "" {
			continue
		}
		if !read {
			evidence, err := s.store.Intelligence.EpisodeKnowledgeEvidence(ctx, run.EpisodeID)
			if err != nil {
				s.log.Warn("read episode knowledge evidence", "run", run.ID, "error", err)
				return
			}
			episode, read = evidence, true
		}
		if err := s.postKnowledgeOffer(
			ctx, run, incidentID, channelID, kind, operation, episode,
		); err != nil && ctx.Err() == nil {
			s.log.Warn(
				"offer episode knowledge",
				"run", run.ID, "operation", operation.ID, "error", err,
			)
		}
	}
}

func (s *Service) postKnowledgeOffer(
	ctx context.Context, run core.AgentRun, incidentID, channelID, kind string,
	operation investigation.ResultOperation, episode knowledgeoffer.Episode,
) error {
	artifact, err := knowledgeoffer.Evaluate(
		kind, operation.RunbookOffer, operation.CardOffer, episode,
	)
	if err != nil {
		// Not an error path. "The episode did not verify anything" is the
		// ordinary answer for almost every turn, and the refused offer is worth
		// a line because a model proposing runbooks for unverified work is a
		// prompt problem this is the only evidence of.
		s.log.Info(
			"episode knowledge not offered",
			"run", run.ID, "operation", operation.ID, "kind", kind, "reason", err,
		)
		return nil
	}
	payload, err := json.Marshal(knowledgeoffer.NewConfirmation(
		kind, run.EpisodeID, operation.ID, channelID, s.now().UTC(),
	))
	if err != nil || len(payload) > 1900 {
		return err
	}
	body, err := slackui.Encode(s.sanitizeMessage(slackui.WithKnowledgeOffer(
		slackui.Message{}, artifact, string(payload),
		s.cleanStructuredField(artifact.Rationale, 200),
	)))
	if err != nil {
		return err
	}
	_, err = s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID:         "knowledge_offer_" + run.ID + "_" + operation.ID,
		IncidentID: incidentID, EpisodeID: run.EpisodeID, Operation: "post",
		Kind: "knowledge_offer", ChannelID: channelID, Body: body,
		CoalesceKey: "knowledge_offer:" + kind + ":" + run.EpisodeID,
	})
	return err
}

// handleConfirmKnowledgeOffer is the operator's click, and the only way any of
// this is ever created.
//
// Everything the card said is recomputed here rather than trusted. The button
// value carries an identity and nothing else; the offer itself is read back out
// of the episode's own event stream, re-validated through the same validator
// that accepted it, and graded again against the record — so a payload edited
// in transit can change which offer is confirmed at most, and not what it says.
// That is the memory confirmation's discipline applied to the two offers whose
// product leaves this host entirely.
func (s *Service) handleConfirmKnowledgeOffer(ctx context.Context, input core.SlackInput) error {
	if !s.cfg.IsOperator(input.UserID) {
		return s.finishSlashInput(ctx, input, slackui.KnowledgeOperatorOnly)
	}
	allowed, err := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
	if err != nil {
		return err
	}
	if !allowed {
		return s.finishSlashInput(ctx, input, slackui.KnowledgeMembershipRequired)
	}
	var payload knowledgeoffer.Confirmation
	if err := decisionpkg.DecodeStrictJSON([]byte(input.ActionValue), &payload); err != nil {
		return s.finishSlashInput(ctx, input, slackui.KnowledgeConfirmationStale)
	}
	if err := payload.Resolve(input.ChannelID, s.now().UTC()); err != nil {
		return s.finishSlashInput(ctx, input, slackui.KnowledgeConfirmationStale)
	}
	operation, err := s.recordedKnowledgeOffer(ctx, payload)
	if err != nil {
		return s.finishSlashInput(ctx, input, slackui.KnowledgeConfirmationStale)
	}
	episode, err := s.store.Intelligence.EpisodeKnowledgeEvidence(ctx, payload.EpisodeID)
	if err != nil {
		return err
	}
	artifact, err := knowledgeoffer.Evaluate(
		payload.Kind, operation.RunbookOffer, operation.CardOffer, episode,
	)
	if err != nil {
		return s.finishSlashInput(ctx, input, slackui.KnowledgeRefusedNotice)
	}
	return s.createConfirmedKnowledge(ctx, input, payload, artifact)
}

// recordedKnowledgeOffer reads the offer back and re-validates it.
//
// Re-validating a payload the host itself wrote looks redundant and is not: the
// row was written by an older binary in every case that matters, and an
// operation this build would refuse must not become a document because a
// previous one accepted it.
func (s *Service) recordedKnowledgeOffer(
	ctx context.Context, payload knowledgeoffer.Confirmation,
) (investigation.ResultOperation, error) {
	var operation investigation.ResultOperation
	kind, recorded, err := s.store.Intelligence.EpisodeOfferedOperation(
		ctx, payload.EpisodeID, payload.OperationID,
	)
	if err != nil {
		return operation, err
	}
	if kind != episodepkg.EventKnowledgeOffered {
		return operation, core.ErrNotFound
	}
	if err := decisionpkg.DecodeStrictJSON(recorded, &operation); err != nil {
		return investigation.ResultOperation{}, err
	}
	if err := operation.Validate(); err != nil {
		return investigation.ResultOperation{}, err
	}
	return operation, nil
}

// createConfirmedKnowledge is the one place either artefact comes into
// existence, and neither of them comes into existence here.
//
// A runbook becomes an unpublished draft Emisar holds; a card becomes an
// engineering task that ends at a draft pull request. Both are somebody else's
// decision to finish, which is the whole shape of this feature: Responder
// proposes durable knowledge and never publishes it.
func (s *Service) createConfirmedKnowledge(
	ctx context.Context, input core.SlackInput,
	payload knowledgeoffer.Confirmation, artifact knowledgeoffer.Artifact,
) error {
	if artifact.Kind == knowledgeoffer.KindCard {
		repository, err := s.effectiveRepository(
			ctx, input.ChannelID, input.UserID, s.cfg.Slack.DefaultRepository,
		)
		if err != nil {
			return err
		}
		if err := s.createWatchedEngineeringTask(
			ctx, input, input, artifact.Card.TaskTitle(), repository,
			artifact.Card.TaskPrompt(s.now().UTC()), nil,
		); err != nil {
			return s.finishSlashInput(ctx, input, slackui.KnowledgeCardFailed+err.Error())
		}
		s.auditKnowledge(ctx, input, payload, "kb_card", artifact.Card.Path())
		return s.finishSlashInput(
			ctx, input, slackui.KnowledgeCardStartedNotice(artifact.Card.Path()),
		)
	}
	arguments, err := knowledgeoffer.RunbookArguments(artifact.Draft)
	if err != nil {
		return s.finishSlashInput(ctx, input, slackui.KnowledgeRefusedNotice)
	}
	state, err := s.emisar.CreateRunbookDraft(ctx, arguments)
	if err != nil {
		return s.finishSlashInput(ctx, input, slackui.KnowledgeDraftFailed+err.Error())
	}
	s.auditKnowledge(
		ctx, input, payload, "runbook_draft",
		state.Slug+" from "+artifact.Draft.Action.ActionID+" on "+artifact.Draft.Action.PackRef,
	)
	return s.finishSlashInput(
		ctx, input, slackui.RunbookDraftedNotice(state.Slug, state.DefinitionSHA256),
	)
}

func (s *Service) auditKnowledge(
	ctx context.Context, input core.SlackInput,
	payload knowledgeoffer.Confirmation, outcome, detail string,
) {
	s.audit(ctx, core.AuditEvent{
		ID:   "audit_knowledge_confirmed_" + input.ID,
		Kind: "knowledge.offer.confirmed", ActorID: input.UserID, ObjectID: payload.EpisodeID,
		Outcome: outcome, Detail: detail,
	})
}
