package provider

import (
	"strings"
	"testing"
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
