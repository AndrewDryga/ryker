package agentcontext

import "testing"

func TestNeedsCaptureRejectsLegacyRepositoryMismatch(t *testing.T) {
	if !NeedsCapture(true, "channel-default", "task-repository") {
		t.Fatal("legacy channel repository was accepted for pinned task work")
	}
	if NeedsCapture(true, "task-repository", "task-repository") {
		t.Fatal("matching pinned task context was unnecessarily recaptured")
	}
	if !NeedsCapture(false, "task-repository", "task-repository") {
		t.Fatal("missing durable context was accepted")
	}
}
