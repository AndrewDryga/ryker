// Package memorystore owns everything Responder remembers between turns:
// memory entries, rollups, the review queue, and conversation memories.
//
// It is a package rather than another few dozen methods on Store because the
// store had reached its method budget, and memory is the most cohesive area in
// it — 27 exported operations with no internal callers elsewhere in the store.
package memorystore

import (
	"database/sql"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Repository reads and writes remembered state.
type Repository struct {
	db          *sql.DB
	currentTime func() time.Time
}

// New builds a repository over an already-migrated database.
//
// The clock is passed in rather than read from the package so a test can move
// time without reaching into the repository, and so every package sharing this
// database shares one notion of now.
func New(db *sql.DB, currentTime func() time.Time) *Repository {
	return &Repository{db: db, currentTime: currentTime}
}

func (r *Repository) now() time.Time { return r.currentTime().UTC() }

func (r *Repository) nowText() string {
	return r.now().Format(core.TimestampFormat)
}
