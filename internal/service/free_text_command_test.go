package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// Free text is never a command.
//
// A keyword table read every plain channel message an operator sent and
// rewrote the ones containing a settings word into a slash subcommand. "shadow
// traffic is on the new cluster, ignore it" turned the channel silent, "the
// proactive alert on api is noise" turned proactive triage on, "we should
// enable shadow deploys next week" turned it silent again, "hey bob what are
// you working on?" posted the commitment card at the room, and a bare "close"
// tried to end whatever was attached to the channel. Nobody addressed
// Responder in any of them.
//
// It never fired in production only because the single operator knew which
// phrases to avoid, which is not a property of the code. A second operator
// makes it a matter of time, and the worst of these fails silently in the
// direction nobody checks: a channel that has stopped answering, with no
// message saying so.
func TestOperatorSentenceMentioningShadowDoesNotFlipShadowMode(t *testing.T) {
	for _, sentence := range []string{
		"shadow traffic is on the new cluster, ignore it",
		"the proactive alert on api is noise",
		"we should enable shadow deploys next week",
		"hey bob what are you working on?",
		"close",
	} {
		t.Run(sentence, func(t *testing.T) {
			ctx := context.Background()
			cfg := serviceConfig(t)
			st, err := store.Open(cfg.StateDir)
			if err != nil {
				t.Fatal(err)
			}
			defer st.Close()
			slackClient := &fakeSlack{channel: slackui.Channel{
				ID: "COPS", Name: "backend-ops", Member: true,
			}}
			svc := New(
				cfg, st, newFakeCoop(), slackClient, nil,
				slackui.NewSanitizer(12000), nil,
			)
			svc.identity = slackui.Identity{
				TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT",
			}

			input := core.SlackInput{
				ID: "free-text", EnvelopeID: "env-free-text",
				EventID: "event-free-text", Kind: "message",
				TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
				MessageTS: "1700.1", UserID: "U123ABC", Text: sentence,
				ReceivedAt: time.Now().UTC(),
			}
			if admitted, err := st.AdmitSlackInput(ctx, input); err != nil || !admitted {
				t.Fatalf("admit sentence = %t, %v", admitted, err)
			}
			if err := svc.processSlackInput(ctx); err != nil {
				t.Fatal(err)
			}
			drainSlackDeliveries(t, ctx, svc)

			for _, setting := range []string{"shadow", "proactive"} {
				stored, err := st.GetSlackSetting(ctx, "channel", "COPS", setting)
				if !errors.Is(err, store.ErrNotFound) {
					t.Fatalf(
						"an unaddressed sentence set %s=%q in this channel (err %v)",
						setting, stored.Value, err,
					)
				}
			}
			if len(slackClient.posts) != 0 || len(slackClient.ephemerals) != 0 {
				t.Fatalf(
					"an unaddressed sentence was answered as a command: "+
						"posts=%+v ephemerals=%+v",
					slackClient.posts, slackClient.ephemerals,
				)
			}
		})
	}
}

// The one sentence still read from free text carries the same guard.
//
// Asking to set a channel up survives in text because it has to work when the
// model is unavailable, which is exactly when somebody needs it. That makes it
// the obvious place for the deleted keyword table to grow back, so the words
// alone are not enough: an operator can plan a reconfiguration out loud to a
// colleague, and a settings wizard must not open on top of that conversation.
func TestOnlyAnAddressedRequestOpensTheChannelSetupWizard(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{channel: slackui.Channel{
		ID: "COPS", Name: "backend-ops", Member: true,
	}}
	svc := New(
		cfg, st, newFakeCoop(), slackClient, nil,
		slackui.NewSanitizer(12000), nil,
	)
	svc.identity = slackui.Identity{TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT"}

	overheard := core.SlackInput{
		ID: "overheard", EnvelopeID: "env-overheard", EventID: "event-overheard",
		Kind: "message", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.1", UserID: "U123ABC",
		Text:       "we should set up this channel differently next sprint",
		ReceivedAt: time.Now().UTC(),
	}
	if admitted, err := st.AdmitSlackInput(ctx, overheard); err != nil || !admitted {
		t.Fatalf("admit overheard sentence = %t, %v", admitted, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if session, err := st.GetActiveConfigurationSession(ctx, "COPS"); err == nil {
		t.Fatalf("an overheard sentence opened the setup wizard: %+v", session)
	} else if !errors.Is(err, store.ErrNotFound) {
		t.Fatal(err)
	}

	asked := core.SlackInput{
		ID: "asked", EnvelopeID: "env-asked", EventID: "event-asked",
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.2", UserID: "U123ABC",
		Text:       "<@U999BOT> please set up this channel",
		ReceivedAt: time.Now().UTC(),
	}
	if admitted, err := st.AdmitSlackInput(ctx, asked); err != nil || !admitted {
		t.Fatalf("admit request = %t, %v", admitted, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	drainSlackDeliveries(t, ctx, svc)
	if _, err := st.GetActiveConfigurationSession(ctx, "COPS"); err != nil {
		t.Fatalf("an addressed request did not open the setup wizard: %v", err)
	}
}
