// Package standingassignmentstore owns scoped authority to act without a
// per-action click: the grant, what it claimed, and what it decided.
//
// It is a repository rather than methods on Store for the reason the other
// extractions here exist — a delegating method still counts against the store's
// method budget, so an extraction only reduces the surface if callers reach it
// through the field.
//
// The area is small and unusually load-bearing. Every method here is either a
// bound on autonomous work or the record of that bound being applied, which is
// why the validation, the claim and the evaluation ledger live together rather
// than beside whatever happens to call them.
package standingassignmentstore

import (
	"database/sql"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
)

// Repository reads and writes standing assignments.
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
