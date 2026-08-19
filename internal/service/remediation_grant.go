package service

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/remediation"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store/grantstore"
)

// grantTriggerClass is the scope a promotion would be granted in.
//
// It is assembled entirely from what the host already knows about the episode —
// the incident's own alert group key, the channel the work happened in, the
// repository the host resolved. A model never supplies any of it, which is the
// cheapest possible enforcement of "a proposal can never widen a grant": there
// is no field on the wire that could name another room, another service or
// another alert.
//
// An episode with no incident has no alert group key and therefore no trigger
// class. That is correct rather than a gap: a grant is authority to act on a
// recurring alert, and a one-off conversation has nothing recurring to key on.
func (s *Service) grantTriggerClass(
	ctx context.Context,
	incidentID string,
	channelID string,
) (remediation.TriggerClass, bool) {
	if incidentID == "" || channelID == "" {
		return remediation.TriggerClass{}, false
	}
	incident, err := s.store.GetIncident(ctx, incidentID)
	if err != nil || incident.SourceIncidentID == "" {
		return remediation.TriggerClass{}, false
	}
	return remediation.TriggerClass{
		AlertGroupKey: incident.SourceIncidentID,
		ChannelID:     channelID,
		Repository:    incident.Repository,
	}, true
}

// evaluateGrantPromotion grades one promotion — the host's own or a model's —
// against the host's recomputed evidence.
//
// `claimed` is what a model said, or zero when the host proposed this itself.
// Either way the decision rests on `verified`, which comes from the outcomes
// table. An offer the host cannot reproduce is refused and logged rather than
// quietly corrected: a result claiming six verified successes where the record
// holds two is worth seeing.
func (s *Service) evaluateGrantPromotion(
	ctx context.Context,
	class remediation.TriggerClass,
	action remediation.ActionRef,
	rung remediation.Rung,
	claimed int,
) (remediation.Grant, int, bool) {
	current, err := s.store.Grants.Get(ctx, class, action)
	if err != nil && !errors.Is(err, grantstore.ErrNotFound) {
		s.log.Warn("read remediation grant", "action", action.ActionID, "error", err)
		return remediation.Grant{}, 0, false
	}
	verified, err := s.store.Grants.VerifiedSuccesses(ctx, class, action)
	if err != nil {
		s.log.Warn("recompute remediation grant evidence", "action", action.ActionID, "error", err)
		return remediation.Grant{}, 0, false
	}
	if rung == "" {
		rung = remediation.NextRung(current)
	}
	granted, err := remediation.EvaluateOffer(
		remediation.Offer{Trigger: class, Action: action, Rung: rung, ClaimedSuccesses: claimed},
		current, verified, remediation.DefaultPolicy(), s.now().UTC(),
	)
	if err != nil {
		// Not an error path for the caller. Most refusals are "not earned yet",
		// which is the ordinary answer for almost every episode.
		s.log.Info(
			"remediation promotion not offered",
			"action", action.ActionID, "claimed", claimed, "verified", verified, "reason", err,
		)
		return remediation.Grant{}, verified, false
	}
	return granted, verified, true
}

// offerGrantPromotion posts the operator confirmation card when a rung has been
// earned, and says nothing at all when it has not.
//
// Silence is the common case and the right one. The alternative — a card saying
// "1 of 3 successes so far" on every remediation — would turn the one message
// that asks for authority into background noise, which is exactly how a
// confirmation click stops being a decision.
func (s *Service) offerGrantPromotion(
	ctx context.Context,
	incidentID string,
	episodeID string,
	channelID string,
	deliveryID string,
	action remediation.ActionRef,
	rung remediation.Rung,
	claimed int,
	rationale string,
) error {
	class, ok := s.grantTriggerClass(ctx, incidentID, channelID)
	if !ok {
		return nil
	}
	granted, verified, ok := s.evaluateGrantPromotion(ctx, class, action, rung, claimed)
	if !ok {
		return nil
	}
	payload, err := json.Marshal(remediation.NewConfirmation(granted, s.now().UTC()))
	if err != nil || len(payload) > 1900 {
		return nil
	}
	message := s.sanitizeMessage(slackui.WithGrantPromotionOffer(
		slackui.Message{}, granted, verified, string(payload),
		slackui.GrantExpiryLabel(granted.ExpiresAt, s.now().UTC()),
		s.cleanStructuredField(rationale, 200),
	))
	body, err := slackui.Encode(message)
	if err != nil {
		return err
	}
	_, err = s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID:          deliveryID,
		IncidentID:  incidentID,
		EpisodeID:   episodeID,
		Operation:   "post",
		Kind:        "grant_promotion",
		ChannelID:   channelID,
		Body:        body,
		CoalesceKey: "grant_promotion:" + granted.Action.ActionID + ":" + class.AlertGroupKey,
	})
	return err
}

// demoteGrantsForRun takes a rung back when a supervised run says the grant's
// premise no longer holds.
//
// Automatic, immediate, and it asks nobody. It runs on every terminal Emisar
// run, granted or not: a run that failed is evidence about the action whether or
// not this particular execution came from a grant. Failures here are logged
// rather than returned, because demotion is an addition to work that has already
// completed and losing it must not strand a finished run — but the log line is
// load-bearing, since a demotion that silently did not happen is authority
// nobody knows is still live.
func (s *Service) demoteGrantsForRun(ctx context.Context, approval core.EmisarApproval) {
	reason, demote := remediation.DemotionForRunStatus(approval.Status)
	if !demote {
		return
	}
	action := remediation.ActionRef{
		ActionID: approval.ActionID, PackRef: approval.PackRef, RunnerRef: approval.RunnerRef,
	}
	demoted, err := s.store.Grants.Demote(ctx, action, reason)
	if err != nil {
		s.log.Warn("demote remediation grant", "action", action.ActionID, "error", err)
		return
	}
	for _, grant := range demoted {
		s.audit(ctx, core.AuditEvent{
			ID:         "audit_grant_demoted_" + grant.ID + "_" + approval.RequestID,
			IncidentID: approval.IncidentID,
			Kind:       "remediation.grant.demoted", ActorID: "responder", ObjectID: grant.ID,
			Outcome: string(reason),
			Detail:  grant.Action.ActionID + " is now " + string(grant.Rung) + " run=" + approval.RunID,
		})
		if approval.ChannelID == "" {
			continue
		}
		body, err := slackui.Encode(s.sanitizeMessage(slackui.GrantDemotedMessage(grant, reason)))
		if err != nil {
			continue
		}
		if _, err := s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
			ID:         "grant_demoted_" + grant.ID + "_" + approval.RequestID,
			IncidentID: approval.IncidentID,
			EpisodeID:  s.approvalEpisodeID(ctx, approval),
			Operation:  "post", Kind: "grant_demotion", ChannelID: approval.ChannelID, Body: body,
		}); err != nil {
			s.log.Warn("post remediation demotion notice", "grant", grant.ID, "error", err)
		}
	}
}

// handleConfirmGrantPromotion is the operator's click, and the only way a rung
// is ever climbed.
//
// Everything the card said is recomputed here rather than trusted. The payload
// carries an identity, and the count, the expiry and the confirming operator are
// all derived again at this moment: the button value made a round trip through a
// Slack client, and a tampered one must not be able to buy authority. That is
// the same discipline the memory confirmation follows, applied to the one
// confirmation in the product where the stake is what Responder may do rather
// than what it may say.
func (s *Service) handleConfirmGrantPromotion(
	ctx context.Context,
	input core.SlackInput,
) error {
	allowed, err := s.authorizeGrantAction(ctx, input)
	if err != nil || !allowed {
		return err
	}
	var payload remediation.Confirmation
	if err := decisionpkg.DecodeStrictJSON([]byte(input.ActionValue), &payload); err != nil {
		return s.finishSlashInput(ctx, input, slackui.GrantConfirmationStale)
	}
	class, action, rung, err := payload.Resolve(input.ChannelID, s.now().UTC())
	if err != nil {
		return s.finishSlashInput(ctx, input, slackui.GrantConfirmationStale)
	}
	// Slack redelivers, and operators double-tap. The second press finds the
	// grant already at the rung it asked for, and EvaluateOffer would correctly
	// refuse it as a climb of zero rungs — which is safe but reads as "nothing
	// was granted" over a grant that plainly exists. Answer the question that
	// was actually asked instead.
	if held, err := s.store.Grants.Get(ctx, class, action); err == nil &&
		held.Rung == rung && held.Live(s.now().UTC()) {
		return s.finishSlashInput(ctx, input, slackui.GrantConfirmedNotice(held, held.SuccessCount))
	}
	granted, verified, ok := s.evaluateGrantPromotion(ctx, class, action, rung, 0)
	if !ok {
		return s.finishSlashInput(ctx, input, slackui.GrantRefusedNotice)
	}
	granted.GrantedBy = input.UserID
	stored, err := s.store.Grants.Confirm(ctx, granted)
	if err != nil {
		return s.finishSlashInput(
			ctx, input,
			"*Responder could not record this grant.* "+err.Error(),
		)
	}
	s.audit(ctx, core.AuditEvent{
		ID:   "audit_grant_confirmed_" + input.ID,
		Kind: "remediation.grant.confirmed", ActorID: input.UserID, ObjectID: stored.ID,
		Outcome: string(stored.Rung),
		Detail: stored.Action.ActionID + " for " + class.AlertGroupKey +
			" on verified=" + strconv.Itoa(verified) + " until " + stored.ExpiresAt.Format(time.RFC3339),
	})
	return s.finishSlashInput(ctx, input, slackui.GrantConfirmedNotice(stored, verified))
}

// authorizeGrantAction is stricter in intent than the memory equivalent even
// though it runs the same two checks: this click decides what Responder is
// allowed to DO, not what it is allowed to remember.
func (s *Service) authorizeGrantAction(
	ctx context.Context,
	input core.SlackInput,
) (bool, error) {
	if !s.cfg.IsOperator(input.UserID) {
		return false, s.finishSlashInput(
			ctx, input,
			"*A configured Responder operator must grant remediation authority.*",
		)
	}
	allowed, err := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
	if err != nil {
		return false, err
	}
	if !allowed {
		return false, s.finishSlashInput(
			ctx, input,
			"*Active full workspace membership is required to grant remediation authority.*",
		)
	}
	return true, nil
}

// approvalEpisodeID resolves the episode an Emisar approval belongs to through
// the watch run its source input started, the same route the continuation
// attempt takes. Empty when the origin is gone: a notice with no episode is
// still delivered, and the binding ratchet counts it, which is the point.
func (s *Service) approvalEpisodeID(ctx context.Context, approval core.EmisarApproval) string {
	if approval.SourceInput == "" {
		return ""
	}
	origin, err := s.store.GetAgentRunBySource(ctx, "watch", approval.SourceInput)
	if err != nil {
		return ""
	}
	return origin.EpisodeID
}
