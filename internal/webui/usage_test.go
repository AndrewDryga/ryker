package webui

import (
	"context"
	"database/sql"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/config"
	"github.com/AndrewDryga/ryker/internal/core"
	"github.com/AndrewDryga/ryker/internal/store"
)

// attempt is one frozen piece of work to render a Usage page from.
type attempt struct {
	id                        string
	channel, repository, mode string
	provider, model, effort   string
	frozen                    time.Time
	spent                     Tokens
	costUSD                   float64
	costedTurns               int
}

// seedUsage writes attempts into a database the store itself migrated.
//
// Against the real schema rather than a fixture, for the reason the rest of
// this package already learned the hard way: a query against a column that has
// never existed fails only when SQLite is the thing parsing it, and every test
// here once pointed at no database at all.
func seedUsage(t *testing.T, attempts ...attempt) *Reader {
	t.Helper()
	dir := t.TempDir()
	live, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := live.Close(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "responder.db")
	writable, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	exec := func(query string, args ...any) {
		t.Helper()
		if _, err := writable.ExecContext(context.Background(), query, args...); err != nil {
			t.Fatalf("%v\n%s", err, query)
		}
	}
	exec(`INSERT INTO slack_channel_memberships (channel_id, channel_name, observed_at)
	      VALUES ('C1','backend-ops','now')`)
	for _, item := range attempts {
		stamp := item.frozen.Format(core.TimestampFormat)
		run, episode := "run_"+item.id, "ep_"+item.id
		exec(`INSERT INTO agent_runs
		  (id, mode, conversation_key, source_kind, source_id, idempotency_key, state,
		   next_attempt_at, created_at, updated_at, channel_id, repository, episode_id, attempt_id)
		  VALUES (?,?,?,?,?,?,'completed',?,?,?,?,?,?,?)`,
			run, item.mode, "conv_"+item.id, "slack", "src_"+item.id, "idem_"+item.id,
			stamp, stamp, stamp, item.channel, item.repository, episode, item.id)
		exec(`INSERT INTO work_episodes
		  (id, agent_run_id, effort, authority, lifecycle_state, objective, created_at, updated_at)
		  VALUES (?,?,'focused_check','read_only','completed',?,?,?)`,
			episode, run, "work "+item.id, stamp, stamp)
		exec(`INSERT INTO episode_attempts
		  (id, episode_id, agent_run_id, attempt_number, state, context_manifest_id,
		   created_at, updated_at)
		  VALUES (?,?,?,1,'succeeded',?,?,?)`,
			item.id, episode, run, "man_"+item.id, stamp, stamp)
		exec(`INSERT INTO context_manifests
		  (id, episode_id, attempt_id, version, provider, model, reasoning_effort, created_at,
		   usage_input_tokens, usage_cached_input_tokens, usage_output_tokens,
		   usage_reasoning_tokens, usage_cost_usd, usage_costed_turns, usage_last_turn_id)
		  VALUES (?,?,?,1,?,?,?,?,?,?,?,?,?,?,?)`,
			"man_"+item.id, episode, item.id, item.provider, item.model, item.effort, stamp,
			item.spent.Input, item.spent.Cached, item.spent.Output, item.spent.Reasoning,
			item.costUSD, item.costedTurns, "turn_"+item.id)
	}
	if err := writable.Close(); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReader(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reader.Close() })
	return reader
}

func servePage(t *testing.T, reader *Reader, target string) string {
	t.Helper()
	handler, err := NewHandler(reader, "test", "48", "ryker-abc", nil, config.Pricing{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	handler.Register(mux)
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, target, nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("GET %s = %d: %s", target, recorder.Code, recorder.Body.String())
	}
	body := recorder.Body.String()
	if strings.Contains(body, "Could not load") {
		t.Errorf("GET %s reported a failed query: %s", target, body)
	}
	return body
}

// twoAttempts is one measured and one not.
//
// Every count on the measured one is deliberately non-zero, so a rendered "0"
// anywhere on the page can only have come from the unmeasured one — which is
// the substitution these tests exist to catch.
func twoAttempts(now time.Time) []attempt {
	return []attempt{
		{id: "a1", channel: "C1", repository: "blitz-platform", mode: "triage",
			provider: "anthropic", model: "claude-opus-4-5", effort: "high",
			frozen: now.Add(-2 * time.Hour),
			spent:  Tokens{Input: 20_000, Cached: 60_000, Output: 2_000, Reasoning: 500}},
		// Frozen with a provider and no measurement. This is the pairing the page
		// exists to keep apart: the attempt ran, something answered it, and no
		// adapter reported what it cost.
		{id: "a2", channel: "C1", repository: "blitz-infra", mode: "engineering_task",
			provider: "openai", model: "gpt-5.4-codex", effort: "medium",
			frozen: now.Add(-3 * time.Hour)},
	}
}

// An attempt nobody measured must not be reported as an attempt that cost
// nothing.
//
// This dashboard has shipped four separate "could not run, displayed as nothing
// found" defects in one day, two of them in this package. A usage table is the
// easiest place to ship a fifth, because a summed zero looks exactly like a
// summed measurement of nothing.
func TestUsageSeparatesWhatWasMeasuredFromWhatWasNot(t *testing.T) {
	now := time.Now().UTC()
	reader := seedUsage(t, twoAttempts(now)...)
	body := servePage(t, reader, "/usage?window=7d")

	if !strings.Contains(body, "1 reported token usage (50% measured)") {
		t.Errorf("the page does not say how much of the window it has a measurement for:\n%s", body)
	}
	if !strings.Contains(body, "claude-opus-4-5") || !strings.Contains(body, "82k") {
		t.Errorf("the measured attempt's tokens are not on the page:\n%s", body)
	}
	if !strings.Contains(body, "not measured") {
		t.Error("the unmeasured attempt is not marked as unmeasured")
	}
	// The unmeasured row carries no figures at all rather than a row of zeros.
	if strings.Contains(body, ">0<") || strings.Contains(body, ">0%<") {
		t.Errorf("a zero was rendered where there is no measurement:\n%s", body)
	}
	// Cache hit rate is cached input over all input read, and the page says so
	// rather than leaving the reader to guess the denominator.
	if !strings.Contains(body, ">75%<") {
		t.Errorf("the cache hit rate is missing or wrong:\n%s", body)
	}
	// The episode's own panel tells the same story from the other end.
	episode := servePage(t, reader, "/episodes/ep_a1")
	if !strings.Contains(episode, "82k") {
		t.Errorf("the episode does not show its own tokens:\n%s", episode)
	}
	unmeasured := servePage(t, reader, "/episodes/ep_a2")
	if !strings.Contains(unmeasured, "The provider reported no token usage.") {
		t.Errorf("an unmeasured episode does not say so:\n%s", unmeasured)
	}
}

// Every list is a way in. A usage table that cannot be opened says which model
// costs the most and gives no route to a single turn of it, which is the dead
// end the grouped failure page had before a cause could be expanded.
func TestAUsageRowOpensTheEpisodesBehindIt(t *testing.T) {
	now := time.Now().UTC()
	reader := seedUsage(t, twoAttempts(now)...)
	window := chosenWindow(UsageWindows("7d", now))
	rows, err := reader.UsageByModel(context.Background(), window)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) == 0 {
		t.Fatal("no rows to open")
	}
	for _, row := range rows {
		if row.Href == "" {
			t.Fatalf("row %q offers no way into the episodes behind it", row.Label)
		}
	}
	// The link is followed, not just inspected: a href that renders and 404s or
	// matches nothing is the same dead end with an underline on it.
	body := servePage(t, reader, string(rows[0].Href))
	if !strings.Contains(body, "ep_a1") {
		t.Errorf("the filtered list does not hold the episode the row counted:\n%s", body)
	}
	if !strings.Contains(body, "1 match") {
		t.Errorf("the filtered list does not report its own size:\n%s", body)
	}
	// A filter nothing matches says nothing matched, and says the count came from
	// the same query, so it cannot be read as a page that failed to load.
	empty := servePage(t, reader, "/episodes?model=never-ran")
	if !strings.Contains(empty, "No episode matches this filter") {
		t.Errorf("an empty filter result does not explain itself:\n%s", empty)
	}
}

// A real quantity must not round away to zero.
//
// An engineering task that spent 61,000 tokens beside a triage lane that spent
// seven million is 0.8% of the window, and integer division printed "0%" —
// a zero standing where there is a measurement.
func TestATinyShareIsNotRoundedAwayToZero(t *testing.T) {
	for _, testCase := range []struct {
		part, whole int64
		want        string
	}{
		{61_000, 7_500_000, "<1%"},
		{0, 7_500_000, "0%"},
		{1, 0, "—"},
		{7_500_000, 7_500_000, "100%"},
		{3_750_000, 7_500_000, "50%"},
	} {
		if got := pctLabel(testCase.part, testCase.whole); got != testCase.want {
			t.Errorf("pctLabel(%d, %d) = %q, want %q",
				testCase.part, testCase.whole, got, testCase.want)
		}
	}
}

// A day that ran attempts nobody measured is not a day that spent nothing, and
// a bar chart draws both as an absent bar unless it is told not to.
func TestTheTrendMarksAnUnmeasuredDayDifferentlyFromAQuietOne(t *testing.T) {
	now := time.Date(2026, 8, 8, 12, 0, 0, 0, time.UTC)
	day := func(offset int) time.Time { return now.AddDate(0, 0, offset).Truncate(24 * time.Hour) }
	trend := layOutTrend([]UsageDay{
		{Date: day(-3), Attempts: 40, Measured: 0},
		{Date: day(-1), Attempts: 10, Measured: 10, Total: 900_000},
	}, now)

	if len(trend.Days) != 2 {
		t.Fatalf("drew %d marks over a four-day span with two days of work, want 2", len(trend.Days))
	}
	unmeasured, measured := trend.Days[0], trend.Days[1]
	if !unmeasured.Missing || unmeasured.H == 0 {
		t.Errorf("an unmeasured day drew nothing, which reads as a quiet one: %+v", unmeasured)
	}
	if !strings.Contains(unmeasured.Title, "none measured") {
		t.Errorf("the unmeasured mark does not say what it is: %q", unmeasured.Title)
	}
	if measured.Missing || measured.H <= unmeasured.H {
		t.Errorf("the measured day did not draw a real bar: %+v", measured)
	}
	// The exact count survives into the hover text; the axis label is rounded and
	// is not the only place the number appears.
	if !strings.Contains(measured.Title, "900,000 tokens") {
		t.Errorf("the bar does not carry its exact count: %q", measured.Title)
	}
	if trend.Max != 900_000 || trend.MaxLabel != "900k" {
		t.Errorf("the peak is wrong: %d / %q", trend.Max, trend.MaxLabel)
	}
	// Bars stay inside the box the viewBox declares, or the tallest one is drawn
	// off the top of a chart that still looks plausible.
	for _, drawn := range trend.Days {
		if drawn.Y < trendTop || drawn.Y+drawn.H > trendBaseline || drawn.X+drawn.W > trendWidth {
			t.Errorf("a mark fell outside the chart: %+v", drawn)
		}
	}
}

// The window threshold has to sort as text the way it sorts in time.
//
// Stored timestamps are TEXT and SQLite compares them as text. RFC3339Nano
// strips trailing zeros, so its terminating Z sorts after every digit: a
// threshold written that way is greater than every timestamp in the same second
// that carries a fraction, and every one of those rows drops out of the window.
func TestTheWindowThresholdDoesNotDropRowsWithAFraction(t *testing.T) {
	// A whole second, so the day-old boundary carries no fraction of its own.
	// That is exactly the case the wrong format gets wrong, and a wall clock
	// almost never lands on it — which is how a threshold like this ships.
	now := time.Date(2026, 8, 9, 12, 0, 0, 0, time.UTC)
	inside := now.AddDate(0, 0, -1).Add(123456 * time.Microsecond)
	reader := seedUsage(t,
		attempt{id: "recent", channel: "C1", repository: "r", mode: "triage",
			provider: "anthropic", model: "claude-opus-4-5", frozen: inside,
			spent: Tokens{Input: 1_000, Output: 100}},
		attempt{id: "old", channel: "C1", repository: "r", mode: "triage",
			provider: "anthropic", model: "claude-opus-4-5", frozen: now.AddDate(0, 0, -40),
			spent: Tokens{Input: 5_000, Output: 500}})

	window := chosenWindow(UsageWindows("1d", now))
	totals, err := reader.UsageTotals(context.Background(), window)
	if err != nil {
		t.Fatal(err)
	}
	if totals.Attempts != 1 || totals.Input != 1_000 {
		t.Errorf("the day window did not hold exactly the attempt inside it: %+v", totals)
	}
	// And the hazard is still live, so the assertion above is worth something:
	// written RFC3339Nano the threshold sorts after a row it is earlier than,
	// and that row falls out of its own window.
	stored := inside.Format(core.TimestampFormat)
	if stored >= window.Since.Format(time.RFC3339Nano) {
		t.Errorf("this no longer covers the text-ordering hazard it was written for: %q vs %q",
			stored, window.Since.Format(time.RFC3339Nano))
	}

	everything := chosenWindow(UsageWindows("all", now))
	all, err := reader.UsageTotals(context.Background(), everything)
	if err != nil {
		t.Fatal(err)
	}
	if all.Attempts != 2 {
		t.Errorf("the all-time window held %d attempts, want both", all.Attempts)
	}
}

// Cost is priced only through config.Pricing.Cost, and the two kinds of
// absence stay distinguishable from money: a model the table does not cover
// says "not priced", an unmeasured row is not priced at all, and a real spend
// that rounds to 0.00 prints "<0.01" rather than a zero — a zero in a spend
// report reads as "this was free", which is a claim about the world.
func TestPricingNeverInventsOrHidesMoney(t *testing.T) {
	pricing := config.Pricing{Currency: "USD", Models: map[string]config.ModelPrice{
		"claude:opus-4.5": {Input: 5, CachedInput: 0.5, Output: 25},
		"openai":          {Input: 2, Output: 8},
	}}
	rows := []UsageGroup{
		{Provider: "claude", Model: "opus-4.5", Measured: 3,
			Tokens: Tokens{Input: 1_000_000, Cached: 1_000_000, Output: 100_000, Reasoning: 100_000}},
		// No exact model key: falls back to the bare provider rate, matching
		// the target grammar the manifest froze.
		{Provider: "openai", Model: "gpt-6", Measured: 1, Tokens: Tokens{Input: 500_000}},
		{Provider: "mystery", Model: "m", Measured: 1, Tokens: Tokens{Input: 1_000_000}},
		{Provider: "claude", Model: "opus-4.5", Measured: 0},
	}
	rows, cost := priceUsage(pricing, rows)
	if !cost.Configured || cost.MeasuredRows != 3 || cost.EstimatedRows != 2 {
		t.Fatalf("cost accounting = %+v, want 2 of 3 measured rows priced", cost)
	}
	// 5.00 input + 0.50 cached + 2.50 output + 2.50 reasoning-at-output-rate,
	// plus 1.00 for the provider-rate row.
	if cost.EstimatedMoney() != "11.50 USD" {
		t.Errorf("total = %q, want 11.50 USD", cost.EstimatedMoney())
	}
	if rows[0].Cost != "10.50 USD estimated" || rows[1].Cost != "1.00 USD estimated" {
		t.Errorf("row costs = %q, %q", rows[0].Cost, rows[1].Cost)
	}
	if rows[2].Cost != "not priced" {
		t.Errorf("an uncovered model shows %q, want \"not priced\"", rows[2].Cost)
	}
	if rows[3].Cost != "" {
		t.Errorf("an unmeasured row was priced: %q", rows[3].Cost)
	}
	if money(0.001, "USD") != "<0.01 USD" {
		t.Errorf("a sub-cent spend rendered as %q", money(0.001, "USD"))
	}

	// With no table at all, nothing gets a per-row tag: the section-level
	// panel explains the missing table once instead of forty rows repeating it.
	bare := []UsageGroup{{Provider: "claude", Model: "opus-4.5", Measured: 1,
		Tokens: Tokens{Input: 10}}}
	bare, cost = priceUsage(config.Pricing{}, bare)
	if cost.Configured || cost.EstimatedKnown() || bare[0].Cost != "" {
		t.Errorf("an empty table produced output: %+v, row %q", cost, bare[0].Cost)
	}
}

func TestProviderReportedCostNeedsNoConfiguredPriceTable(t *testing.T) {
	now := time.Now().UTC()
	reader := seedUsage(t, attempt{
		id: "reported", channel: "C1", repository: "r", mode: "triage",
		provider: "claude", model: "opus-4.5", frozen: now.Add(-time.Hour),
		spent: Tokens{Input: 1_000, Output: 100}, costUSD: 0.375, costedTurns: 1,
	})
	body := servePage(t, reader, "/usage?window=1d")
	for _, want := range []string{"0.38 USD reported", "provider reported", "reported USD cost for 1 turn"} {
		if !strings.Contains(body, want) {
			t.Errorf("usage page is missing %q:\n%s", want, body)
		}
	}
	if strings.Contains(body, "No provider-reported cost or price table") {
		t.Errorf("reported money was replaced by setup guidance:\n%s", body)
	}
	episode := servePage(t, reader, "/episodes/ep_reported")
	if !strings.Contains(episode, "0.38 USD") || !strings.Contains(episode, "provider reported 1 turn") {
		t.Errorf("episode did not use reported money:\n%s", episode)
	}
}

func TestReportedAndEstimatedCostStaySeparate(t *testing.T) {
	pricing := config.Pricing{Currency: "USD", Models: map[string]config.ModelPrice{
		"openai": {Input: 2},
	}}
	rows, cost := priceUsage(pricing, []UsageGroup{
		{Provider: "claude", Model: "opus", CostUSD: 0.375, CostedTurns: 1},
		{Provider: "openai", Model: "gpt", Measured: 1, Tokens: Tokens{Input: 500_000}},
	})
	if cost.ReportedMoney() != "0.38 USD" || cost.EstimatedMoney() != "1.00 USD" ||
		cost.ReportedTurns != 1 || cost.EstimatedRows != 1 {
		t.Fatalf("mixed cost provenance = %+v", cost)
	}
	if rows[0].Cost != "0.38 USD reported" || rows[1].Cost != "1.00 USD estimated" {
		t.Fatalf("mixed row labels = %q / %q", rows[0].Cost, rows[1].Cost)
	}
}

// A row that reported money for a few of its attempts still prices the rest.
//
// On the blitz database (2026-08-16) codex:gpt-5.6-terra had 172 attempts of
// which 4 carried a provider price. The model table read "9.48 USD reported"
// and stopped there, so the 26.8M tokens the other 168 attempts spent were
// rendered as costing nothing — and the same row shape hid 130M tokens under
// "6.26 USD reported" for gpt-5.6-sol. A blind spot printed as a bill reads as
// a saving, which is the one claim this page must never make.
func TestAPartlyBilledRowPricesTheAttemptsNobodyBilled(t *testing.T) {
	now := time.Now().UTC()
	reader := seedUsage(t,
		attempt{id: "billed", channel: "C1", repository: "r", mode: "triage",
			provider: "codex", model: "gpt-5.6-terra", frozen: now.Add(-time.Hour),
			spent:   Tokens{Input: 1_000_000, Cached: 5_000_000, Output: 100_000, Reasoning: 10_000},
			costUSD: 9.48, costedTurns: 1},
		attempt{id: "unbilled", channel: "C1", repository: "r", mode: "triage",
			provider: "codex", model: "gpt-5.6-terra", frozen: now.Add(-time.Hour),
			spent: Tokens{Input: 4_000_000, Cached: 20_000_000, Output: 200_000, Reasoning: 30_000}},
	)
	groups, err := reader.UsageByModel(context.Background(), UsageWindow{Key: "1d"})
	if err != nil {
		t.Fatal(err)
	}
	if len(groups) != 1 {
		t.Fatalf("grouping = %+v, want the two attempts on one model row", groups)
	}
	// The split the query has to make: the unbilled attempt's tokens alone, not
	// the row's total, are what a configured rate may be applied to.
	if got, want := groups[0].UnbilledTokens(),
		(Tokens{Input: 4_000_000, Cached: 20_000_000, Output: 200_000, Reasoning: 30_000}); got != want {
		t.Fatalf("unbilled tokens = %+v, want %+v", got, want)
	}
	if groups[0].PricedAttempts != 1 {
		t.Errorf("priced attempts = %d, want 1 of 2", groups[0].PricedAttempts)
	}

	pricing := config.Pricing{Currency: "USD", Models: map[string]config.ModelPrice{
		"codex:gpt-5.6-terra": {Input: 2, CachedInput: 0.2, Output: 12, Reasoning: 12},
	}}
	rows, cost := priceUsage(pricing, groups)
	// 8.00 input + 4.00 cached + 2.40 output + 0.36 reasoning, over the unbilled
	// attempt only. The billed attempt's own tokens are never estimated on top of
	// the money its provider already reported.
	if rows[0].Cost != "9.48 USD reported + 14.76 USD estimated" {
		t.Errorf("row cost = %q, want both halves", rows[0].Cost)
	}
	if cost.ReportedMoney() != "9.48 USD" || cost.EstimatedMoney() != "14.76 USD" {
		t.Errorf("reported %q and estimated %q were not kept apart",
			cost.ReportedMoney(), cost.EstimatedMoney())
	}
	if cost.ReportedTurns != 1 || cost.EstimatedRows != 1 || cost.PricedAttempts != 1 {
		t.Errorf("cost accounting = %+v", cost)
	}

	// Without a rate for the model, the row still says the reported money does
	// not cover it, rather than letting 9.48 stand for the whole row.
	bare, _ := priceUsage(config.Pricing{Currency: "USD",
		Models: map[string]config.ModelPrice{"other": {Input: 1}}}, groups)
	if bare[0].Cost != "9.48 USD reported + rest not priced" {
		t.Errorf("unpriced remainder = %q", bare[0].Cost)
	}
}

// Zero milliseconds is ambiguous between "instant" and "unmeasured", so the
// timed-turn count is the recorded flag and every derived figure refuses to
// divide by nothing.
func TestWallClockRefusesToAverageNothing(t *testing.T) {
	var idle WallClock
	if idle.Recorded() || idle.Cell() != "" || idle.PerTurn() != "—" {
		t.Errorf("an untimed clock invented output: cell=%q per-turn=%q", idle.Cell(), idle.PerTurn())
	}
	timed := WallClock{TimedTurns: 4, QueuedMS: 2_000, ProviderMS: 236_000, HostMS: 2_000}
	if timed.PerTurn() != "1m00s" {
		t.Errorf("per-turn = %q, want 1m00s", timed.PerTurn())
	}
	if timed.Split() != "queued 2.0s · provider 3m56s · host 2.0s" {
		t.Errorf("split = %q", timed.Split())
	}
	if !strings.Contains(timed.Cell(), "98% provider") {
		t.Errorf("cell does not attribute the time: %q", timed.Cell())
	}
	for _, format := range []struct {
		milliseconds int64
		want         string
	}{{450, "450ms"}, {12_300, "12.3s"}, {83_000, "1m23s"}, {7_260_000, "2h01m"}} {
		if got := humanMS(format.milliseconds); got != format.want {
			t.Errorf("humanMS(%d) = %q, want %q", format.milliseconds, got, format.want)
		}
	}
}
