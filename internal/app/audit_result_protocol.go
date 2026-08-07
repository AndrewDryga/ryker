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
