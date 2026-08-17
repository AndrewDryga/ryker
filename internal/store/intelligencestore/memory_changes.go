package intelligencestore

import (
	"context"
	"database/sql"
	"encoding/json"
)

// ConversationMemoryChangeCount returns the number of individual memory
// fields the accepted decision changed. One audit row can carry several field
// changes, so counting rows would turn "two updates" into "one" precisely on
// the replies where the summary is useful.
func (r *Repository) ConversationMemoryChangeCount(
	ctx context.Context,
	sourceInput string,
) (int, error) {
	var raw []byte
	err := r.db.QueryRowContext(ctx, `
		SELECT changes_json
		FROM conversation_memory_changes
		WHERE source_input = ?
		LIMIT 1`, sourceInput,
	).Scan(&raw)
	if err == sql.ErrNoRows {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	var changes []json.RawMessage
	if err := json.Unmarshal(raw, &changes); err != nil {
		return 0, err
	}
	return len(changes), nil
}
