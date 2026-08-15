package app

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/store/intelligencestore"
)

// backfillOutcomesFailureExamples bounds the ids the report carries. A backfill
// that fails on four hundred episodes written by the same old schema has one
// cause, and printing four hundred ids buries it.
const backfillOutcomesFailureExamples = 5

// backfillOutcomesReport is what one backfill run amounts to.
//
// The per-source counts are the finding, not the totals. A backfilled corpus is
// mostly fallback by construction — retention has already deleted the
// slack_inputs row for most finished episodes — so "398 rows written" says
// almost nothing on its own, and "230 of them were fingerprinted from a
// truncated headline" says what the corpus is actually worth.
type backfillOutcomesReport struct {
	DryRun   bool `json:"dry_run"`
	Examined int  `json:"examined"`
	// Projected counts the rows the projection built and wrote. Under
	// --dry-run they were written to a private copy and discarded.
	Projected      int      `json:"projected"`
	Skipped        int      `json:"skipped"`
	Failed         int      `json:"failed"`
	FailedEpisodes []string `json:"failed_episodes,omitempty"`
	// FingerprintSource counts rows by where their symptom tokens came from,
	// keyed by the intelligencestore constants the rows themselves record.
	FingerprintSource map[string]int `json:"fingerprint_source"`
	// FallbackRows is every row not fingerprinted from the trigger text: the
	// single number that says how much of this corpus is weak.
	FallbackRows int `json:"fallback_rows"`
	// LimitReached says the run stopped at --limit with more episodes left, so
	// a zero on the next line does not read as "the backfill is complete".
	LimitReached bool `json:"limit_reached"`
}

// backfillFingerprintSources orders the report from the strongest recall source
// to the weakest, because that ordering is the point of printing it.
var backfillFingerprintSources = []struct {
	source  string
	meaning string
}{
	{intelligencestore.FingerprintFromTrigger, "what the operator actually wrote"},
	{intelligencestore.FingerprintFromAlert, "the alert title and its label values"},
	{intelligencestore.FingerprintFromControl, "the control that was clicked, plus the headline"},
	{intelligencestore.FingerprintFromObjective, "the 180-byte truncated headline, and nothing else"},
}

// runBackfillOutcomes projects the finished episodes that predate the
// projection into recall rows.
//
// The projection rides the transaction that makes an episode terminal, so it
// only ever fires forward. Every deployed database holds hundreds of completed
// and blocked episodes — evidence, verdicts, verified fixes — with no recall
// row at all, and recall cannot see one of them. Without this command the
// corpus that lets a new incident be told what a similar old one turned out to
// be begins at whatever happened to finish after the deploy.
//
// It opens the store rather than a read-only handle, which means it migrates
// the database and writes to it. Responder must be stopped first: the command
// takes the same process lock serve does rather than racing a live writer
// through a schema change.
//
// --dry-run answers the same question against a private copy of the database,
// so the preview comes from the projection itself rather than from a second
// implementation of it that could quietly disagree with the real one.
func runBackfillOutcomes(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("backfill-outcomes", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultConfigPath(), "configuration file")
	limit := flags.Int("limit", 5000, "maximum episodes to project in one run")
	dryRun := flags.Bool("dry-run", false, "report what would be written without writing it")
	jsonOutput := flags.Bool("json", false, "print JSON")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("backfill-outcomes accepts no positional arguments")
	}
	if *limit < 1 {
		return errors.New("--limit must be positive")
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	if err := ensurePrivateDirectory(cfg.StateDir); err != nil {
		return err
	}
	// A backfill reads a deployment's history; it does not create one. Without
	// this, a mistyped --config would open a fresh database, find no finished
	// episodes and report a completed backfill — the failure this repository
	// keeps meeting, where an empty result and a broken instrument look
	// identical from the outside.
	if _, err := os.Stat(filepath.Join(cfg.StateDir, "responder.db")); err != nil {
		return fmt.Errorf("no deployed database in %s: %w", cfg.StateDir, err)
	}
	lock, err := acquireProcessLock(cfg.StateDir)
	if err != nil {
		return fmt.Errorf("stop Responder before backfilling outcomes: %w", err)
	}
	defer releaseProcessLock(lock)

	stateDir := cfg.StateDir
	if *dryRun {
		// The preview runs the real projection against a copy. Reimplementing
		// the fingerprint rules here to predict the answer would put a second
		// copy of the policy in the CLI, and the moment the two disagreed the
		// preview would be confidently wrong about the only number anybody
		// reads it for.
		temporary, err := os.MkdirTemp("", "responder-backfill-outcomes-")
		if err != nil {
			return err
		}
		defer os.RemoveAll(temporary)
		stateDir = filepath.Join(temporary, "state")
		if err := os.MkdirAll(stateDir, 0o700); err != nil {
			return err
		}
		if err := copyDatabaseWithLog(cfg.StateDir, stateDir); err != nil {
			return err
		}
	}
	st, err := store.Open(stateDir)
	if err != nil {
		return err
	}
	defer st.Close()

	report, err := backfillOutcomes(context.Background(), st, *limit, *dryRun)
	if err != nil {
		return err
	}
	if *jsonOutput {
		encoded, err := json.MarshalIndent(report, "", "  ")
		if err != nil {
			return err
		}
		fmt.Fprintln(stdout, string(encoded))
		return nil
	}
	printBackfillOutcomes(stdout, report, cfg.StateDir)
	return nil
}

// copyDatabaseWithLog copies the deployed database and the write-ahead log
// beside it.
//
// copyDatabase takes the main file alone, which is all migration-check needs:
// it asks what the schema would do, and the schema is in the main file. This
// asks how many rows are there, and that answer is spread across both — the
// store runs PRAGMA journal_mode = WAL, so everything committed since the last
// checkpoint lives in responder.db-wal and none of it is in responder.db.
//
// A preview built from the main file alone silently under-reports, and the
// under-report is the worst possible shape: "0 episodes to backfill" reads
// exactly like "already done", so an operator would skip the run that the
// corpus is waiting for. The exclusive process lock this command holds is what
// makes the pair coherent — nothing is writing between the two copies.
//
// The -shm file is deliberately not copied: it is a rebuildable index over the
// log, and SQLite recreates it when it recovers the log it does have.
func copyDatabaseWithLog(fromStateDir, toStateDir string) error {
	if err := copyDatabase(fromStateDir, toStateDir); err != nil {
		return err
	}
	log, err := os.ReadFile(filepath.Join(fromStateDir, "responder.db-wal"))
	if errors.Is(err, os.ErrNotExist) {
		// A cleanly closed database has already checkpointed and removed it.
		return nil
	}
	if err != nil {
		return fmt.Errorf("read the deployed write-ahead log: %w", err)
	}
	return os.WriteFile(filepath.Join(toStateDir, "responder.db-wal"), log, 0o600)
}

func backfillOutcomes(
	ctx context.Context,
	st *store.Store,
	limit int,
	dryRun bool,
) (backfillOutcomesReport, error) {
	pending, err := st.Intelligence.ListEpisodesAwaitingOutcome(ctx, limit)
	if err != nil {
		return backfillOutcomesReport{}, err
	}
	report := backfillOutcomesReport{
		DryRun: dryRun, Examined: len(pending), LimitReached: len(pending) == limit,
		FingerprintSource: make(map[string]int, len(backfillFingerprintSources)),
	}
	for _, episode := range pending {
		// The query selects the recallable states and this asks the policy
		// directly; they are two statements of one rule and this counts the
		// disagreement instead of trusting it. It is load-bearing rather than
		// defensive: ProjectEpisodeOutcome returns a zero outcome and no error
		// for a state it refuses, so without this check a drift would count
		// rows that were never written, under an empty fingerprint source.
		if !intelligencestore.RecallableTerminalState(string(episode.State)) {
			report.Skipped++
			continue
		}
		outcome, err := st.Intelligence.ProjectEpisodeOutcome(
			ctx, episode.ID, string(episode.State), episode.CompletedAt,
		)
		if err != nil {
			// One episode written by a schema three migrations ago must not
			// abandon the several hundred behind it. The whole value of the
			// corpus is its size, and a backfill that stops at the first
			// unreadable row is a backfill nobody can finish.
			report.Failed++
			if len(report.FailedEpisodes) < backfillOutcomesFailureExamples {
				report.FailedEpisodes = append(report.FailedEpisodes, episode.ID)
			}
			continue
		}
		report.Projected++
		report.FingerprintSource[outcome.FingerprintSource]++
		if outcome.FingerprintSource != intelligencestore.FingerprintFromTrigger {
			report.FallbackRows++
		}
	}
	return report, nil
}

func printBackfillOutcomes(stdout io.Writer, report backfillOutcomesReport, stateDir string) {
	fmt.Fprintf(stdout, "Examined %d finished episodes with no recall row.\n", report.Examined)
	if report.Examined == 0 {
		fmt.Fprintf(stdout,
			"Every completed and blocked episode already has one, so there is\n"+
				"nothing to backfill. That is also what a run against the wrong\n"+
				"deployment looks like; this one read %s.\n", stateDir)
		return
	}
	verb := "Wrote"
	if report.DryRun {
		verb = "Would write"
	}
	fmt.Fprintf(stdout, "%s %d rows; skipped %d; %d could not be projected.\n",
		verb, report.Projected, report.Skipped, report.Failed)
	if report.Failed > 0 {
		fmt.Fprintf(stdout,
			"  left for a later run: %v\n"+
				"  A failure here is one episode, not the backfill; the rest were projected.\n",
			report.FailedEpisodes)
	}
	if report.LimitReached {
		fmt.Fprintln(stdout,
			"  --limit was reached, so more episodes are still waiting. Run it again.")
	}
	if report.Projected == 0 {
		return
	}
	fmt.Fprintf(stdout, "\nFingerprint source of the %d rows:\n", report.Projected)
	for _, entry := range backfillFingerprintSources {
		fmt.Fprintf(stdout, "  %-16s %5d  %s\n",
			entry.source, report.FingerprintSource[entry.source], entry.meaning)
	}
	if report.FallbackRows == 0 {
		fmt.Fprintln(stdout,
			"\nEvery row was fingerprinted from the real trigger text, which is unusual for\n"+
				"a backfill: it means retention has not yet pruned the slack_inputs rows\n"+
				"these episodes came from. Expect the proportion to fall on an older\n"+
				"database.")
	} else {
		fmt.Fprintf(stdout,
			"\n%d of %d rows (%.0f%%) were fingerprinted from something weaker than the\n"+
				"trigger text. That is expected — retention deletes finished Slack inputs,\n"+
				"so most old episodes no longer hold what the operator wrote — and it is not\n"+
				"a formality. A row built from the objective is built from a display headline\n"+
				"truncated at 180 bytes: it frequently stops mid-sentence, and the words that\n"+
				"identify the symptom are often not in it at all, so recall ranks that row on\n"+
				"vocabulary the incident never contained. Alert labels are real symptom\n"+
				"vocabulary and are stronger than that; the trigger text is stronger still.\n"+
				"Every row records which of the four it used, so the weak ones can be\n"+
				"discounted, re-derived or excluded when the corpus is measured. A corpus\n"+
				"that could not say which of its rows are weak could not be audited at all.\n",
			report.FallbackRows, report.Projected,
			100*float64(report.FallbackRows)/float64(report.Projected))
	}
	if report.DryRun {
		fmt.Fprintf(stdout,
			"\nDry run: this was projected against a private copy and discarded. Nothing\n"+
				"was written to %s.\n", stateDir)
	}
}
