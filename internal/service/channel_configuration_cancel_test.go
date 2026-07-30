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
