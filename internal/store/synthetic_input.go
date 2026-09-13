package store

import (
	"context"

	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/store/slackinputstore"
)

// AdmitSyntheticSlackInput queues an input Ryker generated for itself.
//
// It belongs with the input queue rather than with schedules, even though a
// scheduled run is what usually produces one: it shares the queue's admission
// rules and its idempotency, and moving it to schedulestore would have made a
// second package responsible for what reaches the queue.
func (s *Store) AdmitSyntheticSlackInput(ctx context.Context, input core.SlackInput) (bool, error) {
	// Synthetic work is already owned by the caller. Insert it as processing in
	// one statement so a generic pending-input worker cannot claim the row
	// between admission and context freezing.
	return slackinputstore.Admit(ctx, s.db, input, "processing", 1, s.nowText(), false)
}
