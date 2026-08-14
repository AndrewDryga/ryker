// Package selfreport composes the weekly digest Responder posts about its own
// week.
//
// The instruments already existed and nobody read them on a schedule: the
// correction rate behind a CLI, feedback and graded reactions in a table, the
// quality watcher's findings in another, learned knowledge and open loops in
// structured memory. A teammate who never says how their week went is a
// teammate you stop trusting.
//
// Every number here is counted by SQL and rendered by this file. No model turn
// composes the digest, so the digest cannot hallucinate: the worst it can do is
// count the wrong rows, and a wrong count is a bug with a test rather than a
// plausible sentence nobody can check.
//
// The shape follows the same rules the host enforces on model replies — lead
// with the number that moved, short sentences, an identifier only where the
// reader would act on that exact instance, and never close by handing the
// question back.
package selfreport

import (
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// maxDigestBytes keeps the digest inside one Slack markdown block, which Slack
// truncates at 12,000 characters. A report that arrives cut in half is a report
// nobody reads, and the section most worth keeping — the lead — is the one at
// the top, so the trim happens per item on the way in rather than as a cut at
// the end.
const maxDigestBytes = 11000

const (
	maxStatements    = 3
	maxLoopChannels  = 5
	maxStatementRune = 160
	maxSummaryRune   = 240
)

// Week is everything the digest reports, already counted.
type Week struct {
	// Start and End bound the reported window, half-open. They carry the
	// location they were computed in so the digest names the week an operator
	// would recognise rather than a UTC one they have to shift.
	Start time.Time
	End   time.Time
	// This and Previous are the same instrument over adjacent windows. The
	// digest reports the direction, because a single correction rate says very
	// little and the trend is the whole point.
	This     Corrections
	Previous Corrections
	// TopCorrection is the correction text the host sent back most often, and
	// TopCorrectionCount how many times. One repeated correction names the
	// thing actually going wrong far better than a class total does.
	TopCorrection      string
	TopCorrectionCount int
	Feedback           Feedback
	Knowledge          Knowledge
	OpenLoops          []ChannelLoops
	// Worst is the week's worst answer, or nil when the quality watcher
	// confirmed nothing. Nil and "none confirmed" are the same news and are
	// reported the same way.
	Worst *Finding
}

// Corrections is the correction instrument over one window: how many turns
// finished, and how many of them the host sent back to the model.
type Corrections struct {
	Turns int
	Total int
}

// Rate is corrections as a share of finished turns.
func (c Corrections) Rate() float64 {
	if c.Turns == 0 {
		return 0
	}
	return float64(c.Total) / float64(c.Turns)
}

// Feedback counts what the team said about the answers, explicitly and by
// reacting. Reactions are called out separately because they are the cheap
// half: a week carried entirely by reactions is a week nobody wrote about.
type Feedback struct {
	Positive  int
	Negative  int
	Reactions int
}

// Knowledge is what the week added to structured memory.
type Knowledge struct {
	Count int
	// Newest holds the freshest accepted statements. Only the first few are
	// rendered; Count carries the rest.
	Newest []string
}

// ChannelLoops is one channel's unfinished business: what its memory still
// lists as open, and how long nothing has touched it.
type ChannelLoops struct {
	ChannelID string
	IdleDays  int
	Loops     []string
}

// Finding is one confirmed quality finding nobody has acted on.
type Finding struct {
	ID        string
	Severity  string
	Summary   string
	ChannelID string
}

// PreviousOccurrence returns the most recent local send at or before now, or
// the zero time when the schedule has none in the last fortnight.
//
// The boundary is what makes the digest post once. The job compares it against
// the recorded send rather than counting elapsed time, so a process that was
// down for a month comes back to one digest rather than to one per missed week,
// and a process restarting every ten seconds inside the window posts none.
//
// Local rather than UTC because "Monday morning" is what an operator means, and
// a UTC hour is an hour off that for half the year. A wall time that does not
// exist — the hour the spring transition skips — is not an occurrence: Go would
// silently shift it into the next hour, which would move the send.
func PreviousOccurrence(
	now time.Time,
	location *time.Location,
	day time.Weekday,
	hour, minute int,
) time.Time {
	local := now.In(location)
	for offset := range 15 {
		date := local.AddDate(0, 0, -offset)
		if date.Weekday() != day {
			continue
		}
		candidate := time.Date(
			date.Year(), date.Month(), date.Day(), hour, minute, 0, 0, location,
		)
		if candidate.Day() != date.Day() ||
			candidate.Hour() != hour || candidate.Minute() != minute {
			continue
		}
		if !candidate.After(local) {
			return candidate
		}
	}
	return time.Time{}
}

// Render returns the digest as Markdown.
func Render(week Week) string {
	var body strings.Builder
	body.WriteString(correctionLead(week))
	body.WriteString("\n\n")
	body.WriteString(feedbackLine(week.Feedback))
	body.WriteString("\n\n")
	body.WriteString(knowledgeSection(week.Knowledge))
	body.WriteString("\n\n")
	body.WriteString(loopsSection(week.OpenLoops))
	body.WriteString("\n\n")
	body.WriteString(worstAnswerLine(week.Worst))
	return bounded(body.String(), maxDigestBytes)
}

// correctionLead is the first line, and it is the correction rate because that
// is the closest thing Responder has to a measure of whether it is getting
// better.
func correctionLead(week Week) string {
	window := windowLabel(week.Start, week.End)
	switch {
	case week.This.Turns == 0:
		return "No turns finished between " + window + ", so nothing can be concluded about the week."
	case week.This.Total == 0:
		// A clean zero and a broken instrument look identical. Corrections are
		// common enough in normal operation that zero across a window with real
		// traffic is much more likely to mean this build is not the one that ran
		// the turns. The correction-rate CLI says the same thing for the same
		// reason, and a digest that reported this as a good week would send the
		// team to trust a recorder that is switched off.
		return fmt.Sprintf(
			"**No corrections recorded across %d finished turns** (%s). That is more likely to "+
				"mean this build is not recording them than that nothing was wrong. Check that "+
				"the running deployment postdates correction recording before reading it as a "+
				"good week.",
			week.This.Turns, window,
		)
	}
	lead := fmt.Sprintf(
		"**Corrections ran at %s of turns** (%s), %s. %d of %d finished turns went back to the model.",
		percent(week.This.Rate()), window, direction(week.This, week.Previous),
		week.This.Total, week.This.Turns,
	)
	if week.TopCorrection != "" && week.TopCorrectionCount > 0 {
		lead += fmt.Sprintf(
			"\nMost repeated, %s: %s",
			times(week.TopCorrectionCount), quoted(week.TopCorrection, maxSummaryRune),
		)
	}
	return lead
}

// direction says which way the rate moved, and declines to say when the
// previous window cannot support the comparison.
func direction(this, previous Corrections) string {
	if previous.Turns == 0 {
		return "with no comparison because the week before finished no turns"
	}
	switch {
	case this.Rate() > previous.Rate():
		return "up from " + percent(previous.Rate())
	case this.Rate() < previous.Rate():
		return "down from " + percent(previous.Rate())
	default:
		return "unchanged from the week before"
	}
}

func feedbackLine(feedback Feedback) string {
	if feedback.Positive == 0 && feedback.Negative == 0 {
		return "Feedback: none this week."
	}
	line := fmt.Sprintf(
		"Feedback: %d positive, %d negative",
		feedback.Positive, feedback.Negative,
	)
	if feedback.Reactions > 0 {
		line += fmt.Sprintf(" — %d of them reactions", feedback.Reactions)
	}
	return line + "."
}

func knowledgeSection(knowledge Knowledge) string {
	if knowledge.Count == 0 {
		return "Learned: nothing new was accepted into memory this week."
	}
	var body strings.Builder
	fmt.Fprintf(&body, "Learned %s. Newest:", things(knowledge.Count))
	for _, statement := range knowledge.Newest[:min(len(knowledge.Newest), maxStatements)] {
		body.WriteString("\n- " + bounded(strings.TrimSpace(statement), maxStatementRune))
	}
	return body.String()
}

func loopsSection(channels []ChannelLoops) string {
	if len(channels) == 0 {
		return "Open loops: none older than a week."
	}
	var body strings.Builder
	fmt.Fprintf(&body,
		"Open loops older than a week, in %s:", channelCount(len(channels)),
	)
	for _, channel := range channels[:min(len(channels), maxLoopChannels)] {
		// A channel mention rather than a raw id: Slack renders it as a link the
		// reader can click, which is the only form of this identifier they would
		// act on.
		fmt.Fprintf(&body, "\n- <#%s> (%s): %s",
			channel.ChannelID, days(channel.IdleDays),
			bounded(strings.Join(channel.Loops, "; "), maxStatementRune),
		)
	}
	if extra := len(channels) - maxLoopChannels; extra > 0 {
		fmt.Fprintf(&body, "\n- and %d more.", extra)
	}
	return body.String()
}

func worstAnswerLine(finding *Finding) string {
	if finding == nil {
		return "Worst answer: no confirmed finding is still unactioned from this week."
	}
	line := "Worst answer: " + severityLabel(finding.Severity) +
		" — " + bounded(strings.TrimSpace(finding.Summary), maxSummaryRune)
	if !strings.HasSuffix(line, ".") {
		line += "."
	}
	// The id is the only handle on this finding: the dashboard lists it and the
	// watcher's own review directory is named after it.
	line += " Finding `" + finding.ID + "`"
	if finding.ChannelID != "" {
		line += " in <#" + finding.ChannelID + ">"
	}
	return line + "."
}

func severityLabel(severity string) string {
	if strings.TrimSpace(severity) == "" {
		return "severity unrecorded"
	}
	return severity + " severity"
}

// windowLabel names the week the way an operator would say it, in the location
// the window was computed in.
func windowLabel(start, end time.Time) string {
	// End is exclusive, so the last day the digest covers is the day before it.
	return start.Format("2 Jan") + " to " + end.AddDate(0, 0, -1).Format("2 Jan")
}

// percent renders a rate, and refuses to round a real one down to zero. "0% of
// turns" beside a nonzero count is the kind of contradiction that makes a
// reader stop believing the whole message.
func percent(rate float64) string {
	if rate > 0 && rate < 0.005 {
		return "under 1%"
	}
	return fmt.Sprintf("%.0f%%", 100*rate)
}

func times(count int) string {
	if count == 1 {
		return "once"
	}
	return fmt.Sprintf("%d times", count)
}

func things(count int) string {
	if count == 1 {
		return "1 thing"
	}
	return fmt.Sprintf("%d things", count)
}

func days(count int) string {
	if count == 1 {
		return "1 day"
	}
	return fmt.Sprintf("%d days", count)
}

func channelCount(count int) string {
	if count == 1 {
		return "1 channel"
	}
	return fmt.Sprintf("%d channels", count)
}

func quoted(value string, limit int) string {
	return "\"" + bounded(strings.TrimSpace(value), limit) + "\""
}

// bounded truncates on a rune boundary and says that it did.
func bounded(value string, limit int) string {
	return core.TruncateUTF8WithSuffix(value, limit, "…")
}
