package app

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
)

type fakeEpisodeSource struct {
	episode  core.WorkEpisode
	events   []core.WorkEpisodeEvent
	evidence []core.Evidence
}

func (f fakeEpisodeSource) GetWorkEpisode(context.Context, string) (core.WorkEpisode, error) {
	return f.episode, nil
}

func (f fakeEpisodeSource) ListEpisodeEvents(
	context.Context, string, int,
) ([]core.WorkEpisodeEvent, error) {
	return f.events, nil
}

func (f fakeEpisodeSource) ListEpisodeEvidence(
	context.Context, string, int,
) ([]core.Evidence, error) {
	return f.evidence, nil
}

func recordingFixtureSource(secret string) fakeEpisodeSource {
	moment := time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC)
	return fakeEpisodeSource{
		episode: core.WorkEpisode{ID: "ep_1", Objective: "assess the checkout rollout"},
		events: []core.WorkEpisodeEvent{
			{
				Sequence: 1, Kind: "episode.created", Actor: "operator", CreatedAt: moment,
				Payload: json.RawMessage(
					`{"objective":"assess the checkout rollout","note":{"token":"` + secret + `"}}`,
				),
			},
		},
		evidence: []core.Evidence{
			{
				Claim:       "the rollout completed",
				Observation: "deployment finished with token " + secret,
				SourceType:  "emisar", SourceName: "prod-eu", ObservedAt: moment,
			},
		},
	}
}

// A fixture is meant to be sanitized by construction. If a secret can reach one
// through a nested payload field, the corpus becomes a place secrets are stored
// in git — which is worse than having no corpus.
func TestRecordedFixtureCarriesNoSecret(t *testing.T) {
	const secret = "xoxb-recording-secret-value"
	t.Setenv("RECORD_BOT_TOKEN", secret)
	t.Setenv("RECORD_APP_TOKEN", "xapp-recording-app-token")
	t.Setenv("RECORD_EMISAR_TOKEN", "emk-recording-emisar-token")

	var cfg config.Config
	cfg.Slack.BotTokenEnv = "RECORD_BOT_TOKEN"
	cfg.Slack.AppTokenEnv = "RECORD_APP_TOKEN"
	cfg.Coop.EmisarTokenEnv = "RECORD_EMISAR_TOKEN"

	fixture, err := recordEpisodeFixture(
		context.Background(), recordingFixtureSource(secret), cfg,
		"ep_1", "mentions-dms-and-proactive-messages", "",
	)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(fixture)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), secret) {
		t.Fatalf("the recorded fixture carries a secret:\n%s", encoded)
	}
}

// The corpus exists to prove capabilities, so a fixture must say which one it
// proves and where it came from. An untagged fixture reads as coverage while
// proving nothing, which is the failure mode the coverage ratchet exists to
// prevent.
func TestRecordedFixtureIsTaggedAndTraceable(t *testing.T) {
	fixture, err := recordEpisodeFixture(
		context.Background(), recordingFixtureSource("none"), config.Config{},
		"ep_1", "reactions", "",
	)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"episode-replay", "capability:reactions", "source:episode/ep_1"} {
		if !containsString(fixture.Tags, want) {
			t.Errorf("fixture tags %v missing %q", fixture.Tags, want)
		}
	}
	if fixture.Name != "assess the checkout rollout" {
		t.Errorf("fixture name = %q", fixture.Name)
	}
	if len(fixture.RecordedEvents) != 1 || len(fixture.RecordedToolResults) != 1 {
		t.Fatalf("recorded %d events and %d results",
			len(fixture.RecordedEvents), len(fixture.RecordedToolResults))
	}
	if !fixture.RecordedToolResults[0].Sanitized {
		t.Error("recorded tool result is not marked sanitized")
	}
}

// An episode with no evidence cannot prove a capability, and recording it would
// add a fixture that passes without exercising anything.
func TestRecordingRefusesAnEpisodeWithNothingToReplay(t *testing.T) {
	source := recordingFixtureSource("none")
	source.evidence = nil
	_, err := recordEpisodeFixture(
		context.Background(), source, config.Config{}, "ep_1", "reactions", "",
	)
	if err == nil || !strings.Contains(err.Error(), "requires both") {
		t.Fatalf("error = %v", err)
	}
}

// An empty capability is not a missing tag, it is a false one: the fixture
// claims "capability:" and the coverage ratchet has no such row. The flag
// parser refused this, but promotion calls straight past the flag parser and
// wrote four fixtures tagged that way, so the refusal belongs on the shared
// path instead.
func TestRecordingRefusesAnUnnamedCapability(t *testing.T) {
	for _, capability := range []string{"", "   "} {
		_, err := recordEpisodeFixture(
			context.Background(), recordingFixtureSource("none"), config.Config{},
			"ep_1", capability, "",
		)
		if err == nil || !strings.Contains(err.Error(), "section 24") {
			t.Fatalf("capability %q: error = %v", capability, err)
		}
	}
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
