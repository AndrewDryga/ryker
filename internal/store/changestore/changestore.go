// Package changestore owns the change ledger: what changed, when, and to what.
//
// It is a repository rather than methods on Store for the reason the other
// extractions here exist — a delegating method still counts against the store's
// method budget, so an extraction only reduces the surface if callers reach it
// through the field.
//
// Insert is a free function over an exec handle rather than a method because
// one of the three ingest paths has to write inside somebody else's
// transaction. A publication lifecycle transition and the change event it
// implies are one fact; written afterwards the change event could simply be
// absent, and that failure is invisible — the ledger would say nothing was
// deployed and no one would learn it should have.
package changestore

import (
	"context"
	"database/sql"
	"encoding/json"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store/sqlutil"
)

// Execer is anything a statement can run on: the pool, or an open transaction.
type Execer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

type Repository struct {
	db    *sql.DB
	clock func() time.Time
}

func New(db *sql.DB, clock func() time.Time) *Repository {
	return &Repository{db: db, clock: clock}
}

// Record writes one ingested change and reports whether it was new.
//
// The caller has already been through changeledger.Record, which is what
// derives the id from the source's own identity. Everything idempotent about
// this write follows from that: INSERT OR IGNORE against a derived key means a
// webhook redelivery, a rewound poll cursor and a re-read terminal Emisar run
// all address the row that is already there.
func (r *Repository) Record(ctx context.Context, event core.ChangeEvent) (bool, error) {
	return Insert(ctx, r.db, event, r.clock())
}

// Insert writes one change event on the supplied handle. See the package
// comment for why this is not a method.
func Insert(
	ctx context.Context,
	exec Execer,
	event core.ChangeEvent,
	now time.Time,
) (bool, error) {
	services, err := json.Marshal(refs(event.Services))
	if err != nil {
		return false, err
	}
	repositories, err := json.Marshal(refs(event.Repositories))
	if err != nil {
		return false, err
	}
	return sqlutil.Changed(exec.ExecContext(ctx, `
		INSERT OR IGNORE INTO change_events (
		  id, source, source_identity, kind, occurred_at, services_json,
		  repositories_json, actor, summary, source_ref, revision, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		event.ID, event.Source, event.SourceIdentity, event.Kind,
		event.OccurredAt.UTC().Format(core.TimestampFormat),
		string(services), string(repositories), event.Actor, event.Summary,
		event.SourceRef, event.Revision,
		now.UTC().Format(core.TimestampFormat),
	))
}

// Recent reads the candidate window newest first.
//
// It returns the whole window rather than the changes for one scope, because
// scope is assembled from three sources of different freshness and matching it
// in SQL would mean capping before matching — returning the ten newest changes
// in the estate and then discovering none of them are about this incident. The
// window is six hours by default and the candidate set is dozens of rows;
// changeledger.Select does the matching and the capping over what comes back.
func (r *Repository) Recent(
	ctx context.Context,
	since time.Time,
	limit int,
) ([]core.ChangeEvent, error) {
	if limit < 1 {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, source, source_identity, kind, occurred_at, services_json,
		       repositories_json, actor, summary, source_ref, revision, created_at
		FROM change_events
		WHERE occurred_at > ?
		ORDER BY occurred_at DESC, id ASC
		LIMIT ?`,
		since.UTC().Format(core.TimestampFormat), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	events := make([]core.ChangeEvent, 0, limit)
	for rows.Next() {
		var event core.ChangeEvent
		var services, repositories []byte
		var occurredAt, createdAt string
		if err := rows.Scan(
			&event.ID, &event.Source, &event.SourceIdentity, &event.Kind,
			&occurredAt, &services, &repositories, &event.Actor, &event.Summary,
			&event.SourceRef, &event.Revision, &createdAt,
		); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(services, &event.Services); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(repositories, &event.Repositories); err != nil {
			return nil, err
		}
		event.OccurredAt = sqlutil.ParseTime(occurredAt)
		event.CreatedAt = sqlutil.ParseTime(createdAt)
		events = append(events, event)
	}
	return events, rows.Err()
}

// refs keeps an absent list out of the database as [] rather than null, so
// every reader can decode the column without a nil check.
func refs(values []string) []string {
	if values == nil {
		return []string{}
	}
	return values
}
