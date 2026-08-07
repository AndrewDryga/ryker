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
