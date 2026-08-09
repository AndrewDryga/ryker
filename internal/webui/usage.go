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

// usageColumns is the same five figures everywhere: how many attempts are in
// the group, how many of them a provider actually measured, and the four counts.
//
// Measured is counted rather than inferred from a zero total. Zero is a real
// answer for a trivial turn and ACP does not require an adapter to report usage
// at all, so an attempt nobody measured has to stay distinguishable from a free
// one — the same rule core.ContextUsage.Recorded encodes, applied to a SUM.
//
// Every SUM is wrapped in COALESCE because SQLite sums no rows to NULL, not to
// zero, and the driver refuses to scan that into an int. Left off the measured
// count, this failed the whole totals query on an empty window — the page's own
// "could not load" banner over a database that was simply quiet.
const usageColumns = `COUNT(*),
  COALESCE(SUM(m.usage_input_tokens > 0 OR m.usage_cached_input_tokens > 0
      OR m.usage_output_tokens > 0 OR m.usage_reasoning_tokens > 0),0),
  COALESCE(SUM(m.usage_input_tokens),0), COALESCE(SUM(m.usage_cached_input_tokens),0),
  COALESCE(SUM(m.usage_output_tokens),0), COALESCE(SUM(m.usage_reasoning_tokens),0)`

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

// UsageTotals is the headline: what was spent in the window, and over how much
// of it we actually have a measurement.
type UsageTotals struct {
	Tokens
	Attempts, Measured int
	First, Last        time.Time
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
			&totals.Output, &totals.Reasoning, &first, &last)
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
	Label, Sub         string
	Attempts, Measured int
	Tokens
	// Share of the window, filled in once the window total is known. It is the
	// reason to read a breakdown at all: the row worth acting on is the big one,
	// and a column of absolute counts makes the reader do that comparison.
	Share string
	Href  template.URL
}

func (g UsageGroup) Recorded() bool { return g.Measured > 0 }

// UsageTable is one breakdown and the question it splits by. Four of them share
// a single rendering, so a column added for one dimension appears for all four
// rather than drifting apart per section.
type UsageTable struct {
	Heading, Column, Note string
	Rows                  []UsageGroup
}

func shareOf(rows []UsageGroup, whole int64) []UsageGroup {
	for index, row := range rows {
		rows[index].Share = pctLabel(row.Total(), whole)
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
				&item.Cached, &item.Output, &item.Reasoning)
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
	Rows                []AttemptTokens
}

func (e EpisodeTokens) Recorded() bool { return e.Measured > 0 }

type AttemptTokens struct {
	Version                 int
	Provider, Model, Effort string
	Frozen                  time.Time
	Tokens
	Measured bool
}

func (r *Reader) EpisodeTokens(ctx context.Context, episodeID string) (EpisodeTokens, error) {
	var total EpisodeTokens
	rows, err := collect(ctx, r, `
	  SELECT version, COALESCE(provider,''), COALESCE(model,''),
	         COALESCE(reasoning_effort,''), created_at,
	         usage_input_tokens, usage_cached_input_tokens,
	         usage_output_tokens, usage_reasoning_tokens
	  FROM context_manifests WHERE episode_id = ? ORDER BY version LIMIT 50`,
		func(rows *sql.Rows) (AttemptTokens, error) {
			var item AttemptTokens
			var frozen string
			err := rows.Scan(&item.Version, &item.Provider, &item.Model, &item.Effort,
				&frozen, &item.Input, &item.Cached, &item.Output, &item.Reasoning)
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
