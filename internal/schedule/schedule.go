// Package schedule owns when recurring work should next happen, and whether a
// requested schedule is one Responder can honour.
//
// Recurrence is arithmetic over a wall clock in someone's timezone, which is
// the kind of thing that looks obvious and is not: a daily 09:00 job across a
// DST boundary, a weekly job whose weekday has already passed this week, a
// misfire window that must not fire a job twice. Keeping it here means those
// rules are testable without a store, a Slack client, or a running service.
package schedule

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/decision"
)

var ScheduleIntentPattern = regexp.MustCompile(
	`(?i)\b(?:remind|schedule)\b|` +
		`\b(?:every|each)\s+(?:morning|afternoon|evening|night|day|weekday|week|month|` +
		`monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b|` +
		`\b(?:every|each)\s+(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|\d+)\s+` +
		`(?:minutes?|hours?|days?|weeks?)\b|\bonce\s+(?:a|per)\s+(?:day|week|month)\b|` +
		`\b(?:daily|weekly|monthly|hourly)\b|` +
		`\bin\s+(?:an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|\d+)\s+` +
		`(?:minutes?|hours?|days?|weeks?)\b|\b(?:tomorrow|tonight)\b`,
)

var ScheduleContinuationPattern = regexp.MustCompile(
	`(?i)^\s*(?:(?:<@[^>]+>)\s*)?(?:please\s+)?(?:` +
		`try\s+again|retry|do\s+(?:it|that|this|them|both)|go\s+ahead|proceed|yes(?:\s+please)?` +
		`)(?:\s+(?:<@[^>]+>))?[.!?]?\s*$`,
)

func ScheduleInputWithConversationIntent(
	input core.SlackInput,
	recent []decision.WatchContextMessage,
) core.SlackInput {
	if ExplicitScheduleRequest(input.Text) ||
		!ScheduleContinuationPattern.MatchString(input.Text) {
		return input
	}
	for index := len(recent) - 1; index >= 0; index-- {
		message := recent[index]
		if message.SenderType != "human" || message.SenderID != input.UserID ||
			!ExplicitScheduleRequest(message.Text) {
			continue
		}
		if input.ThreadTS != "" && message.ThreadTS != input.ThreadTS &&
			message.MessageTS != input.ThreadTS {
			continue
		}
		input.Text = message.Text
		return input
	}
	return input
}

func ParseScheduleStart(task core.ScheduledTask, value string, now time.Time) (time.Time, error) {
	var start time.Time
	if value != "" {
		parsed, err := time.Parse(time.RFC3339, value)
		if err != nil {
			return time.Time{}, errors.New("schedule start_at must use RFC3339")
		}
		start = parsed.UTC()
	}
	switch task.Recurrence {
	case "once":
		if start.IsZero() {
			return time.Time{}, errors.New("one-time schedule requires an exact RFC3339 start_at")
		}
		if start.Before(now.Add(-5 * time.Minute)) {
			return time.Time{}, errors.New("schedule start_at is already in the past")
		}
		if start.Before(now) {
			return now.UTC(), nil
		}
		return start, nil
	case "interval":
		if start.IsZero() {
			return now.Add(time.Duration(task.IntervalSeconds) * time.Second).UTC(), nil
		}
		if start.Before(now) {
			task.StartAt = start
			return NextScheduledOccurrence(task, now), nil
		}
		return start, nil
	case "daily", "weekly", "monthly":
		after := now
		if start.After(now) {
			after = start.Add(-time.Nanosecond)
		}
		next := NextScheduledOccurrence(task, after)
		if next.IsZero() {
			return time.Time{}, errors.New("calendar schedule has no valid future occurrence")
		}
		return next, nil
	default:
		return time.Time{}, errors.New("schedule recurrence is invalid")
	}
}

func ValidateScheduleShape(task core.ScheduledTask) error {
	// The store repeats these invariants; this gives operator-facing errors before insertion.
	switch task.Recurrence {
	case "once":
	case "interval":
		if task.IntervalSeconds < 300 || task.IntervalSeconds > int64((365*24*time.Hour)/time.Second) {
			return errors.New("interval must be between 5 minutes and 365 days")
		}
	case "daily":
	case "weekly":
		if len(task.Weekdays) == 0 {
			return errors.New("weekly schedule requires at least one weekday")
		}
	case "monthly":
		if task.DayOfMonth < 1 || task.DayOfMonth > 31 {
			return errors.New("monthly schedule requires day_of_month from 1 to 31")
		}
	default:
		return errors.New("recurrence must be once, interval, daily, weekly, or monthly")
	}
	if task.Title == "" || task.Prompt == "" {
		return errors.New("schedule requires a title and a self-contained task prompt")
	}
	return nil
}

func ExplicitScheduleRequest(text string) bool {
	return ScheduleIntentPattern.MatchString(strings.TrimSpace(text))
}

func ScheduleDescription(task core.ScheduledTask) string {
	when := task.NextRunAt.In(MustLocation(task.Timezone)).Format("Mon, 02 Jan 2006 15:04 MST")
	switch task.Recurrence {
	case "interval":
		return "Every " + (time.Duration(task.IntervalSeconds) * time.Second).String() + ", starting " + when
	case "daily":
		return "Every day at " + task.LocalTime + " " + task.Timezone + ", starting " + when
	case "weekly":
		return "Every " + strings.Join(task.Weekdays, ", ") + " at " + task.LocalTime + " " + task.Timezone + ", starting " + when
	case "monthly":
		return "Day " + strconv.Itoa(task.DayOfMonth) + " of each month at " + task.LocalTime + " " + task.Timezone + ", starting " + when
	default:
		return "Once at " + when
	}
}

func MustLocation(name string) *time.Location {
	location, err := time.LoadLocation(name)
	if err != nil {
		return time.UTC
	}
	return location
}

func ParseLocalClock(value string) (int, int, error) {
	parsed, err := time.Parse("15:04", value)
	if err != nil {
		return 0, 0, errors.New("calendar schedule local_time must use HH:MM")
	}
	return parsed.Hour(), parsed.Minute(), nil
}

func WeekdayNumber(value string) (time.Weekday, bool) {
	for day := time.Sunday; day <= time.Saturday; day++ {
		if strings.ToLower(day.String()) == value {
			return day, true
		}
	}
	return 0, false
}

// NextScheduledOccurrence returns the first occurrence strictly after after.

// NextScheduledOccurrence returns the first occurrence strictly after after.
func NextScheduledOccurrence(task core.ScheduledTask, after time.Time) time.Time {
	switch task.Recurrence {
	case "once":
		return time.Time{}
	case "interval":
		step := time.Duration(task.IntervalSeconds) * time.Second
		if step <= 0 {
			return time.Time{}
		}
		next := task.StartAt
		if !next.After(after) {
			elapsed := after.Sub(next)
			next = next.Add((elapsed/step + 1) * step)
		}
		return next.UTC()
	}
	location := MustLocation(task.Timezone)
	hour, minute, err := ParseLocalClock(task.LocalTime)
	if err != nil {
		return time.Time{}
	}
	localAfter := after.In(location)
	for offset := 0; offset <= 370; offset++ {
		date := localAfter.AddDate(0, 0, offset)
		candidate := time.Date(date.Year(), date.Month(), date.Day(), hour, minute, 0, 0, location)
		// A nonexistent wall time during the spring DST transition must be skipped,
		// not silently shifted to a different local clock time.
		if candidate.Year() != date.Year() || candidate.Month() != date.Month() ||
			candidate.Day() != date.Day() || candidate.Hour() != hour || candidate.Minute() != minute {
			continue
		}
		if !candidate.After(localAfter) {
			continue
		}
		match := task.Recurrence == "daily"
		if task.Recurrence == "weekly" {
			for _, value := range task.Weekdays {
				day, ok := WeekdayNumber(value)
				if ok && candidate.Weekday() == day {
					match = true
					break
				}
			}
		}
		if task.Recurrence == "monthly" {
			match = candidate.Day() == task.DayOfMonth
		}
		if match {
			return candidate.UTC()
		}
	}
	return time.Time{}
}

func ScheduledSourceInputID(taskID string, scheduledFor time.Time) string {
	return fmt.Sprintf("schedule_%s_%d", taskID, scheduledFor.UTC().UnixNano())
}
