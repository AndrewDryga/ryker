package incidentrun

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/sessionauthority"
)

type authorityTestSessions struct{ session coop.Session }

func (f authorityTestSessions) ListTurns(context.Context, string, int64, int) ([]coop.Turn, error) {
	return nil, nil
}
func (f authorityTestSessions) Cancel(context.Context, string, string, string, int64) (coop.Turn, coop.Operation, error) {
	return coop.Turn{}, coop.Operation{}, nil
}
func (f authorityTestSessions) GetSession(context.Context, string) (coop.Session, error) {
	return f.session, nil
}
func (f authorityTestSessions) GetTurn(context.Context, string, string) (coop.Turn, error) {
	return coop.Turn{}, nil
}

type failingAuthorityStore struct{ err error }

func (f failingAuthorityStore) RotateReadOnly(context.Context, string, string, int, string, time.Time) (bool, error) {
	return false, f.err
}
func (f failingAuthorityStore) AdvanceAgentRunGeneration(context.Context, string, int, time.Time) error {
	return nil
}

type unusedBranches struct{}

func (unusedBranches) Session(context.Context, core.AgentRun, core.Incident) (coop.Session, int, error) {
	return coop.Session{}, 0, errors.New("branch path was not expected")
}

// A transient store error during authority rotation used to escape as an
// ordinary terminal error. The submission worker then discarded accepted work
// before any model turn started instead of preserving it for convergence.
func TestRotationStoreFailuresRemainAuthorityConvergence(t *testing.T) {
	storeErr := errors.New("database is temporarily busy")
	_, _, _, err := ResolveSession(
		context.Background(),
		core.AgentRun{ID: "run_1"},
		core.Incident{
			ID: "inc_1", CoopSessionID: "ses_1", CoopSessionGeneration: 1,
		},
		authorityTestSessions{session: coop.Session{
			ID: "ses_1", State: "open", RepositoryReadOnly: false,
		}},
		unusedBranches{}, failingAuthorityStore{err: storeErr}, time.Now().UTC(),
	)
	if !errors.Is(err, sessionauthority.ErrConvergence) || !errors.Is(err, storeErr) {
		t.Fatalf("rotation error = %v; want authority convergence preserving store cause", err)
	}
}
