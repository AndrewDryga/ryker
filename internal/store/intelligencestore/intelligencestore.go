// Package intelligencestore owns what an investigation learned: evidence,
// coverage, claim assessments, the incident timeline, and action proposals.
//
// Extracted from store for the same reason as memorystore — the store had
// reached its method budget and this is the largest cohesive area left in it.
package intelligencestore

import (
	"database/sql"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Repository reads and writes what an investigation established.
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
