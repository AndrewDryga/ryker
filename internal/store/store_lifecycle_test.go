package store

import (
	"context"
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
	outbox, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if outbox.Attempts != 0 {
		t.Fatalf("leasing counted as a delivery failure: %+v", outbox)
	}
	if err := st.FinishSlackDelivery(
		ctx, outbox.ID, "1700.001", "sending",
	); err != nil {
		t.Fatal(err)
	}
	storedDelivery, err := st.GetSlackDelivery(ctx, outbox.ID)
	if err != nil ||
		storedDelivery.State != "sent" ||
		storedDelivery.Attempts != 0 || storedDelivery.LastError != "" ||
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
		ctx, leasedTurn.ID, "completed", nil, "end_turn", 0,
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
	storedRun, err := st.GetAgentRun(ctx, leasedTurn.ID)
	if err != nil || storedRun.LastError != "" {
		t.Fatalf("completed run retained a terminal event as an error = %+v, %v", storedRun, err)
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

func TestLeaseSlackDeliveryPreservesMultipartSequence(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	for _, id := range []string{
		"watch_reply_ordered_part_999",
		"watch_reply_ordered_part_002",
		"watch_reply_ordered_part_001",
	} {
		created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
			ID: id, Operation: "post", Kind: "notice", ChannelID: "C123",
			Body: []byte(`{"text":"part"}`),
		})
		if err != nil || !created {
			t.Fatalf("enqueue %s = %t, %v", id, created, err)
		}
	}
	for _, expected := range []string{
		"watch_reply_ordered_part_001",
		"watch_reply_ordered_part_002",
		"watch_reply_ordered_part_999",
	} {
		delivery, err := st.LeaseSlackDelivery(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		if delivery.ID != expected {
			t.Fatalf("leased multipart delivery %q, want %q", delivery.ID, expected)
		}
		if err := st.FinishSlackDelivery(ctx, delivery.ID, "1700.1", "sending"); err != nil {
			t.Fatal(err)
		}
	}
}

func TestLeaseSlackDeliverySuppressesReplyAfterNewHumanInputIsAdmitted(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	for _, input := range []core.SlackInput{
		{ID: "input-001", EnvelopeID: "env-001", Kind: "message", ChannelID: "C123", MessageTS: "1700.100", ReceivedAt: now},
		{ID: "input-002", EnvelopeID: "env-002", Kind: "message", ChannelID: "C123", ThreadTS: "1700.100", MessageTS: "1700.101", ReceivedAt: now.Add(time.Second)},
		{ID: "input-003", EnvelopeID: "env-003", Kind: "message", ChannelID: "C123", MessageTS: "1700.200", ReceivedAt: now.Add(2 * time.Second)},
	} {
		created, err := st.AdmitSlackInput(ctx, input)
		if err != nil || !created {
			t.Fatalf("admit %s = %t, %v", input.ID, created, err)
		}
	}
	for _, delivery := range []core.SlackDelivery{
		{ID: "old-response", SourceInputID: "input-001", Operation: "post", Kind: "notice", ChannelID: "C123", ThreadTS: "1700.100", Body: []byte(`{"text":"old"}`), ResponseRoot: true},
		{ID: "other-response", SourceInputID: "input-003", Operation: "post", Kind: "notice", ChannelID: "C123", ThreadTS: "1700.200", Body: []byte(`{"text":"other"}`), ResponseRoot: true},
	} {
		created, err := st.EnqueueSlackDelivery(ctx, delivery)
		if err != nil || !created {
			t.Fatalf("enqueue %s = %t, %v", delivery.ID, created, err)
		}
	}
	leased, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil || leased.ID != "other-response" {
		t.Fatalf("lease after correction = %+v, %v", leased, err)
	}
	old, err := st.GetSlackDelivery(ctx, "old-response")
	if err != nil || old.State != "superseded" || old.LastError != "newer human turn admitted" {
		t.Fatalf("stale response = %+v, %v", old, err)
	}
}

func TestLeaseSlackDeliveryDoesNotTreatBotUpdateAsHumanCorrection(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	source := core.SlackInput{
		ID: "human-source", EnvelopeID: "env-human-source", Kind: "mention",
		TeamID: "T1", ChannelID: "C1", MessageTS: "1700.100", UserID: "U1",
		Text: "check the deploy", ReceivedAt: time.Now().UTC(),
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit human source = %t, %v", created, err)
	}
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "human-answer", SourceInputID: source.ID, Operation: "post", Kind: "notice",
		ChannelID: source.ChannelID, Body: []byte(`{"text":"answer"}`), ResponseRoot: true,
	}); err != nil {
		t.Fatal(err)
	}
	if created, err := st.AdmitSlackInput(ctx, core.SlackInput{
		ID: "newer-bot", EnvelopeID: "env-newer-bot", Kind: "bot_message",
		TeamID: "T1", ChannelID: "C1", MessageTS: "1700.200", UserID: "B1",
		Text: "deployment status changed", ReceivedAt: source.ReceivedAt.Add(time.Second),
	}); err != nil || !created {
		t.Fatalf("admit bot update = %t, %v", created, err)
	}
	leased, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil || leased.ID != "human-answer" {
		t.Fatalf("human answer after bot update = %+v, %v", leased, err)
	}
}

func TestLeaseSlackDeliveryUsesSlackOrderWhenAdmissionTimesTie(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	for _, input := range []core.SlackInput{
		{ID: "z-source", EnvelopeID: "env-z", Kind: "mention", ChannelID: "C123", MessageTS: "1700.100", ReceivedAt: now},
		{ID: "a-correction", EnvelopeID: "env-a", Kind: "message", ChannelID: "C123", ThreadTS: "1700.100", MessageTS: "1700.200", ReceivedAt: now},
	} {
		if created, admitErr := st.AdmitSlackInput(ctx, input); admitErr != nil || !created {
			t.Fatalf("admit %s = %t, %v", input.ID, created, admitErr)
		}
	}
	if created, enqueueErr := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "equal-time-old-response", SourceInputID: "z-source",
		Operation: "post", Kind: "notice", ChannelID: "C123", ThreadTS: "1700.100",
		Body: []byte(`{"text":"old"}`), ResponseRoot: true,
	}); enqueueErr != nil || !created {
		t.Fatalf("enqueue = %t, %v", created, enqueueErr)
	}
	if _, leaseErr := st.LeaseSlackDelivery(ctx, nil); !errors.Is(leaseErr, ErrNotFound) {
		t.Fatalf("lease stale equal-time response = %v", leaseErr)
	}
	stored, err := st.GetSlackDelivery(ctx, "equal-time-old-response")
	if err != nil || stored.State != "superseded" {
		t.Fatalf("equal-time stale response = %+v, %v", stored, err)
	}
}

func TestRecentWatchReplyUsesDurableResponseRootForPostAndFile(t *testing.T) {
	for _, operation := range []string{"post", "file"} {
		t.Run(operation, func(t *testing.T) {
			ctx := context.Background()
			st, err := Open(filepath.Join(t.TempDir(), "state"))
			if err != nil {
				t.Fatal(err)
			}
			defer st.Close()
			created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
				ID: "opaque-response", Operation: operation, Kind: "notice",
				ChannelID: "C123", ThreadTS: "1700.100", Body: []byte(`{"text":"answer"}`),
				ResponseRoot: true,
			})
			if err != nil || !created {
				t.Fatalf("enqueue = %t, %v", created, err)
			}
			leased, err := st.LeaseSlackDelivery(ctx, nil)
			if err != nil {
				t.Fatal(err)
			}
			if err := st.FinishSlackDelivery(ctx, leased.ID, "1700.150", "sending"); err != nil {
				t.Fatal(err)
			}
			got, err := st.HasRecentWatchReply(ctx, "C123", "1700.100", "1700.200", time.Time{})
			if err != nil || !got {
				t.Fatalf("recent response root = %t, %v", got, err)
			}
		})
	}
}

func TestSlackDeliveryFailureCountTracksFailuresNotLeases(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if created, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "delivery-attempts", Operation: "post", Kind: "notice",
		ChannelID: "C123", Body: []byte(`{"text":"hello"}`),
	}); err != nil || !created {
		t.Fatalf("enqueue = %v, %v", created, err)
	}
	leased, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil || leased.Attempts != 0 {
		t.Fatalf("first lease = %+v, %v", leased, err)
	}
	if err := st.RetrySlackDelivery(
		ctx, leased.ID, "temporary Slack failure", time.Now(), false, false,
	); err != nil {
		t.Fatal(err)
	}
	retried, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil || retried.Attempts != 1 || retried.LastError != "temporary Slack failure" {
		t.Fatalf("retry lease = %+v, %v", retried, err)
	}
	if err := st.FinishSlackDelivery(ctx, retried.ID, "1700.2", "sending"); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetSlackDelivery(ctx, retried.ID)
	if err != nil || stored.Attempts != 1 || stored.LastError != "" {
		t.Fatalf("completed retried delivery = %+v, %v", stored, err)
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
		leased, err := st.LeaseSlackDelivery(ctx, nil)
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
		leased, err := st.LeaseSlackDelivery(ctx, nil)
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
		leased, err := st.LeaseSlackDelivery(ctx, nil)
		if err != nil || leased.ID != current.ID {
			t.Fatalf("stale delivery replaced current = %+v, %v", leased, err)
		}
	})
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

func TestEmisarApprovalLifecycleBindsDeliveryAndSurvivesTerminalReplay(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	approval, created, err := st.Approvals.Record(ctx, core.EmisarApproval{
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
	if _, err := st.Approvals.BindDelivery(
		ctx,
		approval.RequestID,
		"delivery_lifecycle",
	); err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseSlackDelivery(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(ctx, leased.ID, "1700.2", "sending"); err != nil {
		t.Fatal(err)
	}
	approval, err = st.Approvals.Get(ctx, approval.RequestID)
	if err != nil || approval.MessageTS != "1700.2" ||
		approval.DeliveryID != "delivery_lifecycle" {
		t.Fatalf("bound approval = %+v, %v", approval, err)
	}
	approval, changed, err := st.Approvals.Advance(
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
	approval, changed, err = st.Approvals.Advance(
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
	if err := st.Approvals.MarkContinuationQueued(ctx, approval.RequestID); err != nil {
		t.Fatal(err)
	}
	items, err := st.Approvals.ListMonitorable(ctx, 10)
	if err != nil || len(items) != 0 {
		t.Fatalf("monitorable approvals = %+v, %v", items, err)
	}
	if _, _, err := st.Approvals.Advance(
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
