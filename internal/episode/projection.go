package episode

import (
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
)

// Projection is the operator-visible state derived from an episode. The event
// stream owns lifecycle state; Slack, commitments, and controls consume this
// projection instead of maintaining independent state machines.
type Projection struct {
	CommitmentState string
	NativeStatus    string
	NextAction      string
	Busy            bool
	WaitingApproval bool
	Terminal        bool
	CanStop         bool
}

func Project(value core.WorkEpisode) Projection {
	result := Projection{
		NextAction: strings.TrimSpace(value.NextAction),
		Terminal:   terminal(value.State),
	}
	switch value.State {
	case core.EpisodeAccepted, core.EpisodeAcknowledged, core.EpisodePlanning,
		core.EpisodeRetrying:
		result.CommitmentState = "queued"
		result.NativeStatus = "is planning..."
		result.Busy = true
		result.CanStop = true
	case core.EpisodeWorking:
		result.CommitmentState = "working"
		result.NativeStatus = ActivityNativeStatus(value.Activity)
		result.Busy = true
		result.CanStop = true
	case core.EpisodeVerifying:
		result.CommitmentState = "finishing"
		result.NativeStatus = "is verifying the result..."
		result.Busy = true
		result.CanStop = true
	case core.EpisodeWaitingApproval, core.EpisodeWaitingOperator,
		core.EpisodeWaitingExternal:
		result.CommitmentState = "finishing"
		result.NativeStatus = "is waiting for approval..."
		result.WaitingApproval = true
	case core.EpisodeCompleted:
		result.CommitmentState = "done"
	case core.EpisodeBlocked, core.EpisodeFailed, core.EpisodeRefused:
		result.CommitmentState = "blocked"
	case core.EpisodeCancelled, core.EpisodeSuperseded:
		result.CommitmentState = "cancelled"
	default:
		result.CommitmentState = "blocked"
	}
	return result
}

// ProgressSummary is how the host describes a turn that is still running: what
// kind of work is still going, and — for a turn that has narrated nothing at
// all — what it is generally doing.
//
// Two halves rather than one sentence because only the second is a placeholder.
// A turn with a recorded interior replaces the generic clause with what it
// actually last did and keeps the lead, which is the part that comes from the
// contract rather than from the stream.
//
// It sits beside the native status for the same reason that does: both are the
// host's own words about an episode in a state, and having them in one place is
// what stops a turn being called "investigating" in one sentence and "working"
// in the next.
func ProgressSummary(effort core.EffortContract, activity string) string {
	lead, generic := progressSentence(effort)
	if activity == "" {
		return lead + "; " + generic
	}
	return core.TruncateUTF8(lead+" — "+activity, progressSummaryBytes)
}

// progressSummaryBytes bounds the host's own checkin row.
//
// The row is a line in the episode feed beside the model's own progress notes,
// and it is also half of an idempotency key, so it is bounded where it is
// composed. Two lines' worth: the lead, what was last done, and the totals.
const progressSummaryBytes = 200

func progressSentence(effort core.EffortContract) (lead, generic string) {
	switch effort {
	case core.EffortOperationalAssessment:
		return "Still working", "checking every required system layer"
	case core.EffortIncidentInvestigation:
		return "Still investigating", "verifying impact and the safest response"
	case core.EffortEngineeringTask:
		return "Still working", "implementing and validating the focused change"
	default:
		return "Still working", "completing the requested checks"
	}
}

// ActivityNativeStatus is what a thread says an episode of this kind is doing.
//
// Exported because the same mapping answers two questions asked from different
// places: what a working episode is doing, and what a request that has not
// become an episode yet is about to do. One mapping, so a queued turn and the
// same turn a second later do not describe themselves differently.
func ActivityNativeStatus(activity core.EpisodeActivity) string {
	switch activity {
	case core.ActivityExplaining:
		return "is explaining the earlier answer..."
	case core.ActivityScheduling:
		return "is scheduling the follow-up..."
	case core.ActivityEngineering:
		return "is working on the code..."
	case core.ActivityOperating:
		return "is checking the governed operation..."
	default:
		return "is investigating..."
	}
}
