package intelligencestore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/knowledgeoffer"
	"github.com/AndrewDryga/responder/internal/remediation"
)

// EpisodeKnowledgeEvidence is everything the host knows about a finished
// episode that an offer to keep its knowledge is graded against.
//
// Two reads, one method, because they answer one question and separating them
// invites a caller to ask half of it. `verified` is episode_outcomes' own
// column — the same field the promotion ladder counts, not a second definition
// of the word — and the actions are the exact Emisar identities this episode
// ran to a successful terminal state.
//
// A missing outcome row is not an error. An episode that has not reached a
// terminal state has no verified remediation yet, and that is an ordinary
// answer rather than a fault: the caller refuses the offer and says why.
func (r *Repository) EpisodeKnowledgeEvidence(
	ctx context.Context,
	episodeID string,
) (knowledgeoffer.Episode, error) {
	evidence := knowledgeoffer.Episode{EpisodeID: episodeID}
	if episodeID == "" {
		return evidence, nil
	}
	var verified int
	err := r.db.QueryRowContext(ctx, `
		SELECT verified, root_cause, verification FROM episode_outcomes
		WHERE episode_id = ?`, episodeID,
	).Scan(&verified, &evidence.RootCause, &evidence.Verification)
	if errors.Is(err, sql.ErrNoRows) {
		return evidence, nil
	}
	if err != nil {
		return knowledgeoffer.Episode{}, err
	}
	evidence.Verified = verified == 1
	// Exactly the join episodeRemediation already uses to build the outcome
	// row's remediation refs, and deliberately not a new one. Approvals are
	// keyed by the Slack input that requested the run or by the incident, never
	// by the episode; the projection resolved that once, and a second mapping
	// invented here would let a runbook be drafted from an action the recall row
	// for the same episode does not list. Successful runs only — a denied or
	// failed action is not a procedure worth writing down.
	rows, err := r.db.QueryContext(ctx, `
		SELECT DISTINCT a.action_id, a.pack_ref, a.runner_ref
		FROM work_episodes AS episode
		LEFT JOIN agent_runs AS run ON run.id = episode.agent_run_id
		JOIN emisar_approvals AS a
		  ON (COALESCE(run.source_id, '') != '' AND a.source_input = run.source_id)
		  OR (COALESCE(run.incident_id, '') != '' AND a.incident_id = run.incident_id)
		WHERE episode.id = ? AND a.status = 'success'
		  AND a.action_id != '' AND a.pack_ref != '' AND a.runner_ref != ''
		ORDER BY a.action_id LIMIT 16`, episodeID)
	if err != nil {
		return knowledgeoffer.Episode{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var action remediation.ActionRef
		if err := rows.Scan(&action.ActionID, &action.PackRef, &action.RunnerRef); err != nil {
			return knowledgeoffer.Episode{}, err
		}
		evidence.Actions = append(evidence.Actions, action)
	}
	return evidence, rows.Err()
}

// EpisodeOfferedOperation reads back one offer a model made on this episode.
//
// The offer is read from the episode's own event stream rather than carried on
// the confirmation button, because a knowledge card's body does not fit in a
// Slack action value and a runbook's summary barely would. That is the smaller
// reason. The larger one is that the button then carries an identity and
// nothing a client could edit: what is created is what the model wrote and the
// host recorded, not what came back through the operator's browser.
//
// core.ErrNotFound when the episode never carried that operation — including
// the case where retention has since collected it, which is the same answer to
// the operator and the same refusal.
func (r *Repository) EpisodeOfferedOperation(
	ctx context.Context,
	episodeID string,
	operationID string,
) (string, json.RawMessage, error) {
	if episodeID == "" || operationID == "" {
		return "", nil, core.ErrNotFound
	}
	var kind, payload string
	err := r.db.QueryRowContext(ctx, `
		SELECT kind, payload_json FROM work_episode_events
		WHERE episode_id = ? AND idempotency_key = ?
		ORDER BY sequence DESC LIMIT 1`, episodeID, "result:"+operationID,
	).Scan(&kind, &payload)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil, core.ErrNotFound
	}
	if err != nil {
		return "", nil, err
	}
	return kind, json.RawMessage(payload), nil
}
