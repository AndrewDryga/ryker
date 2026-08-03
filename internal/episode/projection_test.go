package episode

import (
	"testing"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestProjectDerivesOperatorVisibleState(t *testing.T) {
	tests := []struct {
		state      core.WorkEpisodeState
		commitment string
		busy       bool
		approval   bool
		stop       bool
		status     string
	}{
		{core.EpisodeAcknowledged, "queued", true, false, true, "is planning..."},
		{core.EpisodeWorking, "working", true, false, true, "is investigating..."},
		{core.EpisodeVerifying, "finishing", true, false, true, "is verifying the result..."},
		{core.EpisodeWaitingApproval, "finishing", false, true, false, "is waiting for approval..."},
		{core.EpisodeCompleted, "done", false, false, false, ""},
		{core.EpisodeBlocked, "blocked", false, false, false, ""},
		{core.EpisodeCancelled, "cancelled", false, false, false, ""},
	}
	for _, test := range tests {
		projection := Project(core.WorkEpisode{State: test.state})
		if projection.CommitmentState != test.commitment || projection.Busy != test.busy ||
			projection.WaitingApproval != test.approval || projection.CanStop != test.stop ||
			projection.NativeStatus != test.status {
			t.Fatalf("projection for %s = %+v", test.state, projection)
		}
	}
	if got := Project(core.WorkEpisode{
		State: core.EpisodeWorking, Activity: core.ActivityScheduling,
	}).NativeStatus; got != "is scheduling the follow-up..." {
		t.Fatalf("scheduled native status = %q", got)
	}
}
