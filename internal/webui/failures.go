package webui

import (
	"context"
	"crypto/sha256"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"
)

// liveFailureWindow is how recently a cause must have happened to count as
// still happening.
//
// Two days rather than one. A cause that fires a few times a week is live and
// needs fixing; a one-day window would file it under history every quiet
// Tuesday and take it out again on Wednesday, which teaches an operator to
// distrust the split.
const liveFailureWindow = 48 * time.Hour

// FailureGroup is one cause of failure, everything that shares it, and whether
// it is still happening.
//
// The page listed 122 lifetime failures ordered by count. That put a pile of 29
// last seen five days ago above the 19 that had happened since yesterday, so a
// page whose subject was failing work every day read as untouched for a week —
// the operator's own conclusion was that the section was dead. Two things were
// wrong: the order asked "what has failed most, ever" when the question is what
// is failing now, and nothing distinguished a cause that had been fixed from a
// cause that was still firing.
type FailureGroup struct {
	Cause string
	Key   string
	// Count is every occurrence; Day and Week are the recent ones. A lifetime
	// count cannot go down, so on its own it is a fact about the past rather
	// than a status.
	Count, Day, Week int
	// Variants is how many distinct error texts fold into this cause, which is
	// the number that says whether the grouping hid anything.
	Variants      int
	First, Latest time.Time
}

// Live reports a cause that has happened recently enough to still be a problem.
func (g FailureGroup) Live() bool { return time.Since(g.Latest) < liveFailureWindow }

// Spread says over what period this cause has been failing, which separates a
// burst from a slow leak — they need different fixes.
func (g FailureGroup) Spread() string {
	if g.Count < 2 || g.First.IsZero() || !g.First.Before(g.Latest) {
		return ""
	}
	return "over " + humanDuration(g.Latest.Sub(g.First))
}

// Failures groups every failed run by cause, newest cause first.
//
// Grouping is done here rather than in SQL because the cause has to be
// normalised first: one problem was arriving as four rows because the error
// text carried the operation id that made each occurrence unique, and a fifth
// and sixth because a suffix explained the same failure in more detail. Four
// hundred failed runs is a small table to read and a much better one to group
// once it can be read as prose.
func (r *Reader) Failures(ctx context.Context) ([]FailureGroup, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT COALESCE(NULLIF(last_error,''),'(no error recorded)'), updated_at
	  FROM agent_runs WHERE terminal_state = 'failed'
	  ORDER BY updated_at DESC LIMIT 2000`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	index := map[string]int{}
	groups := []FailureGroup{}
	variants := map[string]map[string]bool{}
	day, week := time.Now().Add(-24*time.Hour), time.Now().Add(-7*24*time.Hour)
	for rows.Next() {
		var cause, updated string
		if err := rows.Scan(&cause, &updated); err != nil {
			return nil, err
		}
		family := failureFamily(cause)
		at := parseStamp(updated)
		position, seen := index[family]
		if !seen {
			position = len(groups)
			index[family] = position
			variants[family] = map[string]bool{}
			// A hash, because the cause is free text containing slashes, quotes
			// and newlines. The page looks the cause back up from it.
			groups = append(groups, FailureGroup{
				Cause: family,
				Key:   fmt.Sprintf("%x", sha256.Sum256([]byte(family)))[:16],
				First: at, Latest: at,
			})
		}
		group := &groups[position]
		group.Count++
		variants[family][cause] = true
		if at.After(group.Latest) {
			group.Latest = at
		}
		if !at.IsZero() && (group.First.IsZero() || at.Before(group.First)) {
			group.First = at
		}
		if at.After(day) {
			group.Day++
		}
		if at.After(week) {
			group.Week++
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for index := range groups {
		groups[index].Variants = len(variants[groups[index].Cause])
	}
	// Most recent first. Within a day, the busier cause leads: two things that
	// broke this morning are ordered by how much they broke.
	sort.SliceStable(groups, func(i, j int) bool {
		left, right := groups[i], groups[j]
		if left.Live() != right.Live() {
			return left.Live()
		}
		if left.Live() && left.Day != right.Day {
			return left.Day > right.Day
		}
		return left.Latest.After(right.Latest)
	})
	return groups, nil
}

// volatileFailureToken matches the parts of an error that differ on every
// occurrence and identify nothing: operation ids, long hex digests, and the
// byte counts a size complaint quotes back.
var volatileFailureToken = regexp.MustCompile(
	`\b(?:op_[0-9a-f]{8,}|[0-9a-f]{16,}|\d+-byte|\d{4,})\b`)

// failureFamily reduces one error text to the problem it represents.
//
// Errors are written as a headline followed by the specifics: "ACP child closed
// before its response: Coop box image is not built; run 'coop build'". The
// headline is the problem and the tail is one instance of it, so grouping on
// the whole string splits one problem across as many rows as it has instances —
// which is exactly what buried the live causes under a dead one.
//
// The tail is not discarded, only moved: the group's detail page lists every
// distinct text folded into it, so nothing that was said is unreachable.
func failureFamily(cause string) string {
	family := strings.TrimSpace(volatileFailureToken.ReplaceAllString(cause, "…"))
	// Only at a colon that separates a headline from an explanation. A colon in
	// the first few characters is punctuation inside a label, not a boundary,
	// and cutting there would group unrelated failures under a fragment.
	if head, _, found := strings.Cut(family, ": "); found && len(head) >= 16 {
		family = head
	}
	if line, _, found := strings.Cut(family, "\n"); found {
		family = strings.TrimSpace(line)
	}
	// A trailing "operation=…" is what is left when the id that followed it was
	// the volatile part. The label named the id and the id is gone, so the label
	// is now noise at the end of the headline.
	family = strings.TrimSpace(trailingLabel.ReplaceAllString(family, ""))
	if family == "" {
		return "(no error recorded)"
	}
	return family
}

// trailingLabel matches a "name=" left stranded at the end of a headline once
// the value it introduced was recognised as volatile and removed.
var trailingLabel = regexp.MustCompile(`\s+[\w.]+=…$`)

// Tally is the counts worth reading, and only those.
//
// Every count is the same number on a cause that started today, and printing
// "19 today · 19 this week · 19 all time" three times over asks the reader to
// compare three figures to discover they are one. A row earns each number by
// differing from the one before it.
func (g FailureGroup) Tally() string {
	switch {
	case g.Count == 0:
		return ""
	case g.Day == g.Count:
		return fmt.Sprintf("%d today, all of them", g.Count)
	case g.Week == g.Count && g.Day > 0:
		return fmt.Sprintf("%d today of %d this week, all of them", g.Day, g.Week)
	case g.Week == g.Count:
		return fmt.Sprintf("%d this week, all of them", g.Week)
	case g.Day > 0:
		return fmt.Sprintf("%d today · %d this week · %d all time", g.Day, g.Week, g.Count)
	case g.Week > 0:
		return fmt.Sprintf("%d this week · %d all time", g.Week, g.Count)
	}
	return fmt.Sprintf("%d in total", g.Count)
}

// FailureVariant is one distinct error text inside a cause, and how often it
// was the one recorded.
type FailureVariant struct {
	Text  string
	Count int
}

// FailureVariants is every distinct error text folded into one cause. Grouping
// that cannot be unfolded is a claim the operator has to take on trust.
func (r *Reader) FailureVariants(ctx context.Context, family string) ([]FailureVariant, error) {
	if !r.live() || family == "" {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT COALESCE(NULLIF(last_error,''),'(no error recorded)'), COUNT(*)
	  FROM agent_runs WHERE terminal_state = 'failed'
	  GROUP BY 1 ORDER BY COUNT(*) DESC LIMIT 200`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []FailureVariant{}
	for rows.Next() {
		var item FailureVariant
		if err := rows.Scan(&item.Text, &item.Count); err != nil {
			return nil, err
		}
		if failureFamily(item.Text) == family {
			items = append(items, item)
		}
	}
	return items, rows.Err()
}

// FailureShape is what a cause's runs have in common, which is the first thing
// an operator works out by eye and the thing a table of near-identical rows
// makes them work out row by row.
//
// Nineteen rows reading "triage · 20 attempts" across six channels is one fact,
// not nineteen: every triage run in the deployment is exhausting its retries.
// Stated once, it points at the code; left in the table, it reads as nineteen
// unrelated incidents.
func FailureShape(runs []FailureRun) string {
	if len(runs) < 2 {
		return ""
	}
	modes, channels := map[string]bool{}, map[string]bool{}
	attempts, retryable := 0, 0
	for _, run := range runs {
		if run.Mode != "" {
			modes[run.Mode] = true
		}
		if run.Channel != "" {
			channels[run.Channel] = true
		}
		attempts = max(attempts, run.Attempts)
		if run.Retryable {
			retryable++
		}
	}
	parts := []string{fmt.Sprintf("%d runs", len(runs))}
	if len(modes) == 1 {
		for mode := range modes {
			parts = append(parts, "all "+mode)
		}
	} else if len(modes) > 1 {
		parts = append(parts, fmt.Sprintf("%d kinds of work", len(modes)))
	}
	if len(channels) == 1 {
		for channel := range channels {
			parts = append(parts, "all in "+channel)
		}
	} else if len(channels) > 1 {
		parts = append(parts, fmt.Sprintf("across %d channels", len(channels)))
	}
	if attempts > 0 {
		parts = append(parts, fmt.Sprintf("up to %d attempts each", attempts))
	}
	parts = append(parts, fmt.Sprintf("%d can be retried", retryable))
	return strings.Join(parts, " · ")
}

// humanDuration says how long something lasted in one unit, because a spread is
// read for its order of magnitude and not for its minutes.
func humanDuration(span time.Duration) string {
	switch {
	case span >= 48*time.Hour:
		return fmt.Sprintf("%d days", int(span.Hours()/24))
	case span >= 2*time.Hour:
		return fmt.Sprintf("%d hours", int(span.Hours()))
	case span >= time.Minute:
		return fmt.Sprintf("%d minutes", int(span.Minutes()))
	}
	return "under a minute"
}
