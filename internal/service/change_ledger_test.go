package service

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/emisar"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// approvalReachingStatus drives one approval to a terminal Emisar status
// through the real monitor, which is the only path that writes the ledger.
func approvalReachingStatus(
	t *testing.T,
	ctx context.Context,
	st *store.Store,
	cfg config.Config,
	incidentID string,
	requestID string,
	status string,
) {
	t.Helper()
	approval, _, err := st.Approvals.Record(ctx, core.EmisarApproval{
		RequestID: requestID, IncidentID: incidentID, ChannelID: "CINCIDENT",
		SourceInput: "slack_" + requestID, RequestedBy: "U123ABC",
		RunID: "run_" + requestID, OperationID: "op_" + requestID,
		ActionID: "service.enable", PackRef: "service@1#sha256:abc",
		RunnerRef: "prod~abc", Status: "pending_approval",
		MessageTS:   "1700.500",
		ApprovalURL: "https://emisar.dev/app/acme/approvals/" + requestID,
		ExpiresAt:   time.Now().UTC().Add(time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.SetEmisar(&fakeEmisar{state: emisar.RunState{
		RunID: approval.RunID, OperationID: approval.OperationID,
		ActionID: approval.ActionID, PackRef: approval.PackRef,
		RunnerRef: approval.RunnerRef, Status: status,
		RunURL: "https://emisar.dev/app/acme/runs/" + approval.RunID,
	}})
	if err := svc.processEmisarApproval(ctx, approval.RequestID); err != nil {
		t.Fatalf("process %s: %v", requestID, err)
	}
}

// A mutation Responder itself supervised to terminal success is a change, and
// the ledger is the only place that fact survives the approval row.
//
// emisar_approvals expires on the operational horizon, so without this write
// the single most authoritative change Responder can possibly know about — one
// it requested, watched to terminal state, and holds an immutable run reference
// for — is the one it forgets first. A failed run is not a change and must not
// be recorded: listing an action that changed nothing under "what changed"
// sends an operator to check something that never happened.
func TestOnlyASuccessfulSupervisedRunReachesTheChangeLedger(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)

	approvalReachingStatus(t, ctx, st, cfg, incident.ID, "apr_ok", "success")
	approvalReachingStatus(t, ctx, st, cfg, incident.ID, "apr_bad", "failed")

	changes, err := st.Changes.Recent(ctx, time.Now().UTC().Add(-time.Hour), 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(changes) != 1 {
		t.Fatalf("the ledger holds %d changes, want only the successful run: %+v",
			len(changes), changes)
	}
	change := changes[0]
	if change.Source != "emisar" || change.Kind != "config" {
		t.Errorf("source/kind = %q/%q, want emisar/config", change.Source, change.Kind)
	}
	// Immutable references only, per the Emisar client discipline: the run is
	// the identity, the operation is the revision, and the run URL is the
	// same-origin permalink an operator opens to check the claim.
	if change.SourceIdentity != "run_apr_ok" {
		t.Errorf("identity = %q, want the Emisar run id", change.SourceIdentity)
	}
	if change.Revision != "op_apr_ok" {
		t.Errorf("revision = %q, want the Emisar operation id", change.Revision)
	}
	if change.SourceRef != "https://emisar.dev/app/acme/runs/run_apr_ok" {
		t.Errorf("source_ref = %q, want the run permalink", change.SourceRef)
	}
	if change.Actor != "U123ABC" {
		t.Errorf("actor = %q, want whoever requested the action", change.Actor)
	}
}
