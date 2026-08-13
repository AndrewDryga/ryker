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

func Offers(primary *core.ScheduleOffer, additional []*core.ScheduleOffer) []*core.ScheduleOffer {
	offers := make([]*core.ScheduleOffer, 0, 1+len(additional))
	if primary != nil {
		offers = append(offers, primary)
	}
	for _, offer := range additional {
		if offer != nil {
			offers = append(offers, offer)
		}
	}
	return offers
}

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
		`try\s+again|retry|do\s+(?:it|that|this|them|both)|go\s+ahead|proceed|yes(?:\s+please)?|` +
		`(?:activate|enable|schedule|save|set\s+up)\s+(?:it|that|this)` +
		`)(?:\s+(?:<@[^>]+>))?[.!?]?\s*$`,
)

var scheduleConfirmationPattern = regexp.MustCompile(
	`(?i)^\s*(?:(?:<@[^>]+>)\s*)?(?:please\s+)?(?:` +
		`activate|enable|schedule|save|confirm|set\s+up` +
		`)\s+(?:it|that|this)(?:\s+(?:<@[^>]+>))?[.!?]?\s*$`,
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

func ExplicitScheduleConfirmation(text string) bool {
	return scheduleConfirmationPattern.MatchString(strings.TrimSpace(text))
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

// numberWords maps the counts an operator writes out to their value, so "in
// three days" and "in 3 days" are read as the same request.
var numberWords = map[string]int{
	"a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
	"seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
}

var relativeDayPattern = regexp.MustCompile(
	`(?i)\b(tomorrow)\b|\bin\s+(an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|\d+)\s+(days?|weeks?)\b`,
)

// RequestedDayOffsets reads the explicit relative days an operator named, in
// the order they named them and without repeats.
//
// It exists because "check tomorrow and in 3 days" came back as three checks at
// one, two and four days out, and every host validation passed: each offer was
// a well-formed future one-time schedule, and the batch size was inside its
// limit. Nothing compared what was proposed with what was asked for, so a
// schedule the operator never requested only had to be syntactically valid to
// be confirmed.
//
// Only unambiguous forms are extracted. A request this cannot read returns
// nothing, which leaves the batch to the checks that were already there —
// guessing at an offset would replace a proposal the operator can see and
// reject with one Responder invented.
func RequestedDayOffsets(text string) []int {
	offsets := []int{}
	seen := map[int]bool{}
	for _, match := range relativeDayPattern.FindAllStringSubmatch(text, 8) {
		days := 0
		switch {
		case match[1] != "":
			days = 1
		case match[2] != "":
			count, ok := numberWords[strings.ToLower(match[2])]
			if !ok {
				parsed, err := strconv.Atoi(match[2])
				if err != nil {
					continue
				}
				count = parsed
			}
			days = count
			if strings.HasPrefix(strings.ToLower(match[3]), "week") {
				days = count * 7
			}
		}
		if days <= 0 || seen[days] {
			continue
		}
		seen[days] = true
		offsets = append(offsets, days)
	}
	return offsets
}
