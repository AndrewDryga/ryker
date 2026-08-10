package store

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"
)

// timestampColumns lists every TEXT column holding a stored timestamp, read
// from the live schema rather than a hand-written list.
func timestampColumns(t *testing.T, db *sql.DB) []string {
	t.Helper()
	rows, err := db.Query(
		`SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'`,
	)
	if err != nil {
		t.Fatal(err)
	}
	var tables []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatal(err)
		}
		tables = append(tables, name)
	}
	rows.Close()
	sort.Strings(tables)

	var columns []string
	for _, table := range tables {
		info, err := db.Query(fmt.Sprintf("PRAGMA table_info(%s)", table))
		if err != nil {
			t.Fatal(err)
		}
		for info.Next() {
			var (
				cid, notNull, pk int
				name, kind       string
				dflt             any
			)
			if err := info.Scan(&cid, &name, &kind, &notNull, &dflt, &pk); err != nil {
				t.Fatal(err)
			}
			if strings.HasSuffix(name, "_at") && kind == "TEXT" {
				columns = append(columns, table+"."+name)
			}
		}
		info.Close()
	}
	return columns
}

// Migration 46 must cover every timestamp column, and keep covering them as
// tables are added.
//
// A partial migration is worse than none: a fixed-width value compares just as
// wrongly against a variable-width one as the bug it replaces, so a column left
// behind does not stay half-broken, it stays broken in a way that now also
// disagrees with its neighbours. A hand-written list of 145 columns cannot be
// trusted to stay complete, so it is checked against the schema instead.
func TestMigrationCoversEveryTimestampColumn(t *testing.T) {
	dir := t.TempDir()
	st := openAt(t, dir)
	born := tablesCreatedAfterV46(t)
	for _, column := range timestampColumns(t, st.db) {
		table, name, _ := strings.Cut(column, ".")
		if born[table] {
			continue
		}
		needle := fmt.Sprintf("UPDATE %s SET %s =", table, name)
		if !strings.Contains(schemaV46, needle) {
			t.Errorf(
				"%s is a stored timestamp that migration 46 does not rewrite.\n"+
					"Add it, or its values compare wrongly against every column that was.",
				column,
			)
		}
	}
}

// tablesCreatedAfterV46 is every table a later migration brings into existence.
//
// Such a table is exempt from the check above, and the exemption is not a
// loosening. Migration 46 rewrote values that were already stored in the old
// variable-width format; a table that does not exist when 46 runs has no such
// values and never will, because everything written to it afterwards goes
// through timestampFormat. Naming it in timestampColumnsAtV46 would not fix a
// value, it would break the upgrade: the generated statement is one
// UPDATE per column, and a host coming from 45 would run
// "UPDATE quality_findings ..." eight migrations before that table is created
// and fail there. Migration 54 was the first to add a table after 46 and found
// this out.
//
// Read from the migration statements rather than listed by hand, for the same
// reason the column list is checked against the live schema instead of trusted:
// a hand-written exemption list is one nobody updates. Transient rebuild tables
// like work_episodes_rebuilt land in here too and cost nothing — they are
// renamed away before the schema this walks exists.
func tablesCreatedAfterV46(t *testing.T) map[string]bool {
	t.Helper()
	pattern := regexp.MustCompile(
		`(?i)CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?"?([A-Za-z_][A-Za-z0-9_]*)"?`,
	)
	created := map[string]bool{}
	for version, statement := range migrations {
		if version <= 46 {
			continue
		}
		for _, match := range pattern.FindAllStringSubmatch(statement, -1) {
			created[match[1]] = true
		}
	}
	return created
}

// The invariant the migration exists to establish: for stored timestamps, text
// order is chronological order.
//
// Written as a property over the values themselves rather than a spot check.
// The old format failed this for any pair inside one second whose fractions
// differed in width, which is why it was possible to document the hazard for
// months without a test noticing it.
func TestStoredTimestampTextOrderMatchesTimeOrder(t *testing.T) {
	base := time.Date(2026, 8, 7, 12, 0, 0, 0, time.UTC)
	offsets := []time.Duration{
		0, time.Nanosecond, time.Microsecond, time.Millisecond,
		500 * time.Millisecond, 530 * time.Millisecond,
		700 * time.Millisecond, 700010 * time.Microsecond,
		999999999 * time.Nanosecond,
	}
	for i, a := range offsets {
		for j, b := range offsets {
			ta, tb := base.Add(a), base.Add(b)
			sa, sb := ta.Format(timestampFormat), tb.Format(timestampFormat)
			if len(sa) != 30 {
				t.Fatalf("timestamp %q is %d bytes, not a fixed 30", sa, len(sa))
			}
			if (sa < sb) != (i < j) || (sa > sb) != (i > j) {
				t.Fatalf(
					"text order disagrees with time order:\n  %q (%v)\n  %q (%v)",
					sa, ta, sb, tb,
				)
			}
		}
	}
}

// A database written before the migration must come out of it fixed, and its
// rows must still be there.
func TestUpgradeRewritesShortenedTimestamps(t *testing.T) {
	ctx := context.Background()
	dir := writeV39Database(t)
	db, err := sql.Open("sqlite", filepath.Join(dir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	// The exact shapes found in the deployed databases: a whole second, a
	// one-digit fraction, and the six-digit fraction a microsecond clock
	// produces. The first two sort after the third under the old format.
	for id, stamp := range map[string]string{
		"inc_whole": "2026-08-07T12:00:00Z",
		"inc_short": "2026-08-07T12:00:00.5Z",
		"inc_micro": "2026-08-07T12:00:00.530000Z",
	} {
		if _, err := db.Exec(`
			INSERT INTO incidents (id, route, repository, correlation_key, title,
			  status, workflow, created_at, updated_at)
			VALUES (?, 'manual', 'repo', ?, 'keep', 'active', 'idle', ?, ?)`,
			id, id, stamp, stamp,
		); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	st := openAt(t, dir)

	rows, err := st.db.Query(`SELECT id, created_at FROM incidents ORDER BY created_at`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var order []string
	for rows.Next() {
		var id, stamp string
		if err := rows.Scan(&id, &stamp); err != nil {
			t.Fatal(err)
		}
		if len(stamp) != 30 {
			t.Fatalf("%s kept a %d-byte timestamp %q after the migration",
				id, len(stamp), stamp)
		}
		if _, err := time.Parse(timestampParseFormat, stamp); err != nil {
			t.Fatalf("%s is no longer parseable: %q: %v", id, stamp, err)
		}
		order = append(order, id)
	}
	// Sorted by text, they must now come out in time order. Under the old
	// format inc_micro sorted first and inc_whole last, exactly backwards.
	want := []string{"inc_whole", "inc_short", "inc_micro"}
	if strings.Join(order, ",") != strings.Join(want, ",") {
		t.Fatalf("rows sort as %v, want %v", order, want)
	}
	if _, err := st.GetIncident(ctx, "inc_whole"); err != nil {
		t.Fatalf("migration lost a row: %v", err)
	}
}

// Anything not ending in Z is skipped by the migration, because the padding
// expression would mangle a numeric offset. Both deployed databases contain
// none. This fails if that ever stops being true.
func TestNoStoredTimestampCarriesANumericOffset(t *testing.T) {
	dir := t.TempDir()
	st := openAt(t, dir)
	now := time.Now().UTC()
	if formatted := now.Format(timestampFormat); !strings.HasSuffix(formatted, "Z") {
		t.Fatalf("timestamps are no longer written in UTC: %q", formatted)
	}
	for _, column := range timestampColumns(t, st.db) {
		table, name, _ := strings.Cut(column, ".")
		var bad int
		if err := st.db.QueryRow(fmt.Sprintf(
			`SELECT count(*) FROM %s WHERE %s != '' AND %s NOT LIKE '%%Z'`,
			table, name, name,
		)).Scan(&bad); err != nil {
			t.Fatal(err)
		}
		if bad != 0 {
			t.Errorf("%s holds %d timestamps the migration cannot rewrite", column, bad)
		}
	}
}
