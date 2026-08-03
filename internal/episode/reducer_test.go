package episode

import (
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestReduceProjectsOrderedTransitionsAndProtectsTerminalState(t *testing.T) {
	now := time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC)
	payload, err := Encode(Transition{
		State: core.EpisodeWorking, Phase: "investigating", Status: "Checking application health",
	})
	if err != nil {
		t.Fatal(err)
	}
	next, err := Reduce(core.WorkEpisode{ID: "episode-1", State: core.EpisodeAcknowledged, EventSequence: 1}, core.WorkEpisodeEvent{
		ID: "event-2", EpisodeID: "episode-1", Sequence: 2, Kind: EventPhaseChanged,
		IdempotencyKey: "phase-2", Payload: payload, CreatedAt: now,
	})
	if err != nil || next.State != core.EpisodeWorking || next.EventSequence != 2 {
		t.Fatalf("next = %+v, err = %v", next, err)
	}
	payload, _ = Encode(Transition{
		State: core.EpisodeCompleted, Phase: "complete", Status: "Decision ready",
	})
	completed, err := Reduce(next, core.WorkEpisodeEvent{
		Sequence: 3, Kind: EventCompletionAccepted, IdempotencyKey: "complete-3",
		Payload: payload, CreatedAt: now.Add(time.Minute),
	})
	if err != nil || completed.CompletedAt.IsZero() {
		t.Fatalf("completed = %+v, err = %v", completed, err)
	}
	payload, _ = Encode(Transition{
		State: core.EpisodeWorking, Phase: "again", Status: "Reopened",
	})
	if _, err := Reduce(completed, core.WorkEpisodeEvent{
		Sequence: 4, Kind: EventPhaseChanged, IdempotencyKey: "phase-4", Payload: payload,
		CreatedAt: now.Add(2 * time.Minute),
	}); err == nil {
		t.Fatal("terminal episode reopened")
	}
}
