package store

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

func (s *Store) GetConversationSession(
	ctx context.Context,
	channelID string,
) (core.ConversationSession, error) {
	var session core.ConversationSession
	var started, rotated sql.NullString
	var updated string
	err := s.db.QueryRowContext(ctx, `
		SELECT channel_id, repository, policy, session_id, session_revision,
		  coop_event_sequence, generation, turn_count, session_started_at,
		  rotated_at, updated_at
		FROM conversation_sessions
		WHERE channel_id = ?`, channelID).Scan(
		&session.ChannelID,
		&session.Repository,
		&session.Policy,
		&session.SessionID,
		&session.SessionRevision,
		&session.CoopEventSequence,
		&session.Generation,
		&session.TurnCount,
		&started,
		&rotated,
		&updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.ConversationSession{}, ErrNotFound
	}
	if err != nil {
		return core.ConversationSession{}, err
	}
	session.SessionStarted = sqlutil.ScanTime(started)
	session.RotatedAt = sqlutil.ScanTime(rotated)
	session.UpdatedAt = sqlutil.ParseTime(updated)
	return session, nil
}

// ListRecentConversationChannels returns durable conversation lanes in activity order.
// Responder uses this to restore warm model sessions for dynamically joined Slack channels.
func (s *Store) ListRecentConversationChannels(
	ctx context.Context,
	limit int,
) ([]string, error) {
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	return channelIDRows(s.db.QueryContext(ctx, `
		SELECT channel_id
		FROM conversation_sessions
		WHERE channel_id != ''
		ORDER BY updated_at DESC, channel_id
		LIMIT ?`, limit))
}

func (s *Store) BindConversationSession(
	ctx context.Context,
	channelID string,
	repository string,
	policy string,
	sessionID string,
	revision int64,
	generation int,
	started time.Time,
) error {
	if channelID == "" || repository == "" || policy == "" ||
		sessionID == "" || generation < 1 {
		return errors.New("conversation session binding is incomplete")
	}
	if started.IsZero() {
		started = s.now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO conversation_sessions (
		  channel_id, repository, policy, session_id, session_revision,
		  coop_event_sequence, generation, turn_count, session_started_at, updated_at
		) VALUES (?, ?, ?, ?, ?, 0, ?, 0, ?, ?)
		ON CONFLICT(channel_id) DO UPDATE SET
		  repository = excluded.repository,
		  policy = excluded.policy,
		  session_id = excluded.session_id,
		  session_revision = excluded.session_revision,
		  coop_event_sequence = 0,
		  generation = excluded.generation,
		  turn_count = 0,
		  session_started_at = excluded.session_started_at,
		  rotated_at = conversation_sessions.updated_at,
		  updated_at = excluded.updated_at`,
		channelID,
		repository,
		policy,
		sessionID,
		revision,
		generation,
		started.UTC().Format(timestampFormat),
		s.nowText(),
	)
	return err
}

func (s *Store) AdvanceConversationSessionEvents(
	ctx context.Context,
	channelID string,
	sessionID string,
	sequence int64,
) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE conversation_sessions
		SET coop_event_sequence = MAX(coop_event_sequence, ?), updated_at = ?
		WHERE channel_id = ? AND session_id = ?`,
		sequence, s.nowText(), channelID, sessionID,
	)
	return sqlutil.ExpectOne(result, err, "advance conversation session events")
}

func (s *Store) DetachConversationSession(
	ctx context.Context,
	channelID string,
	sessionID string,
) (bool, error) {
	if channelID == "" || sessionID == "" {
		return false, errors.New("conversation session detachment identity is incomplete")
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE conversation_sessions
		SET session_id = '',
		    session_revision = 0,
		    coop_event_sequence = 0,
		    turn_count = 0,
		    session_started_at = NULL,
		    rotated_at = updated_at,
		    updated_at = ?
		WHERE channel_id = ? AND session_id = ?`,
		s.nowText(), channelID, sessionID,
	)
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	return rows == 1, err
}

func (s *Store) DeleteConversationRoutes(
	ctx context.Context,
	channelID string,
) (int64, error) {
	if channelID == "" {
		return 0, errors.New("conversation route channel is required")
	}
	result, err := s.db.ExecContext(
		ctx,
		`DELETE FROM conversation_routes WHERE channel_id = ?`,
		channelID,
	)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (s *Store) GetConversationRoute(
	ctx context.Context,
	channelID string,
	userID string,
) (core.ConversationRoute, error) {
	var route core.ConversationRoute
	var explicit int
	var updated string
	err := s.db.QueryRowContext(ctx, `
		SELECT channel_id, user_id, active_thread_ts, previous_thread_ts,
		  explicit, updated_at
		FROM conversation_routes
		WHERE channel_id = ? AND user_id = ?`,
		channelID, userID,
	).Scan(
		&route.ChannelID,
		&route.UserID,
		&route.ActiveThreadTS,
		&route.PreviousThreadTS,
		&explicit,
		&updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.ConversationRoute{}, ErrNotFound
	}
	if err != nil {
		return core.ConversationRoute{}, err
	}
	route.Explicit = explicit != 0
	route.UpdatedAt = sqlutil.ParseTime(updated)
	return route, nil
}

func (s *Store) PutConversationRoute(
	ctx context.Context,
	route core.ConversationRoute,
) error {
	if route.ChannelID == "" || route.UserID == "" {
		return errors.New("conversation route identity is incomplete")
	}
	explicit := 0
	if route.Explicit {
		explicit = 1
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO conversation_routes (
		  channel_id, user_id, active_thread_ts, previous_thread_ts,
		  explicit, updated_at
		) VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(channel_id, user_id) DO UPDATE SET
		  active_thread_ts = excluded.active_thread_ts,
		  previous_thread_ts = excluded.previous_thread_ts,
		  explicit = excluded.explicit,
		  updated_at = excluded.updated_at`,
		route.ChannelID,
		route.UserID,
		route.ActiveThreadTS,
		route.PreviousThreadTS,
		explicit,
		s.nowText(),
	)
	return err
}
