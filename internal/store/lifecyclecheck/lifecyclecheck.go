// Package lifecyclecheck compares the agent-run lifecycle against the episode
// lifecycle.
//
// It lives beside the store rather than inside it because the store is already
// past its method budget, and a diagnostic that reads two tables is exactly the
// kind of cohesive area that should be split out rather than absorbed.
package lifecyclecheck

import (
	"context"
	"database/sql"
	"fmt"
)

// CancelQueuedUnderTerminalEpisodes reconciles transport rows with their
// authoritative episode. Pending work cannot usefully run after the episode
// has already ended, and otherwise gets retried on every worker restart.
func CancelQueuedUnderTerminalEpisodes(ctx context.Context, tx *sql.Tx, now string) error {
	terminalEpisode := `EXISTS (
		SELECT 1 FROM work_episodes AS episode
		WHERE episode.id = agent_runs.episode_id
		  AND episode.lifecycle_state IN (
		    'completed', 'failed', 'refused', 'cancelled', 'superseded'
		  )
	)`
	if _, err := tx.ExecContext(ctx, `
		UPDATE episode_attempts
		SET state = 'cancelled', failure_class = 'episode_terminal',
		    lease_owner = '', lease_expires_at = NULL,
		    fencing_token = fencing_token + 1,
		    completed_at = COALESCE(completed_at, ?), updated_at = ?
		WHERE agent_run_id IN (
		  SELECT agent_runs.id FROM agent_runs
		  WHERE agent_runs.state IN ('pending', 'preparing') AND `+terminalEpisode+`
		)`, now, now); err != nil {
		return fmt.Errorf("cancel stale episode attempt: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE agent_runs
		SET state = 'cancelled', terminal_state = 'cancelled',
		    last_error = 'episode already reached a terminal state',
		    completed_at = COALESCE(completed_at, ?), updated_at = ?
		WHERE state IN ('pending', 'preparing') AND `+terminalEpisode,
		now, now,
	); err != nil {
		return fmt.Errorf("cancel stale agent run: %w", err)
	}
	return queueTerminalStatusClears(ctx, tx, now)
}

type pendingStatusClear struct {
	runID, episodeID, channelID, threadTS string
}

// queueTerminalStatusClears projects the transport cancellation onto Slack in
// the same transaction. Leaving that projection to a later service callback
// stranded "Checking live systems" forever whenever no useful run was left to
// lease, which is precisely when the cleanup matters most.
func queueTerminalStatusClears(ctx context.Context, tx *sql.Tx, now string) error {
	rows, err := tx.QueryContext(ctx, `
		SELECT run.id, run.episode_id, input.channel_id,
		  CASE
		    WHEN json_extract(run.context_json, '$.approval_continuation') = 1
		      THEN COALESCE(json_extract(run.context_json, '$.response_thread_ts'), '')
		    ELSE COALESCE(NULLIF(input.thread_ts, ''), input.message_ts)
		  END
		FROM agent_runs AS run
		JOIN slack_inputs AS input ON input.id = run.source_id
		WHERE run.source_kind = 'watch'
		  AND run.state = 'cancelled'
		  AND run.last_error = 'episode already reached a terminal state'
		  AND json_valid(run.context_json)
		  AND json_extract(run.context_json, '$.pending_status_set') = 1`)
	if err != nil {
		return fmt.Errorf("list stale Slack statuses: %w", err)
	}
	var pending []pendingStatusClear
	for rows.Next() {
		var item pendingStatusClear
		if err := rows.Scan(&item.runID, &item.episodeID, &item.channelID, &item.threadTS); err != nil {
			rows.Close()
			return fmt.Errorf("scan stale Slack status: %w", err)
		}
		if item.channelID != "" && item.threadTS != "" {
			pending = append(pending, item)
		}
	}
	if err := rows.Close(); err != nil {
		return fmt.Errorf("close stale Slack status rows: %w", err)
	}
	for _, item := range pending {
		var generation int64
		if err := tx.QueryRowContext(ctx, `
			INSERT INTO slack_status_generations (channel_id, thread_ts, generation, updated_at)
			VALUES (?, ?, 1, ?)
			ON CONFLICT(channel_id, thread_ts) DO UPDATE SET
			  generation = slack_status_generations.generation + 1,
			  updated_at = excluded.updated_at
			RETURNING generation`, item.channelID, item.threadTS, now).Scan(&generation); err != nil {
			return fmt.Errorf("advance cancelled Slack status: %w", err)
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT OR IGNORE INTO slack_deliveries (
			  id, episode_id, operation, kind, channel_id, thread_ts,
			  body_json, status_text, steps_json, coalesce_key, card_version,
			  state, next_attempt_at, created_at, updated_at
			) VALUES (?, ?, 'status', 'status', ?, ?, X'', '', '[]', ?, ?,
			          'pending', ?, ?, ?)`,
			"terminal_status_clear_"+item.runID, item.episodeID,
			item.channelID, item.threadTS, "status:"+item.channelID+":"+item.threadTS,
			generation, now, now, now,
		); err != nil {
			return fmt.Errorf("queue cancelled Slack status clear: %w", err)
		}
		if _, err := tx.ExecContext(ctx, `
			UPDATE agent_runs
			SET context_json = json_set(
			  context_json, '$.pending_status_set', json('false'), '$.pending_status_at', 0
			), updated_at = ?
			WHERE id = ?`, now, item.runID); err != nil {
			return fmt.Errorf("mark cancelled Slack status clear queued: %w", err)
		}
	}
	return nil
}

// Report is what the two lifecycles disagree about.
//
// The cutover from agent-run states to episode states follows the project's own
// migration rule: compare projections, cut over, then delete the legacy path.
// This is the compare step, which had never been built — the cutover was being
// planned without the evidence the rule asks for.
type Report struct {
	Episodes int
	// RunningUnderFinished: work is still executing under an episode that says
	// it is over. Only visible on a live system; at rest every run is terminal,
	// which is why a one-off query over a stopped database cannot find it.
	RunningUnderFinished []string
	// ExecutingWithoutRun: the episode claims to be executing and has no live
	// run to do it. This is a stalled episode, whoever is authoritative.
	ExecutingWithoutRun []string
	// OutcomeConflict: the episode and its most recent run disagree about how
	// the work ended. Compared against the latest run on purpose — an episode
	// legitimately contains a failed attempt followed by a successful one, and
	// comparing against every run reports that correct behaviour as a conflict.
	OutcomeConflict []string
}

// Clean reports whether the legacy lifecycle can be retired without losing
// information the episode does not already carry.
func (r Report) Clean() bool {
	return len(r.RunningUnderFinished) == 0 && len(r.ExecutingWithoutRun) == 0 &&
		len(r.OutcomeConflict) == 0
}

// Divergences compares the agent-run lifecycle against the episode lifecycle
// and reports every place they contradict each other.
func Divergences(ctx context.Context, db *sql.DB) (Report, error) {
	var report Report
	if err := db.QueryRowContext(
		ctx, `SELECT count(*) FROM work_episodes`,
	).Scan(&report.Episodes); err != nil {
		return report, err
	}
	for _, probe := range []struct {
		into  *[]string
		query string
	}{
		{&report.RunningUnderFinished, `
			SELECT e.id FROM work_episodes e JOIN agent_runs r ON r.episode_id = e.id
			WHERE r.state IN ('pending','preparing','running','applying','finalizing')
			  AND e.lifecycle_state IN ('completed','failed','refused','cancelled')`},
		{&report.ExecutingWithoutRun, `
			SELECT e.id FROM work_episodes e
			WHERE e.lifecycle_state IN (
			  'accepted','acknowledged','planning','working','verifying','retrying')
			  AND NOT EXISTS (
			    SELECT 1 FROM agent_runs r WHERE r.episode_id = e.id
			      AND r.state NOT IN ('completed','failed','cancelled','superseded'))`},
		{&report.OutcomeConflict, `
			SELECT e.id FROM work_episodes e JOIN agent_runs r ON r.episode_id = e.id
			WHERE r.created_at = (
			    SELECT max(r2.created_at) FROM agent_runs r2 WHERE r2.episode_id = e.id)
			  AND ((e.lifecycle_state = 'completed' AND r.state = 'failed')
			    OR (e.lifecycle_state = 'failed' AND r.state = 'completed'))`},
	} {
		rows, err := db.QueryContext(ctx, probe.query)
		if err != nil {
			return report, err
		}
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return report, err
			}
			*probe.into = append(*probe.into, id)
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return report, err
		}
	}
	return report, nil
}
