package store

import (
	"context"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/core"
)

// A correction round is not a failed attempt.
//
// blitz run_3a615b9db finished with failure_count 19 and every one of those
// nineteen was a host correction: the model answered, the host refused the
// answer and sent it back. The episode page read "failures=19", which says
// "the model was wrong nineteen times" when what happened was that the host
// argued with itself for twenty-two minutes. Every report built on
// failure_count — attrition rates, provider health, the retry ladder's own
// backoff — read the same loop as provider failure and could not tell one from
// the other. Five more runs did it the same day (3c5418076, 03d30c2f,
// 806c9593, 006e593a, f7e37eb4).
//
// Infrastructure attrition still spends an attempt: a rotated session or a
// dropped stream is exactly what the ladder exists to bound.
func TestACorrectionRoundIsNotCountedAsAFailedAttempt(t *testing.T) {
	ctx := context.Background()
	st, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	if _, _, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: "C1", ThreadTS: "100.1",
		ConversationKey: "channel:C1", SourceKind: "watch", SourceID: "input_first",
	}); err != nil {
		t.Fatal(err)
	}

	requeue := func(turnID, detail string, spendsAttempt bool) core.AgentRun {
		t.Helper()
		leased, err := st.LeaseAgentRun(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if err := st.BindAgentRunSession(
			ctx, leased.ID, "session_1", 1, "repo", 0, []byte("{}"),
		); err != nil {
			t.Fatal(err)
		}
		if err := st.MarkAgentRunSubmitted(ctx, leased.ID, turnID, 1, 0); err != nil {
			t.Fatal(err)
		}
		if err := st.RequeueAgentRun(
			ctx, leased.ID, detail, 0, time.Now().UTC(), spendsAttempt,
		); err != nil {
			t.Fatal(err)
		}
		stored, err := st.GetAgentRun(ctx, leased.ID)
		if err != nil {
			t.Fatal(err)
		}
		return stored
	}

	corrected := requeue(
		"turn_1",
		"required claims still contain unresolved contradictions: change.recent",
		false,
	)
	if corrected.Failures != 0 {
		t.Fatalf("a correction round spent an attempt: failures = %d", corrected.Failures)
	}
	// The attempt chain's clock. Evidence freshness is judged against this, so
	// a correction round that moved it would re-open the freshness ping-pong
	// from the other side: the loop would keep resetting the window it is
	// supposed to be holding still.
	chainStart := corrected.StartedAt
	if chainStart.IsZero() {
		t.Fatal("a corrected run has no chain start to judge freshness against")
	}

	// Three more corrections, the shape of the recorded loop: still no failures.
	for round, turn := range []string{"turn_2", "turn_3", "turn_4"} {
		corrected = requeue(turn, "required claims still contain unresolved contradictions", false)
		if corrected.Failures != 0 {
			t.Fatalf("correction round %d spent an attempt: failures = %d", round+2, corrected.Failures)
		}
		if !corrected.StartedAt.Equal(chainStart) {
			t.Fatalf(
				"correction round %d moved the attempt chain start from %s to %s",
				round+2, chainStart, corrected.StartedAt,
			)
		}
	}

	// The rotated session and the dropped stream still climb the ladder they
	// exist for. Counting these is the whole reason failure_count is there.
	attrition := requeue("turn_5", "the Coop session was rotated", true)
	if attrition.Failures != 1 {
		t.Fatalf("an infrastructure requeue did not spend an attempt: failures = %d", attrition.Failures)
	}
	attrition = requeue("turn_6", "the provider dropped the response mid-stream", true)
	if attrition.Failures != 2 {
		t.Fatalf("the second infrastructure requeue did not climb: failures = %d", attrition.Failures)
	}

	// The stall heuristic scripts/watchdog.sh depends on. It reads
	//   failure_count > 0 OR (started_at IS NOT NULL AND started_at != '')
	// and a correction requeue leaves started_at alone — it is set once on the
	// first transition into running and never cleared — so a run cycling
	// corrections with failure_count 0 is still visible as a stall. Without
	// this the watchdog would go blind to exactly the loop being fixed.
	var startedAt string
	if err := st.db.QueryRowContext(ctx,
		`SELECT COALESCE(started_at, '') FROM agent_runs WHERE id = ?`, attrition.ID,
	).Scan(&startedAt); err != nil {
		t.Fatal(err)
	}
	if startedAt == "" {
		t.Fatal("a requeued run lost started_at; the watchdog stall heuristic goes blind")
	}
}
