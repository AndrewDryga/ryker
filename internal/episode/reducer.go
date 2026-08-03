package episode

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

const (
	EventCreated             = "episode_created"
	EventPhaseChanged        = "phase_changed"
	EventProgressReported    = "progress_reported"
	EventEvidenceRecorded    = "evidence_recorded"
	EventApprovalRequested   = "approval_requested"
	EventTaskOffered         = "task_offered"
	EventCompletionSubmitted = "completion_submitted"
	EventCompletionAccepted  = "completion_accepted"
	EventDeliveryProjected   = "delivery_projected"
)

type Transition struct {
	State       core.WorkEpisodeState `json:"state,omitempty"`
	Phase       string                `json:"phase,omitempty"`
	Status      string                `json:"status,omitempty"`
	NextAction  string                `json:"next_action,omitempty"`
	ProgressDue time.Time             `json:"progress_due_at,omitempty"`
	Summary     string                `json:"summary,omitempty"`
}

func Encode(value any) (json.RawMessage, error) {
	data, err := json.Marshal(value)
	return data, err
}

func DecodeTransition(event core.WorkEpisodeEvent) (Transition, error) {
	var transition Transition
	if len(event.Payload) == 0 {
		return transition, nil
	}
	if err := json.Unmarshal(event.Payload, &transition); err != nil {
		return Transition{}, fmt.Errorf("decode %s event: %w", event.Kind, err)
	}
	return transition, nil
}

func Reduce(current core.WorkEpisode, event core.WorkEpisodeEvent) (core.WorkEpisode, error) {
	if strings.TrimSpace(event.Kind) == "" || strings.TrimSpace(event.IdempotencyKey) == "" {
		return core.WorkEpisode{}, errors.New("episode event requires kind and idempotency key")
	}
	transition, err := DecodeTransition(event)
	if err != nil {
		return core.WorkEpisode{}, err
	}
	next := current
	switch event.Kind {
	case EventCreated:
		if current.EventSequence != 0 {
			return core.WorkEpisode{}, errors.New("episode_created can only be the first event")
		}
	case EventPhaseChanged, EventCompletionAccepted:
		if transition.State == "" || strings.TrimSpace(transition.Phase) == "" ||
			strings.TrimSpace(transition.Status) == "" {
			return core.WorkEpisode{}, errors.New("phase event requires state, phase, and status")
		}
		if terminal(current.State) && transition.State != current.State {
			return core.WorkEpisode{}, fmt.Errorf("terminal episode %s cannot transition to %s", current.State, transition.State)
		}
		next.State = transition.State
		next.Phase = strings.TrimSpace(transition.Phase)
		next.Status = strings.TrimSpace(transition.Status)
		next.NextAction = strings.TrimSpace(transition.NextAction)
		next.ProgressDueAt = transition.ProgressDue
		if terminal(next.State) {
			next.CompletedAt = event.CreatedAt
		}
	case EventProgressReported:
		if terminal(current.State) {
			return core.WorkEpisode{}, errors.New("terminal episode cannot accept progress")
		}
		if strings.TrimSpace(transition.Phase) == "" || strings.TrimSpace(transition.Summary) == "" {
			return core.WorkEpisode{}, errors.New("progress event requires phase and summary")
		}
		next.Phase = strings.TrimSpace(transition.Phase)
		next.Status = strings.TrimSpace(transition.Summary)
		next.ProgressDueAt = transition.ProgressDue
	default:
		// Evidence, approvals, offers, and delivery events are durable facts. They
		// do not mutate the execution projection until a phase event follows.
	}
	next.EventSequence = event.Sequence
	next.UpdatedAt = event.CreatedAt
	return next, nil
}

func terminal(state core.WorkEpisodeState) bool {
	switch state {
	case core.EpisodeCompleted, core.EpisodeFailed, core.EpisodeCancelled, core.EpisodeSuperseded:
		return true
	default:
		return false
	}
}
