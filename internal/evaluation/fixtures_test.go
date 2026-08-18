package evaluation

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
)

func serviceConfig(t *testing.T) config.Config {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(root, "responder.yaml")
	body := `version: 1
state_dir: ` + filepath.Join(root, "state") + `
slack:
  team_id: T123ABC
  default_repository: repo
  operators: [U123ABC]
  invite_users: [U123ABC]
  watch_settle_delay: 0s
coop: {}
limits:
  engineering_task_creation_cooldown: 0s
repositories:
  repo:
    display_name: Repository
    coop_policy: repo-observe
    path: /srv/repos/repo
    contributor_policy: repo-contributor
webhooks:
  grafana:
    kind: grafana
    auth: bearer
    secret_env: GRAFANA_TOKEN
    repository: repo
`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

// fakeCoop is the evaluation harness's stand-in for a Coop server. It is the
// service package's fake trimmed to the surface these tests drive: session
// lifecycle, turn submission and completion, and the discard plan the harness
// insists on before it releases a workspace.
type fakeCoop struct {
	session          coop.Session
	turn             coop.Turn
	changes          coop.Changes
	events           []coop.Event
	createKeys       []string
	createPolicies   []string
	createErrors     []error
	prepareSessions  []string
	submitKeys       []string
	submitPrompts    []string
	submitTurns      []coop.Turn
	completeOnSubmit string
	completeQueue    []string
	discardCalls     int
}

func newFakeCoop() *fakeCoop {
	return &fakeCoop{session: coop.Session{
		ID: "ses_1", ForkName: "responder-api-unavailable",
		Revision: 1, State: "open", Activity: "parked", MaxTurns: 100,
	}}
}

func (f *fakeCoop) Ready(context.Context) error { return nil }

func (f *fakeCoop) CreateSession(
	_ context.Context,
	key, policy, _ string,
	_ ...coop.SessionSource,
) (coop.Session, coop.Operation, error) {
	f.createKeys = append(f.createKeys, key)
	f.createPolicies = append(f.createPolicies, policy)
	if len(f.createErrors) > 0 {
		err := f.createErrors[0]
		f.createErrors = f.createErrors[1:]
		return coop.Session{}, coop.Operation{}, err
	}
	if f.session.State == "closed" {
		f.session.State = "open"
		f.session.Activity = "parked"
	}
	return f.session, coop.Operation{}, nil
}

func (f *fakeCoop) ListSessions(context.Context, int) ([]coop.Session, error) {
	return nil, nil
}

func (f *fakeCoop) GetSession(context.Context, string) (coop.Session, error) {
	return f.session, nil
}

func (f *fakeCoop) OperationByKey(context.Context, string) (coop.Operation, error) {
	return coop.Operation{}, errors.New("operation not found")
}

func (f *fakeCoop) PrepareSession(
	_ context.Context, _, sessionID string, expectedRevision int64,
) (coop.Session, error) {
	f.prepareSessions = append(f.prepareSessions, sessionID)
	if expectedRevision != f.session.Revision {
		return coop.Session{}, &coop.APIError{Status: 409, Code: "revision_conflict"}
	}
	return f.session, nil
}

func (f *fakeCoop) SubmitTurn(
	_ context.Context, key, _ string, _ int64, prompt string,
) (coop.Turn, coop.Operation, error) {
	f.submitKeys = append(f.submitKeys, key)
	f.submitPrompts = append(f.submitPrompts, prompt)
	f.turn = coop.Turn{
		ID:        fmt.Sprintf("coop_turn_%d", len(f.submitKeys)),
		SessionID: f.session.ID,
		State:     "running",
	}
	f.session.ActiveTurnID = f.turn.ID
	f.session.Revision++
	if len(f.submitTurns) > 0 {
		scripted := f.submitTurns[0]
		f.submitTurns = f.submitTurns[1:]
		if scripted.ID == "" {
			scripted.ID = f.turn.ID
		}
		if scripted.SessionID == "" {
			scripted.SessionID = f.session.ID
		}
		f.turn = scripted
		if scripted.State == "completed" || scripted.State == "failed" ||
			scripted.State == "cancelled" {
			f.session.ActiveTurnID = ""
			f.session.Activity = "parked"
		}
		return f.turn, coop.Operation{}, nil
	}
	if f.completeOnSubmit != "" {
		f.complete(f.completeOnSubmit)
	} else if len(f.completeQueue) > 0 {
		message := f.completeQueue[0]
		f.completeQueue = f.completeQueue[1:]
		f.complete(message)
	}
	return f.turn, coop.Operation{}, nil
}

func (f *fakeCoop) SubmitTurnWithArtifacts(
	ctx context.Context,
	key string,
	sessionID string,
	revision int64,
	prompt string,
	_ []coop.InputArtifact,
) (coop.Turn, coop.Operation, error) {
	return f.SubmitTurn(ctx, key, sessionID, revision, prompt)
}

func (f *fakeCoop) SubmitTurnAtOrAbove(
	ctx context.Context,
	key string,
	sessionID string,
	revision int64,
	prompt string,
	_ []coop.InputArtifact,
	_ int,
) (coop.Turn, coop.Operation, error) {
	return f.SubmitTurn(ctx, key, sessionID, revision, prompt)
}

func (f *fakeCoop) GetTurn(context.Context, string, string) (coop.Turn, error) {
	if f.turn.ID == "" {
		return coop.Turn{}, errors.New("missing turn")
	}
	return f.turn, nil
}

func (f *fakeCoop) GetOutputArtifact(
	context.Context, string, string, string,
) (coop.OutputArtifact, error) {
	return coop.OutputArtifact{}, errors.New("missing output artifact")
}

func (f *fakeCoop) Events(
	_ context.Context, _ string, after int64, _ int,
) ([]coop.Event, error) {
	var result []coop.Event
	for _, event := range f.events {
		if event.Sequence > after {
			result = append(result, event)
		}
	}
	return result, nil
}

func (f *fakeCoop) Changes(context.Context, string) (coop.Changes, error) {
	return f.changes, nil
}

func (f *fakeCoop) Review(
	context.Context, string, string, int64,
) (coop.Review, coop.Operation, error) {
	return coop.Review{}, coop.Operation{}, nil
}

func (f *fakeCoop) Cancel(
	context.Context, string, string, string, int64,
) (coop.Turn, coop.Operation, error) {
	return f.turn, coop.Operation{}, nil
}

func (f *fakeCoop) Extend(
	_ context.Context, _ string, _ string, _ int64, additional int,
) (coop.Session, coop.Operation, error) {
	f.session.MaxTurns += additional
	f.session.Revision++
	f.session.State = "open"
	f.session.Activity = "parked"
	return f.session, coop.Operation{}, nil
}

func (f *fakeCoop) Close(
	context.Context, string, string, int64,
) (coop.Session, coop.Operation, error) {
	f.session.State = "closed"
	return f.session, coop.Operation{}, nil
}

func (f *fakeCoop) PlanDiscard(
	_ context.Context, _ string, _ string, _ int64, _ bool, acceptUnmerged bool,
) (coop.DiscardPlan, coop.Operation, error) {
	var plan coop.DiscardPlan
	plan.OperationID = "op_discard_plan"
	plan.Plan.SessionID = f.session.ID
	plan.Plan.Revision = f.session.Revision
	plan.Plan.Workspace.AcceptedUnmerged = acceptUnmerged
	return plan, coop.Operation{}, nil
}

func (f *fakeCoop) Discard(
	context.Context, string, string, string,
) (coop.Session, coop.Operation, error) {
	f.discardCalls++
	f.session.State = "discarded"
	return f.session, coop.Operation{}, nil
}

func (f *fakeCoop) complete(message string) {
	f.turn.State = "completed"
	f.turn.AssistantMessage = message
	f.session.ActiveTurnID = ""
	f.session.State = "open"
	f.session.Activity = "parked"
	f.session.Revision++
	sequence := int64(len(f.events) + 1)
	f.events = append(f.events, coop.Event{
		ID: fmt.Sprintf("evt_%d", sequence), SessionID: f.session.ID, Sequence: sequence,
		TurnID: f.turn.ID, Type: "turn.completed",
	})
}
