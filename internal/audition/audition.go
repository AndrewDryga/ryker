// Package audition answers one standing question: which model deserves which
// lane.
//
// It is a flashlight, not an autopilot. Nothing here promotes, demotes or routes
// anything; it counts what already happened and puts the four figures that
// matter beside each other so a person can decide. The four are gate-pass rate,
// mean judge score, correction rate and cost — never similarity to some
// frontier model's prose, which is the metric this deliberately does not have.
//
// The report has two halves and they are NOT joined, because the data cannot
// honestly be joined. Recorded evaluation runs know the corpus and the pass rate
// and the judge's score, and record no provider or model anywhere in the summary
// they write. Live traffic knows the provider, the model, the effort and every
// correction the host issued, and has no gate to pass. Presenting one grid keyed
// by both would mean inventing the attribution that neither source holds, so the
// halves are printed one after the other with the gap stated.
package audition

import (
	"sort"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
)

// Lane is one (case class x requested profile x effective model) row of live
// traffic. The class is the run's mode, which is the only case class the
// database keeps; the requested profile and the effective target are recorded
// separately because a profile selects a session policy and Coop's ladder
// rotates underneath it, so the model that answered is regularly not the one
// that was asked for. A report that showed only one of them would be answering
// a different question than the one it was opened for.
type Lane struct {
	Class    string
	Profile  string
	Provider string
	Model    string
	Effort   string

	// Attempts is every manifest in the window. Measured is the subset a
	// provider reported any token for. They are two figures and stay two:
	// "this turn used zero tokens" and "nobody counted this turn" are
	// different facts, and averaging over the first when you meant the second
	// is how a dashboard reports a model as free.
	Attempts int
	Measured int

	// Corrections is how many times the host sent a result back, and
	// CorrectedAttempts how many attempts drew at least one. A single attempt
	// can be corrected repeatedly, so the ratio of the two is itself worth
	// reading: six corrections over one attempt is a different problem from
	// six over six.
	Corrections       int
	CorrectedAttempts int

	Tokens core.ContextUsage

	// ReportedUSD is money a provider actually charged, over CostedTurns turns.
	// EstimatedUSD is what the configured price list says the measured tokens
	// would have cost. They are never added together and never rendered as one
	// number: one is evidence and the other is arithmetic, and a total that
	// mixes them cannot be checked against an invoice.
	CostedTurns  int
	ReportedUSD  float64
	EstimatedUSD float64
	// Priced records that the price list had an entry for this provider and
	// model. Without it an EstimatedUSD of zero means "not priced", which reads
	// exactly like "free".
	Priced bool
}

// CorrectionRate is corrections per attempt, which is deliberately not capped
// at one: the number that matters is how much re-work a lane costs, and an
// episode corrected six times cost six corrections.
func (l Lane) CorrectionRate() float64 {
	if l.Attempts == 0 {
		return 0
	}
	return float64(l.Corrections) / float64(l.Attempts)
}

// Unmeasured is the attempts no provider counted. Reported separately from
// Attempts so a lane running on an adapter that reports nothing — the ACP path
// does exactly this — reads as unmeasured rather than as cheap.
func (l Lane) Unmeasured() int { return l.Attempts - l.Measured }

// Corpus is one recorded evaluation run, as the results file wrote it.
//
// Model and Provider are absent on purpose and not by oversight:
// evaluation.EvaluationSummary records neither, so a corpus row cannot say
// which model earned its pass rate. Filling that in from the config of whoever
// happens to be reading would be a guess wearing a measurement's clothes.
type Corpus struct {
	Name     string
	Recorded time.Time
	Mode     string

	Total       int
	Passed      int
	Unevaluated int

	// JudgeEvaluated is how many answers the judge actually scored, which is
	// not Total: the judge runs on a subset and only where credentials allowed
	// it. A mean over an unstated denominator is the same lie as a cost over an
	// unstated one.
	JudgeEvaluated int
	JudgeMean      float64

	Cases int
}

// GatePassRate is the promotion metric, and the reason this package exists in
// the shape it does. It is a pass rate against recorded assertions — never a
// similarity score against another model's prose.
func (c Corpus) GatePassRate() float64 {
	if c.Total == 0 {
		return 0
	}
	return float64(c.Passed) / float64(c.Total)
}

// Report is what one audition prints or renders.
type Report struct {
	Since   time.Time
	Lanes   []Lane
	Corpora []Corpus

	// Currency and Priced describe the price list, so an empty cost column can
	// say which kind of empty it is.
	Currency string
	Priced   bool

	// Gaps are the honest empties: every part of the report that has no rows,
	// and what would put rows in it. A panel that renders blank teaches people
	// to stop looking at it.
	Gaps []string
}

// ReportedTotal and EstimatedTotal are separate methods for the same reason the
// fields are separate. There is deliberately no Total().
func (r Report) ReportedTotal() (amount float64, turns int) {
	for _, lane := range r.Lanes {
		amount += lane.ReportedUSD
		turns += lane.CostedTurns
	}
	return amount, turns
}

func (r Report) EstimatedTotal() (amount float64, lanes int) {
	for _, lane := range r.Lanes {
		if !lane.Priced || lane.CostedTurns > 0 {
			continue
		}
		amount += lane.EstimatedUSD
		lanes++
	}
	return amount, lanes
}

// Build assembles a report from the two sources and states what is missing.
//
// pricing is applied here rather than in the query because the rule it enforces
// is a judgement, not arithmetic: a lane whose provider reported money is
// costed by the provider and is NOT also estimated, because two numbers for one
// turn invite somebody to add them. This is the same discipline the Usage page
// applies in priceUsage; it is restated over this package's own row type rather
// than reaching across into a presentation package, and the test beside it pins
// the never-sum rule so the two cannot drift into disagreeing.
func Build(since time.Time, lanes []Lane, corpora []Corpus, pricing config.Pricing) Report {
	report := Report{
		Since: since, Lanes: lanes, Corpora: corpora,
		Currency: pricing.Currency, Priced: len(pricing.Models) > 0,
	}
	for index := range report.Lanes {
		lane := &report.Lanes[index]
		if lane.CostedTurns > 0 {
			// Provider-reported wins outright. Estimating it as well would put
			// two figures on one lane with no way to tell which an invoice
			// should match.
			continue
		}
		if !lane.Tokens.Recorded() {
			// Nothing was counted, so there is nothing to price. Leaving
			// Priced false here is what stops the row rendering 0.00.
			continue
		}
		amount, known := pricing.Cost(lane.Provider, lane.Model, lane.Tokens)
		if !known {
			continue
		}
		lane.EstimatedUSD, lane.Priced = amount, true
	}
	sort.SliceStable(report.Lanes, func(i, j int) bool {
		return report.Lanes[i].Attempts > report.Lanes[j].Attempts
	})
	sort.SliceStable(report.Corpora, func(i, j int) bool {
		if report.Corpora[i].Name != report.Corpora[j].Name {
			return report.Corpora[i].Name < report.Corpora[j].Name
		}
		return report.Corpora[i].Recorded.After(report.Corpora[j].Recorded)
	})
	report.Gaps = gaps(report)
	return report
}

// gaps names every empty the report is carrying, in the words that say what
// would fill it. "No data" is not one of them: an operator reading an empty
// panel needs to know whether the machine is broken, the window is wrong, or
// the thing simply has not been run.
func gaps(report Report) []string {
	var notes []string
	if len(report.Lanes) == 0 {
		notes = append(notes,
			"No attempts in the window, so no lane has a correction rate or a cost yet. "+
				"Widen --days, or check that this deployment has answered anything.")
	}
	if len(report.Corpora) == 0 {
		notes = append(notes,
			"No recorded evaluation runs were found, so no lane has a gate-pass rate or a "+
				"judge score. Run a corpus with --results into the history directory; "+
				"make eval writes there already.")
	}
	measured, unpriced := 0, 0
	for _, lane := range report.Lanes {
		measured += lane.Measured
		if lane.CostedTurns == 0 && lane.Tokens.Recorded() && !lane.Priced {
			unpriced++
		}
	}
	switch {
	case len(report.Lanes) > 0 && measured == 0:
		notes = append(notes,
			"No attempt in the window was measured by its provider, so every token and cost "+
				"column is blank rather than zero. The ACP adapter reports no usage at all.")
	case !report.Priced && unpriced > 0:
		notes = append(notes,
			"No price list is configured, so measured turns show tokens and no estimate. "+
				"Set pricing.models to price the models this deployment actually ran.")
	case unpriced > 0:
		notes = append(notes,
			"Some measured lanes ran on a model the price list does not name, so they report "+
				"no estimate rather than a zero.")
	}
	if len(report.Lanes) > 0 && len(report.Corpora) > 0 {
		notes = append(notes,
			"The two halves are not joined. A recorded run records no provider or model, and "+
				"live traffic has no gate to pass, so no row can honestly carry both.")
	}
	// Stated on every report, because it is the one comparison an audition is
	// really for and the one it cannot make. Every lane below is a model that
	// ANSWERED; none of them is a model that was asked the same question beside
	// the incumbent and had its answer thrown away. Without that there is no way
	// to tell a model that draws fewer corrections from a model that was handed
	// the easier lane — the watch rung is the clearest case, since nothing has
	// ever run shadow there. Saying so beats a table that quietly reads as a
	// controlled comparison.
	notes = append(notes,
		"No shadow rows exist for any rung, including the watch rung: nothing records a "+
			"candidate model answering a question the incumbent also answered. Every rate here "+
			"is observational, so a lane's advantage may be its traffic rather than its model.")
	return notes
}
