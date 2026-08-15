package webui

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/audition"
	"github.com/AndrewDryga/responder/internal/config"
)

// AuditionLanes reads the live half of the audition report.
//
// The query lives in internal/audition rather than here because the command
// runs the same one. Two spellings of "which model deserves which lane" that
// disagreed about a join would be worse than one that only existed in a
// dashboard.
func (r *Reader) AuditionLanes(ctx context.Context, since time.Time) ([]audition.Lane, error) {
	if !r.live() {
		return nil, nil
	}
	return audition.Lanes(ctx, r.db, since)
}

// AuditionRow is one lane rendered for the Decisions page.
type AuditionRow struct {
	Class, Profile, Model, Effort string
	Attempts                      int
	// Measured is a sentence rather than a number so an unmeasured lane cannot
	// be read as a measured zero.
	Measured       string
	Corrections    int
	CorrectionRate string
	// RatePct drives the proportional meter, capped at 100 for display only —
	// CorrectionRate above still reads over 1.00 where the lane earned it.
	RatePct int
	Cost    string
}

// AuditionPanel is the Decisions page's standing answer to "which model
// deserves which lane".
//
// It carries the live half only. Gate-pass rates and judge scores live in the
// evaluation history on disk, which the control plane does not read — it serves
// from the state database — so rather than render an empty column that looks
// broken, the panel says where the other half is and names the command that
// prints it. A panel that looks live and is not is worse than no panel.
type AuditionPanel struct {
	Rows     []AuditionRow
	Days     int
	Reported string
	Estimate string
	Gaps     []string
}

func (r *Reader) AuditionPanel(
	ctx context.Context, pricing config.Pricing, days int,
) (AuditionPanel, error) {
	since := time.Now().UTC().AddDate(0, 0, -days)
	lanes, err := r.AuditionLanes(ctx, since)
	if err != nil {
		return AuditionPanel{}, err
	}
	report := audition.Build(since, lanes, nil, pricing)
	panel := AuditionPanel{Days: days}
	for _, lane := range report.Lanes {
		panel.Rows = append(panel.Rows, AuditionRow{
			Class: fallback(lane.Class, "not recorded"), Profile: fallback(lane.Profile, "none"),
			Model:    fallback(strings.TrimSuffix(lane.Provider+":"+lane.Model, ":"), "not recorded"),
			Effort:   fallback(lane.Effort, "not recorded"),
			Attempts: lane.Attempts, Measured: auditionMeasured(lane),
			Corrections:    lane.Corrections,
			CorrectionRate: fmt.Sprintf("%.2f", lane.CorrectionRate()),
			RatePct:        min(int(lane.CorrectionRate()*100), 100),
			Cost:           auditionCost(lane, report.Currency),
		})
	}
	reported, turns := report.ReportedTotal()
	estimated, estimatedLanes := report.EstimatedTotal()
	// Two figures, two fields, never one. See the Usage page for the rule.
	panel.Reported = fmt.Sprintf("%s over %d costed turns", money(reported, "USD"), turns)
	panel.Estimate = fmt.Sprintf("%s over %d priced lanes",
		money(estimated, auditionCurrency(report.Currency)), estimatedLanes)
	panel.Gaps = append(report.Gaps,
		"Gate-pass rate and judge score are not here: they live in the recorded evaluation "+
			"results on disk, which this dashboard does not read. Run responder audition for "+
			"both halves.")
	return panel, nil
}

func auditionMeasured(lane audition.Lane) string {
	if lane.Measured == 0 {
		return "none measured"
	}
	return fmt.Sprintf("%d of %d measured", lane.Measured, lane.Attempts)
}

func auditionCost(lane audition.Lane, currency string) string {
	switch {
	case lane.CostedTurns > 0:
		return money(lane.ReportedUSD, "USD") + " reported"
	case lane.Priced:
		return money(lane.EstimatedUSD, auditionCurrency(currency)) + " estimated"
	case lane.Tokens.Recorded():
		return "not priced"
	default:
		return "not measured"
	}
}

func auditionCurrency(currency string) string {
	if strings.TrimSpace(currency) == "" {
		return "USD"
	}
	return currency
}
