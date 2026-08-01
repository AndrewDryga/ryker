package service

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestMemoryOfferRequiresExplicitOperatorRequestAndStrictValue(t *testing.T) {
	cfg := serviceConfig(t)
	svc := &Service{cfg: cfg}
	input := core.SlackInput{
		ID: "slack_1", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		UserID: cfg.Slack.Operators[0],
		Text:   "Remember that old portal means the current portal service.",
	}
	offer := &core.MemoryOffer{
		Scope: "channel", Subject: "old portal", Predicate: "alias_of",
		Value: "service:portal", Visibility: "channel", ExpiresIn: "30d",
	}
	value, scope, expiry, ok := svc.prepareMemoryOfferAction(input, offer)
	if !ok || !strings.Contains(value, `"version":1`) ||
		scope != "channel" || expiry != "30 days" {
		t.Fatalf("offer = ok=%t scope=%q expiry=%q value=%q", ok, scope, expiry, value)
	}
	input.Text = "The portal looks healthy."
	if _, _, _, ok := svc.prepareMemoryOfferAction(input, offer); ok {
		t.Fatal("ambient statement produced a memory confirmation")
	}
	input.Text = "Remember this credential."
	offer.Value = "xoxb-secret-value"
	if _, _, _, ok := svc.prepareMemoryOfferAction(input, offer); ok {
		t.Fatal("credential-like value produced a memory confirmation")
	}
}

func TestGuidanceMemoryIsNormalizedAndAvailableAcrossChannels(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(
		cfg, st, newFakeCoop(), &fakeSlack{}, nil,
		slackui.NewSanitizer(12000), nil,
	)
	input := core.SlackInput{
		ID: "slack_guidance", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		UserID: cfg.Slack.Operators[0],
		Text:   "Remember that when you explain a fix to me, start with a simple summary.",
	}
	offer := &core.MemoryOffer{
		Scope: "workspace", Subject: "Fix explanation style", Predicate: "guidance",
		Value:      "When explaining a fix,\nstart with a simple summary before technical details.",
		Visibility: "operator", ExpiresIn: "90d",
		SourceRevision: "this-is-not-a-revision",
	}
	if _, scope, expiry, ok := svc.prepareMemoryOfferAction(input, offer); !ok ||
		scope != "workspace" || expiry != "90 days" {
		t.Fatalf("guidance offer = ok=%t scope=%q expiry=%q offer=%+v", ok, scope, expiry, offer)
	}
	if offer.Subject != "fix_explanation_style" ||
		offer.Value != "When explaining a fix, start with a simple summary before technical details." ||
		offer.SourceRevision != "" {
		t.Fatalf("normalized guidance = %+v", offer)
	}
	entry, _, err := svc.memoryEntryFromOffer(input, *offer, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := st.UpsertMemoryEntry(ctx, entry, 10, 5); err != nil {
		t.Fatal(err)
	}
	memory, err := svc.loadOperationalMemoryContext(
		ctx, "COTHER", "repo", input.UserID, "slack_next",
	)
	if err != nil {
		t.Fatal(err)
	}
	prompt := operationalMemoryPrompt(memory)
	for _, expected := range []string{
		`"predicate":"guidance"`, "start with a simple summary",
		"cannot initiate work by itself", "current request",
	} {
		if !strings.Contains(prompt, expected) {
			t.Fatalf("guidance prompt missing %q:\n%s", expected, prompt)
		}
	}
}

func TestGuidanceMemoryRejectsCredentialLikeValues(t *testing.T) {
	cfg := serviceConfig(t)
	svc := &Service{cfg: cfg}
	_, _, err := svc.memoryEntryFromOffer(core.SlackInput{
		ID: "slack_secret", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		UserID: cfg.Slack.Operators[0],
	}, core.MemoryOffer{
		Scope: "workspace", Subject: "authentication", Predicate: "guidance",
		Value: "Use xoxb-secret-value for requests", Visibility: "operator",
		ExpiresIn: "30d",
	}, time.Now().UTC())
	if err == nil || !strings.Contains(err.Error(), "credential-like") {
		t.Fatalf("credential guidance error = %v", err)
	}
}

func TestConfirmedMemoryActionPersistsAndForgetDeletes(t *testing.T) {
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
	payload, err := json.Marshal(memoryActionPayload{
		Version: 1, ChannelID: "COPS", SourceRef: "event_source", IssuedAt: time.Now().UTC(),
		Offer: core.MemoryOffer{
			Scope: "channel", Subject: "old portal", Predicate: "alias_of",
			Value: "service:portal", Visibility: "channel", ExpiresIn: "30d",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	remember := core.SlackInput{
		ID: "slack_remember", EnvelopeID: "env_remember", EventID: "event_remember",
		Kind: "action", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.001", UserID: cfg.Slack.Operators[0],
		ActionID: slackui.ActionRememberMemory, ActionValue: string(payload),
	}
	if created, err := st.AdmitSlackInput(ctx, remember); err != nil || !created {
		t.Fatalf("admit remember = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	entries, err := st.ListMemoryForContext(
		ctx, cfg.Slack.TeamID, "COPS", "repo", cfg.Slack.Operators[0], 10,
	)
	if err != nil || len(entries) != 1 || entries[0].Value != "service:portal" {
		t.Fatalf("saved entries = %+v, %v", entries, err)
	}
	if len(slackClient.posts) != 1 ||
		slackClient.posts[0].message.Header != "Saved operational memory" {
		t.Fatalf("memory receipt = %+v", slackClient.posts)
	}
	rememberedInput, err := st.GetSlackInput(ctx, remember.ID)
	if err != nil || len(rememberedInput.Frozen) == 0 {
		t.Fatalf("remember action result was not frozen for retry: %+v, %v", rememberedInput, err)
	}
	forget := core.SlackInput{
		ID: "slack_forget", EnvelopeID: "env_forget", EventID: "event_forget",
		Kind: "action", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.002", UserID: cfg.Slack.Operators[0],
		ActionID: slackui.ActionForgetMemory, ActionValue: entries[0].ID,
	}
	if created, err := st.AdmitSlackInput(ctx, forget); err != nil || !created {
		t.Fatalf("admit forget = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := st.GetMemoryEntry(ctx, entries[0].ID); err != store.ErrNotFound {
		t.Fatalf("forgotten entry error = %v", err)
	}
	if len(slackClient.ephemerals) != 1 ||
		slackClient.ephemerals[0].message.Header != "Operational memory forgotten" {
		t.Fatalf("forget receipt = %+v", slackClient.ephemerals)
	}
}

func TestOperationalMemoryPromptDeclaresPrecedence(t *testing.T) {
	prompt := operationalMemoryPrompt(operationalMemoryContext{
		ConfirmedMemory: []memoryPromptEntry{{
			Scope: "channel:COPS", Subject: "old portal", Predicate: "alias_of",
			Value: "service:portal", ExpiresAt: time.Now().Add(time.Hour).Format(time.RFC3339),
		}},
		RecentEvidence: []evidencePromptEntry{{
			ID: "ev_1", Claim: "portal was healthy", Observation: "HTTP 200",
			SourceType: "emisar", SourceName: "health check",
		}},
	})
	for _, expected := range []string{
		"hints, not", "Fresh live evidence takes precedence",
		"untrusted-prior-operational-context", `"old portal"`, `"portal was healthy"`,
	} {
		if !strings.Contains(prompt, expected) {
			t.Fatalf("prompt missing %q:\n%s", expected, prompt)
		}
	}
}
