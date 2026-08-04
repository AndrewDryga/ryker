package episode

import (
	"reflect"
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

func TestReduceReplayIsDeterministic(t *testing.T) {
	now := time.Date(2026, 8, 3, 12, 0, 0, 0, time.UTC)
	working, _ := Encode(Transition{
		State: core.EpisodeWorking, Phase: "investigating", Status: "Checking rollout",
		NextAction: "verify deployment",
	})
	waiting, _ := Encode(Transition{
		State: core.EpisodeWaitingExternal, Phase: "waiting_external",
		Status: "Waiting for deployment", NextAction: "resume on terminal event",
	})
	events := []core.WorkEpisodeEvent{
		{ID: "e1", EpisodeID: "episode-1", Sequence: 1, Kind: EventPhaseChanged, IdempotencyKey: "k1", Payload: working, CreatedAt: now},
		{ID: "e2", EpisodeID: "episode-1", Sequence: 2, Kind: EventExternalWaitStarted, IdempotencyKey: "k2", CreatedAt: now.Add(time.Minute)},
		{ID: "e3", EpisodeID: "episode-1", Sequence: 3, Kind: EventPhaseChanged, IdempotencyKey: "k3", Payload: waiting, CreatedAt: now.Add(time.Minute)},
	}
	replay := func() core.WorkEpisode {
		state := core.WorkEpisode{ID: "episode-1", State: core.EpisodeAccepted}
		for _, event := range events {
			var err error
			state, err = Reduce(state, event)
			if err != nil {
				t.Fatal(err)
			}
		}
		return state
	}
	first := replay()
	second := replay()
	if !reflect.DeepEqual(first, second) {
		t.Fatalf("replays diverged:\nfirst:  %+v\nsecond: %+v", first, second)
	}
	if first.State != core.EpisodeWaitingExternal || first.EventSequence != 3 {
		t.Fatalf("unexpected replay result: %+v", first)
	}
}
