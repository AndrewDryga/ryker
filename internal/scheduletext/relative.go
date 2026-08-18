// Package scheduletext reads the unambiguous relative-day vocabulary used by
// schedule-batch requests and formats those offsets for corrections.
package scheduletext

import (
	"context"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

var numberWords = map[string]int{
	"a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
	"seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
}

var relativeDayPattern = regexp.MustCompile(
	`(?i)\b(tomorrow)\b|\bin\s+(an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|\d+)\s+(days?|weeks?)\b`,
)

var (
	sameTimePattern               = regexp.MustCompile(`(?i)\bsame\s+time\b`)
	terseRelativeSelectionPattern = regexp.MustCompile(
		`(?i)^\s*(?:tomorrow|in\s+(?:an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|\d+)\s+(?:days?|weeks?))[.!?]?\s*$`,
	)
)

// RequestedDayOffsets reads explicit relative days in order, without repeats.
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

// SameTimeRequested and TerseRelativeSelection recognize operator-authored
// scheduling grammar. They are deliberately not used on model prose: the
// model supplies typed occurrences, while the host reads only the request it
// is required to enforce.
func SameTimeRequested(text string) bool { return sameTimePattern.MatchString(text) }

func TerseRelativeSelection(text string) bool {
	return terseRelativeSelectionPattern.MatchString(text)
}

type recentSlackInputReader interface {
	ListRecentWatchMessages(context.Context, string, int) ([]core.SlackInput, error)
}

// PriorSameTimeRequest finds the nearest same-operator request in the same
// Slack conversation. The service owns storage; this package owns the exact
// temporal grammar and which message timestamp it binds to.
func PriorSameTimeRequest(
	ctx context.Context,
	reader recentSlackInputReader,
	input core.SlackInput,
	limit int,
) (time.Time, bool, error) {
	if reader == nil {
		return time.Time{}, false, nil
	}
	recent, err := reader.ListRecentWatchMessages(ctx, input.ChannelID, limit)
	if err != nil {
		return time.Time{}, false, err
	}
	for index := len(recent) - 1; index >= 0; index-- {
		candidate := recent[index]
		if candidate.ID == input.ID || candidate.UserID != input.UserID ||
			!candidate.ReceivedAt.Before(input.ReceivedAt) ||
			!sameConversation(candidate, input) || !SameTimeRequested(candidate.Text) {
			continue
		}
		return candidate.ReceivedAt, true, nil
	}
	return time.Time{}, false, nil
}

func sameConversation(first, second core.SlackInput) bool {
	if first.ChannelID != second.ChannelID {
		return false
	}
	if second.ThreadTS == "" {
		return first.ThreadTS == ""
	}
	return first.ThreadTS == second.ThreadTS || first.MessageTS == second.ThreadTS
}

// Occurrence is the host-normalized part of one typed one-time schedule that
// can be compared with an operator's relative-day request.
type Occurrence struct {
	At       time.Time
	Timezone string
}

// ValidateRelativeOccurrences makes the operator's requested count, calendar
// days, timezone and local clock authoritative over model-authored RFC3339
// values. sameTimeAt is present only when the operator explicitly asked to
// retain the clock from that message.
func ValidateRelativeOccurrences(
	text string,
	requestedAt time.Time,
	sameTimeAt *time.Time,
	occurrences []Occurrence,
) error {
	wanted := RequestedDayOffsets(text)
	if len(wanted) == 0 {
		return nil
	}
	proposed := map[int]bool{}
	zone, clock := "", ""
	for _, occurrence := range occurrences {
		location, err := time.LoadLocation(occurrence.Timezone)
		if err != nil {
			return nil // The typed-offer validator reports malformed zones.
		}
		local := occurrence.At.In(location)
		asked := requestedAt.In(location)
		proposed[localDateOrdinal(local)-localDateOrdinal(asked)] = true
		localClock := local.Format("15:04")
		if zone == "" {
			zone, clock = occurrence.Timezone, localClock
		} else if occurrence.Timezone != zone || localClock != clock {
			return fmt.Errorf(
				"the requested occurrences use inconsistent local times or timezones; " +
					"return every occurrence at one consistent local time and timezone",
			)
		}
		if sameTimeAt != nil {
			expected := sameTimeAt.In(location)
			if local.Hour() != expected.Hour() || local.Minute() != expected.Minute() ||
				local.Second() != 0 || local.Nanosecond() != 0 {
				return fmt.Errorf(
					"the operator requested the same local time, %02d:%02d %s; "+
						"return the occurrence at that minute",
					expected.Hour(), expected.Minute(), occurrence.Timezone,
				)
			}
		}
	}
	if len(occurrences) == len(wanted) && len(proposed) == len(wanted) {
		matched := true
		for _, day := range wanted {
			matched = matched && proposed[day]
		}
		if matched {
			return nil
		}
	}
	return fmt.Errorf(
		"the request named %d check(s), at %s from its message time, and the batch "+
			"proposes %d at %s; return exactly the occurrences that were asked for",
		len(wanted), DayList(wanted), len(occurrences), SortedDaySetList(proposed),
	)
}

func localDateOrdinal(value time.Time) int {
	year, month, day := value.Date()
	return int(time.Date(year, month, day, 0, 0, 0, 0, time.UTC).Unix() / int64(24*time.Hour/time.Second))
}

func DayList(days []int) string {
	parts := make([]string, 0, len(days))
	for _, day := range days {
		parts = append(parts, strconv.Itoa(day)+"d")
	}
	if len(parts) == 0 {
		return "none"
	}
	return strings.Join(parts, ", ")
}

func SortedDaySetList(days map[int]bool) string {
	ordered := make([]int, 0, len(days))
	for day := range days {
		ordered = append(ordered, day)
	}
	sort.Ints(ordered)
	return DayList(ordered)
}
