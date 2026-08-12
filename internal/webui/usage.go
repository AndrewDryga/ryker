package webui

import (
	"context"
	"database/sql"
	"fmt"
	"html/template"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
)

// Tokens is what one attempt, or a group of them, spent.
//
// Cached input is held apart from fresh input rather than folded into it,
// because that is the contract the number arrives under: core.ContextUsage and
// coop.Usage both say cached input is kept separate precisely so a cost can be
// derived, since every provider prices a cache read differently. The four
// counts are therefore added, not overlapped — folding cached into input would
// undercount every cached turn, and Coop's own turn display already sums
// reasoning onto output the same way (streamjson_providers.go, turn.completed).
//
// The four parts stay on the page beside the total so a reader who prices them
// differently can recompute rather than trust this arithmetic.
type Tokens struct {
	Input, Cached, Output, Reasoning int64
}

func (t Tokens) InputRead() int64 { return t.Input + t.Cached }
func (t Tokens) Total() int64     { return t.Input + t.Cached + t.Output + t.Reasoning }

// CacheLabel is the share of everything the model read that came from cache.
//
// Over input read rather than over the grand total: output tokens were never
// cacheable, so including them would report a cache that got worse every time
// the model wrote more.
func (t Tokens) CacheLabel() string { return pctLabel(t.Cached, t.InputRead()) }

// UsageWindow is the span the Usage page totals over.
//
// A window rather than everything on record, because "what is it spending" is a
// question about now: a rate that has doubled this week is invisible inside a
// total dominated by the month behind it.
type UsageWindow struct {
	Key   string
	Label string
	Days  int
	Since time.Time
	On    bool
}

// since is the text threshold SQL compares against.
//
// Formatted with core.TimestampFormat and not RFC3339Nano. Stored timestamps
// are TEXT and SQLite compares them as text, and RFC3339Nano strips trailing
// zeros so its terminating Z sorts after every digit: a threshold written that
// way excludes every row inside the window that happens to carry a fraction.
// An empty string is every row, which is what the all-time window wants.
func (w UsageWindow) since() string {
	if w.Days == 0 {
		return ""
	}
	return w.Since.Format(core.TimestampFormat)
}

var usageSpans = []struct {
	key, label string
	days       int
}{
	{"1d", "last 24 hours", 1},
	{"7d", "last 7 days", 7},
	{"30d", "last 30 days", 30},
	{"all", "everything on record", 0},
}

// UsageWindows offers the spans, marking the one in force. Default is 30 days:
// long enough that a quiet week still has rows in it, short enough that the
// number describes the current configuration rather than two model changes ago.
func UsageWindows(chosen string, now time.Time) []UsageWindow {
	windows := make([]UsageWindow, 0, len(usageSpans))
	matched := false
	for _, span := range usageSpans {
		if span.key == chosen {
			matched = true
		}
	}
	for _, span := range usageSpans {
		window := UsageWindow{Key: span.key, Label: span.label, Days: span.days}
		if span.days > 0 {
			window.Since = now.Add(-time.Duration(span.days) * 24 * time.Hour)
		}
		window.On = span.key == chosen || (!matched && span.key == "30d")
		windows = append(windows, window)
	}
	return windows
}

func chosenWindow(windows []UsageWindow) UsageWindow {
	for _, window := range windows {
		if window.On {
			return window
		}
	}
	return UsageWindow{Key: "all", Label: "everything on record"}
}

// usageColumns is the same figures everywhere: how many attempts are in
// the group, how many of them a provider actually measured, the four token
// counts, and the three wall-clock spans with the count of timed turns.
//
// Measured is counted rather than inferred from a zero total. Zero is a real
// answer for a trivial turn and ACP does not require an adapter to report usage
// at all, so an attempt nobody measured has to stay distinguishable from a free
// one — the same rule core.ContextUsage.Recorded encodes, applied to a SUM.
// usage_timed_turns plays the same role for the clock columns: zero
// milliseconds is ambiguous between "instant" and "unmeasured", and the turn
// count is both the recorded flag and the divisor for a per-turn figure.
//
// Every SUM is wrapped in COALESCE because SQLite sums no rows to NULL, not to
// zero, and the driver refuses to scan that into an int. Left off the measured
// count, this failed the whole totals query on an empty window — the page's own
// "could not load" banner over a database that was simply quiet.
const usageColumns = `COUNT(*),
  COALESCE(SUM(m.usage_input_tokens > 0 OR m.usage_cached_input_tokens > 0
      OR m.usage_output_tokens > 0 OR m.usage_reasoning_tokens > 0),0),
  COALESCE(SUM(m.usage_input_tokens),0), COALESCE(SUM(m.usage_cached_input_tokens),0),
  COALESCE(SUM(m.usage_output_tokens),0), COALESCE(SUM(m.usage_reasoning_tokens),0),
  COALESCE(SUM(m.usage_costed_turns),0), COALESCE(SUM(m.usage_cost_usd),0),
  COALESCE(SUM(m.usage_timed_turns),0), COALESCE(SUM(m.usage_queued_ms),0),
  COALESCE(SUM(m.usage_provider_ms),0), COALESCE(SUM(m.usage_host_ms),0)`

// usageFrom joins each frozen attempt to the run that produced it.
//
// On attempt_id, not on episode_id. An episode can hold several runs, so the
// episode join fans out — 351 manifests became 953 rows against a production
// database — and every token count would then be added once per run that
// happened to share the episode. The attempt is what the manifest is filed
// under and what agent_runs carries back, so the match is one to one. LEFT, so
// an attempt whose run has been pruned still counts toward the coverage figures
// instead of vanishing from the denominator.
const usageFrom = `
  FROM context_manifests AS m
  LEFT JOIN agent_runs AS a ON a.attempt_id = m.attempt_id AND m.attempt_id <> ''
  WHERE m.created_at >= ?`

// WallClock is where a group's turns spent their wall time, split by who was
// holding them: Coop queueing the turn, the provider working, and the host
// not yet having noticed it finished. Three spans because they fail
// independently and are fixed differently — the host span is the one this
// repository can fix on its own.
//
// TimedTurns is both the divisor for a per-turn figure and the recorded flag:
// zero milliseconds is ambiguous between "instant" and "unmeasured", and a
// turn that failed while still queued contributes no span rather than
// dragging every average toward a duration no turn took.
type WallClock struct {
	TimedTurns                   int64
	QueuedMS, ProviderMS, HostMS int64
}

func (c WallClock) Recorded() bool { return c.TimedTurns > 0 }
func (c WallClock) TotalMS() int64 { return c.QueuedMS + c.ProviderMS + c.HostMS }

func (c WallClock) Total() string    { return humanMS(c.TotalMS()) }
func (c WallClock) Queued() string   { return humanMS(c.QueuedMS) }
func (c WallClock) Provider() string { return humanMS(c.ProviderMS) }
func (c WallClock) Host() string     { return humanMS(c.HostMS) }

// PerTurn is the average over the turns that were actually timed, never over
// the group: an unmeasured attempt averaged in as zero would report a system
// twice as fast as the one being run.
func (c WallClock) PerTurn() string {
	if c.TimedTurns == 0 {
		return "—"
	}
	return humanMS(c.TotalMS() / c.TimedTurns)
}

// Split names the three spans in order, so "the answer took four minutes" and
// "the model took four minutes" stay different claims.
func (c WallClock) Split() string {
	return "queued " + c.Queued() + " · provider " + c.Provider() + " · host " + c.Host()
}

// Cell is the one-column form for a breakdown row: the per-turn average and
// where it went, with the exact totals in the title attribute.
func (c WallClock) Cell() string {
	if !c.Recorded() {
		return ""
	}
	return c.PerTurn() + "/turn · " + pctLabel(c.ProviderMS, c.TotalMS()) + " provider"
}

// humanMS keeps durations readable without inventing precision: milliseconds
// under a second, then seconds, then minutes with seconds.
func humanMS(milliseconds int64) string {
	switch duration := time.Duration(milliseconds) * time.Millisecond; {
	case duration < time.Second:
		return strconv.FormatInt(milliseconds, 10) + "ms"
	case duration < time.Minute:
		return strconv.FormatFloat(duration.Seconds(), 'f', 1, 64) + "s"
	case duration < time.Hour:
		return fmt.Sprintf("%dm%02ds", int(duration.Minutes()), int(duration.Seconds())%60)
	default:
		return fmt.Sprintf("%dh%02dm", int(duration.Hours()), int(duration.Minutes())%60)
	}
}

// UsageTotals is the headline: what was spent in the window, and over how much
// of it we actually have a measurement.
type UsageTotals struct {
	Tokens
	Attempts, Measured int
	CostedTurns        int
	CostUSD            float64
	First, Last        time.Time
	Clock              WallClock
}

func (u UsageTotals) Recorded() bool { return u.Measured > 0 }

// CoverageLabel is how much of the window has a number behind it. A total over
// a tenth of the attempts is a tenth of the spend, and reading it as the bill
// is the mistake this figure exists to prevent.
func (u UsageTotals) CoverageLabel() string {
	return pctLabel(int64(u.Measured), int64(u.Attempts))
}

func (r *Reader) UsageTotals(ctx context.Context, window UsageWindow) (UsageTotals, error) {
	var totals UsageTotals
	if !r.live() {
		return totals, nil
	}
	var first, last sql.NullString
	err := r.db.QueryRowContext(ctx, `SELECT `+usageColumns+`,
	    MIN(m.created_at), MAX(m.created_at)`+usageFrom, window.since()).
		Scan(&totals.Attempts, &totals.Measured, &totals.Input, &totals.Cached,
			&totals.Output, &totals.Reasoning, &totals.CostedTurns, &totals.CostUSD,
			&totals.Clock.TimedTurns,
			&totals.Clock.QueuedMS, &totals.Clock.ProviderMS, &totals.Clock.HostMS,
			&first, &last)
	if err != nil {
		return UsageTotals{}, err
	}
	totals.First, totals.Last = parseStamp(first.String), parseStamp(last.String)
	return totals, nil
}

// UsageGroup is one row of a breakdown: a dimension of spend, and the way into
// the episodes behind it.
//
// Href is the whole point of the row. A usage table that cannot be opened tells
// an operator which model costs the most and gives them no route to a single
// turn of it, which is the dead end this dashboard refuses everywhere else.
type UsageGroup struct {
	Label, Sub string
	// Provider and Model are the raw target as the manifest froze it, kept
	// apart from Label/Sub because the model table rewrites those for display
	// when the manifest recorded nothing. Pricing keys on the raw pair.
	Provider, Model    string
	Attempts, Measured int
	Tokens
	CostedTurns int
	CostUSD     float64
	Clock       WallClock
	// Cost is provider-reported money when present, otherwise a configured
	// estimate. The suffix keeps those evidence classes visible.
	Cost string
	// Share of the window, filled in once the window total is known. It is the
	// reason to read a breakdown at all: the row worth acting on is the big one,
	// and a column of absolute counts makes the reader do that comparison.
	// SharePct is the same figure as an integer for the proportional meter.
	Share    string
	SharePct int
	Href     template.URL
}

func (g UsageGroup) Recorded() bool { return g.Measured > 0 }

// UsageTable is one breakdown and the question it splits by. Four of them share
// a single rendering, so a column added for one dimension appears for all four
// rather than drifting apart per section. Money marks the one table that gets
// a cost column — the model table, because cost is a property of which model
// answered — and only when provider cost or a price table exists, so the
// column is never a row of dashes pretending to be a bill.
type UsageTable struct {
	Heading, Column, Note string
	Money                 bool
	Rows                  []UsageGroup
}

func shareOf(rows []UsageGroup, whole int64) []UsageGroup {
	for index, row := range rows {
		rows[index].Share = pctLabel(row.Total(), whole)
		if whole > 0 {
			rows[index].SharePct = int(row.Total() * 100 / whole)
		}
	}
	return rows
}

const (
	usageByModel      = `COALESCE(m.provider,''), COALESCE(m.model,'')`
	usageByChannel    = `COALESCE(a.channel_id,''), ''`
	usageByRepository = `COALESCE(a.repository,''), ''`
	usageByKind       = `COALESCE(a.mode,''), ''`
)

// usageBy runs one breakdown. The grouping expression is a constant above and
// never comes from a request: this dashboard's only writes are three POSTs, and
// a dimension name interpolated from a query string would make the read path
// the injection surface instead.
func (r *Reader) usageBy(
	ctx context.Context,
	window UsageWindow,
	group string,
	link func(key, sub string) template.URL,
) ([]UsageGroup, error) {
	return collect(ctx, r, `SELECT `+group+`, `+usageColumns+usageFrom+`
	  GROUP BY 1, 2
	  ORDER BY SUM(m.usage_input_tokens + m.usage_cached_input_tokens
	                + m.usage_output_tokens + m.usage_reasoning_tokens) DESC,
	           COUNT(*) DESC
	  LIMIT 40`,
		func(rows *sql.Rows) (UsageGroup, error) {
			var item UsageGroup
			var key, sub string
			err := rows.Scan(&key, &sub, &item.Attempts, &item.Measured, &item.Input,
				&item.Cached, &item.Output, &item.Reasoning, &item.CostedTurns,
				&item.CostUSD, &item.Clock.TimedTurns,
				&item.Clock.QueuedMS, &item.Clock.ProviderMS, &item.Clock.HostMS)
			item.Label, item.Sub = key, sub
			// Either half is enough to filter on. An attempt whose provider went
			// unrecorded but whose model did not still has episodes behind it, and
			// dropping the link because the first column is blank would make the
			// row a dead end over data that is right there.
			if key != "" || sub != "" {
				item.Href = link(key, sub)
			}
			return item, err
		}, window.since())
}

// UsageByModel answers which model the spend is going to.
//
// Provider and model come off the manifest, which freezes the session's
// effective target for the attempt — so a turn that rotated to a fallback after
// a rate limit is counted against what actually answered rather than against
// what was configured.
func (r *Reader) UsageByModel(ctx context.Context, window UsageWindow) ([]UsageGroup, error) {
	groups, err := r.usageBy(ctx, window, usageByModel,
		func(provider, model string) template.URL {
			return episodeLink(url.Values{"provider": {provider}, "model": {model}})
		})
	for index, group := range groups {
		// The raw target is kept apart from the display label: pricing keys on
		// provider and model as the manifest froze them, and handing it the
		// rewritten "provider not recorded" as a provider name would be a lookup
		// that can never hit for a reason nobody could see.
		groups[index].Provider, groups[index].Model = group.Label, group.Sub
		// An attempt frozen before the effective target was recorded carries two
		// empty columns. Naming that is the point: it says these attempts are real
		// and unattributable, which a blank row would read as a rendering fault.
		switch {
		case group.Label == "" && group.Sub == "":
			groups[index].Label = "not recorded on the manifest"
			groups[index].Href = ""
		case group.Label == "":
			groups[index].Label = "provider not recorded"
		}
	}
	return groups, err
}

func (r *Reader) UsageByChannel(ctx context.Context, window UsageWindow) ([]UsageGroup, error) {
	groups, err := r.usageBy(ctx, window, usageByChannel, func(channel, _ string) template.URL {
		return episodeLink(url.Values{"channel": {channel}})
	})
	for index, group := range groups {
		groups[index].Label = r.channelName(ctx, group.Label)
		if groups[index].Label == "" {
			groups[index].Label = "no channel on the run"
		}
	}
	return groups, err
}

func (r *Reader) UsageByRepository(ctx context.Context, window UsageWindow) ([]UsageGroup, error) {
	groups, err := r.usageBy(ctx, window, usageByRepository, func(repository, _ string) template.URL {
		return episodeLink(url.Values{"repository": {repository}})
	})
	return labelBlank(groups, "no repository bound"), err
}

func (r *Reader) UsageByKind(ctx context.Context, window UsageWindow) ([]UsageGroup, error) {
	groups, err := r.usageBy(ctx, window, usageByKind, func(mode, _ string) template.URL {
		return episodeLink(url.Values{"mode": {mode}})
	})
	return labelBlank(groups, "no run on record"), err
}

func labelBlank(groups []UsageGroup, missing string) []UsageGroup {
	for index, group := range groups {
		if group.Label == "" {
			groups[index].Label = missing
		}
	}
	return groups
}

// UsageDay is one day of the trend.
//
// Attempts is carried beside the total because a day with a hundred attempts
// and no measurement is a different fact from a quiet day, and a bar chart
// alone renders both as nothing.
type UsageDay struct {
	Date               time.Time
	Attempts, Measured int
	Total              int64
	// Geometry, computed server-side. There is no JavaScript on this dashboard
	// and none may be added, so a chart is arithmetic done before rendering.
	X, Y, W, H int
	Title      string
	Missing    bool
}

// UsageTrend is the daily shape of spend, drawn as inline SVG.
type UsageTrend struct {
	Days                    []UsageDay
	Max                     int64
	MaxLabel                string
	First, Last             string
	Width, Height, Baseline int
	Measured                bool
}

const (
	trendWidth    = 720
	trendTop      = 14
	trendBaseline = 80
	trendHeight   = 96
	trendMaxBar   = 26
)

// UsageTrend buckets the window by day and lays the bars out.
//
// A day with no attempts keeps its slot and draws nothing in it. Closing the
// gap instead would turn a quiet weekend into a continuous run of work that
// never happened, which is the one thing a trend must not invent.
func (r *Reader) UsageTrend(ctx context.Context, window UsageWindow) (UsageTrend, error) {
	trend := UsageTrend{Width: trendWidth, Height: trendHeight, Baseline: trendBaseline}
	if !r.live() {
		return trend, nil
	}
	measured, err := collect(ctx, r, `
	  SELECT substr(m.created_at, 1, 10), COUNT(*),
	         SUM(m.usage_input_tokens > 0 OR m.usage_cached_input_tokens > 0
	             OR m.usage_output_tokens > 0 OR m.usage_reasoning_tokens > 0),
	         COALESCE(SUM(m.usage_input_tokens + m.usage_cached_input_tokens
	                      + m.usage_output_tokens + m.usage_reasoning_tokens),0)
	  FROM context_manifests AS m WHERE m.created_at >= ?
	  GROUP BY 1 ORDER BY 1`,
		func(rows *sql.Rows) (UsageDay, error) {
			var day UsageDay
			var stamp string
			err := rows.Scan(&stamp, &day.Attempts, &day.Measured, &day.Total)
			day.Date, _ = time.Parse(time.DateOnly, stamp)
			return day, err
		}, window.since())
	if err != nil || len(measured) == 0 {
		return trend, err
	}
	return layOutTrend(measured, time.Now().UTC()), nil
}

// trendSpan caps how many bars are drawn.
//
// Ninety days of 8-pixel bars is a texture, not a trend, and the all-time
// window will only get longer. The caption says which dates are on screen so a
// clipped chart cannot be misread as the whole history.
const trendSpan = 90

func layOutTrend(measured []UsageDay, now time.Time) UsageTrend {
	trend := UsageTrend{Width: trendWidth, Height: trendHeight, Baseline: trendBaseline}
	byDay := map[string]UsageDay{}
	for _, day := range measured {
		byDay[day.Date.Format(time.DateOnly)] = day
		if day.Total > trend.Max {
			trend.Max = day.Total
		}
		trend.Measured = trend.Measured || day.Measured > 0
	}
	last := now.Truncate(24 * time.Hour)
	first := measured[0].Date
	if span := int(last.Sub(first).Hours()/24) + 1; span > trendSpan {
		first = last.AddDate(0, 0, -(trendSpan - 1))
	}
	days := int(last.Sub(first).Hours()/24) + 1
	slot := float64(trendWidth) / float64(days)
	width := min(int(slot)-2, trendMaxBar)
	for index := range days {
		date := first.AddDate(0, 0, index)
		day := byDay[date.Format(time.DateOnly)]
		day.Date = date
		day.X = int(float64(index)*slot + (slot-float64(width))/2)
		day.W = max(width, 1)
		day.H, day.Y = 0, trendBaseline
		switch {
		case day.Measured > 0 && trend.Max > 0:
			day.H = max(int(int64(trendBaseline-trendTop)*day.Total/trend.Max), 2)
			day.Y = trendBaseline - day.H
			day.Title = fmt.Sprintf("%s · %s tokens · %d of %d attempts measured",
				date.Format(time.DateOnly), groupDigits(day.Total), day.Measured, day.Attempts)
		case day.Attempts > 0:
			// A measured zero and an unmeasured day must not both draw nothing.
			// This is the fourth time this repository has had to separate "could
			// not ask" from "nothing found", so the unmeasured day gets its own
			// mark at the baseline and says so on hover.
			day.Missing, day.H, day.Y = true, 3, trendBaseline-3
			day.Title = fmt.Sprintf("%s · %d attempts, none measured",
				date.Format(time.DateOnly), day.Attempts)
		default:
			continue
		}
		trend.Days = append(trend.Days, day)
	}
	trend.MaxLabel = humanTokens(trend.Max)
	trend.First, trend.Last = first.Format(time.DateOnly), last.Format(time.DateOnly)
	return trend
}

// EpisodeTokens is what one episode's attempts spent.
//
// Summed across every manifest version rather than read off the latest one.
// Usage is written to whichever manifest the attempt pointed at when the turn
// finished, and extending the context mid-attempt writes a second version — so
// reading only the newest would report the tokens of the last stretch of work
// as the cost of the whole episode.
type EpisodeTokens struct {
	Tokens
	Manifests, Measured int
	CostedTurns         int
	CostUSD             float64
	Rows                []AttemptTokens
	Clock               WallClock
}

func (e EpisodeTokens) Recorded() bool { return e.Measured > 0 }

type AttemptTokens struct {
	Version                 int
	Provider, Model, Effort string
	Frozen                  time.Time
	Tokens
	Measured    bool
	CostedTurns int
	CostUSD     float64
	Clock       WallClock
}

func (r *Reader) EpisodeTokens(ctx context.Context, episodeID string) (EpisodeTokens, error) {
	var total EpisodeTokens
	rows, err := collect(ctx, r, `
	  SELECT version, COALESCE(provider,''), COALESCE(model,''),
	         COALESCE(reasoning_effort,''), created_at,
	         usage_input_tokens, usage_cached_input_tokens,
	         usage_output_tokens, usage_reasoning_tokens, usage_costed_turns,
	         usage_cost_usd,
	         usage_timed_turns, usage_queued_ms, usage_provider_ms, usage_host_ms
	  FROM context_manifests WHERE episode_id = ? ORDER BY version`,
		func(rows *sql.Rows) (AttemptTokens, error) {
			var item AttemptTokens
			var frozen string
			err := rows.Scan(&item.Version, &item.Provider, &item.Model, &item.Effort,
				&frozen, &item.Input, &item.Cached, &item.Output, &item.Reasoning,
				&item.CostedTurns, &item.CostUSD,
				&item.Clock.TimedTurns, &item.Clock.QueuedMS, &item.Clock.ProviderMS,
				&item.Clock.HostMS)
			item.Frozen = parseStamp(frozen)
			item.Measured = item.Input > 0 || item.Cached > 0 ||
				item.Output > 0 || item.Reasoning > 0
			return item, err
		}, episodeID)
	if err != nil {
		return EpisodeTokens{}, err
	}
	for _, row := range rows {
		total.Manifests++
		total.Input += row.Input
		total.Cached += row.Cached
		total.Output += row.Output
		total.Reasoning += row.Reasoning
		total.CostedTurns += row.CostedTurns
		total.CostUSD += row.CostUSD
		total.Clock.TimedTurns += row.Clock.TimedTurns
		total.Clock.QueuedMS += row.Clock.QueuedMS
		total.Clock.ProviderMS += row.Clock.ProviderMS
		total.Clock.HostMS += row.Clock.HostMS
		if row.Measured {
			total.Measured++
		}
	}
	total.Rows = rows
	return total, nil
}

// episodeLink builds one filtered episode URL.
//
// template.URL rather than a plain string, because html/template escapes an
// interpolated href as a single value: "?provider=x&model=y" would arrive as
// one unusable parameter. Declaring it safe is honest here — the path is a
// literal and url.Values.Encode escapes every value that came out of the
// database.
func episodeLink(values url.Values) template.URL {
	return template.URL("/episodes?" + values.Encode()) //nolint:gosec // built here from escaped values
}

// UsageCost keeps provider-reported money and configured token estimates apart.
// They are different evidence and must never be silently added into one bill.
type UsageCost struct {
	Currency                     string
	Configured                   bool
	ReportedUSD, Estimated       float64
	ReportedTurns, EstimatedRows int
	MeasuredRows                 int
}

func (c UsageCost) Reported() bool         { return c.ReportedTurns > 0 }
func (c UsageCost) EstimatedKnown() bool   { return c.EstimatedRows > 0 }
func (c UsageCost) Visible() bool          { return c.Reported() || c.Configured }
func (c UsageCost) ReportedMoney() string  { return money(c.ReportedUSD, "USD") }
func (c UsageCost) EstimatedMoney() string { return money(c.Estimated, c.Currency) }

// priceUsage fills the money column from provider reports first, then estimates
// only rows with measured tokens and no reported money. The totals stay apart.
func priceUsage(pricing config.Pricing, byModel []UsageGroup) ([]UsageGroup, UsageCost) {
	cost := UsageCost{Currency: pricing.Currency, Configured: len(pricing.Models) > 0}
	for index, row := range byModel {
		if row.CostedTurns > 0 {
			byModel[index].Cost = money(row.CostUSD, "USD") + " reported"
			cost.ReportedUSD += row.CostUSD
			cost.ReportedTurns += row.CostedTurns
			continue
		}
		if !row.Recorded() {
			continue
		}
		cost.MeasuredRows++
		amount, known := pricing.Cost(row.Provider, row.Model, core.ContextUsage{
			InputTokens:       int(row.Input),
			CachedInputTokens: int(row.Cached),
			OutputTokens:      int(row.Output),
			ReasoningTokens:   int(row.Reasoning),
		})
		if !known {
			if cost.Configured {
				byModel[index].Cost = "not priced"
			}
			continue
		}
		byModel[index].Cost = money(amount, pricing.Currency) + " estimated"
		cost.Estimated += amount
		cost.EstimatedRows++
	}
	return byModel, cost
}

// money never renders a measured amount as a bare zero: a real spend that
// rounds to 0.00 prints as "<0.01", the same rule pctLabel applies to shares.
func money(amount float64, currency string) string {
	if amount > 0 && amount < 0.005 {
		return "<0.01 " + currency
	}
	return strconv.FormatFloat(amount, 'f', 2, 64) + " " + currency
}

// pctLabel rounds without rounding a real quantity away.
//
// An engineering task that spent 61,000 tokens next to a triage lane that spent
// seven million is 0.8% of the window, and integer division printed that as
// "0%" — a zero standing where there is a measurement, which is the one thing
// no panel here is allowed to do. "<1%" says small; "0%" says none.
func pctLabel(part, whole int64) string {
	if whole == 0 {
		return "—"
	}
	rounded := part * 100 / whole
	if rounded == 0 && part > 0 {
		return "<1%"
	}
	return strconv.FormatInt(rounded, 10) + "%"
}

// humanTokens keeps a table readable without inventing precision.
//
// Exact counts are still carried in the SVG titles and in the four columns
// beside the total, so nothing here is the only place a number appears.
func humanTokens(count int64) string {
	switch {
	case count >= 10_000_000:
		return strconv.FormatInt(count/1_000_000, 10) + "M"
	case count >= 1_000_000:
		return strconv.FormatFloat(float64(count)/1_000_000, 'f', 1, 64) + "M"
	case count >= 10_000:
		return strconv.FormatInt(count/1_000, 10) + "k"
	case count >= 1_000:
		return strconv.FormatFloat(float64(count)/1_000, 'f', 1, 64) + "k"
	default:
		return strconv.FormatInt(count, 10)
	}
}

func groupDigits(count int64) string {
	digits := strconv.FormatInt(count, 10)
	var out strings.Builder
	for index, digit := range digits {
		if index > 0 && (len(digits)-index)%3 == 0 {
			out.WriteByte(',')
		}
		out.WriteRune(digit)
	}
	return out.String()
}
