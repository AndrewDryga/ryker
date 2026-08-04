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
		result.NativeStatus = activeNativeStatus(value.Activity)
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

func activeNativeStatus(activity core.EpisodeActivity) string {
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
