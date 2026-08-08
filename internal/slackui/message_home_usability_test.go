package slackui

import (
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
	// Zero failures is news, so the three state counters always show.
	for _, required := range []string{"Open work", "Waiting on you", "Failed work"} {
		if _, ok := labels[required]; !ok {
			t.Errorf("%q should always be shown, got %v", required, labels)
		}
	}
	for _, hidden := range []string{"Draft PRs", "Cleanup queued", "Saved memory", "Schedules"} {
		if _, ok := labels[hidden]; ok {
			t.Errorf("%q reads zero and should be hidden, got %v", hidden, labels)
		}
	}
	if !strings.Contains(message.Text, "Nothing waiting on you") {
		t.Errorf("an idle system should say so plainly: %q", message.Text)
	}
}
