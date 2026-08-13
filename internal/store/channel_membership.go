package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

type SlackChannelMembershipObservation struct {
	ChannelID   string
	ChannelName string
	Private     bool
	Present     bool
}

type PendingSlackChannelOnboarding struct {
	ChannelID   string
	ChannelName string
	Private     bool
	JoinedAt    time.Time
}

type storedSlackChannelMembership struct {
	present        bool
	onboarding     string
	joinedAt       time.Time
	channelName    string
	private        bool
	wasObservedNow bool
}

// AdmitSlackChannelJoin records the direct Slack join signal and its durable
// setup input together. Marking onboarding complete here prevents the periodic
// membership fallback from queuing a duplicate card while the input is pending.
func (s *Store) AdmitSlackChannelJoin(
	ctx context.Context,
	input core.SlackInput,
) (bool, error) {
	if input.Kind != "channel_joined" || strings.TrimSpace(input.ChannelID) == "" {
		return false, errors.New("Slack channel join input is invalid")
	}
	observedAt := input.ReceivedAt
	if observedAt.IsZero() {
		observedAt = s.now().UTC()
	} else {
		observedAt = observedAt.UTC()
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	input.ReceivedAt = observedAt
	var semanticDuplicate int
	if err := tx.QueryRowContext(ctx, `
		SELECT EXISTS (
		  SELECT 1 FROM slack_inputs
		  WHERE kind = 'channel_joined' AND channel_id = ?
		    AND ABS((julianday(received_at) - julianday(?)) * 86400.0) <= 5
		)`,
		input.ChannelID, observedAt.Format(timestampFormat),
	).Scan(&semanticDuplicate); err != nil {
		return false, fmt.Errorf("deduplicate direct Slack channel join: %w", err)
	}
	created := false
	if semanticDuplicate == 0 {
		created, err = admitSlackInput(ctx, tx, input, "pending", 0, s.nowText())
		if err != nil {
			return false, err
		}
	}
	stamp := observedAt.Format(timestampFormat)
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO slack_channel_memberships (
		  channel_id, channel_name, private, present, onboarding_state, joined_at, observed_at
		) VALUES (?, '', 0, 1, 'complete', ?, ?)
		ON CONFLICT(channel_id) DO UPDATE SET
		  present = 1,
		  onboarding_state = 'complete',
		  joined_at = excluded.joined_at,
		  observed_at = excluded.observed_at`,
		input.ChannelID, stamp, stamp,
	); err != nil {
		return false, fmt.Errorf("record direct Slack channel join: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return created, nil
}

func (s *Store) ReconcileSlackChannelMemberships(
	ctx context.Context,
	observations []SlackChannelMembershipObservation,
	observedAt time.Time,
) error {
	if observedAt.IsZero() {
		observedAt = s.now().UTC()
	} else {
		observedAt = observedAt.UTC()
	}
	if len(observations) > 10000 {
		return errors.New("Slack channel membership observation is too large")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	existing, err := loadSlackChannelMemberships(ctx, tx)
	if err != nil {
		return err
	}
	for _, observation := range observations {
		channelID := strings.TrimSpace(observation.ChannelID)
		if channelID == "" || len(channelID) > 128 {
			return errors.New("Slack channel membership has an invalid channel ID")
		}
		current := existing[channelID]
		if current.wasObservedNow {
			return fmt.Errorf("Slack channel %s was observed more than once", channelID)
		}
		current.wasObservedNow = true
		current.channelName = strings.TrimSpace(observation.ChannelName)
		current.private = observation.Private
		if len(current.channelName) > 256 {
			return fmt.Errorf("Slack channel %s has an invalid name", channelID)
		}
		if observation.Present && !current.present {
			current.onboarding = "pending"
			current.joinedAt = observedAt
		}
		if !observation.Present {
			current.onboarding = "complete"
			current.joinedAt = time.Time{}
		}
		current.present = observation.Present
		existing[channelID] = current
		if err := upsertSlackChannelMembership(ctx, tx, channelID, current, observedAt); err != nil {
			return err
		}
	}
	for channelID, current := range existing {
		if current.wasObservedNow || !current.present {
			continue
		}
		current.present = false
		current.onboarding = "complete"
		current.joinedAt = time.Time{}
		if err := upsertSlackChannelMembership(ctx, tx, channelID, current, observedAt); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func loadSlackChannelMemberships(
	ctx context.Context,
	tx *sql.Tx,
) (map[string]storedSlackChannelMembership, error) {
	rows, err := tx.QueryContext(ctx, `
		SELECT channel_id, channel_name, private, present, onboarding_state, joined_at
		FROM slack_channel_memberships`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make(map[string]storedSlackChannelMembership)
	for rows.Next() {
		var channelID, channelName, onboarding string
		var private, present int
		var joinedAt sql.NullString
		if err := rows.Scan(
			&channelID, &channelName, &private, &present, &onboarding, &joinedAt,
		); err != nil {
			return nil, err
		}
		result[channelID] = storedSlackChannelMembership{
			present: present != 0, onboarding: onboarding,
			joinedAt: parseNullableTime(joinedAt), channelName: channelName,
			private: private != 0,
		}
	}
	return result, rows.Err()
}

func upsertSlackChannelMembership(
	ctx context.Context,
	tx *sql.Tx,
	channelID string,
	membership storedSlackChannelMembership,
	observedAt time.Time,
) error {
	var joinedAt any
	if !membership.joinedAt.IsZero() {
		joinedAt = membership.joinedAt.Format(timestampFormat)
	}
	_, err := tx.ExecContext(ctx, `
		INSERT INTO slack_channel_memberships (
		  channel_id, channel_name, private, present, onboarding_state, joined_at, observed_at
		) VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(channel_id) DO UPDATE SET
		  channel_name = excluded.channel_name,
		  private = excluded.private,
		  present = excluded.present,
		  onboarding_state = excluded.onboarding_state,
		  joined_at = excluded.joined_at,
		  observed_at = excluded.observed_at`,
		channelID, membership.channelName, boolInt(membership.private),
		boolInt(membership.present), membership.onboarding, joinedAt,
		observedAt.Format(timestampFormat),
	)
	return err
}

func (s *Store) ListPendingSlackChannelOnboarding(
	ctx context.Context,
	limit int,
) ([]PendingSlackChannelOnboarding, error) {
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT channel_id, channel_name, private, joined_at
		FROM slack_channel_memberships
		WHERE present = 1 AND onboarding_state = 'pending' AND joined_at IS NOT NULL
		ORDER BY joined_at, channel_id
		LIMIT ?`,
		limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []PendingSlackChannelOnboarding
	for rows.Next() {
		var item PendingSlackChannelOnboarding
		var private int
		var joinedAt string
		if err := rows.Scan(&item.ChannelID, &item.ChannelName, &private, &joinedAt); err != nil {
			return nil, err
		}
		item.Private = private != 0
		item.JoinedAt = sqlutil.ParseTime(joinedAt)
		result = append(result, item)
	}
	return result, rows.Err()
}

func (s *Store) ListPresentSlackChannelIDs(ctx context.Context, limit int) ([]string, error) {
	return channelIDRows(s.db.QueryContext(ctx, `
		SELECT channel_id
		FROM slack_channel_memberships
		WHERE present = 1
		ORDER BY channel_id
		LIMIT ?`, boundedChannelLimit(limit)))
}

// SlackChannelName is the readable name of one channel, empty when Responder
// has never seen it. An id tells a model a transcript came from somewhere else
// and not where; the name is the part a person can check.
func (s *Store) SlackChannelName(ctx context.Context, channelID string) (string, error) {
	var name string
	err := s.db.QueryRowContext(ctx,
		`SELECT channel_name FROM slack_channel_memberships WHERE channel_id = ?`,
		strings.TrimSpace(channelID),
	).Scan(&name)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return name, err
}

func (s *Store) FinishSlackChannelOnboarding(
	ctx context.Context,
	channelID string,
	joinedAt time.Time,
) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE slack_channel_memberships
		SET onboarding_state = 'complete', observed_at = ?
		WHERE channel_id = ? AND present = 1 AND onboarding_state = 'pending'
		  AND joined_at = ?`,
		s.nowText(), channelID, joinedAt.UTC().Format(timestampFormat),
	)
	return sqlutil.ExpectOne(result, err, "finish Slack channel onboarding")
}

func parseNullableTime(value sql.NullString) time.Time {
	if !value.Valid {
		return time.Time{}
	}
	return sqlutil.ParseTime(value.String)
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}
