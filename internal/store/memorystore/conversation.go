package memorystore

import (
	"context"
	"errors"
)

// DeleteConversationMemories removes every conversation memory for a channel.
//
// It lives here rather than with the intelligence queries it was filed under:
// this package already owns listing and compacting conversation memories, and a
// table with two owners is a table whose invariants nobody holds.
func (r *Repository) DeleteConversationMemories(
	ctx context.Context,
	channelID string,
) (int64, error) {
	if channelID == "" {
		return 0, errors.New("conversation memory channel is required")
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `DELETE FROM conversation_memories WHERE channel_id = ?`, channelID)
	if err != nil {
		return 0, err
	}
	deleted, err := result.RowsAffected()
	if err != nil {
		return 0, err
	}
	result, err = tx.ExecContext(ctx, `
		DELETE FROM memory_rollups WHERE scope_kind = 'channel' AND scope_key = ?`, channelID)
	if err != nil {
		return 0, err
	}
	rollups, err := result.RowsAffected()
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return deleted + rollups, nil
}
