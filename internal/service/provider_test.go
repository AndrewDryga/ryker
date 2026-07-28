package service

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
		{"watch triage failed: ACL request was rejected", "authorization", "Re-authenticate"},
		{"configured model does not exist", "model", "restart Responder"},
		{"worker disconnected", "agent", "Coop service"},
	}
	for _, test := range tests {
		failure := classifyProviderFailure(test.detail)
		if failure.Kind != test.kind ||
			!strings.Contains(failure.OperatorFix, test.fix) ||
			failure.Summary == "" {
			t.Fatalf("%q = %+v", test.detail, failure)
		}
	}
}
