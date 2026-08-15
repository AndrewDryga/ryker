package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
)

// reviewableEpisodeState is the boundary the self-improvement pass reads at:
// episode.Terminal, plus blocked.
//
// Blocked is not terminal and is deliberately included. It is where an episode
// stops when it hit an external limit it diagnosed but could not pass, which is
// some of the most informative reading in the corpus — intelligencestore's
// RecallableTerminalState keeps blocked outcomes for the same reason. What
// makes including a non-terminal state safe is the fingerprint: a blocked
// episode that revives spends another attempt and finishes somewhere else, and
// the review it already has stops matching, so the new ending comes back around.
//
// Everything else is refused because its trace is still being written. Reading
// working or waiting-on-a-person work would file a judgement on the half of the
// episode that happened before the interesting half.
func reviewableEpisodeState(state core.WorkEpisodeState) bool {
	return episodepkg.Terminal(state) || state == core.EpisodeBlocked
}

// ReviewEpisode records that a reviewer has read this episode's ending.
//
// The row carries what the ending LOOKED LIKE — lifecycle state, attempt count,
// completion time — because the ledger's whole job is to answer "has this trace
// been read", and an id alone cannot: a review filed against a blocked episode
// would go on suppressing that episode after it revived and finished somewhere
// else. Recording the fingerprint is what lets a moved ending resurface.
//
// One transaction, because the fingerprint and the refusal are read from the
// same episode row the review is filed against. Split across statements, an
// episode transitioning mid-call would be judged on one state and stamped with
// another, and the mismatch reads as a re-opened review forever after.
//
// An upsert rather than an insert: a review judges the latest ending, and the
// same episode is legitimately reviewed again every time its ending moves.
// created_at survives the conflict so the ledger keeps saying when this episode
// was first read.
func (s *Store) ReviewEpisode(ctx context.Context, episodeID, reviewer, note string) error {
	episodeID = strings.TrimSpace(episodeID)
	reviewer = strings.TrimSpace(reviewer)
	if episodeID == "" || reviewer == "" {
		return errors.New("an episode review needs an episode and a reviewer")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var state core.WorkEpisodeState
	var completed sql.NullString
	if err := tx.QueryRowContext(ctx,
		`SELECT lifecycle_state, completed_at FROM work_episodes WHERE id = ?`, episodeID,
	).Scan(&state, &completed); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	if !reviewableEpisodeState(state) {
		return fmt.Errorf(
			"a review judges an ending and episode %s has not ended: it is %s",
			episodeID, state,
		)
	}
	var attempts int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM episode_attempts WHERE episode_id = ?`, episodeID,
	).Scan(&attempts); err != nil {
		return err
	}
	now := s.nowText()
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO episode_reviews
		  (episode_id, reviewed_at, reviewer, note, lifecycle_state, attempts,
		   completed_at, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(episode_id) DO UPDATE SET
		  reviewed_at = excluded.reviewed_at,
		  reviewer = excluded.reviewer,
		  note = excluded.note,
		  lifecycle_state = excluded.lifecycle_state,
		  attempts = excluded.attempts,
		  completed_at = excluded.completed_at,
		  updated_at = excluded.updated_at`,
		episodeID, now, reviewer, core.BoundedText(strings.TrimSpace(note), 1000),
		string(state), attempts, completed.String, now, now,
	); err != nil {
		return err
	}
	return tx.Commit()
}
