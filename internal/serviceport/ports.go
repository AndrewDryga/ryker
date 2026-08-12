// Package serviceport defines the external capabilities used by the service
// coordinator without owning any workflow policy.
package serviceport

import (
	"context"

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
	GetTurn(context.Context, string, string) (coop.Turn, error)
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
}

type Socket interface {
	Events() <-chan socketmode.Event
	Ack(socketmode.Request) error
	Run(context.Context) error
	Connected() bool
	SetConnected(bool)
}
