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
	// Lost is every table that ended with fewer rows than it started with and
	// was not declared in intendedDeletions. This is the field the check exists
	// for: a migration that drops rows is almost never doing what its author
	// intended, and it reports success while doing it.
	Lost map[string]int
	// Removed is the declared deletions, counted. Not a failure, and not
	// silence either: a migration whose purpose is to delete rows should say
	// how many it deleted from the database it is about to be deployed to,
	// which is the number nobody has until the check prints it.
	Removed map[string]int
	// Dropped is every table that is not there afterwards, empty or not.
	//
	// An empty table going away costs no rows, so it never reaches Lost and,
	// until this field existed, it reached nothing at all: the report said "no
	// rows lost across 121 tables" and the operator had no way to see that two
	// of the 123 they started with were gone. Same reasoning as Removed — the
	// deploy's effect belongs in the output, not only in the migration's
	// comment.
	Dropped []string
	// Dangling counts references left pointing at nothing.
	Dangling int
}

// intendedDeletions names the migrations whose purpose is to remove rows, and
// the exact tables they are permitted to remove them from.
//
// This is a declaration, not a waiver. Everything absent from it still fails on
// a single lost row, migration 51 still fails if it reaches any table but the
// one named here, and the count is still printed — so the exemption cannot hide
// the deletion, only stop it being reported as an accident.
//
// 51 deletes the waiting events that were written once per second while a run
// queued behind another turn. There are 5,467 of them on tenant and 327 on
// emisar, all with the same payload, and removing them is the entire point of
// the migration. Every other row in that table survives it, including one per
// run to say the waiting happened.
var intendedDeletions = map[int]map[string]bool{
	51: {"work_episode_events": true},
}

// deletionIsIntended reports whether a migration between two versions declared
// that it removes rows from this table. The range matters: a host upgrading
// from 47 runs 48 through 51 in one pass, and the declaration belongs to the
// step that made it, not to wherever the host happened to stop.
func deletionIsIntended(fromVersion, toVersion int, table string) bool {
	for version := fromVersion + 1; version <= toVersion; version++ {
		if intendedDeletions[version][table] {
			return true
		}
	}
	return false
}

// Safe reports whether the migration can be trusted with real data.
func (e MigrationEffect) Safe() bool {
	return len(e.Lost) == 0 && e.Dangling == 0
}

// Describe renders the effect for a person deciding whether to deploy.
func (e MigrationEffect) Describe() string {
	report := fmt.Sprintf("schema %d -> %d", e.FromVersion, e.ToVersion)
	if e.Safe() {
		report += fmt.Sprintf(
			", no rows lost across %d tables, no dangling references", len(e.After),
		)
	} else {
		report += " UNSAFE:"
		for _, table := range sortedTables(e.Lost) {
			report += fmt.Sprintf(
				"\n  %s lost %d rows (%d -> %d)",
				table, e.Lost[table], e.Before[table], e.After[table],
			)
		}
		if e.Dangling > 0 {
			report += fmt.Sprintf("\n  %d dangling references", e.Dangling)
		}
	}
	// Printed whether or not the migration is safe. An operator reading this to
	// decide on a deploy needs the declared deletions in front of them,
	// especially when everything else came back clean.
	for _, table := range sortedTables(e.Removed) {
		report += fmt.Sprintf(
			"\n  %s removed %d rows on purpose (%d -> %d)",
			table, e.Removed[table], e.Before[table], e.After[table],
		)
	}
	for _, table := range e.Dropped {
		report += fmt.Sprintf(
			"\n  %s dropped, holding %d rows", table, e.Before[table],
		)
	}
	return report
}

func sortedTables(counts map[string]int) []string {
	tables := make([]string, 0, len(counts))
	for table := range counts {
		tables = append(tables, table)
	}
	sort.Strings(tables)
	return tables
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
	effect.Removed = map[string]int{}
	for table, count := range effect.Before {
		remaining, present := effect.After[table]
		if !present {
			// A dropped table is not lost data on its own — a migration may
			// legitimately remove one — but its rows are gone, so it is
			// reported rather than ignored. A declared deletion never covers
			// this: permission to delete rows from a table is not permission to
			// take the table away.
			effect.Dropped = append(effect.Dropped, table)
			if count > 0 {
				effect.Lost[table] = count
			}
			continue
		}
		if remaining >= count {
			continue
		}
		if deletionIsIntended(effect.FromVersion, effect.ToVersion, table) {
			effect.Removed[table] = count - remaining
			continue
		}
		effect.Lost[table] = count - remaining
	}
	sort.Strings(effect.Dropped)
	return effect, nil
}
