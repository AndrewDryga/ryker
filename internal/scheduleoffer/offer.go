// Package scheduleoffer validates schedule proposals before they cross the
// Slack confirmation boundary or become durable scheduled tasks.
package scheduleoffer

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/memory"
	"github.com/AndrewDryga/responder/internal/schedule"
)

type ActionPayload struct {
	Version     int      `json:"version"`
	ProposalID  string   `json:"proposal_id,omitempty"`
	ProposalIDs []string `json:"proposal_ids,omitempty"`
}

type TaskContext struct {
	TeamID, ChannelID, ThreadTS, ActorID, SourceRef string
	Now                                             time.Time
}

func EncodeAction(proposalIDs []string) (string, error) {
	proposalIDs, err := validProposalIDs(proposalIDs, 1)
	if err != nil {
		return "", err
	}
	payload := ActionPayload{Version: 3, ProposalIDs: proposalIDs}
	if len(proposalIDs) == 1 {
		payload = ActionPayload{Version: 2, ProposalID: proposalIDs[0]}
	}
	encoded, err := json.Marshal(payload)
	if err != nil || len(encoded) > 1900 {
		return "", errors.New("schedule confirmation payload is too large")
	}
	return string(encoded), nil
}

func DecodeAction(value string) ([]string, int, error) {
	var payload ActionPayload
	if err := decision.DecodeStrictJSON([]byte(value), &payload); err != nil {
		return nil, 0, err
	}
	switch {
	case payload.Version == 2 && payload.ProposalID != "" && len(payload.ProposalIDs) == 0:
		ids, err := validProposalIDs([]string{payload.ProposalID}, 1)
		return ids, payload.Version, err
	case payload.Version == 3 && payload.ProposalID == "" && len(payload.ProposalIDs) >= 2:
		ids, err := validProposalIDs(payload.ProposalIDs, 2)
		return ids, payload.Version, err
	default:
		return nil, 0, errors.New("schedule confirmation payload is invalid")
	}
}

func validProposalIDs(proposalIDs []string, minimum int) ([]string, error) {
	if len(proposalIDs) < minimum || len(proposalIDs) > decision.MaxScheduleOffers {
		return nil, fmt.Errorf("schedule confirmation must contain between %d and %d proposals", minimum, decision.MaxScheduleOffers)
	}
	ids := make([]string, 0, len(proposalIDs))
	seen := make(map[string]struct{}, len(proposalIDs))
	for _, proposalID := range proposalIDs {
		proposalID = strings.TrimSpace(proposalID)
		if proposalID == "" {
			return nil, errors.New("schedule confirmation contains an empty proposal ID")
		}
		if _, exists := seen[proposalID]; exists {
			return nil, errors.New("schedule confirmation contains duplicate proposal IDs")
		}
		seen[proposalID] = struct{}{}
		ids = append(ids, proposalID)
	}
	return ids, nil
}

func TaskFromOffer(offer core.ScheduleOffer, context TaskContext) (core.ScheduledTask, error) {
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
	if offer.DeliveryChannel == "" {
		offer.DeliveryChannel = context.ChannelID
	}
	if memory.ContainsSecretLikeValue(offer.Prompt) {
		return core.ScheduledTask{}, errors.New("scheduled task cannot contain a credential-like value")
	}
	ttl, err := memory.ParseMemoryTTL(offer.ExpiresIn)
	if err != nil {
		return core.ScheduledTask{}, err
	}
	if ttl == memory.PermanentTTL {
		return core.ScheduledTask{}, errors.New("a scheduled task cannot be permanent because it runs unattended; use 7d, 30d, 90d, or 365d")
	}
	task := core.ScheduledTask{
		TeamID: context.TeamID, ChannelID: context.ChannelID, ThreadTS: context.ThreadTS,
		DeliveryChannel: offer.DeliveryChannel, Repository: offer.Repository,
		Title: offer.Title, Prompt: offer.Prompt, Recurrence: offer.Recurrence,
		IntervalSeconds: offer.IntervalSeconds, DayOfMonth: offer.DayOfMonth,
		LocalTime: offer.LocalTime, Timezone: offer.Timezone, CatchUp: offer.CatchUp,
		ActorID: context.ActorID, SourceRef: context.SourceRef,
		ExpiresAt: context.Now.Add(ttl), Enabled: true,
	}
	seen := map[string]bool{}
	for _, day := range offer.Weekdays {
		day = strings.ToLower(strings.TrimSpace(day))
		if _, ok := schedule.WeekdayNumber(day); !ok || seen[day] {
			return core.ScheduledTask{}, fmt.Errorf("invalid or duplicate weekday %q", day)
		}
		seen[day] = true
		task.Weekdays = append(task.Weekdays, day)
	}
	sort.Strings(task.Weekdays)
	if task.Recurrence == "daily" || task.Recurrence == "weekly" || task.Recurrence == "monthly" {
		if _, _, err := schedule.ParseLocalClock(task.LocalTime); err != nil {
			return core.ScheduledTask{}, err
		}
	}
	if _, err := time.LoadLocation(task.Timezone); err != nil {
		return core.ScheduledTask{}, fmt.Errorf("schedule timezone %q is invalid", task.Timezone)
	}
	if err := schedule.ValidateScheduleShape(task); err != nil {
		return core.ScheduledTask{}, err
	}
	startAt, err := schedule.ParseScheduleStart(task, strings.TrimSpace(offer.StartAt), context.Now)
	if err != nil {
		return core.ScheduledTask{}, err
	}
	task.StartAt, task.NextRunAt = startAt, startAt
	if !task.NextRunAt.Before(task.ExpiresAt) {
		return core.ScheduledTask{}, errors.New("schedule expires before its first occurrence")
	}
	return task, nil
}

func ApplyTaskToOffer(offer *core.ScheduleOffer, task core.ScheduledTask, expiresIn string) {
	offer.Title, offer.Prompt, offer.Repository = task.Title, task.Prompt, task.Repository
	offer.DeliveryChannel, offer.Recurrence = task.DeliveryChannel, task.Recurrence
	offer.StartAt, offer.IntervalSeconds = task.StartAt.Format(time.RFC3339), task.IntervalSeconds
	offer.Weekdays, offer.DayOfMonth = append([]string(nil), task.Weekdays...), task.DayOfMonth
	offer.LocalTime, offer.Timezone, offer.CatchUp = task.LocalTime, task.Timezone, task.CatchUp
	offer.ExpiresIn = expiresIn
}

func SameDefinition(left, right core.ScheduledTask) bool {
	if core.FirstNonempty(left.DeliveryChannel, left.ChannelID) != core.FirstNonempty(right.DeliveryChannel, right.ChannelID) ||
		left.Repository != right.Repository || left.Recurrence != right.Recurrence ||
		left.IntervalSeconds != right.IntervalSeconds || left.DayOfMonth != right.DayOfMonth ||
		left.LocalTime != right.LocalTime || left.Timezone != right.Timezone || len(left.Weekdays) != len(right.Weekdays) {
		return false
	}
	for index := range left.Weekdays {
		if left.Weekdays[index] != right.Weekdays[index] {
			return false
		}
	}
	return true
}
