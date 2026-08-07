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

// Store is the durable state a followup reads and writes.
type Store interface {
	NextPublicationFollowup(ctx context.Context, now time.Time) (core.PublicationFollowup, core.Publication, error)
	GetPublicationFollowup(ctx context.Context, incidentID string) (core.PublicationFollowup, error)
	EnsurePublicationFollowup(ctx context.Context, incidentID string, now time.Time) error
	SavePublicationFollowup(ctx context.Context, followup core.PublicationFollowup) error
	GetPublication(ctx context.Context, incidentID string) (core.Publication, error)
	MarkPublicationStale(ctx context.Context, incidentID, reason string) (bool, error)
	GetIncident(ctx context.Context, incidentID string) (core.Incident, error)
	RecordPublicationLifecycleEvent(ctx context.Context, event core.PublicationLifecycleEvent) (bool, error)
}

// StatusSource reports what the forge currently says about a publication.
// Enabled is separate because a deployment without GitHub credentials is a
// supported configuration, not an error — the followup simply defers.
type StatusSource interface {
	Enabled() bool
	PublicationStatus(ctx context.Context, publication core.Publication) (core.PublicationLifecycleStatus, error)
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
	store    Store
	status   StatusSource
	reporter Reporter
	cfg      Config
	now      func() time.Time
}

func NewFollower(
	store Store,
	status StatusSource,
	reporter Reporter,
	cfg Config,
	now func() time.Time,
) *Follower {
	return &Follower{store: store, status: status, reporter: reporter, cfg: cfg, now: now}
}
