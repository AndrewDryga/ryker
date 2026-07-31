package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

func TestConfigurationSetupAcceptsFormattedCancelCommand(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{
		channel: slackui.Channel{ID: "CNEW", Name: "new-operations", Member: true},
	}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	session, err := st.CreateConfigurationSession(ctx, core.ConfigurationSession{
		TeamID: cfg.Slack.TeamID, ChannelID: "CNEW", Initiator: "U123ABC",
		Step: "audience", Status: "asking",
		Draft: core.ChannelConfiguration{
			ChannelID: "CNEW", Participation: "mentions",
			Repository: cfg.Slack.DefaultRepository, AlertPolicy: "reply",
		},
		ExpiresAt: time.Now().UTC().Add(time.Minute),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindConfigurationThread(ctx, session.ID, "1700.1"); err != nil {
		t.Fatal(err)
	}

	input := core.SlackInput{
		ID: "cancel-formatted", EnvelopeID: "cancel-formatted-envelope",
		EventID: "cancel-formatted-event", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CNEW", ThreadTS: "1700.1", MessageTS: "1700.2",
		UserID: "U123ABC", Text: "`cancel setup`",
	}
	if _, err := st.AdmitSlackInput(ctx, input); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatalf("formatted cancel = %v", err)
	}
	if _, err := st.GetActiveConfigurationSession(ctx, "CNEW"); err != store.ErrNotFound {
		t.Fatalf("active setup after cancellation = %v", err)
	}
	if len(slack.posts) != 1 ||
		slack.posts[0].message.Header != "Channel setup cancelled" {
		t.Fatalf("cancellation message = %+v", slack.posts)
	}
}

func TestExpiredConfigurationReplyRenewsInPlaceAndAppliesAnswer(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{
		channel: slackui.Channel{ID: "CNEW", Name: "infra-alerts", Member: true},
	}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	expired, err := st.CreateConfigurationSession(ctx, core.ConfigurationSession{
		TeamID: cfg.Slack.TeamID, ChannelID: "CNEW", Initiator: "U123ABC",
		Step: "participation", Status: "asking",
		Draft: core.ChannelConfiguration{
			ChannelID: "CNEW", Participation: "mentions",
			Repository: cfg.Slack.DefaultRepository, AlertPolicy: "reply",
		},
		ExpiresAt: time.Now().UTC().Add(-time.Minute),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindConfigurationThread(ctx, expired.ID, "1700.1"); err != nil {
		t.Fatal(err)
	}
	expired, err = st.GetActiveConfigurationSession(ctx, "CNEW")
	if err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "renew-expired", EnvelopeID: "renew-expired-envelope",
		EventID: "renew-expired-event", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CNEW", ThreadTS: "1700.1", MessageTS: "1700.2",
		UserID: "U123ABC", Text: "proactive",
	}
	if admitted, err := svc.shouldAdmitConfigurationMessage(ctx, input); err != nil || !admitted {
		t.Fatalf("expired setup reply admission = %v, %v", admitted, err)
	}
	if _, err := st.AdmitSlackInput(ctx, input); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	renewed, err := st.GetActiveConfigurationSession(ctx, "CNEW")
	if err != nil {
		t.Fatal(err)
	}
	if renewed.ID == expired.ID || renewed.Step != "repository" ||
		renewed.Draft.Participation != "proactive" ||
		!renewed.ExpiresAt.After(time.Now().UTC()) {
		t.Fatalf("renewed setup = %+v, expired = %+v", renewed, expired)
	}
	old, err := st.GetConfigurationSession(ctx, expired.ID)
	if err != nil || old.Status != "expired" {
		t.Fatalf("old setup = %+v, err=%v", old, err)
	}
	if len(slack.posts) != 1 || slack.posts[0].thread != "1700.1" ||
		slack.posts[0].message.Header != "Configure Emisar for #infra-alerts" ||
		len(slack.posts[0].message.Context) == 0 ||
		!strings.Contains(slack.posts[0].message.Context[0], "renewed") {
		t.Fatalf("renewed setup response = %+v", slack.posts)
	}
	if _, err := st.GetChannelConfiguration(ctx, "CNEW"); err != store.ErrNotFound {
		t.Fatalf("renewal saved channel configuration: %v", err)
	}
}

func TestExpiredConfigurationReplyOutsideSetupConversationIsNotAdmitted(t *testing.T) {
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
	expired, err := st.CreateConfigurationSession(ctx, core.ConfigurationSession{
		TeamID: cfg.Slack.TeamID, ChannelID: "CNEW", Initiator: "U123ABC",
		Step: "participation", Status: "asking",
		Draft: core.ChannelConfiguration{
			ChannelID: "CNEW", Participation: "mentions",
			Repository: cfg.Slack.DefaultRepository, AlertPolicy: "reply",
		},
		ExpiresAt: time.Now().UTC().Add(-time.Minute),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindConfigurationThread(ctx, expired.ID, "1700.1"); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CNEW",
		ThreadTS: "unrelated-thread", MessageTS: "1700.2",
		UserID: "U123ABC", Text: "proactive",
	}
	if admitted, err := svc.shouldAdmitConfigurationMessage(ctx, input); err != nil || admitted {
		t.Fatalf("unrelated expired setup reply admission = %v, %v", admitted, err)
	}
	active, err := st.GetActiveConfigurationSession(ctx, "CNEW")
	if err != nil || active.ID != expired.ID {
		t.Fatalf("unrelated reply changed setup = %+v, err=%v", active, err)
	}
}

func TestPersistedExpiredConfigurationDoesNotCaptureChannelMessages(t *testing.T) {
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
	expired, err := st.CreateConfigurationSession(ctx, core.ConfigurationSession{
		TeamID: cfg.Slack.TeamID, ChannelID: "CNEW", Initiator: "U123ABC",
		Step: "participation", Status: "asking",
		Draft: core.ChannelConfiguration{
			ChannelID: "CNEW", Participation: "mentions",
			Repository: cfg.Slack.DefaultRepository, AlertPolicy: "reply",
		},
		ExpiresAt: time.Now().UTC().Add(-time.Minute),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindConfigurationThread(ctx, expired.ID, "1700.1"); err != nil {
		t.Fatal(err)
	}
	expired, err = st.GetActiveConfigurationSession(ctx, "CNEW")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishConfigurationSession(
		ctx, expired.ID, expired.Revision, "expired",
	); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "CNEW",
		MessageTS: "1700.2", UserID: "U123ABC", Text: "proactive",
	}
	if admitted, err := svc.shouldAdmitConfigurationMessage(ctx, input); err != nil || admitted {
		t.Fatalf("channel message admission = %v, %v", admitted, err)
	}
}

func TestPersistedExpiredConfigurationReplyRenewsOriginalConversation(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slack := &fakeSlack{
		channel: slackui.Channel{ID: "CNEW", Name: "infra-alerts", Member: true},
	}
	svc := New(cfg, st, newFakeCoop(), slack, nil, slackui.NewSanitizer(12000), nil)
	expired, err := st.CreateConfigurationSession(ctx, core.ConfigurationSession{
		TeamID: cfg.Slack.TeamID, ChannelID: "CNEW", Initiator: "U123ABC",
		Step: "participation", Status: "asking",
		Draft: core.ChannelConfiguration{
			ChannelID: "CNEW", Participation: "mentions",
			Repository: cfg.Slack.DefaultRepository, AlertPolicy: "reply",
		},
		ExpiresAt: time.Now().UTC().Add(-time.Minute),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.BindConfigurationThread(ctx, expired.ID, "1700.1"); err != nil {
		t.Fatal(err)
	}
	expired, err = st.GetActiveConfigurationSession(ctx, "CNEW")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.FinishConfigurationSession(
		ctx, expired.ID, expired.Revision, "expired",
	); err != nil {
		t.Fatal(err)
	}
	input := core.SlackInput{
		ID: "renew-persisted-expired", EnvelopeID: "renew-persisted-expired-envelope",
		EventID: "renew-persisted-expired-event", Kind: "message", TeamID: cfg.Slack.TeamID,
		ChannelID: "CNEW", ThreadTS: "1700.1", MessageTS: "1700.2",
		UserID: "U123ABC", Text: "proactive",
	}
	if admitted, err := svc.shouldAdmitChannelMessage(ctx, input); err != nil || !admitted {
		t.Fatalf("persisted expired setup reply admission = %v, %v", admitted, err)
	}
	if _, err := st.AdmitSlackInput(ctx, input); err != nil {
		t.Fatal(err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	renewed, err := st.GetActiveConfigurationSession(ctx, "CNEW")
	if err != nil {
		t.Fatal(err)
	}
	if renewed.ID == expired.ID || renewed.Step != "repository" ||
		renewed.Draft.Participation != "proactive" {
		t.Fatalf("renewed setup = %+v, expired = %+v", renewed, expired)
	}
	if len(slack.posts) != 1 || slack.posts[0].thread != "1700.1" ||
		len(slack.posts[0].message.Context) == 0 ||
		!strings.Contains(slack.posts[0].message.Context[0], "renewed") {
		t.Fatalf("renewed setup response = %+v", slack.posts)
	}
}

func TestConfigurationAudienceUsesCurrentChoices(t *testing.T) {
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

	users, groups, err := svc.resolveConfigurationAudience(
		context.Background(), "U123ABC", "no additional invitees",
	)
	if err != nil || len(users) != 0 || len(groups) != 0 {
		t.Fatalf("empty audience = %v, %v, %v", users, groups, err)
	}
	_, _, err = svc.resolveConfigurationAudience(
		context.Background(), "U123ABC", "cancel this nonsense",
	)
	if err == nil || !strings.Contains(err.Error(), "no additional invitees") ||
		strings.Contains(err.Error(), "include me") {
		t.Fatalf("audience guidance = %v", err)
	}
}
