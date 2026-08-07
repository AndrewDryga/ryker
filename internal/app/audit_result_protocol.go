package app

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/service"
	"github.com/AndrewDryga/responder/internal/store"
)

// runAuditResultProtocol replays stored model results and reports how many
// would take the legacy compatibility fallback.
//
// The forward counters answer "does anything still rely on the legacy reading?"
// by watching for seven days after a deploy. This answers the same question
// from history already in the database, which is available now. Retiring the
// fallback is gated on that evidence, and six backlog items are gated on
// retiring the fallback.
// runCorrectionRate reports how often the host had to send a result back to
// the model, and for what.
//
// This is the closest thing Responder has to a measure of whether it is getting
// better. Pass rates on a fixed corpus say whether it still does what it did;
// the correction rate over real traffic says whether it is doing it well, and
// the trend is what matters rather than any single number.
func runCorrectionRate(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("correction-rate", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultConfigPath(), "configuration file")
	days := flags.Int("days", 7, "how far back to report")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("correction-rate accepts no positional arguments")
	}
	if *days < 1 {
		return errors.New("--days must be positive")
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	st, err := store.OpenCurrent(cfg.StateDir)
	if err != nil {
		return err
	}
	defer st.Close()

	since := time.Now().UTC().AddDate(0, 0, -*days)
	counts, turns, err := st.CorrectionRate(context.Background(), since)
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "Last %d days: %d finished turns.\n\n", *days, turns)
	if turns == 0 {
		fmt.Fprintln(stdout, "No turns in this window; nothing can be concluded.")
		return nil
	}
	total := 0
	for _, class := range service.CorrectionClasses() {
		count := counts[class]
		total += count
		fmt.Fprintf(stdout, "  %-12s %4d  %5.1f%% of turns\n",
			class, count, 100*float64(count)/float64(turns))
	}
	fmt.Fprintf(stdout, "\n  %-12s %4d  %5.1f%% of turns\n",
		"any", total, 100*float64(total)/float64(turns))
	if total == 0 {
		// The same trap the legacy-fallback counters fell into: a clean zero
		// and a broken instrument look identical. Corrections are common enough
		// in normal operation that zero across every class, over a window with
		// real traffic, is much more likely to mean the recording is not
		// deployed than that nothing was ever wrong.
		fmt.Fprintf(stdout,
			"\nZero corrections across %d turns is more likely to mean this build "+
				"is not the one that ran them than that nothing was corrected. "+
				"Check that the deployment postdates correction recording before "+
				"reading this as good news.\n", turns)
		return nil
	}
	fmt.Fprintln(stdout,
		"\nA correction means the host refused a result and told the model why. "+
			"Falling is good; the level matters less than the direction.")
	return nil
}

func runAuditResultProtocol(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("audit-result-protocol", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultConfigPath(), "configuration file")
	days := flags.Int("days", 30, "how far back to replay")
	jsonOutput := flags.Bool("json", false, "print JSON")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("audit-result-protocol accepts no positional arguments")
	}
	if *days < 1 {
		return errors.New("--days must be positive")
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	// Read-only: auditing must never disturb a running instance.
	st, err := store.OpenCurrent(cfg.StateDir)
	if err != nil {
		return err
	}
	defer st.Close()

	ctx := context.Background()
	since := time.Now().UTC().AddDate(0, 0, -*days)
	stored, err := st.ListStoredResults(ctx, since, 5000)
	if err != nil {
		return err
	}
	results := make([]service.StoredResult, 0, len(stored))
	for _, item := range stored {
		results = append(results, service.StoredResult{
			RunID: item.RunID, Mode: item.Mode, Message: item.Message, CreatedAt: item.CreatedAt,
		})
	}
	audit := service.AuditResultProtocol(results, time.Now().UTC())

	if *jsonOutput {
		encoded, err := json.MarshalIndent(audit, "", "  ")
		if err != nil {
			return err
		}
		fmt.Fprintln(stdout, string(encoded))
		return nil
	}
	fmt.Fprintf(stdout, "Replayed %d stored results from the last %d days.\n\n", audit.Total, *days)
	fmt.Fprintf(stdout, "  typed operations   %d\n", audit.Typed)
	fmt.Fprintf(stdout, "  legacy shape only  %d\n", audit.LegacyOnly)
	fmt.Fprintf(stdout, "  legacy fallback    %d\n", audit.Fallback)
	fmt.Fprintf(stdout, "  unparsed           %d\n\n", audit.Unparsed)
	switch {
	case audit.Total == 0:
		fmt.Fprintln(stdout, "No stored results in this window; nothing can be concluded.")
	case audit.Fallback == 0:
		fmt.Fprintln(stdout,
			"Nothing in this window needed the legacy fallback. That is evidence the\n"+
				"compatibility path can be retired, not proof: it measures history under\n"+
				"the prompt that produced it, so a later prompt revision could reintroduce\n"+
				"the legacy shape.")
	default:
		fmt.Fprintf(stdout,
			"%d results needed the legacy fallback. Retiring it now would change how\n"+
				"those turns are read. Reasons: %v\nExample runs: %v\n",
			audit.Fallback, audit.Reasons, audit.Examples)
	}
	return nil
}
