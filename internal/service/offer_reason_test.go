package service

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
	decisionpkg "github.com/AndrewDryga/ryker/internal/decision"
	"github.com/AndrewDryga/ryker/internal/slackui"
	"github.com/AndrewDryga/ryker/internal/store"
)

// discardLog returns a service whose warnings are captured, so a test can read
// what the host recorded when it refused an offer instead of guessing.
func discardLog(t *testing.T) (*Service, *bytes.Buffer) {
	t.Helper()
	logs := &bytes.Buffer{}
	return &Service{
		cfg: serviceConfig(t),
		log: slog.New(slog.NewTextHandler(
			logs, &slog.HandlerOptions{Level: slog.LevelWarn},
		)),
	}, logs
}

// Found in the 2026-08-16 audit: the host knew exactly which field failed and
// told nobody. A preference whose name is not one of the three the host
// supports was dropped with a one-line warning, the reply went out, and the
// model — never told which field or which value was refused — proposed the same
// invented preference name the next time it was asked.
//
// Both halves are asserted here. The correction is what the model reads, so it
// has to carry the field, the value it sent, and the accepted set; the discard
// record is what an operator reads afterwards, and "discard invalid preference
// offer" told them nothing about which offer or why.
func TestADiscardedPreferenceOfferTellsTheModelWhichFieldWasWrong(t *testing.T) {
	s, logs := discardLog(t)
	input := core.SlackInput{
		ID: "slack_pref_reason", EventID: "EvPrefReason",
		TeamID: s.cfg.Slack.TeamID, ChannelID: "COPS",
		UserID: s.cfg.Slack.Operators[0],
		Text:   "From now on always keep your answers short.",
	}
	// An invented preference name is the common shape: the request is real, the
	// vocabulary is not.
	offer := &core.PreferenceOffer{
		Scope: "operator", Name: "verbosity", Value: "short", ExpiresIn: "90d",
	}

	correction := s.offerRejectionCorrection(
		context.Background(), input,
		decisionpkg.WatchDecision{PreferenceOffer: offer},
	)
	for _, want := range []string{"preference", "name", "verbosity", "response_detail"} {
		if !strings.Contains(correction, want) {
			t.Fatalf("the preference correction never named %q: %q", want, correction)
		}
	}

	if _, _, _, ok := s.preparePreferenceOfferAction(input, offer); ok {
		t.Fatal("an invalid preference offer was turned into a confirmation button")
	}
	for _, want := range []string{"preference", "name", "verbosity", "response_detail"} {
		if !strings.Contains(logs.String(), want) {
			t.Fatalf("the discard record never named %q: %q", want, logs.String())
		}
	}
}

// Found in the 2026-08-16 audit: the host knew exactly which field failed and
// told nobody. The offer below is harvested from the blitz deployment — a real
// answer that asked for a permanent workspace memory whose predicate is a whole
// sentence rather than `guidance`, which is the one predicate permanence is
// allowed for.
func TestADiscardedMemoryOfferTellsTheModelWhichFieldWasWrong(t *testing.T) {
	s, logs := discardLog(t)
	input := core.SlackInput{
		ID: "slack_memory_reason", EventID: "EvMemoryReason",
		TeamID: s.cfg.Slack.TeamID, ChannelID: "COPS",
		UserID: s.cfg.Slack.Operators[0],
		Text: "Remember that when you report an operational run you should " +
			"always include a direct link.",
	}
	offer := &core.MemoryOffer{
		Scope:   "workspace",
		Subject: "Operational run links",
		Predicate: "When reporting an operational run or external object created " +
			"or inspected by Emisar",
		Value: "Include a clickable direct link alongside the identifier instead " +
			"of presenting only a bare ID.",
		Visibility: "operator",
		ExpiresIn:  "never",
	}

	correction := s.offerRejectionCorrection(
		context.Background(), input,
		decisionpkg.WatchDecision{MemoryOffer: offer},
	)
	for _, want := range []string{"memory", "expires_in", "never", "guidance"} {
		if !strings.Contains(correction, want) {
			t.Fatalf("the memory correction never named %q: %q", want, correction)
		}
	}

	if _, _, _, _, ok := s.prepareMemoryOfferAction(input, offer); ok {
		t.Fatal("an invalid memory offer was turned into a confirmation button")
	}
	for _, want := range []string{"memory", "expires_in", "never"} {
		if !strings.Contains(logs.String(), want) {
			t.Fatalf("the discard record never named %q: %q", want, logs.String())
		}
	}
}

// Found in the 2026-08-16 audit: the host knew exactly which field failed and
// told nobody. The schedule below is harvested from the blitz deployment, whose
// daily health review names a repository this host does not have; the model has
// no way to learn which repositories exist unless the refusal lists them.
func TestADiscardedScheduleOfferTellsTheModelWhichFieldWasWrong(t *testing.T) {
	s, logs := discardLog(t)
	input := core.SlackInput{
		ID: "slack_schedule_reason", EventID: "EvScheduleReason",
		TeamID: s.cfg.Slack.TeamID, ChannelID: "COPS",
		UserID: s.cfg.Slack.Operators[0],
		Text:   "Schedule the daily platform health review here every morning at 9.",
	}
	offer := &core.ScheduleOffer{
		Title:      "Daily Blitz production health report",
		Prompt:     "Produce the daily comprehensive production health report in this channel.",
		Repository: "blitz-infra",
		Recurrence: "daily",
		LocalTime:  "09:00",
		Timezone:   "America/Chicago",
		CatchUp:    "latest",
		ExpiresIn:  "365d",
	}

	correction := s.offerRejectionCorrection(
		context.Background(), input,
		decisionpkg.WatchDecision{ScheduleOffer: offer},
	)
	// "not configured" was the whole of it, and the deployment's own
	// repositories are the one thing the model cannot read off the
	// conversation, so the list is what makes the refusal repairable.
	for _, want := range []string{"repository", "blitz-infra", "configured repositories are repo"} {
		if !strings.Contains(correction, want) {
			t.Fatalf("the schedule correction never named %q: %q", want, correction)
		}
	}

	if _, _, ok := s.normalizeScheduleOffer(context.Background(), input, offer); ok {
		t.Fatal("an invalid schedule offer was turned into a proposal")
	}
	for _, want := range []string{"schedule", "blitz-infra", "configured repositories are repo"} {
		if !strings.Contains(logs.String(), want) {
			t.Fatalf("the discard record never named %q: %q", want, logs.String())
		}
	}
}

// staleConfirmation drives one confirmation click through the interaction path
// that answers it and returns what the operator was told.
func staleConfirmation(t *testing.T, input core.SlackInput) string {
	t.Helper()
	ctx := context.Background()
	cfg := serviceConfig(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	slackClient := &fakeSlack{}
	s := New(cfg, st, newFakeCoop(), slackClient, nil, slackui.NewSanitizer(12000), nil)
	s.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	if created, err := st.AdmitSlackInput(ctx, input); err != nil || !created {
		t.Fatalf("admit confirmation click = %t, %v", created, err)
	}
	if err := s.processSlackInput(ctx); err != nil {
		t.Fatalf("answer confirmation click: %v", err)
	}
	if len(slackClient.ephemerals) != 1 {
		t.Fatalf("the operator was answered %d times: %+v",
			len(slackClient.ephemerals), slackClient.ephemerals)
	}
	return renderedSlackMessage(slackClient.ephemerals[0].message)
}

// Found in the 2026-08-16 audit: the host knew exactly which field failed and
// told nobody. Every refusal below was one sentence — "This preference
// confirmation is invalid or stale." — for four different situations the host
// can tell apart. An operator who clicks a day-old button and one who clicks a
// button belonging to another channel need different next steps, and both were
// given the same one.
func TestAStalePreferenceConfirmationSaysWhyItIsStale(t *testing.T) {
	cfg := serviceConfig(t)
	now := time.Now().UTC()
	click := func(payload string) core.SlackInput {
		return core.SlackInput{
			ID: "slack_pref_stale", EnvelopeID: "env_pref_stale",
			EventID: "EvPrefStale", Kind: "action", TeamID: cfg.Slack.TeamID,
			ChannelID: "COPS", MessageTS: "1700.900", UserID: cfg.Slack.Operators[0],
			ActionID: slackui.ActionRememberPreference, ActionValue: payload,
		}
	}
	for _, tc := range []struct {
		name    string
		payload string
		want    []string
	}{
		{
			name:    "a button Ryker cannot read",
			payload: `{"version":1,"channel_id":"COPS","source_ref":"Ev1","not_a_field":true}`,
			want:    []string{"preference", "could not read"},
		},
		{
			name: "a button from another channel",
			payload: `{"version":1,"channel_id":"CELSEWHERE","source_ref":"Ev1","issued_at":"` +
				now.Format(time.RFC3339) + `","offer":{}}`,
			want: []string{"preference", "another channel"},
		},
		{
			name: "a button older than a day",
			payload: `{"version":1,"channel_id":"COPS","source_ref":"Ev1","issued_at":"` +
				now.Add(-30*time.Hour).Format(time.RFC3339) + `","offer":{}}`,
			want: []string{"preference", "expired"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			answer := staleConfirmation(t, click(tc.payload))
			for _, want := range tc.want {
				if !strings.Contains(strings.ToLower(answer), want) {
					t.Fatalf("the notice never said %q: %q", want, answer)
				}
			}
			if strings.Contains(answer, "invalid or stale") {
				t.Fatalf("the notice still refuses to say which of the two: %q", answer)
			}
		})
	}
}

// Found in the 2026-08-16 audit: the host knew exactly which field failed and
// told nobody. Same defect, one door down: a memory button says only that it is
// "invalid or stale", and the person clicking it cannot tell an expiry from a
// button that belongs somewhere else.
func TestAStaleMemoryConfirmationSaysWhyItIsStale(t *testing.T) {
	cfg := serviceConfig(t)
	now := time.Now().UTC()
	click := func(payload string) core.SlackInput {
		return core.SlackInput{
			ID: "slack_memory_stale", EnvelopeID: "env_memory_stale",
			EventID: "EvMemoryStale", Kind: "action", TeamID: cfg.Slack.TeamID,
			ChannelID: "COPS", MessageTS: "1700.910", UserID: cfg.Slack.Operators[0],
			ActionID: slackui.ActionRememberMemory, ActionValue: payload,
		}
	}
	for _, tc := range []struct {
		name    string
		payload string
		want    []string
	}{
		{
			name: "a button older than a day",
			payload: `{"version":1,"channel_id":"COPS","source_ref":"Ev1","issued_at":"` +
				now.Add(-48*time.Hour).Format(time.RFC3339) + `","offer":{}}`,
			want: []string{"memory", "expired"},
		},
		{
			name: "a button from another channel",
			payload: `{"version":1,"channel_id":"CELSEWHERE","source_ref":"Ev1","issued_at":"` +
				now.Format(time.RFC3339) + `","offer":{}}`,
			want: []string{"memory", "another channel"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			answer := staleConfirmation(t, click(tc.payload))
			for _, want := range tc.want {
				if !strings.Contains(strings.ToLower(answer), want) {
					t.Fatalf("the notice never said %q: %q", want, answer)
				}
			}
			if strings.Contains(answer, "invalid or stale") {
				t.Fatalf("the notice still refuses to say which of the two: %q", answer)
			}
		})
	}
}

// Found in the 2026-08-16 audit: the host knew exactly which field failed and
// told nobody. The schedule button carries proposal ids rather than the offer,
// so its two refusals are "Emisar cannot read this" and "these proposals are
// gone" — and both arrived as the same "invalid or stale" sentence, or as a
// raw store error pasted into Slack.
func TestAStaleScheduleConfirmationSaysWhyItIsStale(t *testing.T) {
	cfg := serviceConfig(t)
	click := func(id, payload string) core.SlackInput {
		return core.SlackInput{
			ID: "slack_schedule_stale_" + id, EnvelopeID: "env_schedule_stale_" + id,
			EventID: "EvScheduleStale" + id, Kind: "action", TeamID: cfg.Slack.TeamID,
			ChannelID: "COPS", MessageTS: "1700.920", UserID: cfg.Slack.Operators[0],
			ActionID: slackui.ActionRememberSchedule, ActionValue: payload,
		}
	}
	for _, tc := range []struct {
		name    string
		id      string
		payload string
		want    []string
	}{
		{
			name: "a button Emisar cannot read", id: "unreadable",
			payload: `{"version":9,"proposals":[]}`,
			want:    []string{"schedule", "could not read"},
		},
		{
			name: "a button whose proposal is gone", id: "gone",
			payload: `{"version":2,"proposal_id":"schedule_proposal_missing"}`,
			want:    []string{"schedule", "expired"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			answer := staleConfirmation(t, click(tc.id, tc.payload))
			for _, want := range tc.want {
				if !strings.Contains(strings.ToLower(answer), want) {
					t.Fatalf("the notice never said %q: %q", want, answer)
				}
			}
			if strings.Contains(answer, "invalid or stale") {
				t.Fatalf("the notice still refuses to say which of the two: %q", answer)
			}
		})
	}
}
