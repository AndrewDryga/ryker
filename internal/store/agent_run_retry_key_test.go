package store

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// A retry rebuilds its request, so it must not reuse the request identity of
// the attempt it is retrying. It did: run_c6423317 hit a revision conflict on
// its first submission, and every resubmission carried the same idempotency
// key against a rebuilt payload, so Coop answered "idempotency key is bound to
// another request" (409) until the attempts ran out — the first organic
// message of 2026-08-15, failed without a single turn running.
func TestARetryMintsAFreshRequestIdentity(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	queued, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "100.1",
		ConversationKey: "channel:C1", SourceKind: "watch", SourceID: "input_retry",
	})
	if err != nil {
		t.Fatal(err)
	}
	leased, err := st.LeaseAgentRun(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if retried, err := st.RetryAgentRunIfOwned(
		ctx, leased.ID, "Coop API revision_conflict (409)", time.Now().UTC(), false,
	); err != nil || !retried {
		t.Fatalf("retry = %v, %v", retried, err)
	}
	stored, err := st.GetAgentRun(ctx, leased.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.IdempotencyKey == queued.IdempotencyKey {
		t.Fatalf("the retry kept idempotency key %q; Coop will refuse every rebuilt "+
			"resubmission as bound to another request", stored.IdempotencyKey)
	}
	if stored.CoopTurnID != "" {
		t.Fatalf("the retry kept turn %q", stored.CoopTurnID)
	}
}
