package app

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/AndrewDryga/ryker/internal/audition"
	"github.com/AndrewDryga/ryker/internal/config"
	"github.com/AndrewDryga/ryker/internal/evaluation"
	"github.com/AndrewDryga/ryker/internal/webui"
)

// runAudition reports which model has earned which lane.
//
// It is the standing answer to a question that has so far been settled by
// whoever last edited the Coop ladder: every lane's correction rate and cost
// come from live traffic, every corpus's gate-pass rate and judge score come
// from runs already recorded on disk, and the two are printed apart because
// nothing in either source can honestly attribute one to the other.
//
// Nothing here calls a model. It reads a read-only copy of the state database
// and the JSON that `make eval --results` already writes, so it costs a second
// and no credentials, and can be run as often as somebody is curious.
func runAudition(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("audition", flag.ContinueOnError)
	flags.SetOutput(stderr)
	configPath := flags.String("config", defaultConfigPath(), "configuration file")
	days := flags.Int("days", 7, "how far back to read live traffic")
	historyDir := flags.String("history", defaultEvalHistoryDir(),
		"directory of recorded evaluation results")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("audition accepts no positional arguments")
	}
	if *days < 1 {
		return errors.New("--days must be positive")
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	// Read-only, like every other reporting command: an audition must never be
	// able to disturb the instance it is measuring.
	reader, err := webui.OpenReader(filepath.Join(cfg.StateDir, "responder.db"))
	if err != nil {
		return err
	}
	defer reader.Close()

	since := time.Now().UTC().AddDate(0, 0, -*days)
	lanes, err := reader.AuditionLanes(context.Background(), since)
	if err != nil {
		return err
	}
	corpora, err := recordedCorpora(*historyDir)
	if err != nil {
		return err
	}
	printAudition(stdout, audition.Build(since, lanes, corpora, cfg.Pricing), *days, *historyDir)
	return nil
}

// defaultEvalHistoryDir matches the Makefile's EVAL_HISTORY, honouring the same
// environment variable so a deployment that moved its history is read from
// where it actually is rather than from where the default says it should be.
func defaultEvalHistoryDir() string {
	if dir := strings.TrimSpace(os.Getenv("EVAL_HISTORY")); dir != "" {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".local", "state", "ryker", "eval-history")
}

// recordedCorpora reads the newest run of each corpus in the history directory.
//
// The filename carries the corpus label and the stamp — `<label>-<stamp>.json`
// — and is the only place either is recorded, because the summary inside knows
// its mode but not which corpus produced it. Newest per label rather than all
// of them: an audition is a standing answer, and ten weeks of a corpus that has
// not moved is noise around the row that matters.
//
// A file that will not decode is skipped rather than fatal. History is written
// by whatever binary was current that week, and refusing to report at all
// because one October file is malformed would lose the other forty.
func recordedCorpora(historyDir string) ([]audition.Corpus, error) {
	if strings.TrimSpace(historyDir) == "" {
		return nil, nil
	}
	matches, err := filepath.Glob(filepath.Join(historyDir, "*.json"))
	if err != nil {
		return nil, err
	}
	sort.Strings(matches)
	newest := map[string]audition.Corpus{}
	for _, path := range matches {
		label, stamp, ok := splitHistoryName(filepath.Base(path))
		if !ok {
			continue
		}
		summary, err := readEvaluationSummary(path)
		if err != nil {
			continue
		}
		newest[label] = corpusFromSummary(label, stamp, summary)
	}
	corpora := make([]audition.Corpus, 0, len(newest))
	for _, corpus := range newest {
		corpora = append(corpora, corpus)
	}
	return corpora, nil
}

func corpusFromSummary(
	label string, stamp time.Time, summary evaluation.EvaluationSummary,
) audition.Corpus {
	return audition.Corpus{
		Name: label, Recorded: stamp, Mode: summary.Mode,
		Total: summary.Total, Passed: summary.Passed, Unevaluated: summary.Unevaluated,
		JudgeEvaluated: summary.Quality.Evaluated, JudgeMean: summary.Quality.MeanScore,
		Cases: len(summary.Cases),
	}
}

// splitHistoryName reads `<label>-<UTC stamp>.json`. The label may itself carry
// hyphens — `episode-replay-blitz` is one — so the split is from the right.
func splitHistoryName(name string) (label string, stamp time.Time, ok bool) {
	trimmed := strings.TrimSuffix(name, ".json")
	cut := strings.LastIndex(trimmed, "-")
	if cut <= 0 {
		return "", time.Time{}, false
	}
	parsed, err := time.Parse("20060102T150405Z", trimmed[cut+1:])
	if err != nil {
		return "", time.Time{}, false
	}
	return trimmed[:cut], parsed, true
}

func printAudition(out io.Writer, report audition.Report, days int, historyDir string) {
	fmt.Fprintf(out, "Audition — live traffic over %d days, recorded corpora from %s\n\n",
		days, fallbackDir(historyDir))

	fmt.Fprintln(out, "LANES — what ran, what it cost, how often it had to be corrected")
	table := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	fmt.Fprintln(table, "class\tprofile\tprovider:model\teffort\tattempts\tmeasured\tcorrections\trate\tcost")
	for _, lane := range report.Lanes {
		fmt.Fprintf(table, "%s\t%s\t%s\t%s\t%d\t%s\t%d over %d\t%.2f\t%s\n",
			blank(lane.Class), blank(lane.Profile),
			blank(strings.TrimSuffix(lane.Provider+":"+lane.Model, ":")),
			blank(lane.Effort), lane.Attempts,
			measuredCell(lane), lane.Corrections, lane.CorrectedAttempts,
			lane.CorrectionRate(), laneCost(lane, report.Currency),
		)
	}
	if len(report.Lanes) == 0 {
		fmt.Fprintln(table, "—\t—\t—\t—\t0\t—\t—\t—\t—")
	}
	table.Flush()

	reported, turns := report.ReportedTotal()
	estimated, estimatedLanes := report.EstimatedTotal()
	// Printed on two lines, never one, because they are two kinds of evidence.
	fmt.Fprintf(out, "\n  provider-reported: %s over %d costed turns\n",
		money(reported, "USD"), turns)
	fmt.Fprintf(out, "  estimated:         %s over %d lanes the price list named\n",
		money(estimated, fallbackCurrency(report.Currency)), estimatedLanes)
	fmt.Fprintln(out, "  (these are never added together: one is an invoice, the other is arithmetic)")

	fmt.Fprintln(out, "\nCORPORA — what the gate and the judge said, newest run of each")
	corpusTable := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	fmt.Fprintln(corpusTable, "corpus\trecorded\tmode\tgate-pass\tjudge mean\tcases\tmodel")
	for _, corpus := range report.Corpora {
		fmt.Fprintf(corpusTable, "%s\t%s\t%s\t%.0f%% (%d/%d)\t%s\t%d\t%s\n",
			corpus.Name, corpus.Recorded.Format("2006-01-02"), blank(corpus.Mode),
			corpus.GatePassRate()*100, corpus.Passed, corpus.Total,
			judgeCell(corpus), corpus.Cases, "not recorded",
		)
	}
	if len(report.Corpora) == 0 {
		fmt.Fprintln(corpusTable, "—\t—\t—\t—\t—\t0\t—")
	}
	corpusTable.Flush()

	if len(report.Gaps) > 0 {
		fmt.Fprintln(out, "\nWHAT THIS REPORT CANNOT SAY")
		for _, gap := range report.Gaps {
			fmt.Fprintf(out, "  - %s\n", gap)
		}
	}
}

// measuredCell keeps "nobody counted this" visibly different from "this counted
// zero", which is the distinction the whole cost column rests on.
func measuredCell(lane audition.Lane) string {
	if lane.Measured == 0 {
		return "none"
	}
	return fmt.Sprintf("%d of %d", lane.Measured, lane.Attempts)
}

func laneCost(lane audition.Lane, currency string) string {
	switch {
	case lane.CostedTurns > 0:
		return money(lane.ReportedUSD, "USD") + " reported"
	case lane.Priced:
		return money(lane.EstimatedUSD, fallbackCurrency(currency)) + " estimated"
	case lane.Tokens.Recorded():
		return "not priced"
	default:
		return "not measured"
	}
}

func judgeCell(corpus audition.Corpus) string {
	if corpus.JudgeEvaluated == 0 {
		return "not scored"
	}
	return fmt.Sprintf("%.2f over %d", corpus.JudgeMean, corpus.JudgeEvaluated)
}

func money(amount float64, currency string) string {
	if amount > 0 && amount < 0.01 {
		return "<0.01 " + currency
	}
	return fmt.Sprintf("%.2f %s", amount, currency)
}

func fallbackCurrency(currency string) string {
	if strings.TrimSpace(currency) == "" {
		return "USD"
	}
	return currency
}

func fallbackDir(dir string) string {
	if strings.TrimSpace(dir) == "" {
		return "(no history directory configured)"
	}
	return dir
}

func blank(value string) string {
	if strings.TrimSpace(value) == "" {
		return "—"
	}
	return value
}
