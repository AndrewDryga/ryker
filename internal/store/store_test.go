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

func TestIncidentDeliveryAndAgentRunLifecycle(t *testing.T) {
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
	if created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "out_root", IncidentID: incident.ID, Kind: "root",
		ChannelID: "C123ABC", Body: body,
	}); err != nil || !created {
		t.Fatalf("enqueue root = %v, %v", created, err)
	}
	outbox, err := st.LeaseSlackDelivery(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(
		ctx, outbox.ID, "1700.001", "sending",
	); err != nil {
		t.Fatal(err)
	}
	storedDelivery, err := st.GetSlackDelivery(ctx, outbox.ID)
	if err != nil ||
		storedDelivery.State != "sent" ||
		storedDelivery.ChannelID != "C123ABC" ||
		storedDelivery.MessageTS != "1700.001" {
		t.Fatalf("stored delivery = %+v, %v", storedDelivery, err)
	}
	matchedDelivery, err := st.GetLatestSentSlackMessageDelivery(
		ctx,
		incident.ID,
		"C123ABC",
		"1700.001",
	)
	if err != nil || matchedDelivery.ID != outbox.ID {
		t.Fatalf("matched delivery = %+v, %v", matchedDelivery, err)
	}
	responderDelivery, err := st.GetSentSlackMessageDelivery(
		ctx,
		"C123ABC",
		"1700.001",
	)
	if err != nil || responderDelivery.ID != outbox.ID {
		t.Fatalf("responder delivery = %+v, %v", responderDelivery, err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.RootTS != "1700.001" ||
		incident.Workflow != core.WorkflowProvisioningSession {
		t.Fatalf("root binding = %+v, %v", incident, err)
	}

	queued, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: incident.ChannelID, ThreadTS: incident.RootTS,
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      "initial", SourceID: incident.ID,
		Repository: incident.Repository, Prompt: "investigate",
	})
	if err != nil || !created {
		t.Fatalf("queue turn = %+v, %v, %v", queued, created, err)
	}
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api-latency", 1); err != nil {
		t.Fatal(err)
	}
	leasedTurn, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindAgentRunSession(
		ctx,
		leasedTurn.ID,
		"ses_1",
		0,
		incident.Repository,
		0,
		leasedTurn.Context,
	); err != nil {
		t.Fatal(err)
	}
	revision, err := st.FreezeAgentRunRevision(ctx, leasedTurn.ID, 1)
	if err != nil || revision != 1 {
		t.Fatalf("freeze revision = %d, %v", revision, err)
	}
	if err := st.MarkAgentRunSubmitted(
		ctx, leasedTurn.ID, "coop_turn_1", 2, 0,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(
		ctx, leasedTurn.ID, "completed", nil, "", 0,
	); err != nil {
		t.Fatal(err)
	}
	completed, err := st.BeginAgentRunFinalization(ctx, leasedTurn.ID)
	if err != nil || completed.ID != leasedTurn.ID {
		t.Fatalf("begin finalization = %+v, %v", completed, err)
	}
	if err := st.FinishAgentRun(ctx, leasedTurn.ID); err != nil {
		t.Fatal(err)
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

func TestOpenLiveWritesCurrentDatabaseWithoutMigration(t *testing.T) {
	ctx := context.Background()
	stateDir := filepath.Join(t.TempDir(), "state")
	owner, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer owner.Close()
	live, err := OpenLive(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer live.Close()
	input := core.SlackInput{
		ID: "slack_live_control", EnvelopeID: "env_live_control",
		EventID: "event_live_control", Kind: "mention", TeamID: "T123",
		ChannelID: "C123", MessageTS: "1700.001", UserID: "U123", Text: "verify",
	}
	if created, err := live.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit through live store = %v, %v", created, err)
	}
	stored, err := owner.GetSlackInput(ctx, input.ID)
	if err != nil || stored.Text != input.Text {
		t.Fatalf("owner observed live write = %+v, %v", stored, err)
	}
}

func TestListSlackDeliveriesByPrefixIncludesMultipartAndFilesOnly(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	for _, delivery := range []core.SlackDelivery{
		{ID: "watch_reply_replay_part_001", Operation: "post", Kind: "notice", ChannelID: "C123", Body: []byte(`{"text":"one"}`)},
		{ID: "watch_reply_replay_part_999", Operation: "post", Kind: "notice", ChannelID: "C123", Body: []byte(`{"text":"two"}`)},
		{ID: "watch_reply_replay_visual_01", Operation: "file", Kind: "generated_visual", ChannelID: "C123", Body: []byte(`{"file":"chart"}`)},
		{ID: "watch_reply_other", Operation: "post", Kind: "notice", ChannelID: "C123", Body: []byte(`{"text":"other"}`)},
	} {
		if created, err := st.EnqueueSlackDelivery(ctx, delivery); err != nil || !created {
			t.Fatalf("enqueue %s = %v, %v", delivery.ID, created, err)
		}
	}
	deliveries, err := st.ListSlackDeliveriesByPrefix(ctx, "watch_reply_replay")
	if err != nil {
		t.Fatal(err)
	}
	if len(deliveries) != 3 {
		t.Fatalf("prefix deliveries = %+v", deliveries)
	}
	for _, delivery := range deliveries {
		if !strings.HasPrefix(delivery.ID, "watch_reply_replay") || delivery.ID == "watch_reply_other" {
			t.Fatalf("unexpected prefix delivery = %+v", delivery)
		}
	}
}

func TestRetryLatestGeneratedVisualIsConversationScoped(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	for _, delivery := range []core.SlackDelivery{
		{
			ID: "visual-channel", Operation: "file", Kind: "generated_visual",
			ChannelID: "C123", Body: []byte(`{"filename":"channel.png"}`),
		},
		{
			ID: "visual-thread", Operation: "file", Kind: "generated_visual",
			ChannelID: "C123", ThreadTS: "1700.1", Body: []byte(`{"filename":"thread.png"}`),
		},
	} {
		if created, err := st.EnqueueSlackDelivery(ctx, delivery); err != nil || !created {
			t.Fatalf("enqueue %s = %t, %v", delivery.ID, created, err)
		}
		leased, err := st.LeaseSlackDelivery(ctx)
		if err != nil || leased.ID != delivery.ID {
			t.Fatalf("lease %s = %+v, %v", delivery.ID, leased, err)
		}
		if err := st.RetrySlackDelivery(
			ctx, leased.ID, "old failure", time.Now().Add(time.Hour), false, true,
		); err != nil {
			t.Fatal(err)
		}
	}

	retried, err := st.RetryLatestGeneratedVisual(ctx, "C123", "")
	if err != nil {
		t.Fatal(err)
	}
	if retried.ID != "visual-channel" || retried.State != "retry" ||
		retried.Attempts != 0 || retried.LastError != "" || retried.NextAttemptAt.After(time.Now()) {
		t.Fatalf("retried channel visual = %+v", retried)
	}
	thread, err := st.GetSlackDelivery(ctx, "visual-thread")
	if err != nil || thread.State != "failed" || thread.LastError != "old failure" {
		t.Fatalf("unrelated thread visual = %+v, %v", thread, err)
	}
	if _, err := st.RetryLatestGeneratedVisual(ctx, "C999", ""); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing visual retry error = %v", err)
	}
}

func TestSlackDeliveryCoalescingIsIdempotentAndSupersedesOnlyOlderVersions(t *testing.T) {
	ctx := context.Background()
	t.Run("identical delivery stays pending", func(t *testing.T) {
		st, err := Open(filepath.Join(t.TempDir(), "state"))
		if err != nil {
			t.Fatal(err)
		}
		defer st.Close()
		delivery := core.SlackDelivery{
			ID: "delivery_card_inc_1_2", Operation: "update", Kind: "card",
			ChannelID: "C1", MessageTS: "1700.001",
			Body: []byte(`{"text":"card"}`), CoalesceKey: "card:inc_1",
			CardVersion: 2,
		}
		if created, err := st.EnqueueSlackDelivery(ctx, delivery); err != nil || !created {
			t.Fatalf("first enqueue = %v, %v", created, err)
		}
		if created, err := st.EnqueueSlackDelivery(ctx, delivery); err != nil || created {
			t.Fatalf("idempotent enqueue = %v, %v", created, err)
		}
		leased, err := st.LeaseSlackDelivery(ctx)
		if err != nil || leased.ID != delivery.ID {
			t.Fatalf("identical delivery was superseded = %+v, %v", leased, err)
		}
	})
	t.Run("new version supersedes old pending version", func(t *testing.T) {
		st, err := Open(filepath.Join(t.TempDir(), "state"))
		if err != nil {
			t.Fatal(err)
		}
		defer st.Close()
		base := core.SlackDelivery{
			Operation: "update", Kind: "card", ChannelID: "C1",
			MessageTS: "1700.001", Body: []byte(`{"text":"card"}`),
			CoalesceKey: "card:inc_1",
		}
		old := base
		old.ID = "delivery_card_inc_1_2"
		old.CardVersion = 2
		if _, err := st.EnqueueSlackDelivery(ctx, old); err != nil {
			t.Fatal(err)
		}
		current := base
		current.ID = "delivery_card_inc_1_3"
		current.CardVersion = 3
		if _, err := st.EnqueueSlackDelivery(ctx, current); err != nil {
			t.Fatal(err)
		}
		leased, err := st.LeaseSlackDelivery(ctx)
		if err != nil || leased.ID != current.ID {
			t.Fatalf("newer delivery did not supersede old = %+v, %v", leased, err)
		}
	})
	t.Run("late stale version cannot replace current version", func(t *testing.T) {
		st, err := Open(filepath.Join(t.TempDir(), "state"))
		if err != nil {
			t.Fatal(err)
		}
		defer st.Close()
		current := core.SlackDelivery{
			ID: "delivery_card_inc_1_5", Operation: "update", Kind: "card",
			ChannelID: "C1", MessageTS: "1700.001",
			Body: []byte(`{"text":"current"}`), CoalesceKey: "card:inc_1",
			CardVersion: 5,
		}
		if created, err := st.EnqueueSlackDelivery(ctx, current); err != nil || !created {
			t.Fatalf("current enqueue = %v, %v", created, err)
		}
		stale := current
		stale.ID = "delivery_card_inc_1_4"
		stale.Body = []byte(`{"text":"stale"}`)
		stale.CardVersion = 4
		if created, err := st.EnqueueSlackDelivery(ctx, stale); err != nil || created {
			t.Fatalf("stale enqueue = %v, %v", created, err)
		}
		leased, err := st.LeaseSlackDelivery(ctx)
		if err != nil || leased.ID != current.ID {
			t.Fatalf("stale delivery replaced current = %+v, %v", leased, err)
		}
	})
}

func TestSlackStatusGenerationMakesClearMonotonic(t *testing.T) {
	ctx := context.Background()
	stateDir := filepath.Join(t.TempDir(), "state")
	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	activeGeneration, err := st.NextSlackStatusGeneration(ctx, "C1", "1700.001")
	if err != nil {
		t.Fatal(err)
	}
	active := core.SlackDelivery{
		ID: "status_active", Operation: "status", Kind: "status",
		ChannelID: "C1", ThreadTS: "1700.001", Status: "is investigating...",
		CoalesceKey: "status:C1:1700.001", CardVersion: activeGeneration,
	}
	if created, err := st.EnqueueSlackDelivery(ctx, active); err != nil || !created {
		t.Fatalf("enqueue active status = %v, %v", created, err)
	}
	clearGeneration, err := st.NextSlackStatusGeneration(ctx, "C1", "1700.001")
	if err != nil {
		t.Fatal(err)
	}
	clear := core.SlackDelivery{
		ID: "status_clear", Operation: "status", Kind: "status",
		ChannelID: "C1", ThreadTS: "1700.001",
		CoalesceKey: "status:C1:1700.001", CardVersion: clearGeneration,
	}
	if created, err := st.EnqueueSlackDelivery(ctx, clear); err != nil || !created {
		t.Fatalf("enqueue status clear = %v, %v", created, err)
	}
	stale := active
	stale.ID = "status_stale_late"
	if created, err := st.EnqueueSlackDelivery(ctx, stale); err != nil || created {
		t.Fatalf("late stale status = %v, %v", created, err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	st, err = Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	nextGeneration, err := st.NextSlackStatusGeneration(ctx, "C1", "1700.001")
	if err != nil || nextGeneration != clearGeneration+1 {
		t.Fatalf("persisted status generation = %d, %v", nextGeneration, err)
	}
	leased, err := st.LeaseSlackDelivery(ctx)
	if err != nil || leased.ID != clear.ID || leased.Status != "" {
		t.Fatalf("monotonic status delivery = %+v, %v", leased, err)
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

func TestAgentRunSubmissionRequiresAndRecoversIncidentSessionBinding(t *testing.T) {
	ctx := context.Background()
	stateDir := filepath.Join(t.TempDir(), "state")
	st, err := Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	event := testWebhookEvent()
	incidents, err := st.ApplySignals(ctx, event, time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("create incident = %+v, %v", incidents, err)
	}
	incident := incidents[0]
	if err := st.SetChannel(ctx, incident.ID, "C123ABC", "inc-test"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incident.ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetCoopSession(ctx, incident.ID, "ses_recover", "fork-recover", 1); err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: "C123ABC", ThreadTS: "1700.001",
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      "initial", SourceID: incident.ID,
		Repository: incident.Repository, Prompt: "investigate",
	})
	if err != nil || !created {
		t.Fatalf("queue run = %+v, %v, %v", run, created, err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(
		ctx, leased.ID, "turn_unbound", 2, 0,
	); err == nil || !strings.Contains(err.Error(), "bound Coop session") {
		t.Fatalf("unbound submission error = %v", err)
	}
	if _, err := st.db.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'running', coop_turn_id = 'turn_interrupted'
		WHERE id = ?`, leased.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	st, err = Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.RecoverInterrupted(ctx); err != nil {
		t.Fatal(err)
	}
	recovered, err := st.GetAgentRun(ctx, leased.ID)
	if err != nil || recovered.SessionID != "ses_recover" ||
		recovered.State != core.AgentRunRunning {
		t.Fatalf("recovered binding = %+v, %v", recovered, err)
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

func TestSlackInputsOnlySerializeActiveChannelWork(t *testing.T) {
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
	second, err := st.LeaseSlackInput(ctx)
	if err != nil || second.ID != "slack-b1" {
		t.Fatalf("independent channel lease = %+v, %v", second, err)
	}
	if err := st.FinishSlackInput(ctx, second.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.RetrySlackInput(
		ctx, first.ID, "long-running work was detached", time.Now().Add(time.Hour), false,
	); err != nil {
		t.Fatal(err)
	}
	third, err := st.LeaseSlackInput(ctx)
	if err != nil || third.ID != "slack-a2" {
		t.Fatalf("later channel input remained head-of-line blocked = %+v, %v", third, err)
	}
	if err := st.FinishSlackInput(ctx, third.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deferred input became due early: %v", err)
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

func TestSchemaV9MigratesBehaviorPreferencesAndRules(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	for _, schema := range []string{
		schemaV1, schemaV2, schemaV3, schemaV4, schemaV5,
		schemaV6, schemaV7, schemaV8, schemaV9,
	} {
		if _, err := db.Exec(schema); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(`INSERT INTO schema_version(version) VALUES (9)`); err != nil {
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
	if _, _, err := st.UpsertPreference(
		context.Background(),
		core.ResponderPreference{
			ScopeKind: "workspace", ScopeKey: "TWORKSPACE",
			Name: "health_check_depth", Value: "deep",
			SourceRef: "slack_pref", ActorID: "UOPERATOR",
			ExpiresAt: time.Now().UTC().Add(time.Hour),
		},
		10,
		5,
	); err != nil {
		t.Fatalf("migrated preference table: %v", err)
	}
	if _, _, err := st.UpsertStandingRule(
		context.Background(),
		core.StandingRule{
			ChannelID: "COPS", Repository: "repo",
			Trigger: "terraform_plan", Action: "review_terraform_plan",
			SourceKind: "any", SourceRef: "slack_rule", ActorID: "UOPERATOR",
			ExpiresAt: time.Now().UTC().Add(time.Hour),
		},
		10,
		5,
	); err != nil {
		t.Fatalf("migrated standing rule table: %v", err)
	}
}

func TestSchemaV10MigratesActiveAgentRunAndUncertainSlackDelivery(t *testing.T) {
	ctx := context.Background()
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	for _, schema := range []string{
		schemaV1, schemaV2, schemaV3, schemaV4, schemaV5,
		schemaV6, schemaV7, schemaV8, schemaV9, schemaV10,
	} {
		if _, err := db.Exec(schema); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now().UTC().Format(timestampFormat)
	if _, err := db.Exec(`
		INSERT INTO schema_version(version) VALUES (10);
		INSERT INTO incidents (
		  id, route, repository, correlation_key, title, status, workflow,
		  channel_id, root_ts, coop_session_id, created_at, updated_at
		) VALUES (
		  'inc_migrate', 'grafana', 'repo', 'migration', 'Migration',
		  'active', 'investigating', 'CMIGRATE', '1700.001', 'ses_migrate', ?, ?
		);
		INSERT INTO turn_submissions (
		  id, incident_id, source_kind, source_id, user_id, prompt,
		  idempotency_key, expected_revision, coop_turn_id, state, attempts,
		  next_attempt_at, last_error, created_at, updated_at
		) VALUES (
		  'turn_migrate', 'inc_migrate', 'slack', 'slack_migrate', 'U1',
		  'Inspect.', 'responder:turn:turn_migrate', 7, 'coop_turn_migrate',
		  'submitted', 3, ?, '', ?, ?
		);
		INSERT INTO outbox (
		  id, incident_id, kind, channel_id, thread_ts, body_json, state,
		  attempts, next_attempt_at, last_error, created_at, updated_at
		) VALUES (
		  'out_migrate', 'inc_migrate', 'reply', 'CMIGRATE', '1700.001',
		  '{"text":"accepted"}', 'sending', 2, ?, '', ?, ?
		);
		INSERT INTO slack_inputs (
		  id, envelope_id, event_id, kind, team_id, channel_id, message_ts,
		  text, state, attempts, next_attempt_at, received_at, updated_at
		) VALUES (
		  'slack_migrate', 'env_migrate', 'event_migrate', 'message',
		  'T1', 'CMIGRATE', '1700.002', 'Inspect.', 'done', 4, ?, ?, ?
		)`,
		now, now,
		now, now, now,
		now, now, now,
		now, now, now,
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
	if err := st.RecoverInterrupted(ctx); err != nil {
		t.Fatal(err)
	}
	run, err := st.GetAgentRunBySource(ctx, "slack", "slack_migrate")
	if err != nil {
		t.Fatal(err)
	}
	if run.ID != "turn_migrate" || run.State != core.AgentRunRunning ||
		run.SessionID != "ses_migrate" || run.ExpectedRevision != 7 ||
		run.Failures != 3 || run.CoopTurnID != "coop_turn_migrate" {
		t.Fatalf("migrated agent run = %+v", run)
	}
	deliveries, err := st.ListUncertainSlackDeliveries(ctx, 10)
	if err != nil || len(deliveries) != 1 {
		t.Fatalf("migrated Slack deliveries = %+v, %v", deliveries, err)
	}
	delivery := deliveries[0]
	if delivery.ID != "out_migrate" || delivery.Operation != "post" ||
		delivery.Attempts != 2 || string(delivery.Body) != `{"text":"accepted"}` {
		t.Fatalf("migrated Slack delivery = %+v", delivery)
	}
	input, err := st.GetSlackInput(ctx, "slack_migrate")
	if err != nil || input.Failures != 0 || input.Attempts != 4 {
		t.Fatalf("migrated Slack input failure budget = %+v, %v", input, err)
	}
	for _, oldTable := range []string{"turn_submissions", "outbox"} {
		var count int
		if err := st.db.QueryRow(`
			SELECT count(*) FROM sqlite_master
			WHERE type = 'table' AND name = ?`, oldTable).Scan(&count); err != nil {
			t.Fatal(err)
		}
		if count != 0 {
			t.Fatalf("legacy table %q survived migration", oldTable)
		}
	}
}

func TestSchemaV21AddsResponseLocationWithoutLosingPreferences(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	for _, schema := range migrations[:20] {
		if _, err := db.Exec(schema); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now().UTC()
	if _, err := db.Exec(`
		INSERT INTO schema_version(version) VALUES (20);
		INSERT INTO responder_preferences (
		  id, scope_kind, scope_key, name, value, enabled, source_ref, actor_id,
		  expires_at, created_at, updated_at
		) VALUES (?, 'operator', 'UOPERATOR', 'response_detail', 'concise', 1,
		  'slack_existing', 'UOPERATOR', ?, ?, ?)`,
		"pref_existing",
		now.Add(time.Hour).Format(timestampFormat),
		now.Format(timestampFormat),
		now.Format(timestampFormat),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		INSERT INTO memory_entries (
		  id, scope_kind, scope_key, subject_key, predicate, value_json, value_hash,
		  source_ref, source_revision, actor_id, visibility_kind, visibility_id,
		  expires_at, created_at, updated_at
		) VALUES (
		  'mem_existing', 'channel', 'COPS', 'old portal', 'alias_of',
		  '"service:portal"', 'hash', 'slack_memory', '', 'UOPERATOR',
		  'channel', 'COPS', ?, ?, ?
		)`,
		now.Add(time.Hour).Format(timestampFormat),
		now.Format(timestampFormat),
		now.Format(timestampFormat),
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
	if existing, err := st.GetPreference(context.Background(), "pref_existing"); err != nil ||
		existing.Value != "concise" {
		t.Fatalf("existing preference after migration = %+v, %v", existing, err)
	}
	if existing, err := st.GetMemoryEntry(context.Background(), "mem_existing"); err != nil ||
		existing.Value != "service:portal" {
		t.Fatalf("existing memory after migration = %+v, %v", existing, err)
	}
	if _, _, err := st.UpsertPreference(
		context.Background(),
		core.ResponderPreference{
			ScopeKind: "operator", ScopeKey: "UOPERATOR",
			Name: "response_location", Value: "prefer_thread",
			SourceRef: "slack_new", ActorID: "UOPERATOR",
			ExpiresAt: now.Add(90 * 24 * time.Hour),
		},
		20,
		10,
	); err != nil {
		t.Fatalf("new response location after migration: %v", err)
	}
	if _, _, err := st.UpsertMemoryEntry(
		context.Background(),
		core.MemoryEntry{
			ScopeKind: "workspace", ScopeKey: "TWORKSPACE",
			SubjectKey: "fix_explanation_style", Predicate: "guidance",
			Value: "Start with a simple summary.", SourceRef: "slack_guidance",
			ActorID: "UOPERATOR", VisibilityKind: "operator", VisibilityID: "UOPERATOR",
			ExpiresAt: now.Add(90 * 24 * time.Hour),
		},
		20,
		10,
	); err != nil {
		t.Fatalf("new guidance after migration: %v", err)
	}
}

func TestSchemaV24AllowsEmisarApprovalWithoutIncident(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	for _, schema := range migrations[:22] {
		if _, err := db.Exec(schema); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(`INSERT INTO schema_version(version) VALUES (22)`); err != nil {
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
	expires := time.Now().UTC().Add(time.Hour).Truncate(time.Second)
	approval, created, err := st.RecordEmisarApproval(
		context.Background(),
		core.EmisarApproval{
			RequestID: "apr_shared", ChannelID: "CSHARED",
			SourceInput: "slack_shared", RequestedBy: "UOPERATOR",
			RunID:       "run_shared",
			OperationID: "op_shared", ActionID: "service.enable",
			PackRef: "service@1#sha256:abc", RunnerRef: "prod~abc",
			Status:      "pending_approval",
			ApprovalURL: "https://emisar.dev/app/acme/approvals/apr_shared",
			ExpiresAt:   expires,
		},
	)
	if err != nil || !created || approval.IncidentID != "" ||
		approval.ChannelID != "CSHARED" || approval.RequestedBy != "UOPERATOR" ||
		approval.NextCheckAt.IsZero() || !approval.ExpiresAt.Equal(expires) {
		t.Fatalf("shared approval after migration = %+v, %t, %v", approval, created, err)
	}
}

func TestSchemaV24PreservesExistingPendingApproval(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	for _, schema := range migrations[:23] {
		if _, err := db.Exec(schema); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(`INSERT INTO schema_version(version) VALUES (23)`); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	if _, err := db.Exec(`
		INSERT INTO emisar_approvals (
		  request_id, incident_id, channel_id, source_input, run_id,
		  operation_id, action_id, pack_ref, runner_ref, status,
		  approval_url, expires_at, created_at, updated_at
		) VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?, 'pending_approval', ?, ?, ?, ?)`,
		"apr_existing", "C123", "slack_existing", "run_existing",
		"op_existing", "service.enable", "service@1#sha256:abc", "prod~abc",
		"https://emisar.dev/app/acme/approvals/apr_existing",
		now.Add(time.Hour).Format(timestampFormat),
		now.Format(timestampFormat),
		now.Format(timestampFormat),
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
	approval, err := st.GetEmisarApproval(context.Background(), "apr_existing")
	if err != nil || approval.Status != "pending_approval" ||
		approval.RunID != "run_existing" || approval.NextCheckAt.IsZero() ||
		approval.ContinuationQueued {
		t.Fatalf("migrated approval = %+v, %v", approval, err)
	}
}

func TestSchemaV25PreservesMemoryAndAddsLifecycleState(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	for _, schema := range migrations[:24] {
		if _, err := db.Exec(schema); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now().UTC().Truncate(time.Second)
	if _, err := db.Exec(`
		INSERT INTO schema_version(version) VALUES (24);
		INSERT INTO memory_entries (
		  id, scope_kind, scope_key, subject_key, predicate, value_json, value_hash,
		  source_ref, source_revision, actor_id, visibility_kind, visibility_id,
		  expires_at, created_at, updated_at
		) VALUES (
		  'mem_v24', 'workspace', 'TWORKSPACE', 'style', 'guidance',
		  '"Use plain language."', 'old_hash', 'slack_old', '', 'UOPERATOR',
		  'workspace', 'TWORKSPACE', ?, ?, ?
		);
		INSERT INTO conversation_memories (
		  channel_id, thread_ts, repository, last_message_ts, state_json, updated_at
		) VALUES ('COPS', '1700.1', 'repo', '1700.2', '{"goal":"keep context"}', ?);`,
		now.Add(30*24*time.Hour).Format(timestampFormat),
		now.Format(timestampFormat), now.Format(timestampFormat),
		now.Format(timestampFormat),
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
	entry, err := st.GetMemoryEntry(context.Background(), "mem_v24")
	if err != nil || entry.Value != "Use plain language." || entry.RecallCount != 0 {
		t.Fatalf("migrated memory = %+v, %v", entry, err)
	}
	conversation, err := st.GetConversationMemory(context.Background(), "COPS", "1700.1")
	if err != nil || conversation.State.Goal != "keep context" {
		t.Fatalf("migrated conversation = %+v, %v", conversation, err)
	}
	if health, err := st.MemoryHealth(context.Background()); err != nil ||
		health.ExplicitActive != 1 || health.ConversationSummaries != 1 {
		t.Fatalf("memory health = %+v, %v", health, err)
	}
}

func TestEmisarApprovalLifecycleBindsDeliveryAndSurvivesTerminalReplay(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	approval, created, err := st.RecordEmisarApproval(ctx, core.EmisarApproval{
		RequestID: "apr_lifecycle", ChannelID: "C123",
		SourceInput: "slack_lifecycle", RequestedBy: "U123",
		RunID: "run_lifecycle", OperationID: "op_lifecycle",
		ActionID: "service.enable", PackRef: "service@1#sha256:abc",
		RunnerRef: "prod~abc", Status: "pending_approval",
		ApprovalURL: "https://emisar.dev/app/acme/approvals/apr_lifecycle",
		ExpiresAt:   now.Add(time.Hour),
	})
	if err != nil || !created {
		t.Fatalf("record approval = %+v, %t, %v", approval, created, err)
	}
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "delivery_lifecycle", Operation: "post", Kind: "notice",
		ChannelID: "C123", ThreadTS: "1700.1", Body: []byte(`{"text":"approval"}`),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BindEmisarApprovalDelivery(
		ctx,
		approval.RequestID,
		"delivery_lifecycle",
	); err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseSlackDelivery(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(ctx, leased.ID, "1700.2", "sending"); err != nil {
		t.Fatal(err)
	}
	approval, err = st.GetEmisarApproval(ctx, approval.RequestID)
	if err != nil || approval.MessageTS != "1700.2" ||
		approval.DeliveryID != "delivery_lifecycle" {
		t.Fatalf("bound approval = %+v, %v", approval, err)
	}
	approval, changed, err := st.AdvanceEmisarApproval(
		ctx,
		approval.RequestID,
		"running",
		"https://emisar.dev/app/acme/runs/run_lifecycle",
		"",
		now.Add(time.Second),
	)
	if err != nil || !changed || approval.Status != "running" ||
		!approval.TerminalAt.IsZero() {
		t.Fatalf("running approval = %+v, %t, %v", approval, changed, err)
	}
	approval, changed, err = st.AdvanceEmisarApproval(
		ctx,
		approval.RequestID,
		"success",
		approval.RunURL,
		"",
		now.Add(2*time.Second),
	)
	if err != nil || !changed || approval.TerminalAt.IsZero() {
		t.Fatalf("terminal approval = %+v, %t, %v", approval, changed, err)
	}
	if err := st.MarkEmisarApprovalContinuationQueued(ctx, approval.RequestID); err != nil {
		t.Fatal(err)
	}
	items, err := st.ListMonitorableEmisarApprovals(ctx, 10)
	if err != nil || len(items) != 0 {
		t.Fatalf("monitorable approvals = %+v, %v", items, err)
	}
	if _, _, err := st.AdvanceEmisarApproval(
		ctx,
		approval.RequestID,
		"failed",
		approval.RunURL,
		"late conflicting status",
		now.Add(3*time.Second),
	); err == nil {
		t.Fatal("terminal approval accepted a conflicting replay")
	}
}

func TestMigrationCreatesVerifiedPrivateBackup(t *testing.T) {
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(stateDir, "responder.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	for _, schema := range migrations[:12] {
		if _, err := db.Exec(schema); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(`INSERT INTO schema_version(version) VALUES (12)`); err != nil {
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

	paths, err := filepath.Glob(filepath.Join(
		stateDir,
		"backups",
		fmt.Sprintf("responder-v12-to-v%d-*.db", currentSchemaVersion),
	))
	if err != nil || len(paths) != 1 {
		t.Fatalf("migration backups = %v, %v", paths, err)
	}
	info, err := os.Stat(paths[0])
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("migration backup mode = %v, %v", info, err)
	}
	backup, err := sql.Open("sqlite", paths[0])
	if err != nil {
		t.Fatal(err)
	}
	defer backup.Close()
	version, err := schemaVersion(backup)
	if err != nil || version != 12 {
		t.Fatalf("backup schema version = %d, %v", version, err)
	}
	var quickCheck string
	if err := backup.QueryRow(`PRAGMA quick_check`).Scan(&quickCheck); err != nil || quickCheck != "ok" {
		t.Fatalf("backup quick check = %q, %v", quickCheck, err)
	}
	var workTable int
	if err := backup.QueryRow(`
		SELECT count(*) FROM sqlite_master
		WHERE type = 'table' AND name = 'work_items'`).Scan(&workTable); err != nil {
		t.Fatal(err)
	}
	if workTable != 0 {
		t.Fatal("migration backup contains post-migration scheduler table")
	}
}

func TestMigrationV22PreservesDeliveriesAndAllowsFiles(t *testing.T) {
	ctx := context.Background()
	stateDir := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(stateDir, "responder.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	for _, schema := range migrations[:21] {
		if _, err := db.Exec(schema); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(`
		INSERT INTO schema_version(version) VALUES (21);
		INSERT INTO slack_deliveries (
		  id, operation, kind, channel_id, body_json, state,
		  next_attempt_at, created_at, updated_at
		) VALUES (
		  'delivery_existing', 'post', 'reply', 'C123', '{"text":"kept"}',
		  'pending', '2026-07-31T00:00:00Z', '2026-07-31T00:00:00Z',
		  '2026-07-31T00:00:00Z'
		)`); err != nil {
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
	existing, err := st.GetSlackDelivery(ctx, "delivery_existing")
	if err != nil || existing.Operation != "post" || string(existing.Body) != `{"text":"kept"}` {
		t.Fatalf("existing delivery after migration = %+v, %v", existing, err)
	}
	created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "delivery_file", Operation: "file", Kind: "generated_visual",
		ChannelID: "C123", ThreadTS: "1700.1", Body: []byte(`{"name":"chart.png"}`),
	})
	if err != nil || !created {
		t.Fatalf("enqueue file after migration = %v, %v", created, err)
	}
	file, err := st.GetSlackDelivery(ctx, "delivery_file")
	if err != nil || file.Operation != "file" {
		t.Fatalf("file delivery after migration = %+v, %v", file, err)
	}
}

func TestMigrationBackupRetentionIsBoundedAndScoped(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "backups")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	base := time.Now().UTC().Add(-time.Hour)
	for i := range 6 {
		path := filepath.Join(dir, fmt.Sprintf("responder-v%d-to-v13-test.db", i+1))
		if err := os.WriteFile(path, []byte("backup"), 0o600); err != nil {
			t.Fatal(err)
		}
		when := base.Add(time.Duration(i) * time.Minute)
		if err := os.Chtimes(path, when, when); err != nil {
			t.Fatal(err)
		}
	}
	unrelated := filepath.Join(dir, "operator-note.txt")
	if err := os.WriteFile(unrelated, []byte("retain"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := pruneMigrationBackups(dir, migrationBackupRetention); err != nil {
		t.Fatal(err)
	}
	paths, err := filepath.Glob(filepath.Join(dir, "responder-v*-to-v*.db"))
	if err != nil || len(paths) != migrationBackupRetention {
		t.Fatalf("retained migration backups = %v, %v", paths, err)
	}
	if _, err := os.Stat(unrelated); err != nil {
		t.Fatalf("unrelated file was removed: %v", err)
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
		INSERT INTO schema_version(version) VALUES (?);
		CREATE TABLE future_state (value TEXT NOT NULL);
		INSERT INTO future_state(value) VALUES ('preserve-me');
	`, currentSchemaVersion+1); err != nil {
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
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "out_failed", IncidentID: incident[0].ID, Kind: "notice",
		ChannelID: "C123ABC", Body: []byte(`{"text":"notice"}`),
	}); err != nil {
		t.Fatal(err)
	}
	leasedOutbox, err := st.LeaseSlackDelivery(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.RetrySlackDelivery(ctx, leasedOutbox.ID, "invalid Slack payload", time.Now(), false, true); err != nil {
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
	uncertain, err := st.ListUncertainSlackDeliveries(ctx, 10)
	if err != nil || len(uncertain) != 1 || uncertain[0].ID != leasedOutbox.ID {
		t.Fatalf("retried outbox skipped reconciliation = %+v, %v", uncertain, err)
	}
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "update_failed", IncidentID: incident[0].ID,
		Operation: "update", Kind: "card", ChannelID: "C123ABC",
		MessageTS: "1700.001", Body: []byte(`{"text":"updated"}`),
	}); err != nil {
		t.Fatal(err)
	}
	leasedUpdate, err := st.LeaseSlackDelivery(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.RetrySlackDelivery(
		ctx, leasedUpdate.ID, "update rejected", time.Now(), false, true,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.RetryFailedWork(ctx, "outbox", leasedUpdate.ID); err != nil {
		t.Fatal(err)
	}
	retriedUpdate, err := st.LeaseSlackDelivery(ctx)
	if err != nil || retriedUpdate.ID != leasedUpdate.ID ||
		retriedUpdate.Operation != "update" {
		t.Fatalf("legacy alias stranded Slack update = %+v, %v", retriedUpdate, err)
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
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	queued, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: incident.ChannelID, ThreadTS: incident.RootTS,
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      "slack", SourceID: "slack-1",
		Repository: incident.Repository, Prompt: "investigate",
	})
	if err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindAgentRunSession(
		ctx,
		leased.ID,
		"ses_1",
		0,
		incident.Repository,
		0,
		leased.Context,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(
		ctx, leased.ID, "coop_turn_1", 2, 0,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(
		ctx, leased.ID, "failed", nil, "agent failed", 0,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BeginAgentRunFinalization(ctx, leased.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.FinishAgentRun(ctx, leased.ID); err != nil {
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
