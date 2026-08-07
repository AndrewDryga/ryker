package store

import (
	"context"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

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
	result, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'pending', last_error = ?, next_attempt_at = ?, updated_at = ?
		WHERE id = ? AND state IN ('preparing', 'finalizing')`,
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
