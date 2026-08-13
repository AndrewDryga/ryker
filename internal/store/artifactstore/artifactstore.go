// Package artifactstore retains the bodies of bounded input artifacts handed
// to model turns — a rendered pull-request snapshot, a pasted log — keyed by
// the digest their manifest references record. Until it existed the dashboard
// could prove an artifact was handed to the model and could not show a byte
// of it.
package artifactstore

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Repository reads and writes retained artifact bodies.
type Repository struct {
	db          *sql.DB
	currentTime func() time.Time
}

// New builds a repository over an already-migrated database.
func New(db *sql.DB, currentTime func() time.Time) *Repository {
	return &Repository{db: db, currentTime: currentTime}
}

// Save retains artifact bodies keyed by digest. Saving is idempotent — the
// same file attached to ten turns is stored once — and silently skips bodies
// core.RetainableArtifact refuses.
func (r *Repository) Save(ctx context.Context, artifacts []core.ContextArtifact) error {
	for _, artifact := range artifacts {
		digest := strings.TrimSpace(artifact.Digest)
		if digest == "" || !core.RetainableArtifact(artifact.MediaType, len(artifact.Body)) {
			continue
		}
		if _, err := r.db.ExecContext(ctx, `
			INSERT INTO context_artifacts (digest, name, media_type, body, created_at)
			VALUES (?, ?, ?, ?, ?)
			ON CONFLICT(digest) DO NOTHING`,
			digest, artifact.Name, artifact.MediaType, artifact.Body,
			r.currentTime().UTC().Format(core.TimestampFormat),
		); err != nil {
			return err
		}
	}
	return nil
}

// Get returns one retained artifact body by its digest.
func (r *Repository) Get(ctx context.Context, digest string) (core.ContextArtifact, bool, error) {
	artifact := core.ContextArtifact{Digest: strings.TrimSpace(digest)}
	if artifact.Digest == "" {
		return core.ContextArtifact{}, false, nil
	}
	var created string
	err := r.db.QueryRowContext(ctx, `
		SELECT name, media_type, body, created_at FROM context_artifacts WHERE digest = ?`,
		artifact.Digest,
	).Scan(&artifact.Name, &artifact.MediaType, &artifact.Body, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return core.ContextArtifact{}, false, nil
	}
	if err != nil {
		return core.ContextArtifact{}, false, err
	}
	if parsed, parseErr := time.Parse(core.TimestampFormat, created); parseErr == nil {
		artifact.CreatedAt = parsed
	}
	return artifact, true, nil
}

type execer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

// PruneSpent deletes bodies older than the cutoff once every manifest that
// referenced them has had its prompt text emptied; the digest on the
// reference remains for audit. It runs inside the caller's retention
// transaction.
func PruneSpent(ctx context.Context, tx execer, cutoff string) (int64, error) {
	result, err := tx.ExecContext(ctx, `
		DELETE FROM context_artifacts WHERE created_at < ? AND NOT EXISTS (
		  SELECT 1 FROM context_manifest_refs f
		  JOIN context_manifests m ON m.id = f.manifest_id
		  WHERE f.kind = 'artifact' AND f.content_digest = context_artifacts.digest
		    AND m.submitted_prompt != ''
		)`, cutoff)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}
