package app

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/store"
)

// runMigrationCheck reports what this build's migrations would do to a real
// database, without touching it.
//
// A migration that passes every test can still destroy production data, because
// the tests do not have production's shape. This copies the deployed database
// and migrates the copy, so the answer comes from the rows that actually exist
// rather than from a fixture someone imagined.
//
// It is the check to run before deploying a build that migrates. On 2026-08-07
// it would have caught, mechanically, a migration that deleted 352 attempts,
// 332 commitments and 9934 episode events while reporting success.
func runMigrationCheck(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("migration-check", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultConfigPath(), "configuration file")
	keep := flags.String("keep", "", "directory to leave the migrated copy in for inspection")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("migration-check accepts no positional arguments")
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}

	destination := *keep
	if destination == "" {
		temporary, err := os.MkdirTemp("", "responder-migration-check-")
		if err != nil {
			return err
		}
		defer os.RemoveAll(temporary)
		destination = filepath.Join(temporary, "state")
	}
	if err := os.MkdirAll(destination, 0o700); err != nil {
		return err
	}
	if err := copyDatabase(cfg.StateDir, destination); err != nil {
		return err
	}

	effect, err := store.CheckMigration(destination)
	if err != nil {
		return fmt.Errorf("the migration failed against real data: %w", err)
	}
	fmt.Fprintln(stdout, effect.Describe())
	if effect.Safe() {
		return nil
	}
	return errors.New(
		"this build's migrations lose data on the deployed database; do not deploy it",
	)
}

// copyDatabase copies the database file only.
//
// Only the file, and only in this direction. Everything else in a state
// directory — Coop sessions, credentials, worktrees — is either irrelevant to a
// migration or actively dangerous to duplicate, and the source is opened
// read-only so a check can never be what damages the thing it is checking.
func copyDatabase(fromStateDir, toStateDir string) error {
	source, err := os.Open(filepath.Join(fromStateDir, "responder.db"))
	if err != nil {
		return fmt.Errorf("read the deployed database: %w", err)
	}
	defer source.Close()
	destination, err := os.OpenFile(
		filepath.Join(toStateDir, "responder.db"),
		os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600,
	)
	if err != nil {
		return err
	}
	defer destination.Close()
	if _, err := io.Copy(destination, source); err != nil {
		return fmt.Errorf("copy the deployed database: %w", err)
	}
	return destination.Sync()
}
