package publication

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// A transition is what turns "the forge says something changed" into a message
// an operator sees. The cases that must NOT emit one matter most: a stale
// publication and an unverified PR head both mean Responder is looking at
// something other than what it published, and reporting on it would attribute
// someone else's change to this task.
func TestPublicationTransitions(t *testing.T) {
	publication := core.Publication{
		State: "published", PRNumber: 493,
		PRURL:     "https://github.com/org/repo/pull/493",
		RemoteSHA: "0123456789abcdef",
	}
	old := core.PublicationFollowup{PRState: "open", ChecksState: "pending"}
	current := core.PublicationFollowup{PRState: "open", ChecksState: "passing"}
	kind, state, summary := publicationTransition(
		publication, old, current,
		core.PublicationLifecycleStatus{ChecksTotal: 4, ChecksPassed: 4}, false,
		14*24*time.Hour,
	)
	if kind != "checks" || state != "succeeded" || !strings.Contains(summary, "4 of 4") {
		t.Fatalf("passing transition = %q, %q, %q", kind, state, summary)
	}
	publication.State = "stale"
	kind, state, summary = publicationTransition(
		publication, old, current,
		core.PublicationLifecycleStatus{
			HeadSHA: publication.RemoteSHA, ChecksTotal: 4, ChecksPassed: 4,
		},
		false,
		14*24*time.Hour,
	)
	if kind != "" || state != "" || summary != "" {
		t.Fatalf("stale publication emitted transition = %q, %q, %q", kind, state, summary)
	}
	publication.State = "published"
	kind, state, summary = publicationTransition(
		publication, old, current,
		core.PublicationLifecycleStatus{
			HeadSHA: "fedcba9876543210", ChecksTotal: 4, ChecksPassed: 4,
		},
		false,
		14*24*time.Hour,
	)
	if kind != "" || state != "" || summary != "" {
		t.Fatalf("unverified PR head emitted transition = %q, %q, %q", kind, state, summary)
	}

}
