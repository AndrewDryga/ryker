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
	EventAccepted            = "episode_accepted"
	EventDestinationBound    = "destination_bound"
	EventDestinationChanged  = "destination_changed"
	EventGoalPlanned         = "goal_planned"
	EventGoalStarted         = "goal_started"
	EventGoalCompleted       = "goal_completed"
	EventGoalBlocked         = "goal_blocked"
	EventAttemptStarted      = "attempt_started"
	EventAttemptFailed       = "attempt_failed"
	EventContextExtended     = "context_extended"
	EventPhaseChanged        = "phase_changed"
	EventProgressReported    = "progress_reported"
	EventProgressRecorded    = "progress_recorded"
	EventEvidenceRecorded    = "evidence_recorded"
	EventOperatorInputAsked  = "operator_input_requested"
	EventApprovalRequested   = "approval_requested"
	EventExternalWaitStarted = "external_wait_started"
	EventWakeupResolved      = "wakeup_resolved"
	EventEffectPlanned       = "effect_planned"
	EventEffectSucceeded     = "effect_succeeded"
	EventEffectFailed        = "effect_failed"
	EventVerificationStarted = "verification_started"
	EventEpisodeCompleted    = "episode_completed"
	EventEpisodeReopened     = "episode_reopened"
	EventEpisodeBlocked      = "episode_blocked"
	EventEpisodeCancelled    = "episode_cancelled"
	EventEpisodeRefused      = "episode_refused"
	EventTaskOffered         = "task_offered"
	// EventKnowledgeOffered records a proposal that a verified remediation
	// should outlive its episode. The event carries the whole operation because
	// the confirmation click reads the offer back from here rather than from
	// the button: a knowledge card's body does not fit in a Slack action value,
	// and an identity that does is the only thing worth trusting one for.
	EventKnowledgeOffered    = "knowledge_offered"
	EventCompletionSubmitted = "completion_submitted"
	EventCompletionAccepted  = "completion_accepted"
	EventDeliveryProjected   = "delivery_projected"
	EventCommitmentOverdue   = "commitment_overdue"
	// EventOperationDropped records a result operation the host refused to
	// apply. It changes no projection — it exists so that "the model asked for
	// this and it did not happen" is answerable from the episode's own
	// timeline rather than from a log line nobody is reading.
	EventOperationDropped = "operation_dropped"
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
	case EventCreated, EventAccepted:
		if current.EventSequence != 0 {
			return core.WorkEpisode{}, errors.New("episode acceptance can only be the first event")
		}
	case EventPhaseChanged, EventCompletionAccepted, EventEpisodeCompleted,
		EventEpisodeBlocked, EventEpisodeCancelled, EventEpisodeRefused,
		EventVerificationStarted:
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
	case EventEpisodeReopened:
		if !terminal(current.State) {
			return core.WorkEpisode{}, errors.New("only a terminal episode can be reopened")
		}
		if transition.State == "" || terminal(transition.State) ||
			strings.TrimSpace(transition.Phase) == "" ||
			strings.TrimSpace(transition.Status) == "" {
			return core.WorkEpisode{}, errors.New("episode reopen requires a nonterminal state, phase, and status")
		}
		next.State = transition.State
		next.Phase = strings.TrimSpace(transition.Phase)
		next.Status = strings.TrimSpace(transition.Status)
		next.NextAction = strings.TrimSpace(transition.NextAction)
		next.ProgressDueAt = transition.ProgressDue
		next.CompletedAt = time.Time{}
	case EventProgressReported, EventProgressRecorded:
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
	case core.EpisodeCompleted, core.EpisodeFailed, core.EpisodeRefused,
		core.EpisodeCancelled, core.EpisodeSuperseded:
		return true
	default:
		return false
	}
}

// Terminal is the shared lifecycle boundary used by the reducer, store, and
// effect planner. It intentionally contains no transport-specific states.
func Terminal(state core.WorkEpisodeState) bool { return terminal(state) }
