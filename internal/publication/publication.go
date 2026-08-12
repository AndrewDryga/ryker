// Package publication tracks a published pull request through its remaining
// life: checks, merge, deployment, and the Slack messages that report each.
//
// It exists as its own package because that tracking is a self-contained
// concern with a small surface — nine store reads and writes, a status source,
// and somewhere to send a message — and because keeping it inside the service
// meant it could reach anything, which is how a bounded concern stops being
// bounded.
//
// The interfaces below are the port, declared here at the consumer rather than
// exported from the packages that satisfy them. That direction matters: it
// names what this package needs rather than what those packages happen to
// offer, so it cannot quietly grow to depend on more of them.
package publication

import (
	"context"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
)

// FollowupStore owns post-publication status and lifecycle events.
type FollowupStore interface {
	Next(ctx context.Context, now time.Time) (core.PublicationFollowup, core.Publication, error)
	Get(ctx context.Context, incidentID string) (core.PublicationFollowup, error)
	Ensure(ctx context.Context, incidentID string, now time.Time) error
	SaveTransition(ctx context.Context, expected, followup core.PublicationFollowup, event *core.PublicationLifecycleEvent) (bool, error)
}

// PublicationStore owns the reviewed publication receipt.
type PublicationStore interface {
	Get(ctx context.Context, incidentID string) (core.Publication, error)
	MarkStale(ctx context.Context, incidentID, reason string) (bool, error)
}

// IncidentStore supplies the task whose card or thread receives a transition.
type IncidentStore interface {
	GetIncident(ctx context.Context, incidentID string) (core.Incident, error)
}

// StatusSource reports what the forge currently says about a publication.
// Enabled is separate because a deployment without GitHub credentials is a
// supported configuration, not an error — the followup simply defers.
type StatusSource interface {
	Enabled() bool
	PublicationStatus(ctx context.Context, publication core.Publication) (core.PublicationLifecycleStatus, error)
}

type statusAPI interface {
	PublicationStatus(context.Context, core.Publication) (core.PublicationLifecycleStatus, error)
}

type statusSource struct {
	publisher interface{ Enabled() bool }
	client    statusAPI
}

func (s statusSource) Enabled() bool { return s.publisher.Enabled() }

func (s statusSource) PublicationStatus(
	ctx context.Context,
	publication core.Publication,
) (core.PublicationLifecycleStatus, error) {
	return s.client.PublicationStatus(ctx, publication)
}

// StatusSourceFor joins the publisher's capability and status halves when both
// are present. A deployment without the status half is supported and returns nil.
func StatusSourceFor(candidate any) StatusSource {
	publisher, enabled := candidate.(interface{ Enabled() bool })
	client, supported := candidate.(statusAPI)
	if candidate == nil || !enabled || !supported {
		return nil
	}
	return statusSource{publisher: publisher, client: client}
}

// Reporter delivers what the followup found. Enqueue rather than post: a
// lifecycle message is durable work like any other, and posting inline would
// put a Slack round trip inside the followup loop.
type Reporter interface {
	Enqueue(ctx context.Context, deliveryID string, incident core.Incident, kind, threadTS string, message slackui.Message) error
	RecordTimeline(ctx context.Context, event core.TimelineEvent)
}

// Config is the two durations this package needs, passed rather than read from
// a global configuration it would otherwise have to import all of.
type Config struct {
	FollowupInterval          time.Duration
	DeliveryCorrelationWindow time.Duration
}

// Follower tracks publications through their remaining lifecycle.
type Follower struct {
	followups    FollowupStore
	publications PublicationStore
	incidents    IncidentStore
	status       StatusSource
	reporter     Reporter
	cfg          Config
	now          func() time.Time
}

func NewFollower(
	followups FollowupStore,
	publications PublicationStore,
	incidents IncidentStore,
	status StatusSource,
	reporter Reporter,
	cfg Config,
	now func() time.Time,
) *Follower {
	return &Follower{
		followups: followups, publications: publications, incidents: incidents,
		status: status, reporter: reporter, cfg: cfg, now: now,
	}
}
