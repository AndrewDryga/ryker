package store

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"sort"
)

// TableCounts is a row count per user table, the cheapest description of a
// database that notices data going missing.
type TableCounts map[string]int

// MigrationEffect is what happened to a database when it was migrated.
type MigrationEffect struct {
	FromVersion int
	ToVersion   int
	Before      TableCounts
	After       TableCounts
	// Lost is every table that ended with fewer rows than it started with.
	// This is the field the check exists for: a migration that drops rows is
	// almost never doing what its author intended, and it reports success
	// while doing it.
	Lost map[string]int
	// Dangling counts references left pointing at nothing.
	Dangling int
}

// Safe reports whether the migration can be trusted with real data.
func (e MigrationEffect) Safe() bool {
	return len(e.Lost) == 0 && e.Dangling == 0
}

// Describe renders the effect for a person deciding whether to deploy.
func (e MigrationEffect) Describe() string {
	if e.Safe() {
		return fmt.Sprintf(
			"schema %d -> %d, no rows lost across %d tables, no dangling references",
			e.FromVersion, e.ToVersion, len(e.After),
		)
	}
	tables := make([]string, 0, len(e.Lost))
	for table := range e.Lost {
		tables = append(tables, table)
	}
	sort.Strings(tables)
	report := fmt.Sprintf("schema %d -> %d UNSAFE:", e.FromVersion, e.ToVersion)
	for _, table := range tables {
		report += fmt.Sprintf(
			"\n  %s lost %d rows (%d -> %d)",
			table, e.Lost[table], e.Before[table], e.After[table],
		)
	}
	if e.Dangling > 0 {
		report += fmt.Sprintf("\n  %d dangling references", e.Dangling)
	}
	return report
}

// countTables reads every user table's row count.
func countTables(db *sql.DB) (TableCounts, error) {
	rows, err := db.Query(`
		SELECT name FROM sqlite_master
		WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`)
	if err != nil {
		return nil, err
	}
	var tables []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			rows.Close()
			return nil, err
		}
		tables = append(tables, name)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	counts := make(TableCounts, len(tables))
	for _, table := range tables {
		var count int
		if err := db.QueryRow(`SELECT count(*) FROM "` + table + `"`).Scan(&count); err != nil {
			return nil, fmt.Errorf("count %s: %w", table, err)
		}
		counts[table] = count
	}
	return counts, nil
}

// countDanglingReferences reports rows pointing at a parent that is not there.
func countDanglingReferences(db *sql.DB) (int, error) {
	rows, err := db.Query(`PRAGMA foreign_key_check`)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	dangling := 0
	for rows.Next() {
		dangling++
	}
	return dangling, rows.Err()
}

// CheckMigration migrates a copy of a database and reports what it did to the
// data.
//
// The copy is the point. A migration that passes every test can still destroy
// production data, because the tests do not have production's shape: dropping
// work_episodes cascades through eight tables, and that only matters when those
// tables have rows. On 2026-08-07 the obvious form of migration 47 would have
// deleted 352 attempts, 332 commitments and 9934 episode events on the deployed
// database while reporting success. This is the check that catches that without
// anyone having to think of it.
//
// It takes a directory that has already been copied. Copying is the caller's
// job so that this can never be pointed at a live database by accident.
func CheckMigration(copiedStateDir string) (MigrationEffect, error) {
	var effect MigrationEffect

	// Opened directly rather than through OpenCurrent, which refuses a database
	// that needs an upgrade — which is exactly the database this is for.
	before, err := sql.Open("sqlite", filepath.Join(copiedStateDir, "responder.db"))
	if err != nil {
		return effect, fmt.Errorf("read the copy: %w", err)
	}
	effect.FromVersion, err = schemaVersion(before)
	if err != nil {
		before.Close()
		return effect, err
	}
	effect.Before, err = countTables(before)
	if err != nil {
		before.Close()
		return effect, err
	}
	if err := before.Close(); err != nil {
		return effect, err
	}

	// Open normally, which migrates.
	after, err := Open(copiedStateDir)
	if err != nil {
		return effect, fmt.Errorf("migrate the copy: %w", err)
	}
	defer after.Close()
	effect.ToVersion, err = schemaVersion(after.db)
	if err != nil {
		return effect, err
	}
	effect.After, err = countTables(after.db)
	if err != nil {
		return effect, err
	}
	effect.Dangling, err = countDanglingReferences(after.db)
	if err != nil {
		return effect, err
	}

	effect.Lost = map[string]int{}
	for table, count := range effect.Before {
		remaining, present := effect.After[table]
		if !present {
			// A dropped table is not lost data on its own — a migration may
			// legitimately remove one — but its rows are gone, so it is
			// reported rather than ignored.
			if count > 0 {
				effect.Lost[table] = count
			}
			continue
		}
		if remaining < count {
			effect.Lost[table] = count - remaining
		}
	}
	return effect, nil
}
