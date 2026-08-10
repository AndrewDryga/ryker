package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

func (s *Store) CreateConfigurationSession(
	ctx context.Context,
	session core.ConfigurationSession,
) (core.ConfigurationSession, error) {
	if strings.TrimSpace(session.TeamID) == "" || strings.TrimSpace(session.ChannelID) == "" {
		return core.ConfigurationSession{}, errors.New("configuration workspace and channel are required")
	}
	if session.ID == "" {
		var err error
		session.ID, err = core.NewID("cfg")
		if err != nil {
			return core.ConfigurationSession{}, err
		}
	}
	if session.Step == "" {
		session.Step = "participation"
	}
	if session.Status == "" {
		session.Status = "asking"
	}
	now := s.now().UTC()
	if session.ExpiresAt.IsZero() {
		session.ExpiresAt = now.Add(30 * time.Minute)
	}
	session.CreatedAt = now
	session.UpdatedAt = now
	session.Revision = 1
	session.Draft.ChannelID = session.ChannelID
	draft, err := json.Marshal(session.Draft)
	if err != nil {
		return core.ConfigurationSession{}, err
	}
	threadRoots, err := json.Marshal(session.ThreadRoots)
	if err != nil {
		return core.ConfigurationSession{}, err
	}
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO configuration_sessions (
		  id, team_id, channel_id, thread_ts, card_ts, response_thread_ts, thread_roots_json,
		  initiator_id, step, status, draft_json, revision, expires_at, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		session.ID, session.TeamID, session.ChannelID, session.ThreadTS, session.CardTS,
		session.ResponseThreadTS, threadRoots, session.Initiator, session.Step,
		session.Status, draft, session.Revision,
		session.ExpiresAt.Format(timestampFormat), now.Format(timestampFormat),
		now.Format(timestampFormat),
	)
	if isUniqueConstraint(err) {
		return core.ConfigurationSession{}, ErrConflict
	}
	return session, err
}

func (s *Store) GetActiveConfigurationSession(
	ctx context.Context,
	channelID string,
) (core.ConfigurationSession, error) {
	return scanConfigurationSession(s.db.QueryRowContext(ctx, `
		SELECT id, team_id, channel_id, thread_ts, card_ts, response_thread_ts, thread_roots_json,
		  initiator_id, step, status, draft_json, revision, expires_at, created_at, updated_at
		FROM configuration_sessions
		WHERE channel_id = ? AND status IN ('asking', 'confirming')
		ORDER BY created_at DESC LIMIT 1`,
		channelID,
	))
}

func (s *Store) GetLatestConfigurationSession(
	ctx context.Context,
	channelID string,
) (core.ConfigurationSession, error) {
	return scanConfigurationSession(s.db.QueryRowContext(ctx, `
		SELECT id, team_id, channel_id, thread_ts, card_ts, response_thread_ts, thread_roots_json,
		  initiator_id, step, status, draft_json, revision, expires_at, created_at, updated_at
		FROM configuration_sessions
		WHERE channel_id = ?
		ORDER BY created_at DESC, rowid DESC LIMIT 1`,
		channelID,
	))
}

func (s *Store) GetConfigurationSession(
	ctx context.Context,
	id string,
) (core.ConfigurationSession, error) {
	return scanConfigurationSession(s.db.QueryRowContext(ctx, `
		SELECT id, team_id, channel_id, thread_ts, card_ts, response_thread_ts, thread_roots_json,
		  initiator_id, step, status, draft_json, revision, expires_at, created_at, updated_at
		FROM configuration_sessions WHERE id = ?`,
		id,
	))
}

// BindConfigurationThread records the opening card: the message the rest of the
// setup edits, and the thread root that its replies may arrive under.
func (s *Store) BindConfigurationThread(
	ctx context.Context,
	id string,
	threadTS string,
) error {
	roots, err := json.Marshal([]string{threadTS})
	if err != nil {
		return err
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE configuration_sessions
		SET thread_ts = ?, card_ts = ?, response_thread_ts = '', thread_roots_json = ?,
		  revision = revision + 1, updated_at = ?
		WHERE id = ? AND status IN ('asking', 'confirming') AND thread_ts = ''`,
		threadTS, threadTS, roots, s.nowText(), id,
	)
	return sqlutil.ExpectOne(result, err, "bind configuration thread")
}

// RecordConfigurationMessage points the session at the card it just posted, and
// keeps the set of conversations whose replies count as setup answers.
//
// Both facts come from the same post, and writing them in one statement is why
// the card cannot be recorded without its thread root or the other way round.
// They are still different questions. card_ts is the single message chat.update
// may rewrite and response_thread_ts is where it sits, so both are replaced.
// thread_roots_json accumulates: a setup that moved into a thread leaves an
// operator reading the earlier question, and an answer typed under that one is
// still an answer.
//
// Callers record only when the card is posted or adopted. An edit in place
// changes neither pointer, and writing response_thread_ts on every reply would
// make it the last answer's thread rather than the card's home — which would
// read the next answer in the channel as a request to move.
func (s *Store) RecordConfigurationMessage(
	ctx context.Context,
	id string,
	cardTS string,
	responseThreadTS string,
) error {
	if cardTS == "" || len(cardTS) > 64 || len(responseThreadTS) > 64 {
		return errors.New("invalid Slack configuration message location")
	}
	session, err := s.GetConfigurationSession(ctx, id)
	if err != nil {
		return err
	}
	root := cardTS
	if responseThreadTS != "" {
		root = responseThreadTS
	}
	seen := make(map[string]bool, len(session.ThreadRoots)+1)
	roots := make([]string, 0, len(session.ThreadRoots)+1)
	for _, candidate := range append(session.ThreadRoots, root) {
		if candidate == "" || seen[candidate] {
			continue
		}
		seen[candidate] = true
		roots = append(roots, candidate)
	}
	data, err := json.Marshal(roots)
	if err != nil {
		return err
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE configuration_sessions
		SET card_ts = ?, response_thread_ts = ?, thread_roots_json = ?, updated_at = ?
		WHERE id = ? AND status IN ('asking', 'confirming')`,
		cardTS, responseThreadTS, data, s.nowText(), id,
	)
	return sqlutil.ExpectOne(result, err, "record configuration message location")
}

func (s *Store) AdvanceConfigurationSession(
	ctx context.Context,
	id string,
	expectedRevision int,
	step string,
	status string,
	draft core.ChannelConfiguration,
) (core.ConfigurationSession, error) {
	if status != "asking" && status != "confirming" {
		return core.ConfigurationSession{}, errors.New("configuration session can only advance while active")
	}
	data, err := json.Marshal(draft)
	if err != nil {
		return core.ConfigurationSession{}, err
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE configuration_sessions
		SET step = ?, status = ?, draft_json = ?, revision = revision + 1, updated_at = ?
		WHERE id = ? AND revision = ? AND status IN ('asking', 'confirming')
		  AND julianday(expires_at) > julianday(?)`,
		step, status, data, s.nowText(), id, expectedRevision, s.nowText(),
	)
	if err := sqlutil.ExpectOne(result, err, "advance configuration session"); err != nil {
		return core.ConfigurationSession{}, err
	}
	return s.GetConfigurationSession(ctx, id)
}

func (s *Store) FinishConfigurationSession(
	ctx context.Context,
	id string,
	expectedRevision int,
	status string,
) error {
	if status != "saved" && status != "cancelled" && status != "expired" {
		return errors.New("invalid terminal configuration status")
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE configuration_sessions
		SET status = ?, revision = revision + 1, updated_at = ?
		WHERE id = ? AND revision = ? AND status IN ('asking', 'confirming')`,
		status, s.nowText(), id, expectedRevision,
	)
	return sqlutil.ExpectOne(result, err, "finish configuration session")
}

func (s *Store) SaveChannelConfiguration(
	ctx context.Context,
	configuration core.ChannelConfiguration,
) (core.ChannelConfiguration, error) {
	if err := validateChannelConfiguration(configuration); err != nil {
		return core.ChannelConfiguration{}, err
	}
	users, err := json.Marshal(configuration.InviteUsers)
	if err != nil {
		return core.ChannelConfiguration{}, err
	}
	groups, err := json.Marshal(configuration.InviteUserGroups)
	if err != nil {
		return core.ChannelConfiguration{}, err
	}
	now := s.nowText()
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO channel_configurations (
		  channel_id, participation, repository, alert_policy,
		  invite_users_json, invite_user_groups_json, actor_id,
		  revision, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
		ON CONFLICT(channel_id) DO UPDATE SET
		  participation = excluded.participation,
		  repository = excluded.repository,
		  alert_policy = excluded.alert_policy,
		  invite_users_json = excluded.invite_users_json,
		  invite_user_groups_json = excluded.invite_user_groups_json,
		  actor_id = excluded.actor_id,
		  revision = channel_configurations.revision + 1,
		  updated_at = excluded.updated_at`,
		configuration.ChannelID, configuration.Participation, configuration.Repository,
		configuration.AlertPolicy, users, groups, configuration.ActorID, now, now,
	)
	if err != nil {
		return core.ChannelConfiguration{}, err
	}
	return s.GetChannelConfiguration(ctx, configuration.ChannelID)
}

func (s *Store) GetChannelConfiguration(
	ctx context.Context,
	channelID string,
) (core.ChannelConfiguration, error) {
	var configuration core.ChannelConfiguration
	var users, groups []byte
	var created, updated string
	err := s.db.QueryRowContext(ctx, `
		SELECT channel_id, participation, repository, alert_policy,
		  invite_users_json, invite_user_groups_json, actor_id,
		  revision, created_at, updated_at
		FROM channel_configurations WHERE channel_id = ?`,
		channelID,
	).Scan(
		&configuration.ChannelID, &configuration.Participation, &configuration.Repository,
		&configuration.AlertPolicy, &users, &groups, &configuration.ActorID,
		&configuration.Revision, &created, &updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.ChannelConfiguration{}, ErrNotFound
	}
	if err != nil {
		return core.ChannelConfiguration{}, err
	}
	if err := json.Unmarshal(users, &configuration.InviteUsers); err != nil {
		return core.ChannelConfiguration{}, fmt.Errorf("decode configured invite users: %w", err)
	}
	if err := json.Unmarshal(groups, &configuration.InviteUserGroups); err != nil {
		return core.ChannelConfiguration{}, fmt.Errorf("decode configured invite groups: %w", err)
	}
	configuration.CreatedAt = sqlutil.ParseTime(created)
	configuration.UpdatedAt = sqlutil.ParseTime(updated)
	return configuration, nil
}

// ListConfiguredChannelIDs returns the channels an operator has configured
// Responder into, newest decision first.
//
// This is the control plane. A deployment that onboards channels by inviting
// the bot and answering its questions has every one of them here and none of
// them in YAML, so anything that reads only the static file sees an empty
// workspace and behaves as though there is nothing to do.
func (s *Store) ListConfiguredChannelIDs(ctx context.Context, limit int) ([]string, error) {
	return channelIDRows(s.db.QueryContext(ctx, `
		SELECT channel_id
		FROM channel_configurations
		WHERE channel_id != ''
		ORDER BY updated_at DESC, channel_id
		LIMIT ?`, boundedChannelLimit(limit)))
}

// ListConfiguredChannelsMissingMembership returns channels an operator
// configured that the bot is not currently in.
//
// Each one is a coverage hole: the configuration says Responder is watching,
// and Slack says it cannot see the room. Alerts posted there reach nobody and
// nothing about the arrangement looks wrong from either side on its own.
func (s *Store) ListConfiguredChannelsMissingMembership(
	ctx context.Context,
	limit int,
) ([]string, error) {
	return channelIDRows(s.db.QueryContext(ctx, `
		SELECT configured.channel_id
		FROM channel_configurations AS configured
		LEFT JOIN slack_channel_memberships AS membership
		  ON membership.channel_id = configured.channel_id
		WHERE configured.channel_id != ''
		  AND (membership.channel_id IS NULL OR membership.present = 0)
		ORDER BY configured.channel_id
		LIMIT ?`, boundedChannelLimit(limit)))
}

// boundedChannelLimit and channelIDRows carry the shape every channel-ID query
// in this package repeats: clamp the caller's limit, then drain one string
// column. Four copies of the same fifteen lines were four chances to forget
// rows.Err(), which reports a truncated result as a complete one.
func boundedChannelLimit(limit int) int {
	if limit <= 0 || limit > 10000 {
		return 10000
	}
	return limit
}

func channelIDRows(rows *sql.Rows, err error) ([]string, error) {
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]string, 0, 64)
	for rows.Next() {
		var channelID string
		if err := rows.Scan(&channelID); err != nil {
			return nil, err
		}
		result = append(result, channelID)
	}
	return result, rows.Err()
}

func (s *Store) DeleteChannelConfigurationState(
	ctx context.Context,
	channelID string,
) (int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	var deleted int64
	for _, query := range []string{
		`DELETE FROM configuration_sessions WHERE channel_id = ?`,
		`DELETE FROM channel_configurations WHERE channel_id = ?`,
		`DELETE FROM slack_channel_memberships WHERE channel_id = ?`,
	} {
		result, err := tx.ExecContext(ctx, query, channelID)
		if err != nil {
			return 0, err
		}
		count, err := result.RowsAffected()
		if err != nil {
			return 0, err
		}
		deleted += count
	}
	return deleted, tx.Commit()
}

func scanConfigurationSession(row *sql.Row) (core.ConfigurationSession, error) {
	var session core.ConfigurationSession
	var draft, threadRoots []byte
	var expires, created, updated string
	err := row.Scan(
		&session.ID, &session.TeamID, &session.ChannelID, &session.ThreadTS,
		&session.CardTS, &session.ResponseThreadTS, &threadRoots, &session.Initiator,
		&session.Step, &session.Status, &draft, &session.Revision, &expires,
		&created, &updated,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.ConfigurationSession{}, ErrNotFound
	}
	if err != nil {
		return core.ConfigurationSession{}, err
	}
	if err := json.Unmarshal(draft, &session.Draft); err != nil {
		return core.ConfigurationSession{}, fmt.Errorf("decode configuration draft: %w", err)
	}
	if err := json.Unmarshal(threadRoots, &session.ThreadRoots); err != nil {
		return core.ConfigurationSession{}, fmt.Errorf("decode configuration thread roots: %w", err)
	}
	session.ExpiresAt = sqlutil.ParseTime(expires)
	session.CreatedAt = sqlutil.ParseTime(created)
	session.UpdatedAt = sqlutil.ParseTime(updated)
	return session, nil
}

func validateChannelConfiguration(configuration core.ChannelConfiguration) error {
	if configuration.ChannelID == "" || configuration.Repository == "" ||
		configuration.ActorID == "" {
		return errors.New("channel configuration identity fields are required")
	}
	if configuration.Participation != "mentions" &&
		configuration.Participation != "proactive" &&
		configuration.Participation != "shadow" {
		return errors.New("invalid channel participation mode")
	}
	if configuration.AlertPolicy != "reply" &&
		configuration.AlertPolicy != "offer" &&
		configuration.AlertPolicy != "automatic" {
		return errors.New("invalid channel alert policy")
	}
	if len(configuration.Repository) > 63 || len(configuration.ActorID) > 64 ||
		len(configuration.InviteUsers) > 100 || len(configuration.InviteUserGroups) > 100 {
		return errors.New("channel configuration exceeds its field limits")
	}
	for _, id := range append(
		append([]string(nil), configuration.InviteUsers...),
		configuration.InviteUserGroups...,
	) {
		if len(id) < 3 || len(id) > 32 || id[0] < 'A' || id[0] > 'Z' {
			return errors.New("channel configuration contains an invalid Slack ID")
		}
		for _, value := range id[1:] {
			if (value < 'A' || value > 'Z') && (value < '0' || value > '9') {
				return errors.New("channel configuration contains an invalid Slack ID")
			}
		}
	}
	return nil
}

func isUniqueConstraint(err error) bool {
	return err != nil && strings.Contains(strings.ToLower(err.Error()), "unique constraint")
}
