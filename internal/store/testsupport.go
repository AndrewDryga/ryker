package store

// Test-support API.
//
// Every method here is exported and reachable only from tests, including tests
// in other packages, which is why they cannot live in a _test.go file. They
// exist to arrange durable state directly — set an incident's Slack root,
// advance a channel memory generation, read back an episode's event stream —
// so a test can assert against a real database instead of a mock.
//
// They are deliberately narrow and must stay that way: nothing in the service
// may call them, and the architecture test's dependency direction plus the
// deadcode sweep are what keep that honest. If a production path ever needs one
// of these, move it back beside the code that owns its table.

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/AndrewDryga/responder/internal/core"
)

func (s *Store) SetRoot(ctx context.Context, id, rootTS string) error {
	result, err := s.db.ExecContext(ctx, `
		UPDATE incidents SET root_ts = ?, workflow = 'provisioning_session',
		  updated_at = ?, card_version = card_version + 1, last_error = ''
		WHERE id = ? AND channel_id != '' AND root_ts = ''`, rootTS, s.nowText(), id)
	return expectOne(result, err, "bind incident root")
}

func (s *Store) MarkCardRendered(ctx context.Context, id string, version int64) error {
	_, err := s.db.ExecContext(ctx, `
		UPDATE incidents SET card_rendered_version = CASE
		  WHEN card_rendered_version < ? THEN ? ELSE card_rendered_version END
		WHERE id = ?`, version, version, id)
	return err
}

func (s *Store) AdvanceChannelMemory(
	ctx context.Context,
	channelID string,
	sessionRevision int64,
	state core.AgentMemory,
) error {
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	if len(data) > 64<<10 {
		return errors.New("channel memory exceeds 64 KiB")
	}
	result, err := s.db.ExecContext(ctx, `
		UPDATE channel_memories
		SET session_revision = ?, turn_count = turn_count + 1, state_json = ?, updated_at = ?
		WHERE channel_id = ?`,
		sessionRevision, data, s.nowText(), channelID,
	)
	return expectOne(result, err, "advance channel memory")
}

// GetCommitmentByRun finds the commitment for the episode a run belongs to.
//
// It reaches through the run's episode rather than the run itself, because a
// replacement attempt shares its predecessor's promise — that is the whole
// point of keying commitments by episode.
func (s *Store) GetCommitmentByRun(
	ctx context.Context,
	runID string,
) (core.Commitment, error) {
	return scanCommitment(s.db.QueryRowContext(
		ctx,
		`SELECT `+commitmentProjectionColumns+`
		 FROM commitments AS c
		 JOIN work_episodes AS e ON e.id = c.episode_id
		 JOIN agent_runs AS r ON r.id = e.agent_run_id
		 WHERE c.episode_id = (SELECT episode_id FROM agent_runs WHERE id = ?)`,
		runID,
	))
}

func (s *Store) ListWorkEpisodeEvents(
	ctx context.Context,
	runID string,
	limit int,
) ([]core.WorkEpisodeEvent, error) {
	episode, err := s.GetWorkEpisodeByRun(ctx, runID)
	if err != nil {
		return nil, err
	}
	return s.ListEpisodeEvents(ctx, episode.ID, limit)
}

func (s *Store) ListEpisodeEvents(
	ctx context.Context,
	episodeID string,
	limit int,
) ([]core.WorkEpisodeEvent, error) {
	if limit < 1 || limit > 500 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT v.id, v.episode_id, v.sequence, v.kind, v.actor,
		       v.idempotency_key, v.payload_json, v.created_at
		FROM work_episode_events AS v
		WHERE v.episode_id = ?
		ORDER BY v.sequence ASC LIMIT ?`, episodeID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]core.WorkEpisodeEvent, 0)
	for rows.Next() {
		event, err := scanWorkEpisodeEvent(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, event)
	}
	return result, rows.Err()
}
