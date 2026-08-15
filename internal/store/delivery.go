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
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

const slackDeliveryColumns = `
	id, COALESCE(incident_id, ''), episode_id, agent_run_id, agent_run_key, source_input_id, expected_episode_revision,
	expected_destination_revision, operation, kind, channel_id, thread_ts,
	message_ts, body_json, status_text, steps_json, coalesce_key, card_version,
	sequence_key, sequence_index, response_root, state, failure_count, next_attempt_at, last_error, created_at`

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
		delivery.Operation != "status" && delivery.Operation != "file" &&
		delivery.Operation != "reaction" {
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
	if delivery.Operation == "reaction" &&
		(delivery.MessageTS == "" || delivery.Status == "" ||
			(delivery.Kind != "failure_marker_add" && delivery.Kind != "failure_marker_remove")) {
		return false, errors.New("Slack reaction delivery target, reaction, and action are required")
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
		if delivery.Operation != "status" && delivery.Operation != "reaction" &&
			(delivery.ExpectedDestinationRevision != episode.DestinationRevision ||
				delivery.ChannelID != episode.Destination.ChannelID ||
				delivery.ThreadTS != episode.Destination.ThreadTS) {
			return false, errors.New("Slack delivery destination does not match the current episode binding")
		}
	}
	if delivery.AgentRunID == "" && delivery.EpisodeID != "" {
		_ = tx.QueryRowContext(ctx, `
			SELECT id, idempotency_key, source_id FROM agent_runs
			WHERE episode_id = ? AND state = 'finalizing'
			ORDER BY updated_at DESC, id DESC LIMIT 1`, delivery.EpisodeID,
		).Scan(&delivery.AgentRunID, &delivery.AgentRunKey, &delivery.SourceInputID)
	}
	if delivery.AgentRunID == "" && delivery.SourceInputID != "" {
		_ = tx.QueryRowContext(ctx, `
			SELECT id FROM agent_runs
			WHERE source_kind = 'watch' AND source_id = ?
			ORDER BY created_at DESC, id DESC LIMIT 1`, delivery.SourceInputID,
		).Scan(&delivery.AgentRunID)
	}
	if delivery.SourceInputID == "" && delivery.AgentRunID != "" {
		_ = tx.QueryRowContext(ctx,
			`SELECT source_id, idempotency_key FROM agent_runs WHERE id = ?`,
			delivery.AgentRunID).Scan(&delivery.SourceInputID, &delivery.AgentRunKey)
	} else if delivery.AgentRunID != "" && delivery.AgentRunKey == "" {
		_ = tx.QueryRowContext(ctx, `SELECT idempotency_key FROM agent_runs WHERE id = ?`,
			delivery.AgentRunID).Scan(&delivery.AgentRunKey)
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
		  id, incident_id, episode_id, agent_run_id, agent_run_key, source_input_id, expected_episode_revision,
		  expected_destination_revision, operation, kind, channel_id, thread_ts, message_ts,
		  body_json, status_text, steps_json, coalesce_key, card_version,
		  sequence_key, sequence_index, response_root, state, next_attempt_at, created_at, updated_at
		)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)`,
		delivery.ID, incidentID, delivery.EpisodeID, delivery.AgentRunID,
		delivery.AgentRunKey, delivery.SourceInputID, delivery.ExpectedEpisodeRevision,
		delivery.ExpectedDestinationRevision, delivery.Operation, delivery.Kind,
		delivery.ChannelID, delivery.ThreadTS, delivery.MessageTS, delivery.Body,
		delivery.Status, steps, delivery.CoalesceKey, delivery.CardVersion,
		sequenceKey, sequenceIndex,
		boolInt(delivery.ResponseRoot),
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

// insertTerminalSlackDeliveryTx is the deliberately small outbox seam used by
// terminal agent finalization. It omits coalescing because terminal notices
// have deterministic IDs, but preserves episode destination fencing and the
// same durable delivery shape as the ordinary enqueue path.
func (s *Store) insertTerminalSlackDeliveryTx(
	ctx context.Context,
	tx *sql.Tx,
	delivery core.SlackDelivery,
	now string,
) error {
	if delivery.ID == "" || delivery.ChannelID == "" ||
		(delivery.Operation != "status" && delivery.Operation != "reaction" && len(delivery.Body) == 0) ||
		(delivery.Operation == "reaction" && (delivery.MessageTS == "" || delivery.Status == "")) {
		return errors.New("terminal Slack delivery identity, destination, and body are required")
	}
	if delivery.Operation == "" {
		delivery.Operation = "post"
	}
	if delivery.Kind == "" {
		delivery.Kind = "notice"
	}
	if delivery.Body == nil {
		delivery.Body = []byte{}
	}
	if delivery.EpisodeID != "" {
		var channelID, threadTS string
		if err := tx.QueryRowContext(ctx, `
			SELECT destination_channel_id, destination_thread_ts,
			       destination_revision, event_sequence
			FROM work_episodes WHERE id = ?`, delivery.EpisodeID,
		).Scan(&channelID, &threadTS, &delivery.ExpectedDestinationRevision,
			&delivery.ExpectedEpisodeRevision); err != nil {
			return err
		}
		if channelID != "" && delivery.Operation != "reaction" {
			delivery.ChannelID, delivery.ThreadTS = channelID, threadTS
		}
	}
	if delivery.AgentRunID != "" && delivery.AgentRunKey == "" {
		if err := tx.QueryRowContext(ctx,
			`SELECT idempotency_key FROM agent_runs WHERE id = ?`, delivery.AgentRunID,
		).Scan(&delivery.AgentRunKey); err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
	}
	sequenceKey, sequenceIndex := slackDeliverySequence(delivery.ID)
	var incidentID any
	if delivery.IncidentID != "" {
		incidentID = delivery.IncidentID
	}
	_, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO slack_deliveries (
		  id, incident_id, episode_id, agent_run_id, agent_run_key, source_input_id,
		  expected_episode_revision, expected_destination_revision,
		  operation, kind, channel_id, thread_ts, message_ts, body_json,
		  status_text, steps_json, coalesce_key, card_version,
		  sequence_key, sequence_index, response_root,
		  state, next_attempt_at, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '[]', ?, ?,
		          ?, ?, ?, 'pending', ?, ?, ?)`,
		delivery.ID, incidentID, delivery.EpisodeID,
		delivery.AgentRunID, delivery.AgentRunKey, delivery.SourceInputID, delivery.ExpectedEpisodeRevision,
		delivery.ExpectedDestinationRevision, delivery.Operation, delivery.Kind,
		delivery.ChannelID, delivery.ThreadTS, delivery.MessageTS, delivery.Body, delivery.Status,
		delivery.CoalesceKey, delivery.CardVersion,
		sequenceKey, sequenceIndex, boolInt(delivery.ResponseRoot), now, now, now,
	)
	return err
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
		&delivery.AgentRunID, &delivery.AgentRunKey, &delivery.SourceInputID,
		&delivery.ExpectedEpisodeRevision, &delivery.ExpectedDestinationRevision,
		&delivery.Operation, &delivery.Kind,
		&delivery.ChannelID, &delivery.ThreadTS, &delivery.MessageTS,
		&delivery.Body, &delivery.Status, &steps, &delivery.CoalesceKey,
		&delivery.CardVersion, &sequenceKey, &sequenceIndex, &delivery.ResponseRoot,
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
		  AND (state IN ('pending', 'retry', 'failed') OR
		       (state = 'superseded' AND last_error = 'replaced by upload failure notice'))
		ORDER BY created_at DESC, id DESC
		LIMIT 1`,
		channelID,
		threadTS,
	))
	if err != nil {
		return core.SlackDelivery{}, err
	}
	if sequenceKey, _ := slackDeliverySequence(delivery.ID); sequenceKey != "" {
		earliest, earliestErr := scanSlackDelivery(tx.QueryRowContext(ctx, `
			SELECT `+slackDeliveryColumns+`
			FROM slack_deliveries
			WHERE sequence_key = ? AND operation = 'file'
			  AND kind = 'generated_visual'
			  AND (state = 'failed' OR
			       (state = 'superseded' AND last_error = 'replaced by upload failure notice'))
			ORDER BY sequence_index, created_at, id LIMIT 1`, sequenceKey))
		if earliestErr == nil {
			delivery = earliest
		} else if !errors.Is(earliestErr, ErrNotFound) {
			return core.SlackDelivery{}, earliestErr
		}
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
		  AND operation IN ('post', 'update', 'file')
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
		  AND operation IN ('post', 'update', 'file')
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
	// A human correction becomes authoritative when its input is admitted, not
	// later when the control lane happens to create an agent run. Enforce that
	// boundary at the outbox lease so a result cannot pass an earlier service
	// check and then race a newly durable correction into Slack.
	if _, err := tx.ExecContext(ctx, `
		UPDATE slack_deliveries AS delivery
		SET state = 'superseded', last_error = 'newer human turn admitted', updated_at = ?
		WHERE delivery.state IN ('pending', 'retry')
		  AND delivery.source_input_id != ''
		  AND EXISTS (
		    SELECT 1
		    FROM slack_inputs AS source
		    JOIN slack_inputs AS newer
		      ON newer.id != source.id
		     AND newer.channel_id = source.channel_id
		     AND COALESCE(NULLIF(newer.thread_ts, ''), newer.message_ts) =
		         COALESCE(NULLIF(source.thread_ts, ''), source.message_ts)
		     AND newer.kind IN ('message', 'mention', 'direct')
		     AND (
		       CAST(newer.message_ts AS REAL) > CAST(source.message_ts AS REAL) OR
		       (newer.message_ts = source.message_ts AND newer.rowid > source.rowid)
		     )
		    WHERE source.id = delivery.source_input_id
		  )`, now); err != nil {
		return core.SlackDelivery{}, err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE slack_deliveries AS delivery
		SET state = 'superseded', last_error = 'newer reaction intent', updated_at = ?
		WHERE delivery.state IN ('pending', 'retry')
		  AND delivery.operation = 'reaction' AND delivery.coalesce_key != ''
		  AND EXISTS (
		    SELECT 1 FROM slack_deliveries AS newer
		    WHERE newer.coalesce_key = delivery.coalesce_key
		      AND newer.operation = 'reaction'
		      AND (newer.created_at > delivery.created_at OR
		           (newer.created_at = delivery.created_at AND newer.rowid > delivery.rowid))
		  )`, now); err != nil {
		return core.SlackDelivery{}, err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE slack_deliveries AS delivery
		SET state = 'superseded', last_error = 'episode destination changed', updated_at = ?
		WHERE delivery.state IN ('pending', 'retry')
		  AND delivery.episode_id != ''
		  AND delivery.operation NOT IN ('status', 'reaction')
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
		skip = "  AND (candidate.operation = 'reaction' OR candidate.channel_id NOT IN (" +
			strings.TrimSuffix(strings.Repeat("?,", len(coolingChannels)), ",") + "))\n"
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
		    candidate.operation != 'reaction' OR candidate.coalesce_key = '' OR NOT EXISTS (
		      SELECT 1 FROM slack_deliveries AS active_reaction
		      WHERE active_reaction.coalesce_key = candidate.coalesce_key
		        AND active_reaction.id != candidate.id AND active_reaction.state = 'sending'
		    )
		  )
		  AND (
		    candidate.sequence_key = '' OR NOT EXISTS (
		      SELECT 1
		      FROM slack_deliveries AS predecessor
		      WHERE predecessor.sequence_key = candidate.sequence_key
		        AND predecessor.sequence_index < candidate.sequence_index
		        AND predecessor.state NOT IN ('sent', 'superseded')
		    )
		  )
		ORDER BY
		  CASE candidate.operation WHEN 'status' THEN 0 WHEN 'reaction' THEN 1 WHEN 'update' THEN 2 ELSE 3 END,
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
	id = strings.TrimSuffix(id, "_upload_failed")
	visualAt := strings.LastIndex(id, "_visual_")
	if visualAt > 0 && len(id[visualAt+len("_visual_"):]) == 2 {
		visual, err := strconv.Atoi(id[visualAt+len("_visual_"):])
		if err == nil && visual > 0 {
			key := id[:visualAt]
			// Multipart results attach visuals to their synthetic final part. Keep
			// those files in the original text sequence so a retrying text part
			// cannot be overtaken by a file that creates the reply thread.
			if partAt := strings.LastIndex(key, "_part_"); partAt > 0 &&
				len(key[partAt+len("_part_"):]) == 3 {
				if part, partErr := strconv.Atoi(key[partAt+len("_part_"):]); partErr == nil {
					return key[:partAt], part*1000 + visual
				}
			}
			return key, visual
		}
	}
	partAt := strings.LastIndex(id, "_part_")
	if partAt > 0 && len(id[partAt+len("_part_"):]) == 3 {
		part, err := strconv.Atoi(id[partAt+len("_part_"):])
		if err == nil && part > 0 {
			return id[:partAt], part
		}
	}
	return "", 0
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
	var episodeID, operation, kind, channelID, threadTS, sequenceKey string
	var responseRoot bool
	var cardVersion int64
	if err := tx.QueryRowContext(ctx, `
		SELECT incident_id, episode_id, operation, kind, channel_id, thread_ts, card_version,
		  response_root, sequence_key
		FROM slack_deliveries
		WHERE id = ? AND state = ?`,
		id, fromState).Scan(
		&incidentID, &episodeID, &operation, &kind, &channelID, &threadTS, &cardVersion,
		&responseRoot, &sequenceKey,
	); err != nil {
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
	if episodeID != "" && responseRoot && threadTS == "" && messageTS != "" {
		episode, getErr := scanWorkEpisode(tx.QueryRowContext(
			ctx, `SELECT `+workEpisodeColumns+` FROM work_episodes WHERE id = ?`, episodeID,
		))
		if getErr != nil {
			return getErr
		}
		if episode.Destination.ChannelID == channelID && episode.Destination.ThreadTS == "" {
			payload, _ := episodepkg.Encode(map[string]any{
				"channel_id": channelID, "thread_ts": messageTS,
				"reason":               "reply_thread_created",
				"destination_revision": episode.DestinationRevision + 1,
			})
			event, err := s.appendEpisodeEventTx(ctx, tx, episodeID, core.WorkEpisodeEvent{
				Kind: episodepkg.EventDestinationChanged, Actor: "host",
				IdempotencyKey: "reply-thread:" + id, Payload: payload,
			})
			if err != nil {
				return err
			}
			if _, err := tx.ExecContext(ctx, `
				UPDATE work_episodes
				SET thread_ts = CASE WHEN thread_ts = '' AND channel_id = ? THEN ? ELSE thread_ts END,
				    destination_thread_ts = ?, destination_revision = destination_revision + 1
				WHERE id = ? AND destination_thread_ts = ''`,
				channelID, messageTS, messageTS, episodeID,
			); err != nil {
				return err
			}
			// A visual bundle starts with one top-level file and continues in the
			// thread that Slack creates for it. Retarget its not-yet-leased siblings
			// in the same transaction as the durable episode destination change.
			if sequenceKey != "" {
				if _, err := tx.ExecContext(ctx, `
					UPDATE slack_deliveries
					SET thread_ts = ?, expected_destination_revision = ?,
					    expected_episode_revision = ?, updated_at = ?
					WHERE sequence_key = ? AND id != ? AND state IN ('pending', 'retry', 'failed')`,
					messageTS, episode.DestinationRevision+1, event.Sequence, s.nowText(),
					sequenceKey, id,
				); err != nil {
					return err
				}
			}
		}
	}
	if responseRoot && strings.HasSuffix(id, "_upload_failed") && sequenceKey != "" {
		if _, err := tx.ExecContext(ctx, `
			UPDATE slack_deliveries
			SET state = 'superseded', last_error = 'replaced by upload failure notice', updated_at = ?
			WHERE sequence_key = ? AND operation = 'file' AND state = 'failed'`,
			s.nowText(), sequenceKey,
		); err != nil {
			return err
		}
	}
	if incidentID.Valid && kind == "root" {
		result, err = tx.ExecContext(ctx, `
			UPDATE incidents
			SET root_ts = ?,
			    -- Thread-scoped work may already have bound its session while
			    -- this card was in flight; the card landing must not walk the
			    -- workflow backwards over it.
			    workflow = CASE WHEN coop_session_id = ''
			      THEN 'provisioning_session' ELSE workflow END,
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
	// The diff that is now open. Recorded here rather than where it was
	// composed because here is the only place the ts exists: the handler
	// enqueues a delivery and Slack decides where it lands. Paging rewrites
	// this same message, so the same branch answers both without a second
	// spelling of the rule.
	//
	// The version bump is guarded on the value actually changing. Without the
	// guard every Next press would re-render the card to say the same thing.
	if incidentID.Valid && kind == "changes" && messageTS != "" {
		if _, err := tx.ExecContext(ctx, `
			UPDATE incidents
			SET changes_message_ts = ?, updated_at = ?, card_version = card_version + 1
			WHERE id = ? AND changes_message_ts != ?`,
			messageTS, s.nowText(), incidentID.String, messageTS); err != nil {
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
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var operation, coalesceKey, created string
	var rowID int64
	if err := tx.QueryRowContext(ctx, `
		SELECT operation, coalesce_key, created_at, rowid
		FROM slack_deliveries WHERE id = ? AND state = 'sending'`, id,
	).Scan(&operation, &coalesceKey, &created, &rowID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("retry Slack delivery: %w", ErrConflict)
		}
		return err
	}
	if operation == "reaction" && coalesceKey != "" {
		var newer bool
		if err := tx.QueryRowContext(ctx, `SELECT EXISTS (
			SELECT 1 FROM slack_deliveries
			WHERE coalesce_key = ? AND operation = 'reaction' AND id != ?
			  AND (created_at > ? OR (created_at = ? AND rowid > ?))
		)`, coalesceKey, id, created, created, rowID).Scan(&newer); err != nil {
			return err
		}
		if newer {
			state, detail = "superseded", "newer reaction intent"
		}
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = ?, failure_count = failure_count + 1,
		    last_error = ?, next_attempt_at = ?, updated_at = ?
		WHERE id = ? AND state = 'sending'`,
		state, sqlutil.BoundedError(detail), next.UTC().Format(timestampFormat),
		s.nowText(), id)
	if err := sqlutil.ExpectOne(result, err, "retry Slack delivery"); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) SupersedeLeasedSlackDelivery(ctx context.Context, id, detail string) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE slack_deliveries
		SET state = 'superseded', last_error = ?, updated_at = ?
		WHERE id = ? AND state = 'sending'`, sqlutil.BoundedError(detail), s.nowText(), id)
	return sqlutil.ExpectOne(result, err, "supersede leased Slack delivery")
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
