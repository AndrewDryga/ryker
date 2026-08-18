package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	memorypkg "github.com/AndrewDryga/responder/internal/memory"
	"github.com/AndrewDryga/responder/internal/offerreason"
	schedulepkg "github.com/AndrewDryga/responder/internal/schedule"
	scheduleofferpkg "github.com/AndrewDryga/responder/internal/scheduleoffer"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/store/schedulestore"
)

const scheduleOfferMaxAge = 24 * time.Hour

type scheduleActionPayload = scheduleofferpkg.ActionPayload

// OrderedScheduleOffers merges the primary schedule offer with any additional
// ones into the single order the runtime presents them in.
func OrderedScheduleOffers(primary *core.ScheduleOffer, additional []*core.ScheduleOffer) []*core.ScheduleOffer {
	return schedulepkg.Offers(primary, additional)
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
	actionValue, tasks, whens, ok := s.prepareScheduleOffersAction(ctx, input, []*core.ScheduleOffer{offer})
	if !ok || len(tasks) != 1 || len(whens) != 1 {
		return "", core.ScheduledTask{}, "", false
	}
	return actionValue, tasks[0], whens[0], true
}

func (s *Service) prepareScheduleOffersAction(
	ctx context.Context,
	input core.SlackInput,
	offers []*core.ScheduleOffer,
) (string, []core.ScheduledTask, []string, bool) {
	if s.store == nil {
		return "", nil, nil, false
	}
	if len(offers) == 0 || len(offers) > decisionpkg.MaxScheduleOffers {
		return "", nil, nil, false
	}
	if err := s.scheduleBatchMatchesRequest(ctx, input, offers, s.now().UTC()); err != nil {
		s.recordDiscardedOffer(input, "scheduled task batch", err)
		return "", nil, nil, false
	}
	tasks := make([]core.ScheduledTask, 0, len(offers))
	whens := make([]string, 0, len(offers))
	proposals := make([]core.ScheduleProposal, 0, len(offers))
	replacements := make(map[string]struct{}, len(offers))
	baseSource := core.FirstNonempty(input.EventID, input.ID)
	for index, offer := range offers {
		replacementID, err := s.inheritScheduleOfferFromConversation(ctx, input, offer)
		if err != nil {
			if s.log != nil {
				s.log.Warn("inherit schedule continuation", "source_input", input.ID, "error", err)
			}
			return "", nil, nil, false
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
			return "", nil, nil, false
		}
		if replacementID == "" {
			replacementID, err = s.scheduleReplacementCandidate(ctx, task)
			if err != nil {
				if s.log != nil {
					s.log.Warn("find schedule replacement", "source_input", input.ID, "error", err)
				}
				return "", nil, nil, false
			}
		}
		if replacementID != "" {
			if _, duplicate := replacements[replacementID]; duplicate {
				return "", nil, nil, false
			}
			replacements[replacementID] = struct{}{}
		}
		sourceRef := baseSource
		if len(offers) > 1 {
			sourceRef = fmt.Sprintf("%s:schedule:%d", baseSource, index+1)
		}
		// Each task in a confirmed batch needs its own durable identity. The
		// proposal already uses this indexed source reference; carry it into the
		// task so the atomic insert cannot collide on the channel/source key.
		task.SourceRef = sourceRef
		proposals = append(proposals, core.ScheduleProposal{
			TeamID: s.cfg.Slack.TeamID, ChannelID: input.ChannelID,
			ThreadTS: conversationalResponseThread(input), ActorID: input.UserID,
			SourceRef: sourceRef, Task: task, ReplaceTaskID: replacementID,
			ExpiresAt: s.now().UTC().Add(scheduleOfferMaxAge),
		})
		tasks = append(tasks, task)
		whens = append(whens, when)
	}
	stored, err := s.store.Schedules.CreateMany(ctx, proposals)
	if err != nil {
		if s.log != nil {
			s.log.Warn("store schedule proposal batch", "source_input", input.ID, "count", len(proposals), "error", err)
		}
		return "", nil, nil, false
	}
	proposalIDs := make([]string, 0, len(stored))
	for _, proposal := range stored {
		proposalIDs = append(proposalIDs, proposal.ID)
	}
	payload, err := scheduleofferpkg.EncodeAction(proposalIDs)
	if err != nil {
		return "", nil, nil, false
	}
	return payload, tasks, whens, true
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
	tasks, err := s.store.Schedules.ListScheduledTasksForChannel(ctx, input.ChannelID, 100)
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
	tasks, err := s.store.Schedules.ListScheduledTasksForChannel(ctx, input.ChannelID, 100)
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
	if value := strings.TrimSpace(offer.DeliveryChannel); value != "" && value != core.FirstNonempty(task.DeliveryChannel, task.ChannelID) {
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
		if !slices.Equal(weekdays, task.Weekdays) {
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
		s.recordDiscardedOffer(input, "schedule", err)
		return core.ScheduledTask{}, "", false
	}
	scheduleofferpkg.ApplyTaskToOffer(offer, task, expiresIn)
	return task, schedulepkg.ScheduleDescription(task), true
}

func (s *Service) scheduleReplacementCandidate(ctx context.Context, proposed core.ScheduledTask) (string, error) {
	tasks, err := s.store.Schedules.ListScheduledTasksForChannel(ctx, proposed.ChannelID, 100)
	if err != nil {
		return "", err
	}
	matches := make([]string, 0, 1)
	for _, existing := range tasks {
		if !existing.Enabled || existing.TeamID != proposed.TeamID || !scheduleofferpkg.SameDefinition(existing, proposed) {
			continue
		}
		matches = append(matches, existing.ID)
	}
	if len(matches) == 1 {
		return matches[0], nil
	}
	return "", nil
}

func (s *Service) scheduledTaskFromOffer(
	ctx context.Context,
	input core.SlackInput,
	offer core.ScheduleOffer,
	now time.Time,
) (core.ScheduledTask, error) {
	offer.Timezone = strings.TrimSpace(offer.Timezone)
	offer.Repository = strings.ToLower(strings.TrimSpace(offer.Repository))
	offer.DeliveryChannel = strings.TrimSpace(offer.DeliveryChannel)
	if offer.Timezone == "" {
		if provider, ok := unpacedSlack(s.slack).(interface {
			UserTimezone(context.Context, string) (string, error)
		}); ok {
			zone, err := provider.UserTimezone(ctx, input.UserID)
			if err != nil {
				return core.ScheduledTask{}, fmt.Errorf("read the operator's Slack timezone: %w", err)
			}
			if strings.TrimSpace(zone) == "" {
				return core.ScheduledTask{}, offerreason.Field(
					"timezone", "",
					"the operator's Slack profile has no timezone, so name an IANA zone such as America/Chicago",
				)
			}
			offer.Timezone = zone
		} else {
			offer.Timezone = "UTC"
		}
	}
	if _, ok := s.cfg.RepositoryContext(offer.Repository); !ok {
		return core.ScheduledTask{}, s.unknownRepository(offer.Repository)
	}
	offer.DeliveryChannel = core.FirstNonempty(offer.DeliveryChannel, input.ChannelID)
	if offer.DeliveryChannel != input.ChannelID {
		channel, channelErr := s.slack.GetChannel(ctx, offer.DeliveryChannel)
		if channelErr != nil {
			return core.ScheduledTask{}, fmt.Errorf("read scheduled delivery channel: %w", channelErr)
		}
		if channel.ID != offer.DeliveryChannel || channel.Archived || !channel.Member {
			return core.ScheduledTask{}, offerreason.Field(
				"delivery_channel", offer.DeliveryChannel,
				"Emisar is not an active member of that channel; deliver to "+
					input.ChannelID+" or have Emisar invited there first",
			)
		}
	}
	return scheduleofferpkg.TaskFromOffer(offer, scheduleofferpkg.TaskContext{
		TeamID: s.cfg.Slack.TeamID, ChannelID: input.ChannelID,
		ThreadTS: conversationalResponseThread(input), ActorID: input.UserID,
		SourceRef: core.FirstNonempty(input.EventID, input.ID), Now: now,
	})
}

func (s *Service) handleRememberSchedule(ctx context.Context, input core.SlackInput) error {
	allowed, err := s.authorizeMemoryAction(ctx, input)
	if err != nil || !allowed {
		return err
	}
	proposalIDs, version, decodeErr := scheduleofferpkg.DecodeAction(input.ActionValue)
	if decodeErr != nil {
		return s.behaviorActionFeedback(ctx, input, offerreason.Stale(
			offerreason.ScheduleConfirmation, offerreason.Unreadable,
		))
	}
	if len(input.Frozen) != 0 {
		var tasks []core.ScheduledTask
		if err := json.Unmarshal(input.Frozen, &tasks); err == nil && len(tasks) > 0 {
			return s.postBehaviorReceipt(ctx, input, slackui.SchedulesSavedMessage(tasks), true)
		}
		if version == 2 {
			var task core.ScheduledTask
			if err := json.Unmarshal(input.Frozen, &task); err == nil {
				return s.postBehaviorReceipt(ctx, input, slackui.ScheduleSavedMessage(task), true)
			}
		}
	}
	tasks, err := s.acceptScheduleProposals(ctx, input, proposalIDs)
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
	if scheduleProposalGone(err) {
		// The proposal row is the button's subject, and when it is missing,
		// lapsed, or already spent, the operator was shown a raw store error —
		// "schedule proposal not found" reached Slack verbatim. It is the same
		// stale button every other confirmation has, and it says so now.
		return s.behaviorActionFeedback(ctx, input, offerreason.Stale(
			offerreason.ScheduleConfirmation, offerreason.Gone,
		))
	}
	if err != nil {
		return s.behaviorActionFeedback(ctx, input, "*Emisar could not save these schedules.* "+err.Error())
	}
	frozen, _ := json.Marshal(tasks)
	if err := s.store.SetSlackInputFrozen(ctx, input.ID, frozen); err != nil {
		return err
	}
	for _, task := range tasks {
		s.audit(ctx, core.AuditEvent{Kind: "schedule.created", ActorID: input.UserID, ObjectID: task.ID, Outcome: "enabled", Detail: task.Title})
	}
	return s.postBehaviorReceipt(ctx, input, slackui.SchedulesSavedMessage(tasks), true)
}

// scheduleProposalGone reports whether an acceptance failed because the button
// no longer has anything to accept, rather than because the save itself broke.
// The store answers both in prose, so the two sentences it uses are matched
// here beside the not-found row they accompany.
func scheduleProposalGone(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, store.ErrNotFound) || errors.Is(err, schedulestore.ErrNotFound) {
		return true
	}
	reason := err.Error()
	return strings.Contains(reason, "no longer pending") ||
		strings.Contains(reason, "belongs to another conversation")
}

func (s *Service) acceptScheduleProposal(ctx context.Context, input core.SlackInput, proposalID string) (core.ScheduledTask, error) {
	tasks, err := s.acceptScheduleProposals(ctx, input, []string{proposalID})
	if err != nil {
		return core.ScheduledTask{}, err
	}
	return tasks[0], nil
}

func (s *Service) acceptScheduleProposals(ctx context.Context, input core.SlackInput, proposalIDs []string) ([]core.ScheduledTask, error) {
	allowed, err := s.slack.UserAllowed(ctx, input.UserID, s.cfg.Slack.TeamID)
	if err != nil {
		return nil, err
	}
	if !s.cfg.IsOperator(input.UserID) || !allowed {
		return nil, errors.New("only a configured operator can activate these schedules")
	}
	return s.store.Schedules.AcceptMany(
		ctx, proposalIDs, core.FirstNonempty(input.TeamID, s.cfg.Slack.TeamID), input.ChannelID, input.UserID,
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
		return s.behaviorActionFeedback(ctx, input, offerreason.Stale(
			offerreason.ScheduleSwitch, offerreason.Unreadable,
		))
	}
	if _, err := s.authorizedScheduledTask(ctx, input, payload.ID); err != nil {
		return s.behaviorActionFeedback(ctx, input, "*This schedule control does not belong to this channel.* Nothing changed.")
	}
	task, err := s.store.Schedules.SetScheduledTaskEnabled(ctx, payload.ID, payload.Enabled)
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
	if _, err := s.store.Schedules.DeleteScheduledTask(ctx, id); err != nil {
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
	run, execute, err := s.store.Schedules.ClaimScheduledTaskRun(ctx, task, now, time.Time{}, sourceID, false, true, "")
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
	task, err := s.store.Schedules.GetScheduledTask(ctx, id)
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
	tasks, err := s.store.Schedules.ListDueScheduledTasks(ctx, now, 50)
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
			if _, _, err := s.store.Schedules.ClaimScheduledTaskRun(
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
		run, claimed, err := s.store.Schedules.ClaimScheduledTaskRun(ctx, task, scheduledFor, next, sourceID, true, execute, "skipped_missed")
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
		state := scheduledTaskTurnState(task, occurrence, deliveryThread)
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
		_, admitErr := s.store.AdmitSyntheticSlackInput(ctx, input)
		if admitErr != nil {
			return admitErr
		}
	} else if err != nil {
		return err
	}
	// Synthetic inputs used to become runnable before their frozen context was
	// stored. Repair any row left by that ordering before the queue can observe
	// it, and fail closed rather than silently falling back to channel state.
	if len(input.Frozen) == 0 {
		frozen, marshalErr := json.Marshal(scheduledTaskTurnState(
			task, occurrence, input.ThreadTS,
		))
		if marshalErr != nil {
			return marshalErr
		}
		input.Frozen, err = s.store.FreezeSlackInput(ctx, input.ID, frozen)
		if err != nil {
			return fmt.Errorf("freeze scheduled task input: %w", err)
		}
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
	return s.store.Schedules.LinkScheduledTaskRun(
		ctx, task.ID, occurrence.ScheduledFor, agentRun.ID, agentRun.EpisodeID,
	)
}

func scheduledTaskTurnState(
	task core.ScheduledTask,
	occurrence core.ScheduledTaskRun,
	deliveryThread string,
) decisionpkg.WatchTurnState {
	return decisionpkg.WatchTurnState{
		Lane: "investigation", Repository: task.Repository,
		RepositoryPinned: true,
		// A schedule is durable, but its tool registry is not. Give every
		// occurrence a fresh Coop session so connector changes and credentials
		// are picked up on the next run without operator intervention.
		SessionChannelID: "scheduled:" + occurrence.SourceInput,
		ResponseThreadTS: deliveryThread, RouteCaptured: true,
		RulesCaptured: true, ConversationFollowup: true,
	}
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
	runs, err := s.store.Schedules.ListActiveScheduledTaskRuns(ctx, 100)
	if err != nil {
		return err
	}
	for _, occurrence := range runs {
		task, taskErr := s.store.Schedules.GetScheduledTask(ctx, occurrence.TaskID)
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
		if err := s.store.Schedules.CompleteScheduledTaskRun(ctx, task.ID, occurrence.ScheduledFor, outcome, detail); err != nil {
			return err
		}
	}
	return nil
}
