package slackui

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func homeContent(message Message) string {
	parts := append([]string{message.Text}, message.Sections...)
	for _, row := range message.Rows {
		parts = append(parts, row.Text)
	}
	for _, field := range message.Fields {
		parts = append(parts, field.Label+" "+field.Value)
	}
	return strings.Join(parts, "\n")
}

// A failed run is not a promise owed to the team. Listing failures under "what
// Emisar owes the team" put a Coop idempotency conflict — an internal transport
// error the retry machinery owns — in front of an operator as a task, six times
// over, each with "Needs operator attention / Review the blocker or retry".
func TestWaitingOnYouExcludesFailuresAndBoilerplate(t *testing.T) {
	message := OperationsHome(
		0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1, nil,
		[]core.Commitment{
			{
				Title: "Deploy the website", State: core.CommitmentBlocked,
				Status: "The apply is waiting on a workspace lock", NextAction: "Force-unlock va1-apps",
			},
			{
				Title:  "<https://grafana.example.com/alerting/grafana/va1-reaper/view?orgId=1|[VA1 FIRING:1] Reaper missed its cycle> *FIRING*",
				State:  core.CommitmentBlocked,
				Status: "Coop API idempotency_conflict (409): idempotency key is bound to another request",
			},
			{
				Title: "Answer Slack request", State: core.CommitmentBlocked,
				Status: "Needs operator attention", NextAction: "Review the blocker or retry",
			},
		},
		nil, nil, nil, nil,
	)
	content := homeContent(message)

	if !strings.Contains(content, "Deploy the website") {
		t.Errorf("real blocked work is missing:\n%s", content)
	}
	// The store no longer projects failed episodes into commitments at all, so
	// this asserts the surviving half: an internal error that does reach a row
	// must not be shown as prose an operator is expected to act on.
	if strings.Contains(content, "idempotency key is bound") {
		t.Errorf("an internal transport failure is shown as operator prose:\n%s", content)
	}
	// The boilerplate pair says only what the Blocked label already said.
	if strings.Contains(content, "Needs operator attention") ||
		strings.Contains(content, "Review the blocker or retry") {
		t.Errorf("boilerplate status survived:\n%s", content)
	}
	// A raw alert URL is three unreadable lines; the link text is the alert.
	if strings.Contains(content, "https://grafana.example.com") {
		t.Errorf("a raw URL is being used as a title:\n%s", content)
	}
}

func TestCommitmentHeadlineKeepsTheAlertNotTheURL(t *testing.T) {
	got := commitmentHeadline(
		"<https://grafana.example.com/alerting/grafana/va1-reaper/view?orgId=1|[VA1 FIRING:1] WARNING | Reaper missed its cycle> *FIRING - 1 alert*",
	)
	if strings.Contains(got, "http") {
		t.Errorf("headline still carries a URL: %q", got)
	}
	if !strings.Contains(got, "Reaper missed its cycle") {
		t.Errorf("headline lost the alert name: %q", got)
	}
}

// "Context retained; no current summary" is a placeholder dressed as content.
// Three of them made a section that told the reader nothing.
func TestChannelSituationsWithoutASummaryAreOmitted(t *testing.T) {
	message := OperationsHome(
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, nil, nil,
		[]core.ChannelMemory{
			{ChannelID: "CQUIET", UpdatedAt: time.Now()},
			{ChannelID: "CBUSY", UpdatedAt: time.Now(), State: core.AgentMemory{
				SituationSummary: "Rollout verified; drift backlog still open",
			}},
		},
		nil, nil, nil,
	)
	content := homeContent(message)
	if strings.Contains(content, "no current summary") {
		t.Errorf("placeholder summary rendered:\n%s", content)
	}
	if strings.Contains(content, "CQUIET") {
		t.Errorf("a channel with nothing to report was listed:\n%s", content)
	}
	if !strings.Contains(content, "drift backlog still open") {
		t.Errorf("the channel that had something to say is missing:\n%s", content)
	}
}

// The page answers one question, so the numbers it is not about are one line
// of context with the command that opens each — not a grid of tiles competing
// with the work. Nine tiles, most of them zero or restating the heading, were
// most of what made the page read as a mess.
func TestSecondaryNumbersAreOneLineNotAGridOfTiles(t *testing.T) {
	message := OperationsHome(0, 0, 0, 100, 3, 0, 30, 0, 0, 0, 0, 0, nil, nil, nil, nil, nil, nil)

	if len(message.Fields) != 0 {
		t.Errorf("the page still renders a tile block: %+v", message.Fields)
	}
	context := strings.Join(message.Context, "\n")
	// Each number the page is not about names the command that opens it.
	for _, expected := range []string{
		"100 failed", "/responder failures",
		"30 retained workspaces", "/responder sessions",
		"3 draft PRs", "/responder status",
	} {
		if !strings.Contains(context, expected) {
			t.Errorf("context is missing %q:\n%s", expected, context)
		}
	}

	// An idle system says so in the one place the reader looks first.
	idle := OperationsHome(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, nil, nil, nil, nil, nil, nil)
	if !strings.Contains(strings.Join(idle.Sections, "\n"), "Nothing needs you") {
		t.Errorf("an idle system should say so plainly: %+v", idle.Sections)
	}
	if strings.Contains(strings.Join(idle.Context, "\n"), "retained workspaces") {
		t.Errorf("an idle system should not list chores it does not have: %+v", idle.Context)
	}
}

// Headings must keep their items. Rendering every row after every section put
// "Responder preferences", "Standing rules" and "Corrections worth keeping?"
// in a stack with all of their rows below all three, so no heading described
// what followed it.
func TestHomeHeadingsKeepTheirRows(t *testing.T) {
	expires := time.Now().Add(720 * time.Hour)
	message := OperationsHome(
		0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, nil, nil, nil, nil,
		[]core.ResponderPreference{{
			ID: "pref_1", Name: "response_location", Value: "prefer_thread",
			ScopeKind: "channel", ScopeKey: "CBACKEND", Enabled: true, ExpiresAt: expires,
		}},
		[]core.StandingRule{{
			ID: "rule_1", Trigger: "operational_alert", Action: "triage_alert",
			ChannelID: "CBACKEND", Enabled: true, ExpiresAt: expires,
		}},
	)
	message = AppendFixtureReview(message, []FixtureCandidateSummary{
		{ID: "cand_1", Correction: "a correction to judge"},
	})

	var order []string
	for _, block := range message.Blocks() {
		raw, err := json.Marshal(block)
		if err != nil {
			t.Fatal(err)
		}
		var probe struct {
			Type string `json:"type"`
			Text struct {
				Text string `json:"text"`
			} `json:"text"`
		}
		if err := json.Unmarshal(raw, &probe); err != nil {
			t.Fatal(err)
		}
		if probe.Type == "section" && probe.Text.Text != "" {
			order = append(order, probe.Text.Text)
		}
	}

	// Each heading must be immediately followed by its own item.
	for _, pair := range [][2]string{
		{"*Settings*", "response_location"},
		{"*Standing rules*", "operational_alert"},
		{"*Improve Responder*", "correction to judge"},
	} {
		found := false
		for index, text := range order {
			if !strings.Contains(text, pair[0]) {
				continue
			}
			if index+1 >= len(order) || !strings.Contains(order[index+1], pair[1]) {
				t.Errorf("%q is not followed by its row; order was:\n%s",
					pair[0], strings.Join(order, "\n"))
			}
			found = true
			break
		}
		if !found {
			t.Errorf("heading %q missing; order was:\n%s", pair[0], strings.Join(order, "\n"))
		}
	}
}

// The same alert firing twice made two identical rows with nothing to tell
// them apart, which reads as a rendering fault rather than two events.
func TestRepeatedAlertsCollapseWithACount(t *testing.T) {
	title := "<https://grafana.example.com/a|[VA1 FIRING:1] CRITICAL | Reaper overdue for 24h> *FIRING*"
	message := OperationsHome(
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, nil,
		[]core.Commitment{
			{Title: title, State: core.CommitmentBlocked},
			{Title: title, State: core.CommitmentBlocked},
		},
		nil, nil, nil, nil,
	)
	content := homeContent(message)
	if strings.Count(content, "Reaper overdue") != 1 {
		t.Errorf("the repeated alert was listed more than once:\n%s", content)
	}
	if !strings.Contains(content, "×2") {
		t.Errorf("the repeat count is missing:\n%s", content)
	}
	// Emphasis from the source message must not leak into the headline.
	if strings.Contains(content, "*FIRING*") {
		t.Errorf("source markup leaked into the headline:\n%s", content)
	}
}

// A correction reads as the rule that was broken, not as the same machinery
// prefix five times over. Four of the five on the page opened with "the
// structured Slack response is invalid:", which pushed the part that differs
// to the right of a colon the reader had to scan past every time.
func TestCorrectionsLeadWithWhatWasWrong(t *testing.T) {
	message := AppendFixtureReview(Message{}, []FixtureCandidateSummary{
		{ID: "c1", Correction: "the structured Slack response is invalid: decision-ready completion cannot contain material gaps"},
		{ID: "c2", Correction: "the deep work episode found active degradation but has no diagnostic closure"},
	})
	var rows []string
	for _, row := range message.Rows {
		rows = append(rows, row.Text)
	}
	content := strings.Join(rows, "\n")

	if strings.Contains(content, "structured Slack response is invalid") {
		t.Errorf("the machinery prefix survived:\n%s", content)
	}
	if !strings.Contains(content, "Decision-ready completion cannot contain material gaps") {
		t.Errorf("the rule that was broken is missing:\n%s", content)
	}
	// A correction that never had the prefix is left alone apart from its case.
	if !strings.Contains(content, "The deep work episode found active degradation") {
		t.Errorf("an unprefixed correction was mangled:\n%s", content)
	}
}

// Active work outranks a standing chore. Thirty retained workspaces is cleanup
// that has waited days; a blocked question has somebody waiting on the answer,
// and the chore used to sit above it in a paragraph of its own.
func TestTheChoreDoesNotOutrankTheWork(t *testing.T) {
	message := OperationsHome(
		0, 0, 0, 0, 0, 0, 30, 0, 0, 0, 0, 1, nil,
		[]core.Commitment{{
			Title: "Deploy the website", State: core.CommitmentBlocked,
			Status: "Waiting on a workspace lock", NextAction: "Force-unlock va1-apps",
		}},
		nil, nil, nil, nil,
	)
	sections := strings.Join(message.Sections, "\n")
	if !strings.Contains(sections, "Deploy the website") {
		t.Fatalf("the blocked work is missing:\n%s", sections)
	}
	// The chore is a line of context, not a section competing with the work.
	if strings.Contains(sections, "retained workspace") {
		t.Errorf("the cleanup chore is still a section:\n%s", sections)
	}
	if !strings.Contains(strings.Join(message.Context, "\n"), "30 retained workspaces") {
		t.Errorf("the chore should still be reachable: %+v", message.Context)
	}
}
