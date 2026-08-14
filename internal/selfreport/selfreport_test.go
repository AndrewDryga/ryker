package selfreport

import (
	"strings"
	"testing"
	"time"
)

func week() Week {
	start := time.Date(2026, 8, 3, 9, 0, 0, 0, time.UTC)
	return Week{
		Start:    start,
		End:      start.AddDate(0, 0, 7),
		This:     Corrections{Turns: 340, Total: 41},
		Previous: Corrections{Turns: 300, Total: 57},
	}
}

// The lead is the number that moved, not a greeting. An operator skimming the
// digest in a busy channel reads one line; if that line is "Here is your weekly
// report" the instrument has spent its only sentence saying nothing.
func TestTheDigestLeadsWithTheCorrectionRateAndItsDirection(t *testing.T) {
	body := Render(week())
	lead, _, _ := strings.Cut(body, "\n")
	if !strings.Contains(lead, "12%") || !strings.Contains(lead, "19%") {
		t.Fatalf("lead does not carry both rates: %q", lead)
	}
	if !strings.Contains(lead, "down") {
		t.Fatalf("lead does not say which way the rate moved: %q", lead)
	}
}

// Zero corrections and a broken recorder look identical, which is the trap the
// legacy-fallback counters fell into and why the correction-rate CLI says so in
// its own words. A digest that reports a clean zero as good news sends the team
// to trust a build that may simply not be recording.
func TestZeroCorrectionsIsReportedAsAProbablyBrokenInstrument(t *testing.T) {
	value := week()
	value.This = Corrections{Turns: 340, Total: 0}
	body := Render(value)
	if !strings.Contains(body, "not recording") {
		t.Fatalf("a zero rate was reported without the broken-instrument warning:\n%s", body)
	}
	if strings.Contains(body, "down from") {
		t.Fatalf("a zero rate was reported as an improvement:\n%s", body)
	}
}

func TestAWindowWithNoFinishedTurnsConcludesNothing(t *testing.T) {
	value := week()
	value.This = Corrections{}
	body := Render(value)
	if !strings.Contains(body, "nothing can be concluded") {
		t.Fatalf("an empty window drew a conclusion anyway:\n%s", body)
	}
}

// A section that vanishes when it is empty reads as a good week. Every section
// has to say "none" out loud, because the reader cannot tell a quiet week from
// a query that returned nothing.
func TestAnEmptySectionSaysNoneRatherThanVanishing(t *testing.T) {
	body := Render(week())
	for _, want := range []string{
		"Feedback: none",
		"Learned: nothing",
		"Open loops: none",
		"Worst answer: no confirmed finding",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("empty digest is missing %q:\n%s", want, body)
		}
	}
}

func TestEverySectionRendersItsNumbersAndItsNewestItems(t *testing.T) {
	value := week()
	value.TopCorrection = "the reply runs 180 words against a message of 4 words"
	value.TopCorrectionCount = 9
	value.Feedback = Feedback{Positive: 6, Negative: 2, Reactions: 5}
	value.Knowledge = Knowledge{Count: 7, Newest: []string{
		"Symbols upload from GitHub Actions through WIF.",
		"Checkout alerts route to #payments.",
		"The staging cluster is rebuilt every Sunday.",
	}}
	value.OpenLoops = []ChannelLoops{
		{ChannelID: "C0LOOPS", IdleDays: 9, Loops: []string{"confirm the migration ran"}},
	}
	value.Worst = &Finding{
		ID: "qw_2026_08_09_1", Severity: "high", ChannelID: "C0BAD",
		Summary: "Reported the deploy as verified without checking the rollout.",
	}
	body := Render(value)
	for _, want := range []string{
		"41 of 340",
		"the reply runs 180 words against a message of 4 words",
		"9 times",
		"6 positive",
		"2 negative",
		"5 of them reactions",
		"Learned 7",
		"Symbols upload from GitHub Actions through WIF.",
		"<#C0LOOPS>",
		"9 days",
		"confirm the migration ran",
		"high",
		"Reported the deploy as verified without checking the rollout.",
		"qw_2026_08_09_1",
		"<#C0BAD>",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("digest is missing %q:\n%s", want, body)
		}
	}
}

// Three, because a digest is skimmed. The count carries the rest.
func TestOnlyTheThreeNewestKnowledgeStatementsAreListed(t *testing.T) {
	value := week()
	value.Knowledge = Knowledge{Count: 5, Newest: []string{"one", "two", "three", "four", "five"}}
	body := Render(value)
	if strings.Contains(body, "four") || strings.Contains(body, "five") {
		t.Fatalf("digest listed more than three statements:\n%s", body)
	}
}

// The host now refuses replies that close by handing the question back, and a
// digest it composes itself must not do what it corrects the model for doing.
func TestTheDigestDoesNotCloseByHandingTheWeekBack(t *testing.T) {
	body := strings.ToLower(Render(week()))
	for _, banned := range []string{
		"no further action", "let me know", "nothing needed", "feel free",
	} {
		if strings.Contains(body, banned) {
			t.Errorf("digest closes on %q:\n%s", banned, body)
		}
	}
}

// A digest is one Slack message. Slack truncates a markdown block at 12,000
// characters, and a report that arrives cut in half is a report nobody reads.
func TestTheDigestStaysInsideOneSlackMessage(t *testing.T) {
	value := week()
	value.TopCorrection = strings.Repeat("correction text ", 200)
	value.Knowledge = Knowledge{Count: 400}
	for range 400 {
		value.Knowledge.Newest = append(value.Knowledge.Newest, strings.Repeat("statement ", 100))
	}
	for index := range 400 {
		value.OpenLoops = append(value.OpenLoops, ChannelLoops{
			ChannelID: "C0LOOPS", IdleDays: index,
			Loops: []string{strings.Repeat("loop ", 100)},
		})
	}
	value.Worst = &Finding{ID: "qw_1", Severity: "high", Summary: strings.Repeat("summary ", 500)}
	if size := len(Render(value)); size > 11000 {
		t.Fatalf("digest rendered %d characters, over what one Slack message holds", size)
	}
}

// The boundary is what makes the digest post once, so it has to be the same
// instant no matter when in the week it is asked for.
func TestThePreviousOccurrenceIsStableAcrossTheWholeWeek(t *testing.T) {
	monday := time.Date(2026, 8, 10, 9, 0, 0, 0, time.UTC)
	for _, at := range []time.Time{
		monday, monday.Add(time.Second), monday.Add(71 * time.Hour),
		monday.AddDate(0, 0, 6).Add(23 * time.Hour),
	} {
		got := PreviousOccurrence(at, time.UTC, time.Monday, 9, 0)
		if !got.Equal(monday) {
			t.Errorf("occurrence at %s = %s, want %s", at, got, monday)
		}
	}
	if got := PreviousOccurrence(
		monday.Add(-time.Second), time.UTC, time.Monday, 9, 0,
	); !got.Equal(monday.AddDate(0, 0, -7)) {
		t.Errorf("a second before the send resolved to %s", got)
	}
}

// Spring forward skips 02:00 in Chicago. A send scheduled inside the skipped
// hour has no occurrence that week; Go's time.Date would silently move it to
// 03:00, which is a digest posted at a time nobody configured.
func TestASendInsideTheSkippedHourIsNotSilentlyMoved(t *testing.T) {
	chicago, err := time.LoadLocation("America/Chicago")
	if err != nil {
		t.Skip("no timezone database")
	}
	transition := time.Date(2026, 3, 8, 20, 0, 0, 0, time.UTC)
	got := PreviousOccurrence(transition, chicago, time.Sunday, 2, 30)
	if want := time.Date(2026, 3, 1, 2, 30, 0, 0, chicago); !got.Equal(want) {
		t.Fatalf("occurrence = %s, want the previous week's %s", got.In(chicago), want)
	}
	// The hour on either side of the gap is ordinary and must still fire.
	if got := PreviousOccurrence(transition, chicago, time.Sunday, 9, 0); !got.Equal(
		time.Date(2026, 3, 8, 9, 0, 0, 0, chicago),
	) {
		t.Fatalf("a send outside the gap moved to %s", got.In(chicago))
	}
}

// The window is stated in the operator's own timezone, because "the week of
// 3 Aug" is what they will check the numbers against.
func TestTheWindowIsStatedInTheTimeZoneItWasComputedIn(t *testing.T) {
	chicago, err := time.LoadLocation("America/Chicago")
	if err != nil {
		t.Skip("no timezone database")
	}
	value := week()
	value.Start = time.Date(2026, 8, 3, 23, 30, 0, 0, time.UTC).In(chicago)
	value.End = value.Start.AddDate(0, 0, 7)
	if body := Render(value); !strings.Contains(body, "3 Aug") {
		t.Fatalf("window was rendered in UTC rather than the configured zone:\n%s", body)
	}
}
