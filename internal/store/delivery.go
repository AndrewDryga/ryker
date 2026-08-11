package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

const slackDeliveryColumns = `
	id, COALESCE(incident_id, ''), episode_id, expected_episode_revision,
	expected_destination_revision, operation, kind, channel_id, thread_ts,
	message_ts, body_json, status_text, steps_json, coalesce_key, card_version,
	sequence_key, sequence_index, state, failure_count, next_attempt_at, last_error, created_at`

func (s *Store) NextSlackStatusGeneration(
	ctx context.Context,
	channelID string,
	threadTS string,
) (int64, error) {
	if channelID == "" || threadTS == "" {
		return 0, errors.New("Slack status generation target is required")
	}
	var generation int64
	err := s.db.QueryRowContext(ctx, `
		INSERT INTO slack_status_generations (
		  channel_id, thread_ts, generation, updated_at
		)
		VALUES (?, ?, 1, ?)
		ON CONFLICT(channel_id, thread_ts) DO UPDATE SET
		  generation = slack_status_generations.generation + 1,
		  updated_at = excluded.updated_at
		RETURNING generation`,
		channelID,
		threadTS,
		s.nowText(),
	).Scan(&generation)
	if err != nil {
		return 0, fmt.Errorf("advance Slack status generation: %w", err)
	}
	return generation, nil
}

func (s *Store) EnqueueSlackDelivery(
	ctx context.Context,
	delivery core.SlackDelivery,
) (bool, error) {
	if delivery.Operation == "" {
		delivery.Operation = "post"
	}
	if delivery.Operation != "post" && delivery.Operation != "update" &&
		delivery.Operation != "status" && delivery.Operation != "file" {
		return false, fmt.Errorf(
			"unsupported Slack delivery operation %q",
			delivery.Operation,
		)
	}
	if delivery.ChannelID == "" {
		return false, errors.New("Slack delivery channel is required")
	}
	if (delivery.Operation == "post" || delivery.Operation == "file") && len(delivery.Body) == 0 {
		return false, errors.New("Slack post delivery body is required")
	}
	if delivery.Operation == "update" &&
		(delivery.MessageTS == "" || len(delivery.Body) == 0) {
		return false, errors.New("Slack update delivery target and body are required")
	}
	if delivery.Operation == "status" && delivery.ThreadTS == "" {
		return false, errors.New("Slack status delivery thread is required")
	}
	if delivery.Body == nil {
		delivery.Body = []byte{}
	}
	if delivery.ID == "" {
		var err error
		delivery.ID, err = core.NewID("delivery")
		if err != nil {
			return false, err
		}
	}
	steps, err := json.Marshal(delivery.Steps)
	if err != nil {
		return false, fmt.Errorf("encode Slack delivery steps: %w", err)
	}
	if string(steps) == "null" || len(steps) == 0 {
		steps = []byte("[]")
	}
	var incidentID any
	if delivery.IncidentID != "" {
		incidentID = delivery.IncidentID
	}
	sequenceKey, sequenceIndex := slackDeliverySequence(delivery.ID)
	now := s.nowText()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	if delivery.EpisodeID != "" {
		episode, episodeErr := scanWorkEpisode(tx.QueryRowContext(
			ctx, `SELECT `+workEpisodeColumns+` FROM work_episodes WHERE id = ?`,
			delivery.EpisodeID,
		))
		if episodeErr != nil {
			return false, episodeErr
		}
		if delivery.ExpectedDestinationRevision == 0 {
			delivery.ExpectedDestinationRevision = episode.DestinationRevision
		}
		// A native status is a processing indicator on the source Slack
		// conversation. It belongs to the episode trace, but it does not choose
		// where the final answer is delivered. A request may deliberately move
		// the answer from a thread back to the channel while the indicator stays
		// on the message being processed.
		if delivery.Operation != "status" &&
			(delivery.ExpectedDestinationRevision != episode.DestinationRevision ||
				delivery.ChannelID != episode.Destination.ChannelID ||
				delivery.ThreadTS != episode.Destination.ThreadTS) {
			return false, errors.New("Slack delivery destination does not match the current episode binding")
		}
	}
	if delivery.CoalesceKey != "" && delivery.CardVersion > 0 {
		var newest int64
		if err := tx.QueryRowContext(ctx, `
			SELECT COALESCE(MAX(card_version), 0)
			FROM slack_deliveries
			WHERE coalesce_key = ? AND card_version > 0
			  AND state IN ('pending', 'sending', 'retry', 'uncertain', 'sent')`,
			delivery.CoalesceKey,
		).Scan(&newest); err != nil {
			return false, err
		}
		if newest >= delivery.CardVersion {
			if err := tx.Commit(); err != nil {
				return false, err
			}
			return false, nil
		}
	}
	result, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO slack_deliveries (
		  id, incident_id, episode_id, expected_episode_revision,
		  expected_destination_revision, operation, kind, channel_id, thread_ts, message_ts,
		  body_json, status_text, steps_json, coalesce_key, card_version,
		  sequence_key, sequence_index, state, next_attempt_at, created_at, updated_at
		)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)`,
		delivery.ID, incidentID, delivery.EpisodeID, delivery.ExpectedEpisodeRevision,
		delivery.ExpectedDestinationRevision, delivery.Operation, delivery.Kind,
		delivery.ChannelID, delivery.ThreadTS, delivery.MessageTS, delivery.Body,
		delivery.Status, steps, delivery.CoalesceKey, delivery.CardVersion,
		sequenceKey, sequenceIndex,
		now, now, now)
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	if rows == 1 && delivery.CoalesceKey != "" {
		if _, err := tx.ExecContext(ctx, `
			UPDATE slack_deliveries
			SET state = 'superseded', updated_at = ?
			WHERE coalesce_key = ? AND id != ?
			  AND state IN ('pending', 'retry')
			  AND (? = 0 OR card_version <= ?)
			  AND NOT (
			    ? = 'status' AND ? = '' AND
			    operation = 'status' AND status_text != ''
			  )`,
			now,
			delivery.CoalesceKey,
			delivery.ID,
			delivery.CardVersion,
			delivery.CardVersion,
			delivery.Operation,
			delivery.Status,
		); err != nil {
			return false, err
		}
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return rows == 1, nil
}

func scanSlackDelivery(
	row interface{ Scan(...any) error },
) (core.SlackDelivery, error) {
	var delivery core.SlackDelivery
	var steps []byte
	var sequenceKey string
	var sequenceIndex int
	var next, created string
	err := row.Scan(
		&delivery.ID, &delivery.IncidentID, &delivery.EpisodeID,
		&delivery.ExpectedEpisodeRevision, &delivery.ExpectedDestinationRevision,
		&delivery.Operation, &delivery.Kind,
		&delivery.ChannelID, &delivery.ThreadTS, &delivery.MessageTS,
		&delivery.Body, &delivery.Status, &steps, &delivery.CoalesceKey,
		&delivery.CardVersion, &sequenceKey, &sequenceIndex,
		&delivery.State, &delivery.Attempts, &next,
		&delivery.LastError, &created,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.SlackDelivery{}, ErrNotFound
	}
	if err != nil {
		return core.SlackDelivery{}, err
	}
	if len(steps) > 0 {
		if err := json.Unmarshal(steps, &delivery.Steps); err != nil {
			return core.SlackDelivery{}, fmt.Errorf(
				"decode Slack delivery steps: %w",
				err,
			)
		}
	}
	delivery.NextAttemptAt = sqlutil.ParseTime(next)
	delivery.CreatedAt = sqlutil.ParseTime(created)
	return delivery, nil
}

func (s *Store) GetSlackDelivery(
	ctx context.Context,
	id string,
) (core.SlackDelivery, error) {
	if id == "" {
		return core.SlackDelivery{}, errors.New("Slack delivery ID is required")
	}
	return scanSlackDelivery(s.db.QueryRowContext(ctx, `
		SELECT `+slackDeliveryColumns+`
		FROM slack_deliveries
		WHERE id = ?`,
		id,
	))
}

// ListSlackDeliveriesByPrefix returns every delivery produced by one
// deterministic reply key, including multipart messages and generated files.
func (s *Store) ListSlackDeliveriesByPrefix(
	ctx context.Context,
	prefix string,
) ([]core.SlackDelivery, error) {
	if prefix == "" {
		return nil, errors.New("Slack delivery prefix is required")
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+slackDeliveryColumns+`
		FROM slack_deliveries
		WHERE substr(id, 1, length(?)) = ?
		ORDER BY created_at, id`, prefix, prefix)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.SlackDelivery, 0)
	for rows.Next() {
		delivery, err := scanSlackDelivery(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, delivery)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return result, nil
}

func (s *Store) RetryLatestGeneratedVisual(
	ctx context.Context,
	channelID string,
	threadTS string,
) (core.SlackDelivery, error) {
	if channelID == "" {
		return core.SlackDelivery{}, errors.New("Slack visual retry channel is required")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.SlackDelivery{}, err
	}
	defer tx.Rollback()
	delivery, err := scanSlackDelivery(tx.QueryRowContext(ctx, `
		SELECT `+slackDeliveryColumns+`
		FROM slack_deliveries
		WHERE operation = 'file'
		  AND kind = 'generated_visual'
		  AND channel_id = ?
		  AND thread_ts = ?
		  AND state IN ('pending', 'retry', 'failed')
		ORDER BY created_at DESC, id DESC
		LIMIT 1`,
		channelID,
		threadTS,
	))
	if err != nil {
		return core.SlackDelivery{}, err
	}
	now := s.nowText()
	result, err := tx.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = 'retry', failure_count = 0, next_attempt_at = ?,
		    last_error = '', updated_at = ?
		WHERE id = ? AND state = ?`,
		now,
		now,
		delivery.ID,
		delivery.State,
	)
	if err := sqlutil.ExpectOne(result, err, "retry retained Slack visual"); err != nil {
		return core.SlackDelivery{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.SlackDelivery{}, err
	}
	delivery.State = "retry"
	delivery.Attempts = 0
	delivery.NextAttemptAt = sqlutil.ParseTime(now)
	delivery.LastError = ""
	return delivery, nil
}

func (s *Store) GetLatestSentSlackMessageDelivery(
	ctx context.Context,
	incidentID string,
	channelID string,
	messageTS string,
) (core.SlackDelivery, error) {
	if incidentID == "" || channelID == "" || messageTS == "" {
		return core.SlackDelivery{}, errors.New(
			"Slack message delivery incident, channel, and timestamp are required",
		)
	}
	return scanSlackDelivery(s.db.QueryRowContext(ctx, `
		SELECT `+slackDeliveryColumns+`
		FROM slack_deliveries
		WHERE incident_id = ?
		  AND channel_id = ?
		  AND message_ts = ?
		  AND state = 'sent'
		  AND operation IN ('post', 'update')
		ORDER BY updated_at DESC, created_at DESC, id DESC
		LIMIT 1`,
		incidentID,
		channelID,
		messageTS,
	))
}

func (s *Store) GetSentSlackMessageDelivery(
	ctx context.Context,
	channelID string,
	messageTS string,
) (core.SlackDelivery, error) {
	if channelID == "" || messageTS == "" {
		return core.SlackDelivery{}, errors.New(
			"Slack message delivery channel and timestamp are required",
		)
	}
	return scanSlackDelivery(s.db.QueryRowContext(ctx, `
		SELECT `+slackDeliveryColumns+`
		FROM slack_deliveries
		WHERE channel_id = ?
		  AND message_ts = ?
		  AND state = 'sent'
		  AND operation IN ('post', 'update')
		ORDER BY updated_at DESC, created_at DESC, id DESC
		LIMIT 1`,
		channelID,
		messageTS,
	))
}

// LeaseSlackDelivery claims the next Slack write.
//
// coolingChannels are channels whose pacing slot has not reopened. Skipping
// them rather than waiting is what lets a busy channel stop holding up every
// other conversation: Slack rate-limits chat.postMessage per channel, so two
// different channels can be written at once even though one channel cannot.
func (s *Store) LeaseSlackDelivery(
	ctx context.Context,
	coolingChannels []string,
) (core.SlackDelivery, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.SlackDelivery{}, err
	}
	defer tx.Rollback()
	now := s.nowText()
	if _, err := tx.ExecContext(ctx, `
		UPDATE slack_deliveries AS delivery
		SET state = 'superseded', last_error = 'episode destination changed', updated_at = ?
		WHERE delivery.state IN ('pending', 'retry')
		  AND delivery.episode_id != ''
		  AND delivery.operation != 'status'
		  AND EXISTS (
		    SELECT 1 FROM work_episodes AS episode
		    WHERE episode.id = delivery.episode_id
		      AND (
		        delivery.expected_destination_revision != episode.destination_revision OR
		        delivery.channel_id != episode.destination_channel_id OR
		        delivery.thread_ts != episode.destination_thread_ts OR
		        (delivery.expected_episode_revision > 0 AND
		         delivery.expected_episode_revision != episode.event_sequence)
		      )
		  )`, now); err != nil {
		return core.SlackDelivery{}, err
	}
	skip := ""
	arguments := []any{now}
	if len(coolingChannels) > 0 {
		skip = "  AND candidate.channel_id NOT IN (" +
			strings.TrimSuffix(strings.Repeat("?,", len(coolingChannels)), ",") + ")\n"
		for _, channelID := range coolingChannels {
			arguments = append(arguments, channelID)
		}
	}
	delivery, err := scanSlackDelivery(tx.QueryRowContext(ctx, `
		SELECT `+slackDeliveryColumns+`
		FROM slack_deliveries AS candidate
		WHERE candidate.state IN ('pending', 'retry')
		  AND julianday(candidate.next_attempt_at) <= julianday(?)
`+skip+`		  AND (
		    candidate.sequence_key = '' OR NOT EXISTS (
		      SELECT 1
		      FROM slack_deliveries AS predecessor
		      WHERE predecessor.sequence_key = candidate.sequence_key
		        AND predecessor.sequence_index < candidate.sequence_index
		        AND predecessor.state NOT IN ('sent', 'superseded')
		    )
		  )
		ORDER BY
		  CASE candidate.operation WHEN 'status' THEN 0 WHEN 'update' THEN 1 ELSE 2 END,
		  candidate.created_at,
		  candidate.id
		LIMIT 1`, arguments...))
	if errors.Is(err, ErrNotFound) {
		if commitErr := tx.Commit(); commitErr != nil {
			return core.SlackDelivery{}, commitErr
		}
		return core.SlackDelivery{}, ErrNotFound
	}
	if err != nil {
		return core.SlackDelivery{}, err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = 'sending', updated_at = ?
		WHERE id = ? AND state IN ('pending', 'retry')`,
		now, delivery.ID)
	if err := sqlutil.ExpectOne(result, err, "lease Slack delivery"); err != nil {
		return core.SlackDelivery{}, err
	}
	if err := tx.Commit(); err != nil {
		return core.SlackDelivery{}, err
	}
	delivery.State = "sending"
	return delivery, nil
}

func slackDeliverySequence(id string) (string, int) {
	const marker = "_part_"
	index := strings.LastIndex(id, marker)
	if index <= 0 || len(id[index+len(marker):]) != 3 {
		return "", 0
	}
	sequence, err := strconv.Atoi(id[index+len(marker):])
	if err != nil || sequence <= 0 {
		return "", 0
	}
	return id[:index], sequence
}

func (s *Store) FinishSlackDelivery(
	ctx context.Context,
	id string,
	messageTS string,
	fromState string,
) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var incidentID sql.NullString
	var kind string
	var cardVersion int64
	if err := tx.QueryRowContext(ctx, `
		SELECT incident_id, kind, card_version
		FROM slack_deliveries
		WHERE id = ? AND state = ?`,
		id, fromState).Scan(&incidentID, &kind, &cardVersion); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("finish Slack delivery: %w", ErrConflict)
		}
		return err
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = 'sent', message_ts = CASE WHEN ? = '' THEN message_ts ELSE ? END,
		    last_error = '', updated_at = ?
		WHERE id = ? AND state = ?`,
		messageTS, messageTS, s.nowText(), id, fromState)
	if err := sqlutil.ExpectOne(result, err, "finish Slack delivery"); err != nil {
		return err
	}
	if incidentID.Valid && kind == "root" {
		result, err = tx.ExecContext(ctx, `
			UPDATE incidents
			SET root_ts = ?, workflow = 'provisioning_session',
			    updated_at = ?, card_version = card_version + 1, last_error = ''
			WHERE id = ? AND channel_id != '' AND root_ts = ''`,
			messageTS, s.nowText(), incidentID.String)
		if err := sqlutil.ExpectOne(result, err, "bind incident root"); err != nil {
			return err
		}
	}
	if incidentID.Valid && kind == "card" && cardVersion > 0 {
		if _, err := tx.ExecContext(ctx, `
			UPDATE incidents
			SET card_rendered_version = MAX(card_rendered_version, ?), updated_at = ?
			WHERE id = ?`,
			cardVersion, s.nowText(), incidentID.String); err != nil {
			return err
		}
	}
	if messageTS != "" {
		if _, err := tx.ExecContext(ctx, `
			UPDATE emisar_approvals
			SET message_ts = ?, updated_at = ?
			WHERE delivery_id = ? AND message_ts = ''`,
			messageTS,
			s.nowText(),
			id,
		); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) RetrySlackDelivery(
	ctx context.Context,
	id string,
	detail string,
	next time.Time,
	uncertain bool,
	terminal bool,
) error {
	state := "retry"
	if uncertain {
		state = "uncertain"
	} else if terminal {
		state = "failed"
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = ?, failure_count = failure_count + 1,
		    last_error = ?, next_attempt_at = ?, updated_at = ?
		WHERE id = ? AND state = 'sending'`,
		state, sqlutil.BoundedError(detail), next.UTC().Format(timestampFormat),
		s.nowText(), id)
	return sqlutil.ExpectOne(result, err, "retry Slack delivery")
}

func (s *Store) ListUncertainSlackDeliveries(
	ctx context.Context,
	limit int,
) ([]core.SlackDelivery, error) {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+slackDeliveryColumns+`
		FROM slack_deliveries
		WHERE state = 'uncertain' AND operation IN ('post', 'file')
		  AND julianday(next_attempt_at) <= julianday(?)
		ORDER BY created_at, id
		LIMIT ?`, s.nowText(), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.SlackDelivery, 0)
	for rows.Next() {
		delivery, err := scanSlackDelivery(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, delivery)
	}
	return result, rows.Err()
}

func (s *Store) RetryUncertainSlackDelivery(
	ctx context.Context,
	id string,
	detail string,
	next time.Time,
	terminal bool,
) error {
	state := "retry"
	if terminal {
		state = "failed"
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = ?, failure_count = failure_count + 1,
		    last_error = ?, next_attempt_at = ?, updated_at = ?
		WHERE id = ? AND state = 'uncertain'`,
		state, sqlutil.BoundedError(detail), next.UTC().Format(timestampFormat),
		s.nowText(), id)
	return sqlutil.ExpectOne(result, err, "retry uncertain Slack delivery")
}
