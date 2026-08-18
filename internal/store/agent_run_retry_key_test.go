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
// Covers: TestTriageRetryNeverChangesTheRequestBehindAnIdempotencyKey
// Covers: TestRevisionConflictRetrySubmitsWithFreshRequestIdentity
// Covers: TestChangedSubmitRequestNeverReusesItsIdempotencyKey
// Covers: TestRevisionConflictRetryUsesFreshIdempotencyKey
// Covers finding: 20260813T191130Z-run_e867516ff75289e5d019314aadb84e23
// Covers finding: 20260813T212632Z-run_280e1377b17f0f2da4b98d66fd96b950
// Covers finding: 20260813T213814Z-run_52dd857732e14f1c43d18000fdcb8191
// Covers finding: 20260815T001139Z-run_0e8c9178fb5a83c4314c5569ffb6f373
// Covers finding: 20260815T003018Z-run_cb191d47eaa463fcff734f7af5f1cc53
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
