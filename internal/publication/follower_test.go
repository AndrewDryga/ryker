package publication

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
)

type orderingFollowups struct {
	mu      sync.Mutex
	current core.PublicationFollowup
}

func (s *orderingFollowups) Next(context.Context, time.Time) (core.PublicationFollowup, core.Publication, error) {
	return s.current, core.Publication{}, nil
}
func (s *orderingFollowups) Get(context.Context, string) (core.PublicationFollowup, error) {
	return s.current, nil
}
func (*orderingFollowups) Ensure(context.Context, string, time.Time) error { return nil }
func (s *orderingFollowups) SaveTransition(
	_ context.Context,
	expected, item core.PublicationFollowup,
	_ *core.PublicationLifecycleEvent,
) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !expected.UpdatedAt.Equal(s.current.UpdatedAt) ||
		expected.ChecksState != s.current.ChecksState ||
		expected.FailureCount != s.current.FailureCount ||
		expected.LastError != s.current.LastError {
		return false, core.ErrConflict
	}
	item.UpdatedAt = s.current.UpdatedAt.Add(time.Second)
	s.current = item
	return true, nil
}

type orderingStatus struct {
	mu         sync.Mutex
	calls      int
	firstReady chan<- struct{}
	release    <-chan struct{}
	firstError error
}

func (*orderingStatus) Enabled() bool { return true }
func (s *orderingStatus) PublicationStatus(
	context.Context,
	core.Publication,
) (core.PublicationLifecycleStatus, error) {
	s.mu.Lock()
	s.calls++
	call := s.calls
	s.mu.Unlock()
	if call == 1 {
		s.firstReady <- struct{}{}
		<-s.release
		if s.firstError != nil {
			return core.PublicationLifecycleStatus{}, s.firstError
		}
		return core.PublicationLifecycleStatus{
			PRState: "open", ChecksState: "pending", HeadSHA: "remote",
		}, nil
	}
	return core.PublicationLifecycleStatus{
		PRState: "open", ChecksState: "passing", HeadSHA: "remote",
		ChecksTotal: 1, ChecksPassed: 1,
	}, nil
}

type orderingPublications struct{ item core.Publication }

func (s orderingPublications) Get(context.Context, string) (core.Publication, error) {
	return s.item, nil
}
func (orderingPublications) MarkStale(context.Context, string, string) (bool, error) {
	return false, nil
}

type orderingIncidents struct{ item core.Incident }

func (s orderingIncidents) GetIncident(context.Context, string) (core.Incident, error) {
	return s.item, nil
}

type orderingReporter struct{}

func (orderingReporter) Enqueue(context.Context, string, core.Incident, string, string, slackui.Message) error {
	return nil
}
func (orderingReporter) RecordTimeline(context.Context, core.TimelineEvent) {}

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

func TestDelayedFollowupCannotOverwriteNewerSuccess(t *testing.T) {
	for _, test := range []struct {
		name     string
		firstErr error
	}{
		{name: "older no-event status"},
		{name: "older transient failure", firstErr: errors.New("temporary forge failure")},
	} {
		t.Run(test.name, func(t *testing.T) {
			now := time.Date(2026, 8, 12, 12, 0, 0, 0, time.UTC)
			initial := core.PublicationFollowup{
				IncidentID: "inc_ordering", PRState: "open", ChecksState: "pending",
				NextCheckAt: now, UpdatedAt: now,
			}
			followups := &orderingFollowups{current: initial}
			firstReady := make(chan struct{}, 1)
			release := make(chan struct{})
			status := &orderingStatus{
				firstReady: firstReady, release: release, firstError: test.firstErr,
			}
			published := core.Publication{
				IncidentID: initial.IncidentID, State: core.PublicationPublished,
				RemoteSHA: "remote", PRNumber: 42, PRURL: "https://example.test/pull/42",
			}
			follower := NewFollower(
				followups, orderingPublications{item: published},
				orderingIncidents{item: core.Incident{ID: initial.IncidentID}},
				status, orderingReporter{}, Config{FollowupInterval: time.Minute},
				func() time.Time { return now },
			)
			older := make(chan error, 1)
			go func() {
				older <- follower.refresh(
					context.Background(), initial, published, core.SlackInput{}, false,
				)
			}()
			<-firstReady
			if err := follower.refresh(
				context.Background(), initial, published, core.SlackInput{}, false,
			); err != nil {
				t.Fatal(err)
			}
			close(release)
			if err := <-older; !errors.Is(err, core.ErrConflict) {
				t.Fatalf("delayed write = %v, want conflict", err)
			}
			if followups.current.ChecksState != "passing" ||
				followups.current.ChecksTotal != 1 || followups.current.ChecksPassed != 1 ||
				followups.current.FailureCount != 0 || followups.current.LastError != "" {
				t.Fatalf("newer success overwritten = %+v", followups.current)
			}
		})
	}
}
