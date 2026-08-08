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

// Twelve counters, most reading zero, buried the two worth reading — and were
// what pushed the section past Slack's ten-field limit so the page did not
// render at all.
func TestZeroCountersAreHiddenButTheStateIsAlwaysShown(t *testing.T) {
	message := OperationsHome(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, nil, nil, nil, nil, nil, nil)
	labels := map[string]string{}
	for _, field := range message.Fields {
		labels[field.Label] = field.Value
	}
	if len(message.Fields) > 10 {
		t.Fatalf("%d fields exceeds Slack's limit of 10", len(message.Fields))
	}
	// Zero failures is news, so that one counter always shows.
	if _, ok := labels["Failed work"]; !ok {
		t.Errorf("failed work should always be shown, got %v", labels)
	}
	// Nothing that the heading, the retained-workspace banner, or a section
	// listing the rows in full already says. A number beside itself is noise.
	for _, duplicated := range []string{
		"Waiting on you", "Cleanup blocked", "Preferences", "Standing rules",
		"Open work", "Recorded work", "Schedules", "Saved memory", "Active sessions",
	} {
		if _, ok := labels[duplicated]; ok {
			t.Errorf("%q is already stated elsewhere on the page, got %v", duplicated, labels)
		}
	}
	if !strings.Contains(message.Text, "Nothing waiting on you") {
		t.Errorf("an idle system should say so plainly: %q", message.Text)
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
		{"*Responder preferences*", "response_location"},
		{"*Standing rules*", "operational_alert"},
		{"*Corrections worth keeping?*", "correction to judge"},
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
// that has waited days; a blocked question has somebody waiting on the answer.
func TestBlockedWorkIsListedBeforeTheCleanupBanner(t *testing.T) {
	message := OperationsHome(
		0, 0, 0, 0, 0, 0, 30, 0, 0, 0, 0, 1, nil,
		[]core.Commitment{{
			Title: "Deploy the website", State: core.CommitmentBlocked,
			Status: "Waiting on a workspace lock", NextAction: "Force-unlock va1-apps",
		}},
		nil, nil, nil, nil,
	)
	joined := strings.Join(message.Sections, "\n---\n")
	work := strings.Index(joined, "Waiting on you")
	chore := strings.Index(joined, "retained workspace")
	if work < 0 || chore < 0 {
		t.Fatalf("expected both sections:\n%s", joined)
	}
	if work > chore {
		t.Errorf("the cleanup chore is above the blocked work:\n%s", joined)
	}
}
