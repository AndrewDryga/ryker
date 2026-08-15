package app

import (
	"context"
	"database/sql"
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
	run      core.AgentRun
	runErr   error
	input    core.SlackInput
	inputErr error
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

func (f fakeEpisodeSource) GetAgentRun(context.Context, string) (core.AgentRun, error) {
	return f.run, f.runErr
}

func (f fakeEpisodeSource) GetSlackInput(context.Context, string) (core.SlackInput, error) {
	return f.input, f.inputErr
}

// recordingTriggerText is longer than the 180-byte objective headline on
// purpose: the whole defect was that the headline was recorded in its place.
const recordingTriggerText = "Assess the checkout rollout end to end. Start from the " +
	"deployment that landed this morning, reconcile it against what the repository says should " +
	"be running, and tell me whether customers can complete a purchase right now. If anything " +
	"is degraded, say what and since when."

func recordingFixtureSource(secret string) fakeEpisodeSource {
	moment := time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC)
	return fakeEpisodeSource{
		episode: core.WorkEpisode{
			ID: "ep_1", Objective: "assess the checkout rollout", AgentRunID: "run_1",
		},
		run:   core.AgentRun{ID: "run_1", SourceKind: "watch", SourceID: "slack_message_1"},
		input: core.SlackInput{ID: "slack_message_1", Text: recordingTriggerText},
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

// The fixture's input must be what the operator actually said, not the display
// headline built from it.
//
// core.WorkEpisode.Objective is truncated to 180 bytes with an ellipsis for the
// Slack status line, and recording it as the input cut three of the four
// promoted fixtures mid-sentence. One lost its entire instruction, so the model
// asked what outcome to apply — the correct answer to a question that had been
// cut in half, scored as a regression.
func TestRecordedFixtureCarriesTheRealTriggerText(t *testing.T) {
	fixture, err := recordEpisodeFixture(
		context.Background(), recordingFixtureSource("none"), config.Config{},
		"ep_1", "reactions", "",
	)
	if err != nil {
		t.Fatal(err)
	}
	if fixture.Input != recordingTriggerText {
		t.Fatalf("fixture input = %q", fixture.Input)
	}
	if len(fixture.Input) <= 180 {
		t.Fatalf("the test's own trigger text is not long enough to prove anything: %d bytes",
			len(fixture.Input))
	}
	// The headline is still fine as a label.
	if fixture.Name != "assess the checkout rollout" {
		t.Fatalf("fixture name = %q", fixture.Name)
	}
}

// A fixture whose trigger text cannot be read is unanswerable, and an
// unanswerable fixture in a corpus gated at a 100% pass rate is a gate that can
// never be green. Refusing is the only outcome that stays honest: retention had
// already pruned the input row for one promoted episode, and nothing in the
// resulting file said the question was missing its second half.
func TestRecordingRefusesWhenTheTriggerTextIsGone(t *testing.T) {
	for name, mutate := range map[string]func(*fakeEpisodeSource){
		"no originating run": func(s *fakeEpisodeSource) { s.episode.AgentRunID = "" },
		"run is gone":        func(s *fakeEpisodeSource) { s.runErr = sql.ErrNoRows },
		"run has no source":  func(s *fakeEpisodeSource) { s.run.SourceID = "" },
		"input row pruned":   func(s *fakeEpisodeSource) { s.inputErr = sql.ErrNoRows },
		"input has no text":  func(s *fakeEpisodeSource) { s.input.Text = "   " },
	} {
		t.Run(name, func(t *testing.T) {
			source := recordingFixtureSource("none")
			mutate(&source)
			_, err := recordEpisodeFixture(
				context.Background(), source, config.Config{}, "ep_1", "reactions", "",
			)
			if err == nil || !strings.Contains(err.Error(), "real trigger text") {
				t.Fatalf("error = %v", err)
			}
		})
	}
}

// A control click is a real recorded trigger with no prose: the interaction IS
// the ask. Refusing it left the controls capabilities structurally
// unrecordable — the diff-and-draft-pr-controls material on the emisar
// deployment is exactly a Publish click whose input row carries ActionID and
// no text (2026-08-14 fixture sprint). The synthesized trigger renders only
// what the durable row already records, so it is harvested, not invented.
func TestAControlClickTriggerIsRenderedFromItsRecordedAction(t *testing.T) {
	source := recordingFixtureSource("none")
	source.input.Text = "  "
	source.input.Kind = "action"
	source.input.ActionID = "publish_draft_pr"
	fixture, err := recordEpisodeFixture(
		context.Background(), source, config.Config{}, "ep_1", "diff-and-draft-pr-controls", "",
	)
	if err != nil {
		t.Fatal(err)
	}
	if fixture.Input != "[control] publish_draft_pr" {
		t.Fatalf("fixture input = %q", fixture.Input)
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
