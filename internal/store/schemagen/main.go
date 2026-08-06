// Command schemagen prints the complete schema a freshly opened store produces.
//
// It regenerates the baselineSchema constant in internal/store/schema.go after
// enough migrations have accumulated and every deployed database has passed the
// new minimumUpgradableVersion:
//
//	go run ./internal/store/schemagen "$(mktemp -d)" > /tmp/baseline.sql
//
// The store's own tests compare a baseline-built database against one upgraded
// through the surviving migrations, so a stale baseline fails CI.
package main

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/AndrewDryga/responder/internal/store"
	_ "modernc.org/sqlite"
)

func main() {
	dir := os.Args[1]
	st, err := store.Open(dir)
	if err != nil {
		panic(err)
	}
	st.Close()
	db, err := sql.Open("sqlite", filepath.Join(dir, "responder.db"))
	if err != nil {
		panic(err)
	}
	defer db.Close()
	rows, err := db.Query(`SELECT type, name, tbl_name, sql FROM sqlite_master
		WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY tbl_name, type DESC, name`)
	if err != nil {
		panic(err)
	}
	defer rows.Close()
	type obj struct{ kind, name, table, sql string }
	var objs []obj
	for rows.Next() {
		var o obj
		if err := rows.Scan(&o.kind, &o.name, &o.table, &o.sql); err != nil {
			panic(err)
		}
		objs = append(objs, o)
	}
	sort.SliceStable(objs, func(i, j int) bool {
		if objs[i].table != objs[j].table {
			return objs[i].table < objs[j].table
		}
		if objs[i].kind != objs[j].kind {
			return objs[i].kind == "table"
		}
		return objs[i].name < objs[j].name
	})
	for _, o := range objs {
		fmt.Printf("%s;\n\n", o.sql)
	}
	var v int
	_ = db.QueryRow(`SELECT version FROM schema_version`).Scan(&v)
	fmt.Fprintf(os.Stderr, "version=%d objects=%d\n", v, len(objs))
}
