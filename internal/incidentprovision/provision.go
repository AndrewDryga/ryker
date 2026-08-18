// Package incidentprovision converges incident work onto a session with the
// exact repository authority its lane grants.
package incidentprovision

import (
	"context"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/sessionauthority"
	"github.com/AndrewDryga/responder/internal/sessioncreate"
)

type Client interface {
	sessionauthority.CandidateClient
	sessioncreate.OperationLookup
	CreateSession(context.Context, string, string, string, ...coop.SessionSource) (coop.Session, coop.Operation, error)
}

func Resolve(
	ctx context.Context,
	client Client,
	cleanup sessionauthority.CleanupScheduler,
	generations sessioncreate.GenerationAdvancer,
	incident core.Incident,
	policy string,
	label string,
	sources []coop.SessionSource,
	now time.Time,
) (coop.Session, int, error) {
	lane, readOnly := "incident", true
	if incident.IsEngineeringTask() {
		lane, readOnly = "engineering", false
	}
	return sessioncreate.ResolveCandidates(ctx, sessioncreate.CandidateRequest{
		Lane: lane, Generation: incident.CoopSessionGeneration,
		RepositoryReadOnly: readOnly, BaseKey: "responder:session:" + incident.ID,
		AttemptStarted: now.UTC(), Lookup: client,
		Create: func(ctx context.Context, key string, _ int) (coop.Session, error) {
			session, _, err := client.CreateSession(ctx, key, policy, label, sources...)
			return session, err
		},
		Reject: func(ctx context.Context, session coop.Session) error {
			return sessionauthority.RejectCandidate(
				ctx, client, cleanup, session, incident.ID, lane, now,
			)
		},
		Advance: func(ctx context.Context, generation int) error {
			return generations.AdvanceSessionGeneration(ctx, incident.ID, generation)
		},
	})
}
