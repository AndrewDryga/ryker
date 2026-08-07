package app

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"io"
	"path/filepath"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/store/lifecyclecheck"

	_ "modernc.org/sqlite"
)

// runLifecycleDivergence reports where the agent-run lifecycle and the episode
// lifecycle contradict each other.
//
// The cutover rule is compare projections, cut over, then delete the legacy
// path. This is the compare step. It is meant to be run against a live system
// before each slice: at rest every run is terminal, so the most dangerous
// disagreement — work still executing under an episode that says it is over —
// is invisible to a query over a stopped database.
func runLifecycleDivergence(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("lifecycle-divergence", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultConfigPath(), "configuration file")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("lifecycle-divergence accepts no positional arguments")
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	// Opened read-only and directly rather than through the store: this only
	// reads two tables, and a diagnostic should not be able to write to the
	// database it is diagnosing.
	db, err := sql.Open("sqlite", "file:"+
		filepath.Join(cfg.StateDir, "responder.db")+"?mode=ro")
	if err != nil {
		return err
	}
	defer db.Close()

	report, err := lifecyclecheck.Divergences(context.Background(), db)
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "%d episodes.\n\n", report.Episodes)
	if report.Episodes == 0 {
		// The same trap the correction-rate reader documents: an empty result
		// and a broken instrument look identical from the outside.
		fmt.Fprintln(stdout, "No episodes; this proves nothing about the cutover.")
		return nil
	}
	for _, section := range []struct {
		label string
		ids   []string
		note  string
	}{
		{"work running under a finished episode", report.RunningUnderFinished,
			"the episode says it is over while work continues"},
		{"episode executing with no live run", report.ExecutingWithoutRun,
			"stalled: nothing is advancing it"},
		{"episode and its latest run disagree on the outcome", report.OutcomeConflict,
			"the two lifecycles reached different answers about the same work"},
		{"state is not the projection of lifecycle_state", report.ProjectionMismatch,
			"one column was written without the other"},
	} {
		fmt.Fprintf(stdout, "  %-52s %4d\n", section.label, len(section.ids))
		for _, id := range section.ids {
			fmt.Fprintf(stdout, "      %s  (%s)\n", id, section.note)
		}
	}
	fmt.Fprintln(stdout)
	if report.Clean() {
		fmt.Fprintln(stdout,
			"The projections agree. The legacy lifecycle carries nothing the\n"+
				"episode does not, so a cutover slice can proceed — but run this\n"+
				"against a busy system, not an idle one, before believing it.")
		return nil
	}
	fmt.Fprintln(stdout, "The projections disagree. Do not cut over until this is explained.")
	return nil
}
