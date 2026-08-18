// Package serviceport defines the external capabilities used by the service
// coordinator without owning any workflow policy.
package serviceport

import (
	"context"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/emisar"
	"github.com/AndrewDryga/responder/internal/publisher"
	"github.com/slack-go/slack/socketmode"
)

type Coop interface {
	Ready(context.Context) error
	CreateSession(context.Context, string, string, string, ...coop.SessionSource) (coop.Session, coop.Operation, error)
	GetSession(context.Context, string) (coop.Session, error)
	OperationByKey(context.Context, string) (coop.Operation, error)
	PrepareSession(context.Context, string, string, int64) (coop.Session, error)
	ListSessions(context.Context, int) ([]coop.Session, error)
	SubmitTurn(context.Context, string, string, int64, string) (coop.Turn, coop.Operation, error)
	SubmitTurnWithArtifacts(context.Context, string, string, int64, string, []coop.InputArtifact) (coop.Turn, coop.Operation, error)
	// SubmitTurnAtOrAbove carries the escalation floor: the rung of the session
	// policy's target ladder below which the turn may not be answered.
	SubmitTurnAtOrAbove(context.Context, string, string, int64, string, []coop.InputArtifact, int) (coop.Turn, coop.Operation, error)
	// SubmitTurnRewound explicitly starts one turn on the first policy rung.
	// Unlike a zero floor, it moves a session whose durable target is higher.
	SubmitTurnRewound(context.Context, string, string, int64, string, []coop.InputArtifact) (coop.Turn, coop.Operation, error)
	GetTurn(context.Context, string, string) (coop.Turn, error)
	ListTurns(context.Context, string, int64, int) ([]coop.Turn, error)
	GetOutputArtifact(context.Context, string, string, string) (coop.OutputArtifact, error)
	Events(context.Context, string, int64, int) ([]coop.Event, error)
	Changes(context.Context, string) (coop.Changes, error)
	Review(context.Context, string, string, int64) (coop.Review, coop.Operation, error)
	Cancel(context.Context, string, string, string, int64) (coop.Turn, coop.Operation, error)
	Extend(context.Context, string, string, int64, int) (coop.Session, coop.Operation, error)
	Close(context.Context, string, string, int64) (coop.Session, coop.Operation, error)
	PlanDiscard(context.Context, string, string, int64, bool, bool) (coop.DiscardPlan, coop.Operation, error)
	Discard(context.Context, string, string, string) (coop.Session, coop.Operation, error)
}

type Publication interface {
	Enabled() bool
	HeadBranch(core.Incident, core.Publication) (string, error)
	Publish(context.Context, publisher.Request) (publisher.Result, error)
	VerifyPublication(context.Context, core.Publication) error
}

type Emisar interface {
	WaitForRun(context.Context, string) (emisar.RunState, error)
	CreateRunbookDraft(context.Context, map[string]any) (emisar.DraftState, error)
}

// FixturePromotion writes the corrections an operator kept into the regression
// corpus on a schedule, so that keeping one is the last human step rather than
// the second-to-last.
//
// A port because the corpus is a file in a checkout and the fixture is built by
// the same code the promote-fixtures command runs: the coordinator's part is
// deciding that the maintenance sweep is the moment to try, and nothing else.
type FixturePromotion interface {
	PromoteApprovedFixtures(ctx context.Context, now time.Time) error
}

type Socket interface {
	Events() <-chan socketmode.Event
	Ack(socketmode.Request) error
	Run(context.Context) error
	Connected() bool
	SetConnected(bool)
}
