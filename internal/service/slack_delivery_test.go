package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	decisionpkg "github.com/AndrewDryga/responder/internal/decision"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"
)

func TestGeneratedVisualDeliveryIsVerifiedThreadedAndReconciled(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	data := []byte("\x89PNG\r\n\x1a\nchart")
	digest := sha256.Sum256(data)
	digestHex := hex.EncodeToString(digest[:])
	coopClient := newFakeCoop()
	coopClient.turn = coop.Turn{ID: "turn_visual", SessionID: "ses_1", OutputArtifacts: []coop.OutputArtifact{{
		ID: "artifact_visual", Name: "load.png", MediaType: "image/png", SHA256: digestHex, Bytes: int64(len(data)),
	}}}
	coopClient.outputArtifacts = map[string]coop.OutputArtifact{
		"artifact_visual": {ID: "artifact_visual", MediaType: "image/png", SHA256: digestHex, Bytes: int64(len(data)), Data: data},
	}
	slackClient := &fakeSlack{uploadErr: errors.New("timeout after Slack accepted upload")}
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	clock := useTestClock(svc, st)
	message := slackui.ConversationResponse("CPU stayed below saturation.", slackui.NewSanitizer(12000))
	if err := svc.enqueueGeneratedVisuals(ctx, "out_test", "", "", "C123", "1700.001", "ses_1", "turn_visual", []core.GeneratedVisual{{
		Artifact: "load.png", Title: "Production load", AltText: "Line chart of production load over 24 hours.",
	}}, &message); err != nil {
		t.Fatal(err)
	}
	if delivery, err := st.GetSlackDelivery(ctx, "out_test_visual_01"); err != nil {
		t.Fatalf("queued visual delivery = %+v err=%v", delivery, err)
	}
	if err := svc.processSlackDelivery(ctx, nil); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.uploads) != 1 || slackClient.uploads[0].thread != "1700.001" ||
		slackClient.uploads[0].upload.Title != "Production load" ||
		slackClient.uploads[0].upload.Message == nil ||
		!strings.Contains(slackClient.uploads[0].upload.Message.Text, "below saturation") ||
		!strings.Contains(slackClient.uploads[0].upload.Filename, "out_test_visual_01") {
		t.Fatalf("upload = %+v", slackClient.uploads)
	}
	clock.Advance(2100 * time.Millisecond)
	if err := svc.reconcileSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.uploads) != 1 {
		t.Fatalf("uncertain upload was duplicated: %+v", slackClient.uploads)
	}
	delivery, err := st.GetSlackDelivery(ctx, "out_test_visual_01")
	if err != nil || delivery.State != "sent" {
		t.Fatalf("delivery = %+v err=%v", delivery, err)
	}
}

func TestGeneratedVisualMissingScopePostsTruthfulFailureInsteadOfSuccess(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	data := []byte("\x89PNG\r\n\x1a\nchart")
	digest := sha256.Sum256(data)
	digestHex := hex.EncodeToString(digest[:])
	coopClient := newFakeCoop()
	coopClient.turn = coop.Turn{ID: "turn_visual", SessionID: "ses_1", OutputArtifacts: []coop.OutputArtifact{{
		ID: "artifact_visual", Name: "load.png", MediaType: "image/png", SHA256: digestHex, Bytes: int64(len(data)),
	}}}
	coopClient.outputArtifacts = map[string]coop.OutputArtifact{
		"artifact_visual": {ID: "artifact_visual", MediaType: "image/png", SHA256: digestHex, Bytes: int64(len(data)), Data: data},
	}
	slackClient := &fakeSlack{uploadErr: errors.New("GetUploadURLExternal: missing_scope")}
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	message := slackui.ConversationResponse("CPU stayed below saturation.", slackui.NewSanitizer(12000))
	if err := svc.enqueueGeneratedVisuals(ctx, "out_scope", "", "", "C123", "1700.001", "ses_1", "turn_visual", []core.GeneratedVisual{{
		Artifact: "load.png", Title: "Production load", AltText: "Line chart of production load over 24 hours.",
	}}, &message); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackDelivery(ctx, nil); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("success text posted before failed upload: %+v", slackClient.posts)
	}
	delivery, err := st.GetSlackDelivery(ctx, "out_scope_visual_01")
	if err != nil || delivery.State != "failed" || !strings.Contains(delivery.LastError, "missing_scope") {
		t.Fatalf("visual delivery = %+v err=%v", delivery, err)
	}
	if err := svc.processSlackDelivery(ctx, nil); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "files:write") ||
		!strings.Contains(slackClient.posts[0].message.Text, "CPU stayed below saturation") {
		t.Fatalf("upload failure reply = %+v", slackClient.posts)
	}
}

func TestGeneratedVisualDeliveryRejectsUnknownAndMismatchedArtifacts(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	data := []byte("\x89PNG\r\n\x1a\nchart")
	digest := sha256.Sum256(data)
	coopClient := newFakeCoop()
	coopClient.turn = coop.Turn{ID: "turn_visual", SessionID: "ses_1", OutputArtifacts: []coop.OutputArtifact{{
		ID: "artifact_visual", Name: "load.png", MediaType: "image/png",
		SHA256: hex.EncodeToString(digest[:]), Bytes: int64(len(data)),
	}}}
	coopClient.outputArtifacts = map[string]coop.OutputArtifact{
		"artifact_visual": {
			ID: "artifact_visual", MediaType: "image/png",
			SHA256: hex.EncodeToString(digest[:]), Bytes: int64(len(data)), Data: append(data, 'x'),
		},
	}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	for name, visual := range map[string]core.GeneratedVisual{
		"unknown":  {Artifact: "other.png", Title: "Load", AltText: "Load chart."},
		"mismatch": {Artifact: "load.png", Title: "Load", AltText: "Load chart."},
	} {
		t.Run(name, func(t *testing.T) {
			if err := svc.enqueueGeneratedVisuals(
				ctx, "out_"+name, "", "", "C123", "1700.1", "ses_1", "turn_visual",
				[]core.GeneratedVisual{visual}, nil,
			); err == nil {
				t.Fatal("untrusted generated visual was accepted")
			}
		})
	}
}

func TestRepeatedFiringRefreshUpdatesCardAndAgentWithoutRawThreadPost(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.MarkInitialTurnQueued(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	repeat := core.Signal{
		Route: "grafana", SourceID: "alert-bound", EventID: "event-refresh",
		Repository: "repo", CorrelationKey: "bound", Status: core.SignalFiring,
		Title: "API unavailable", Severity: "critical",
		Summary: "API requests are still timing out.", SourceURL: "https://grafana.example.test/alerting/1",
		ReceivedAt: time.Now().UTC(),
	}
	event, _, err := st.AdmitWebhook(ctx, "grafana", "delivery-refresh", "digest-refresh", []core.Signal{repeat})
	if err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.processWebhook(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := st.LeaseSlackDelivery(ctx, nil); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("routine firing refresh queued raw Slack output: %v", err)
	}
	submission, err := st.GetAgentRunBySource(ctx, "webhook", event.ID+":"+incident.ID)
	if err != nil || !strings.Contains(submission.Prompt, "still timing out") {
		t.Fatalf("agent did not receive firing refresh: %+v, %v", submission, err)
	}
}

func TestCommandsRequireExactWholeMessage(t *testing.T) {
	for _, command := range []string{
		"!respond status", "!respond update", "!respond changes", "!respond review",
		"!respond stop", "!respond extend", "!respond close", "!respond help",
	} {
		if _, ok := exactCommand(command); !ok {
			t.Fatalf("command %q was not recognized", command)
		}
	}
	for _, prose := range []string{
		"please !respond stop", "!respond stop after the test", "maybe close this",
	} {
		if _, ok := exactCommand(prose); ok {
			t.Fatalf("prose %q executed as a control", prose)
		}
	}
}

func TestManualSummonGetsCapacityRejectionInOriginThread(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CSUMMON"}
	cfg.Limits.MaxOpenIncidents = 1
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	event := core.WebhookEvent{Signals: []core.Signal{{
		Route: "grafana", SourceID: "alert-1", EventID: "event-1",
		Repository: "repo", CorrelationKey: "existing", Status: core.SignalFiring,
		Title: "Existing incident", ReceivedAt: time.Now().UTC(),
	}}}
	if _, err := st.ApplySignals(ctx, event, time.Hour, 0, 1); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "slack-manual-1", EnvelopeID: "envelope-1", EventID: "event-manual-1",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "CSUMMON",
		MessageTS: "1700.001", UserID: "U123ABC",
		Text: "<@U999BOT> open an incident for checkout",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack input = %v, %v", created, err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || slack.posts[0].channel != "CSUMMON" ||
		slack.posts[0].thread != input.MessageTS ||
		!strings.Contains(slack.posts[0].message.Text, "open incident limit") {
		t.Fatalf("capacity response = %+v", slack.posts)
	}
	if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("capacity input was not completed: %v", err)
	}
}

func TestAcceptedSlackPostWithLostResponseIsReconciledExactlyOnce(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	slack := &fakeSlack{postErr: errors.New("response lost after Slack accepted post")}
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		slack,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	clock := useTestClock(svc, st)
	if err := svc.enqueue(
		ctx,
		"delivery-lost-response",
		incident,
		"notice",
		incident.RootTS,
		slackui.Notice("Durable result"),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackDelivery(ctx, nil); err != nil {
		t.Fatal(err)
	}
	if len(slack.posts) != 1 {
		t.Fatalf("initial Slack attempt = %+v", slack.posts)
	}
	slack.postErr = nil
	clock.Advance(2100 * time.Millisecond)
	if err := svc.reconcileSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackDelivery(ctx, nil); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("reconciled delivery remained runnable: %v", err)
	}
	if len(slack.posts) != 1 {
		t.Fatalf("accepted Slack post was duplicated: %+v", slack.posts)
	}
}

func TestSlackWritesAlternateBetweenDirtyCardAndDelivery(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.enqueue(
		ctx, "out_fairness", incident, "notice", incident.RootTS, slackui.Notice("Queued reply"),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackWrite(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slack.updates) != 1 || len(slack.posts) != 0 {
		t.Fatalf("card was not given first write slot: updates=%d posts=%d", len(slack.updates), len(slack.posts))
	}
	rendered := slack.updates[0].message
	if len(rendered.Sections) < 2 ||
		!strings.Contains(rendered.Sections[1], "API requests are timing out") ||
		!slices.Contains(rendered.Context, "Alert source: <https://grafana.example.test/alerting/1|Open grafana.example.test>") {
		t.Fatalf("updated card omitted current signal evidence: %+v", rendered)
	}
	svc.channelWrites.Reset()
	if err := svc.processSlackWrite(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slack.updates) != 1 || len(slack.posts) != 1 {
		t.Fatalf("outbox was not given second write slot: updates=%d posts=%d", len(slack.updates), len(slack.posts))
	}
}

func TestDirtyCardBacksOffAfterTransientSlackFailure(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	createBoundIncident(t, ctx, st)
	slack := &fakeSlack{updateErr: errors.New("Slack unavailable")}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.processSlackWrite(ctx); err != nil {
		t.Fatal(err)
	}
	if slack.updateCall != 1 {
		t.Fatalf("card update attempt = %d", slack.updateCall)
	}
	slack.updateErr = nil
	delivery, err := st.ListFailedWork(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(delivery) != 0 {
		t.Fatalf("transient card delivery became terminal: %+v", delivery)
	}
	metrics, err := st.Metrics(ctx)
	if err != nil {
		t.Fatal(err)
	}
	dirty, err := st.ListDirtyCards(ctx, 10)
	if err != nil || len(dirty) != 1 || metrics.SlackDeliveriesPending != 1 {
		t.Fatalf(
			"card retry was not durable: dirty=%+v pending=%d err=%v",
			dirty,
			metrics.SlackDeliveriesPending,
			err,
		)
	}
}

func TestAcceptedOperatorReplySetsAndRefreshesNativeStatus(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api", 1); err != nil {
		t.Fatal(err)
	}
	incident, _ = st.GetIncident(ctx, incident.ID)
	input := core.SlackInput{
		ID: "slack-reply-1", EnvelopeID: "envelope-reply-1", EventID: "event-reply-1",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: incident.ChannelID,
		ThreadTS: incident.RootTS, MessageTS: "1700.002", UserID: "U123ABC",
		Text: "Check whether the last deploy changed this.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack reply = %v, %v", created, err)
	}
	slack := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.statuses) != 1 || slack.statuses[0].text != "is investigating..." {
		t.Fatalf("accepted reply status = %+v", slack.statuses)
	}
	svc.setNativeStatus(ctx, incident, "is investigating...")
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.statuses) != 1 {
		t.Fatalf("status refreshed too early: %+v", slack.statuses)
	}
	statusKey := incident.ID + "@" + incident.ConversationThreadTS()
	svc.nativeStatus.Age(statusKey, 76*time.Second)
	svc.setNativeStatus(ctx, incident, "is investigating...")
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.statuses) != 2 {
		t.Fatalf("long-running status was not refreshed: %+v", slack.statuses)
	}
	if err := svc.enqueue(
		ctx, "out_status_reset", incident, "notice", incident.RootTS, slackui.Notice("Done"),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackDelivery(ctx, nil); err != nil {
		t.Fatal(err)
	}
	if _, ok := svc.nativeStatus.TextFor(statusKey); ok {
		t.Fatal("thread reply did not clear the local native-status cache")
	}
}

func TestAmbientConversationMayCompleteWithoutSlackReply(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api", 1); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "slack-ambient", EnvelopeID: "envelope-ambient", EventID: "event-ambient",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: incident.ChannelID,
		MessageTS: "1700.600", UserID: "U123ABC", Text: "Lunch arrived.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit ambient message = %v, %v", created, err)
	}
	slack := &fakeSlack{}
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	coopClient.complete(decisionpkg.NoConversationReply)
	incident, _ = st.GetIncident(ctx, incident.ID)
	if err := svc.pollIncident(ctx, incident); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 0 {
		t.Fatalf("silent conversation posted: %+v", slack.posts)
	}
}

func TestNativeStatusRetriesAfterTransientSlackFailure(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	slack := &fakeSlack{statusErr: errors.New("Slack unavailable")}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	svc.setNativeStatus(ctx, incident, "is investigating...")
	statusKey := incident.ID + "@" + incident.ConversationThreadTS()
	if err := svc.processSlackDelivery(ctx, nil); err != nil {
		t.Fatal(err)
	}
	if firstOf(svc.nativeStatus.TextFor(statusKey)) != "is investigating..." {
		t.Fatal("desired native status was not retained for durable retry")
	}
	if err := svc.enqueue(
		ctx, "out_failed_status_reset", incident, "notice", incident.RootTS, slackui.Notice("Request finished"),
	); err != nil {
		t.Fatal(err)
	}
	slack.statusErr = nil
	metrics, err := st.Metrics(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(slack.statuses) != 1 || metrics.SlackDeliveriesPending == 0 ||
		firstOf(svc.nativeStatus.TextFor(statusKey)) != "is investigating..." {
		t.Fatalf(
			"native status retry was not durable: statuses=%+v pending=%d",
			slack.statuses,
			metrics.SlackDeliveriesPending,
		)
	}
}

func TestSocketAdmitsOwnChannelJoinImmediatelyWithoutFallbackDuplicate(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	slackClient := &fakeSlack{channels: []slackui.Channel{{
		ID: "CJOINED", Name: "backend-ops", Member: true,
	}}}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, socket,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	payload, _ := json.Marshal(map[string]any{
		"event_id": "EvBotJoined", "event_time": int64(1785574912),
	})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{Data: &slackevents.MessageEvent{
				User: "U999BOT", Channel: "CJOINED", TimeStamp: "1785574912.610529",
				SubType: slack.MsgSubTypeChannelJoin,
				Message: &slack.Msg{User: "U999BOT", Timestamp: "1785574912.610529",
					SubType: slack.MsgSubTypeChannelJoin, Inviter: "U123ABC"},
			}},
		},
		Request: &socketmode.Request{EnvelopeID: "env-bot-joined", Payload: payload},
	})
	if socket.acks != 1 {
		t.Fatalf("channel join acknowledgements = %d", socket.acks)
	}
	input, err := st.LeaseSlackInput(ctx)
	if err != nil || input.Kind != "channel_joined" || input.ChannelID != "CJOINED" ||
		input.UserID != "U123ABC" || input.MessageTS != "1785574912.610529" {
		t.Fatalf("direct channel join = %+v, %v", input, err)
	}
	if err := st.FinishSlackInput(ctx, input.ID); err != nil {
		t.Fatal(err)
	}
	if err := svc.reconcileSlackChannelMemberships(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("membership fallback duplicated direct join: %v", err)
	}
	if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("duplicate channel setup input = %v", err)
	}
}

func TestSocketAdmitsHumanFileShareAsChannelMessage(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CFILES"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, socket,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	payload, _ := json.Marshal(map[string]any{"event_id": "EvFileShare"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{Data: &slackevents.MessageEvent{
				SubType: slack.MsgSubTypeFileShare, User: "U123ABC", Channel: "CFILES",
				TimeStamp: "1700.650", ThreadTimeStamp: "1700.600",
				Text: "See the failing check in this screenshot.",
				Message: &slack.Msg{
					SubType: slack.MsgSubTypeFileShare, User: "U123ABC",
					Timestamp: "1700.650", ThreadTimestamp: "1700.600",
					Text: "See the failing check in this screenshot.",
					Files: []slack.File{{
						ID: "FFAIL", Name: "failure.png", Mimetype: "image/png",
						Size:               len(testPNG),
						URLPrivateDownload: "https://files.slack.com/files-pri/T-F/failure.png",
					}},
				},
			}},
		},
		Request: &socketmode.Request{EnvelopeID: "env-file-share", Payload: payload},
	})
	input, err := st.LeaseSlackInput(ctx)
	if err != nil || input.Kind != "message" || input.ThreadTS != "1700.600" ||
		input.Text != "See the failing check in this screenshot." ||
		len(input.Attachments) != 1 || input.Attachments[0].ID != "FFAIL" {
		t.Fatalf("human file share = %+v, %v", input, err)
	}
	if socket.acks != 1 {
		t.Fatalf("file share acknowledgements = %d", socket.acks)
	}
}

func TestSocketAdmitsAttachmentOnlyTerraformRuleAndThreadFollowup(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, _, err := st.UpsertStandingRule(ctx, core.StandingRule{
		ChannelID: "CPLAN", Repository: "repo", Trigger: "terraform_plan",
		Action: "review_terraform_plan", SourceKind: "any",
		SourceRef: "EvRule", ActorID: cfg.Slack.Operators[0],
		ExpiresAt: time.Now().UTC().Add(time.Hour),
	}, cfg.Limits.MaxStandingRules, cfg.Limits.MaxRulesPerChannel); err != nil {
		t.Fatal(err)
	}
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, socket,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}

	admit := func(envelope, eventID string, message *slackevents.MessageEvent) {
		t.Helper()
		payload, _ := json.Marshal(map[string]any{"event_id": eventID})
		svc.admitEventsAPI(ctx, socketmode.Event{
			Type: socketmode.EventTypeEventsAPI,
			Data: slackevents.EventsAPIEvent{
				TeamID:     cfg.Slack.TeamID,
				InnerEvent: slackevents.EventsAPIInnerEvent{Data: message},
			},
			Request: &socketmode.Request{EnvelopeID: envelope, Payload: payload},
		})
	}

	rootTS := "1700.700"
	terraformAttachment := slack.Attachment{
		Pretext: "Run notification for <https://app.terraform.io/app/acme/infra|acme/infra>",
		Title:   "Run run-abc", TitleLink: "https://app.terraform.io/app/acme/infra/runs/run-abc",
		Text: "main deadbeef (gh run 123)",
	}
	admit("env-plan", "EvPlan", &slackevents.MessageEvent{
		SubType: "bot_message", BotID: "BTERRAFORM", Channel: "CPLAN",
		TimeStamp: rootTS, Message: &slack.Msg{
			SubType: "bot_message", BotID: "BTERRAFORM", Timestamp: rootTS,
			Attachments: []slack.Attachment{
				terraformAttachment,
				{Title: "Run Planning", Fallback: "Run run-abc - Run Planning"},
			},
		},
	})
	pending, err := st.LeaseSlackInput(ctx)
	if err != nil || pending.Kind != "bot_message" ||
		!strings.Contains(pending.Text, "Run Planning") {
		t.Fatalf("intermediate Terraform lifecycle message = %+v, %v", pending, err)
	}
	if err := st.FinishSlackInput(ctx, pending.ID); err != nil {
		t.Fatal(err)
	}

	admit("env-followup", "EvFollowup", &slackevents.MessageEvent{
		User: "U123ABC", Channel: "CPLAN", TimeStamp: "1700.701",
		ThreadTimeStamp: rootTS, Text: "Can you review this plan?",
	})
	followup, err := st.LeaseSlackInput(ctx)
	if err != nil || followup.Kind != "message" || followup.ThreadTS != rootTS {
		t.Fatalf("Terraform thread follow-up = %+v, %v", followup, err)
	}
	if err := st.FinishSlackInput(ctx, followup.ID); err != nil {
		t.Fatal(err)
	}

	admit("env-planned", "EvPlanned", &slackevents.MessageEvent{
		SubType: slack.MsgSubTypeMessageChanged, Channel: "CPLAN", TimeStamp: rootTS,
		Message: &slack.Msg{
			SubType: "bot_message", BotID: "BTERRAFORM", Timestamp: rootTS,
			Attachments: []slack.Attachment{
				terraformAttachment,
				{Title: "Run Planned", Fallback: "Run run-abc - Run Planned"},
			},
		},
	})
	updated, err := st.LeaseSlackInput(ctx)
	if err != nil || updated.Kind != "bot_message" ||
		!strings.Contains(updated.Text, "Run Planned") {
		t.Fatalf("updated Terraform plan = %+v, %v", updated, err)
	}
	if socket.acks != 3 {
		t.Fatalf("acknowledgements = %d, want 3", socket.acks)
	}
}

func TestSlashProactiveOffPreemptsQueuedChannelMessage(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	message := core.SlackInput{
		ID: "slack-before-off", EnvelopeID: "env-before-off", EventID: "event-before-off",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.700", UserID: "U123ABC", Text: "Please investigate this alert.",
	}
	command := core.SlackInput{
		ID: "slash-off", EnvelopeID: "env-slash-off", EventID: "event-slash-off",
		Kind: "slash", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		UserID: "U123ABC", Text: "proactive off", ActionID: "/responder",
	}
	for _, input := range []core.SlackInput{message, command} {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", input.ID, created, err)
		}
	}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	commandState, err := st.GetSlackInput(ctx, command.ID)
	if err != nil || commandState.State != "done" {
		t.Fatalf("priority command = %+v, %v", commandState, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	messageState, err := st.GetSlackInput(ctx, message.ID)
	if err != nil || messageState.State != "done" {
		t.Fatalf("suppressed message = %+v, %v", messageState, err)
	}
	if len(coopClient.createKeys) != 0 || len(coopClient.submitKeys) != 0 {
		t.Fatalf("disabled message reached Coop: create=%v submit=%v",
			coopClient.createKeys, coopClient.submitKeys)
	}
}
