package store

import (
	"context"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

// AdmitSyntheticSlackInput queues an input Responder generated for itself.
//
// It belongs with the input queue rather than with schedules, even though a
// scheduled run is what usually produces one: it shares the queue's admission
// rules and its idempotency, and moving it to schedulestore would have made a
// second package responsible for what reaches the queue.
func (s *Store) AdmitSyntheticSlackInput(ctx context.Context, input core.SlackInput) (bool, error) {
	admitted, err := admitSlackInput(ctx, s.db, input, s.nowText())
	if err != nil || !admitted {
		return admitted, err
	}
	result, err := s.db.ExecContext(ctx, `UPDATE slack_inputs SET state = 'processing', attempts = 1, updated_at = ? WHERE id = ? AND state = 'pending'`, s.nowText(), input.ID)
	if err := sqlutil.ExpectOne(result, err, "activate synthetic Slack input"); err != nil {
		return false, err
	}
	return true, nil
}
