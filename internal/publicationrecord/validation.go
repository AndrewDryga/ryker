// Package publicationrecord defines the durable proof required by each state
// of a reviewed pull-request publication.
package publicationrecord

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Reader is the narrow query surface shared by a database and a transaction.
type Reader interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

// Get decodes one durable publication receipt. Keeping the row shape beside
// its validation rules makes publicationstore responsible for lifecycle
// transactions without also owning a second representation of the receipt.
func Get(ctx context.Context, db Reader, incidentID string) (core.Publication, error) {
	var item core.Publication
	var created, updated string
	var published sql.NullString
	err := db.QueryRowContext(ctx, `
		SELECT incident_id, attempt_input_id, generation, repository, base_branch,
		  head_branch, parent_head, candidate_tree, commit_sha, remote_sha,
		  pr_number, pr_url, state, failure_code, last_error, created_at,
		  updated_at, published_at
		FROM publications WHERE incident_id = ?`, incidentID).Scan(
		&item.IncidentID, &item.AttemptInputID, &item.Generation, &item.Repository,
		&item.BaseBranch, &item.HeadBranch, &item.ParentHead, &item.CandidateTree,
		&item.CommitSHA, &item.RemoteSHA, &item.PRNumber, &item.PRURL, &item.State,
		&item.FailureCode, &item.LastError, &created, &updated, &published,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return core.Publication{}, core.ErrNotFound
	}
	if err != nil {
		return core.Publication{}, err
	}
	item.CreatedAt = parseTime(created)
	item.UpdatedAt = parseTime(updated)
	if published.Valid {
		item.PublishedAt = parseTime(published.String)
	}
	return item, nil
}

func parseTime(value string) time.Time {
	parsed, _ := time.Parse(core.TimestampParseFormat, value)
	return parsed
}

func Validate(item core.Publication) error {
	if item.IncidentID == "" || item.Repository == "" || item.BaseBranch == "" {
		return errors.New("publication identity, repository, base branch, and state are required")
	}
	switch item.State {
	case core.PublicationReviewing, core.PublicationRetrying, core.PublicationFailed:
	case core.PublicationPublishing:
		if item.ParentHead == "" || item.CandidateTree == "" {
			return errors.New("reviewed tree is required before publication")
		}
	case core.PublicationPublished, core.PublicationStale:
		if item.ParentHead == "" || item.CandidateTree == "" {
			return errors.New("reviewed tree is required before publication")
		}
		if item.HeadBranch == "" || item.CommitSHA == "" || item.RemoteSHA == "" ||
			item.PRNumber < 1 || item.PRURL == "" || item.PublishedAt.IsZero() {
			return errors.New("durable draft PR identity and proof are required")
		}
	default:
		return fmt.Errorf("publication state %q is invalid", item.State)
	}
	return nil
}
