package store

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestIncidentOutboxAndTurnLifecycle(t *testing.T) {
	ctx := context.Background()
	stateDir := filepath.Join(t.TempDir(), "state")
	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.Check(ctx); err != nil {
		t.Fatal(err)
	}
	event := testWebhookEvent()
	admitted, created, err := st.AdmitWebhook(ctx, event.Route, event.DedupeKey, event.BodyDigest, event.Signals)
	if err != nil || !created {
		t.Fatalf("admit = %+v, %v, %v", admitted, created, err)
	}
	leased, err := st.LeaseWebhook(ctx)
	if err != nil {
		t.Fatal(err)
	}
	incidents, err := st.ApplySignals(ctx, leased, time.Hour, time.Minute, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("apply = %+v, %v", incidents, err)
	}
	incident := incidents[0]

	// Replaying an interrupted durable webhook retains exactly the incident IDs
	// whose deterministic downstream work still needs reconciliation.
	if err := st.RetryWebhook(ctx, leased.ID, "simulated crash", time.Now(), false); err != nil {
		t.Fatal(err)
	}
	replayed, err := st.LeaseWebhook(ctx)
	if err != nil || !replayed.Applied || len(replayed.IncidentIDs) != 1 ||
		replayed.IncidentIDs[0] != incident.ID {
		t.Fatalf("replay = %+v, %v", replayed, err)
	}
	if err := st.SetChannel(ctx, incident.ID, "C123ABC", "inc-test"); err != nil {
		t.Fatal(err)
	}
	body := []byte(`{"text":"root"}`)
	if _, err := st.EnqueueOutbox(ctx, core.OutboxMessage{
		ID: "out_root", IncidentID: incident.ID, Kind: "root",
		ChannelID: "C123ABC", Body: body,
	}); err != nil {
		t.Fatal(err)
	}
	outbox, err := st.LeaseOutbox(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishOutbox(ctx, outbox.ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.RootTS != "1700.001" ||
		incident.Workflow != core.WorkflowProvisioningSession {
		t.Fatalf("root binding = %+v, %v", incident, err)
	}

	queued, created, err := st.QueueTurn(ctx, core.TurnSubmission{
		IncidentID: incident.ID, SourceKind: "initial", SourceID: incident.ID, Prompt: "investigate",
	})
	if err != nil || !created {
		t.Fatalf("queue turn = %+v, %v, %v", queued, created, err)
	}
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api-latency", 1); err != nil {
		t.Fatal(err)
	}
	leasedTurn, err := st.LeaseTurnSubmission(ctx)
	if err != nil {
		t.Fatal(err)
	}
	revision, err := st.FreezeTurnRevision(ctx, leasedTurn.ID, 1)
	if err != nil || revision != 1 {
		t.Fatalf("freeze revision = %d, %v", revision, err)
	}
	if err := st.MarkTurnSubmitted(ctx, leasedTurn.ID, "coop_turn_1", 2); err != nil {
		t.Fatal(err)
	}
	completed, err := st.CompleteTurnSubmission(ctx, "coop_turn_1", "completed", "")
	if err != nil || completed.ID != leasedTurn.ID {
		t.Fatalf("complete = %+v, %v", completed, err)
	}
	incident, _ = st.GetIncident(ctx, incident.ID)
	if incident.ActiveTurnID != "" || incident.Workflow != core.WorkflowParked {
		t.Fatalf("terminal incident = %+v", incident)
	}

	owner, mode, err := FileOwner(filepath.Join(stateDir, "responder.db"))
	if err != nil || owner != uint32(os.Getuid()) || mode != 0o600 {
		t.Fatalf("database ownership/mode = %d %o, %v", owner, mode, err)
	}
}

func TestRecoveryAndManualIncidentDeduplication(t *testing.T) {
	ctx := context.Background()
	stateDir := filepath.Join(t.TempDir(), "state")
	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	event := testWebhookEvent()
	if _, _, err := st.AdmitWebhook(ctx, event.Route, event.DedupeKey, event.BodyDigest, event.Signals); err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseWebhook(ctx); err != nil {
		t.Fatal(err)
	}
	first, created, err := st.CreateManualIncident(ctx, "repo", "Ev123", "Manual", "U123ABC", 100)
	if err != nil || !created {
		t.Fatalf("manual first = %+v, %v, %v", first, created, err)
	}
	second, created, err := st.CreateManualIncident(ctx, "repo", "Ev123", "Manual", "U123ABC", 100)
	if err != nil || created || second.ID != first.ID {
		t.Fatalf("manual duplicate = %+v, %v, %v", second, created, err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	st, err = Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.LeaseWebhook(ctx); !errors.Is(err, ErrNotFound) {
		t.Fatalf("ordinary open recovered live work: %v", err)
	}
	if err := st.RecoverInterrupted(ctx); err != nil {
		t.Fatal(err)
	}
	recovered, err := st.LeaseWebhook(ctx)
	if err != nil || recovered.Attempts != 2 {
		t.Fatalf("recovered webhook = %+v, %v", recovered, err)
	}
}

func TestNewerSchemaIsRejectedWithoutMutation(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(stateDir, "responder.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		CREATE TABLE schema_version (version INTEGER NOT NULL);
		INSERT INTO schema_version(version) VALUES (2);
		CREATE TABLE future_state (value TEXT NOT NULL);
		INSERT INTO future_state(value) VALUES ('preserve-me');
	`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if st, err := Open(stateDir); err == nil {
		st.Close()
		t.Fatal("newer schema unexpectedly opened")
	}
	db, err = sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var value string
	if err := db.QueryRow(`SELECT value FROM future_state`).Scan(&value); err != nil || value != "preserve-me" {
		t.Fatalf("future state changed: %q, %v", value, err)
	}
	var incidentsTable int
	if err := db.QueryRow(`
		SELECT count(*) FROM sqlite_master
		WHERE type = 'table' AND name = 'incidents'`).Scan(&incidentsTable); err != nil {
		t.Fatal(err)
	}
	if incidentsTable != 0 {
		t.Fatal("older binary applied its schema before rejecting future state")
	}
}

func TestOpenCurrentDoesNotCreateOrWriteDatabase(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if st, err := OpenCurrent(stateDir); err == nil {
		st.Close()
		t.Fatal("inspection unexpectedly created a database")
	}
	if _, err := os.Stat(filepath.Join(stateDir, "responder.db")); !os.IsNotExist(err) {
		t.Fatalf("inspection database stat = %v", err)
	}

	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	st, err = OpenCurrent(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.db.Exec(`CREATE TABLE inspection_must_not_write(value TEXT)`); err == nil {
		t.Fatal("inspection connection accepted a write")
	}
}

func TestOpenIncidentCapacityRollsBackNewOccurrences(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	first := testWebhookEvent()
	if incidents, err := st.ApplySignals(ctx, first, time.Hour, 0, 1); err != nil || len(incidents) != 1 {
		t.Fatalf("first incident = %+v, %v", incidents, err)
	}
	second := testWebhookEvent()
	second.Signals[0].SourceID = "alert-2"
	second.Signals[0].EventID = "event-2"
	second.Signals[0].CorrelationKey = "cluster-b"
	if _, err := st.ApplySignals(ctx, second, time.Hour, 0, 1); !errors.Is(err, ErrCapacity) {
		t.Fatalf("second incident capacity error = %v", err)
	}
	if _, _, err := st.CreateManualIncident(
		ctx, "repo", "manual-1", "Manual", "U123ABC", 1,
	); !errors.Is(err, ErrCapacity) {
		t.Fatalf("manual incident capacity error = %v", err)
	}
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incidents after capacity rejection = %+v, %v", incidents, err)
	}
}

func TestCapacityDoesNotRollBackExistingSignalsInMixedBatch(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	first := testWebhookEvent()
	incidents, err := st.ApplySignals(ctx, first, time.Hour, 0, 1)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("first incident = %+v, %v", incidents, err)
	}
	mixed := testWebhookEvent()
	mixed.Signals[0].EventID = "event-resolved"
	mixed.Signals[0].Status = core.SignalResolved
	newSignal := mixed.Signals[0]
	newSignal.SourceID = "alert-2"
	newSignal.EventID = "event-new"
	newSignal.Status = core.SignalFiring
	newSignal.CorrelationKey = "cluster-b"
	mixed.Signals = append(mixed.Signals, newSignal)
	affected, err := st.ApplySignals(ctx, mixed, time.Hour, 0, 1)
	if !errors.Is(err, ErrCapacity) || len(affected) != 1 ||
		affected[0].ID != incidents[0].ID {
		t.Fatalf("mixed batch = %+v, %v", affected, err)
	}
	updated, err := st.GetIncident(ctx, incidents[0].ID)
	if err != nil || updated.Status != core.IncidentResolved {
		t.Fatalf("existing incident update was rolled back: %+v, %v", updated, err)
	}
	all, err := st.ListIncidents(ctx, 10)
	if err != nil || len(all) != 1 {
		t.Fatalf("capacity created an extra incident: %+v, %v", all, err)
	}
}

func TestFiringAlertAfterClosedIncidentCreatesNewOccurrence(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	event := testWebhookEvent()
	first, err := st.ApplySignals(ctx, event, time.Hour, 0, 100)
	if err != nil || len(first) != 1 {
		t.Fatalf("first occurrence = %+v, %v", first, err)
	}
	if err := st.CloseIncident(ctx, first[0].ID); err != nil {
		t.Fatal(err)
	}
	event.Signals[0].EventID = "event-2"
	event.Signals[0].ReceivedAt = time.Now().UTC().Add(time.Second)
	second, err := st.ApplySignals(ctx, event, time.Hour, 0, 100)
	if err != nil || len(second) != 1 || second[0].ID == first[0].ID {
		t.Fatalf("second occurrence = %+v, %v; first = %s", second, err, first[0].ID)
	}
	closed, err := st.GetIncident(ctx, first[0].ID)
	if err != nil || closed.Status != core.IncidentClosed {
		t.Fatalf("closed occurrence changed = %+v, %v", closed, err)
	}
}

func TestUnchangedSignalDeliveryDoesNotCreateDuplicateWork(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	event := testWebhookEvent()
	first, err := st.ApplySignals(ctx, event, time.Hour, 0, 100)
	if err != nil || len(first) != 1 {
		t.Fatalf("first delivery = %+v, %v", first, err)
	}
	unchanged, err := st.ApplySignals(ctx, event, time.Hour, 0, 100)
	if err != nil || len(unchanged) != 0 {
		t.Fatalf("unchanged delivery created work = %+v, %v", unchanged, err)
	}
	event.Signals[0].EventID = "event-materially-changed"
	changed, err := st.ApplySignals(ctx, event, time.Hour, 0, 100)
	if err != nil || len(changed) != 1 || changed[0].ID != first[0].ID {
		t.Fatalf("changed delivery = %+v, %v", changed, err)
	}
}

func TestFailedWorkCanBeInspectedAndExplicitlyRetried(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	event := testWebhookEvent()
	admitted, _, err := st.AdmitWebhook(
		ctx, event.Route, event.DedupeKey, event.BodyDigest, event.Signals,
	)
	if err != nil {
		t.Fatal(err)
	}
	leasedWebhook, err := st.LeaseWebhook(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.RetryWebhook(ctx, leasedWebhook.ID, "route temporarily unavailable", time.Now(), true); err != nil {
		t.Fatal(err)
	}

	incident, err := st.ApplySignals(ctx, event, time.Hour, 0, 100)
	if err != nil || len(incident) != 1 {
		t.Fatalf("incident = %+v, %v", incident, err)
	}
	if _, err := st.EnqueueOutbox(ctx, core.OutboxMessage{
		ID: "out_failed", IncidentID: incident[0].ID, Kind: "notice",
		ChannelID: "C123ABC", Body: []byte(`{"text":"notice"}`),
	}); err != nil {
		t.Fatal(err)
	}
	leasedOutbox, err := st.LeaseOutbox(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.RetryOutbox(ctx, leasedOutbox.ID, "invalid Slack payload", time.Now(), false, true); err != nil {
		t.Fatal(err)
	}

	failures, err := st.ListFailedWork(ctx, 50)
	if err != nil || len(failures) != 2 {
		t.Fatalf("failures = %+v, %v", failures, err)
	}
	retried, err := st.RetryFailedWork(ctx, "webhook", admitted.ID)
	if err != nil {
		t.Fatal(err)
	}
	if retried.LastError != "route temporarily unavailable" || retried.Attempts != 1 {
		t.Fatalf("retried snapshot = %+v", retried)
	}
	replayed, err := st.LeaseWebhook(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if replayed.ID != admitted.ID || replayed.Attempts != 1 {
		t.Fatalf("replayed webhook = %+v", replayed)
	}
	if _, err := st.RetryFailedWork(ctx, "webhook", admitted.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("non-failed retry = %v", err)
	}
	if _, err := st.RetryFailedWork(ctx, "outbox", leasedOutbox.ID); err != nil {
		t.Fatal(err)
	}
	uncertain, err := st.ListUncertainOutbox(ctx, 10)
	if err != nil || len(uncertain) != 1 || uncertain[0].ID != leasedOutbox.ID {
		t.Fatalf("retried outbox skipped reconciliation = %+v, %v", uncertain, err)
	}
	if _, err := st.RetryFailedWork(ctx, "unknown", admitted.ID); err == nil {
		t.Fatal("unknown work kind accepted")
	}
}

func TestTerminalCoopTurnCannotBeRetried(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	event := testWebhookEvent()
	incidents, err := st.ApplySignals(ctx, event, time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incidents = %+v, %v", incidents, err)
	}
	incident := incidents[0]
	if err := st.SetChannel(ctx, incident.ID, "C123ABC", "inc-test"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incident.ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "fork-1", 1); err != nil {
		t.Fatal(err)
	}
	queued, _, err := st.QueueTurn(ctx, core.TurnSubmission{
		IncidentID: incident.ID, SourceKind: "slack", SourceID: "slack-1", Prompt: "investigate",
	})
	if err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseTurnSubmission(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.MarkTurnSubmitted(ctx, leased.ID, "coop_turn_1", 2); err != nil {
		t.Fatal(err)
	}
	if _, err := st.CompleteTurnSubmission(ctx, "coop_turn_1", "failed", "agent failed"); err != nil {
		t.Fatal(err)
	}
	failures, err := st.ListFailedWork(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	var found bool
	for _, failure := range failures {
		if failure.ID == queued.ID {
			found = true
			if failure.Retryable {
				t.Fatalf("terminal Coop turn shown as retryable: %+v", failure)
			}
		}
	}
	if !found {
		t.Fatal("terminal Coop turn missing from failure inspection")
	}
	if _, err := st.RetryFailedWork(ctx, "turn", queued.ID); err == nil {
		t.Fatal("terminal Coop turn was requeued")
	}
}

func testWebhookEvent() core.WebhookEvent {
	now := time.Now().UTC()
	return core.WebhookEvent{
		Route: "grafana", DedupeKey: "delivery-1", BodyDigest: "digest",
		Signals: []core.Signal{{
			Route: "grafana", SourceID: "alert-1", EventID: "event-1",
			Repository: "repo", CorrelationKey: "cluster-a", Status: core.SignalFiring,
			Title: "API latency", Severity: "critical", ReceivedAt: now,
		}},
	}
}
