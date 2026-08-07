package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	memorypkg "github.com/AndrewDryga/responder/internal/memory"
	schedulepkg "github.com/AndrewDryga/responder/internal/schedule"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

const scheduleOfferMaxAge = 24 * time.Hour

type scheduleActionPayload struct {
	Version    int    `json:"version"`
	ProposalID string `json:"proposal_id"`
}

type scheduleTogglePayload struct {
	ID      string `json:"id"`
	Enabled bool   `json:"enabled"`
}

func (s *Service) prepareScheduleOfferAction(
	ctx context.Context,
	input core.SlackInput,
	offer *core.ScheduleOffer,
) (string, core.ScheduledTask, string, bool) {
	if s.store == nil {
		return "", core.ScheduledTask{}, "", false
	}
	replacementID, err := s.inheritScheduleOfferFromConversation(ctx, input, offer)
	if err != nil {
		if s.log != nil {
			s.log.Warn("inherit schedule continuation", "source_input", input.ID, "error", err)
		}
		return "", core.ScheduledTask{}, "", false
	}
	normalizeInput := input
	if replacementID != "" &&
		schedulepkg.ExplicitScheduleConfirmation(s.stripBotMention(input.Text)) &&
		!schedulepkg.ExplicitScheduleRequest(input.Text) {
		// The existing schedule supplies the durable intent and stable fields.
		// Treat the operator's short confirmation as the scheduling request so
		// the model does not have to repeat the original sentence verbatim.
		normalizeInput.Text = "schedule this"
	}
	task, when, ok := s.normalizeScheduleOffer(ctx, normalizeInput, offer)
	if !ok {
		return "", core.ScheduledTask{}, "", false
	}
	if replacementID == "" {
		replacementID, err = s.scheduleReplacementCandidate(ctx, task)
		if err != nil {
			if s.log != nil {
				s.log.Warn("find schedule replacement", "source_input", input.ID, "error", err)
			}
			return "", core.ScheduledTask{}, "", false
		}
	}
	proposal, err := s.store.ScheduleProposals.Create(ctx, core.ScheduleProposal{
		TeamID: s.cfg.Slack.TeamID, ChannelID: input.ChannelID,
		ThreadTS: conversationalResponseThread(input), ActorID: input.UserID,
		SourceRef: core.FirstNonempty(input.EventID, input.ID), Task: task,
		ReplaceTaskID: replacementID, ExpiresAt: s.now().UTC().Add(scheduleOfferMaxAge),
	})
	if err != nil {
		if s.log != nil {
			s.log.Warn("store schedule proposal", "source_input", input.ID, "error", err)
		}
		return "", core.ScheduledTask{}, "", false
	}
	payload, err := json.Marshal(scheduleActionPayload{Version: 2, ProposalID: proposal.ID})
	if err != nil || len(payload) > 1900 {
		return "", core.ScheduledTask{}, "", false
	}
	return string(payload), task, when, true
}

// scheduleActivationNeedsOffer identifies the one case where a conversational
// completion is not enough: an operator explicitly activated the single live
// schedule anchored to this thread. The model still chooses the updated typed
// task, but the host refuses a prose claim that it was activated without the
// operation that can actually update the schedule.
func (s *Service) scheduleActivationNeedsOffer(
	ctx context.Context,
	input core.SlackInput,
	offer *core.ScheduleOffer,
) (bool, error) {
	if offer != nil || s.store == nil || input.ThreadTS == "" ||
		!s.cfg.IsOperator(input.UserID) ||
		!schedulepkg.ExplicitScheduleConfirmation(s.stripBotMention(input.Text)) {
		return false, nil
	}
	tasks, err := s.store.ListScheduledTasksForChannel(ctx, input.ChannelID, 100)
	if err != nil {
		return false, err
	}
	matches := 0
	for _, task := range tasks {
		if task.Enabled && task.TeamID == s.cfg.Slack.TeamID && task.ThreadTS == input.ThreadTS {
			matches++
		}
	}
	return matches == 1, nil
}

func scheduleActivationOfferCorrection() string {
	return "The operator explicitly activated the existing schedule in this conversation. " +
		"Do not merely say it was activated. Return one typed schedule_offer containing the intended updated task; " +
		"Responder will inherit unchanged title, destination, timezone, and cadence from the existing schedule and update it atomically."
}

// inheritScheduleOfferFromConversation makes short confirmations such as
// "activate it" reliable without asking the model to repeat stable schedule
// metadata. The source thread is the authority: only one enabled compatible
// schedule may be inherited, so a new or ambiguous request still has to stand
// on its own.
func (s *Service) inheritScheduleOfferFromConversation(
	ctx context.Context,
	input core.SlackInput,
	offer *core.ScheduleOffer,
) (string, error) {
	if offer == nil || input.ThreadTS == "" {
		return "", nil
	}
	tasks, err := s.store.ListScheduledTasksForChannel(ctx, input.ChannelID, 100)
	if err != nil {
		return "", err
	}
	matches := make([]core.ScheduledTask, 0, 1)
	for _, existing := range tasks {
		if !existing.Enabled || existing.TeamID != s.cfg.Slack.TeamID || existing.ThreadTS != input.ThreadTS ||
			!scheduleOfferCompatibleWithTask(*offer, existing) {
			continue
		}
		matches = append(matches, existing)
	}
	if len(matches) != 1 {
		return "", nil
	}
	existing := matches[0]
	if strings.TrimSpace(offer.Title) == "" {
		offer.Title = existing.Title
	}
	if strings.TrimSpace(offer.Prompt) == "" {
		offer.Prompt = existing.Prompt
	}
	if strings.TrimSpace(offer.Repository) == "" {
		offer.Repository = existing.Repository
	}
	if strings.TrimSpace(offer.DeliveryChannel) == "" {
		offer.DeliveryChannel = existing.DeliveryChannel
	}
	if strings.TrimSpace(offer.Recurrence) == "" {
		offer.Recurrence = existing.Recurrence
	}
	if offer.IntervalSeconds == 0 {
		offer.IntervalSeconds = existing.IntervalSeconds
	}
	if len(offer.Weekdays) == 0 {
		offer.Weekdays = append([]string(nil), existing.Weekdays...)
	}
	if offer.DayOfMonth == 0 {
		offer.DayOfMonth = existing.DayOfMonth
	}
	if strings.TrimSpace(offer.LocalTime) == "" {
		offer.LocalTime = existing.LocalTime
	}
	if strings.TrimSpace(offer.Timezone) == "" {
		offer.Timezone = existing.Timezone
	}
	if strings.TrimSpace(offer.CatchUp) == "" {
		offer.CatchUp = existing.CatchUp
	}
	return existing.ID, nil
}

func scheduleOfferCompatibleWithTask(offer core.ScheduleOffer, task core.ScheduledTask) bool {
	if value := strings.ToLower(strings.TrimSpace(offer.Repository)); value != "" && value != task.Repository {
		return false
	}
	if value := strings.TrimSpace(offer.DeliveryChannel); value != "" && value != firstNonemptyScheduleChannel(task) {
		return false
	}
	if value := strings.ToLower(strings.TrimSpace(offer.Recurrence)); value != "" && value != task.Recurrence {
		return false
	}
	if offer.IntervalSeconds != 0 && offer.IntervalSeconds != task.IntervalSeconds {
		return false
	}
	if offer.DayOfMonth != 0 && offer.DayOfMonth != task.DayOfMonth {
		return false
	}
	if value := strings.TrimSpace(offer.LocalTime); value != "" && value != task.LocalTime {
		return false
	}
	if value := strings.TrimSpace(offer.Timezone); value != "" && value != task.Timezone {
		return false
	}
	if value := strings.ToLower(strings.TrimSpace(offer.CatchUp)); value != "" && value != task.CatchUp {
		return false
	}
	if len(offer.Weekdays) != 0 {
		weekdays := append([]string(nil), offer.Weekdays...)
		for index := range weekdays {
			weekdays[index] = strings.ToLower(strings.TrimSpace(weekdays[index]))
		}
		sort.Strings(weekdays)
		if !equalScheduleWeekdays(weekdays, task.Weekdays) {
			return false
		}
	}
	return true
}

func (s *Service) normalizeScheduleOffer(
	ctx context.Context,
	input core.SlackInput,
	offer *core.ScheduleOffer,
) (core.ScheduledTask, string, bool) {
	if offer == nil || !s.scheduleOfferInScope(input) {
		return core.ScheduledTask{}, "", false
	}
	expiresIn := strings.ToLower(strings.TrimSpace(offer.ExpiresIn))
	if expiresIn == "" {
		expiresIn = memorypkg.MemoryTTLValue(memorypkg.DefaultTTL)
	}
	task, err := s.scheduledTaskFromOffer(ctx, input, *offer, s.now().UTC())
	if err != nil {
		if s.log != nil {
			s.log.Warn("discard invalid schedule offer", "source_input", input.ID, "error", err)
		}
		return core.ScheduledTask{}, "", false
	}
	offer.Title = task.Title
	offer.Prompt = task.Prompt
	offer.Repository = task.Repository
	offer.DeliveryChannel = task.DeliveryChannel
	offer.Recurrence = task.Recurrence
	offer.StartAt = task.StartAt.Format(time.RFC3339)
	offer.IntervalSeconds = task.IntervalSeconds
	offer.Weekdays = append([]string(nil), task.Weekdays...)
	offer.DayOfMonth = task.DayOfMonth
	offer.LocalTime = task.LocalTime
	offer.Timezone = task.Timezone
	offer.CatchUp = task.CatchUp
	offer.ExpiresIn = expiresIn
	return task, schedulepkg.ScheduleDescription(task), true
}

func (s *Service) scheduleReplacementCandidate(ctx context.Context, proposed core.ScheduledTask) (string, error) {
	tasks, err := s.store.ListScheduledTasksForChannel(ctx, proposed.ChannelID, 100)
	if err != nil {
		return "", err
	}
	matches := make([]string, 0, 1)
	for _, existing := range tasks {
		if !existing.Enabled || existing.TeamID != proposed.TeamID ||
			firstNonemptyScheduleChannel(existing) != firstNonemptyScheduleChannel(proposed) ||
			existing.Repository != proposed.Repository || existing.Recurrence != proposed.Recurrence ||
			existing.IntervalSeconds != proposed.IntervalSeconds || existing.DayOfMonth != proposed.DayOfMonth ||
			existing.LocalTime != proposed.LocalTime || existing.Timezone != proposed.Timezone ||
			!equalScheduleWeekdays(existing.Weekdays, proposed.Weekdays) {
			continue
		}
		matches = append(matches, existing.ID)
	}
	if len(matches) == 1 {
		return matches[0], nil
	}
	return "", nil
}

func firstNonemptyScheduleChannel(task core.ScheduledTask) string {
	return core.FirstNonempty(task.DeliveryChannel, task.ChannelID)
}

func equalScheduleWeekdays(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func (s *Service) scheduledTaskFromOffer(
	ctx context.Context,
	input core.SlackInput,
	offer core.ScheduleOffer,
	now time.Time,
) (core.ScheduledTask, error) {
	offer.Title = strings.TrimSpace(offer.Title)
	offer.Prompt = strings.TrimSpace(offer.Prompt)
	offer.Repository = strings.ToLower(strings.TrimSpace(offer.Repository))
	offer.DeliveryChannel = strings.TrimSpace(offer.DeliveryChannel)
	offer.Recurrence = strings.ToLower(strings.TrimSpace(offer.Recurrence))
	offer.Timezone = strings.TrimSpace(offer.Timezone)
	offer.LocalTime = strings.TrimSpace(offer.LocalTime)
	offer.CatchUp = strings.ToLower(strings.TrimSpace(offer.CatchUp))
	if offer.CatchUp == "" {
		offer.CatchUp = "latest"
	}
	if offer.Timezone == "" {
		if provider, ok := s.slack.(interface {
			UserTimezone(context.Context, string) (string, error)
		}); ok {
			zone, err := provider.UserTimezone(ctx, input.UserID)
			if err != nil {
				return core.ScheduledTask{}, fmt.Errorf("read the operator's Slack timezone: %w", err)
			}
			if strings.TrimSpace(zone) == "" {
				return core.ScheduledTask{}, errors.New("schedule needs an explicit timezone because the operator's Slack profile has none")
			}
			offer.Timezone = zone
		} else {
			offer.Timezone = "UTC"
		}
	}
	if _, ok := s.cfg.RepositoryContext(offer.Repository); !ok {
		return core.ScheduledTask{}, fmt.Errorf("repository %q is not configured", offer.Repository)
	}
	if offer.DeliveryChannel == "" {
		offer.DeliveryChannel = input.ChannelID
	}
	if offer.DeliveryChannel != input.ChannelID {
		channel, channelErr := s.slack.GetChannel(ctx, offer.DeliveryChannel)
		if channelErr != nil {
			return core.ScheduledTask{}, fmt.Errorf("read scheduled delivery channel: %w", channelErr)
		}
		if channel.ID != offer.DeliveryChannel || channel.Archived || !channel.Member {
			return core.ScheduledTask{}, errors.New("Emisar must be an active member of the scheduled delivery channel")
		}
	}
	if memorypkg.ContainsSecretLikeValue(offer.Prompt) {
		return core.ScheduledTask{}, errors.New("scheduled task cannot contain a credential-like value")
	}
	ttl, err := memorypkg.ParseMemoryTTL(offer.ExpiresIn)
	if err != nil {
		return core.ScheduledTask{}, err
	}
	task := core.ScheduledTask{
		TeamID: s.cfg.Slack.TeamID, ChannelID: input.ChannelID,
		ThreadTS:        conversationalResponseThread(input),
		DeliveryChannel: offer.DeliveryChannel, Repository: offer.Repository,
		Title: offer.Title, Prompt: offer.Prompt, Recurrence: offer.Recurrence,
		IntervalSeconds: offer.IntervalSeconds,
		DayOfMonth:      offer.DayOfMonth, LocalTime: offer.LocalTime,
		Timezone: offer.Timezone, CatchUp: offer.CatchUp,
		ActorID: input.UserID, SourceRef: core.FirstNonempty(input.EventID, input.ID),
		ExpiresAt: now.Add(ttl), Enabled: true,
	}
	seen := map[string]bool{}
	for _, day := range offer.Weekdays {
		day = strings.ToLower(strings.TrimSpace(day))
		if _, ok := schedulepkg.WeekdayNumber(day); !ok || seen[day] {
			return core.ScheduledTask{}, fmt.Errorf("invalid or duplicate weekday %q", day)
		}
		seen[day] = true
		task.Weekdays = append(task.Weekdays, day)
	}
	sort.Strings(task.Weekdays)
	if task.Recurrence == "daily" || task.Recurrence == "weekly" || task.Recurrence == "monthly" {
		if _, _, err := schedulepkg.ParseLocalClock(task.LocalTime); err != nil {
			return core.ScheduledTask{}, err
		}
	}
	if _, err := time.LoadLocation(task.Timezone); err != nil {
		return core.ScheduledTask{}, fmt.Errorf("schedule timezone %q is invalid", task.Timezone)
	}
	if err := schedulepkg.ValidateScheduleShape(task); err != nil {
		return core.ScheduledTask{}, err
	}
	startAt, err := schedulepkg.ParseScheduleStart(task, strings.TrimSpace(offer.StartAt), now)
	if err != nil {
		return core.ScheduledTask{}, err
	}
	task.StartAt = startAt
	task.NextRunAt = startAt
	if !task.NextRunAt.Before(task.ExpiresAt) {
		return core.ScheduledTask{}, errors.New("schedule expires before its first occurrence")
	}
	return task, nil
}

func (s *Service) handleRememberSchedule(ctx context.Context, input core.SlackInput) error {
	allowed, err := s.authorizeMemoryAction(ctx, input)
	if err != nil || !allowed {
		return err
	}
	var payload scheduleActionPayload
	if err := decisionpkg.DecodeStrictJSON([]byte(input.ActionValue), &payload); err != nil || payload.Version != 2 || payload.ProposalID == "" {
		return s.behaviorActionFeedback(ctx, input, "*This schedule confirmation is invalid or stale.* Nothing was saved. Ask Emisar to schedule it again and use the new button.")
	}
	if len(input.Frozen) != 0 {
		var task core.ScheduledTask
		if err := json.Unmarshal(input.Frozen, &task); err == nil {
			return s.postBehaviorReceipt(ctx, input, slackui.ScheduleSavedMessage(task))
		}
	}
	task, err := s.acceptScheduleProposal(ctx, input, payload.ProposalID)
	if errors.Is(err, store.ErrConflict) {
		// Acceptance is an atomic pending -> accepted transition, so a second
		// route to the same proposal — the button after a conversational
		// confirmation, or the other way round — loses the race by design. It
		// did not fail: the schedule exists. Saying so beats surfacing a
		// database error for something that worked.
		return s.behaviorActionFeedback(
			ctx, input, "This schedule is already saved — nothing more to do.",
		)
	}
	if err != nil {
		return s.behaviorActionFeedback(ctx, input, "*Emisar could not save this schedule.* "+err.Error())
	}
	frozen, _ := json.Marshal(task)
	if err := s.store.SetSlackInputFrozen(ctx, input.ID, frozen); err != nil {
		return err
	}
	s.audit(ctx, core.AuditEvent{Kind: "schedule.created", ActorID: input.UserID, ObjectID: task.ID, Outcome: "enabled", Detail: task.Title})
	return s.postBehaviorReceipt(ctx, input, slackui.ScheduleSavedMessage(task))
}

func (s *Service) acceptScheduleProposal(ctx context.Context, input core.SlackInput, proposalID string) (core.ScheduledTask, error) {
	allowed, err := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
	if err != nil {
		return core.ScheduledTask{}, err
	}
	if !s.cfg.IsOperator(input.UserID) || !allowed {
		return core.ScheduledTask{}, errors.New("only a configured operator can activate this schedule")
	}
	return s.store.ScheduleProposals.Accept(
		ctx, proposalID, core.FirstNonempty(input.TeamID, s.cfg.Slack.TeamID), input.ChannelID, input.UserID,
		s.cfg.Limits.MaxScheduledTasks, s.cfg.Limits.MaxSchedulesPerChannel,
	)
}

func (s *Service) handleToggleSchedule(ctx context.Context, input core.SlackInput) error {
	allowed, err := s.authorizeMemoryAction(ctx, input)
	if err != nil || !allowed {
		return err
	}
	var payload scheduleTogglePayload
	if err := decisionpkg.DecodeStrictJSON([]byte(input.ActionValue), &payload); err != nil || payload.ID == "" {
		return s.behaviorActionFeedback(ctx, input, "*This schedule control is invalid.* Nothing changed.")
	}
	if _, err := s.authorizedScheduledTask(ctx, input, payload.ID); err != nil {
		return s.behaviorActionFeedback(ctx, input, "*This schedule control does not belong to this channel.* Nothing changed.")
	}
	task, err := s.store.SetScheduledTaskEnabled(ctx, payload.ID, payload.Enabled)
	if err != nil {
		return err
	}
	return s.finishBehaviorMessage(ctx, input, slackui.ScheduleStateMessage(task))
}

func (s *Service) handleDeleteSchedule(ctx context.Context, input core.SlackInput) error {
	allowed, err := s.authorizeMemoryAction(ctx, input)
	if err != nil || !allowed {
		return err
	}
	id := strings.TrimSpace(input.ActionValue)
	if _, err := s.authorizedScheduledTask(ctx, input, id); err != nil {
		return s.behaviorActionFeedback(ctx, input, "*This schedule control does not belong to this channel.* Nothing changed.")
	}
	if _, err := s.store.DeleteScheduledTask(ctx, id); err != nil {
		return err
	}
	return s.finishBehaviorMessage(ctx, input, slackui.ScheduleDeletedMessage())
}

func (s *Service) handleEditSchedule(ctx context.Context, input core.SlackInput) error {
	allowed, err := s.authorizeMemoryAction(ctx, input)
	if err != nil || !allowed {
		return err
	}
	task, err := s.authorizedScheduledTask(ctx, input, strings.TrimSpace(input.ActionValue))
	if err != nil {
		return err
	}
	return s.finishSlashInput(ctx, input, fmt.Sprintf("*Tell me the replacement for %q.*\n\nMention Emisar with the complete task and timing. I’ll confirm the new schedule before saving it; the current one stays active until you delete it.", task.Title))
}

func (s *Service) handleRunScheduleNow(ctx context.Context, input core.SlackInput) error {
	allowed, err := s.authorizeMemoryAction(ctx, input)
	if err != nil || !allowed {
		return err
	}
	task, err := s.authorizedScheduledTask(ctx, input, strings.TrimSpace(input.ActionValue))
	if err != nil {
		return err
	}
	now := s.now().UTC()
	sourceID := schedulepkg.ScheduledSourceInputID(task.ID, now)
	run, execute, err := s.store.ClaimScheduledTaskRun(ctx, task, now, time.Time{}, sourceID, false, true, "")
	if err != nil {
		return err
	}
	if !execute {
		return s.finishSlashInput(ctx, input, "That task is already running. I won’t start an overlapping copy.")
	}
	if err := s.ensureScheduledTaskExecution(ctx, task, run); err != nil {
		return err
	}
	return s.finishSlashInput(ctx, input, "Started *"+task.Title+"* now. I’ll post the result in its configured conversation.")
}

func (s *Service) authorizedScheduledTask(
	ctx context.Context,
	input core.SlackInput,
	id string,
) (core.ScheduledTask, error) {
	task, err := s.store.GetScheduledTask(ctx, id)
	if err != nil {
		return core.ScheduledTask{}, err
	}
	if task.TeamID != input.TeamID || task.ChannelID != input.ChannelID {
		return core.ScheduledTask{}, errors.New("scheduled task belongs to another Slack channel")
	}
	return task, nil
}

func (s *Service) processScheduledTasks(ctx context.Context) error {
	now := s.now().UTC()
	if err := s.reconcileScheduledTaskRuns(ctx); err != nil {
		return err
	}
	tasks, err := s.store.ListDueScheduledTasks(ctx, now, 50)
	if err != nil {
		return err
	}
	if len(tasks) == 0 {
		return store.ErrNotFound
	}
	for _, task := range tasks {
		scheduledFor := task.NextRunAt
		next := schedulepkg.NextScheduledOccurrence(task, now)
		operatorAllowed := s.cfg.IsOperator(task.ActorID)
		if operatorAllowed {
			operatorAllowed, err = s.slack.UserAllowed(ctx, task.ActorID, task.TeamID)
			if err != nil {
				return err
			}
		}
		if !operatorAllowed {
			sourceID := schedulepkg.ScheduledSourceInputID(task.ID, scheduledFor)
			if _, _, err := s.store.ClaimScheduledTaskRun(
				ctx, task, scheduledFor, time.Time{}, sourceID, true, false, "skipped_unauthorized",
			); err != nil {
				return err
			}
			s.audit(ctx, core.AuditEvent{
				Kind: "schedule.disabled", ActorID: task.ActorID, ObjectID: task.ID,
				Outcome: "operator_no_longer_authorized", Detail: task.Title,
			})
			continue
		}
		execute := task.CatchUp == "latest" || now.Sub(scheduledFor) <= s.cfg.Limits.ScheduleMisfireGrace.Duration
		sourceID := schedulepkg.ScheduledSourceInputID(task.ID, scheduledFor)
		run, claimed, err := s.store.ClaimScheduledTaskRun(ctx, task, scheduledFor, next, sourceID, true, execute, "skipped_missed")
		if err != nil {
			return err
		}
		if claimed {
			if err := s.ensureScheduledTaskExecution(ctx, task, run); err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *Service) ensureScheduledTaskExecution(ctx context.Context, task core.ScheduledTask, occurrence core.ScheduledTaskRun) error {
	input, err := s.store.GetSlackInput(ctx, occurrence.SourceInput)
	if errors.Is(err, store.ErrNotFound) {
		deliveryChannel := core.FirstNonempty(task.DeliveryChannel, task.ChannelID)
		deliveryThread := task.ThreadTS
		if deliveryChannel != task.ChannelID {
			deliveryThread = ""
		}
		if deliveryThread == "" && s.cfg.Slack.NativeStatus {
			deliveryThread, err = s.ensureScheduledRunAnchor(
				ctx, task, occurrence, deliveryChannel,
			)
			if err != nil {
				return err
			}
		}
		deliveryRepository, repositoryErr := s.effectiveRepository(
			ctx,
			deliveryChannel,
			task.ActorID,
			s.cfg.Slack.DefaultRepository,
		)
		if repositoryErr != nil {
			return repositoryErr
		}
		if err := s.store.Intelligence.EnsureChannelMemory(
			ctx, deliveryChannel, deliveryRepository,
		); err != nil {
			return err
		}
		state := decisionpkg.WatchTurnState{
			Lane: "investigation", Repository: task.Repository,
			RepositoryPinned: true,
			SessionChannelID: "scheduled:" + task.ID,
			ResponseThreadTS: deliveryThread, RouteCaptured: true,
			RulesCaptured: true, ConversationFollowup: true,
		}
		frozen, marshalErr := json.Marshal(state)
		if marshalErr != nil {
			return marshalErr
		}
		input = core.SlackInput{
			ID: occurrence.SourceInput, EnvelopeID: occurrence.SourceInput,
			EventID: occurrence.SourceInput, Kind: "scheduled", TeamID: task.TeamID,
			ChannelID: deliveryChannel, ThreadTS: deliveryThread, UserID: task.ActorID,
			Text: task.Prompt, Frozen: frozen, ReceivedAt: occurrence.ScheduledFor,
		}
		admitted, admitErr := s.store.AdmitSyntheticSlackInput(ctx, input)
		if admitErr != nil {
			return admitErr
		}
		if admitted {
			if err := s.store.SetSlackInputFrozen(ctx, input.ID, frozen); err != nil {
				return err
			}
		}
	} else if err != nil {
		return err
	}
	if _, err := s.store.GetAgentRunBySource(ctx, "watch", input.ID); errors.Is(err, store.ErrNotFound) {
		if err := s.queueWatchedInput(ctx, input); err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	agentRun, err := s.store.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		return err
	}
	return s.store.LinkScheduledTaskRun(
		ctx, task.ID, occurrence.ScheduledFor, agentRun.ID, agentRun.EpisodeID,
	)
}

func (s *Service) ensureScheduledRunAnchor(
	ctx context.Context,
	task core.ScheduledTask,
	occurrence core.ScheduledTaskRun,
	channelID string,
) (string, error) {
	deliveryID := "scheduled_run_anchor_" + occurrence.SourceInput
	delivery, err := s.store.GetSlackDelivery(ctx, deliveryID)
	switch {
	case err == nil && delivery.State == "sent" && delivery.MessageTS != "":
		return delivery.MessageTS, nil
	case err == nil && delivery.State == "failed":
		return "", fmt.Errorf("post scheduled run anchor: %s", delivery.LastError)
	case err == nil:
		// The durable Slack outbox owns uncertain delivery recovery. Let its
		// worker finish before binding native status and the scheduled input.
		return "", store.ErrNotFound
	case !errors.Is(err, store.ErrNotFound):
		return "", err
	}
	body, err := slackui.Encode(s.sanitizer.Message(
		slackui.ScheduledRunStartedMessage(task, occurrence.ScheduledFor),
	))
	if err != nil {
		return "", err
	}
	if _, err := s.store.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: deliveryID, Kind: "scheduled_anchor", ChannelID: channelID, Body: body,
	}); err != nil {
		return "", err
	}
	return "", store.ErrNotFound
}

func (s *Service) reconcileScheduledTaskRuns(ctx context.Context) error {
	runs, err := s.store.ListActiveScheduledTaskRuns(ctx, 100)
	if err != nil {
		return err
	}
	for _, occurrence := range runs {
		task, taskErr := s.store.GetScheduledTask(ctx, occurrence.TaskID)
		if errors.Is(taskErr, store.ErrNotFound) {
			continue
		}
		if taskErr != nil {
			return taskErr
		}
		if occurrence.AgentRunID == "" {
			if err := s.ensureScheduledTaskExecution(ctx, task, occurrence); err != nil {
				return err
			}
			continue
		}
		run, runErr := s.store.GetAgentRun(ctx, occurrence.AgentRunID)
		if runErr != nil {
			return runErr
		}
		if run.State != core.AgentRunCompleted && run.State != core.AgentRunFailed && run.State != core.AgentRunCancelled && run.State != core.AgentRunSuperseded {
			continue
		}
		outcome := "completed"
		detail := run.LastError
		if run.TerminalState != "completed" || run.State != core.AgentRunCompleted {
			outcome = "failed"
		}
		if err := s.store.CompleteScheduledTaskRun(ctx, task.ID, occurrence.ScheduledFor, outcome, detail); err != nil {
			return err
		}
	}
	return nil
}
