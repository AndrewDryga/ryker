package store

// schemaV55 removes the two tables the action-proposal feature never filled.
//
// A proposal was an operational action the model suggested and a Slack operator
// approved, and it required an entry in the configuration's `actions` map to
// exist at all. Loading a configuration with a non-empty `actions` map has been
// a hard error for several releases, and neither deployed configuration sets the
// key, so no row was ever writable. Measured on copies of both deployed
// databases before this migration was written: action_proposals 0 rows,
// proposal_approvals 0 rows, on blitz and on emisar alike.
//
// Dropped rather than left standing. An empty table is cheap, but it is not
// free: it appears in the schema dump, in every backup, in the ER diagram, and
// in the list anyone reads to learn what Ryker stores — where it describes a
// capability the binary does not have. The previous commit removed every line of
// Go that could read or write either table, so leaving them would be leaving two
// tables with no reader, no writer, and no retention policy, which is the
// half-deleted state that is worse than either whole.
//
// The check that guards deploys stays armed through this. CheckMigration treats
// a table that disappears with rows in it as lost data and refuses the build,
// and says so explicitly: permission to delete rows is not permission to take
// the table away, so no intendedDeletions entry can excuse it. That is why this
// needs no declaration — the tables are empty, so nothing is lost — and it is
// also the safety net: run against a database where somebody did configure an
// action and get a proposal recorded, this migration is reported UNSAFE and the
// deploy stops. The declaration migration 51 needed is for a migration that
// deletes rows on purpose; this one deletes none.
//
// proposal_approvals goes first because it holds the foreign key into
// action_proposals. Nothing else references either table, so nothing cascades.
// Migration 46 still rewrites both tables' timestamp columns: it is frozen
// history that runs before this one on any database old enough to need it, and
// a migration has to do the same thing to every database that runs it.
//
// baselineSchema is left alone, as its own comment asks. It is the schema
// exactly as it stood at version 40, where both tables existed, so a fresh
// install creates them and this migration takes them away again a few steps
// later — the same route migration 40 takes for the effect ledger. The check
// that a fresh database and an upgraded one end up identical is what proves it.
//
// No table is rebuilt here, so 54 stays out of tableRebuildMigrations and runs
// with foreign keys enforced. Running it twice drops nothing the second time.
const schemaV55 = `
DROP TABLE IF EXISTS proposal_approvals;

DROP INDEX IF EXISTS proposals_source_once_idx;
DROP INDEX IF EXISTS proposals_incident_idx;
DROP TABLE IF EXISTS action_proposals;
`
