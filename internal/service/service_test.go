package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/emisar"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"
)

func TestReviewSummaryTreatsMissingGateAsRecommendation(t *testing.T) {
	summary := reviewSummary(coop.Review{
		Gate:   "none",
		Rebase: "clean",
		NotPublishableReasons: []string{
			"gate_not_configured",
			"gate_modified_candidate",
		},
	})
	for _, want := range []string{
		"Repository gate: not configured (recommended)",
		"can still open a draft PR",
		"must leave the reviewed source unchanged",
	} {
		if !strings.Contains(summary, want) {
			t.Fatalf("summary does not explain %q:\n%s", want, summary)
		}
	}
	for _, raw := range []string{"gate_not_configured", "gate_modified_candidate"} {
		if strings.Contains(summary, raw) {
			t.Fatalf("summary leaked machine reason %q:\n%s", raw, summary)
		}
	}
}

func TestPublicationReviewDoesNotHideRealBlockers(t *testing.T) {
	review := publicationReview(coop.Review{
		Gate:      "none",
		Rebase:    "conflict",
		GateError: "",
		NotPublishableReasons: []string{
			"gate_not_configured",
			"rebase_conflict",
		},
	})
	if review.Publishable || len(review.NotPublishableReasons) != 1 ||
		review.NotPublishableReasons[0] != "rebase_conflict" {
		t.Fatalf("ungated review hid blocker = %+v", review)
	}

	review = publicationReview(coop.Review{
		Gate: "none", Rebase: "clean",
		NotPublishableReasons: []string{"gate_not_configured"},
		PolicyFindings:        []string{"generated file is not allowed"},
	})
	if review.Publishable {
		t.Fatalf("ungated review ignored policy finding = %+v", review)
	}
}

func TestPublicationReviewDeliveryIDDeduplicatesOnlyIdenticalResults(t *testing.T) {
	base := coop.Review{
		CandidateTree: "candidate-tree", Rebase: "conflict", Gate: "none",
		NotPublishableReasons: []string{"rebase_conflict"},
	}
	first := publicationReviewDeliveryID("inc_1", base)
	if again := publicationReviewDeliveryID("inc_1", base); again != first {
		t.Fatalf("identical review delivery IDs differ: %q != %q", first, again)
	}
	base.Rebase = "clean"
	base.NotPublishableReasons = nil
	if changed := publicationReviewDeliveryID("inc_1", base); changed == first {
		t.Fatalf("changed review reused delivery ID %q", changed)
	}
}

func TestPublicationTransitionsAndExactReferenceMatching(t *testing.T) {
	publication := core.Publication{PRNumber: 493}
	old := core.PublicationFollowup{PRState: "open", ChecksState: "pending"}
	current := core.PublicationFollowup{PRState: "open", ChecksState: "passing"}
	kind, state, summary := publicationTransition(
		publication, old, current,
		core.PublicationLifecycleStatus{ChecksTotal: 4, ChecksPassed: 4}, false,
		14*24*time.Hour,
	)
	if kind != "checks" || state != "succeeded" || !strings.Contains(summary, "4 of 4") {
		t.Fatalf("passing transition = %q, %q, %q", kind, state, summary)
	}

	context := core.PublicationContext{
		PRNumber: 493, PRURL: "https://github.com/org/repo/pull/493",
		HeadBranch: "responder/reduce-redis", HeadSHA: "0123456789abcdef",
		MergeSHA: "abcdef0123456789",
	}
	if !publicationReferenceMatches(
		"Deployed commit abcdef0 to production", "abcdef0", context,
	) {
		t.Fatal("exact merge SHA prefix was not accepted")
	}
	if publicationReferenceMatches(
		"A deploy happened in org/repo", "org/repo", context,
	) {
		t.Fatal("repository-only correlation was accepted")
	}
	if publicationReferenceMatches(
		"Deployed a different commit", "0123456", context,
	) {
		t.Fatal("reference absent from the source message was accepted")
	}
	if !publicationContextAppearsInText(
		"Terraform applied main at abcdef0123456789", context,
	) {
		t.Fatal("exact merge SHA did not activate delivery correlation")
	}
	if publicationContextAppearsInText("Terraform applied org/repo", context) {
		t.Fatal("repository-only text activated delivery correlation")
	}
}

func TestPublicationUpdateReturnsToOriginalTaskThreadAndDeduplicates(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident, _, err := st.CreateEngineeringTask(
		ctx, "repo", "source-publication", "Reduce Redis pool", "summary",
		"U123ABC", "CTASKS", "1700.100", 100,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindThreadWork(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	publication := core.Publication{
		IncidentID: incident.ID, Repository: "owner/repository", BaseBranch: "main",
		HeadBranch: "responder/reduce-redis", ParentHead: "parent", CandidateTree: "tree",
		CommitSHA: "commit", RemoteSHA: "0123456789abcdef", PRNumber: 493,
		PRURL: "https://github.com/owner/repository/pull/493", State: "published",
		PublishedAt: time.Now().UTC(),
	}
	if err := st.SavePublication(ctx, publication); err != nil {
		t.Fatal(err)
	}
	if err := st.EnsurePublicationFollowup(ctx, incident.ID, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	input := core.SlackInput{
		ID: "input-deploy-1", Kind: "bot_message", ChannelID: "CDEPLOY",
		MessageTS: "1700.200", Text: "Deployment of 0123456 completed successfully.",
	}
	state := watchTurnState{ActivePublications: []core.PublicationContext{{
		IncidentID: incident.ID, PRNumber: 493, PRURL: publication.PRURL,
		HeadBranch: publication.HeadBranch, HeadSHA: publication.RemoteSHA,
	}}}
	updates := []publicationUpdate{{
		IncidentID: incident.ID, Kind: "deployment", State: "succeeded",
		Reference: "0123456", Summary: "Production deployment completed successfully.",
	}}
	if err := svc.applyPublicationUpdates(ctx, input, state, updates); err != nil {
		t.Fatal(err)
	}
	if err := svc.applyPublicationUpdates(ctx, input, state, updates); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.posts) != 1 {
		t.Fatalf("publication update posts = %d, want 1", len(slackClient.posts))
	}
	post := slackClient.posts[0]
	if post.channel != "CTASKS" || post.thread != "1700.100" ||
		!strings.Contains(post.message.Text, "Production deployment completed") {
		t.Fatalf("publication update post = %+v", post)
	}
}

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
	message := slackui.ConversationResponse("CPU stayed below saturation.", slackui.NewSanitizer(12000))
	if err := svc.enqueueGeneratedVisuals(ctx, "out_test", "", "C123", "1700.001", "ses_1", "turn_visual", []core.GeneratedVisual{{
		Artifact: "load.png", Title: "Production load", AltText: "Line chart of production load over 24 hours.",
	}}, &message); err != nil {
		t.Fatal(err)
	}
	if delivery, err := st.GetSlackDelivery(ctx, "out_test_visual_01"); err != nil {
		t.Fatalf("queued visual delivery = %+v err=%v", delivery, err)
	}
	if err := svc.processSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.uploads) != 1 || slackClient.uploads[0].thread != "1700.001" ||
		slackClient.uploads[0].upload.Title != "Production load" ||
		slackClient.uploads[0].upload.Message == nil ||
		!strings.Contains(slackClient.uploads[0].upload.Message.Text, "below saturation") ||
		!strings.Contains(slackClient.uploads[0].upload.Filename, "out_test_visual_01") {
		t.Fatalf("upload = %+v", slackClient.uploads)
	}
	time.Sleep(2100 * time.Millisecond)
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
	if err := svc.enqueueGeneratedVisuals(ctx, "out_scope", "", "C123", "1700.001", "ses_1", "turn_visual", []core.GeneratedVisual{{
		Artifact: "load.png", Title: "Production load", AltText: "Line chart of production load over 24 hours.",
	}}, &message); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("success text posted before failed upload: %+v", slackClient.posts)
	}
	delivery, err := st.GetSlackDelivery(ctx, "out_scope_visual_01")
	if err != nil || delivery.State != "failed" || !strings.Contains(delivery.LastError, "missing_scope") {
		t.Fatalf("visual delivery = %+v err=%v", delivery, err)
	}
	if err := svc.processSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "files:write") ||
		!strings.Contains(slackClient.posts[0].message.Text, "CPU stayed below saturation") {
		t.Fatalf("upload failure reply = %+v", slackClient.posts)
	}
}

func TestGeneratedVisualLegacyUncertainMissingScopeFailsImmediately(t *testing.T) {
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
	slackClient := &fakeSlack{}
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.enqueueGeneratedVisuals(ctx, "out_legacy", "", "C123", "1700.001", "ses_1", "turn_visual", []core.GeneratedVisual{{
		Artifact: "load.png", Title: "Production load", AltText: "Line chart of production load over 24 hours.",
	}}, nil); err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseSlackDelivery(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.RetrySlackDelivery(
		ctx, leased.ID, "GetUploadURLExternal: missing_scope", time.Now(), true, false,
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.reconcileSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.historyRequests) != 0 {
		t.Fatalf("definitive missing_scope was reconciled through Slack history: %+v", slackClient.historyRequests)
	}
	delivery, err := st.GetSlackDelivery(ctx, "out_legacy_visual_01")
	if err != nil || delivery.State != "failed" {
		t.Fatalf("legacy visual delivery = %+v err=%v", delivery, err)
	}
	if err := svc.processSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 1 || !strings.Contains(slackClient.posts[0].message.Text, "files:write") {
		t.Fatalf("legacy upload failure reply = %+v", slackClient.posts)
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
				ctx, "out_"+name, "", "C123", "1700.1", "ses_1", "turn_visual",
				[]core.GeneratedVisual{visual}, nil,
			); err == nil {
				t.Fatal("untrusted generated visual was accepted")
			}
		})
	}
}

func TestEmisarApprovalMonitorUpdatesCardAndQueuesOneContinuation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack_approval_monitor", EnvelopeID: "env_approval_monitor",
		EventID: "EvApprovalMonitor", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.100", UserID: "U123ABC",
		Text: "Enable the exact governed setting.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit input = %t, %v", created, err)
	}
	approval, created, err := st.RecordEmisarApproval(ctx, core.EmisarApproval{
		RequestID: "apr_monitor", ChannelID: input.ChannelID,
		SourceInput: input.ID, RequestedBy: input.UserID,
		RunID: "run_monitor", OperationID: "op_monitor",
		ActionID: "service.enable", PackRef: "service@1#sha256:abc",
		RunnerRef: "prod~abc", Status: "pending_approval",
		ApprovalURL: "https://emisar.dev/app/acme/approvals/apr_monitor",
		ExpiresAt:   time.Now().UTC().Add(time.Hour),
	})
	if err != nil || !created {
		t.Fatalf("record approval = %+v, %t, %v", approval, created, err)
	}
	body, err := slackui.Encode(slackui.WithEmisarApproval(
		slackui.ConversationResponse("Ready for approval.", slackui.NewSanitizer(12000)),
		approval,
	))
	if err != nil {
		t.Fatal(err)
	}
	deliveryID := "watch_reply_" + input.ID
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: deliveryID, Operation: "post", Kind: "notice",
		ChannelID: input.ChannelID, ThreadTS: input.MessageTS, Body: body,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BindEmisarApprovalDelivery(ctx, approval.RequestID, deliveryID); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, slackClient, nil, slackui.NewSanitizer(12000), nil)
	emisarClient := &fakeEmisar{state: emisar.RunState{
		RunID: approval.RunID, OperationID: approval.OperationID,
		ActionID: approval.ActionID, PackRef: approval.PackRef,
		RunnerRef: approval.RunnerRef, Status: "success",
		RunURL: "https://emisar.dev/app/acme/runs/run_monitor",
	}}
	svc.SetEmisar(emisarClient)
	if err := svc.processSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processEmisarApproval(ctx, approval.RequestID); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetEmisarApproval(ctx, approval.RequestID)
	if err != nil || stored.Status != "success" || !stored.ContinuationQueued ||
		stored.MessageTS == "" || stored.RunURL == "" {
		t.Fatalf("monitored approval = %+v, %v", stored, err)
	}
	run, err := st.GetAgentRunBySource(
		ctx,
		"emisar_approval:"+approval.RequestID,
		input.ID,
	)
	if err != nil || run.Prompt == "" || run.Mode != core.AgentRunTriage {
		t.Fatalf("approval continuation = %+v, %v", run, err)
	}
	state, err := decodeWatchRunContext(run)
	if err != nil || !state.ApprovalContinuation ||
		state.ReplyDeliveryID != "emisar_approval_reply_"+approval.RequestID {
		t.Fatalf("approval continuation state = %+v, %v", state, err)
	}
	if err := svc.processEmisarApproval(ctx, approval.RequestID); err != nil {
		t.Fatal(err)
	}
	if emisarClient.calls != 1 {
		t.Fatalf("terminal approval was polled again: %d calls", emisarClient.calls)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.updates) != 1 ||
		slackClient.updates[0].message.Header != "Emisar action completed" {
		t.Fatalf("approval Slack update = %+v", slackClient.updates)
	}
}

func TestEmisarApprovalMonitorFailsClosedOnIdentityMismatch(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	approval, _, err := st.RecordEmisarApproval(ctx, core.EmisarApproval{
		RequestID: "apr_mismatch", ChannelID: "CWATCH",
		SourceInput: "slack_mismatch", RequestedBy: "U123ABC",
		RunID: "run_mismatch", OperationID: "op_expected",
		ActionID: "service.enable", PackRef: "service@1#sha256:abc",
		RunnerRef: "prod~abc", Status: "pending_approval",
		ApprovalURL: "https://emisar.dev/app/acme/approvals/apr_mismatch",
		ExpiresAt:   time.Now().UTC().Add(time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.SetEmisar(&fakeEmisar{state: emisar.RunState{
		RunID: approval.RunID, OperationID: "op_other",
		ActionID: approval.ActionID, PackRef: approval.PackRef,
		RunnerRef: approval.RunnerRef, Status: "success",
	}})
	if err := svc.processEmisarApproval(ctx, approval.RequestID); err == nil ||
		!strings.Contains(err.Error(), "immutable identity") {
		t.Fatalf("identity mismatch error = %v", err)
	}
	stored, err := st.GetEmisarApproval(ctx, approval.RequestID)
	if err != nil || stored.Status != "pending_approval" || stored.ContinuationQueued {
		t.Fatalf("mismatched approval was advanced = %+v, %v", stored, err)
	}
}

func TestEmisarApprovalMonitorPersistsProgressWithoutQueueingContinuation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	approval, _, err := st.RecordEmisarApproval(ctx, core.EmisarApproval{
		RequestID: "apr_running", ChannelID: "CWATCH",
		SourceInput: "slack_running", RequestedBy: "U123ABC",
		RunID: "run_running", OperationID: "op_running",
		ActionID: "service.enable", PackRef: "service@1#sha256:abc",
		RunnerRef: "prod~abc", Status: "pending_approval",
		ApprovalURL: "https://emisar.dev/app/acme/approvals/apr_running",
		ExpiresAt:   time.Now().UTC().Add(time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	emisarClient := &fakeEmisar{state: emisar.RunState{
		RunID: approval.RunID, OperationID: approval.OperationID,
		ActionID: approval.ActionID, PackRef: approval.PackRef,
		RunnerRef: approval.RunnerRef, Status: "running",
		RunURL: "https://emisar.dev/app/acme/runs/run_running",
	}}
	svc.SetEmisar(emisarClient)
	if err := svc.processEmisarApproval(ctx, approval.RequestID); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetEmisarApproval(ctx, approval.RequestID)
	if err != nil || stored.Status != "running" || stored.ContinuationQueued ||
		stored.RunURL == "" || !stored.NextCheckAt.After(stored.UpdatedAt) {
		t.Fatalf("running approval = %+v, %v", stored, err)
	}
	if _, err := st.GetAgentRunBySource(
		ctx,
		"emisar_approval:"+approval.RequestID,
		approval.SourceInput,
	); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("nonterminal approval queued a model continuation: %v", err)
	}
}

func TestEmisarApprovalSchedulerRecoversPersistedTerminalRun(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	approval, _, err := st.RecordEmisarApproval(ctx, core.EmisarApproval{
		RequestID: "apr_restart", ChannelID: "CWATCH",
		SourceInput: "slack_restart", RequestedBy: "U123ABC",
		RunID: "run_restart", OperationID: "op_restart",
		ActionID: "service.enable", PackRef: "service@1#sha256:abc",
		RunnerRef: "prod~abc", Status: "pending_approval",
		ApprovalURL: "https://emisar.dev/app/acme/approvals/apr_restart",
		ExpiresAt:   time.Now().UTC().Add(time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	approval, _, err = st.AdvanceEmisarApproval(
		ctx,
		approval.RequestID,
		"success",
		"https://emisar.dev/app/acme/runs/run_restart",
		"",
		time.Now().UTC(),
	)
	if err != nil {
		t.Fatal(err)
	}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.seedEmisarApprovalWork(ctx); err != nil {
		t.Fatal(err)
	}
	work, err := st.LeaseWork(ctx, store.WorkLaneBackground, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if work.Kind != workEmisarApproval || work.SubjectID != approval.RequestID {
		t.Fatalf("recovered approval work = %+v", work)
	}
}

type fakeEmisar struct {
	state emisar.RunState
	err   error
	calls int
}

func (f *fakeEmisar) WaitForRun(context.Context, string) (emisar.RunState, error) {
	f.calls++
	return f.state, f.err
}

func TestChangesCursorAndNavigationBindPagesToIncidentAndDigest(t *testing.T) {
	digest := strings.Repeat("a", 64)
	value := encodeChangesCursor(changesCursor{
		IncidentID: "incident_123",
		Offset:     changesPatchPageBytes,
		Digest:     digest,
	})
	cursor, ok := decodeChangesCursor(value)
	if !ok || cursor.IncidentID != "incident_123" ||
		cursor.Offset != changesPatchPageBytes || cursor.Digest != digest {
		t.Fatalf("cursor = %+v, %t", cursor, ok)
	}
	if _, ok := decodeChangesCursor(value + "!"); ok {
		t.Fatal("malformed diff cursor was accepted")
	}
	navigation := changesNavigation("incident_123", coop.Changes{
		PatchOffset: 7000, PatchNextOffset: 14000,
		PatchBytes: 15000, PatchHasMore: true, PatchDigest: digest,
	})
	if navigation.Page != 2 || navigation.Pages != 3 ||
		navigation.PreviousValue == "" || navigation.NextValue == "" ||
		navigation.RefreshValue == "" {
		t.Fatalf("navigation = %+v", navigation)
	}
	for _, action := range []struct {
		id    string
		value string
	}{
		{slackui.ActionChangesPrevious, navigation.PreviousValue},
		{slackui.ActionChangesNext, navigation.NextValue},
		{slackui.ActionChangesRefresh, navigation.RefreshValue},
	} {
		incidentID, ok := changesActionIncidentID(action.id, action.value)
		if !ok || incidentID != "incident_123" {
			t.Fatalf("action %s incident = %q, %t", action.id, incidentID, ok)
		}
	}
}

func TestAlertToSlackAndCompletedCoopTurn(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	coopClient := newFakeCoop()
	svc := New(cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	signal := core.Signal{
		Route: "grafana", SourceID: "alert-1", EventID: "signal-event-1",
		Repository: "repo", CorrelationKey: "prod-api", Status: core.SignalFiring,
		Title: "API is unavailable", Severity: "critical", ReceivedAt: time.Now().UTC(),
	}
	if _, _, err := st.AdmitWebhook(ctx, "grafana", "delivery-1", "digest", []core.Signal{signal}); err != nil {
		t.Fatal(err)
	}
	if err := svc.processWebhook(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processChannel(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 1 || incidents[0].RootTS == "" {
		t.Fatalf("root incident = %+v, %v", incidents, err)
	}
	incident := incidents[0]
	if err := svc.processSession(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	incident, _ = st.GetIncident(ctx, incident.ID)
	if incident.CoopSessionID == "" || incident.ActiveTurnID == "" {
		t.Fatalf("Coop binding = %+v", incident)
	}
	if len(slack.statuses) != 1 || slack.statuses[0].text != "is investigating..." ||
		slack.statuses[0].thread != incident.RootTS {
		t.Fatalf("active turn status = %+v", slack.statuses)
	}

	coopClient.complete(`{
	  "message":"Verified the alert. The API process is healthy; the load balancer target is stale.",
	  "coverage":[
	    {"layer":"change","status":"healthy","source":"repository","detail":"The declared backend topology was checked"},
	    {"layer":"host","status":"healthy","source":"Emisar","detail":"The API host is responsive"},
	    {"layer":"runtime","status":"healthy","source":"Emisar","detail":"The API runtime is responsive"},
	    {"layer":"workload","status":"healthy","source":"Emisar","detail":"The API process is running"},
	    {"layer":"dependency","status":"unhealthy","source":"Emisar","detail":"The load balancer target is stale"},
	    {"layer":"application","status":"healthy","source":"Emisar","detail":"The API process responds locally"},
	    {"layer":"slo","status":"degraded","source":"Grafana","detail":"The availability alert is firing"}
	  ],
	  "completion":{"status":"decision_ready","summary":"The stale load balancer target is the bounded failure and should be corrected."}
	}`)
	incident, _ = st.GetIncident(ctx, incident.ID)
	if err := svc.pollIncident(ctx, incident); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	svc.lastPost = time.Time{}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 2 {
		t.Fatalf("Slack posts = %+v", slack.posts)
	}
	if slack.posts[0].thread != "" || slack.posts[1].thread != incident.RootTS {
		t.Fatalf("thread mapping = %+v", slack.posts)
	}
	incident, _ = st.GetIncident(ctx, incident.ID)
	if incident.ActiveTurnID != "" || incident.Workflow != core.WorkflowParked {
		t.Fatalf("terminal workflow = %+v", incident)
	}
	if len(slack.statuses) != 2 || slack.statuses[1].channel != incident.ChannelID ||
		slack.statuses[1].thread != incident.RootTS || slack.statuses[1].text != "" {
		t.Fatalf("terminal turn did not clear its native status: %+v", slack.statuses)
	}
}

func TestAgentRunInterruptedByResponderShutdownIsReplayed(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(
		ctx, incident.ID, "ses_1", "incident-restart", 1,
	); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	svc := New(
		cfg,
		st,
		coopClient,
		&fakeSlack{},
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	run, created, err := svc.queueIncidentAgentRun(
		ctx,
		incident,
		"initial",
		incident.ID,
		"",
		"Investigate the alert.",
	)
	if err != nil || !created {
		t.Fatalf("queue run = %+v, %t, %v", run, created, err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	running, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || running.State != core.AgentRunRunning ||
		running.CoopTurnID != "coop_turn_1" ||
		running.SessionID != coopClient.session.ID {
		t.Fatalf("first submission = %+v, %v", running, err)
	}
	firstKey := running.IdempotencyKey
	coopClient.turn.State = "failed"
	coopClient.turn.ErrorCode = "acp_cancelled"
	coopClient.turn.ErrorDetail = "turn cancelled"
	coopClient.session.ActiveTurnID = ""
	coopClient.session.State = "open"
	coopClient.session.Activity = "parked"
	coopClient.session.Revision++
	coopClient.events = append(coopClient.events, coop.Event{
		ID: "evt_restart", SessionID: coopClient.session.ID, Sequence: 1,
		TurnID: "coop_turn_1", Type: "turn.failed",
	})
	svc.pollAgentRuns(ctx)
	requeued, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || requeued.State != core.AgentRunPending ||
		requeued.Failures != 1 || requeued.CoopTurnID != "" ||
		requeued.ExpectedRevision != 0 ||
		requeued.CoopEventSequence != 1 ||
		requeued.IdempotencyKey == firstKey {
		t.Fatalf("requeued run = %+v, %v", requeued, err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.ActiveTurnID != "" ||
		incident.Workflow != core.WorkflowParked ||
		incident.CoopEventSequence != 1 {
		t.Fatalf("released incident = %+v, %v", incident, err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	replayed, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || replayed.State != core.AgentRunRunning ||
		replayed.CoopTurnID != "coop_turn_2" ||
		replayed.IdempotencyKey != requeued.IdempotencyKey {
		t.Fatalf("replayed run = %+v, %v", replayed, err)
	}
	if len(coopClient.submitKeys) != 2 ||
		coopClient.submitKeys[0] == coopClient.submitKeys[1] {
		t.Fatalf("submission keys = %v", coopClient.submitKeys)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.ActiveTurnID != replayed.CoopTurnID ||
		incident.Workflow != core.WorkflowInvestigating {
		t.Fatalf("replayed incident = %+v, %v", incident, err)
	}
}

func TestExplicitAgentRunCancellationIsTerminal(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "CWATCH", ThreadTS: "1700.100",
		ConversationKey: "thread:CWATCH:1700.100",
		SourceKind:      "watch", SourceID: "explicit-cancel",
		SessionID: "ses_1", Context: []byte("{}"),
	})
	if err != nil || !created {
		t.Fatalf("queue run = %+v, %t, %v", run, created, err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(
		ctx, leased.ID, "coop_turn_1", 2, 0,
	); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.turn = coop.Turn{
		ID: "coop_turn_1", SessionID: "ses_1", State: "cancelled",
		ErrorCode: "acp_cancelled", ErrorDetail: "turn cancelled",
	}
	coopClient.events = []coop.Event{{
		ID: "evt_cancel", SessionID: "ses_1", Sequence: 1,
		TurnID: "coop_turn_1", Type: "turn.cancelled",
	}}
	svc := New(
		cfg,
		st,
		coopClient,
		&fakeSlack{},
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	svc.pollAgentRuns(ctx)
	staged, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || staged.State != core.AgentRunApplying ||
		staged.TerminalState != "cancelled" || staged.Failures != 0 {
		t.Fatalf("explicit cancellation = %+v, %v", staged, err)
	}
}

func TestAgentRunProtocolReplayIsExactAndBounded(t *testing.T) {
	run := core.AgentRun{Failures: 0}
	oversized := coop.Turn{
		ErrorCode:   "acp_protocol_error",
		ErrorDetail: "ACP frame exceeded its bound",
	}
	if reason, replay := replayAgentRunFailure(
		run, "turn.failed", oversized, 20,
	); !replay || !strings.Contains(reason, "oversized ACP frame") {
		t.Fatalf("oversized frame replay = %q, %t", reason, replay)
	}
	run.Failures = 1
	if reason, replay := replayAgentRunFailure(
		run, "turn.failed", oversized, 20,
	); replay || reason != "" {
		t.Fatalf("oversized frame replay was not bounded = %q, %t", reason, replay)
	}
	transcript := coop.Turn{
		ErrorCode:   "acp_protocol_error",
		ErrorDetail: "ACP transcript exceeded its bound",
	}
	run.Mode = core.AgentRunTriage
	for _, failures := range []int{0, 3, 18} {
		run.Failures = failures
		if reason, replay := replayAgentRunFailure(
			run, "turn.failed", transcript, 20,
		); !replay || !strings.Contains(reason, "fresh read-only session") {
			t.Fatalf(
				"transcript overflow %d replay = %q, %t",
				failures,
				reason,
				replay,
			)
		}
	}
	run.Failures = 19
	if reason, replay := replayAgentRunFailure(
		run, "turn.failed", transcript, 20,
	); replay || reason != "" {
		t.Fatalf("transcript overflow ignored configured poison budget = %q, %t", reason, replay)
	}
	run.Mode = core.AgentRunIncident
	run.Failures = 0
	if reason, replay := replayAgentRunFailure(
		run, "turn.failed", transcript, 20,
	); replay || reason != "" {
		t.Fatalf("writable transcript overflow replayed = %q, %t", reason, replay)
	}
	cleanupFailure := coop.Turn{
		ErrorCode:   "acp_protocol_error",
		ErrorDetail: "turn cleanup failed",
	}
	for failures := 0; failures < 2; failures++ {
		run.Failures = failures
		if reason, replay := replayAgentRunFailure(
			run, "turn.failed", cleanupFailure, 20,
		); !replay || !strings.Contains(reason, "retrying") {
			t.Fatalf(
				"cleanup failure %d replay = %q, %t",
				failures,
				reason,
				replay,
			)
		}
	}
	run.Failures = 2
	if reason, replay := replayAgentRunFailure(
		run, "turn.failed", cleanupFailure, 20,
	); replay || reason != "" {
		t.Fatalf("cleanup failure replay was not bounded = %q, %t", reason, replay)
	}
	childClosed := coop.Turn{
		ErrorCode:   "acp_process_error",
		ErrorDetail: "ACP child closed before its response",
	}
	run.Mode = core.AgentRunTriage
	for failures := 0; failures < 19; failures++ {
		run.Failures = failures
		if reason, replay := replayAgentRunFailure(
			run, "turn.failed", childClosed, 20,
		); !replay || !strings.Contains(reason, "fresh read-only session") {
			t.Fatalf(
				"ACP process failure %d replay = %q, %t",
				failures,
				reason,
				replay,
			)
		}
	}
	run.Failures = 19
	if reason, replay := replayAgentRunFailure(
		run, "turn.failed", childClosed, 20,
	); replay || reason != "" {
		t.Fatalf("ACP process failure replay was not bounded = %q, %t", reason, replay)
	}
	run.Mode = core.AgentRunIncident
	run.Failures = 0
	if reason, replay := replayAgentRunFailure(
		run, "turn.failed", childClosed, 20,
	); replay || reason != "" {
		t.Fatalf("writable ACP process failure replayed = %q, %t", reason, replay)
	}
	if !replayAgentRunInFreshSession(childClosed) ||
		!replayAgentRunInFreshSession(transcript) ||
		!replayAgentRunInFreshSession(coop.Turn{
			ErrorCode: "acp_cancelled", ErrorDetail: "turn cancelled",
		}) || replayAgentRunInFreshSession(coop.Turn{
		ErrorCode: "acp_cancelled", ErrorDetail: "operator cancelled",
	}) {
		t.Fatal("fresh-session recovery classification is not exact")
	}
	run.Failures = 0
	for _, candidate := range []struct {
		event string
		turn  coop.Turn
	}{
		{event: "turn.cancelled", turn: oversized},
		{
			event: "turn.failed",
			turn: coop.Turn{
				ErrorCode: "acp_protocol_error", ErrorDetail: "invalid ACP response",
			},
		},
		{
			event: "turn.failed",
			turn: coop.Turn{
				ErrorCode: "acp_cancelled", ErrorDetail: "operator cancelled",
			},
		},
	} {
		if reason, replay := replayAgentRunFailure(
			run, candidate.event, candidate.turn, 20,
		); replay || reason != "" {
			t.Fatalf(
				"unrelated failure replayed: event=%s turn=%+v reason=%q",
				candidate.event,
				candidate.turn,
				reason,
			)
		}
	}
	if reason, replay := replayAgentRunFailure(
		run, "turn.failed", oversized, 1,
	); replay || reason != "" {
		t.Fatalf("configured terminal attempt replayed = %q, %t", reason, replay)
	}
}

func TestAgentRunACPProcessFailureRotatesSlackInvestigationSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CPROCESS"}
	cfg.Slack.WatchChannels = nil
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-process-recovery", EnvelopeID: "env-process-recovery",
		EventID: "event-process-recovery", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CPROCESS", MessageTS: "1700.710", UserID: "U123ABC",
		Text: "<@U999BOT> graph the last seven days of Cassandra CPU load",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack input = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	coopClient.submitTurns = []coop.Turn{
		{
			State:       "failed",
			ErrorCode:   "acp_process_error",
			ErrorDetail: "ACP child closed before its response",
		},
		{
			State: "completed",
			AssistantMessage: `{
				"action":"reply",
				"message":"The seven-day Cassandra CPU graph is ready."
			}`,
		},
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	requeued, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || requeued.State != core.AgentRunPending || requeued.Failures != 1 {
		t.Fatalf("requeued process failure = %+v, %v", requeued, err)
	}
	firstSession := requeued.SessionID
	coopClient.openAfterCreateKey = "responder:watch-session:CPROCESS:2"
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	completed, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || completed.State != core.AgentRunCompleted ||
		completed.SessionID == firstSession || completed.SessionGeneration != 2 {
		t.Fatalf("recovered Slack run = %+v, %v", completed, err)
	}
	if len(coopClient.submitPrompts) != 2 ||
		!strings.Contains(coopClient.submitPrompts[1], "<host-transport-recovery>") ||
		!strings.Contains(coopClient.submitPrompts[1], "Long task duration is not a reason to stop") {
		t.Fatalf("process recovery prompts = %+v", coopClient.submitPrompts)
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "graph is ready") ||
		strings.Contains(slackClient.posts[0].message.Text, "could not complete") {
		t.Fatalf("process recovery result = %+v", slackClient.posts)
	}
}

func TestAgentRunTranscriptOverflowRotatesSlackSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"COVERFLOW"}
	cfg.Slack.WatchChannels = nil
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-transcript-overflow", EnvelopeID: "env-transcript-overflow",
		EventID: "event-transcript-overflow", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "COVERFLOW", MessageTS: "1700.700", UserID: "U123ABC",
		Text: "<@U999BOT> please check all pull zones again and make sure we do not have any unresolved traffic spikes from the last two weeks",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack input = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	coopClient.submitTurns = []coop.Turn{
		{
			State:       "failed",
			ErrorCode:   "acp_protocol_error",
			ErrorDetail: "ACP transcript exceeded its bound",
		},
		{
			State: "completed",
			AssistantMessage: `{
				"action":"reply",
				"message":"All pull zones were checked with bounded current and historical queries."
			}`,
		},
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	requeued, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || requeued.State != core.AgentRunPending || requeued.Failures != 1 {
		t.Fatalf("requeued Slack run = %+v, %v", requeued, err)
	}
	firstSession := requeued.SessionID
	coopClient.openAfterCreateKey = "responder:watch-session:COVERFLOW:2"
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	completed, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || completed.State != core.AgentRunCompleted ||
		completed.SessionID == firstSession || completed.SessionGeneration != 2 {
		t.Fatalf("completed Slack run = %+v, %v", completed, err)
	}
	if len(coopClient.submitPrompts) != 2 ||
		!strings.Contains(coopClient.submitPrompts[0], "<host-tool-transport>") ||
		!strings.Contains(coopClient.submitPrompts[1], "<host-transport-recovery>") ||
		!strings.Contains(coopClient.submitPrompts[1], "tightly filtered queries") ||
		!strings.Contains(coopClient.submitPrompts[1], "check all pull zones again") {
		t.Fatalf("Slack recovery prompts = %+v", coopClient.submitPrompts)
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "All pull zones were checked") ||
		strings.Contains(slackClient.posts[0].message.Text, "could not complete") {
		t.Fatalf("Slack continuation result = %+v", slackClient.posts)
	}
}

func TestEvaluationTurnCleanupRetryIsBoundedAndRecovers(t *testing.T) {
	client := newFakeCoop()
	client.submitTurns = []coop.Turn{
		{
			State:       "failed",
			ErrorCode:   "acp_protocol_error",
			ErrorDetail: "turn cleanup failed",
		},
		{
			State:       "failed",
			ErrorCode:   "acp_protocol_error",
			ErrorDetail: "turn cleanup failed",
		},
		{
			State:            "completed",
			AssistantMessage: `{"action":"ignore"}`,
		},
	}
	response, turnID, calls, err := runEvaluationTurnWithRetry(
		context.Background(),
		client,
		client.session.ID,
		"responder:test-eval-turn",
		"evaluate",
		time.Millisecond,
	)
	if err != nil {
		t.Fatal(err)
	}
	if response != `{"action":"ignore"}` || turnID == "" || calls != 3 {
		t.Fatalf(
			"retry result = response %q, turn %q, calls %d",
			response,
			turnID,
			calls,
		)
	}
	if want := []string{
		"responder:test-eval-turn",
		"responder:test-eval-turn:cleanup-retry:1",
		"responder:test-eval-turn:cleanup-retry:2",
	}; !slices.Equal(client.submitKeys, want) {
		t.Fatalf("retry keys = %v, want %v", client.submitKeys, want)
	}
}

func TestReadyRequiresFreshSchedulerHeartbeatsAndDueWork(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.WorkerStallAfter.Duration = time.Second
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	socket := &fakeSocket{connected: true}
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		&fakeSlack{},
		socket,
		slackui.NewSanitizer(12000),
		nil,
	)
	if err := svc.seedScheduledWork(ctx); err != nil {
		t.Fatal(err)
	}
	svc.initialized.Store(true)
	svc.running.Store(true)
	svc.coopHealthy.Store(true)
	now := time.Now().UTC()
	for _, lane := range []string{
		store.WorkLaneControl,
		store.WorkLaneBackground,
		store.WorkLaneMaintenance,
	} {
		svc.heartbeats.mark(lane, now)
	}
	if ready, reason := svc.Ready(ctx); !ready || reason != "ready" {
		t.Fatalf("fresh readiness = %v, %q", ready, reason)
	}

	svc.heartbeats.mark(store.WorkLaneControl, now.Add(-2*time.Second))
	if ready, reason := svc.Ready(ctx); ready || reason != "control worker stalled" {
		t.Fatalf("stale heartbeat readiness = %v, %q", ready, reason)
	}

	svc.heartbeats.mark(store.WorkLaneControl, time.Now().UTC())
	if err := st.EnqueueWork(ctx, store.WorkItem{
		Kind: "stale_test", SubjectID: "due", Lane: store.WorkLaneControl,
		Priority: 1, AvailableAt: now.Add(-2 * time.Second),
	}); err != nil {
		t.Fatal(err)
	}
	if ready, reason := svc.Ready(ctx); ready || reason != "control queue stalled" {
		t.Fatalf("stale queue readiness = %v, %q", ready, reason)
	}
}

func TestOperatorRequestedEmisarApprovalReachesIncidentThread(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(
		ctx, incident.ID, "ses_1", "incident-api", 1,
	); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	input := core.SlackInput{
		ID: "slack-operational-action", EnvelopeID: "env-operational-action",
		EventID: "event-operational-action", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: incident.ChannelID, ThreadTS: incident.RootTS, MessageTS: "1700.002",
		UserID: cfg.Slack.Operators[0], Text: "Restart the failed allocation on prod-1.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit operator request = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	expires := time.Now().UTC().Add(time.Hour).Truncate(time.Second)
	coopClient.complete(fmt.Sprintf(`{
	  "message":"Emisar paused the requested restart before execution.",
	  "evidence":[],
	  "coverage":[],
	  "memory":{},
	  "pending_approval":{
	    "request_id":"apr_123",
	    "run_id":"run_123",
	    "operation_id":"op_123",
	    "action_id":"nomad.alloc_restart",
	    "pack_ref":"nomad@1.2.3#sha256:abc",
	    "runner_ref":"prod-1~abc123",
	    "status":"pending_approval",
	    "approval_url":"https://emisar.dev/app/acme/approvals/apr_123",
	    "expires_at":%q
	  },
	  "proposals":[]
	}`, expires.Format(time.RFC3339)))
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.pollIncident(ctx, incident); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.posts) != 1 {
		t.Fatalf("approval posts = %+v", slackClient.posts)
	}
	post := slackClient.posts[0]
	if post.thread != incident.RootTS ||
		post.message.Header != "Approval required in Emisar" ||
		len(post.message.Actions) != 1 ||
		post.message.Actions[0].ID != slackui.ActionOpenApproval ||
		post.message.Actions[0].URL != "https://emisar.dev/app/acme/approvals/apr_123" {
		t.Fatalf("approval thread card = %+v", post)
	}
	stored, err := st.GetEmisarApproval(ctx, "apr_123")
	if err != nil || stored.RunID != "run_123" {
		t.Fatalf("stored approval = %+v, %v", stored, err)
	}
}

func TestMixedCapacityBatchDispatchesAcceptedIncidentUpdate(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxOpenIncidents = 1
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	existing := core.Signal{
		Route: "grafana", SourceID: "alert-1", EventID: "event-1",
		Repository: "repo", CorrelationKey: "existing", Status: core.SignalFiring,
		Title: "Existing incident", ReceivedAt: time.Now().UTC(),
	}
	incidents, err := st.ApplySignals(
		ctx, core.WebhookEvent{Signals: []core.Signal{existing}}, time.Hour, 0, 1,
	)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("existing incident = %+v, %v", incidents, err)
	}
	if err := st.SetChannel(ctx, incidents[0].ID, "CINCIDENT", "inc-existing"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incidents[0].ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	resolved := existing
	resolved.EventID = "event-resolved"
	resolved.Status = core.SignalResolved
	deferred := existing
	deferred.SourceID = "alert-2"
	deferred.EventID = "event-new"
	deferred.CorrelationKey = "new"
	if _, _, err := st.AdmitWebhook(
		ctx, "grafana", "delivery-mixed", "digest-mixed", []core.Signal{resolved, deferred},
	); err != nil {
		t.Fatal(err)
	}
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processWebhook(ctx); err != nil {
		t.Fatal(err)
	}
	dirty, err := st.ListDirtyCards(ctx, 10)
	if err != nil || len(dirty) != 1 || dirty[0].ID != incidents[0].ID {
		t.Fatalf("accepted incident card was not refreshed: %+v, %v", dirty, err)
	}
	updated, err := st.GetIncident(ctx, incidents[0].ID)
	if err != nil || updated.Status != core.IncidentMonitoring || updated.FiringCount != 0 {
		t.Fatalf("accepted incident was not updated: %+v, %v", updated, err)
	}
	metrics, err := st.Metrics(ctx)
	if err != nil || metrics.WebhooksPending != 1 {
		t.Fatalf("deferred webhook was not retained: %+v, %v", metrics, err)
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
	if _, err := st.LeaseSlackDelivery(ctx); !errors.Is(err, store.ErrNotFound) {
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

func TestExplicitMentionRepliesOutsideConfiguredChannelsWithoutCreatingIncident(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"COTHER"}
	cfg.Slack.WatchChannels = nil
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-summon-question", EnvelopeID: "envelope-summon-question",
		EventID: "event-summon-question", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CUNCONFIGURED", MessageTS: "1700.000", UserID: "U123ABC",
		Text: "<@U999BOT> how is the health of our infrastructure?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack input = %v, %v", created, err)
	}
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
	  "action":"reply",
	  "message":"I checked current infrastructure state and found no active alerts.",
	  "coverage":[
	    {"layer":"change","status":"healthy","source":"repository","detail":"The deployed revision matches the declared revision"},
	    {"layer":"host","status":"healthy","source":"Emisar","detail":"All declared hosts are connected"},
	    {"layer":"runtime","status":"healthy","source":"Emisar","detail":"The host runtimes are responsive"},
	    {"layer":"workload","status":"healthy","source":"Emisar","detail":"All declared workloads are running"},
	    {"layer":"dependency","status":"healthy","source":"Emisar","detail":"Declared dependencies passed their checks"},
	    {"layer":"application","status":"healthy","source":"monitoring","detail":"Application probes are passing"},
	    {"layer":"slo","status":"healthy","source":"monitoring","detail":"No SLO alerts are active"}
	  ],
	  "completion":{"status":"decision_ready","verdict":"healthy","summary":"The checked production scope is healthy."}
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "no active alerts") {
		t.Fatalf("summon reply = %+v", slackClient.posts)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("summon question created incident = %+v, %v", incidents, err)
	}
	if len(coopClient.submitPrompts) != 1 ||
		!strings.Contains(coopClient.submitPrompts[0], `"mentions_responder":true`) {
		t.Fatalf("explicit mention did not use watched triage: %+v", coopClient.submitPrompts)
	}

	for name, threadTS := range map[string]string{
		"top-level continuation":    "",
		"thread started from reply": "1700.001",
	} {
		t.Run(name, func(t *testing.T) {
			admit, err := svc.shouldAdmitChannelMessage(ctx, core.SlackInput{
				Kind: "message", ChannelID: input.ChannelID,
				ThreadTS: threadTS, MessageTS: "1700.010", UserID: input.UserID,
				Text: "How were you able to verify that?",
			})
			if err != nil || !admit {
				t.Fatalf("continuation admission = %t, %v", admit, err)
			}
		})
	}
	if active, err := st.HasRecentWatchReply(
		ctx,
		input.ChannelID,
		"",
		"1700.010",
		time.Now().UTC().Add(time.Minute),
	); err != nil || active {
		t.Fatalf("expired continuation = %t, %v", active, err)
	}
	if active, err := st.HasRecentWatchReply(
		ctx,
		input.ChannelID,
		"",
		"1700.0005",
		time.Now().UTC().Add(-time.Minute),
	); err != nil || active {
		t.Fatalf("message preceding reply continuation = %t, %v", active, err)
	}

	followup := core.SlackInput{
		ID: "slack-summon-followup", EnvelopeID: "envelope-summon-followup",
		EventID: "event-summon-followup", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: input.ChannelID, MessageTS: "1700.010", UserID: input.UserID,
		Text: "How were you able to verify that?",
	}
	if created, err := st.AdmitSlackInput(ctx, followup); err != nil || !created {
		t.Fatalf("admit continuation = %v, %v", created, err)
	}
	coopClient.completeOnSubmit = `{
		"action":"reply",
		"message":"I used the configured GitHub credentials and checked the current workflow run."
	}`
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 2 ||
		!strings.Contains(slackClient.posts[1].message.Text, "configured GitHub credentials") {
		t.Fatalf("continuation reply = %+v", slackClient.posts)
	}
	if len(coopClient.submitPrompts) != 2 ||
		!strings.Contains(
			coopClient.submitPrompts[1],
			`"conversation_continuation":true`,
		) {
		t.Fatalf("continuation prompt = %+v", coopClient.submitPrompts)
	}
}

func TestDurableSelfInviteRequestDoesNotCreateIncident(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CSUMMON"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-invite-policy", EnvelopeID: "envelope-invite-policy",
		EventID: "event-invite-policy", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CSUMMON", MessageTS: "1700.000", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> when you create an incident channel always invite me into it",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack input = %v, %v", created, err)
	}
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)

	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "already included") ||
		!strings.Contains(slackClient.posts[0].message.Text, "No incident was created") {
		t.Fatalf("self-invite response = %+v", slackClient.posts)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("self-invite request created incident = %+v, %v", incidents, err)
	}
	if slackClient.createChannelCalls != 0 {
		t.Fatalf("self-invite request created %d Slack channels", slackClient.createChannelCalls)
	}
	if len(coopClient.submitPrompts) != 0 {
		t.Fatalf("self-invite request reached model: %+v", coopClient.submitPrompts)
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

func TestManualSummonCompletesHandoffToIncidentRoom(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CSUMMON"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-manual-ready", EnvelopeID: "envelope-ready", EventID: "event-manual-ready",
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
	if err := svc.processSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processChannel(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSession(ctx); err != nil {
		t.Fatal(err)
	}
	for count := 0; count < 4; count++ {
		err := svc.processSlackDelivery(ctx)
		if errors.Is(err, store.ErrNotFound) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	var handoff *slackPost
	for index := range slack.posts {
		if slack.posts[index].message.Header == "Incident room ready" {
			handoff = &slack.posts[index]
		}
	}
	if handoff == nil || handoff.channel != "CSUMMON" || handoff.thread != input.MessageTS ||
		!strings.Contains(handoff.message.Text, "<#CINCIDENT>") {
		t.Fatalf("manual handoff = %+v", slack.posts)
	}
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("manual incident = %+v, %v", incidents, err)
	}
	if err := svc.enqueueManualHandoff(ctx, incidents[0]); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackDelivery(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("manual handoff was not idempotent: %v", err)
	}
}

func TestManualHandoffWaitsForUsableIncidentRoom(t *testing.T) {
	tests := []struct {
		name       string
		rootErr    error
		inviteErr  error
		wantRootTS bool
	}{
		{name: "root delivery uncertain", rootErr: errors.New("Slack timeout")},
		{name: "responder invite fails", inviteErr: errors.New("invite denied"), wantRootTS: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx := context.Background()
			cfg := serviceConfig(t)
			st, err := store.Open(cfg.StateDir)
			if err != nil {
				t.Fatal(err)
			}
			defer st.Close()
			incident, created, err := st.CreateManualIncident(
				ctx, "repo", "manual-source", "Investigate checkout", "Investigate checkout", "U123ABC",
				"CSUMMON", "1700.001", cfg.Limits.MaxOpenIncidents,
			)
			if err != nil || !created {
				t.Fatalf("manual incident = %+v, %v, %v", incident, created, err)
			}
			slack := &fakeSlack{postErr: test.rootErr, inviteErr: test.inviteErr}
			svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
			if err := svc.processChannel(ctx); err != nil {
				t.Fatal(err)
			}
			if err := svc.processSlackDelivery(ctx); err != nil {
				t.Fatal(err)
			}
			sessionErr := svc.processSession(ctx)
			if test.inviteErr != nil {
				if sessionErr == nil || !strings.Contains(sessionErr.Error(), test.inviteErr.Error()) {
					t.Fatalf("session preparation error = %v, want %v", sessionErr, test.inviteErr)
				}
			} else if sessionErr != nil && !errors.Is(sessionErr, store.ErrNotFound) {
				t.Fatal(sessionErr)
			}
			for _, post := range slack.posts {
				if post.message.Header == "Incident room ready" {
					t.Fatalf("handoff announced unusable room: %+v", slack.posts)
				}
			}
			incident, err = st.GetIncident(ctx, incident.ID)
			if err != nil || (incident.RootTS != "") != test.wantRootTS {
				t.Fatalf("root binding = %+v, %v", incident, err)
			}
			if _, err := st.LeaseSlackDelivery(ctx); !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("handoff was queued before room preparation: %v", err)
			}
		})
	}
}

func TestIncidentScopedSchedulerFailureDoesNotBlockAnotherIncident(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	createBound := func(sourceID, channelID, rootTS string) core.Incident {
		t.Helper()
		incident, created, err := st.CreateManualIncident(
			ctx,
			"repo",
			sourceID,
			"Investigate "+sourceID,
			"Investigate "+sourceID,
			"U123ABC",
			"CSOURCE",
			"1700.001",
			cfg.Limits.MaxOpenIncidents,
		)
		if err != nil || !created {
			t.Fatalf("create %s = %+v, %v, %v", sourceID, incident, created, err)
		}
		if err := st.SetChannel(ctx, incident.ID, channelID, "room-"+sourceID); err != nil {
			t.Fatal(err)
		}
		if err := st.SetRoot(ctx, incident.ID, rootTS); err != nil {
			t.Fatal(err)
		}
		incident, err = st.GetIncident(ctx, incident.ID)
		if err != nil {
			t.Fatal(err)
		}
		return incident
	}
	blocked := createBound("blocked", "CBLOCKED", "1700.101")
	healthy := createBound("healthy", "CHEALTHY", "1700.102")
	slack := &fakeSlack{inviteByChannel: map[string]error{
		blocked.ChannelID: errors.New("invite temporarily unavailable"),
	}}
	svc := New(
		cfg, st, newFakeCoop(), slack, nil,
		slackui.NewSanitizer(12000), nil,
	)
	for priority, incident := range []core.Incident{blocked, healthy} {
		if err := st.EnsureWork(ctx, store.WorkItem{
			Kind: workIncidentSession, SubjectID: incident.ID,
			Lane:            store.WorkLaneBackground,
			ConversationKey: "incident:" + incident.ID,
			Priority:        10 + priority,
		}); err != nil {
			t.Fatal(err)
		}
	}
	first, err := st.LeaseWork(ctx, store.WorkLaneBackground, time.Minute)
	if err != nil || first.SubjectID != blocked.ID {
		t.Fatalf("first scheduled incident = %+v, %v", first, err)
	}
	svc.handleScheduledWork(ctx, first)
	second, err := st.LeaseWork(ctx, store.WorkLaneBackground, time.Minute)
	if err != nil || second.SubjectID != healthy.ID {
		t.Fatalf("second scheduled incident = %+v, %v", second, err)
	}
	svc.handleScheduledWork(ctx, second)
	blocked, err = st.GetIncident(ctx, blocked.ID)
	if err != nil || blocked.CoopSessionID != "" ||
		blocked.Workflow != core.WorkflowHolding {
		t.Fatalf("blocked incident = %+v, %v", blocked, err)
	}
	healthy, err = st.GetIncident(ctx, healthy.ID)
	if err != nil || healthy.CoopSessionID == "" {
		t.Fatalf("unrelated incident did not progress = %+v, %v", healthy, err)
	}
	metrics, err := st.WorkMetrics(ctx, store.WorkLaneBackground)
	if err != nil || metrics.Pending != 1 || metrics.Running != 0 {
		t.Fatalf("per-incident retry queue = %+v, %v", metrics, err)
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
	if err := svc.processSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slack.posts) != 1 {
		t.Fatalf("initial Slack attempt = %+v", slack.posts)
	}
	slack.postErr = nil
	time.Sleep(2100 * time.Millisecond)
	if err := svc.reconcileSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackDelivery(ctx); !errors.Is(err, store.ErrNotFound) {
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
	svc.lastPost = time.Time{}
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
	status := svc.nativeStatus[statusKey]
	status.at = time.Now().Add(-76 * time.Second)
	svc.nativeStatus[statusKey] = status
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
	if err := svc.processSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	if _, ok := svc.nativeStatus[statusKey]; ok {
		t.Fatal("thread reply did not clear the local native-status cache")
	}
}

func TestIncidentSubthreadKeepsProgressOnTheSourceConversation(t *testing.T) {
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
		ID: "slack-subthread-reply", EnvelopeID: "envelope-subthread-reply",
		EventID: "event-subthread-reply", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: incident.ChannelID, ThreadTS: "1700.777", MessageTS: "1700.778",
		UserID: "U123ABC", Text: "<@U999BOT> Check this follow-up in depth.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit Slack subthread reply = %v, %v", created, err)
	}
	slack := &fakeSlack{}
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		slack,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	svc.identity = slackui.Identity{
		TeamID:    cfg.Slack.TeamID,
		BotUserID: "U999BOT",
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.statuses) != 1 || slack.statuses[0].thread != input.ThreadTS ||
		slack.statuses[0].text != "is investigating..." {
		t.Fatalf("accepted subthread status = %+v", slack.statuses)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.statuses) != 1 || slack.statuses[0].thread != input.ThreadTS ||
		slack.statuses[0].text != "is investigating..." {
		t.Fatalf("running subthread replaced the pending status: %+v", slack.statuses)
	}
}

func TestRequestNativeStatusIsStableAndScheduleSpecific(t *testing.T) {
	if got := requestNativeStatus("Check this in 24 hours and report again"); got != "is scheduling the follow-up..." {
		t.Fatalf("schedule status = %q", got)
	}
	if got := requestNativeStatus("Check whether the deployment is healthy"); got != "is investigating..." {
		t.Fatalf("investigation status = %q", got)
	}
	if got := requestNativeStatus("Explain the earlier answer in simple terms"); got != "is explaining the earlier answer..." {
		t.Fatalf("explanation status = %q", got)
	}
}

func TestEngineeringTaskDeliveryRequiresChangesFromCurrentTurn(t *testing.T) {
	before := coop.Changes{
		BaseCommit: "base", ForkHead: "existing",
		Committed:   []coop.Change{{Path: "infra.tf", Status: "M"}},
		PatchDigest: "existing-diff", PatchBytes: 100,
	}
	if engineeringTaskTurnCreatedChanges(coopChangesFingerprint(before), before) {
		t.Fatal("unchanged task work was attributed to the current turn")
	}
	after := before
	after.ForkHead = "new-head"
	after.Committed = append(
		after.Committed,
		coop.Change{Path: "followup.tf", Status: "M"},
	)
	after.PatchDigest = "new-diff"
	if !engineeringTaskTurnCreatedChanges(coopChangesFingerprint(before), after) {
		t.Fatal("new task work was not attributed to the current turn")
	}
	if engineeringTaskTurnCreatedChanges("unavailable", after) {
		t.Fatal("unknown initial state exposed stale task controls")
	}
}

func TestIncidentConversationAcceptsMessagesWithoutMentions(t *testing.T) {
	tests := []struct {
		name       string
		kind       string
		threadTS   string
		text       string
		wantPolicy string
		wantText   string
	}{
		{
			name: "pinned card reply", kind: "message", threadTS: "1700.001",
			text: "What should we do next?", wantPolicy: "directly addresses",
			wantText: "What should we do next?",
		},
		{
			name: "top level without mention", kind: "message",
			text: "The deploy finished; anything else?", wantPolicy: "ambient room conversation",
			wantText: "The deploy finished; anything else?",
		},
		{
			name: "top level mention", kind: "mention",
			text: "<@U999BOT> Are you following this?", wantPolicy: "directly addresses",
			wantText: "Are you following this?",
		},
		{
			name: "another conversation thread", kind: "message", threadTS: "1700.900",
			text: "I think the database is healthy.", wantPolicy: "ambient room conversation",
			wantText: "I think the database is healthy.",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
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
				ID: "slack-conversation", EnvelopeID: "envelope-conversation",
				EventID: "event-conversation", Kind: test.kind, TeamID: cfg.Slack.TeamID,
				ChannelID: incident.ChannelID, ThreadTS: test.threadTS, MessageTS: "1700.901",
				UserID: "U123ABC", Text: test.text,
			}
			if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
				t.Fatalf("admit conversation = %v, %v", created, err)
			}
			svc := New(
				cfg, st, newFakeCoop(), &fakeSlack{}, nil,
				slackui.NewSanitizer(12000), nil,
			)
			svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
			if err := svc.processSlackInput(ctx); err != nil {
				t.Fatal(err)
			}
			submission, err := st.GetAgentRunBySource(ctx, "slack", input.ID)
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(submission.Prompt, test.wantPolicy) ||
				!strings.Contains(submission.Prompt, test.wantText) ||
				strings.Contains(submission.Prompt, "<@U999BOT>") {
				t.Fatalf("conversation prompt = %q", submission.Prompt)
			}
		})
	}
}

func TestConversationReplyReturnsToOriginWithoutIncidentChrome(t *testing.T) {
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
		ID: "slack-top-level", EnvelopeID: "envelope-top-level", EventID: "event-top-level",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: incident.ChannelID,
		MessageTS: "1700.500", UserID: "U123ABC", Text: "What's next?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit top-level message = %v, %v", created, err)
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
	coopClient.complete("The inspection is complete. Close the incident unless another gate should run.")
	incident, _ = st.GetIncident(ctx, incident.ID)
	if err := svc.pollIncident(ctx, incident); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || slack.posts[0].thread != "" ||
		slack.posts[0].message.Header != "" || len(slack.posts[0].message.Context) != 0 ||
		!strings.Contains(slack.posts[0].message.Text, "inspection is complete") {
		t.Fatalf("conversation reply = %+v", slack.posts)
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
	coopClient.complete(noConversationReply)
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
	if err := svc.processSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	if svc.nativeStatus[statusKey].text != "is investigating..." {
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
		svc.nativeStatus[statusKey].text != "is investigating..." {
		t.Fatalf(
			"native status retry was not durable: statuses=%+v pending=%d",
			slack.statuses,
			metrics.SlackDeliveriesPending,
		)
	}
}

func TestAgentRunFinalizationFailureUsesDurableBackoff(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run := stageAgentRunWithMissingConversationSource(t, ctx, st)
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	before := time.Now().UTC()
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != core.AgentRunApplying || stored.Failures != 1 ||
		!stored.NextAttemptAt.After(before) ||
		!strings.Contains(stored.LastError, "not found") {
		t.Fatalf("deferred finalization = %+v", stored)
	}
	if err := svc.processAgentRunFinalization(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("finalization ignored durable due time: %v", err)
	}
}

func TestAgentRunFinalizationExhaustionPostsFailureAndClearsStatus(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 1
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run := stageAgentRunWithMissingConversationSource(t, ctx, st)
	slack := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slack, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunFailed ||
		!strings.Contains(stored.LastError, "configured retry limit") {
		t.Fatalf("terminal finalization = %+v, %v", stored, err)
	}
	incident, err := st.GetIncident(ctx, run.IncidentID)
	if err != nil || incident.ActiveTurnID != "" ||
		incident.Workflow != core.WorkflowParked {
		t.Fatalf("terminal incident = %+v, %v", incident, err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 ||
		!strings.Contains(slack.posts[0].message.Text, "could not finalize") {
		t.Fatalf("terminal finalization notice = %+v", slack.posts)
	}
	if len(slack.statuses) != 1 || slack.statuses[0].text != "" ||
		slack.statuses[0].thread != incident.RootTS {
		t.Fatalf("terminal finalization status clear = %+v", slack.statuses)
	}
}

func TestTriageFinalizationExhaustionUsesFrozenSlackDestination(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 1
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "CWATCH", ThreadTS: "1700.900",
		ConversationKey: "thread:CWATCH:1700.900",
		SourceKind:      "watch", SourceID: "missing-watch-input",
		Repository: "repo", Prompt: "investigate", SessionID: "ses_watch",
	})
	if err != nil || !created {
		t.Fatalf("queue triage run = %+v, %v, %v", run, created, err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(
		ctx,
		leased.ID,
		"coop_turn_missing_source",
		2,
		0,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(
		ctx,
		leased.ID,
		"completed",
		[]byte(`{"action":"ignore"}`),
		"",
		0,
	); err != nil {
		t.Fatal(err)
	}
	slack := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slack, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil || stored.State != core.AgentRunFailed {
		t.Fatalf("terminal triage run = %+v, %v", stored, err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slack.posts) != 1 || slack.posts[0].channel != run.ChannelID ||
		slack.posts[0].thread != run.ThreadTS {
		t.Fatalf("fallback triage notice = %+v", slack.posts)
	}
	if len(slack.statuses) != 1 || slack.statuses[0].text != "" ||
		slack.statuses[0].channel != run.ChannelID ||
		slack.statuses[0].thread != run.ThreadTS {
		t.Fatalf("fallback triage status clear = %+v", slack.statuses)
	}
}

func TestSocketEventIsPersistedBeforeAcknowledgement(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CINCIDENT"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, socket, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	payload, _ := json.Marshal(map[string]any{"event_id": "Ev123"})
	request := &socketmode.Request{EnvelopeID: "env-1", Payload: payload}
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{Data: &slackevents.MessageEvent{
				User: "U123ABC", Channel: "CINCIDENT", TimeStamp: "1700.2",
				ThreadTimeStamp: "1700.1", Text: "What changed?",
			}},
		},
		Request: request,
	})
	if socket.acks != 1 {
		t.Fatalf("acks = %d", socket.acks)
	}
	input, err := st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if input.EventID != "Ev123" || input.ThreadTS != "1700.1" || input.Text != "What changed?" {
		t.Fatalf("persisted input = %+v", input)
	}
	if err := st.FinishSlackInput(ctx, input.ID); err != nil {
		t.Fatal(err)
	}

	// Top-level channel conversation is persisted too; routing and authorization
	// happen in the durable input worker.
	payload, _ = json.Marshal(map[string]any{"event_id": "Ev124"})
	request = &socketmode.Request{EnvelopeID: "env-2", Payload: payload}
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{Data: &slackevents.MessageEvent{
				User: "U123ABC", Channel: "CINCIDENT", TimeStamp: "1700.3", Text: "ordinary chatter",
			}},
		},
		Request: request,
	})
	if socket.acks != 2 {
		t.Fatalf("top-level event was not acknowledged: %d", socket.acks)
	}
	input, err = st.LeaseSlackInput(ctx)
	if err != nil || input.ThreadTS != "" || input.MessageTS != "1700.3" ||
		input.Text != "ordinary chatter" {
		t.Fatalf("top-level conversation = %+v, %v", input, err)
	}
}

func TestSocketAdmitsMentionOnlyOnce(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, socket, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	text := "<@U999BOT> inspect current infrastructure health"

	payload, _ := json.Marshal(map[string]any{"event_id": "EvMessageMention"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{Data: &slackevents.MessageEvent{
				User: "U123ABC", Channel: "CWATCH", TimeStamp: "1700.10", Text: text,
			}},
		},
		Request: &socketmode.Request{EnvelopeID: "env-message-mention", Payload: payload},
	})
	if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("message event containing app mention was admitted: %v", err)
	}

	payload, _ = json.Marshal(map[string]any{"event_id": "EvAppMention"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{Data: &slackevents.AppMentionEvent{
				User: "U123ABC", Channel: "CWATCH", TimeStamp: "1700.10", Text: text,
			}},
		},
		Request: &socketmode.Request{EnvelopeID: "env-app-mention", Payload: payload},
	})
	input, err := st.LeaseSlackInput(ctx)
	if err != nil || input.Kind != "mention" || input.EventID != "EvAppMention" ||
		input.Text != text {
		t.Fatalf("authoritative app mention = %+v, %v", input, err)
	}
	if socket.acks != 2 {
		t.Fatalf("acknowledgements = %d, want 2", socket.acks)
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

func TestSocketAdmitsAtomicMemberJoinedEventForBotOnly(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
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
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	payload, _ := json.Marshal(map[string]any{"event_id": "EvMemberJoined"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{Data: &slackevents.MemberJoinedChannelEvent{
				User: "U999BOT", Channel: "CJOINED", Inviter: "U123ABC",
				EventTimestamp: "1785574912.610529",
			}},
		},
		Request: &socketmode.Request{EnvelopeID: "env-member-joined", Payload: payload},
	})
	input, err := st.LeaseSlackInput(ctx)
	if err != nil || input.Kind != "channel_joined" || input.UserID != "U123ABC" {
		t.Fatalf("member joined input = %+v, %v", input, err)
	}
}

func TestSocketPersistsReactionsToResponderMessagesWithoutStartingAgentTurn(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	if created, enqueueErr := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "reaction-target", Kind: "watch_reply", ChannelID: "CWATCH",
		ThreadTS: "1700.100", Body: []byte(`{"text":"Production is healthy."}`),
	}); enqueueErr != nil || !created {
		t.Fatalf("enqueue reaction target = %v, %v", created, enqueueErr)
	}
	delivery, err := st.LeaseSlackDelivery(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(ctx, delivery.ID, "1700.200", "sending"); err != nil {
		t.Fatal(err)
	}

	socket := &fakeSocket{events: make(chan socketmode.Event)}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, socket,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}

	admitReaction := func(eventID, eventTS, kind string) {
		t.Helper()
		payload, _ := json.Marshal(map[string]any{"event_id": eventID})
		var event any
		item := slackevents.Item{
			Type: "message", Channel: "CWATCH", Timestamp: "1700.200",
		}
		if kind == "reaction_added" {
			event = &slackevents.ReactionAddedEvent{
				User: "U123ABC", Reaction: "thumbsup", ItemUser: "U999BOT",
				Item: item, EventTimestamp: eventTS,
			}
		} else {
			event = &slackevents.ReactionRemovedEvent{
				User: "U123ABC", Reaction: "thumbsup", ItemUser: "U999BOT",
				Item: item, EventTimestamp: eventTS,
			}
		}
		svc.admitEventsAPI(ctx, socketmode.Event{
			Type: socketmode.EventTypeEventsAPI,
			Data: slackevents.EventsAPIEvent{
				TeamID:     cfg.Slack.TeamID,
				InnerEvent: slackevents.EventsAPIInnerEvent{Data: event},
			},
			Request: &socketmode.Request{EnvelopeID: "env-" + eventID, Payload: payload},
		})
	}

	admitReaction("EvReactionAdded", "1700.300", "reaction_added")
	if socket.acks != 1 {
		t.Fatalf("reaction acknowledgements = %d", socket.acks)
	}
	input, err := st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if input.Kind != "reaction_added" || input.ThreadTS != "1700.100" ||
		input.MessageTS != "1700.300" || input.ActionID != "thumbsup" ||
		input.ActionValue != "1700.200" || input.UserID != "U123ABC" {
		t.Fatalf("added reaction input = %+v", input)
	}
	if err := st.RetrySlackInput(ctx, input.ID, "test release", time.Now(), false); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}

	admitReaction("EvReactionRemoved", "1700.400", "reaction_removed")
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	context, err := st.ListRecentWatchMessages(ctx, "CWATCH", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(context) != 2 || context[0].Kind != "reaction_added" ||
		context[1].Kind != "reaction_removed" {
		t.Fatalf("durable reaction context = %+v", context)
	}
	if len(coopClient.submitPrompts) != 0 {
		t.Fatalf("reactions started agent turns: %v", coopClient.submitPrompts)
	}

	message := watchPromptMessage(context[1], "U999BOT", false)
	if message.SenderType != "human_reaction" || message.Text != "" ||
		len(message.Reactions) != 1 || message.Reactions[0].Change != "removed" ||
		message.Reactions[0].TargetMessageTS != "1700.200" {
		t.Fatalf("reaction prompt context = %+v", message)
	}
	current := watchPromptMessage(core.SlackInput{
		Kind: "bot_message", UserID: "U999BOT", Text: "Production is healthy.",
		Reactions: []core.SlackReaction{{
			Name: "thumbsup", Count: 2, UserIDs: []string{"U123ABC", "U456DEF"},
		}},
	}, "U999BOT", false)
	if current.SenderType != "responder" || len(current.Reactions) != 1 ||
		current.Reactions[0].Count != 2 ||
		!slices.Equal(current.Reactions[0].UserIDs, []string{"U123ABC", "U456DEF"}) {
		t.Fatalf("current reaction state = %+v", current)
	}
}

func TestSocketIgnoresReactionsToOtherUsersMessages(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
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
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	payload, _ := json.Marshal(map[string]any{"event_id": "EvForeignReaction"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{
				Data: &slackevents.ReactionAddedEvent{
					User: "U123ABC", Reaction: "eyes", ItemUser: "U456DEF",
					Item: slackevents.Item{
						Type: "message", Channel: "CWATCH", Timestamp: "1700.500",
					},
					EventTimestamp: "1700.600",
				},
			},
		},
		Request: &socketmode.Request{EnvelopeID: "env-foreign-reaction", Payload: payload},
	})
	if socket.acks != 1 {
		t.Fatalf("foreign reaction acknowledgements = %d", socket.acks)
	}
	if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("foreign reaction was admitted: %v", err)
	}
}

func TestDeletedChannelEventBlocksIncidentAndSuppressesSlackDelivery(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetSlackSetting(
		ctx,
		"channel",
		incident.ChannelID,
		"proactive",
		"on",
		"U123ABC",
	); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, socket,
		slackui.NewSanitizer(12000), nil,
	)
	payload, _ := json.Marshal(map[string]any{"event_id": "EvDeleted"})
	svc.admitEventsAPI(ctx, socketmode.Event{
		Type: socketmode.EventTypeEventsAPI,
		Data: slackevents.EventsAPIEvent{
			TeamID: cfg.Slack.TeamID,
			InnerEvent: slackevents.EventsAPIInnerEvent{
				Data: &slackevents.ChannelDeletedEvent{
					Type: "channel_deleted", Channel: incident.ChannelID,
				},
			},
		},
		Request: &socketmode.Request{EnvelopeID: "env-deleted", Payload: payload},
	})
	if socket.acks != 1 {
		t.Fatalf("deletion event acknowledgements = %d", socket.acks)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	if incident.ChannelState != core.ChannelDeleted ||
		incident.Workflow != core.WorkflowBlocked ||
		!strings.Contains(incident.LastError, "room was deleted") {
		t.Fatalf("deleted incident = %+v", incident)
	}
	if _, err := st.GetSlackSetting(
		ctx,
		"channel",
		incident.ChannelID,
		"proactive",
	); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("deleted channel retained its Slack override: %v", err)
	}
	if err := svc.enqueue(
		ctx, "out-after-delete", incident, "notice", incident.RootTS,
		slackui.Notice("This must not be posted."),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("deleted room received posts: %+v", slackClient.posts)
	}
	failures, err := st.ListFailedWork(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	var suppressed bool
	for _, failure := range failures {
		if failure.ID == "out-after-delete" &&
			strings.Contains(failure.LastError, "delivery suppressed") {
			suppressed = true
		}
	}
	if !suppressed {
		t.Fatalf("suppressed delivery was not retained as failed work: %+v", failures)
	}
}

func TestIncidentChannelReconciliationDistinguishesArchiveAndUnreachable(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	slackClient := &fakeSlack{
		channel: slackui.Channel{ID: incident.ChannelID, Name: incident.ChannelName, Archived: true},
	}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.reconcileIncidentChannel(ctx); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.ChannelState != core.ChannelArchived {
		t.Fatalf("archived reconciliation = %+v, %v", incident, err)
	}
	slackClient.channel.Archived = false
	if err := svc.reconcileIncidentChannel(ctx); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.ChannelState != core.ChannelActive {
		t.Fatalf("active reconciliation = %+v, %v", incident, err)
	}
	slackClient.channel = slackui.Channel{}
	slackClient.channelErr = slackui.ErrNotFound
	if err := svc.reconcileIncidentChannel(ctx); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.ChannelState != core.ChannelUnreachable ||
		incident.ChannelState == core.ChannelDeleted {
		t.Fatalf("unreachable reconciliation = %+v, %v", incident, err)
	}
}

func TestSocketAdmitsExternalAppsOnlyInWatchChannels(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, socket, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}

	admitBotMessage := func(envelope, eventID, channel, botID, text string) {
		t.Helper()
		payload, _ := json.Marshal(map[string]any{"event_id": eventID})
		svc.admitEventsAPI(ctx, socketmode.Event{
			Type: socketmode.EventTypeEventsAPI,
			Data: slackevents.EventsAPIEvent{
				TeamID: cfg.Slack.TeamID,
				InnerEvent: slackevents.EventsAPIInnerEvent{Data: &slackevents.MessageEvent{
					SubType: "bot_message", BotID: botID, Channel: channel,
					TimeStamp: "1700.4", Text: text,
				}},
			},
			Request: &socketmode.Request{EnvelopeID: envelope, Payload: payload},
		})
	}

	admitBotMessage("env-watch", "EvWatch", "CWATCH", "BEXTERNAL", "alert notification")
	input, err := st.LeaseSlackInput(ctx)
	if err != nil || input.Kind != "bot_message" || input.UserID != "BEXTERNAL" ||
		input.ChannelID != "CWATCH" {
		t.Fatalf("watched app message = %+v, %v", input, err)
	}
	if err := st.FinishSlackInput(ctx, input.ID); err != nil {
		t.Fatal(err)
	}
	admitBotMessage(
		"env-planning", "EvPlanning", "CWATCH", "BTERRAFORM",
		"Run notification for <https://app.terraform.io/app/acme/infra|acme/infra>\nRun run-abc\nRun Planning",
	)
	input, err = st.LeaseSlackInput(ctx)
	if err != nil || input.EventID != "EvPlanning" {
		t.Fatalf("Terraform lifecycle message = %+v, %v", input, err)
	}
	if err := st.FinishSlackInput(ctx, input.ID); err != nil {
		t.Fatal(err)
	}

	if err := st.SetSlackSetting(ctx, "global", "", proactiveSettingName, "on", "U123ABC"); err != nil {
		t.Fatal(err)
	}
	admitBotMessage("env-global", "EvGlobal", "CDYNAMIC", "BEXTERNAL", "alert notification")
	input, err = st.LeaseSlackInput(ctx)
	if err != nil || input.ChannelID != "CDYNAMIC" {
		t.Fatalf("globally watched app message = %+v, %v", input, err)
	}
	if err := st.FinishSlackInput(ctx, input.ID); err != nil {
		t.Fatal(err)
	}
	if err := st.SetSlackSetting(ctx, "global", "", proactiveSettingName, "off", "U123ABC"); err != nil {
		t.Fatal(err)
	}
	admitBotMessage("env-global-off", "EvGlobalOff", "CWATCH", "BEXTERNAL", "alert notification")
	admitBotMessage("env-other", "EvOther", "COTHER", "BEXTERNAL", "alert notification")
	admitBotMessage("env-self", "EvSelf", "CWATCH", "B999BOT", "alert notification")
	if _, err := st.LeaseSlackInput(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("unwatched or self-authored app message was persisted: %v", err)
	}
	if socket.acks != 6 {
		t.Fatalf("acks = %d", socket.acks)
	}
}

func TestScheduledRetryHonorsSlackRetryAfter(t *testing.T) {
	now := time.Date(2026, time.July, 31, 12, 0, 0, 0, time.UTC)
	next, delay, rateLimited := scheduledRetryAt(
		now,
		1,
		fmt.Errorf("list Slack channels: %w", &slack.RateLimitedError{
			RetryAfter: 30 * time.Second,
		}),
	)
	if !rateLimited || delay != 30*time.Second || !next.Equal(now.Add(30*time.Second)) {
		t.Fatalf("scheduled retry = %s, %s, %t", next, delay, rateLimited)
	}
	next, delay, rateLimited = scheduledRetryAt(now, 1, errors.New("temporary failure"))
	if rateLimited || delay != 0 || !next.Equal(now.Add(2*time.Second)) {
		t.Fatalf("ordinary retry = %s, %s, %t", next, delay, rateLimited)
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

func TestSlashCommandIsPersistedBeforeAcknowledgement(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, socket, slackui.NewSanitizer(12000), nil)
	request := &socketmode.Request{EnvelopeID: "env-slash", AcceptsResponsePayload: true}
	svc.admitSlashCommand(ctx, socketmode.Event{
		Type: socketmode.EventTypeSlashCommand,
		Data: slack.SlashCommand{
			TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH", UserID: "U123ABC",
			Command: "/responder", Text: "proactive on",
		},
		Request: request,
	})
	if socket.acks != 1 {
		t.Fatalf("slash acknowledgement = %d", socket.acks)
	}
	input, err := st.LeaseSlackInput(ctx)
	if err != nil || input.Kind != "slash" || input.ActionID != "/responder" ||
		input.Text != "proactive on" || input.ChannelID != "CWATCH" {
		t.Fatalf("persisted slash command = %+v, %v", input, err)
	}
}

func TestSlashFeedbackFailureKeepsCommandForDurableRetry(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{ephemeralErr: errors.New("Slack ephemeral delivery failed")}
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		slackClient,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	input := core.SlackInput{
		ID: "slash-feedback-retry", EnvelopeID: "env-slash-feedback-retry",
		EventID: "event-slash-feedback-retry", Kind: "slash",
		TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH", UserID: "U123ABC",
		Text: "proactive on", ActionID: "/responder",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit slash command = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil || stored.State != "retry" {
		t.Fatalf("failed feedback was not retained for retry: %+v, %v", stored, err)
	}
	setting, err := st.GetSlackSetting(
		ctx,
		"channel",
		input.ChannelID,
		proactiveSettingName,
	)
	if err != nil || setting.Value != "on" {
		t.Fatalf("idempotent command mutation was not preserved: %+v, %v", setting, err)
	}
}

func TestSlashProactiveOverrides(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CSTATIC"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	run := func(id, channel, text string) {
		t.Helper()
		input := core.SlackInput{
			ID: id, EnvelopeID: "env-" + id, EventID: "event-" + id,
			Kind: "slash", TeamID: cfg.Slack.TeamID, ChannelID: channel,
			UserID: "U123ABC", Text: text, ActionID: "/responder",
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", id, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", id, err)
		}
		stored, err := st.GetSlackInput(ctx, id)
		if err != nil || stored.State != "done" {
			t.Fatalf("stored %s = %+v, %v", id, stored, err)
		}
	}

	run("slash-global-on", "CCONTROL", "proactive global on")
	if enabled, err := svc.proactiveEnabled(ctx, "COTHER"); err != nil || !enabled {
		t.Fatalf("global proactive on = %v, %v", enabled, err)
	}
	run("slash-channel-off", "COTHER", "proactive off")
	if enabled, err := svc.proactiveEnabled(ctx, "COTHER"); err != nil || enabled {
		t.Fatalf("channel proactive off = %v, %v", enabled, err)
	}
	run("slash-status", "COTHER", "status")
	statusMessage := slackClient.ephemerals[len(slackClient.ephemerals)-1].message
	if statusMessage.Header != "Responder is passive in this channel" ||
		!strings.Contains(strings.Join(statusMessage.Sections, "\n"), "ignores ordinary human and app messages") ||
		len(statusMessage.Fields) != 4 ||
		!strings.Contains(statusMessage.Fields[0].Value, "force passive behavior") ||
		!strings.Contains(statusMessage.Fields[1].Value, "proactive by default") ||
		strings.Contains(statusMessage.Text, "responder.yaml") ||
		strings.Contains(statusMessage.Text, "inherit") {
		t.Fatalf("slash status does not explain effective behavior = %+v", statusMessage)
	}
	run("slash-channel-inherit", "COTHER", "proactive inherit")
	if enabled, err := svc.proactiveEnabled(ctx, "COTHER"); err != nil || !enabled {
		t.Fatalf("channel inherit = %v, %v", enabled, err)
	}
	run("slash-global-inherit", "CCONTROL", "proactive global inherit")
	if enabled, err := svc.proactiveEnabled(ctx, "COTHER"); err != nil || enabled {
		t.Fatalf("global inherit non-configured channel = %v, %v", enabled, err)
	}
	if enabled, err := svc.proactiveEnabled(ctx, "CSTATIC"); err != nil || !enabled {
		t.Fatalf("global inherit configured channel = %v, %v", enabled, err)
	}
}

func TestSlashPostmortemReadsLatestClosedIncidentRecord(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incidents, err := st.ApplySignals(ctx, core.WebhookEvent{
		Route: "grafana", DedupeKey: "postmortem-delivery", BodyDigest: "digest",
		Signals: []core.Signal{{
			Route: "grafana", SourceID: "alert-postmortem", EventID: "alert-event",
			Repository: "emisar", CorrelationKey: "api", Status: core.SignalFiring,
			Title: "API errors", Severity: "high", ReceivedAt: time.Now().UTC(),
		}},
	}, time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("incident = %+v, %v", incidents, err)
	}
	incident := incidents[0]
	if err := st.SetChannel(ctx, incident.ID, "CPOSTMORTEM", "ems-api"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incident.ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	if _, err := st.RecordEvidence(ctx, []core.Evidence{{
		IncidentID: incident.ID, ChannelID: "CPOSTMORTEM", SourceInput: "run_1",
		Claim: "API recovered", Observation: "Probe returned HTTP 200",
		SourceType: "emisar", SourceName: "http probe", Target: "api",
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.CloseIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}

	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	input := core.SlackInput{
		ID: "slash-postmortem", EnvelopeID: "env-slash-postmortem",
		EventID: "event-slash-postmortem", Kind: "slash", TeamID: cfg.Slack.TeamID,
		ChannelID: "CPOSTMORTEM", UserID: "U123ABC",
		Text: "postmortem", ActionID: "/responder",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit command = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("postmortem responses = %+v", slackClient.ephemerals)
	}
	message := slackClient.ephemerals[0].message
	if !strings.Contains(message.Markdown, "Post-incident draft") ||
		!strings.Contains(message.Markdown, "API recovered") ||
		strings.Contains(message.Markdown, "Still open") {
		t.Fatalf("postmortem = %+v", message)
	}
}

func TestSlashTurnLimitOverrides(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if _, err := svc.turnLimitStatus(ctx, "COTHER"); err != nil {
		t.Fatalf("initial turn-limit status: %v", err)
	}
	run := func(id, channel, text string) slackui.Message {
		t.Helper()
		input := core.SlackInput{
			ID: id, EnvelopeID: "env-" + id, EventID: "event-" + id,
			Kind: "slash", TeamID: cfg.Slack.TeamID, ChannelID: channel,
			UserID: "U123ABC", Text: text, ActionID: "/responder",
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", id, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", id, err)
		}
		if len(slackClient.ephemerals) == 0 {
			stored, storedErr := st.GetSlackInput(ctx, id)
			t.Fatalf("process %s produced no response: input=%+v, error=%v", id, stored, storedErr)
		}
		return slackClient.ephemerals[len(slackClient.ephemerals)-1].message
	}

	status := run("turn-status-default", "COTHER", "turn-limit")
	if !strings.Contains(status.Text, "up to 1000 agent requests") ||
		!strings.Contains(strings.Join(status.Sections, "\n"), "Operators do not choose") {
		t.Fatalf("default turn-limit status = %+v", status)
	}
	run("turn-global", "CCONTROL", "turn-limit global 2000")
	if got, err := svc.effectiveTurnLimit(ctx, "COTHER"); err != nil || got != 2000 {
		t.Fatalf("workspace turn limit = %d, %v", got, err)
	}
	run("turn-channel", "COTHER", "turn-limit 1500")
	if got, err := svc.effectiveTurnLimit(ctx, "COTHER"); err != nil || got != 1500 {
		t.Fatalf("channel turn limit = %d, %v", got, err)
	}
	run("turn-channel-inherit", "COTHER", "turn-limit inherit")
	if got, err := svc.effectiveTurnLimit(ctx, "COTHER"); err != nil || got != 2000 {
		t.Fatalf("inherited turn limit = %d, %v", got, err)
	}
	invalid := run("turn-invalid", "COTHER", "turn-limit 99")
	if !strings.Contains(invalid.Text, "between `100` and `10000`") {
		t.Fatalf("invalid turn-limit guidance = %+v", invalid)
	}
}

func TestRaisingTurnLimitResumesPreservedIncidentWork(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Coop.TurnLimit = 100
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api", 3); err != nil {
		t.Fatal(err)
	}
	if err := st.SetIncidentError(
		ctx, incident.ID, core.WorkflowBlocked, turnLimitReachedMessage(100),
	); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "raise-preserved-work", EnvelopeID: "env-raise-preserved-work",
		EventID: "event-raise-preserved-work", Kind: "slash", TeamID: cfg.Slack.TeamID,
		ChannelID: incident.ChannelID, UserID: "U123ABC", Text: "turn-limit 200",
		ActionID: "/responder",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	coopClient.session.State = "exhausted"
	coopClient.session.MaxTurns = 100
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil || incident.Workflow != core.WorkflowParked || incident.LastError != "" {
		t.Fatalf("resumed incident = %+v, %v", incident, err)
	}
}

func TestSlashSettingsRejectUnauthorizedUsers(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	input := core.SlackInput{
		ID: "slash-denied", EnvelopeID: "env-denied", EventID: "event-denied",
		Kind: "slash", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		UserID: "UOTHER", Text: "proactive global on", ActionID: "/responder",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := st.GetSlackSetting(
		ctx, "global", "", proactiveSettingName,
	); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("unauthorized global setting = %v", err)
	}
	if len(slackClient.ephemerals) != 1 ||
		!strings.Contains(slackClient.ephemerals[0].message.Text, "not listed in `slack.operators`") ||
		!strings.Contains(slackClient.ephemerals[0].message.Text, "administrator must add") {
		t.Fatalf("denial response = %+v", slackClient.ephemerals)
	}
}

func TestSlashStatusExplainsIncidentRoomBehavior(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	input := core.SlackInput{
		ID: "slash-incident-status", EnvelopeID: "env-incident-status",
		EventID: "event-incident-status", Kind: "slash", TeamID: cfg.Slack.TeamID,
		ChannelID: incident.ChannelID, UserID: "U123ABC", Text: "status",
		ActionID: "/responder",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("ephemeral status count = %d", len(slackClient.ephemerals))
	}
	message := slackClient.ephemerals[0].message
	sections := strings.Join(message.Sections, "\n")
	for _, required := range []string{
		"Incident collaboration remains active regardless of proactive triage",
		"without an `@mention`",
		"Attached incident `" + slackui.ShortID(incident.ID) + "`",
		"Reply normally anywhere in this incident channel",
	} {
		if !strings.Contains(sections, required) {
			t.Fatalf("incident status lacks %q: %+v", required, message)
		}
	}
	for _, internal := range []string{"parked", "provisioning_channel", "responder.yaml"} {
		if strings.Contains(message.Text+"\n"+sections, internal) {
			t.Fatalf("incident status exposes internal label %q: %+v", internal, message)
		}
	}
}

func TestSlashIncidentDirectoryLinksChannelsAndIncludesClosedHistory(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.CloseIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := st.SetIncidentChannelState(
		ctx, incident.ChannelID, core.ChannelDeleted, time.Now().UTC(),
	); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	run := func(id, text string) slackui.Message {
		t.Helper()
		input := core.SlackInput{
			ID: id, EnvelopeID: "env-" + id, EventID: "event-" + id,
			Kind: "slash", TeamID: cfg.Slack.TeamID, ChannelID: "CCONTROL",
			UserID: "U123ABC", Text: text, ActionID: "/responder",
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", id, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", id, err)
		}
		return slackClient.ephemerals[len(slackClient.ephemerals)-1].message
	}
	open := run("slash-open-incidents", "incidents")
	if open.Header != "No open incidents" ||
		!strings.Contains(strings.Join(open.Sections, "\n"), "`/responder incidents all`") {
		t.Fatalf("open incident directory = %+v", open)
	}
	all := run("slash-all-incidents", "incidents all")
	content := all.Text + "\n" + strings.Join(all.Sections, "\n")
	for _, required := range []string{
		"All incidents (1)",
		slackui.ShortID(incident.ID),
		"API unavailable",
		"#inc-api (Slack room deleted)",
		"Closed",
		"1 alert firing",
	} {
		if !strings.Contains(all.Header+"\n"+content, required) {
			t.Fatalf("all incident directory lacks %q: %+v", required, all)
		}
	}
	if strings.Contains(content, "slack.com/app_redirect") {
		t.Fatalf("incident directory uses a redirect instead of a channel mention: %+v", all)
	}
	if strings.Contains(content, "<#CINCIDENT>") {
		t.Fatalf("deleted incident directory contains a broken channel mention: %+v", all)
	}
}

func TestSlashHelpButtonsRouteToReadOnlyCommands(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	helpInput := core.SlackInput{
		ID: "slash-help", EnvelopeID: "env-slash-help", EventID: "event-slash-help",
		Kind: "slash", TeamID: cfg.Slack.TeamID, ChannelID: "CCONTROL",
		UserID: "U123ABC", ActionID: "/responder",
	}
	if created, err := st.AdmitSlackInput(ctx, helpInput); err != nil || !created {
		t.Fatalf("admit help = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	help := slackClient.ephemerals[len(slackClient.ephemerals)-1].message
	if help.Header != "Responder command guide" || len(help.Actions) != 3 ||
		help.Actions[0].ID != slackui.ActionCommandStatus ||
		help.Actions[1].ID != slackui.ActionCommandOpenIncidents ||
		help.Actions[2].ID != slackui.ActionCommandAllIncidents {
		t.Fatalf("interactive help = %+v", help)
	}
	helpContent := strings.Join(help.Sections, "\n")
	for _, command := range []string{
		"`/responder preferences`",
		"`/responder rules`",
	} {
		if !strings.Contains(helpContent, command) {
			t.Fatalf("interactive help lacks %s: %+v", command, help)
		}
	}
	actionIDs := make(map[string]bool)
	for _, action := range help.Actions {
		if actionIDs[action.ID] {
			t.Fatalf("interactive help repeats action ID %q: %+v", action.ID, help)
		}
		actionIDs[action.ID] = true
	}
	action := core.SlackInput{
		ID: "action-status", EnvelopeID: "env-action-status",
		EventID: "event-action-status", Kind: "action", TeamID: cfg.Slack.TeamID,
		ChannelID: "CCONTROL", UserID: "U123ABC",
		ActionID: slackui.ActionCommandStatus, ActionValue: "status",
	}
	if created, err := st.AdmitSlackInput(ctx, action); err != nil || !created {
		t.Fatalf("admit action = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	status := slackClient.ephemerals[len(slackClient.ephemerals)-1].message
	if status.Header != "Responder is passive in this channel" {
		t.Fatalf("help status action = %+v", status)
	}
}

func TestClosedIncidentControlsResolveByIDAndHideWithoutChanges(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(
		ctx, incident.ID, "ses_1", "incident-read-only", 1,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.CloseIncident(ctx, incident.ID); err != nil {
		t.Fatal(err)
	}
	incident, err = st.GetIncident(ctx, incident.ID)
	if err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processCard(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.updates) != 1 ||
		len(slackClient.updates[0].message.Actions) != 0 {
		t.Fatalf("unchanged closed card controls = %+v", slackClient.updates)
	}
	runAction := func(id, actionID string) {
		t.Helper()
		input := core.SlackInput{
			ID: id, EnvelopeID: "env-" + id, EventID: "event-" + id,
			Kind: "action", TeamID: cfg.Slack.TeamID, ChannelID: incident.ChannelID,
			MessageTS: incident.RootTS, UserID: "U123ABC",
			ActionID: actionID, ActionValue: incident.ID,
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", id, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", id, err)
		}
		drainSlackDeliveries(t, ctx, svc)
	}
	runAction("closed-changes", slackui.ActionChanges)
	if got := slackClient.posts[len(slackClient.posts)-1].message; !strings.Contains(
		got.Text+"\n"+strings.Join(got.Sections, "\n"),
		"no changes",
	) {
		t.Fatalf("closed changes response = %+v", got)
	}
	runAction("closed-review", slackui.ActionReview)
	if got := slackClient.posts[len(slackClient.posts)-1].message; !strings.Contains(
		got.Text+"\n"+strings.Join(got.Sections, "\n"),
		"no proposed code change",
	) {
		t.Fatalf("closed review response = %+v", got)
	}
}

func TestIncidentControlMatchesDeliveredResultMessage(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		&fakeSlack{},
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	message := slackui.Message{
		Text: "The requested change is ready.",
		Actions: []slackui.Action{{
			ID: slackui.ActionChanges, Label: "View diff", Value: incident.ID,
		}},
	}
	body, err := slackui.Encode(message)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "out_result_with_controls", IncidentID: incident.ID,
		Kind: "assistant", ChannelID: incident.ChannelID,
		ThreadTS: incident.ConversationThreadTS(), Body: body,
	}); err != nil {
		t.Fatal(err)
	}
	delivery, err := st.LeaseSlackDelivery(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(
		ctx,
		delivery.ID,
		"1700.900",
		"sending",
	); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		Kind: "action", ChannelID: incident.ChannelID,
		ThreadTS: incident.ConversationThreadTS(), MessageTS: "1700.900",
		ActionID: slackui.ActionChanges, ActionValue: incident.ID,
	}
	matches, err := svc.incidentControlMatchesMessage(ctx, input, incident)
	if err != nil || !matches {
		t.Fatalf("delivered result control = %t, %v", matches, err)
	}
	input.ActionID = slackui.ActionPublishPR
	matches, err = svc.incidentControlMatchesMessage(ctx, input, incident)
	if err != nil || matches {
		t.Fatalf("undelivered result control = %t, %v", matches, err)
	}
	input.ActionID = slackui.ActionChanges
	input.MessageTS = "1700.999"
	matches, err = svc.incidentControlMatchesMessage(ctx, input, incident)
	if err != nil || matches {
		t.Fatalf("wrong result message control = %t, %v", matches, err)
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

func TestWatchedChannelDecisions(t *testing.T) {
	tests := []struct {
		name          string
		kind          string
		text          string
		decision      string
		alertPolicy   string
		wantState     string
		wantPosts     int
		wantIncidents int
		wantOffer     bool
		wantApproval  bool
		maxAttempts   int
	}{
		{
			name: "ignore", kind: "bot_message",
			decision: `{"action":"ignore"}`, wantState: "done",
		},
		{
			name: "reply", kind: "message",
			decision: `{"action":"reply","attention":{"addressee":"channel",` +
				`"urgency":1,"confidence":3,"novelty":2,"ownership":2},` +
				`"message":"The deploy recovered; no action is needed."}`,
			wantState: "done", wantPosts: 1,
		},
		{
			name: "operator governed action awaits Emisar approval", kind: "message",
			text: "Enable origin certificate verification for this pull zone.",
			decision: `{"action":"reply","attention":{"addressee":"responder",` +
				`"urgency":2,"confidence":3,"novelty":2,"ownership":3},` +
				`"message":"Emisar accepted the exact request and paused it for approval.",` +
				`"pending_approval":{"request_id":"apr_watch_1","run_id":"run_watch_1",` +
				`"operation_id":"op_watch_1","action_id":"bunny.pull_zone.update",` +
				`"pack_ref":"bunny@1.0.0#sha256:abc","runner_ref":"prod~abc",` +
				`"status":"pending_approval",` +
				`"approval_url":"https://emisar.dev/app/acme/approvals/apr_watch_1",` +
				`"expires_at":"2099-08-01T00:00:00Z"}}`,
			wantState: "done", wantPosts: 1, wantApproval: true,
		},
		{
			name: "incident", kind: "bot_message",
			decision:  `{"action":"incident","title":"Checkout error rate is elevated"}`,
			wantState: "done", wantPosts: 1, wantIncidents: 1,
		},
		{
			name: "configured app alert offers incident", kind: "bot_message",
			alertPolicy: "offer",
			decision:    `{"action":"incident","title":"Checkout error rate is elevated"}`,
			wantState:   "done", wantPosts: 1, wantOffer: true,
		},
		{
			name: "configured app alert replies in place", kind: "bot_message",
			alertPolicy: "reply",
			decision:    `{"action":"incident","title":"Checkout error rate is elevated"}`,
			wantState:   "done", wantPosts: 1,
		},
		{
			name: "reply incident offer obeys automatic app policy", kind: "bot_message",
			alertPolicy: "automatic",
			decision: `{"action":"reply","attention":{"addressee":"channel",` +
				`"urgency":3,"confidence":3,"novelty":3,"ownership":3},` +
				`"message":"The alert is credible.",` +
				`"incident_title":"Checkout error rate is elevated"}`,
			wantState: "done", wantPosts: 1, wantIncidents: 1,
		},
		{
			name: "human incident decision requires confirmation", kind: "message",
			decision:  `{"action":"incident","title":"Checkout error rate is elevated"}`,
			wantState: "done", wantPosts: 1, wantOffer: true,
		},
		{
			name: "explicit human incident request", kind: "message",
			text:      "Please open an incident for the checkout HTTP 500 errors.",
			decision:  `{"action":"incident","title":"Checkout error rate is elevated"}`,
			wantState: "done", wantPosts: 1, wantIncidents: 1,
		},
		{
			name: "malformed", kind: "bot_message", decision: `I would ignore this.`,
			wantState: "done", wantPosts: 0, maxAttempts: 1,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx := context.Background()
			cfg := serviceConfig(t)
			cfg.Slack.WatchChannels = []string{"CWATCH"}
			if test.maxAttempts > 0 {
				cfg.Limits.MaxAgentRunAttempts = test.maxAttempts
			}
			st, err := store.Open(cfg.StateDir)
			if err != nil {
				t.Fatal(err)
			}
			defer st.Close()
			slack := &fakeSlack{}
			coopClient := newFakeCoop()
			coopClient.completeOnSubmit = test.decision
			svc := New(cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000), nil)
			svc.identity = slackui.Identity{
				TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
			}
			if test.alertPolicy != "" {
				if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
					ChannelID: "CWATCH", Participation: "proactive",
					Repository: "repo", AlertPolicy: test.alertPolicy,
					ActorID: "U123ABC",
				}); err != nil {
					t.Fatal(err)
				}
			}
			input := core.SlackInput{
				ID: "slack-watch-1", EnvelopeID: "env-watch-1", EventID: "EvWatch1",
				Kind: test.kind, TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
				MessageTS: "1700.500", UserID: "U123ABC",
				Text: "Checkout is returning HTTP 500 responses.",
			}
			if test.kind == "bot_message" {
				input.UserID = "BEXTERNAL"
			}
			if test.text != "" {
				input.Text = test.text
			}
			if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
				t.Fatalf("admit = %v, %v", created, err)
			}
			if err := svc.processSlackInput(ctx); err != nil {
				t.Fatal(err)
			}
			finishQueuedAgentRun(t, ctx, svc)
			stored, err := st.GetSlackInput(ctx, input.ID)
			if err != nil || stored.State != test.wantState {
				t.Fatalf("stored input = %+v, %v", stored, err)
			}
			if len(slack.posts) != test.wantPosts {
				t.Fatalf("posts = %+v", slack.posts)
			}
			if len(slack.statuses) != 0 {
				t.Fatalf("ambient triage exposed a thread status: %+v", slack.statuses)
			}
			if test.name == "reply" {
				if slack.posts[0].thread != "" ||
					!strings.Contains(slack.posts[0].message.Text, "deploy recovered") {
					t.Fatalf("threaded watch reply = %+v", slack.posts[0])
				}
			}
			if test.wantApproval {
				message := slack.posts[0].message
				if message.Header != "Approval required in Emisar" ||
					len(message.Actions) != 1 ||
					message.Actions[0].ID != slackui.ActionOpenApproval ||
					message.Actions[0].URL != "https://emisar.dev/app/acme/approvals/apr_watch_1" ||
					!strings.Contains(strings.Join(message.Sections, "\n"), "update this card automatically") ||
					strings.Contains(strings.Join(message.Sections, "\n"), "pinned card") {
					t.Fatalf("shared conversation approval card = %+v", message)
				}
				approval, err := st.GetEmisarApproval(ctx, "apr_watch_1")
				if err != nil || approval.IncidentID != "" ||
					approval.ChannelID != input.ChannelID || approval.SourceInput != input.ID ||
					approval.RequestedBy != input.UserID || approval.DeliveryID == "" ||
					approval.MessageTS == "" {
					t.Fatalf("shared conversation approval = %+v, %v", approval, err)
				}
			}
			if test.name == "malformed" {
				run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
				if err != nil || run.State != core.AgentRunFailed {
					t.Fatalf("malformed agent run = %+v, %v", run, err)
				}
			}
			if test.wantOffer {
				message := slack.posts[0].message
				if len(message.Actions) != 1 ||
					message.Actions[0].ID != slackui.ActionOpenIncident ||
					message.Actions[0].Value != input.ID ||
					!strings.Contains(message.Text, "have not opened an incident") {
					t.Fatalf("human incident confirmation = %+v", message)
				}
				run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
				if err != nil {
					t.Fatal(err)
				}
				state, err := decodeWatchRunContext(run)
				if err != nil || state.OfferedIncidentTitle != "Checkout error rate is elevated" {
					t.Fatalf("persisted incident offer = %+v, %v", state, err)
				}
			}
			incidents, err := st.ListIncidents(ctx, 10)
			if err != nil || len(incidents) != test.wantIncidents {
				t.Fatalf("incidents = %+v, %v", incidents, err)
			}
			if test.name == "incident" {
				signals, err := st.ListSignals(ctx, incidents[0].ID)
				if err != nil || len(signals) != 1 ||
					signals[0].Summary != input.Text ||
					signals[0].Labels["slack_origin_channel"] != input.ChannelID {
					t.Fatalf("watch incident signal = %+v, %v", signals, err)
				}
			}
			if len(coopClient.createKeys) != 1 ||
				coopClient.createKeys[0] != "responder:watch-session:CWATCH" ||
				len(coopClient.submitPrompts) != 1 ||
				!strings.Contains(coopClient.submitPrompts[0], "<untrusted-slack-context>") ||
				!strings.Contains(coopClient.submitPrompts[0], "recent_channel_messages") ||
				!strings.Contains(coopClient.submitPrompts[0], "declared intent and expected topology") ||
				!strings.Contains(coopClient.submitPrompts[0], "other available MCP servers and tools") ||
				!strings.Contains(coopClient.submitPrompts[0], "runner identities and connection state") ||
				!strings.Contains(coopClient.submitPrompts[0], "not by itself permission") ||
				!strings.Contains(coopClient.submitPrompts[0], "operator confirmation button") {
				t.Fatalf("watch Coop calls = keys=%v prompts=%v",
					coopClient.createKeys, coopClient.submitPrompts)
			}
		})
	}
}

func TestWatchedAppAlertBurstEvaluatesEveryEventInOrder(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchSettleDelay.Duration = 0
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if _, err := st.SaveChannelConfiguration(ctx, core.ChannelConfiguration{
		ChannelID: "CWATCH", Participation: "proactive",
		Repository: "repo", AlertPolicy: "reply", ActorID: "U123ABC",
	}); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.completeQueue = []string{
		`{"action":"reply","attention":{"addressee":"channel","urgency":3,"confidence":3,"novelty":3,"ownership":3},"message":"Cassandra is firing and needs investigation."}`,
		`{"action":"reply","attention":{"addressee":"channel","urgency":2,"confidence":3,"novelty":3,"ownership":3},"message":"Cassandra recovered after the firing alert."}`,
	}
	slackClient := &fakeSlack{}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	inputs := []core.SlackInput{
		{
			ID: "slack-app-firing", EnvelopeID: "env-app-firing",
			EventID: "EvAppFiring", Kind: "bot_message", TeamID: cfg.Slack.TeamID,
			ChannelID: "CWATCH", MessageTS: "1700.500", UserID: "BBETTERSTACK",
			Text: "FIRING: Cassandra total RPS is below 4k.",
		},
		{
			ID: "slack-app-recovered", EnvelopeID: "env-app-recovered",
			EventID: "EvAppRecovered", Kind: "bot_message", TeamID: cfg.Slack.TeamID,
			ChannelID: "CWATCH", MessageTS: "1700.501", UserID: "BGRAFANA",
			Text: "RESOLVED: Cassandra total RPS recovered.",
		},
	}
	for _, input := range inputs {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %t, %v", input.ID, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatal(err)
		}
	}
	for range inputs {
		finishQueuedAgentRun(t, ctx, svc)
	}
	for _, input := range inputs {
		run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
		if err != nil || run.State != core.AgentRunCompleted {
			t.Fatalf("agent run for %s = %+v, %v", input.ID, run, err)
		}
	}
	if len(slackClient.posts) != 2 ||
		!strings.Contains(slackClient.posts[0].message.Text, "firing") ||
		!strings.Contains(slackClient.posts[1].message.Text, "recovered") {
		t.Fatalf("ordered app alert replies = %+v", slackClient.posts)
	}
}

func TestWatchedFailureKeepsPendingStatusUntilNoticeIsPosted(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 1
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{postErr: errors.New("Slack is unavailable")}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `not a watch decision`
	svc := New(cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "slack-watch-failure", EnvelopeID: "env-watch-failure",
		EventID: "EvWatchFailure", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.700", UserID: "U123ABC",
		Text: "How is production health?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatalf("agent finalization should not depend on Slack: %v", err)
	}
	if err := svc.processSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != "done" {
		t.Fatalf("stored input = %+v", stored)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || run.State != core.AgentRunFailed {
		t.Fatalf("finalized failed run = %+v, %v", run, err)
	}
	if len(slack.posts) != 1 ||
		!strings.Contains(slack.posts[0].message.Text, "couldn't finish this assessment") {
		t.Fatalf("failure notice attempt = %+v", slack.posts)
	}
	if len(slack.statuses) != 0 {
		t.Fatalf("ambient failure exposed a thread status: %+v", slack.statuses)
	}
}

func TestMalformedDeepCompletionIsCorrectedAndRetried(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Limits.MaxAgentRunAttempts = 3
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeQueue = []string{
		`{
		  "action":"reply",
		  "attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":3,"ownership":3},
		  "message":"Application impact still needs investigation.",
		  "coverage":[
		    {"layer":"change","status":"healthy","detail":"revision is current"},
		    {"layer":"host","status":"healthy","detail":"hosts respond"},
		    {"layer":"runtime","status":"healthy","detail":"runtime responds"},
		    {"layer":"workload","status":"healthy","detail":"workloads run"},
		    {"layer":"dependency","status":"healthy","detail":"dependencies respond"},
		    {"layer":"application","status":"unknown","detail":"not queried"},
		    {"layer":"slo","status":"unknown","detail":"not queried"}
		  ],
		  "completion":{"status":"blocked","summary":"Impact is unknown.","material_gaps":["application and SLO impact"],"next_action":"Query application and SLO telemetry"}
		}`,
		`{
		  "action":"reply",
		  "attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":3,"ownership":3},
		  "message":"Core infrastructure responds, but customer impact cannot be verified with the configured sources.",
		  "coverage":[
		    {"layer":"change","status":"healthy","detail":"revision is current"},
		    {"layer":"host","status":"healthy","detail":"hosts respond"},
		    {"layer":"runtime","status":"healthy","detail":"runtime responds"},
		    {"layer":"workload","status":"healthy","detail":"workloads run"},
		    {"layer":"dependency","status":"healthy","detail":"dependencies respond"},
		    {"layer":"application","status":"unknown","detail":"the application telemetry source denied access"},
		    {"layer":"slo","status":"unknown","detail":"the SLO telemetry source denied access"}
		  ],
		  "completion":{"status":"blocked","summary":"Customer impact cannot be verified because monitoring access is denied.","material_gaps":["application and SLO impact"],"blocker_kind":"access_denied","attempts":["Queried the configured application and SLO source; it returned permission denied"],"next_action":"Grant the monitoring identity read access, then retry"}
		}`,
	}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	input := core.SlackInput{
		ID: "slack-completion-retry", EnvelopeID: "env-completion-retry",
		EventID: "EvCompletionRetry", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.710", UserID: "U123ABC",
		Text: "<@U999BOT> Give me a decision-ready production health assessment.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || run.State != core.AgentRunPending || run.Failures != 1 ||
		!strings.Contains(run.LastError, "blocker_kind") {
		t.Fatalf("corrected run = %+v, %v", run, err)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("invalid partial result reached Slack: %+v", slackClient.posts)
	}
	finishQueuedAgentRun(t, ctx, svc)
	run, err = st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || run.State != core.AgentRunCompleted {
		t.Fatalf("retried run = %+v, %v", run, err)
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(strings.Join(slackClient.posts[0].message.Sections, "\n"), "Assessment incomplete") {
		t.Fatalf("retried Slack result = %+v", slackClient.posts)
	}
	if len(coopClient.submitPrompts) != 2 ||
		!strings.Contains(coopClient.submitPrompts[1], "blocker_kind") {
		t.Fatalf("correction prompt was not carried into retry: %v", coopClient.submitPrompts)
	}
}

func TestStructuredResultFailureNoticeIsOperatorFacing(t *testing.T) {
	detail := "the deep work episode has no completion assessment; continue until ready"
	notice := watchFailureNotice(detail)
	if !strings.Contains(notice, "couldn't finish this assessment") ||
		!strings.Contains(notice, "completeness checks after retrying") ||
		strings.Contains(notice, detail) ||
		strings.Contains(notice, "Reason reported by Coop") {
		t.Fatalf("structured failure notice = %q", notice)
	}
}

func TestStructuredCorrectionBudgetIsBounded(t *testing.T) {
	if terminalStructuredCorrection(1, 20) ||
		terminalStructuredCorrection(2, 20) ||
		!terminalStructuredCorrection(3, 20) ||
		!terminalStructuredCorrection(1, 1) {
		t.Fatal("structured correction budget does not stop after three attempts")
	}
}

func TestWatchStructuredCorrectionBudgetIsIndependentFromRunFailures(t *testing.T) {
	state := watchTurnState{}
	first := consumeWatchStructuredCorrection(&state, 20)
	second := consumeWatchStructuredCorrection(&state, 20)
	third := consumeWatchStructuredCorrection(&state, 20)
	if first || second || !third ||
		state.StructuredCorrections != 3 {
		t.Fatalf("watch correction state = %+v", state)
	}
}

func TestWatchedIncidentOfferRequiresOperatorAndCreatesOnce(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{dedupePosts: true}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
	  "action":"reply",
	  "attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3},
	  "message":"Two production runners are disconnected.",
	  "incident_title":"Two production runners disconnected",
	  "coverage":[
	    {"layer":"change","status":"unknown","detail":"The deployed revision was not available"},
	    {"layer":"host","status":"unhealthy","source":"Emisar","detail":"Two production runners are disconnected"},
	    {"layer":"runtime","status":"unknown","detail":"Disconnected runners cannot be queried"},
	    {"layer":"workload","status":"unknown","detail":"Workload placement was not available"},
	    {"layer":"dependency","status":"unknown","detail":"Dependency health was not available"},
	    {"layer":"application","status":"unknown","detail":"Application probes were not available"},
	    {"layer":"slo","status":"unknown","detail":"Customer impact was not available"}
	  ],
	  "completion":{"status":"blocked","summary":"Two runners are disconnected and the production impact cannot yet be bounded.","material_gaps":["workload placement and customer impact"],"blocker_kind":"source_unavailable","attempts":["Queried the configured live source; disconnected runners could not return workload or application evidence"],"next_action":"Restore runner connectivity or provide an authoritative workload and customer-impact source"}
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID: "slack-health-question", EnvelopeID: "env-health-question",
		EventID: "event-health-question", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.800", UserID: "U123ABC",
		Text: "How is the health of our infrastructure?",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 ||
		slackClient.posts[0].thread != "" ||
		len(slackClient.posts[0].message.Actions) != 1 ||
		slackClient.posts[0].message.Actions[0].ID != slackui.ActionOpenIncident {
		t.Fatalf("incident offer = %+v", slackClient.posts)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("question created incident before approval = %+v, %v", incidents, err)
	}

	click := func(id, userID string) {
		t.Helper()
		input := core.SlackInput{
			ID: id, EnvelopeID: "env-" + id, EventID: "event-" + id,
			Kind: "action", TeamID: cfg.Slack.TeamID, ChannelID: source.ChannelID,
			MessageTS: "1700.001", UserID: userID,
			ActionID: slackui.ActionOpenIncident, ActionValue: source.ID,
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", id, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", id, err)
		}
	}
	click("incident-offer-unauthorized", "UOTHER")
	if len(slackClient.ephemerals) != 1 ||
		!strings.Contains(slackClient.ephemerals[0].message.Text, "Only a configured incident operator") {
		t.Fatalf("unauthorized offer response = %+v", slackClient.ephemerals)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("unauthorized click created incident = %+v, %v", incidents, err)
	}

	stale := core.SlackInput{
		ID: "incident-offer-stale", EnvelopeID: "env-incident-offer-stale",
		EventID: "event-incident-offer-stale", Kind: "action",
		TeamID: cfg.Slack.TeamID, ChannelID: source.ChannelID,
		MessageTS: "1700.999", UserID: "U123ABC",
		ActionID: slackui.ActionOpenIncident, ActionValue: source.ID,
	}
	if created, err := st.AdmitSlackInput(ctx, stale); err != nil || !created {
		t.Fatalf("admit stale = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatalf("process stale: %v", err)
	}
	if len(slackClient.ephemerals) != 2 ||
		!strings.Contains(slackClient.ephemerals[1].message.Text, "stale") {
		t.Fatalf("stale offer response = %+v", slackClient.ephemerals)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("stale click created incident = %+v, %v", incidents, err)
	}

	click("incident-offer-authorized", "U123ABC")
	click("incident-offer-repeated", "U123ABC")
	drainSlackDeliveries(t, ctx, svc)
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("authorized offer incidents = %+v, %v", incidents, err)
	}
	if len(slackClient.posts) != 2 ||
		slackClient.posts[1].thread != "" ||
		!strings.Contains(slackClient.posts[1].message.Text, "opening a dedicated incident room") {
		t.Fatalf("incident creation acknowledgement = %+v", slackClient.posts)
	}
	signals, err := st.ListSignals(ctx, incidents[0].ID)
	if err != nil || len(signals) != 1 ||
		signals[0].Summary != source.Text ||
		signals[0].Labels["slack_origin_channel"] != source.ChannelID {
		t.Fatalf("approved offer evidence = %+v, %v", signals, err)
	}
}

func TestWatchedScheduleAndRunbookRequestUsesEmisarAndOffersSchedule(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{
		dedupePosts: true,
		history: []slackui.HistoryMessage{
			{Timestamp: "1700.800", UserID: "U123ABC", Text: "Can you post a daily deep infrastructure health review around 9 am? Maybe make a reusable runbook for it too."},
			{Timestamp: "1700.850", ThreadTS: "1700.800", UserID: "U123ABC", Text: "Try again <@U999BOT>"},
		},
	}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
		"action":"reply",
		"attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":3,"ownership":3},
		"reason":"the operator requested an Emisar runbook and recurring execution",
		"message":"I created and published the reusable Emisar runbook deep-infrastructure-health@1. Confirm the daily schedule below.",
		"schedule_offer":{
			"title":"Daily deep infrastructure health review",
			"prompt":"Execute the exact published Emisar runbook deep-infrastructure-health@1 with fresh evidence and report the result.",
			"repository":"repo",
			"recurrence":"daily",
			"local_time":"09:00",
			"timezone":"UTC",
			"catch_up":"latest",
			"expires_in":"365d"
		},
		"evidence":[{"claim":"the runbook is published","observation":"Emisar published deep-infrastructure-health@1","source_type":"emisar","source_name":"publish_runbook"}]
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID: "slack-schedule-runbook", EnvelopeID: "env-schedule-runbook",
		EventID: "event-schedule-runbook", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", ThreadTS: "1700.800", MessageTS: "1700.850", UserID: "U123ABC",
		Text: "Try again <@U999BOT>",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 {
		t.Fatalf("compound offer posts = %+v", slackClient.posts)
	}
	message := slackClient.posts[0].message
	if len(message.Actions) != 1 ||
		message.Actions[0].ID != slackui.ActionRememberSchedule ||
		!strings.Contains(strings.Join(message.Sections, "\n"), "Daily deep infrastructure health review") ||
		!strings.Contains(strings.Join(message.Sections, "\n"), "deep-infrastructure-health@1") ||
		strings.Contains(strings.Join(message.Sections, "\n"), "engineering task") {
		t.Fatalf("compound offer = %+v", message)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", source.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(run)
	if err != nil || state.OfferedTaskTitle != "" || state.OfferedTaskRepository != "" {
		t.Fatalf("runbook request became a repository task = %+v, %v", state, err)
	}
	if schedules, err := st.ListScheduledTasksForChannel(ctx, source.ChannelID, 10); err != nil || len(schedules) != 0 {
		t.Fatalf("schedule was created before confirmation = %+v, %v", schedules, err)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("engineering task was created before confirmation = %+v, %v", incidents, err)
	}
}

func TestWatchedCompoundRequestPostsOrderedMessagesInOneThread(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{dedupePosts: true}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
		"action":"reply",
		"attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":3,"ownership":3},
		"reason":"the operator requested three independent read-only outcomes",
		"message":"**CI:** all required checks passed for the current revision.",
		"followup_messages":[
			"**Deployments:** production is waiting for one approval; no failed rollout was observed.",
			"**Incidents:** two remain open, and the database-latency incident is the higher priority."
		],
		"evidence":[{"claim":"CI passed","observation":"All required jobs succeeded","source_type":"other","source_name":"CI"}],
		"coverage":[{"layer":"change","status":"healthy","source":"CI","detail":"Current revision checks passed"}]
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID: "slack-compound-read", EnvelopeID: "env-compound-read",
		EventID: "event-compound-read", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.860", UserID: "U123ABC",
		Text: "Check CI, tell me deployment status, and summarize the two active operational investigations.",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 3 {
		t.Fatalf("compound reply posts = %+v", slackClient.posts)
	}
	for _, post := range slackClient.posts {
		if post.channel != source.ChannelID || post.thread != "" {
			t.Fatalf("compound reply changed destination = %+v", slackClient.posts)
		}
	}
	for index, expected := range []string{"CI", "Deployments", "Incidents"} {
		if !strings.Contains(slackClient.posts[index].message.Text, expected) {
			t.Fatalf("compound reply order = %+v", slackClient.posts)
		}
	}
	if strings.Contains(strings.Join(slackClient.posts[0].message.Context, "\n"), "Details saved") ||
		!strings.Contains(strings.Join(slackClient.posts[2].message.Context, "\n"), "Details saved") {
		t.Fatalf("evidence summary was not confined to final reply = %+v", slackClient.posts)
	}
}

func TestIncidentCompoundReportPostsOrderedMessagesBeforeFinalEvidenceCard(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(
		ctx, incident.ID, "ses_compound_incident", "incident-compound", 1,
	); err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: incident.ChannelID, ThreadTS: incident.RootTS,
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      "signal", SourceID: "signal-compound",
		Repository: incident.Repository, Prompt: "check host, workload, and dependency",
	})
	if err != nil || !created {
		t.Fatalf("queue incident run = %+v, %t, %v", run, created, err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindAgentRunSession(
		ctx, leased.ID, "ses_compound_incident", 0, incident.Repository, 0, leased.Context,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(ctx, leased.ID, "turn_compound", 2, 0); err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(
		ctx,
		leased.ID,
		"completed",
		[]byte(`{
			"message":"**Host:** both nodes are responsive.",
			"followup_messages":[
				"**Workload:** all expected allocations are running.",
				"**Dependency:** database latency remains unverified."
			],
			"evidence":[{"claim":"hosts respond","observation":"two host checks passed","source_type":"emisar","source_name":"host check"}],
			"coverage":[{"layer":"host","status":"healthy","source":"host check","detail":"both nodes responded"}],
			"memory":{},
			"proposals":[]
		}`),
		"",
		0,
	); err != nil {
		t.Fatal(err)
	}
	slackClient := &fakeSlack{dedupePosts: true}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if len(slackClient.posts) != 3 {
		t.Fatalf("compound incident posts = %+v", slackClient.posts)
	}
	for index, expected := range []string{"Host", "Workload", "Dependency"} {
		post := slackClient.posts[index]
		if post.channel != incident.ChannelID || post.thread != incident.RootTS ||
			!strings.Contains(post.message.Text, expected) {
			t.Fatalf("compound incident delivery = %+v", slackClient.posts)
		}
	}
	if !strings.Contains(
		strings.Join(slackClient.posts[2].message.Context, "\n"),
		"Details saved",
	) {
		t.Fatalf("final compound incident evidence = %+v", slackClient.posts[2])
	}
}

func TestWatchedEngineeringRequestStaysInSourceThread(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	const screenshotURL = "https://files.slack.com/files-pri/T-F/task.png"
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{
		dedupePosts: true,
		files:       map[string][]byte{screenshotURL: testPNG},
	}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
			"action":"reply",
			"attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3},
			"message":"I can audit and update infra/ in a dedicated isolated working copy.",
		"task_title":"Audit infrastructure packs"
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID: "slack-engineering-request", EnvelopeID: "env-engineering-request",
		EventID: "event-engineering-request", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.900", UserID: "U123ABC",
		Text: "Change infra/ to install every pack our production topology needs.",
		Attachments: []core.SlackAttachment{{
			ID: "FTASK", Name: "task.png", MediaType: "image/png",
			Size: int64(len(testPNG)), URLPrivate: screenshotURL,
		}},
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 ||
		slackClient.posts[0].thread != "" ||
		len(slackClient.posts[0].message.Actions) != 1 ||
		slackClient.posts[0].message.Actions[0].ID != slackui.ActionStartTask ||
		slackClient.posts[0].message.Actions[0].Value != source.ID {
		t.Fatalf("engineering task offer = %+v", slackClient.posts)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", source.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(run)
	if err != nil ||
		state.OfferedTaskTitle != "Audit infrastructure packs" ||
		state.OfferedTaskRepository != cfg.Slack.DefaultRepository {
		t.Fatalf("persisted task offer = %+v, %v", state, err)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("task started before approval = %+v, %v", incidents, err)
	}

	click := func(id, userID string) {
		t.Helper()
		input := core.SlackInput{
			ID: id, EnvelopeID: "env-" + id, EventID: "event-" + id,
			Kind: "action", TeamID: cfg.Slack.TeamID, ChannelID: source.ChannelID,
			MessageTS: "1700.001", UserID: userID,
			ActionID: slackui.ActionStartTask, ActionValue: source.ID,
		}
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", id, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", id, err)
		}
	}
	click("engineering-task-unauthorized", "UOTHER")
	if len(slackClient.ephemerals) != 1 ||
		!strings.Contains(slackClient.ephemerals[0].message.Text, "Only a configured operator") {
		t.Fatalf("unauthorized engineering task response = %+v", slackClient.ephemerals)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("unauthorized click created task = %+v, %v", incidents, err)
	}
	stale := core.SlackInput{
		ID: "engineering-task-stale", EnvelopeID: "env-engineering-task-stale",
		EventID: "event-engineering-task-stale", Kind: "action",
		TeamID: cfg.Slack.TeamID, ChannelID: source.ChannelID,
		MessageTS: "1700.999", UserID: "U123ABC",
		ActionID: slackui.ActionStartTask, ActionValue: source.ID,
	}
	if created, err := st.AdmitSlackInput(ctx, stale); err != nil || !created {
		t.Fatalf("admit stale = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatalf("process stale: %v", err)
	}
	if len(slackClient.ephemerals) != 2 ||
		!strings.Contains(slackClient.ephemerals[1].message.Text, "stale") {
		t.Fatalf("stale task response = %+v", slackClient.ephemerals)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("stale click created task = %+v, %v", incidents, err)
	}
	click("engineering-task-authorized", "U123ABC")
	drainSlackDeliveries(t, ctx, svc)
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 1 || !incidents[0].IsEngineeringTask() {
		t.Fatalf("engineering task = %+v, %v", incidents, err)
	}
	if !incidents[0].IsThreadScoped() ||
		incidents[0].OriginChannelID != source.ChannelID ||
		incidents[0].OriginThreadTS != source.MessageTS {
		t.Fatalf("engineering task scope = %+v", incidents[0])
	}
	directoryEntry := incidentDirectoryEntry(incidents[0])
	if !strings.Contains(directoryEntry, "engineering task") ||
		!strings.Contains(directoryEntry, "repository work") ||
		strings.Contains(directoryEntry, "alert firing") {
		t.Fatalf("engineering task directory entry = %q", directoryEntry)
	}
	if len(slackClient.posts) != 2 ||
		slackClient.posts[1].thread != source.MessageTS ||
		slackClient.posts[1].message.Text !=
			"On it. I’ll make the change in an isolated working copy and report back here." {
		t.Fatalf("engineering task acknowledgement = %+v", slackClient.posts)
	}
	signals, err := st.ListSignals(ctx, incidents[0].ID)
	if err != nil || len(signals) != 1 ||
		signals[0].Labels["work_kind"] != "engineering_task" ||
		signals[0].Summary != source.Text {
		t.Fatalf("engineering task source = %+v, %v", signals, err)
	}
	if err := svc.processChannel(ctx); err != nil {
		t.Fatal(err)
	}
	if slackClient.createChannelCalls != 0 {
		t.Fatalf("thread task created %d Slack channels", slackClient.createChannelCalls)
	}
	if err := svc.processSlackDelivery(ctx); err != nil {
		t.Fatal(err)
	}
	incidents, err = st.ListIncidents(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	task := incidents[0]
	if task.ChannelID != source.ChannelID || task.RootTS == "" ||
		task.ConversationThreadTS() != source.MessageTS {
		t.Fatalf("bound thread task = %+v", task)
	}
	taskCard := slackClient.posts[len(slackClient.posts)-1]
	if taskCard.channel != source.ChannelID ||
		taskCard.thread != source.MessageTS ||
		!strings.Contains(taskCard.message.Text, "Engineering task") {
		t.Fatalf("thread task card = %+v", taskCard)
	}
	if err := svc.processSession(ctx); err != nil {
		t.Fatal(err)
	}
	for count := 0; count < 4; count++ {
		err := svc.processSlackDelivery(ctx)
		if errors.Is(err, store.ErrNotFound) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	for _, post := range slackClient.posts {
		if post.message.Header == "Engineering room ready" ||
			strings.Contains(post.message.Text, "<#CINCIDENT>") {
			t.Fatalf("thread task posted a room handoff = %+v", slackClient.posts)
		}
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	taskPrompt := coopClient.submitPrompts[len(coopClient.submitPrompts)-1]
	taskArtifacts := coopClient.submitArtifacts[len(coopClient.submitArtifacts)-1]
	if len(taskArtifacts) != 1 || taskArtifacts[0].Name != "task.png" ||
		string(taskArtifacts[0].Data) != string(testPNG) {
		t.Fatalf("engineering task lost source attachment = %+v", taskArtifacts)
	}
	for _, required := range []string{
		"Complete this operator-approved engineering task",
		"File edits, tests, and commits are allowed",
		"Do not merge, push, deploy, sign, or mutate infrastructure",
	} {
		if !strings.Contains(taskPrompt, required) {
			t.Fatalf("dedicated task prompt lacks %q:\n%s", required, taskPrompt)
		}
	}

	followup := core.SlackInput{
		ID: "task-thread-followup", EnvelopeID: "env-task-thread-followup",
		EventID: "event-task-thread-followup", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: source.ChannelID, ThreadTS: source.MessageTS, MessageTS: "1700.902",
		UserID: "U123ABC", Text: "Also update the operations documentation.",
	}
	if created, err := st.AdmitSlackInput(ctx, followup); err != nil || !created {
		t.Fatalf("admit task follow-up = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	queued, err := st.GetAgentRunBySource(ctx, "slack", followup.ID)
	if err != nil || queued.IncidentID != task.ID {
		t.Fatalf("thread follow-up routing = %+v, %v", queued, err)
	}

	unrelated := core.SlackInput{
		ID: "task-channel-unrelated", EnvelopeID: "env-task-channel-unrelated",
		EventID: "event-task-channel-unrelated", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: source.ChannelID, MessageTS: "1700.903",
		UserID: "U123ABC", Text: "Unrelated shared-channel conversation.",
	}
	if created, err := st.AdmitSlackInput(ctx, unrelated); err != nil || !created {
		t.Fatalf("admit unrelated message = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if queued, err := st.GetAgentRunBySource(ctx, "slack", unrelated.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("unrelated message entered task session = %+v, %v", queued, err)
	}
}

func TestWatchedEngineeringOfferConditionsPrimaryReplyOnConfirmation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	slackClient := &fakeSlack{dedupePosts: true}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
		"action":"reply",
		"attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":3},
		"message":"Yes — I’ll prepare a PR to require a sustained latency condition before this warning fires. I’ll also review the device wording.",
		"task_title":"Reduce Cassandra disk-latency alert noise",
		"task_repository":"repo"
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID:         "slack-conditional-engineering-offer",
		EnvelopeID: "env-conditional-engineering-offer",
		EventID:    "event-conditional-engineering-offer",
		Kind:       "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.950", UserID: "U123ABC",
		Text: "Make a PR to reduce noise from brief latency spikes.",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)

	if len(slackClient.posts) != 1 {
		t.Fatalf("engineering task offer posts = %+v", slackClient.posts)
	}
	offer := slackClient.posts[0].message
	for field, content := range map[string]string{
		"text": offer.Text, "markdown": offer.Markdown,
	} {
		if !strings.Contains(content, "Confirm the engineering task below before I start repository work.") {
			t.Errorf("engineering task offer %s does not condition work on confirmation: %q", field, content)
		}
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("engineering task started before confirmation = %+v, %v", incidents, err)
	}
}

func TestDecisionReadyDiagnosisOffersIncidentAndPreparedFix(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{dedupePosts: true}
	coopClient := newFakeCoop()
	const taskPrompt = "Update the LoL rank decoder to treat unknown upstream rank values as unranked, add focused regression tests for WOOD and SALT, and verify the exact production error signature is absent after deployment."
	coopClient.completeOnSubmit = `{
		"action":"reply",
		"attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":3,"ownership":3},
		"message":"LoL requests are failing because the rank decoder rejects new upstream values.",
		"incident_title":"Coordinate LoL request degradation",
		"task_title":"Make LoL rank decoding forward-compatible",
		"task_repository":"repo",
		"task_prompt":` + fmt.Sprintf("%q", taskPrompt) + `,
		"alert_assessment":{
			"verdict":"confirmed_issue",
			"impact":"LoL requests fail continuously.",
			"cause_status":"identified",
			"cause":"The decoder rejects WOOD and SALT rank values.",
			"immediate_action":"Treat unknown values as unranked.",
			"verification":"Confirm the exact errors disappear after deployment.",
			"long_term_solution":"Use forward-compatible rank decoding with telemetry."
		},
		"completion":{"status":"decision_ready","summary":"The failure and fix boundary are established."},
		"evidence":[{"claim":"the decoder is strict","observation":"the repository decoder enumerates rank values","source_type":"repository","source_name":"lib/rank.ex"}],
		"coverage":[{"layer":"application","status":"degraded","detail":"LoL requests fail on new rank values"}]
	}`
	if _, err := parseWatchDecision(coopClient.completeOnSubmit); err != nil {
		t.Fatalf("parse diagnosis decision: %v", err)
	}
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID: "slack-diagnosed-fix", EnvelopeID: "env-diagnosed-fix",
		EventID: "event-diagnosed-fix", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1701.100", UserID: "U123ABC",
		Text: "<@U999BOT> Why are LoL requests failing?",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 || len(slackClient.posts[0].message.Actions) != 2 ||
		slackClient.posts[0].message.Actions[0].ID != slackui.ActionOpenIncident ||
		slackClient.posts[0].message.Actions[1].ID != slackui.ActionStartTask ||
		slackClient.posts[0].message.Actions[1].Label != "Prepare code fix" {
		run, _ := st.GetAgentRunBySource(ctx, "watch", source.ID)
		t.Fatalf("diagnosis offers = %+v; run = %+v", slackClient.posts, run)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", source.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(run)
	if err != nil || state.OfferedTaskPrompt != taskPrompt ||
		state.OfferedIncidentTitle == "" || state.OfferedTaskTitle == "" {
		t.Fatalf("persisted diagnosis offers = %+v, %v", state, err)
	}
	click := core.SlackInput{
		ID: "prepare-diagnosed-fix", EnvelopeID: "env-prepare-diagnosed-fix",
		EventID: "event-prepare-diagnosed-fix", Kind: "action",
		TeamID: cfg.Slack.TeamID, ChannelID: source.ChannelID,
		MessageTS: "1700.001", UserID: "U123ABC",
		ActionID: slackui.ActionStartTask, ActionValue: source.ID,
	}
	if created, err := st.AdmitSlackInput(ctx, click); err != nil || !created {
		t.Fatalf("admit click = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	incidents, err := st.ListIncidents(ctx, 10)
	if err != nil || len(incidents) != 1 || !incidents[0].IsEngineeringTask() {
		t.Fatalf("prepared fix task = %+v, %v", incidents, err)
	}
	signals, err := st.ListSignals(ctx, incidents[0].ID)
	if err != nil || len(signals) != 1 || signals[0].Summary != taskPrompt {
		t.Fatalf("prepared fix objective = %+v, %v", signals, err)
	}
}

func TestWatchOfferActionMatchesExactThreadedDelivery(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(
		cfg,
		st,
		newFakeCoop(),
		&fakeSlack{},
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	source := core.SlackInput{
		ID: "threaded-offer-source", ChannelID: "CWATCH",
		ThreadTS: "1700.700", MessageTS: "1700.701",
	}
	if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
		ID: "watch_reply_" + source.ID, Kind: "notice",
		ChannelID: source.ChannelID, ThreadTS: source.ThreadTS,
		Body: []byte(`{"text":"offer"}`),
	}); err != nil {
		t.Fatal(err)
	}
	delivery, err := st.LeaseSlackDelivery(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackDelivery(
		ctx,
		delivery.ID,
		"1700.702",
		"sending",
	); err != nil {
		t.Fatal(err)
	}
	matching := core.SlackInput{
		ChannelID: source.ChannelID,
		ThreadTS:  source.ThreadTS,
		MessageTS: "1700.702",
	}
	matches, err := svc.watchOfferActionMatchesDelivery(ctx, matching, source)
	if err != nil || !matches {
		t.Fatalf("matching threaded offer = %v, %v", matches, err)
	}
	for name, input := range map[string]core.SlackInput{
		"wrong channel": {
			ChannelID: "COTHER", ThreadTS: source.ThreadTS, MessageTS: "1700.702",
		},
		"wrong thread": {
			ChannelID: source.ChannelID, ThreadTS: "1700.799", MessageTS: "1700.702",
		},
		"wrong message": {
			ChannelID: source.ChannelID, ThreadTS: source.ThreadTS, MessageTS: "1700.799",
		},
	} {
		t.Run(name, func(t *testing.T) {
			matches, err := svc.watchOfferActionMatchesDelivery(ctx, input, source)
			if err != nil || matches {
				t.Fatalf("mismatched threaded offer = %v, %v", matches, err)
			}
		})
	}

	multipartSource := core.SlackInput{
		ID: "multipart-offer-source", ChannelID: "CWATCH",
		ThreadTS: "1700.800", MessageTS: "1700.801",
	}
	for _, part := range []struct {
		id        string
		messageTS string
	}{
		{id: "watch_reply_" + multipartSource.ID + "_part_001", messageTS: "1700.802"},
		{id: "watch_reply_" + multipartSource.ID + "_part_999", messageTS: "1700.803"},
	} {
		if _, err := st.EnqueueSlackDelivery(ctx, core.SlackDelivery{
			ID: part.id, Kind: "notice", ChannelID: multipartSource.ChannelID,
			ThreadTS: multipartSource.ThreadTS, Body: []byte(`{"text":"offer part"}`),
		}); err != nil {
			t.Fatal(err)
		}
		delivery, err := st.LeaseSlackDelivery(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if delivery.ID != part.id {
			t.Fatalf("leased multipart delivery = %q, want %q", delivery.ID, part.id)
		}
		if err := st.FinishSlackDelivery(
			ctx,
			delivery.ID,
			part.messageTS,
			"sending",
		); err != nil {
			t.Fatal(err)
		}
	}
	finalPart := core.SlackInput{
		ChannelID: multipartSource.ChannelID,
		ThreadTS:  multipartSource.ThreadTS,
		MessageTS: "1700.803",
	}
	matches, err = svc.watchOfferActionMatchesDelivery(ctx, finalPart, multipartSource)
	if err != nil || !matches {
		t.Fatalf("multipart final offer = %v, %v", matches, err)
	}
	earlierPart := finalPart
	earlierPart.MessageTS = "1700.802"
	matches, err = svc.watchOfferActionMatchesDelivery(ctx, earlierPart, multipartSource)
	if err != nil || matches {
		t.Fatalf("multipart earlier offer = %v, %v", matches, err)
	}
}

func TestWatchedEngineeringRequestRequiresRepositoryWhenSeveralAreConfigured(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Repositories["backend"] = config.Repository{
		DisplayName: "Backend",
		CoopPolicy:  "backend-observe",
	}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{dedupePosts: true}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
			"action":"reply",
			"attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3},
			"message":"I can make that repository change.",
		"task_title":"Update deployment packs"
	}`
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	source := core.SlackInput{
		ID: "slack-ambiguous-repository", EnvelopeID: "env-ambiguous-repository",
		EventID: "event-ambiguous-repository", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.950", UserID: "U123ABC",
		Text: "Update the deployment packs.",
	}
	if created, err := st.AdmitSlackInput(ctx, source); err != nil || !created {
		t.Fatalf("admit source = %v, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.posts) != 1 ||
		len(slackClient.posts[0].message.Actions) != 0 ||
		!strings.Contains(slackClient.posts[0].message.Text, "Which configured repository") ||
		!strings.Contains(slackClient.posts[0].message.Text, "Backend (`backend`)") ||
		!strings.Contains(slackClient.posts[0].message.Text, "Repository (`repo`)") {
		t.Fatalf("ambiguous repository response = %+v", slackClient.posts)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", source.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(run)
	if err != nil {
		t.Fatal(err)
	}
	if state.OfferedTaskTitle != "" || state.OfferedTaskRepository != "" {
		t.Fatalf("ambiguous task offer was persisted: %+v", state)
	}
	if incidents, err := st.ListIncidents(ctx, 10); err != nil || len(incidents) != 0 {
		t.Fatalf("ambiguous task started work: %+v, %v", incidents, err)
	}
}

func TestExplicitIncidentRequestRecognition(t *testing.T) {
	for _, input := range []string{
		"Open an incident for this failure",
		"please create incident for checkout",
		"Declare the incident now",
		"turn this into an incident",
	} {
		if !explicitIncidentRequest(input) {
			t.Fatalf("explicit request was not recognized: %q", input)
		}
	}
	for _, input := range []string{
		"How healthy is production?",
		"This looks like an incident",
		"Should we open one?",
		"Investigate the disconnected runners",
		"When you create an incident channel always invite me into it",
		"Always create an incident for critical alerts",
	} {
		if explicitIncidentRequest(input) {
			t.Fatalf("ordinary conversation was treated as explicit: %q", input)
		}
	}
}

func TestWatchedDecisionReceivesFreshChronologicalChannelContext(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	inputs := []core.SlackInput{
		{
			ID: "slack-context-3", EnvelopeID: "env-context-3", EventID: "EvContext3",
			Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
			MessageTS: "1700000000.000003", UserID: "U333",
			Text: "Yes, I am checking it now.",
		},
		{
			ID: "slack-context-1", EnvelopeID: "env-context-1", EventID: "EvContext1",
			Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
			MessageTS: "1700000000.000001", UserID: "U111",
			Text: "Can someone review the deploy?",
		},
		{
			ID: "slack-context-2", EnvelopeID: "env-context-2", EventID: "EvContext2",
			Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
			MessageTS: "1700000000.000002", UserID: "U222",
			Text: "<@U333> do you know what changed?",
		},
	}
	for _, input := range inputs {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %v, %v", input.ID, created, err)
		}
	}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{"action":"ignore"}`
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(coopClient.submitPrompts) != 1 {
		t.Fatalf("submitted prompts = %d", len(coopClient.submitPrompts))
	}
	prompt := coopClient.submitPrompts[0]
	start := strings.Index(prompt, "<untrusted-slack-context>\n")
	end := strings.Index(prompt, "\n</untrusted-slack-context>")
	if start < 0 || end <= start {
		t.Fatalf("prompt has no bounded context: %s", prompt)
	}
	var evidence struct {
		TargetMessage  watchContextMessage   `json:"target_message"`
		RecentMessages []watchContextMessage `json:"recent_channel_messages"`
	}
	start += len("<untrusted-slack-context>\n")
	if err := json.Unmarshal([]byte(prompt[start:end]), &evidence); err != nil {
		t.Fatal(err)
	}
	if evidence.TargetMessage.Text != inputs[1].Text ||
		len(evidence.RecentMessages) != 3 {
		t.Fatalf("watch evidence = %+v", evidence)
	}
	wantTexts := []string{inputs[1].Text, inputs[2].Text, inputs[0].Text}
	for i, want := range wantTexts {
		if evidence.RecentMessages[i].Text != want {
			t.Fatalf("recent message %d = %+v, want %q",
				i, evidence.RecentMessages[i], want)
		}
	}
	if !evidence.RecentMessages[0].Target ||
		evidence.RecentMessages[1].MentionsResponder ||
		!strings.Contains(prompt, "people are talking to each other") ||
		!strings.Contains(prompt, "newer human message already answers the target") {
		t.Fatalf("conversation targeting guidance = %+v", evidence)
	}
	first, err := st.GetSlackInput(ctx, "slack-context-1")
	if err != nil || first.State != "done" {
		t.Fatalf("oldest source message was not processed first: %+v, %v", first, err)
	}
	for _, id := range []string{"slack-context-2", "slack-context-3"} {
		item, err := st.GetSlackInput(ctx, id)
		if err != nil || item.State != "pending" {
			t.Fatalf("later source message %s overtook target: %+v, %v", id, item, err)
		}
	}
}

func TestExplicitMentionLoadsAmbientSlackHistoryWhenProactiveTriageIsOff(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.SummonChannels = []string{"CWATCH"}
	cfg.Slack.WatchChannels = nil
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	target := core.SlackInput{
		ID: "slack-mentioned", EnvelopeID: "env-mentioned", EventID: "EvMentioned",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700000000.000003", UserID: "U123ABC",
		Text: "<@U999BOT> should we roll this back?",
	}
	if created, err := st.AdmitSlackInput(ctx, target); err != nil || !created {
		t.Fatalf("admit mention = %v, %v", created, err)
	}
	slack := &fakeSlack{history: []slackui.HistoryMessage{
		{
			Timestamp: "1700000000.000001", UserID: "U111",
			Text: "The deploy raised the API error rate.",
		},
		{
			Timestamp: "1700000000.000002", UserID: "U222",
			Text: "I paused the next rollout step.",
		},
		{
			Timestamp: target.MessageTS, UserID: target.UserID, Text: target.Text,
		},
	}}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{"action":"ignore"}`
	svc := New(
		cfg, st, coopClient, slack, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(coopClient.submitPrompts) != 1 {
		t.Fatalf("submitted prompts = %d", len(coopClient.submitPrompts))
	}
	prompt := coopClient.submitPrompts[0]
	start := strings.Index(prompt, "<untrusted-slack-context>\n")
	end := strings.Index(prompt, "\n</untrusted-slack-context>")
	if start < 0 || end <= start {
		t.Fatalf("prompt has no bounded context: %s", prompt)
	}
	var evidence struct {
		RecentMessages []watchContextMessage `json:"recent_channel_messages"`
	}
	start += len("<untrusted-slack-context>\n")
	if err := json.Unmarshal([]byte(prompt[start:end]), &evidence); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"The deploy raised the API error rate.",
		"I paused the next rollout step.",
		"should we roll this back?",
	}
	if len(evidence.RecentMessages) != len(want) {
		t.Fatalf("recent Slack history = %+v", evidence.RecentMessages)
	}
	for i := range want {
		if evidence.RecentMessages[i].Text != want[i] {
			t.Fatalf(
				"recent Slack history %d = %q, want %q",
				i,
				evidence.RecentMessages[i].Text,
				want[i],
			)
		}
	}
}

func TestProactiveAttentionCanAcknowledgeWithoutPosting(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-react", EnvelopeID: "env-react", EventID: "EvReact",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700000000.000010", UserID: "U123ABC",
		Text: "The production rollout is complete and all checks passed.",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit message = %v, %v", created, err)
	}
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
		"action":"react",
		"reaction":"tada",
		"attention":{
			"addressee":"channel",
			"urgency":1,
			"confidence":3,
			"novelty":1,
			"ownership":1
		},
		"reason":"Acknowledge the completed handoff without interrupting the channel."
	}`
	svc := New(
		cfg,
		st,
		coopClient,
		slackClient,
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)
	if len(slackClient.reactions) != 1 ||
		slackClient.reactions[0].channel != input.ChannelID ||
		slackClient.reactions[0].timestamp != input.MessageTS ||
		slackClient.reactions[0].name != "tada" {
		t.Fatalf("reactions = %+v", slackClient.reactions)
	}
	if len(slackClient.posts) != 0 {
		t.Fatalf("reaction-only decision posted a message: %+v", slackClient.posts)
	}
}

func TestWatchedDecisionWaitsForNearbyConversation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	cfg.Slack.WatchSettleDelay.Duration = 5 * time.Second
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	input := core.SlackInput{
		ID: "slack-settle", EnvelopeID: "env-settle", EventID: "EvSettle",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700000000.000001", UserID: "U111", Text: "Is the deploy okay?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	run, runErr := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || stored.State != "done" || runErr != nil ||
		run.State != core.AgentRunPending ||
		!run.NextAttemptAt.After(time.Now()) ||
		len(coopClient.createKeys) != 0 {
		t.Fatalf("settling input = %+v, Coop creates=%v, error=%v",
			stored, coopClient.createKeys, err)
	}
}

func TestLateWatchedMessageCannotRespondAfterNewerDecision(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	newer := core.SlackInput{
		ID: "slack-late-new", EnvelopeID: "env-late-new", EventID: "EvLateNew",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700000000.000002", UserID: "U222", Text: "Newer event",
	}
	if created, err := st.AdmitSlackInput(ctx, newer); err != nil || !created {
		t.Fatalf("admit newer = %v, %v", created, err)
	}
	leased, err := st.LeaseSlackInput(ctx)
	if err != nil || leased.ID != newer.ID {
		t.Fatalf("lease newer = %+v, %v", leased, err)
	}
	if err := st.Audit(ctx, core.AuditEvent{
		Kind: "slack.watch", ObjectID: "slack-late-new", Outcome: "ignored",
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.FinishSlackInput(ctx, newer.ID); err != nil {
		t.Fatal(err)
	}
	older := core.SlackInput{
		ID: "slack-late-old", EnvelopeID: "env-late-old", EventID: "EvLateOld",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700000000.000001", UserID: "U111", Text: "Old delayed event",
	}
	if created, err := st.AdmitSlackInput(ctx, older); err != nil || !created {
		t.Fatalf("admit older = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetSlackInput(ctx, "slack-late-old")
	if err != nil || stored.State != "done" || len(coopClient.createKeys) != 0 {
		t.Fatalf("late input = %+v, Coop creates=%v, error=%v",
			stored, coopClient.createKeys, err)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", older.ID)
	if err != nil || run.State != core.AgentRunSuperseded {
		t.Fatalf("late run = %+v, %v", run, err)
	}
}

func TestIncidentTurnCapacityExtendsAutomatically(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(ctx, incident.ID, "ses_1", "incident-api", 7); err != nil {
		t.Fatal(err)
	}
	if _, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: incident.ChannelID, ThreadTS: incident.RootTS,
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      "control", SourceID: "automatic-capacity",
		UserID: "U123ABC", Repository: incident.Repository,
		Prompt: "Inspect current evidence.",
	}); err != nil || !created {
		t.Fatalf("queue turn = %v, %v", created, err)
	}
	coopClient := newFakeCoop()
	coopClient.session.Revision = 7
	coopClient.session.State = "exhausted"
	coopClient.session.MaxTurns = 100
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	if coopClient.session.MaxTurns != 125 || len(coopClient.submitKeys) != 1 {
		t.Fatalf("automatic capacity session = %+v, submissions = %v",
			coopClient.session, coopClient.submitKeys)
	}
	submission, err := st.GetAgentRunBySource(ctx, "control", "automatic-capacity")
	if err != nil || submission.State != core.AgentRunRunning ||
		submission.SessionID != "ses_1" {
		t.Fatalf("automatic-capacity submission = %+v, %v", submission, err)
	}
}

func TestAutomaticTurnCapacityHonorsConfiguredCeiling(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Coop.TurnLimit = 100
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.State = "exhausted"
	coopClient.session.MaxTurns = 100
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	_, err = svc.ensureTurnCapacity(ctx, "CWATCH", "", coopClient.session)
	var limitErr *automaticTurnLimitError
	if !errors.As(err, &limitErr) || limitErr.Limit != 100 {
		t.Fatalf("configured ceiling error = %T %v", err, err)
	}
	if coopClient.session.MaxTurns != 100 {
		t.Fatalf("capacity changed beyond ceiling: %+v", coopClient.session)
	}
}

func TestWatchedTurnResumesFromDurableState(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	coopClient.submitState = "starting"
	input := core.SlackInput{
		ID: "slack-watch-resume", EnvelopeID: "env-watch-resume", EventID: "EvWatchResume",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CWATCH",
		MessageTS: "1700.600", UserID: "U123ABC", Text: "Did the deploy recover?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %v, %v", created, err)
	}
	firstSlack := &fakeSlack{}
	svc := New(cfg, st, coopClient, firstSlack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	run, runErr := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || stored.State != "done" || runErr != nil ||
		run.State != core.AgentRunRunning || len(run.Context) == 0 {
		t.Fatalf("running watch input = %+v, %v", stored, err)
	}
	if len(firstSlack.statuses) != 0 {
		t.Fatalf("ambient triage exposed a thread status: %+v", firstSlack.statuses)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}

	coopClient.complete(`{"action":"reply","attention":{"addressee":"responder","urgency":2,"confidence":3,"novelty":2,"ownership":3},"message":"Yes, the deploy recovered."}`)
	st, err = store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{}
	svc = New(cfg, st, coopClient, slack, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	stored, err = st.GetSlackInput(ctx, input.ID)
	if err != nil || stored.State != "done" || len(slack.posts) != 1 {
		t.Fatalf("resumed watch input = %+v, posts=%+v, %v", stored, slack.posts, err)
	}
	if len(slack.statuses) != 0 {
		t.Fatalf("resumed ambient triage exposed a thread status: %+v", slack.statuses)
	}
	if len(coopClient.createKeys) != 1 || len(coopClient.submitKeys) != 1 {
		t.Fatalf("durable state replayed Coop mutations: create=%v submit=%v",
			coopClient.createKeys, coopClient.submitKeys)
	}
}

func TestLongWatchedRunDoesNotConsumeInputRetriesOrBlockLaterContext(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.submitState = "running"
	svc := New(
		cfg,
		st,
		coopClient,
		&fakeSlack{},
		nil,
		slackui.NewSanitizer(12000),
		nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT",
	}
	first := core.SlackInput{
		ID: "slack-long-first", EnvelopeID: "env-long-first",
		EventID: "EvLongFirst", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.100", UserID: "U111",
		Text: "The deploy started.",
	}
	second := core.SlackInput{
		ID: "slack-long-second", EnvelopeID: "env-long-second",
		EventID: "EvLongSecond", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", MessageTS: "1700.200", UserID: "U222",
		Text: "It completed successfully.",
	}
	for _, input := range []core.SlackInput{first, second} {
		if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
			t.Fatalf("admit %s = %t, %v", input.ID, created, err)
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("process %s: %v", input.ID, err)
		}
		if input.ID == first.ID {
			if err := svc.processAgentRun(ctx); err != nil {
				t.Fatal(err)
			}
		}
	}
	for range cfg.Limits.MaxSlackInputAttempts + 5 {
		svc.pollAgentRuns(ctx)
	}
	storedFirst, err := st.GetSlackInput(ctx, first.ID)
	if err != nil || storedFirst.State != "done" || storedFirst.Failures != 0 {
		t.Fatalf("long-running source input = %+v, %v", storedFirst, err)
	}
	firstRun, err := st.GetAgentRunBySource(ctx, "watch", first.ID)
	if err != nil || firstRun.State != core.AgentRunRunning ||
		firstRun.Failures != 0 {
		t.Fatalf("long-running agent run = %+v, %v", firstRun, err)
	}
	secondRun, err := st.GetAgentRunBySource(ctx, "watch", second.ID)
	if err != nil || secondRun.State != core.AgentRunPending {
		t.Fatalf("later message run = %+v, %v", secondRun, err)
	}
	if err := svc.processAgentRun(ctx); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("later run bypassed per-conversation serialization: %v", err)
	}

	coopClient.complete(`{"action":"ignore","reason":"superseded by the successful completion"}`)
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	secondRun, err = st.GetAgentRunBySource(ctx, "watch", second.ID)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeWatchRunContext(secondRun)
	if err != nil {
		t.Fatal(err)
	}
	if len(state.RecentMessages) < 2 ||
		state.RecentMessages[len(state.RecentMessages)-2].Text != first.Text ||
		state.RecentMessages[len(state.RecentMessages)-1].Text != second.Text {
		t.Fatalf("later run context is not ordered and fresh: %+v", state.RecentMessages)
	}
}

func TestWatchedRunRepairsStaleRotatedEventCursor(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Slack.WatchChannels = []string{"CWATCH"}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT",
	}
	input := core.SlackInput{
		ID: "slack-stale-cursor", EnvelopeID: "env-stale-cursor",
		EventID: "EvStaleCursor", Kind: "mention", TeamID: cfg.Slack.TeamID,
		ChannelID: "CWATCH", ThreadTS: "1700.001", MessageTS: "1700.002",
		UserID: "U123ABC", Text: "<@U999BOT> can you review it?",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if err := svc.processAgentRun(ctx); err != nil {
		t.Fatal(err)
	}
	run, err := st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.AdvanceAgentRunEvents(ctx, run.ID, 13); err != nil {
		t.Fatal(err)
	}
	if err := st.AdvanceChannelEvents(
		ctx, input.ChannelID, run.SessionID, 13,
	); err != nil {
		t.Fatal(err)
	}
	coopClient.complete(`{"action":"reply","attention":{"addressee":"responder","urgency":1,"confidence":3,"novelty":2,"ownership":3},"message":"The Terraform plan is safe to apply."}`)
	coopClient.session.LastEventSequence = 1
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	run, err = st.GetAgentRunBySource(ctx, "watch", input.ID)
	if err != nil || run.State != core.AgentRunCompleted ||
		run.CoopEventSequence != 1 {
		t.Fatalf("recovered run = %+v, %v", run, err)
	}
	memory, err := st.GetChannelMemory(ctx, input.ChannelID)
	if err != nil || memory.CoopEventSequence != 1 {
		t.Fatalf("repaired channel memory = %+v, %v", memory, err)
	}
	if len(slackClient.posts) != 1 ||
		!strings.Contains(slackClient.posts[0].message.Text, "Terraform plan") {
		t.Fatalf("recovered Slack posts = %+v", slackClient.posts)
	}
}

func TestParseWatchDecisionIsStrict(t *testing.T) {
	valid := []string{
		`{"action":"ignore"}`,
		`{"action":"ignore","publication_updates":[{"incident_id":"inc_123","kind":"deployment","state":"succeeded","reference":"0123456","summary":"Production rollout completed."}]}`,
		`{"action":"react","reaction":"eyes","attention":{"addressee":"channel","urgency":1,"confidence":3,"novelty":1,"ownership":1}}`,
		`{"action":"react","reaction":"thumbsup"}`,
		`{"action":"react","reaction":"wave::skin-tone-3"}`,
		`{"action":"react","reaction":":deployment_parrot:"}`,
		`{"action":"reply","message":"I am looking at it."}`,
		`{"action":"reply","message":"Waiting for Emisar approval.","pending_approval":{"request_id":"apr_1","run_id":"run_1","operation_id":"op_1","action_id":"service.enable","pack_ref":"service@1#sha256:abc","runner_ref":"prod~abc","status":"pending_approval","approval_url":"https://emisar.dev/app/acme/approvals/apr_1","expires_at":"2099-08-01T00:00:00Z"}}`,
		`{"action":"reply","message":"Two runners are offline.","incident_title":"Two runners offline"}`,
		`{"action":"reply","message":"I can make that change.","task_title":"Audit infrastructure packs","task_repository":"repo","memory":{"topology":{"portal_hosts_declared":2,"runner_mapping":"Two current runners"}}}`,
		`{"action":"reply","message":"The issue is bounded.","incident_title":"Coordinate API degradation","task_title":"Fix API decoder","task_repository":"repo","task_prompt":"Update the decoder to fail soft on unknown values and run focused tests.","alert_assessment":{"verdict":"confirmed_issue","impact":"API requests fail.","cause_status":"identified","cause":"The decoder rejects a new upstream value.","immediate_action":"Fail soft on the new value.","verification":"Confirm the exact error disappears.","long_term_solution":"Use forward-compatible decoding."},"completion":{"status":"decision_ready","summary":"The failure is bounded."},"evidence":[{"claim":"the decoder is strict","observation":"the repository decoder enumerates rank values","source_type":"repository","source_name":"lib/rank.ex"}]}`,
		`{"action":"incident","title":"API unavailable"}`,
	}
	for _, input := range valid {
		if _, err := parseWatchDecision(input); err != nil {
			t.Fatalf("valid decision %s: %v", input, err)
		}
	}
	invalid := []string{
		`{"action":"ignore","message":"no"}`,
		`{"action":"reply","message":""}`,
		`{"action":"incident"}`,
		`{"action":"incident","title":"API unavailable","incident_title":"duplicate"}`,
		`{"action":"reply","message":"Choose a repository.","task_repository":"repo"}`,
		`{"action":"reply","message":"Prepare it.","task_title":"Fix it","task_repository":"repo","task_prompt":"Change the code."}`,
		`{"action":"reply","message":"Prepare it.","task_prompt":"Change the code."}`,
		`{"action":"reply","message":"Prepare it.","task_title":"Fix it","task_repository":"repo","task_prompt":"Change the code.","alert_assessment":{"verdict":"confirmed_issue","impact":"Requests fail.","cause_status":"identified","cause":"The decoder rejects a value.","immediate_action":"Fail soft.","verification":"Confirm errors stop.","long_term_solution":"Use forward-compatible decoding."},"completion":{"status":"decision_ready","summary":"The failure is bounded."},"evidence":[{"claim":"requests fail","observation":"fresh logs contain failures","source_type":"emisar","source_name":"logs"}]}`,
		`{"action":"ignore","unknown":true}`,
		`{"action":"ignore","publication_updates":[{"incident_id":"inc_123","kind":"build","state":"succeeded","reference":"0123456","summary":"Build completed."}]}`,
		`{"action":"ignore","publication_updates":[{"incident_id":"inc_123","kind":"terraform","state":"maybe","reference":"0123456","summary":"Plan changed."}]}`,
		`{"action":"ignore","publication_updates":[{"incident_id":"inc_123","kind":"terraform","state":"pending","reference":"repo","summary":""}]}`,
		`{"action":"react","reaction":"✅"}`,
		`{"action":"react","reaction":"wave::skin-tone-9"}`,
		`{"action":"react","reaction":"not/an/emoji"}`,
		`{"action":"react","reaction":"eyes","message":"also replying"}`,
		`{"action":"ignore","pending_approval":{"request_id":"apr_1"}}`,
		`{"action":"reply","message":"Waiting.","incident_title":"Open it","pending_approval":{"request_id":"apr_1"}}`,
		`{"action":"ignore","attention":{"addressee":"team","urgency":1,"confidence":1,"novelty":1,"ownership":1}}`,
		`{"action":"ignore","attention":{"addressee":"channel","urgency":4,"confidence":1,"novelty":1,"ownership":1}}`,
		"```json\n{\"action\":\"ignore\"}\n```",
		`{"action":"ignore"} {"action":"ignore"}`,
	}
	for _, input := range invalid {
		if _, err := parseWatchDecision(input); err == nil {
			t.Fatalf("invalid decision accepted: %s", input)
		}
	}
}

func TestParseWatchDecisionAcceptsEmptyOptionalObservationTimestamps(t *testing.T) {
	decision, err := parseWatchDecision(`{
		"action":"reply",
		"message":"The live layer is healthy; the declared layer has no source timestamp.",
		"attention":{"addressee":"responder","confidence":3,"ownership":3},
		"evidence":[
			{
				"claim":"Topology is declared",
				"observation":"Two instances",
				"source_type":"repository",
				"source_name":"infra/main.tf",
				"observed_at":""
			},
			{
				"claim":"Two runners are connected",
				"observation":"Both responded",
				"source_type":"emisar",
				"source_name":"Emisar list_runners",
				"observed_at":"2026-07-30T07:00:00Z"
			}
		],
		"coverage":[
			{"layer":"change","status":"unknown","observed_at":""},
			{"layer":"runtime","status":"healthy","observed_at":"2026-07-30T07:00:00Z"}
		],
		"memory":{}
	}`)
	if err != nil {
		t.Fatal(err)
	}
	if len(decision.Evidence) != 2 || !decision.Evidence[0].ObservedAt.IsZero() ||
		len(decision.Coverage) != 2 || !decision.Coverage[0].ObservedAt.IsZero() {
		t.Fatalf("empty optional timestamps were not normalized: %+v", decision)
	}
}

func TestSlackReactionNameNormalization(t *testing.T) {
	valid := map[string]string{
		" TADA ":               "tada",
		":white_check_mark:":   "white_check_mark",
		"+1":                   "+1",
		"wave::skin-tone-6":    "wave::skin-tone-6",
		":deployment_parrot:":  "deployment_parrot",
		"custom-release-ready": "custom-release-ready",
	}
	for input, want := range valid {
		got, err := normalizeSlackReactionName(input)
		if err != nil {
			t.Fatalf("normalize %q: %v", input, err)
		}
		if got != want {
			t.Fatalf("normalize %q = %q, want %q", input, got, want)
		}
	}

	invalid := []string{
		"",
		"✅",
		"wave::skin-tone-1",
		"wave::skin-tone-7",
		"not/an/emoji",
		strings.Repeat("a", 256),
	}
	for _, input := range invalid {
		if got, err := normalizeSlackReactionName(input); err == nil {
			t.Fatalf("normalize %q = %q, want error", input, got)
		}
	}
}

func TestAttentionPolicySuppressesLowValueAmbientInterruptions(t *testing.T) {
	input := core.SlackInput{Kind: "message", ChannelID: "CINFRA"}
	decision := watchDecision{
		Action:  "reply",
		Message: "I can add something.",
		Attention: attentionAssessment{
			Addressee: "human", Urgency: 1, Confidence: 3, Novelty: 1, Ownership: 1,
		},
	}
	filtered := enforceAttentionPolicy(input, watchTurnState{}, decision, 7, 4)
	if filtered.Action != "ignore" || filtered.Message != "" ||
		!strings.Contains(filtered.Reason, "suppressed") {
		t.Fatalf("filtered decision = %+v", filtered)
	}

	input.Kind = "mention"
	filtered = enforceAttentionPolicy(input, watchTurnState{}, decision, 7, 4)
	if filtered.Action != "reply" || filtered.Message == "" {
		t.Fatalf("explicit mention was suppressed: %+v", filtered)
	}

	input.Kind = "message"
	decision.Attention = attentionAssessment{}
	filtered = enforceAttentionPolicy(input, watchTurnState{}, decision, 7, 4)
	if filtered.Action != "ignore" {
		t.Fatalf("ambient action without assessment = %q, want ignore", filtered.Action)
	}

	decision.Action = "react"
	decision.Reaction = "eyes"
	filtered = enforceAttentionPolicy(input, watchTurnState{}, decision, 7, 4)
	if filtered.Action != "ignore" || filtered.Reaction != "" {
		t.Fatalf("reaction without assessment = %+v, want suppressed", filtered)
	}

	decision.Action = "reply"
	decision.Message = "I will interrupt them."
	decision.Attention = attentionAssessment{
		Addressee: "human", Urgency: 2, Confidence: 3, Novelty: 2, Ownership: 2,
	}
	filtered = enforceAttentionPolicy(
		input,
		watchTurnState{ConversationFollowup: true},
		decision,
		7,
		4,
	)
	if filtered.Action != "ignore" {
		t.Fatalf("human-directed continuation was not suppressed: %+v", filtered)
	}
}

func TestParseWatchDecisionNormalizesStructuredMemoryTopology(t *testing.T) {
	decision, err := parseWatchDecision(`{
		"action":"reply",
		"message":"I can make that change.",
		"task_title":"Audit infrastructure packs",
		"memory":{
			"topology":{
				"runner_mapping":"Two current runners",
				"portal_hosts_declared":2
			}
		}
	}`)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"portal_hosts_declared: 2",
		"runner_mapping: Two current runners",
	}
	if !slices.Equal(decision.Memory.Topology, want) {
		t.Fatalf("normalized topology = %#v, want %#v", decision.Memory.Topology, want)
	}

	decision, err = parseWatchDecision(`{
		"action":"reply",
		"message":"I can make that change.",
		"task_title":"Audit infrastructure packs",
		"memory":{
			"topology":[
				{"service":"portal","declared_instances":2},
				{"service":"database","kind":"cloud-sql"}
			]
		}
	}`)
	if err != nil {
		t.Fatal(err)
	}
	want = []string{
		"declared_instances: 2; service: portal",
		"kind: cloud-sql; service: database",
	}
	if !slices.Equal(decision.Memory.Topology, want) {
		t.Fatalf("normalized topology array = %#v, want %#v", decision.Memory.Topology, want)
	}
}

func TestParseWatchDecisionExtractsFinalEnvelopeAfterCoopProgress(t *testing.T) {
	output := "I’m checking the repository and current infrastructure state." +
		"The evidence is sufficient; I’m preparing the answer." +
		`{"action":"reply","reason":"The operator asked for a health assessment.",` +
		`"message":"Production is healthy within the checked scope.",` +
		`"evidence":[{"claim":"Both hosts are connected","observation":"Two of two runners are connected",` +
		`"source_type":"emisar","source_name":"list_runners"}],` +
		`"coverage":[{"layer":"host","status":"healthy"}],"memory":{}}`
	decision, err := parseWatchDecision(output)
	if err != nil {
		t.Fatal(err)
	}
	if decision.Action != "reply" ||
		decision.Message != "Production is healthy within the checked scope." ||
		len(decision.Evidence) != 1 || len(decision.Coverage) != 1 {
		t.Fatalf("extracted decision = %+v", decision)
	}
}

func createBoundIncident(t *testing.T, ctx context.Context, st *store.Store) core.Incident {
	t.Helper()
	event := core.WebhookEvent{Signals: []core.Signal{{
		Route: "grafana", SourceID: "alert-bound", EventID: "event-bound",
		Repository: "repo", CorrelationKey: "bound", Status: core.SignalFiring,
		Title: "API unavailable", Severity: "critical",
		Summary:    "API requests are timing out.",
		SourceURL:  "https://grafana.example.test/alerting/1",
		ReceivedAt: time.Now().UTC(),
	}}}
	incidents, err := st.ApplySignals(ctx, event, time.Hour, 0, 100)
	if err != nil || len(incidents) != 1 {
		t.Fatalf("create incident = %+v, %v", incidents, err)
	}
	if err := st.SetChannel(ctx, incidents[0].ID, "CINCIDENT", "inc-api"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetRoot(ctx, incidents[0].ID, "1700.001"); err != nil {
		t.Fatal(err)
	}
	incident, err := st.GetIncident(ctx, incidents[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	return incident
}

func stageAgentRunWithMissingConversationSource(
	t *testing.T,
	ctx context.Context,
	st *store.Store,
) core.AgentRun {
	t.Helper()
	incident := createBoundIncident(t, ctx, st)
	if err := st.SetCoopSession(
		ctx,
		incident.ID,
		"ses_finalization",
		"incident-finalization",
		1,
	); err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunIncident, IncidentID: incident.ID,
		ChannelID: incident.ChannelID, ThreadTS: incident.RootTS,
		ConversationKey: "incident:" + incident.ID,
		SourceKind:      "slack", SourceID: "missing-slack-source",
		Repository: incident.Repository, Prompt: "investigate",
	})
	if err != nil || !created {
		t.Fatalf("queue agent run = %+v, %v, %v", run, created, err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindAgentRunSession(
		ctx,
		leased.ID,
		"ses_finalization",
		0,
		incident.Repository,
		0,
		leased.Context,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.MarkAgentRunSubmitted(
		ctx,
		leased.ID,
		"coop_turn_finalization",
		2,
		0,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.StageAgentRunResult(
		ctx,
		leased.ID,
		"completed",
		[]byte(`{"message":"Investigation complete.","evidence":[],"coverage":[]}`),
		"",
		0,
	); err != nil {
		t.Fatal(err)
	}
	return run
}

type fakeCoop struct {
	session            coop.Session
	turn               coop.Turn
	changes            coop.Changes
	events             []coop.Event
	createKeys         []string
	createPolicies     []string
	createTasks        []string
	prepareKeys        []string
	prepareSessions    []string
	listSessions       []coop.Session
	createErrors       []error
	createResultState  string
	openAfterCreateKey string
	submitKeys         []string
	submitPrompts      []string
	submitArtifacts    [][]coop.InputArtifact
	submitState        string
	completeOnSubmit   string
	completeQueue      []string
	submitTurns        []coop.Turn
	discardPlan        coop.DiscardPlan
	discardCalls       int
	discardAccepts     []bool
	outputArtifacts    map[string]coop.OutputArtifact
}

func newFakeCoop() *fakeCoop {
	return &fakeCoop{session: coop.Session{
		ID: "ses_1", ForkName: "responder-api-unavailable",
		Revision: 1, State: "open", Activity: "parked", MaxTurns: 100,
	}}
}

func (f *fakeCoop) Ready(context.Context) error { return nil }
func (f *fakeCoop) CreateSession(_ context.Context, key, policy, task string) (coop.Session, coop.Operation, error) {
	f.createKeys = append(f.createKeys, key)
	f.createPolicies = append(f.createPolicies, policy)
	f.createTasks = append(f.createTasks, task)
	if len(f.createErrors) > 0 {
		err := f.createErrors[0]
		f.createErrors = f.createErrors[1:]
		if err != nil {
			return coop.Session{}, coop.Operation{}, err
		}
	}
	if f.session.State == "closed" {
		f.session.State = "open"
		f.session.Activity = "parked"
	}
	if key == f.openAfterCreateKey {
		f.session.ID = "ses_2"
		f.session.State = "open"
		f.session.Activity = "parked"
		f.session.Revision = 1
	}
	result := f.session
	if f.createResultState != "" {
		result.State = f.createResultState
	}
	return result, coop.Operation{}, nil
}

func TestWatchRepositorySetSelectsItsCoopPolicy(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.RepositorySets = map[string]config.RepositorySet{
		"platform": {
			DisplayName: "Platform",
			Primary:     "repo",
			CoopPolicy:  "platform-observe",
		},
	}
	cfg.Slack.DefaultRepository = "platform"
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	memory, _, err := svc.ensureWatchSession(ctx, "CREPOSET")
	if err != nil {
		t.Fatal(err)
	}
	if memory.Repository != "platform" {
		t.Fatalf("watch memory repository = %q", memory.Repository)
	}
	if !slices.Equal(coopClient.createPolicies, []string{"platform-observe"}) {
		t.Fatalf("Coop create policies = %v", coopClient.createPolicies)
	}
}

func TestPinnedScheduledSessionUsesTaskRepositoryWithoutReplacingChannelSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	cfg.Repositories["infra"] = config.Repository{
		DisplayName: "Infrastructure",
		CoopPolicy:  "infra-observe",
	}
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.BindChannelSession(
		ctx, "CREPORT", "repo", "ses_channel", 1, 1, time.Now().UTC(),
	); err != nil {
		t.Fatal(err)
	}
	coopClient := newFakeCoop()
	svc := New(
		cfg, st, coopClient, &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	memory, _, err := svc.ensureWatchSessionForRepositoryAtGeneration(
		ctx, "scheduled:health", "infra", 1,
	)
	if err != nil {
		t.Fatal(err)
	}
	if memory.Repository != "infra" || memory.ChannelID != "scheduled:health" {
		t.Fatalf("scheduled memory = %+v", memory)
	}
	if !slices.Equal(coopClient.createPolicies, []string{"infra-observe"}) {
		t.Fatalf("Coop create policies = %v", coopClient.createPolicies)
	}
	channel, err := st.GetChannelMemory(ctx, "CREPORT")
	if err != nil {
		t.Fatal(err)
	}
	if channel.Repository != "repo" || channel.SessionID != "ses_channel" {
		t.Fatalf("delivery channel session was replaced: %+v", channel)
	}
}

func (f *fakeCoop) ListSessions(context.Context, int) ([]coop.Session, error) {
	return append([]coop.Session(nil), f.listSessions...), nil
}
func (f *fakeCoop) GetSession(context.Context, string) (coop.Session, error) {
	return f.session, nil
}
func (f *fakeCoop) PrepareSession(_ context.Context, key, sessionID string, expectedRevision int64) (coop.Session, error) {
	f.prepareKeys = append(f.prepareKeys, key)
	f.prepareSessions = append(f.prepareSessions, sessionID)
	if expectedRevision != f.session.Revision {
		return coop.Session{}, &coop.APIError{Status: 409, Code: "revision_conflict"}
	}
	return f.session, nil
}
func (f *fakeCoop) SubmitTurn(_ context.Context, key, _ string, _ int64, prompt string) (coop.Turn, coop.Operation, error) {
	return f.SubmitTurnWithArtifacts(
		context.Background(), key, "", 0, prompt, nil,
	)
}

func (f *fakeCoop) SubmitTurnWithArtifacts(
	_ context.Context,
	key string,
	_ string,
	_ int64,
	prompt string,
	artifacts []coop.InputArtifact,
) (coop.Turn, coop.Operation, error) {
	f.submitKeys = append(f.submitKeys, key)
	f.submitPrompts = append(f.submitPrompts, prompt)
	f.submitArtifacts = append(f.submitArtifacts, artifacts)
	state := f.submitState
	if state == "" {
		state = "running"
	}
	f.turn = coop.Turn{
		ID:        fmt.Sprintf("coop_turn_%d", len(f.submitKeys)),
		SessionID: f.session.ID,
		State:     state,
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
func (f *fakeCoop) GetTurn(context.Context, string, string) (coop.Turn, error) {
	if f.turn.ID == "" {
		return coop.Turn{}, errors.New("missing turn")
	}
	return f.turn, nil
}
func (f *fakeCoop) GetOutputArtifact(_ context.Context, _, _, artifactID string) (coop.OutputArtifact, error) {
	artifact, ok := f.outputArtifacts[artifactID]
	if !ok {
		return coop.OutputArtifact{}, errors.New("missing output artifact")
	}
	return artifact, nil
}
func (f *fakeCoop) Events(_ context.Context, _ string, after int64, _ int) ([]coop.Event, error) {
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
func (f *fakeCoop) Review(context.Context, string, string, int64) (coop.Review, coop.Operation, error) {
	return coop.Review{}, coop.Operation{}, nil
}
func (f *fakeCoop) Cancel(context.Context, string, string, string, int64) (coop.Turn, coop.Operation, error) {
	return f.turn, coop.Operation{}, nil
}
func (f *fakeCoop) Extend(_ context.Context, _ string, _ string, _ int64, additional int) (coop.Session, coop.Operation, error) {
	f.session.MaxTurns += additional
	f.session.Revision++
	f.session.State = "open"
	f.session.Activity = "parked"
	return f.session, coop.Operation{}, nil
}
func (f *fakeCoop) Close(context.Context, string, string, int64) (coop.Session, coop.Operation, error) {
	f.session.State = "closed"
	return f.session, coop.Operation{}, nil
}
func (f *fakeCoop) PlanDiscard(
	_ context.Context, _ string, _ string, _ int64, _ bool, acceptUnmerged bool,
) (coop.DiscardPlan, coop.Operation, error) {
	f.discardAccepts = append(f.discardAccepts, acceptUnmerged)
	if f.discardPlan.OperationID != "" {
		plan := f.discardPlan
		plan.Plan.Workspace.AcceptedUnmerged = acceptUnmerged
		return plan, coop.Operation{}, nil
	}
	var plan coop.DiscardPlan
	plan.OperationID = "op_discard_plan"
	plan.Plan.SessionID = f.session.ID
	plan.Plan.Revision = f.session.Revision
	return plan, coop.Operation{}, nil
}
func (f *fakeCoop) Discard(
	context.Context, string, string, string,
) (coop.Session, coop.Operation, error) {
	f.discardCalls++
	f.session.State = "discarded"
	return f.session, coop.Operation{}, nil
}

func TestCleanupDiscardsOnlyCleanOwnedSession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.State = "closed"
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := st.ScheduleCleanup(
		ctx, coopClient.session.ID, "", "rotated watch state", false, time.Now().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processCleanup(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	if coopClient.discardCalls != 1 || coopClient.session.State != "discarded" {
		t.Fatalf("clean session was not discarded: calls=%d state=%s",
			coopClient.discardCalls, coopClient.session.State)
	}
}

func TestCleanupRetainsDirtySession(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.State = "closed"
	coopClient.discardPlan.OperationID = "op_dirty"
	coopClient.discardPlan.Plan.SessionID = coopClient.session.ID
	coopClient.discardPlan.Plan.Revision = coopClient.session.Revision
	coopClient.discardPlan.Plan.Workspace.Dirty = true
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := st.ScheduleCleanup(
		ctx, coopClient.session.ID, "", "closed task", false, time.Now().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processCleanup(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	if coopClient.discardCalls != 0 || coopClient.session.State != "closed" {
		t.Fatalf("dirty session was discarded: calls=%d state=%s",
			coopClient.discardCalls, coopClient.session.State)
	}
}

func TestCleanupDiscardsCleanSessionWhoseBaseBranchAdvanced(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.State = "closed"
	coopClient.session.BaseCommit = "abc123"
	coopClient.discardPlan.OperationID = "op_stale_base"
	coopClient.discardPlan.Plan.SessionID = coopClient.session.ID
	coopClient.discardPlan.Plan.Revision = coopClient.session.Revision
	coopClient.discardPlan.Plan.Workspace.Head = "abc123"
	coopClient.discardPlan.Plan.Workspace.Unmerged = true
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := st.ScheduleCleanup(
		ctx, coopClient.session.ID, "", "rotated watch state", false,
		time.Now().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processCleanup(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	if coopClient.discardCalls != 1 || coopClient.session.State != "discarded" {
		t.Fatalf("clean stale-base session was not discarded: calls=%d state=%s",
			coopClient.discardCalls, coopClient.session.State)
	}
	if !slices.Equal(coopClient.discardAccepts, []bool{false, true}) {
		t.Fatalf("discard plan acceptance = %v", coopClient.discardAccepts)
	}
}

func TestCleanupRetainsCleanSessionWithUnpublishedCommit(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.session.State = "closed"
	coopClient.session.BaseCommit = "abc123"
	coopClient.discardPlan.OperationID = "op_unpublished"
	coopClient.discardPlan.Plan.SessionID = coopClient.session.ID
	coopClient.discardPlan.Plan.Revision = coopClient.session.Revision
	coopClient.discardPlan.Plan.Workspace.Head = "def456"
	coopClient.discardPlan.Plan.Workspace.Unmerged = true
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := st.ScheduleCleanup(
		ctx, coopClient.session.ID, "", "closed task", false,
		time.Now().Add(-time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	if err := svc.processCleanup(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	if coopClient.discardCalls != 0 || coopClient.session.State != "closed" {
		t.Fatalf("unpublished commit was discarded: calls=%d state=%s",
			coopClient.discardCalls, coopClient.session.State)
	}
	if !slices.Equal(coopClient.discardAccepts, []bool{false}) {
		t.Fatalf("discard plan acceptance = %v", coopClient.discardAccepts)
	}
}

func TestOrphanReconciliationSchedulesOnlyResponderManagedSessions(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	now := time.Now().UTC()
	coopClient := newFakeCoop()
	coopClient.listSessions = []coop.Session{
		{
			ID: "ses_orphan", ExternalRef: "engineering-task:task_1",
			ForkName: "remote-orphan", State: "closed", UpdatedAt: now.Add(-time.Hour),
		},
		{
			ID: "ses_unrelated", ExternalRef: "catalog-roadmap",
			ForkName: "catalog-roadmap", State: "closed", UpdatedAt: now.Add(-time.Hour),
		},
		{
			ID: "ses_fresh", ExternalRef: "incident:inc_fresh",
			ForkName: "remote-fresh", State: "closed", UpdatedAt: now,
		},
	}
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	if err := svc.reconcileOrphanedResponderSessions(
		ctx, now.Add(-cfg.Retention.ClosedSessionGrace.Duration), now,
	); err != nil {
		t.Fatal(err)
	}
	item, err := st.NextCleanup(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	if item.SessionID != "ses_orphan" || item.Reason != "orphaned Responder session" {
		t.Fatalf("scheduled cleanup = %+v", item)
	}
	for _, sessionID := range []string{"ses_unrelated", "ses_fresh"} {
		known, err := st.ResponderSessionKnown(ctx, sessionID)
		if err != nil {
			t.Fatal(err)
		}
		if known {
			t.Fatalf("session %s was incorrectly claimed by Responder", sessionID)
		}
	}
}

func TestOperationsHomeDoesNotExposeWorkToNonOperators(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)

	if err := svc.publishOperationsHome(ctx, "U_NOT_OPERATOR"); err != nil {
		t.Fatal(err)
	}
	if len(slackClient.homes) != 1 {
		t.Fatalf("homes = %+v", slackClient.homes)
	}
	home := slackClient.homes[0].message
	rendered := strings.Join(home.Sections, "\n")
	if !strings.Contains(rendered, "dashboard access is restricted") ||
		strings.Contains(rendered, "Current work") {
		t.Fatalf("restricted home = %+v", home)
	}
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

type slackPost struct {
	outboxID  string
	channel   string
	thread    string
	broadcast bool
	message   slackui.Message
}

type slackUpdate struct {
	channel string
	ts      string
	message slackui.Message
}

type slackStatus struct {
	channel string
	thread  string
	text    string
}

type slackReaction struct {
	channel   string
	timestamp string
	name      string
}

type slackFileUpload struct {
	channel string
	thread  string
	upload  slackui.FileUpload
}

type slackHistoryRequest struct {
	channel string
	thread  string
	target  string
	since   string
	limit   int
}

type fakeSlack struct {
	posts              []slackPost
	ephemerals         []slackPost
	updates            []slackUpdate
	statuses           []slackStatus
	reactions          []slackReaction
	removedReactions   []slackReaction
	suggested          []slackStatus
	homes              []slackPost
	postErr            error
	ephemeralErr       error
	inviteErr          error
	inviteByChannel    map[string]error
	statusErr          error
	updateErr          error
	updateCall         int
	channel            slackui.Channel
	channelErr         error
	dedupePosts        bool
	createChannelCalls int
	history            []slackui.HistoryMessage
	historyErr         error
	historyRequests    []slackHistoryRequest
	channels           []slackui.Channel
	listChannelsErr    error
	files              map[string][]byte
	fileInfo           map[string]slackui.HistoryFile
	fileInfoRequests   []string
	fileInfoErr        error
	downloadErr        error
	downloads          []string
	uploads            []slackFileUpload
	uploadErr          error
}

type fakeSocket struct {
	events    chan socketmode.Event
	acks      int
	connected bool
}

func (f *fakeSocket) Events() <-chan socketmode.Event { return f.events }
func (f *fakeSocket) Ack(socketmode.Request) error {
	f.acks++
	return nil
}
func (f *fakeSocket) Run(context.Context) error { return nil }
func (f *fakeSocket) Connected() bool           { return f.connected }
func (f *fakeSocket) SetConnected(value bool)   { f.connected = value }

func (f *fakeSlack) Auth(context.Context) (slackui.Identity, error) {
	return slackui.Identity{TeamID: "T123ABC", BotUserID: "U999BOT"}, nil
}
func (f *fakeSlack) CreateChannel(_ context.Context, name string, _ bool, _ string) (slackui.Channel, error) {
	f.createChannelCalls++
	return slackui.Channel{ID: "CINCIDENT", Name: name, Creator: "U999BOT", Created: time.Now()}, nil
}
func (f *fakeSlack) FindChannelByName(context.Context, string, string) (slackui.Channel, error) {
	return slackui.Channel{}, slackui.ErrNotFound
}
func (f *fakeSlack) GetChannel(context.Context, string) (slackui.Channel, error) {
	if f.channelErr != nil {
		return slackui.Channel{}, f.channelErr
	}
	if f.channel.ID != "" {
		return f.channel, nil
	}
	return slackui.Channel{ID: "CWATCH", Name: "watch", Member: true}, nil
}
func (f *fakeSlack) ListChannels(context.Context, string) ([]slackui.Channel, error) {
	return slices.Clone(f.channels), f.listChannelsErr
}
func (f *fakeSlack) Invite(_ context.Context, channel string, _ ...string) error {
	if err := f.inviteByChannel[channel]; err != nil {
		return err
	}
	return f.inviteErr
}
func (f *fakeSlack) SetTopic(context.Context, string, string) error { return nil }
func (f *fakeSlack) Post(_ context.Context, outboxID, channel, thread string, message slackui.Message) (string, error) {
	f.posts = append(f.posts, slackPost{
		outboxID: outboxID, channel: channel, thread: thread, message: message,
	})
	return "1700.00" + string(rune('1'+len(f.posts)-1)), f.postErr
}
func (f *fakeSlack) PostBroadcast(
	_ context.Context,
	outboxID string,
	channel string,
	thread string,
	message slackui.Message,
) (string, error) {
	f.posts = append(f.posts, slackPost{
		outboxID:  outboxID,
		channel:   channel,
		thread:    thread,
		broadcast: true,
		message:   message,
	})
	return "1700.00" + string(rune('1'+len(f.posts)-1)), f.postErr
}
func (f *fakeSlack) PostEphemeral(_ context.Context, channel, user string, message slackui.Message) error {
	f.ephemerals = append(f.ephemerals, slackPost{
		channel: channel, thread: user, message: message,
	})
	return f.ephemeralErr
}
func (f *fakeSlack) Update(_ context.Context, channel, ts string, message slackui.Message) error {
	f.updateCall++
	f.updates = append(f.updates, slackUpdate{channel: channel, ts: ts, message: message})
	return f.updateErr
}
func (f *fakeSlack) Pin(context.Context, string, string) error { return nil }
func (f *fakeSlack) React(
	_ context.Context,
	channel string,
	timestamp string,
	reaction string,
) error {
	f.reactions = append(f.reactions, slackReaction{
		channel: channel, timestamp: timestamp, name: reaction,
	})
	return nil
}
func (f *fakeSlack) Unreact(
	_ context.Context,
	channel string,
	timestamp string,
	reaction string,
) error {
	f.removedReactions = append(f.removedReactions, slackReaction{
		channel: channel, timestamp: timestamp, name: reaction,
	})
	return nil
}
func (f *fakeSlack) SetStatus(_ context.Context, channel, thread, text string) error {
	f.statuses = append(f.statuses, slackStatus{channel: channel, thread: thread, text: text})
	return f.statusErr
}
func (f *fakeSlack) SetProgress(
	_ context.Context,
	channel string,
	thread string,
	text string,
	_ []string,
) error {
	return f.SetStatus(context.Background(), channel, thread, text)
}
func (f *fakeSlack) SetSuggestedPrompts(
	_ context.Context,
	channel string,
	thread string,
) error {
	f.suggested = append(f.suggested, slackStatus{channel: channel, thread: thread})
	return nil
}
func (f *fakeSlack) PublishHome(
	_ context.Context,
	user string,
	message slackui.Message,
) error {
	f.homes = append(f.homes, slackPost{thread: user, message: message})
	return nil
}
func (f *fakeSlack) UserAllowed(context.Context, string, string) (bool, error) {
	return true, nil
}
func (f *fakeSlack) UserGroupMembers(context.Context, string, string) ([]string, error) {
	return []string{"UOPERATOR"}, nil
}
func (f *fakeSlack) GetFile(_ context.Context, fileID string) (slackui.HistoryFile, error) {
	f.fileInfoRequests = append(f.fileInfoRequests, fileID)
	if f.fileInfoErr != nil {
		return slackui.HistoryFile{}, f.fileInfoErr
	}
	file, ok := f.fileInfo[fileID]
	if !ok {
		return slackui.HistoryFile{}, errors.New("missing fake Slack file info")
	}
	return file, nil
}
func (f *fakeSlack) DownloadFile(_ context.Context, fileURL string, writer io.Writer) error {
	f.downloads = append(f.downloads, fileURL)
	if f.downloadErr != nil {
		return f.downloadErr
	}
	data, ok := f.files[fileURL]
	if !ok {
		return errors.New("missing fake Slack file")
	}
	_, err := writer.Write(data)
	return err
}
func (f *fakeSlack) UploadFile(_ context.Context, channel, thread string, upload slackui.FileUpload) (string, error) {
	f.uploads = append(f.uploads, slackFileUpload{channel: channel, thread: thread, upload: upload})
	if f.uploadErr != nil {
		return "", f.uploadErr
	}
	return fmt.Sprintf("F%03d", len(f.uploads)), nil
}
func (f *fakeSlack) RecentMessages(
	_ context.Context,
	channel string,
	thread string,
	target string,
	since string,
	limit int,
) ([]slackui.HistoryMessage, error) {
	f.historyRequests = append(f.historyRequests, slackHistoryRequest{
		channel: channel, thread: thread, target: target, since: since, limit: limit,
	})
	return slices.Clone(f.history), f.historyErr
}
func (f *fakeSlack) FindDeliveryMessage(
	_ context.Context,
	channel string,
	thread string,
	outboxID string,
) (string, error) {
	if f.dedupePosts {
		for index, post := range f.posts {
			if post.outboxID == outboxID && post.channel == channel && post.thread == thread {
				return fmt.Sprintf("1700.%03d", index+1), nil
			}
		}
	}
	return "", slackui.ErrNotFound
}
func (f *fakeSlack) FindDeliveryFile(_ context.Context, channel, thread, filename string) (string, error) {
	for index, upload := range f.uploads {
		if upload.channel == channel && upload.thread == thread && upload.upload.Filename == filename {
			return fmt.Sprintf("F%03d", index+1), nil
		}
	}
	return "", slackui.ErrNotFound
}

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
repositories:
  repo:
    display_name: Repository
    coop_policy: repo-observe
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

func finishQueuedAgentRun(
	t *testing.T,
	ctx context.Context,
	svc *Service,
) {
	t.Helper()
	if err := svc.processAgentRun(ctx); err != nil && !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("process queued agent run: %v", err)
	}
	svc.pollAgentRuns(ctx)
	if err := svc.processAgentRunFinalization(ctx); err != nil &&
		!errors.Is(err, store.ErrNotFound) {
		t.Fatalf("finalize queued agent run: %v", err)
	}
	drainSlackDeliveries(t, ctx, svc)
}

func drainSlackDeliveries(
	t *testing.T,
	ctx context.Context,
	svc *Service,
) {
	t.Helper()
	for range 100 {
		err := svc.processSlackDelivery(ctx)
		if errors.Is(err, store.ErrNotFound) {
			return
		}
		if err != nil {
			t.Fatalf("deliver queued Slack work: %v", err)
		}
	}
	t.Fatal("Slack delivery queue did not drain")
}
