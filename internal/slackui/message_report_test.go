package slackui

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func reportFixture() core.RemediationRecord {
	incident := core.Incident{
		ID: "inc_va1memory", Title: "VA1 memory growth", ChannelID: "CINCIDENT",
		Status: core.IncidentActive, Workflow: core.WorkflowInvestigating,
		FiringCount: 2, SignalCount: 5, Severity: "high",
		CreatedAt: time.Date(2026, 7, 27, 19, 0, 0, 0, time.UTC),
	}
	return core.RemediationRecord{
		Incident: incident,
		Events: []core.TimelineEvent{{
			Title:     "Alert received",
			CreatedAt: time.Date(2026, 7, 27, 19, 0, 0, 0, time.UTC),
		}, {
			Title:     "Live state checked",
			CreatedAt: time.Date(2026, 7, 27, 20, 30, 0, 0, time.UTC),
		}},
		Evidence: []core.Evidence{{
			Claim: "Heap grew for six hours", Observation: "RSS climbed 400MB",
			SourceType: "emisar", SourceName: "metrics",
		}},
		Coverage: []core.Coverage{
			{Layer: "application", Status: "verified", Detail: "SLO source read"},
			{Layer: "database", Status: "unknown", Detail: "No source available"},
			{Layer: "CDN", Status: "unknown", Detail: "No source available"},
		},
	}
}

// A report card names the document by the document's own heading.
//
// The title is taken out of the Markdown rather than composed a second time
// here, so the canvas and the card cannot come to disagree about what a reader
// is opening. Two independent spellings of the same name is exactly how a
// document ends up filed under one title and linked under another.
func TestReportTitlesComeFromTheReportsOwnHeading(t *testing.T) {
	record := reportFixture()
	for _, testCase := range []struct {
		name   string
		report Report
		want   string
	}{
		{name: "timeline", report: TimelineReport(record), want: "Remediation timeline"},
		{name: "handoff", report: HandoffReport(record), want: "Shift handoff: VA1 memory growth"},
		{name: "postmortem", report: PostmortemReport(record), want: "Post-incident draft: VA1 memory growth"},
		{
			name:   "evidence",
			report: EvidenceReport(record.Incident, record.Evidence, record.Coverage),
			want:   "Evidence for incident va1memory",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			if testCase.report.Title != testCase.want {
				t.Fatalf("title = %q, want %q", testCase.report.Title, testCase.want)
			}
			// The document is the report the constructors already build, not a
			// second rendering of the same facts.
			if testCase.report.Markdown != testCase.report.Message.Markdown {
				t.Fatal("the canvas body is not the report the message form carries")
			}
			if testCase.report.Headline == "" || testCase.report.Counts == "" {
				t.Fatalf("report = %+v", testCase.report)
			}
		})
	}
}

// The postmortem card leads with what the draft refuses to claim.
//
// The draft never assigns a root cause — its own follow-up list carries
// "Confirm root cause from cited evidence" as an unticked box — so a card
// summarising it as a finished postmortem would quietly promote a document of
// open questions into a conclusion. Naming the layers nobody checked is the
// part a reader can act on, and it is otherwise at the bottom of a canvas.
func TestPostmortemCardStatesWhatTheDraftDoesNotClaim(t *testing.T) {
	report := PostmortemReport(reportFixture())
	if !strings.Contains(report.Headline, "Root cause is not assigned") {
		t.Fatalf("postmortem headline = %q", report.Headline)
	}
	if !strings.Contains(report.Headline, "database and CDN were never checked") {
		t.Fatalf("postmortem headline hides the coverage gaps: %q", report.Headline)
	}

	// With nothing recorded at all the sentence has to get stronger, not
	// vaguer: an empty draft is the case where a confident summary would do the
	// most damage.
	empty := PostmortemReport(core.RemediationRecord{Incident: reportFixture().Incident})
	if !strings.Contains(empty.Headline, "no structured evidence was recorded") {
		t.Fatalf("empty postmortem headline = %q", empty.Headline)
	}
}

// Each report's one sentence answers the question that report exists to answer.
func TestEachReportLeadsWithItsOwnJudgement(t *testing.T) {
	record := reportFixture()
	for _, testCase := range []struct {
		name     string
		headline string
		want     []string
	}{{
		name:     "timeline is a count and a span",
		headline: TimelineReport(record).Headline,
		want:     []string{"3 recorded events", "2026-07-27 19:00 UTC", "2026-07-27 20:30 UTC"},
	}, {
		name:     "handoff is state and signals",
		headline: HandoffReport(record).Headline,
		want:     []string{"Investigating", "2 of 5 signals firing", "high"},
	}, {
		name:     "evidence is counts",
		headline: EvidenceReport(record.Incident, record.Evidence, record.Coverage).Headline,
		want:     []string{"1 durable observation", "3 coverage layers"},
	}} {
		t.Run(testCase.name, func(t *testing.T) {
			for _, want := range testCase.want {
				if !strings.Contains(testCase.headline, want) {
					t.Fatalf("headline %q is missing %q", testCase.headline, want)
				}
			}
		})
	}
}

// An empty timeline says so rather than describing a span between two moments
// that never happened.
func TestEmptyReportsSayThereIsNothingToRead(t *testing.T) {
	empty := core.RemediationRecord{Incident: core.Incident{ID: "inc_empty", Title: "Nothing"}}
	if !strings.Contains(TimelineReport(empty).Headline, "No incident activity") {
		t.Fatalf("empty timeline headline = %q", TimelineReport(empty).Headline)
	}
	evidence := EvidenceReport(empty.Incident, nil, nil)
	if !strings.Contains(evidence.Headline, "No evidence has been recorded") {
		t.Fatalf("empty evidence headline = %q", evidence.Headline)
	}
}

// The card is a pointer, not a document, and it holds custody of nothing.
//
// Grey with no primary because a report is informational: nothing here is
// waiting on the reader, and a green button would say the opposite. One
// control, and it is the way in — a "post it here instead" button would need a
// handler able to rebuild the report at click time, and a control that cannot
// do what its label says is worse than no control.
func TestReportCanvasCardIsAPointerWithOneWayIn(t *testing.T) {
	report := TimelineReport(reportFixture())
	card := ReportCanvasCard(report, "https://acme.slack.com/docs/T1/F0CANVAS")
	if card.Stripe != StripeIdle {
		t.Fatalf("stripe = %q, want the informational grey", card.Stripe)
	}
	if card.Header != report.Title {
		t.Fatalf("header = %q, want %q", card.Header, report.Title)
	}
	if len(card.Sections) != 1 || card.Sections[0] != report.Headline {
		t.Fatalf("sections = %v", card.Sections)
	}
	if len(card.Context) != 1 || card.Context[0] != report.Counts {
		t.Fatalf("context = %v", card.Context)
	}
	if len(card.Actions) != 1 {
		t.Fatalf("actions = %+v, want only the way into the canvas", card.Actions)
	}
	action := card.Actions[0]
	if action.ID != ActionOpenCanvas || action.Label != "Open the canvas" ||
		action.URL != "https://acme.slack.com/docs/T1/F0CANVAS" || action.Style != "" {
		t.Fatalf("canvas action = %+v", action)
	}
	// The card never carries the document. Putting the timeline on the card as
	// well as the canvas would defeat the whole point of moving it.
	if card.Markdown != "" {
		t.Fatalf("the card carries the document: %q", card.Markdown)
	}
	// Notifications strip the button, so the fallback line has to say what the
	// card is and what it found.
	if !strings.Contains(card.Text, report.Title) ||
		!strings.Contains(card.Text, report.Headline) {
		t.Fatalf("fallback text = %q", card.Text)
	}
}

// A card with no link offers no button rather than a button that goes nowhere.
func TestReportCanvasCardWithoutALinkOffersNoControl(t *testing.T) {
	card := ReportCanvasCard(TimelineReport(reportFixture()), "")
	if len(card.Actions) != 0 {
		t.Fatalf("actions = %+v", card.Actions)
	}
}

// The counts line is arithmetic the headline stands on, and it drops the parts
// that would say nothing: an incident with full coverage has no unresolved
// layers to report, and "0 unresolved" reads as a finding.
func TestReportCountsOmitWhatWouldSayNothing(t *testing.T) {
	record := reportFixture()
	counts := TimelineReport(record).Counts
	for _, want := range []string{"3 events", "1 observation", "3 coverage layers", "2 unresolved"} {
		if !strings.Contains(counts, want) {
			t.Fatalf("counts %q is missing %q", counts, want)
		}
	}
	record.Coverage = []core.Coverage{{Layer: "application", Status: "verified"}}
	if strings.Contains(TimelineReport(record).Counts, "unresolved") {
		t.Fatalf("fully covered counts = %q", TimelineReport(record).Counts)
	}
}
