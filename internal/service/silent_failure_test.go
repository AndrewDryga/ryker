package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/slack-go/slack/slackevents"
	"github.com/slack-go/slack/socketmode"
)

// capturingLogger returns a logger and the buffer it writes to, so a test can
// assert that a failure was reported rather than only that it happened.
func capturingLogger() (*slog.Logger, *bytes.Buffer) {
	buffer := &bytes.Buffer{}
	return slog.New(slog.NewTextHandler(buffer, &slog.HandlerOptions{Level: slog.LevelDebug})), buffer
}

// The App Home messages tab carries no thread, and that is the contract.
//
// Slack's agent messaging experience pins suggested prompts to the top of the
// Messages tab and sets them from app_home_opened with no thread_ts; the
// per-thread form belongs to the older assistant experience and arrives with
// assistant_thread_started. Both shapes are pinned here together because the
// empty thread looks like an omission next to the branch that fills one in,
// and "fixing" it by addressing a thread that does not exist would break the
// surface rather than repair it.
func TestSuggestedPromptsUseTheThreadOnlyWhenSlackProvidesOne(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	socket := &fakeSocket{events: make(chan socketmode.Event)}
	svc := New(cfg, st, newFakeCoop(), slackClient, socket, slackui.NewSanitizer(12000), nil)

	for _, event := range []struct {
		name       string
		envelope   string
		data       slackevents.EventsAPIInnerEvent
		wantThread string
	}{
		{
			name:     "agent messages tab",
			envelope: "env-messages",
			data: slackevents.EventsAPIInnerEvent{Data: &slackevents.AppHomeOpenedEvent{
				User: "U123ABC", Channel: "D123ABC", Tab: "messages",
			}},
			wantThread: "",
		},
		{
			name:     "assistant thread",
			envelope: "env-assistant",
			data: slackevents.EventsAPIInnerEvent{Data: &slackevents.AssistantThreadStartedEvent{
				AssistantThread: slackevents.AssistantThread{
					UserID: "U123ABC", ChannelID: "D123ABC", ThreadTimeStamp: "1700.902",
				},
			}},
			wantThread: "1700.902",
		},
	} {
		payload, _ := json.Marshal(map[string]any{"event_id": event.envelope})
		svc.admitEventsAPI(ctx, socketmode.Event{
			Type: socketmode.EventTypeEventsAPI,
			Data: slackevents.EventsAPIEvent{
				TeamID: cfg.Slack.TeamID, InnerEvent: event.data,
			},
			Request: &socketmode.Request{EnvelopeID: event.envelope, Payload: payload},
		})
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatalf("%s: %v", event.name, err)
		}
		last := slackClient.suggested[len(slackClient.suggested)-1]
		if last.channel != "D123ABC" || last.thread != event.wantThread {
			t.Fatalf("%s prompts = %+v, want thread %q", event.name, last, event.wantThread)
		}
	}
}

// A surface repaint that Slack keeps rejecting must stop, and must say so.
//
// This is the shape of the defect that went unnoticed for months: every App
// Home open queued a suggested-prompts refresh, Slack answered internal_error,
// and the input was retried to the full twelve-attempt budget reserved for work
// an operator actually asked for. Nothing was logged, nothing was audited, and
// the only trace was a failed row in a table nobody reads. Not one refresh has
// ever succeeded on either deployment, and nothing said so.
func TestFailingSurfaceRefreshGivesUpEarlyAndIsReported(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	logger, logged := capturingLogger()
	slackClient := &fakeSlack{suggestedErr: errors.New("internal_error")}
	svc := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), logger)
	// The queue backs off between attempts, so the clock has to move for the
	// next one to come due. Both the service and the store read it.
	clock := time.Now().UTC()
	svc.SetClock(func() time.Time { return clock })
	st.SetClock(func() time.Time { return clock })

	input := core.SlackInput{
		ID: "slack_prompts", EnvelopeID: "env-prompts", EventID: "ev-prompts",
		Kind: inputSuggestedPrompts, TeamID: cfg.Slack.TeamID,
		ChannelID: "D123ABC", UserID: "U123ABC", ReceivedAt: clock,
	}
	if _, err := st.AdmitSlackInput(ctx, input); err != nil {
		t.Fatal(err)
	}
	for range cfg.Limits.MaxSlackInputAttempts {
		stored, err := st.GetSlackInput(ctx, input.ID)
		if err != nil {
			t.Fatal(err)
		}
		if stored.State == "failed" {
			break
		}
		if err := svc.processSlackInput(ctx); err != nil {
			t.Fatal(err)
		}
		clock = clock.Add(10 * time.Minute)
	}

	if len(slackClient.suggested) != surfaceRefreshAttempts {
		t.Fatalf(
			"Slack calls before giving up = %d, want %d",
			len(slackClient.suggested), surfaceRefreshAttempts,
		)
	}
	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != "failed" {
		t.Fatalf("state after the budget = %q, want failed", stored.State)
	}
	if !strings.Contains(logged.String(), "Slack input attempt failed") ||
		!strings.Contains(logged.String(), "internal_error") ||
		!strings.Contains(logged.String(), "gave_up=true") {
		t.Fatalf("a surface refresh failed without saying so; log = %s", logged)
	}
}

// Slack has already answered these; asking again eleven more times cannot
// change the answer, and the eleven extra rejections are the only thing the
// budget buys.
func TestPermanentSlackErrorIsNotRetried(t *testing.T) {
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	logger, logged := capturingLogger()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), logger)

	input := core.SlackInput{
		ID: "slack_permanent", EnvelopeID: "env-permanent", EventID: "ev-permanent",
		Kind: "action", TeamID: cfg.Slack.TeamID, UserID: "U123ABC",
		ReceivedAt: svc.now().UTC(),
	}
	if _, err := st.AdmitSlackInput(ctx, input); err != nil {
		t.Fatal(err)
	}
	// Only a leased input can be failed, which is the state it is in when a
	// handler reports an error.
	leased, err := st.LeaseSlackInput(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.retrySlackInput(ctx, leased, errors.New("channel_not_found")); err != nil {
		t.Fatal(err)
	}

	stored, err := st.GetSlackInput(ctx, input.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != "failed" {
		t.Fatalf("state after a permanent Slack error = %q, want failed on the first attempt", stored.State)
	}
	if !strings.Contains(logged.String(), "channel_not_found") {
		t.Fatalf("a permanent Slack failure was not reported; log = %s", logged)
	}
}
