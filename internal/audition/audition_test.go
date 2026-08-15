package audition_test

import (
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/audition"
	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
)

func pricedAt(input, output float64) config.Pricing {
	return config.Pricing{
		Currency: "USD",
		Models: map[string]config.ModelPrice{
			"anthropic:claude": {Input: input, Output: output},
		},
	}
}

// The rule the Usage page already holds and the one an audition is most likely
// to break, because an audition is a comparison and a comparison wants one
// number per row. A lane the provider charged for is costed by the provider and
// is not ALSO estimated: two figures for one turn is an invitation for somebody
// downstream to add them, and the sum matches no invoice anybody will ever
// receive.
func TestAProviderCostedLaneIsNeverAlsoEstimated(t *testing.T) {
	report := audition.Build(time.Now().Add(-24*time.Hour), []audition.Lane{{
		Class: "triage", Provider: "anthropic", Model: "claude",
		Attempts: 4, Measured: 4, CostedTurns: 4, ReportedUSD: 1.25,
		Tokens: core.ContextUsage{InputTokens: 1_000_000, OutputTokens: 1_000_000, CostedTurns: 4},
	}}, nil, pricedAt(3, 15))

	lane := report.Lanes[0]
	if lane.EstimatedUSD != 0 {
		t.Fatalf("a provider-costed lane was also estimated at %v; the two would be summed "+
			"by the first reader who wanted one number", lane.EstimatedUSD)
	}
	if lane.ReportedUSD != 1.25 {
		t.Fatalf("reported cost = %v, want the provider's own figure kept", lane.ReportedUSD)
	}
	reported, turns := report.ReportedTotal()
	estimated, lanes := report.EstimatedTotal()
	if reported != 1.25 || turns != 4 {
		t.Fatalf("reported total = %v over %d turns, want 1.25 over 4", reported, turns)
	}
	if estimated != 0 || lanes != 0 {
		t.Fatalf("estimated total = %v over %d lanes, want nothing estimated at all",
			estimated, lanes)
	}
}

// The other half of the same rule: a lane nobody charged for, whose tokens were
// counted and whose model is priced, gets an estimate — and the estimate stays
// in its own field so no caller can reach a combined figure without writing the
// addition itself.
func TestAnUncostedButMeasuredLaneIsEstimatedIntoItsOwnField(t *testing.T) {
	report := audition.Build(time.Now().Add(-24*time.Hour), []audition.Lane{{
		Class: "triage", Provider: "anthropic", Model: "claude",
		Attempts: 2, Measured: 2,
		Tokens: core.ContextUsage{InputTokens: 1_000_000, OutputTokens: 1_000_000},
	}}, nil, pricedAt(3, 15))

	lane := report.Lanes[0]
	if !lane.Priced {
		t.Fatal("a measured lane on a priced model reported no estimate at all")
	}
	if lane.EstimatedUSD != 18 {
		t.Fatalf("estimate = %v, want 18 (1M input at 3 + 1M output at 15)", lane.EstimatedUSD)
	}
	if lane.ReportedUSD != 0 || lane.CostedTurns != 0 {
		t.Fatalf("an estimate was written into the provider-reported fields: %v over %d turns",
			lane.ReportedUSD, lane.CostedTurns)
	}
}

// "Zero tokens" and "nobody measured this" are different facts. The ACP adapter
// reports no usage at all, so a lane running on it has real attempts and no
// measurement, and a report that let those average into the priced lanes would
// present a model as free.
func TestAnUnmeasuredLaneIsNotPricedAtZero(t *testing.T) {
	report := audition.Build(time.Now().Add(-24*time.Hour), []audition.Lane{{
		Class: "triage", Provider: "anthropic", Model: "claude", Attempts: 6,
	}}, nil, pricedAt(3, 15))

	lane := report.Lanes[0]
	if lane.Priced || lane.EstimatedUSD != 0 {
		t.Fatalf("an unmeasured lane was priced at %v; zero tokens is not zero cost",
			lane.EstimatedUSD)
	}
	if lane.Unmeasured() != 6 {
		t.Fatalf("unmeasured attempts = %d, want all 6 counted as unmeasured", lane.Unmeasured())
	}
	if !hasGap(report, "no attempt in the window was measured") {
		t.Fatalf("the report did not say why every cost column is blank: %q", report.Gaps)
	}
}

// A measured lane on a model the price list does not name reports no estimate,
// and says so. Rendering it as 0.00 is the failure this guards: it reads
// exactly like a model that costs nothing.
func TestAnUnpricedModelReportsNoEstimateRatherThanZero(t *testing.T) {
	report := audition.Build(time.Now().Add(-24*time.Hour), []audition.Lane{{
		Class: "triage", Provider: "openai", Model: "gpt", Attempts: 3, Measured: 3,
		Tokens: core.ContextUsage{InputTokens: 500, OutputTokens: 100},
	}}, nil, pricedAt(3, 15))

	if report.Lanes[0].Priced {
		t.Fatal("a model absent from the price list was reported as priced")
	}
	if !hasGap(report, "price list does not name") {
		t.Fatalf("the report did not say the model was unpriced: %q", report.Gaps)
	}
}

// The promotion metric, and the shape of it. A corpus row carries a gate-pass
// rate and a judge mean over a stated denominator, and carries no model —
// because the results file records none, and inventing one from whoever's
// configuration happens to be loaded would be a guess presented as evidence.
func TestACorpusReportsItsGateAndJudgeOverStatedDenominators(t *testing.T) {
	report := audition.Build(time.Now().Add(-24*time.Hour), nil, []audition.Corpus{{
		Name: "regressions", Total: 9, Passed: 6, JudgeEvaluated: 4, JudgeMean: 4.25, Cases: 3,
	}}, config.Pricing{})

	corpus := report.Corpora[0]
	if rate := corpus.GatePassRate(); rate < 0.666 || rate > 0.667 {
		t.Fatalf("gate-pass rate = %v, want 6 of 9", rate)
	}
	if corpus.JudgeEvaluated != 4 || corpus.JudgeMean != 4.25 {
		t.Fatalf("judge mean %v over %d scored answers, want the denominator kept beside it",
			corpus.JudgeMean, corpus.JudgeEvaluated)
	}
}

// The report refuses to pretend it can attribute a corpus result to a model.
// EvaluationSummary records neither provider nor model, so the two halves stay
// two halves and the reader is told why rather than being handed a grid whose
// model column was filled in by inference.
func TestTheTwoHalvesAreReportedApartAndSayWhy(t *testing.T) {
	report := audition.Build(time.Now().Add(-24*time.Hour), []audition.Lane{{
		Class: "triage", Provider: "anthropic", Model: "claude", Attempts: 1,
	}}, []audition.Corpus{{Name: "regressions", Total: 3, Passed: 3}}, config.Pricing{})

	if !hasGap(report, "not joined") {
		t.Fatalf("the report joined the halves silently or did not explain the gap: %q",
			report.Gaps)
	}
}

// The comparison an audition is really for, and the one it cannot make. Every
// lane is a model that answered; none was asked a question the incumbent also
// answered with its reply discarded. Until shadow rows exist, a lane's low
// correction rate may be its traffic rather than its model, and the report has
// to say so or the table reads as a controlled trial.
func TestEveryAuditionAdmitsItHasNoShadowRows(t *testing.T) {
	full := audition.Build(time.Now().Add(-24*time.Hour), []audition.Lane{{
		Class: "watch", Provider: "anthropic", Model: "claude", Attempts: 40,
	}}, []audition.Corpus{{Name: "regressions", Total: 3, Passed: 3}}, config.Pricing{})
	empty := audition.Build(time.Now().Add(-24*time.Hour), nil, nil, config.Pricing{})

	for name, report := range map[string]audition.Report{"populated": full, "empty": empty} {
		if !hasGap(report, "no shadow rows exist") {
			t.Fatalf("the %s report presents observational rates as a comparison: %q",
				name, report.Gaps)
		}
	}
}

// An empty report is the common case on a fresh deployment and the one most
// likely to be misread as breakage. Each empty names the thing that would fill
// it, so nobody debugs a working machine.
func TestAnEmptyAuditionNamesWhatWouldFillIt(t *testing.T) {
	report := audition.Build(time.Now().Add(-24*time.Hour), nil, nil, config.Pricing{})
	if len(report.Gaps) < 2 {
		t.Fatalf("an entirely empty report offered %d explanations: %q", len(report.Gaps), report.Gaps)
	}
	if !hasGap(report, "no attempts in the window") || !hasGap(report, "no recorded evaluation runs") {
		t.Fatalf("the empty report does not name both missing sources: %q", report.Gaps)
	}
}

// Corrections per attempt, uncapped. An episode the host corrected six times
// cost six corrections, and flattening that to "one corrected attempt" hides
// exactly the lane worth moving off a model — the worst recorded case was 6.6
// corrections on a single episode.
func TestTheCorrectionRateCountsRepeatsRatherThanAttempts(t *testing.T) {
	lane := audition.Lane{Attempts: 2, Corrections: 6, CorrectedAttempts: 1}
	if rate := lane.CorrectionRate(); rate != 3 {
		t.Fatalf("correction rate = %v, want 6 corrections over 2 attempts", rate)
	}
	if lane.CorrectedAttempts != 1 {
		t.Fatal("the count of attempts that drew a correction was lost, so a lane corrected " +
			"once six times reads the same as one corrected six times once")
	}
}

func hasGap(report audition.Report, want string) bool {
	for _, gap := range report.Gaps {
		if strings.Contains(strings.ToLower(gap), strings.ToLower(want)) {
			return true
		}
	}
	return false
}
