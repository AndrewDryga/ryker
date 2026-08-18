package sessioncreate

import (
	"strings"
	"testing"

	"github.com/AndrewDryga/responder/internal/coop"
)

// Coop detail may contain operation IDs, refs, and local checkout paths. The
// operator needs custody and retry state, not transport internals from another
// process.
func TestRepositoryPreparationStatusDoesNotExposeCoopDetail(t *testing.T) {
	secret := "/Users/operator/private/token-ref op_secret_123"
	status := Status("tenant-core", &coop.APIError{
		Status: 500, Code: "repository_unavailable", Detail: secret,
	})
	if strings.Contains(status, secret) || strings.Contains(status, "op_secret_123") {
		t.Fatalf("workspace status exposed Coop detail: %q", status)
	}
	for _, want := range []string{"Investigation queued", "No model turn has started", "Responder will retry"} {
		if !strings.Contains(status, want) {
			t.Fatalf("workspace status lost %q: %q", want, status)
		}
	}
	if !strings.Contains(status, "tenant-core") {
		t.Fatalf("workspace status lost trusted repository label: %q", status)
	}
}
