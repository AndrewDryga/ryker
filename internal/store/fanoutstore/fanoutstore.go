// Package fanoutstore reads the branches of a parallel investigation and what
// the investigation has already spent.
//
// It is a package rather than three more methods on Store for the reason
// goalstore is: Store was at its method budget when these reads arrived, and
// the budget is answered by extracting a cohesive area instead of raising it.
// This is that area — the shape of a fan-out, read back.
//
// Nothing here decides anything. Whether a fan-out is admitted is
// internal/fanout's question, and it is a pure function over what this package
// returns precisely so the refusals can be tested without a database.
package fanoutstore

import (
	"context"
	"database/sql"
	"strings"

	"github.com/AndrewDryga/responder/internal/fanout"
)

type Repository struct {
	db *sql.DB
}

func New(db *sql.DB) *Repository {
	return &Repository{db: db}
}

// Branch is one child episode of a lead investigation: the goal it was funded
// to answer, and where it got to.
type Branch struct {
	EpisodeID string
	GoalID    string
	// State is the child episode's lifecycle state, which is what says a branch
	// has stopped. The goal's own state is the model's account of the same
	// thing and a branch that died never wrote one.
	State     string
	Objective string
	RunID     string
	CreatedAt string
}

// Terminal reports whether this branch has stopped, by any road.
//
// Stopped, not succeeded: a branch that blocked is information the synthesis
// wants, because "this could not be established" is half of most operational
// answers. Waiting for success would hang the lead on the first branch that
// failed.
func (b Branch) Terminal() bool {
	switch b.State {
	case "completed", "failed", "refused", "cancelled", "superseded":
		return true
	case "blocked":
		// Blocked counts, and it is the whole reason this is a list rather than
		// the episode kernel's own terminal set. A blocked episode is resumable
		// in general, so the kernel keeps it out of that set — but a blocked
		// branch is where a failed branch is deliberately put, precisely so a
		// branch failure is a goal blocker instead of an incident failure.
		// Reading it as "still running" would hang the synthesis on the one
		// branch that most needs reporting, and "this could not be established"
		// is half of most operational answers.
		return true
	default:
		return false
	}
}

// ListForLead returns the branch children of a lead episode, oldest first.
//
// The branch-marker filter is load-bearing and not defensive. parent_episode_id
// is already used by watch correlation, where a follow-up message becomes a
// child of the episode it continues — those children are not branches, they are
// the same investigation carrying on, and counting one as a branch would let a
// busy thread look like a fan-out that had already spent its whole allowance.
func (r *Repository) ListForLead(
	ctx context.Context,
	leadEpisodeID string,
	limit int,
) ([]Branch, error) {
	if strings.TrimSpace(leadEpisodeID) == "" || limit <= 0 {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT episode.id, episode.lifecycle_state, episode.objective,
		       run.id, run.conversation_key, episode.created_at
		FROM work_episodes AS episode
		JOIN agent_runs AS run ON run.id = episode.agent_run_id
		WHERE episode.parent_episode_id = ?
		  AND instr(run.conversation_key, ?) > 0
		ORDER BY episode.created_at, episode.id
		LIMIT ?`, leadEpisodeID, fanout.BranchMarker, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var branches []Branch
	for rows.Next() {
		var item Branch
		var conversationKey string
		if err := rows.Scan(
			&item.EpisodeID, &item.State, &item.Objective, &item.RunID,
			&conversationKey, &item.CreatedAt,
		); err != nil {
			return nil, err
		}
		item.GoalID, _ = fanout.GoalOf(conversationKey)
		branches = append(branches, item)
	}
	return branches, rows.Err()
}

// Spend totals what an episode's attempts have cost, in both figures.
//
// Both, because "zero tokens" and "nobody measured" are different facts. Coop's
// ACP path reports no usage at all, so an episode denominated only in tokens
// reads as having spent nothing however long it has run — and a budget that
// cannot tell those apart would fund fan-out forever.
//
// The join is attempt to manifest, never episode to manifest. An episode has
// many attempts and each attempt its own manifest; joining on episode_id
// multiplies every attempt's usage by the manifest count and reports a number
// several times the truth. That exact mistake turned 351 into 953 once already.
func (r *Repository) Spend(ctx context.Context, episodeID string) (tokens int64, turns int, err error) {
	if strings.TrimSpace(episodeID) == "" {
		return 0, 0, nil
	}
	err = r.db.QueryRowContext(ctx, `
		SELECT COALESCE(SUM(
		         manifest.usage_input_tokens + manifest.usage_cached_input_tokens +
		         manifest.usage_output_tokens + manifest.usage_reasoning_tokens
		       ), 0), COUNT(*)
		FROM episode_attempts AS attempt
		LEFT JOIN context_manifests AS manifest
		  ON manifest.id = attempt.context_manifest_id
		WHERE attempt.episode_id = ?`, episodeID).Scan(&tokens, &turns)
	if err != nil {
		return 0, 0, err
	}
	return tokens, turns, nil
}
