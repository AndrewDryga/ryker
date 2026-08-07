package app

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/service"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// recordEpisodeMaxEvents bounds one fixture. An episode with more events than
// this is a runaway rather than a representative example, and a fixture nobody
// can read is a fixture nobody will maintain.
const recordEpisodeMaxEvents = 200

// runRecordEpisode turns a completed episode from the live database into a
// replay fixture on stdout.
//
// The episode replay corpus is meant to be sanitized history, and history that
// has not happened yet cannot be fabricated into a fixture. This is the other
// way to build it: record real episodes as they complete, so each fixture is
// sanitized by construction, carries a source reference a reviewer can audit,
// and accumulates against the capability gaps that
// internal/episode_replay_coverage_test.go measures.
func runRecordEpisode(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("record-episode", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultConfigPath(), "configuration file")
	episodeID := flags.String("episode", "", "episode to record")
	capability := flags.String("capability", "", "capability slug this fixture proves")
	name := flags.String("name", "", "fixture name (defaults to the episode objective)")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("record-episode accepts no positional arguments")
	}
	if strings.TrimSpace(*episodeID) == "" {
		return errors.New("record-episode requires --episode")
	}
	if strings.TrimSpace(*capability) == "" {
		return errors.New(
			"record-episode requires --capability naming the row in section 24 this fixture proves;\n" +
				"an untagged fixture reads as coverage without proving anything",
		)
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	// Open read-only: recording must never be able to disturb a running instance.
	st, err := store.OpenCurrent(cfg.StateDir)
	if err != nil {
		return err
	}
	defer st.Close()

	fixture, err := recordEpisodeFixture(context.Background(), storeEpisodeSource{store: st}, cfg, *episodeID, *capability, *name)
	if err != nil {
		return err
	}
	encoded, err := json.Marshal(fixture)
	if err != nil {
		return err
	}
	fmt.Fprintln(stdout, string(encoded))
	return nil
}

// episodeSource is the read surface recording needs, named at the consumer so
// this stays testable without a live database.
type episodeSource interface {
	GetWorkEpisode(ctx context.Context, episodeID string) (core.WorkEpisode, error)
	ListEpisodeEvents(ctx context.Context, episodeID string, limit int) ([]core.WorkEpisodeEvent, error)
	ListEpisodeEvidence(ctx context.Context, episodeID string, limit int) ([]core.Evidence, error)
}

func recordEpisodeFixture(
	ctx context.Context,
	source episodeSource,
	cfg config.Config,
	episodeID string,
	capability string,
	name string,
) (service.EvaluationCase, error) {
	episode, err := source.GetWorkEpisode(ctx, episodeID)
	if err != nil {
		return service.EvaluationCase{}, err
	}
	events, err := source.ListEpisodeEvents(ctx, episodeID, recordEpisodeMaxEvents)
	if err != nil {
		return service.EvaluationCase{}, err
	}
	evidence, err := source.ListEpisodeEvidence(ctx, episodeID, 200)
	if err != nil {
		return service.EvaluationCase{}, err
	}
	if len(events) == 0 || len(evidence) == 0 {
		return service.EvaluationCase{}, fmt.Errorf(
			"episode %s has %d events and %d evidence rows; a replay fixture requires both",
			episodeID, len(events), len(evidence),
		)
	}

	// Every free-text field passes through the same sanitizer the running
	// service uses on outgoing messages, so a fixture cannot carry a secret
	// that a Slack message would have had redacted.
	sanitizer := slackui.NewSanitizer(0, recordingRedactions(cfg)...)

	recorded := make([]service.EvaluationRecordedEvent, 0, len(events))
	for _, event := range events {
		payload, err := sanitizeJSON(sanitizer, event.Payload)
		if err != nil {
			return service.EvaluationCase{}, fmt.Errorf("event %d: %w", event.Sequence, err)
		}
		recorded = append(recorded, service.EvaluationRecordedEvent{
			Sequence:   int64(event.Sequence),
			Kind:       event.Kind,
			Actor:      event.Actor,
			OccurredAt: event.CreatedAt.UTC().Format(time.RFC3339),
			Payload:    payload,
		})
	}

	results := make([]service.EvaluationToolResult, 0, len(evidence))
	for index, item := range evidence {
		observed := item.ObservedAt
		if observed.IsZero() {
			observed = item.CreatedAt
		}
		output, err := json.Marshal(map[string]string{
			"claim":       sanitizer.Text(item.Claim),
			"observation": sanitizer.Text(item.Observation),
			"source_name": sanitizer.Text(item.SourceName),
			"freshness":   item.Freshness,
			"confidence":  item.Confidence,
		})
		if err != nil {
			return service.EvaluationCase{}, err
		}
		results = append(results, service.EvaluationToolResult{
			ID:         fmt.Sprintf("rec_%s_%d", episode.ID, index+1),
			Tool:       core.FirstNonempty(item.SourceType, "unknown"),
			SourceType: core.FirstNonempty(item.SourceType, "unknown"),
			ObservedAt: observed.UTC().Format(time.RFC3339),
			Sanitized:  true,
			Output:     output,
		})
	}

	fixtureName := core.FirstNonempty(name, sanitizer.Text(episode.Objective), episode.ID)
	return service.EvaluationCase{
		Name: fixtureName,
		Tags: []string{
			"episode-replay",
			"capability:" + capability,
			// The source reference section 23.3 requires: an authorized
			// reviewer can audit how this fixture was labeled without the
			// fixture itself carrying private content.
			"source:episode/" + episode.ID,
		},
		Kind:                "watch",
		Input:               sanitizer.Text(episode.Objective),
		MentionsResponder:   true,
		RecordedEvents:      recorded,
		RecordedToolResults: results,
	}, nil
}

// recordingRedactions is every secret the recording process can see, so none of
// them can reach a fixture. It reuses preflight's assembly rather than building
// a second list that would drift from it.
func recordingRedactions(cfg config.Config) []string {
	pre := newPreflight(cfg)
	if err := pre.checkRuntimeSecrets(context.Background()); err != nil {
		// Recording still works without credentials loaded; it just cannot
		// redact values it was never given. The fixture is reviewed before it
		// lands either way.
		return nil
	}
	return pre.redactions
}

// sanitizeJSON walks a decoded payload and redacts every string it contains.
// Recursing rather than redacting the raw JSON text keeps the structure intact
// and means a secret cannot survive by sitting inside a nested object.
func sanitizeJSON(sanitizer *slackui.Sanitizer, payload json.RawMessage) (json.RawMessage, error) {
	if len(payload) == 0 {
		return json.RawMessage("{}"), nil
	}
	var decoded any
	if err := json.Unmarshal(payload, &decoded); err != nil {
		return nil, err
	}
	return json.Marshal(sanitizeValue(sanitizer, decoded))
}

func sanitizeValue(sanitizer *slackui.Sanitizer, value any) any {
	switch typed := value.(type) {
	case string:
		return sanitizer.Text(typed)
	case map[string]any:
		for key, nested := range typed {
			typed[key] = sanitizeValue(sanitizer, nested)
		}
		return typed
	case []any:
		for index, nested := range typed {
			typed[index] = sanitizeValue(sanitizer, nested)
		}
		return typed
	default:
		return value
	}
}

// storeEpisodeSource composes the episode view this command needs.
//
// It spans two repositories: the episode and its events belong to the store,
// the evidence belongs to intelligencestore. Rather than put a delegating
// method back on Store — which would undo the extraction, since a passthrough
// still counts against its method budget — the caller that wants both assembles
// them.
type storeEpisodeSource struct{ store *store.Store }

func (s storeEpisodeSource) GetWorkEpisode(
	ctx context.Context, episodeID string,
) (core.WorkEpisode, error) {
	return s.store.GetWorkEpisode(ctx, episodeID)
}

func (s storeEpisodeSource) ListEpisodeEvents(
	ctx context.Context, episodeID string, limit int,
) ([]core.WorkEpisodeEvent, error) {
	return s.store.ListEpisodeEvents(ctx, episodeID, limit)
}

func (s storeEpisodeSource) ListEpisodeEvidence(
	ctx context.Context, episodeID string, limit int,
) ([]core.Evidence, error) {
	return s.store.Intelligence.ListEpisodeEvidence(ctx, episodeID, limit)
}
