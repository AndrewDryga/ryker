// Package goalstore reads what an episode said it would do.
//
// The goals themselves are written by the episode kernel, inside the same
// transactions that append the episode's events — planning a goal and recording
// that it was planned are one fact and must not be able to half-happen. Reading
// them is a different job with different callers: a Slack card composing itself
// every fifteen seconds, and a test asking what a result actually stored.
//
// It is a package rather than four more methods on Store because the reads
// arrived when Store was already at its method budget, and the budget exists to
// be answered by extracting a cohesive area instead of raising it. This is that
// area: the plan, read, by whoever is rendering it.
package goalstore

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

type Repository struct {
	db *sql.DB
}

func New(db *sql.DB) *Repository {
	return &Repository{db: db}
}

const goalSelect = `
	SELECT id, episode_id, parent_goal_id, prerequisite_goal_ids_json, kind,
	       requested_outcome, completion_contract, writable_repository,
	       read_only_repositories_json, authority_requirement, required, state,
	       blocker, created_at, updated_at, completed_at
	FROM episode_goals `

// ListForEpisode reads an episode's plan in the order it was planned.
//
// Planning order, not state order: the plan is a sequence the model laid out,
// and a card that re-sorted it by state would reorder itself as the work
// progressed — the same five goals in a different arrangement on every refresh,
// which is the one thing a checklist must not do. It is also the order the
// completion gate and the web episode page already read them in.
func (r *Repository) ListForEpisode(
	ctx context.Context,
	episodeID string,
	limit int,
) ([]core.EpisodeGoal, error) {
	if strings.TrimSpace(episodeID) == "" || limit <= 0 {
		return nil, nil
	}
	return r.list(
		ctx,
		goalSelect+`WHERE episode_id = ? ORDER BY created_at, id LIMIT ?`,
		episodeID, limit,
	)
}

// GoalsForIncident reads the plan behind a card.
//
// Addressed by incident rather than by episode for the reason the activity tail
// is: the card worker holds an incident, and resolving the episode first would
// be a second round trip on a card that rewrites itself every fifteen seconds.
// The subquery is the same one the activity tail uses, so the plan on a card
// and the window above it always describe one episode.
func (r *Repository) GoalsForIncident(
	ctx context.Context,
	incidentID string,
	limit int,
) ([]core.EpisodeGoal, error) {
	if strings.TrimSpace(incidentID) == "" || limit <= 0 {
		return nil, nil
	}
	return r.list(ctx, goalSelect+`
		WHERE episode_id = (
		  SELECT episode_id FROM agent_runs
		  WHERE incident_id = ? AND episode_id != ''
		  ORDER BY created_at DESC, id DESC LIMIT 1
		)
		ORDER BY created_at, id LIMIT ?`, incidentID, limit)
}

func (r *Repository) list(
	ctx context.Context,
	query string,
	args ...any,
) ([]core.EpisodeGoal, error) {
	rows, err := r.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var goals []core.EpisodeGoal
	for rows.Next() {
		goal, err := scan(rows)
		if err != nil {
			return nil, err
		}
		goals = append(goals, goal)
	}
	return goals, rows.Err()
}

func scan(row interface{ Scan(...any) error }) (core.EpisodeGoal, error) {
	var item core.EpisodeGoal
	var prerequisitesJSON, readOnlyJSON, created, updated string
	var required int
	var completed sql.NullString
	err := row.Scan(
		&item.ID, &item.EpisodeID, &item.ParentGoalID, &prerequisitesJSON,
		&item.Kind, &item.RequestedOutcome, &item.CompletionContract,
		&item.WritableRepository, &readOnlyJSON, &item.AuthorityRequirement,
		&required, &item.State, &item.Blocker, &created, &updated, &completed,
	)
	if err != nil {
		return core.EpisodeGoal{}, err
	}
	if err := json.Unmarshal([]byte(prerequisitesJSON), &item.PrerequisiteGoalIDs); err != nil {
		return core.EpisodeGoal{}, err
	}
	if err := json.Unmarshal([]byte(readOnlyJSON), &item.ReadOnlyRepositories); err != nil {
		return core.EpisodeGoal{}, err
	}
	item.Required = required == 1
	item.CreatedAt, item.UpdatedAt = sqlutil.ParseTime(created), sqlutil.ParseTime(updated)
	item.CompletedAt = sqlutil.ScanTime(completed)
	return item, nil
}
