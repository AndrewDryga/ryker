// Package behaviorstore owns the durable behaviour an operator has taught
// Responder: preferences and standing rules.
//
// These are the offers a reply can carry, and what makes them different from
// memory is that they change what Responder does rather than what it knows.
package behaviorstore

import (
	"database/sql"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Repository reads and writes taught behaviour.
type Repository struct {
	db          *sql.DB
	currentTime func() time.Time
}

// New builds a repository over an already-migrated database.
func New(db *sql.DB, currentTime func() time.Time) *Repository {
	return &Repository{db: db, currentTime: currentTime}
}

func (r *Repository) now() time.Time { return r.currentTime().UTC() }

func (r *Repository) nowText() string {
	return r.now().Format(core.TimestampFormat)
}
