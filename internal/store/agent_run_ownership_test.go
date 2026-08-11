package store

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

func TestRetryAgentRunIfOwnedRequeuesCurrentOwner(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, _ := queueKernelEpisode(t, st, "message-current")
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if leased.ID != run.ID {
		t.Fatalf("leased run %s, want %s", leased.ID, run.ID)
	}

	applied, err := st.RetryAgentRunIfOwned(ctx, run.ID, "temporary failure", time.Now().UTC(), false)
	if err != nil {
		t.Fatal(err)
	}
	if !applied {
		t.Fatal("current worker did not apply its retry")
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != core.AgentRunPending || stored.Failures != 1 {
		t.Fatalf("stored run = state %s failures %d, want pending / 1", stored.State, stored.Failures)
	}
}

func TestRetryAgentRunIfOwnedAcceptsVerifiedSupersession(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	run, _ := queueKernelEpisode(t, st, "message-stale")
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if leased.ID != run.ID {
		t.Fatalf("leased run %s, want %s", leased.ID, run.ID)
	}
	if err := st.SupersedeAgentRun(ctx, run.ID, "a newer correlated event took over"); err != nil {
		t.Fatal(err)
	}

	applied, err := st.RetryAgentRunIfOwned(ctx, run.ID, "stale worker failed", time.Now().UTC(), false)
	if err != nil {
		t.Fatal(err)
	}
	if applied {
		t.Fatal("stale worker claimed it changed a superseded run")
	}
	stored, err := st.GetAgentRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.State != core.AgentRunSuperseded || stored.Failures != 0 {
		t.Fatalf("stored run = state %s failures %d, want superseded / 0", stored.State, stored.Failures)
	}
}
