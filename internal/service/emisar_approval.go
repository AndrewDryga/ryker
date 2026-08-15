package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/changeledger"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/emisar"
	"github.com/AndrewDryga/responder/internal/remediation"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/store/approvalstore"
)

func (s *Service) seedEmisarApprovalWork(ctx context.Context) error {
	items, err := s.store.Approvals.ListMonitorable(ctx, 1000)
	if err != nil {
		return err
	}
	for _, item := range items {
		if err := s.store.EnsureWork(ctx, emisarApprovalWorkItem(item, s.now())); err != nil {
			return err
		}
	}
	return nil
}

func emisarApprovalWorkItem(item core.EmisarApproval, now time.Time) store.WorkItem {
	availableAt := item.NextCheckAt
	if availableAt.IsZero() {
		availableAt = now.UTC()
	}
	return store.WorkItem{
		Kind: workEmisarApproval, SubjectID: item.RequestID,
		Lane: store.WorkLaneBackground, Priority: 70,
		AvailableAt: availableAt,
	}
}

func (s *Service) bindAndScheduleEmisarApproval(
	ctx context.Context,
	approval *core.EmisarApproval,
	deliveryID string,
) error {
	if approval == nil {
		return nil
	}
	bound, err := s.store.Approvals.BindDelivery(
		ctx,
		approval.RequestID,
		deliveryID,
	)
	if err != nil {
		return err
	}
	*approval = bound
	return s.store.EnqueueWork(ctx, emisarApprovalWorkItem(bound, s.now()))
}

func (s *Service) processEmisarApproval(
	ctx context.Context,
	requestID string,
) error {
	approval, err := s.store.Approvals.Get(ctx, requestID)
	if err != nil {
		return err
	}
	if approval.ContinuationQueued {
		return nil
	}
	now := s.now().UTC()
	if approval.NextCheckAt.After(now) {
		return s.store.EnqueueWork(ctx, emisarApprovalWorkItem(approval, s.now()))
	}
	if s.emisar == nil {
		return errors.New("Emisar approval monitor is unavailable")
	}
	if approvalstore.RunTerminal(approval.Status) {
		return s.finishTerminalEmisarApproval(ctx, approval)
	}
	state, err := s.emisar.WaitForRun(ctx, approval.RunID)
	if err != nil {
		next := s.queueDelay(approval.FailureCount + 1)
		if retryErr := s.store.Approvals.Retry(
			ctx,
			approval.RequestID,
			trimError(err),
			next,
		); retryErr != nil {
			return retryErr
		}
		approval.NextCheckAt = next
		if enqueueErr := s.store.EnqueueWork(
			ctx,
			emisarApprovalWorkItem(approval, s.now()),
		); enqueueErr != nil {
			return enqueueErr
		}
		s.log.Warn(
			"Emisar approval status check deferred",
			"request", approval.RequestID,
			"run", approval.RunID,
			"error", err,
		)
		return nil
	}
	if err := validateEmisarApprovalRun(approval, state); err != nil {
		return err
	}
	next := now.Add(s.cfg.Coop.ApprovalPoll.Duration)
	updated, changed, err := s.store.Approvals.Advance(
		ctx,
		approval.RequestID,
		state.Status,
		state.RunURL,
		s.cleanStructuredField(state.ErrorMessage, 1000),
		next,
	)
	if err != nil {
		return err
	}
	if !approvalstore.RunTerminal(updated.Status) {
		if changed && updated.MessageTS != "" {
			if err := s.enqueueEmisarApprovalCardUpdate(
				ctx,
				updated,
				false,
			); err != nil {
				return err
			}
		}
		return s.store.EnqueueWork(ctx, emisarApprovalWorkItem(updated, s.now()))
	}
	return s.finishTerminalEmisarApproval(ctx, updated)
}

// emisarApprovalCardGrace bounds how long a completed Emisar run waits for its
// own card to exist before finishing without one.
//
// It used to wait forever. The card's message_ts is written when the Slack
// delivery lands, so an approval whose card was superseded, coalesced away, or
// failed permanently re-queued itself once a second for the life of the
// process, never completed, never queued its verification turn, and said
// nothing anywhere — the operator who pressed approve simply never heard back.
// Two minutes is far longer than a Slack post takes and far shorter than an
// operator's patience.
const emisarApprovalCardGrace = 2 * time.Minute

func (s *Service) finishTerminalEmisarApproval(
	ctx context.Context,
	updated core.EmisarApproval,
) error {
	if updated.MessageTS == "" {
		if s.now().UTC().Before(emisarApprovalCardDeadline(updated)) {
			updated.NextCheckAt = s.now().UTC().Add(time.Second)
			return s.store.EnqueueWork(ctx, emisarApprovalWorkItem(updated, s.now()))
		}
		// The card is presentation and the continuation is the work. Say so
		// once, loudly, and finish: a governed mutation that reached a terminal
		// status must be verified whether or not its card survived.
		s.log.Warn(
			"Emisar approval completed with no card to update",
			"request", updated.RequestID,
			"run", updated.RunID,
			"status", updated.Status,
		)
	}
	if err := s.store.ResolveWaitingApprovalEpisodes(
		ctx,
		updated.IncidentID,
		updated.SourceInput,
		updated.Status,
	); err != nil {
		return err
	}
	if _, _, err := s.queueEmisarApprovalContinuation(ctx, updated); err != nil {
		return err
	}
	if updated.MessageTS != "" {
		if err := s.enqueueEmisarApprovalCardUpdate(ctx, updated, true); err != nil {
			return err
		}
	}
	if err := s.store.Approvals.MarkContinuationQueued(
		ctx,
		updated.RequestID,
	); err != nil {
		return err
	}
	// A mutation Responder itself supervised to terminal success is a change,
	// and the ledger is the only place that fact survives the approval row.
	// Logged rather than returned on failure: the ledger is an addition to work
	// that has already happened, so losing a row must not strand a completed
	// run before its continuation is queued.
	repository, _ := s.effectiveRepository(ctx, updated.ChannelID, "", s.cfg.Slack.DefaultRepository)
	if change, ok := changeledger.FromEmisarApproval(updated, repository, s.now().UTC()); ok {
		if _, err := s.store.Changes.Record(ctx, change); err != nil && ctx.Err() == nil {
			s.log.Warn("record Emisar change event", "run", updated.RunID, "error", err)
		}
	}
	s.audit(ctx, core.AuditEvent{
		IncidentID: updated.IncidentID,
		Kind:       "emisar.approval.completed",
		ActorID:    "responder",
		ObjectID:   updated.RequestID,
		Outcome:    updated.Status,
		Detail:     updated.ActionID + " run=" + updated.RunID,
	})
	// The trust ladder moves on the same terminal fact, in both directions. A
	// run that did not work takes a rung back immediately and asks nobody; a run
	// that did may have earned the next one, and that only ever becomes an offer
	// for a person to confirm.
	s.demoteGrantsForRun(ctx, updated)
	if updated.Status == "success" {
		action := remediation.ActionRef{
			ActionID: updated.ActionID, PackRef: updated.PackRef, RunnerRef: updated.RunnerRef,
		}
		if err := s.offerGrantPromotion(
			ctx, updated.IncidentID, s.approvalEpisodeID(ctx, updated), updated.ChannelID,
			"grant_offer_"+updated.RequestID, action, "", 0, "",
		); err != nil && ctx.Err() == nil {
			s.log.Warn("offer remediation grant promotion", "run", updated.RunID, "error", err)
		}
	}
	return nil
}

func validateEmisarApprovalRun(
	approval core.EmisarApproval,
	state emisar.RunState,
) error {
	if approval.RunID != state.RunID || approval.OperationID != state.OperationID ||
		approval.ActionID != state.ActionID || approval.PackRef != state.PackRef ||
		approval.RunnerRef != state.RunnerRef {
		return fmt.Errorf(
			"Emisar run %q no longer matches approval %q immutable identity",
			state.RunID,
			approval.RequestID,
		)
	}
	if !approvalstore.ValidRunStatus(state.Status) {
		return fmt.Errorf("Emisar run returned unsupported status %q", state.Status)
	}
	return nil
}

func (s *Service) enqueueEmisarApprovalCardUpdate(
	ctx context.Context,
	approval core.EmisarApproval,
	continuing bool,
) error {
	if approval.ChannelID == "" || approval.MessageTS == "" {
		return errors.New("Emisar approval Slack target is unavailable")
	}
	message := slackui.EmisarApprovalStateMessage(approval, continuing)
	message = s.sanitizeMessage(message)
	body, err := slackui.Encode(message)
	if err != nil {
		return err
	}
	_, err = s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID:          "emisar_approval_state_" + approval.RequestID + "_" + approval.Status,
		IncidentID:  approval.IncidentID,
		Operation:   "update",
		Kind:        "emisar_approval",
		ChannelID:   approval.ChannelID,
		MessageTS:   approval.MessageTS,
		Body:        body,
		CoalesceKey: "emisar_approval:" + approval.RequestID,
	})
	return err
}

func (s *Service) queueEmisarApprovalContinuation(
	ctx context.Context,
	approval core.EmisarApproval,
) (core.AgentRun, bool, error) {
	prompt := emisarApprovalContinuationPrompt(approval)
	sourceKind := "emisar_approval:" + approval.RequestID
	if approval.IncidentID != "" {
		incident, err := s.store.GetIncident(ctx, approval.IncidentID)
		if err != nil {
			return core.AgentRun{}, false, err
		}
		return s.queueIncidentAgentRun(
			ctx,
			incident,
			sourceKind,
			approval.SourceInput,
			approval.RequestedBy,
			prompt,
		)
	}
	target, err := s.approvalContinuationTarget(ctx, approval)
	if err != nil {
		return core.AgentRun{}, false, err
	}
	repository, err := s.effectiveRepository(
		ctx,
		target.ChannelID,
		approval.RequestedBy,
		s.cfg.Slack.DefaultRepository,
	)
	if err != nil {
		return core.AgentRun{}, false, err
	}
	state := decisionpkg.WatchTurnState{
		Lane:                 "investigation",
		Repository:           repository,
		ResponseThreadTS:     target.ThreadTS,
		RouteCaptured:        true,
		RulesCaptured:        true,
		ConversationFollowup: true,
		ApprovalContinuation: true,
		DecisionSourceID:     approval.RequestID,
		ReplyDeliveryID:      "emisar_approval_reply_" + approval.RequestID,
	}
	contextJSON, err := json.Marshal(state)
	if err != nil {
		return core.AgentRun{}, false, err
	}
	run := core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: target.ChannelID,
		ThreadTS: target.ThreadTS, ConversationKey: target.ConversationKey,
		SourceKind: sourceKind, SourceID: approval.SourceInput, UserID: approval.RequestedBy,
		Repository: repository, Prompt: prompt, Context: contextJSON,
		CommitmentTitle: "Verify " + approval.ActionID + " after Emisar completed it",
		Episode:         approvalContinuationEpisode(approval.ActionID),
	}
	if target.EpisodeID != "" {
		return s.store.QueueEpisodeAttempt(ctx, target.EpisodeID, run)
	}
	return s.store.QueueAgentRun(ctx, run)
}

// approvalTarget is where an approval's verification turn belongs when no
// incident room answers that question.
type approvalTarget struct {
	ChannelID       string
	ThreadTS        string
	ConversationKey string
	EpisodeID       string
}

// approvalContinuationTarget resolves that destination from the episode first
// and the transport rows second.
//
// The order is the whole point. slack_inputs, slack_deliveries and agent_runs
// all expire on the OPERATIONAL horizon; work_episodes lives on the
// episode-history one, and its bound destination is revisioned and validated.
// The previous shape loaded the Slack input and the card delivery and returned
// their ErrNotFound to the work queue, so an Emisar run that took longer than
// the operational horizon — which is precisely the run an approval exists for —
// reached its terminal status and then died looking for the message it meant to
// reply under. Permanently, and without telling the operator who approved it.
//
// Every lookup below the episode is consulted, never required.
func (s *Service) approvalContinuationTarget(
	ctx context.Context,
	approval core.EmisarApproval,
) (approvalTarget, error) {
	target := approvalTarget{EpisodeID: approval.EpisodeID, ChannelID: approval.ChannelID}
	// The origin run carries the conversation key this thread serializes on,
	// which an alert-correlated episode does not spell as "channel:<id>".
	origin, err := s.store.GetAgentRunBySource(ctx, "watch", approval.SourceInput)
	switch {
	case err == nil:
		target.ConversationKey = origin.ConversationKey
		if target.EpisodeID == "" {
			target.EpisodeID = origin.EpisodeID
		}
	case !errors.Is(err, store.ErrNotFound):
		return approvalTarget{}, err
	}
	if target.EpisodeID != "" {
		episode, episodeErr := s.store.GetWorkEpisode(ctx, target.EpisodeID)
		switch {
		case episodeErr == nil:
			target.ChannelID = core.FirstNonempty(episode.Destination.ChannelID, target.ChannelID)
			target.ThreadTS = episode.Destination.ThreadTS
		case !errors.Is(episodeErr, store.ErrNotFound):
			return approvalTarget{}, episodeErr
		}
	}
	if target.ThreadTS == "" {
		delivery, deliveryErr := s.store.GetSlackDelivery(ctx, approval.DeliveryID)
		switch {
		case deliveryErr == nil:
			target.ThreadTS = delivery.ThreadTS
		case !errors.Is(deliveryErr, store.ErrNotFound):
			return approvalTarget{}, deliveryErr
		}
	}
	if target.ChannelID == "" {
		return approvalTarget{}, fmt.Errorf(
			"Emisar approval %q has no conversation left to answer in",
			approval.RequestID,
		)
	}
	if target.ConversationKey == "" {
		target.ConversationKey = "channel:" + target.ChannelID
	}
	return target, nil
}

// emisarApprovalCardDeadline is measured from when Emisar went terminal, not
// from now, so the grace period cannot be renewed by re-polling.
func emisarApprovalCardDeadline(approval core.EmisarApproval) time.Time {
	terminal := approval.TerminalAt
	if terminal.IsZero() {
		terminal = approval.UpdatedAt
	}
	return terminal.Add(emisarApprovalCardGrace)
}

func emisarApprovalContinuationPrompt(approval core.EmisarApproval) string {
	return fmt.Sprintf(`Emisar run %q for action %q is now terminal with status %q.
Continue the exact existing run; do not call run_action, repeat the mutation, or create a new run.
Use wait_for_run on exactly this run ID to inspect its authoritative terminal result. Then use only
relevant read-only tools to verify the intended effect when verification is possible. Report the
outcome concisely in plain professional Slack language. Clearly distinguish Emisar's terminal run
status from any independently verified live effect, and name any remaining evidence gap.`,
		approval.RunID,
		approval.ActionID,
		approval.Status,
	)
}
