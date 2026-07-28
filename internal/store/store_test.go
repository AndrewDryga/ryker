package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
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
	if created, err := st.EnqueueOutbox(ctx, core.OutboxMessage{
		ID: "out_root", IncidentID: incident.ID, Kind: "root",
		ChannelID: "C123ABC", Body: body,
	}); err != nil || !created {
		t.Fatalf("enqueue root = %v, %v", created, err)
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
	first, created, err := st.CreateManualIncident(
		ctx, "repo", "Ev123", "Manual", "Manual summary", "U123ABC", "CSUMMON", "1700.1", 100,
	)
	if err != nil || !created {
		t.Fatalf("manual first = %+v, %v, %v", first, created, err)
	}
	signals, err := st.ListSignals(ctx, first.ID)
	if err != nil || len(signals) != 1 ||
		signals[0].Summary != "Manual summary" ||
		signals[0].Labels["slack_origin_channel"] != "CSUMMON" ||
		signals[0].Labels["slack_origin_thread"] != "1700.1" {
		t.Fatalf("manual Slack origin = %+v, %v", signals, err)
	}
	second, created, err := st.CreateManualIncident(
		ctx, "repo", "Ev123", "Manual", "Manual summary", "U123ABC", "CSUMMON", "1700.1", 100,
	)
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

func TestEngineeringTaskIsDistinctAndIdempotent(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	first, created, err := st.CreateEngineeringTask(
		ctx, "repo", "EvTask", "Audit infrastructure packs",
		"Update infra/ to install every required pack.", "U123ABC",
		"COPS", "1700.2", 100,
	)
	if err != nil || !created || !first.IsEngineeringTask() {
		t.Fatalf("engineering task first = %+v, %v, %v", first, created, err)
	}
	if !first.IsThreadScoped() ||
		first.WorkKind != core.WorkKindEngineeringTask ||
		first.WorkScope != core.WorkScopeThread ||
		first.OriginChannelID != "COPS" ||
		first.OriginThreadTS != "1700.2" ||
		first.ConversationThreadTS() != "1700.2" {
		t.Fatalf("engineering task scope = %+v", first)
	}
	signals, err := st.ListSignals(ctx, first.ID)
	if err != nil || len(signals) != 1 ||
		signals[0].Labels["work_kind"] != "engineering_task" ||
		signals[0].Labels["slack_origin_channel"] != "COPS" {
		t.Fatalf("engineering task source = %+v, %v", signals, err)
	}
	second, created, err := st.CreateEngineeringTask(
		ctx, "repo", "EvTask", "Audit infrastructure packs",
		"Update infra/ to install every required pack.", "U123ABC",
		"COPS", "1700.2", 100,
	)
	if err != nil || created || second.ID != first.ID || !second.IsEngineeringTask() {
		t.Fatalf("engineering task duplicate = %+v, %v, %v", second, created, err)
	}
}

func TestSlackInputsAreLeasedInOrderPerChannel(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	inputs := []core.SlackInput{
		{
			ID: "slack-a2", EnvelopeID: "env-a2", EventID: "event-a2",
			Kind: "message", TeamID: "T1", ChannelID: "CA", MessageTS: "1700000000.000002",
			UserID: "U1", Text: "second A", ReceivedAt: now.Add(time.Second),
		},
		{
			ID: "slack-a1", EnvelopeID: "env-a1", EventID: "event-a1",
			Kind: "message", TeamID: "T1", ChannelID: "CA", MessageTS: "1700000000.000001",
			UserID: "U1", Text: "first A", ReceivedAt: now,
		},
		{
			ID: "slack-b1", EnvelopeID: "env-b1", EventID: "event-b1",
			Kind: "message", TeamID: "T1", ChannelID: "CB", MessageTS: "1700000000.000003",
			UserID: "U1", Text: "first B", ReceivedAt: now.Add(2 * time.Second),
		},
	}
	for _, input := range inputs {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", input.ID, created, err)
		}
	}
	first, err := st.LeaseSlackInput(ctx)
	if err != nil || first.ID != "slack-a1" {
		t.Fatalf("first lease = %+v, %v", first, err)
	}
	if err := st.RetrySlackInput(ctx, first.ID, "still running", time.Now().Add(time.Hour), false); err != nil {
		t.Fatal(err)
	}
	second, err := st.LeaseSlackInput(ctx)
	if err != nil || second.ID != "slack-b1" {
		t.Fatalf("independent channel lease = %+v, %v", second, err)
	}
	if err := st.FinishSlackInput(ctx, second.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, ErrNotFound) {
		t.Fatalf("later input overtook retrying channel predecessor: %v", err)
	}
}

func TestRecentWatchContextIsBoundedChronologicalAndTracksNewerDecisions(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	for i := 1; i <= 25; i++ {
		input := core.SlackInput{
			ID:         fmt.Sprintf("slack-context-%02d", i),
			EnvelopeID: fmt.Sprintf("env-context-%02d", i),
			EventID:    fmt.Sprintf("event-context-%02d", i),
			Kind:       "message",
			TeamID:     "T1",
			ChannelID:  "CA",
			MessageTS:  fmt.Sprintf("1700000000.%06d", i),
			UserID:     fmt.Sprintf("U%d", i%3),
			Text:       fmt.Sprintf("message %02d", i),
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %d = %v, %v", i, created, err)
		}
	}
	if created, err := st.AdmitSlackInput(ctx, core.SlackInput{
		ID: "slack-command", EnvelopeID: "env-command", EventID: "event-command",
		Kind: "slash", TeamID: "T1", ChannelID: "CA", MessageTS: "1700000000.999999",
		UserID: "U1", Text: "status",
	}); err != nil || !created {
		t.Fatalf("admit command = %v, %v", created, err)
	}
	recent, err := st.ListRecentWatchMessages(ctx, "CA", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(recent) != 20 || recent[0].Text != "message 06" ||
		recent[19].Text != "message 25" {
		t.Fatalf("recent context = %+v", recent)
	}
	for i := 1; i < len(recent); i++ {
		if recent[i-1].MessageTS >= recent[i].MessageTS {
			t.Fatalf("context is not chronological: %+v", recent)
		}
	}
	newer, err := st.HasNewerWatchDecision(ctx, "CA", "1700000000.000024")
	if err != nil || newer {
		t.Fatalf("decision existed before audit = %v, %v", newer, err)
	}
	if err := st.Audit(ctx, core.AuditEvent{
		Kind: "slack.watch", ObjectID: "slack-context-25", Outcome: "ignored",
	}); err != nil {
		t.Fatal(err)
	}
	newer, err = st.HasNewerWatchDecision(ctx, "CA", "1700000000.000024")
	if err != nil || !newer {
		t.Fatalf("newer decision = %v, %v", newer, err)
	}
}

func TestSlackControlsCanOvertakeRunningChannelConversation(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	for _, input := range []core.SlackInput{
		{
			ID: "slack-message", EnvelopeID: "env-message", EventID: "event-message",
			Kind: "message", TeamID: "T1", ChannelID: "CA", MessageTS: "1",
			UserID: "U1", Text: "alert",
		},
		{
			ID: "slack-slash", EnvelopeID: "env-slash", EventID: "event-slash",
			Kind: "slash", TeamID: "T1", ChannelID: "CA",
			UserID: "U1", Text: "proactive off",
		},
	} {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", input.ID, created, err)
		}
	}
	first, err := st.LeaseSlackInput(ctx)
	if err != nil || first.ID != "slack-slash" {
		t.Fatalf("priority lease = %+v, %v", first, err)
	}
	if err := st.FinishSlackInput(ctx, first.ID); err != nil {
		t.Fatal(err)
	}
	second, err := st.LeaseSlackInput(ctx)
	if err != nil || second.ID != "slack-message" {
		t.Fatalf("conversation after control = %+v, %v", second, err)
	}
}

func TestSlackSettingsLifecycle(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.SetSlackSetting(ctx, "global", "", "proactive", "on", "U1"); err != nil {
		t.Fatal(err)
	}
	setting, err := st.GetSlackSetting(ctx, "global", "", "proactive")
	if err != nil || setting.Value != "on" || setting.ActorID != "U1" {
		t.Fatalf("global setting = %+v, %v", setting, err)
	}
	if err := st.SetSlackSetting(ctx, "channel", "C1", "proactive", "off", "U2"); err != nil {
		t.Fatal(err)
	}
	setting, err = st.GetSlackSetting(ctx, "channel", "C1", "proactive")
	if err != nil || setting.Value != "off" || setting.ActorID != "U2" {
		t.Fatalf("channel setting = %+v, %v", setting, err)
	}
	if err := st.DeleteSlackSetting(ctx, "channel", "C1", "proactive"); err != nil {
		t.Fatal(err)
	}
	if _, err := st.GetSlackSetting(ctx, "channel", "C1", "proactive"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deleted setting = %v", err)
	}
	for _, invalid := range []struct {
		scope, channel string
	}{
		{scope: "workspace"},
		{scope: "global", channel: "C1"},
		{scope: "channel"},
	} {
		if err := st.SetSlackSetting(
			ctx, invalid.scope, invalid.channel, "proactive", "on", "U1",
		); err == nil {
			t.Fatalf("invalid setting accepted: %+v", invalid)
		}
	}
}

func TestSchemaV1MigratesSlackSettings(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(schemaV1); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO schema_version(version) VALUES (1)`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.SetSlackSetting(
		context.Background(), "global", "", "proactive", "on", "U1",
	); err != nil {
		t.Fatalf("migrated settings table: %v", err)
	}
}

func TestSchemaV2MigratesIncidentChannelLifecycle(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(schemaV1 + schemaV2); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Format(timestampFormat)
	if _, err := db.Exec(`
		INSERT INTO schema_version(version) VALUES (2);
		INSERT INTO incidents
		  (id, route, repository, correlation_key, title, status, workflow,
		   channel_id, channel_name, created_at, updated_at)
		VALUES ('inc_existing', 'grafana', 'repo', 'existing', 'Existing',
		        'active', 'parked', 'CEXISTING', 'ems-existing', ?, ?)`,
		now, now,
	); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident, err := st.GetIncident(context.Background(), "inc_existing")
	if err != nil {
		t.Fatal(err)
	}
	if incident.ChannelState != core.ChannelActive ||
		incident.ChannelStateChangedAt.IsZero() ||
		incident.ChannelCheckedAt.IsZero() {
		t.Fatalf("migrated channel lifecycle = %+v", incident)
	}
}

func TestSchemaV4MigratesEngineeringTaskScopeWithoutMovingBoundRooms(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(schemaV1 + schemaV2 + schemaV3 + schemaV4); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Format(timestampFormat)
	if _, err := db.Exec(`
		INSERT INTO schema_version(version) VALUES (4);
		INSERT INTO incidents
		  (id, route, repository, correlation_key, source_incident_id, title, status,
		   workflow, created_at, updated_at)
		VALUES ('inc_pending_task', 'manual', 'repo', 'manual:task:pending',
		        'task:pending', 'Pending task', 'active', 'provisioning_channel', ?, ?);
		INSERT INTO signals
		  (route, source_id, incident_id, event_id, repository, correlation_key, status,
		   title, labels_json, received_at, updated_at)
		VALUES ('manual', 'task:pending', 'inc_pending_task', 'pending', 'repo',
		        'manual:task:pending', 'firing', 'Pending task',
		        '{"slack_origin_channel":"CSOURCE","slack_origin_thread":"1700.1"}', ?, ?);

		INSERT INTO incidents
		  (id, route, repository, correlation_key, source_incident_id, title, status,
		   workflow, channel_id, channel_name, root_ts, coop_session_id, created_at, updated_at)
		VALUES ('inc_bound_task', 'manual', 'repo', 'manual:task:bound',
		        'task:bound', 'Bound task', 'active', 'parked', 'COLDROOM',
		        'old-room', '1700.2', 'ses_old', ?, ?);
		INSERT INTO signals
		  (route, source_id, incident_id, event_id, repository, correlation_key, status,
		   title, labels_json, received_at, updated_at)
		VALUES ('manual', 'task:bound', 'inc_bound_task', 'bound', 'repo',
		        'manual:task:bound', 'firing', 'Bound task',
		        '{"slack_origin_channel":"CSOURCE","slack_origin_thread":"1700.3"}', ?, ?);
	`, now, now, now, now, now, now, now, now); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	pending, err := st.GetIncident(context.Background(), "inc_pending_task")
	if err != nil {
		t.Fatal(err)
	}
	if !pending.IsEngineeringTask() || !pending.IsThreadScoped() ||
		pending.OriginChannelID != "CSOURCE" || pending.OriginThreadTS != "1700.1" {
		t.Fatalf("pending migrated task = %+v", pending)
	}
	bound, err := st.GetIncident(context.Background(), "inc_bound_task")
	if err != nil {
		t.Fatal(err)
	}
	if !bound.IsEngineeringTask() || bound.IsThreadScoped() ||
		bound.WorkScope != core.WorkScopeRoom || bound.ChannelID != "COLDROOM" {
		t.Fatalf("bound migrated task = %+v", bound)
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
		INSERT INTO schema_version(version) VALUES (7);
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

func TestIncidentChannelLifecycleBlocksAndRestoresOpenIncident(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incidents, err := st.ApplySignals(ctx, testWebhookEvent(), time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("create incident = %+v, %v", incidents, err)
	}
	incident := incidents[0]
	if err := st.SetChannel(ctx, incident.ID, "C123ABC", "ems-test"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incident.ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "fork-1", 1); err != nil {
		t.Fatal(err)
	}
	changed := time.Now().UTC().Add(time.Second)
	updated, err := st.SetIncidentChannelState(
		ctx, "C123ABC", core.ChannelArchived, changed,
	)
	if err != nil || len(updated) != 1 {
		t.Fatalf("archive = %+v, %v", updated, err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if incident.ChannelState != core.ChannelArchived ||
		incident.Workflow != core.WorkflowBlocked ||
		!strings.Contains(incident.LastError, "was archived") ||
		incident.ChannelStateChangedAt.Before(changed) {
		t.Fatalf("archived incident = %+v", incident)
	}
	dirty, err := st.ListDirtyCards(ctx, 10)
	if err != nil || len(dirty) != 0 {
		t.Fatalf("archived dirty cards = %+v, %v", dirty, err)
	}
	if _, err := st.SetIncidentChannelState(
		ctx, "C123ABC", core.ChannelActive, changed.Add(-time.Second),
	); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if incident.ChannelState != core.ChannelArchived {
		t.Fatalf("stale lifecycle event regressed channel state: %+v", incident)
	}
	if _, err := st.SetIncidentChannelState(
		ctx, "C123ABC", core.ChannelActive, changed.Add(time.Second),
	); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if incident.ChannelState != core.ChannelActive ||
		incident.Workflow != core.WorkflowParked ||
		incident.LastError != "" {
		t.Fatalf("restored incident = %+v", incident)
	}
	if _, err := st.SetIncidentChannelState(
		ctx, "C123ABC", core.ChannelDeleted, changed.Add(2*time.Second),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.SetIncidentChannelState(
		ctx, "C123ABC", core.ChannelActive, changed.Add(3*time.Second),
	); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if incident.ChannelState != core.ChannelDeleted {
		t.Fatalf("deleted channel was revived by lifecycle event: %+v", incident)
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
		ctx, "repo", "manual-1", "Manual", "Manual", "U123ABC", "CSUMMON", "1700.1", 1,
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

func TestListIncidentPageFiltersAndPaginates(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	ids := make([]string, 0, 3)
	for index := 0; index < 3; index++ {
		event := testWebhookEvent()
		event.Signals[0].SourceID = fmt.Sprintf("alert-page-%d", index)
		event.Signals[0].EventID = fmt.Sprintf("event-page-%d", index)
		event.Signals[0].CorrelationKey = fmt.Sprintf("cluster-page-%d", index)
		incidents, err := st.ApplySignals(ctx, event, time.Hour, 0, 100)
		if err != nil || len(incidents) != 1 {
			t.Fatalf("create incident %d = %+v, %v", index, incidents, err)
		}
		ids = append(ids, incidents[0].ID)
	}
	if err := st.CloseIncident(ctx, ids[0]); err != nil {
		t.Fatal(err)
	}
	open, total, err := st.ListIncidentPage(ctx, true, 1, 0)
	if err != nil || total != 2 || len(open) != 1 ||
		open[0].Status == core.IncidentClosed {
		t.Fatalf("open incident page = %+v, total %d, %v", open, total, err)
	}
	all, total, err := st.ListIncidentPage(ctx, false, 2, 1)
	if err != nil || total != 3 || len(all) != 2 {
		t.Fatalf("all incident page = %+v, total %d, %v", all, total, err)
	}
	if _, _, err := st.ListIncidentPage(ctx, false, 0, 0); err == nil {
		t.Fatal("invalid incident page limit was accepted")
	}
	if _, _, err := st.ListIncidentPage(ctx, false, 10, -1); err == nil {
		t.Fatal("invalid incident page offset was accepted")
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
