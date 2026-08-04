package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/investigation"
	"github.com/AndrewDryga/responder/internal/store"
)

const episodeRecheckSeparator = "#"

func (s *Service) scheduleEpisodeRechecks(
	ctx context.Context,
	run core.AgentRun,
	input core.SlackInput,
	state watchTurnState,
	action string,
	completion *completionAssessment,
) error {
	directive := (*investigation.RecheckDirective)(nil)
	nextAttempt := 1
	if state.RecheckOriginRunID == "" {
		if completion != nil {
			directive = completion.Recheck
		}
	} else {
		if action != "ignore" {
			return nil
		}
		origin, err := s.store.GetAgentRun(ctx, state.RecheckOriginRunID)
		if err != nil {
			return err
		}
		decision, err := parseWatchDecision(string(origin.Result))
		if err != nil || decision.Completion == nil {
			return nil
		}
		directive = decision.Completion.Recheck
		nextAttempt = state.RecheckAttempt + 1
	}
	if directive == nil || nextAttempt > directive.AdditionalAttempts {
		return nil
	}
	return s.store.EnqueueWork(ctx, store.WorkItem{
		Kind:            workEpisodeRecheck,
		SubjectID:       episodeRecheckSubject(firstNonempty(state.RecheckOriginRunID, run.ID), nextAttempt),
		Lane:            store.WorkLaneBackground,
		ConversationKey: watchConversationKey(input),
		Priority:        48,
		AvailableAt: time.Now().UTC().Add(
			time.Duration(directive.AfterSeconds) * time.Second,
		),
	})
}

func episodeRecheckSubject(runID string, attempt int) string {
	return runID + episodeRecheckSeparator + strconv.Itoa(attempt)
}

func parseEpisodeRecheckSubject(subject string) (string, int, error) {
	index := strings.LastIndex(subject, episodeRecheckSeparator)
	if index <= 0 || index == len(subject)-1 {
		return "", 0, errors.New("invalid episode recheck subject")
	}
	attempt, err := strconv.Atoi(subject[index+1:])
	if err != nil || attempt < 1 || attempt > 4 {
		return "", 0, errors.New("invalid episode recheck attempt")
	}
	return subject[:index], attempt, nil
}

func episodeRecheckInputID(originRunID string, attempt int) string {
	return "slack_recheck_" + strings.TrimPrefix(originRunID, "run_") + "_" + strconv.Itoa(attempt)
}

func (s *Service) processEpisodeRecheck(ctx context.Context, item store.WorkItem) error {
	originRunID, attempt, err := parseEpisodeRecheckSubject(item.SubjectID)
	if err != nil {
		return err
	}
	originRun, err := s.store.GetAgentRun(ctx, originRunID)
	if err != nil {
		return err
	}
	originInput, err := s.store.GetSlackInput(ctx, originRun.SourceID)
	if err != nil {
		return err
	}
	decision, err := parseWatchDecision(string(originRun.Result))
	if err != nil || decision.Completion == nil || decision.Completion.Recheck == nil {
		return nil
	}
	if attempt > decision.Completion.Recheck.AdditionalAttempts {
		return nil
	}
	for prior := 1; prior < attempt; prior++ {
		priorRun, priorErr := s.store.GetAgentRunBySource(
			ctx, "watch", episodeRecheckInputID(originRunID, prior),
		)
		if errors.Is(priorErr, store.ErrNotFound) {
			return deferScheduledWork(
				time.Now().UTC().Add(time.Duration(decision.Completion.Recheck.AfterSeconds)*time.Second),
				fmt.Sprintf("prior episode recheck %d has not completed", prior),
			)
		}
		if priorErr != nil {
			return priorErr
		}
		if priorRun.State != core.AgentRunCompleted && priorRun.State != core.AgentRunFailed &&
			priorRun.State != core.AgentRunCancelled && priorRun.State != core.AgentRunSuperseded {
			return deferScheduledWork(
				time.Now().UTC().Add(time.Duration(decision.Completion.Recheck.AfterSeconds)*time.Second),
				fmt.Sprintf("prior episode recheck %d is still %s", prior, priorRun.State),
			)
		}
		if priorRun.TerminalState != "completed" {
			continue
		}
		priorDecision, parseErr := parseWatchDecision(string(priorRun.Result))
		if parseErr == nil && priorDecision.Action != "ignore" {
			return nil
		}
	}
	state, err := decodeWatchRunContext(originRun)
	if err != nil {
		return err
	}
	state.RecheckOriginRunID = originRunID
	state.RecheckKey = decision.Completion.Recheck.Key
	state.RecheckAttempt = attempt
	state.TurnID = ""
	state.ExpectedRevision = 0
	state.ContextCaptured = false
	state.PriorCaptured = false
	state.RecentMessages = nil
	state.RelatedSituations = nil
	state.ReferencedThread = nil
	state.PendingStatusSet = false
	state.PendingStatusAt = 0
	state.DecisionSourceID = ""
	state.ReplyDeliveryID = ""
	state.ConversationFollowup = true
	state.RulesCaptured = true
	state.MatchedRules = nil
	frozen, err := json.Marshal(state)
	if err != nil {
		return err
	}
	id := episodeRecheckInputID(originRunID, attempt)
	input := core.SlackInput{
		ID: id, EnvelopeID: "recheck:" + id, EventID: "recheck:" + id,
		Kind: "recheck", TeamID: originInput.TeamID, ChannelID: originInput.ChannelID,
		ThreadTS: originInput.ThreadTS, MessageTS: originInput.MessageTS,
		UserID: originInput.UserID, Text: originInput.Text,
		Attachments: append([]core.SlackAttachment(nil), originInput.Attachments...),
		Frozen:      frozen, ReceivedAt: time.Now().UTC(),
	}
	created, err := s.store.AdmitSyntheticSlackInput(ctx, input)
	if err != nil {
		return err
	}
	if created {
		return s.store.SetSlackInputFrozen(ctx, input.ID, frozen)
	}
	return nil
}
