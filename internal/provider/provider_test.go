package provider

import (
	"strings"
	"testing"
	"time"
)

func TestProviderFailureClassificationGivesOperatorNextStep(t *testing.T) {
	tests := []struct {
		detail string
		kind   string
		fix    string
	}{
		{"insufficient_quota", "usage_limit", "billing"},
		{"HTTP 429 too many requests", "rate_limit", "Wait"},
		{"watch triage failed: ACL request was rejected", "authorization", "Sign in"},
		{"provider credential needs sign-in or renewal", "authorization", "Sign in"},
		{"configured model does not exist", "model", "restart Responder"},
		{"ACP transcript exceeded its bound", "transcript_limit", "paginated"},
		{"worker disconnected", "agent", "Coop service"},
	}
	for _, test := range tests {
		failure := Classify(test.detail)
		if failure.Kind != test.kind ||
			!strings.Contains(failure.OperatorFix, test.fix) ||
			failure.Summary == "" {
			t.Fatalf("%q = %+v", test.detail, failure)
		}
	}
}

// Coop stamps the soonest rung reset into an exhausted-ladder detail. Waiting
// exactly that long beats guessing, but the wait is capped so a credential
// signed in during the window is picked up without sitting the window out.
func TestLadderRetryDelayFollowsTheReportedReset(t *testing.T) {
	now := time.Date(2026, 8, 7, 18, 0, 0, 0, time.UTC)
	for name, expect := range map[string]struct {
		detail string
		want   time.Duration
	}{
		"named reset": {
			"every target in the policy ladder is rate limited until 2026-08-07T18:30:00Z",
			30 * time.Minute,
		},
		"reset beyond the cap": {
			"every target in the policy ladder is rate limited until 2026-08-11T00:00:00Z",
			UsageLimitRetryDelay,
		},
		"no reset stamped": {"every target is rate limited", RateLimitRetryDelay},
		"unparseable reset": {
			"every target in the policy ladder is rate limited until soon", RateLimitRetryDelay,
		},
		"reset already passed": {
			"every target in the policy ladder is rate limited until 2026-08-07T17:00:00Z",
			RateLimitRetryDelay,
		},
	} {
		if got := LadderRetryDelay(expect.detail, now); got != expect.want {
			t.Fatalf("%s delay = %s, want %s", name, got, expect.want)
		}
	}
	if !LadderExhausted("rate_limited") || LadderExhausted("acp_process_error") {
		t.Fatal("exhausted-ladder classification does not match Coop's turn error code")
	}
}

// The errors that must never reach Slack: the request reached the model and the
// connection broke. Reporting those as failed checks is what trains people to
// ignore the channel.
func TestTransientProviderFailuresAreRecognised(t *testing.T) {
	for _, detail := range []string{
		"ACP request was rejected: Internal error: API Error: Response stalled mid-stream. The response above may be incomplete.",
		"ACP request was rejected: upstream connect error: service unavailable",
		"ACP request was rejected: Overloaded",
		"ACP request was rejected: read tcp: connection reset by peer",
	} {
		if !Transient(detail) {
			t.Fatalf("a dropped stream was treated as a real failure: %q", detail)
		}
	}
	// A refusal that says something an operator can act on is NOT transient, or
	// retrying would bury the one message worth reading.
	for _, detail := range []string{
		"ACP request was rejected: You have hit your usage limit. Try again Aug 11.",
		"ACP request was rejected: model gpt-9 does not exist",
		"ACP request was rejected: invalid api key",
		"every target in the policy ladder is rate limited until 2026-08-07T18:30:00Z",
	} {
		if Transient(detail) {
			t.Fatalf("an actionable refusal was treated as transient: %q", detail)
		}
	}
}
