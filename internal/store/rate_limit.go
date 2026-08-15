package store

import (
	"context"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

// RequeueRateLimitedFinalization puts a run whose finalization the provider
// refused back in the finalization lane, without counting the attempt.
//
// Finalization has its own lane and its own state, so it needs its own requeue:
// sending the run back to 'pending' would re-run work that already succeeded.
// The turn produced a result; only reading it was refused.
func (s *Store) RequeueRateLimitedFinalization(
	ctx context.Context,
	id string,
	detail string,
	next time.Time,
) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'applying', last_error = ?, next_attempt_at = ?, updated_at = ?
		WHERE id = ? AND state IN ('applying', 'finalizing')`,
		sqlutil.BoundedError(detail), next.UTC().Format(timestampFormat),
		s.nowText(), id,
	)
	return sqlutil.ExpectOne(result, err, "requeue rate-limited finalization")
}

// RequeueRateLimitedAgentRun puts a run back in the queue without counting the
// attempt against it.
//
// A provider rate limit is not the run failing. It is the provider saying "not
// now", and the only correct response is to ask again later — the work is
// still valid and nobody needs to be told. Counting it as a failure spends the
// run's attempts on something the run did not do, and once they are spent the
// operator gets an error message for work that was never wrong.
//
// So failure_count is deliberately not incremented and the run can never go
// terminal here. The episode stays acknowledged and retrying rather than
// moving to failed, because from the episode's point of view nothing has gone
// wrong yet.
//
// 'running' is in the accepted states because a refusal most often arrives as a
// failed turn — Coop reports turn.failed while the run is still running, and
// that path stages a terminal failure without going through any retry function.
// It is the reason a refused run showed state 'failed' with failure_count 0.
//
// last_error still records the detail: `responder status` and the logs should
// show why a run is waiting, even though Slack does not.
func (s *Store) RequeueRateLimitedAgentRun(
	ctx context.Context,
	id string,
	detail string,
	next time.Time,
) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	// coop_turn_id is dropped because the turn it names is dead, and keeping
	// it made the park permanent: the next lease polled the dead turn, re-read
	// its stale refusal, and parked again. run_d55f248a rode that loop for 3.5
	// hours on 2026-08-15 — its session had rotated to a healthy provider rung
	// at 00:42 and no new turn was ever submitted to it. Released, the next
	// attempt submits fresh into the same session and takes whatever rung the
	// ladder is on now.
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'pending', coop_turn_id = '',
		    last_error = ?, next_attempt_at = ?, updated_at = ?
		WHERE id = ? AND state IN ('preparing', 'running', 'finalizing')`,
		sqlutil.BoundedError(detail), next.UTC().Format(timestampFormat),
		s.nowText(), id,
	)
	if err := sqlutil.ExpectOne(result, err, "requeue rate-limited agent run"); err != nil {
		return err
	}
	if err := s.setEpisodeAttemptStateTx(
		ctx, tx, id, core.AttemptPending, detail, false,
	); err != nil {
		return err
	}
	if err := s.setWorkEpisodePhaseTx(
		ctx, tx, id, core.EpisodeAcknowledged, "waiting",
		"The AI provider is rate-limiting requests; the work is queued.",
		"Resume when the provider limit window recovers", time.Time{},
		"agent-run:"+id+":rate-limited:"+next.UTC().Format(time.RFC3339),
	); err != nil {
		return err
	}
	return tx.Commit()
}
