package webui

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

// Reader is the dashboard's own read-only view of the database.
//
// A separate connection rather than the service's store, for two reasons. It
// cannot migrate, write or lock anything the running service depends on — a
// dashboard should never be able to hurt the thing it observes. And the queries
// here are presentation shapes that would otherwise grow internal/store, which
// is already at its line budget.
type Reader struct {
	db       *sql.DB
	channels sync.Map
}

func OpenReader(path string) (*Reader, error) {
	db, err := sql.Open("sqlite", "file:"+path+"?mode=ro&_pragma=busy_timeout(2000)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(2)
	return &Reader{db: db}, nil
}

func (r *Reader) Close() error {
	if !r.live() {
		return nil
	}
	return r.db.Close()
}

// live reports whether there is a database to read.
//
// The dashboard observes the service; it must never be able to hurt it. If the
// database could not be opened, every panel degrades to empty rather than
// taking down the process that is still answering Slack.
func (r *Reader) live() bool { return r != nil && r.db != nil }

func parseStamp(value string) time.Time {
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02T15:04:05.999999999Z"} {
		if parsed, err := time.Parse(layout, value); err == nil {
			return parsed
		}
	}
	return time.Time{}
}

type Item struct {
	ID      string
	Title   string
	State   string
	Kind    string
	Channel string
	Status  string
	Next    string
	Created time.Time
	Updated time.Time
}

const episodeSelect = `
  SELECT e.id, COALESCE(c.title, ''), e.lifecycle_state, COALESCE(r.mode, ''),
         COALESCE(r.channel_id, ''), COALESCE(e.status, ''), COALESCE(e.next_action, ''),
         e.created_at, e.updated_at
  FROM work_episodes AS e
  LEFT JOIN commitments AS c ON c.episode_id = e.id
  LEFT JOIN agent_runs AS r ON r.id = e.agent_run_id`

func (r *Reader) scanItems(ctx context.Context, query string, args ...any) ([]Item, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []Item{}
	for rows.Next() {
		var item Item
		var created, updated string
		if err := rows.Scan(&item.ID, &item.Title, &item.State, &item.Kind,
			&item.Channel, &item.Status, &item.Next, &created, &updated); err != nil {
			return nil, err
		}
		item.Created, item.Updated = parseStamp(created), parseStamp(updated)
		if item.Title == "" {
			item.Title = "Untitled work"
		}
		item.Channel = r.channelName(ctx, item.Channel)
		item.Title = cleanTitle(item.Title)
		items = append(items, item)
	}
	return items, rows.Err()
}

// Blocked is the same set the App Home leads with: work a person can move.
// 'failed' is excluded for the same reason it is excluded there — a crash the
// retry machinery owns is not a decision anyone is waiting to make.
func (r *Reader) Blocked(ctx context.Context, limit int) ([]Item, error) {
	return r.scanItems(ctx, episodeSelect+`
	  WHERE e.lifecycle_state IN ('blocked','waiting_operator','waiting_approval')
	  ORDER BY e.updated_at DESC LIMIT ?`, limit)
}

func (r *Reader) Episodes(ctx context.Context, limit int) ([]Item, error) {
	return r.scanItems(ctx, episodeSelect+` ORDER BY e.created_at DESC LIMIT ?`, limit)
}

func (r *Reader) Episode(ctx context.Context, id string) (Item, error) {
	items, err := r.scanItems(ctx, episodeSelect+` WHERE e.id = ? LIMIT 1`, id)
	if err != nil || len(items) == 0 {
		return Item{}, err
	}
	return items[0], nil
}

// channelName trades the raw id for the name, because "#C0TENANTOPS" tells a
// reader nothing.
func (r *Reader) channelName(ctx context.Context, id string) string {
	if id == "" || !r.live() {
		return ""
	}
	if name, known := r.channelLookup(ctx, id); known {
		return "#" + name
	}
	return "#" + id
}

// channelLookup answers from a cache the earlier version only claimed to have.
//
// It is called once per row and now again for every id embedded in free text,
// so a page of forty audit rows was forty round trips for a table with a dozen
// entries in it. Names are cached for the life of the process because a channel
// rename is not something this dashboard has to notice within a page load.
func (r *Reader) channelLookup(ctx context.Context, id string) (string, bool) {
	if cached, ok := r.channels.Load(id); ok {
		name, _ := cached.(string)
		return name, name != ""
	}
	var name string
	if err := r.db.QueryRowContext(ctx,
		`SELECT channel_name FROM slack_channel_memberships WHERE channel_id = ?`, id).
		Scan(&name); err != nil {
		name = ""
	}
	r.channels.Store(id, name)
	return name, name != ""
}

// slackChannelID matches the raw ids that leak into stored free text.
//
// An audit detail reading "channel=C0TENANTX01 participation=proactive" says
// which setting changed and not which channel it changed for, and a publication
// note citing "Slack message C0TENANTOPS/1785885550.501459" is a coordinate
// nobody can read. Only ids with a known name are swapped: turning an unknown
// id into "#C0TENANTX01" would dress a failed lookup as a resolved one.
var slackChannelID = regexp.MustCompile(`\bC[A-Z0-9]{8,}\b`)

func (r *Reader) resolveChannels(ctx context.Context, text string) string {
	if !r.live() || !strings.Contains(text, "C") {
		return text
	}
	return slackChannelID.ReplaceAllStringFunc(text, func(id string) string {
		if name, known := r.channelLookup(ctx, id); known {
			return "#" + name
		}
		return id
	})
}

// cleanTitle strips the source message's own markup. A title is usually the
// Slack message that started the work, so an alert arrives as the whole
// "<https://grafana…|[VA1 FIRING:1] …> *FIRING*" and fills a row with a URL.
func cleanTitle(title string) string {
	cleaned := slackLink.ReplaceAllString(strings.TrimSpace(title), "$1")
	cleaned = strings.TrimSpace(bareLink.ReplaceAllString(cleaned, ""))
	// What the screenshots kept finding after the URL pass: ":fire:" rendered
	// as literal colons, because only Slack expands shortcodes; "[no value]"
	// leaked out of an upstream template handed a nil field; and a title cut
	// at its storage bound mid-link left an orphaned "|Run run-Qmzu…" whose
	// URL half had stripped as a bare link. The pipe becomes a separator dot
	// rather than vanishing, since inside alert titles it separates clauses.
	cleaned = emojiCode.ReplaceAllString(cleaned, "")
	cleaned = strings.ReplaceAll(cleaned, "[no value]", "")
	cleaned = strings.NewReplacer("*", "", "_", "", "`", "", "|", " · ").Replace(cleaned)
	cleaned = strings.Trim(strings.Join(strings.Fields(cleaned), " "), "·—- ")
	// Punctuation left over from stripping is not a title. A Slack permalink
	// posted with the same URL as its own link text arrives truncated, so the
	// closing bracket is missing, both halves strip as bare links, and the
	// separator survives alone: one row of the episode list was the single
	// character "|".
	if !strings.ContainsFunc(cleaned, func(symbol rune) bool {
		return unicode.IsLetter(symbol) || unicode.IsDigit(symbol)
	}) {
		return "Untitled work"
	}
	return cleaned
}

var (
	slackLink = regexp.MustCompile(`<https?://[^|>]+\|([^>]*)>`)
	bareLink  = regexp.MustCompile(`<?https?://[^\s|>]+>?`)
	emojiCode = regexp.MustCompile(`:[a-z0-9_+-]{2,32}:`)
)

// The counted queries are named rather than written inline at each call site.
//
// Count cannot report a failure — it has one return value and a broken query
// comes back as 0, which on this dashboard is supposed to mean "none" and not
// "could not ask". That is the same defect as the swallowed evidence error,
// only quieter, because a zero looks like an answer. Naming them lets one test
// run every counter against a migrated schema; countedQueries below is the list
// that test walks, and a new counter belongs in both places.
const (
	countNeedsDecision = `SELECT COUNT(*) FROM work_episodes
	  WHERE lifecycle_state IN ('blocked','waiting_operator','waiting_approval')`
	countFailedRuns = `SELECT COUNT(*) FROM agent_runs WHERE terminal_state = 'failed'`
	countInFlight   = `SELECT COUNT(*) FROM work_episodes
	  WHERE lifecycle_state IN ('accepted','acknowledged','planning','working','retrying','verifying')`
	countRetained     = `SELECT COUNT(*) FROM coop_cleanup WHERE state = 'blocked'`
	countCleanupDone  = `SELECT COUNT(*) FROM coop_cleanup WHERE state = 'done'`
	countEpisodes     = `SELECT COUNT(*) FROM work_episodes`
	countTerminalRuns = `SELECT COUNT(*) FROM agent_runs WHERE terminal_state <> ''`
	countCorrections  = `SELECT COUNT(*) FROM fixture_candidates WHERE correction_class = ?`
	countAudited      = `SELECT COUNT(*) FROM audit_events`
	countAuditKind    = `SELECT COUNT(*) FROM audit_events WHERE kind = ?`
)

func (r *Reader) Count(ctx context.Context, query string, args ...any) int {
	if !r.live() {
		return 0
	}
	var count int
	if err := r.db.QueryRowContext(ctx, query, args...).Scan(&count); err != nil {
		return 0
	}
	return count
}

// Schema reports the version the database is actually at, which differs from
// the one the binary expects exactly when something is wrong.
func (r *Reader) Schema(ctx context.Context) string {
	if !r.live() {
		return "unavailable"
	}
	var version int
	if err := r.db.QueryRowContext(ctx, `PRAGMA user_version`).Scan(&version); err != nil || version == 0 {
		if err := r.db.QueryRowContext(ctx,
			`SELECT MAX(version) FROM schema_version`).Scan(&version); err != nil {
			return "unknown"
		}
	}
	return strconv.Itoa(version)
}

type Event struct {
	Kind    string
	Actor   string
	Detail  string
	At      time.Time
	Elapsed string
	Attempt int
	Repeats int
	Span    string
}

// Events renders the episode's own history. 11,679 of these exist and none is
// visible anywhere today, which is why "why did it say that" has been answered
// by running sqlite against production.
func (r *Reader) Events(ctx context.Context, episodeID string) ([]Event, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT kind, actor, payload_json, created_at
	  FROM work_episode_events WHERE episode_id = ?
	  ORDER BY sequence ASC LIMIT 400`, episodeID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	events := []Event{}
	attempt := 1
	for rows.Next() {
		var event Event
		var payload, at string
		if err := rows.Scan(&event.Kind, &event.Actor, &payload, &at); err != nil {
			return nil, err
		}
		event.At = parseStamp(at)
		event.Detail = summarizePayload(event.Kind, payload)
		// Where the time went. Six minutes between two rows is the interesting
		// part of a timeline and was invisible when every row showed only a
		// wall-clock stamp.
		if len(events) > 0 {
			if gap := event.At.Sub(events[len(events)-1].At); gap >= time.Second {
				event.Elapsed = "+" + gap.Round(time.Second).String()
			}
		}
		// A reopen starts a new attempt. This episode ran twice; the timeline
		// read as one long sequence that inexplicably planned the work twice.
		event.Attempt = attempt
		if event.Kind == "episode_reopened" {
			attempt++
			event.Attempt = attempt
		}
		events = append(events, event)
	}
	return collapseEvents(events), rows.Err()
}

// summarizePayload says what an event actually was.
//
// A generic scan of top-level keys showed almost nothing: the content lives
// nested and differs per kind. Six `evidence_recorded` rows rendered as the
// word "evidence_recorded" six times, and a `completion_submitted` — the whole
// answer — rendered as nothing at all. Each kind is unpacked where its
// substance really is.
func summarizePayload(kind, payload string) string {
	var decoded map[string]any
	if err := json.Unmarshal([]byte(payload), &decoded); err != nil {
		return ""
	}
	nested := func(outer, inner string) string {
		object, ok := decoded[outer].(map[string]any)
		if !ok {
			return ""
		}
		value, _ := object[inner].(string)
		return value
	}
	number := func(key string) float64 {
		value, _ := decoded[key].(float64)
		return value
	}
	switch kind {
	case "evidence_recorded":
		if claim := nested("evidence", "claim"); claim != "" {
			return claim
		}
		if observation := nested("evidence", "observation"); observation != "" {
			return observation
		}
	case "completion_submitted":
		status := ""
		if inner, ok := decoded["completion"].(map[string]any); ok {
			if deeper, ok := inner["completion"].(map[string]any); ok {
				status, _ = deeper["status"].(string)
				if verdict, _ := deeper["verdict"].(string); verdict != "" {
					status += " · " + verdict
				}
			}
		}
		message := nested("completion", "message")
		if status != "" && message != "" {
			return status + " — " + message
		}
		return status + message
	case "context_extended":
		// A count is the substance here: how much context the turn was given.
		return fmt.Sprintf("%d references, manifest v%d",
			int(number("reference_count")), int(number("version")))
	case "destination_changed":
		reason, _ := decoded["reason"].(string)
		return "reply routed elsewhere · " + strings.ReplaceAll(reason, "_", " ")
	case "progress_reported":
		// Falls through when the nested lookup is empty rather than returning
		// it: a kind-specific branch that guesses wrong must not silence the
		// generic one, which is how progress reports briefly went blank.
		if summary := nested("progress", "summary"); summary != "" {
			return summary
		}
	}
	for _, key := range []string{"status", "summary", "detail", "reason", "message", "phase"} {
		if value, ok := decoded[key].(string); ok && strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

// collapseEvents folds consecutive identical events into one row with a count
// and the span they cover.
//
// Waiting is one fact however long it lasts, and a hundred rows of it is not a
// hundred things that happened. The store no longer writes those repeats, but
// 5,483 of them are already on disk and history still has to be readable. Only
// consecutive ones fold: merging across a different event would hide the thing
// that actually happened.
func collapseEvents(events []Event) []Event {
	folded := make([]Event, 0, len(events))
	for _, event := range events {
		last := len(folded) - 1
		if last >= 0 && folded[last].Kind == event.Kind && folded[last].Detail == event.Detail {
			folded[last].Repeats++
			if span := event.At.Sub(folded[last].At); span >= time.Second {
				folded[last].Span = span.Round(time.Second).String()
			}
			continue
		}
		folded = append(folded, event)
	}
	return folded
}

// EvidenceRow is one observation the episode recorded.
//
// Relation is shown because "supports" and "contradicts" are the whole point of
// the ledger: without it a contradicting observation reads as another reason to
// believe the claim it was recorded to refute.
type EvidenceRow struct {
	ClaimID     string
	Claim       string
	Observation string
	Relation    string
	Source      string
	Freshness   string
	Confidence  string
}

func (r *Reader) Evidence(ctx context.Context, episodeID string) ([]EvidenceRow, error) {
	return collect(ctx, r, `
	  SELECT COALESCE(claim_id,''), COALESCE(claim,''), COALESCE(observation,''),
	         COALESCE(relation,''), COALESCE(source_name,''), COALESCE(freshness,''),
	         COALESCE(confidence,'')
	  FROM evidence WHERE source_input IN (`+episodeSources+`)
	  ORDER BY created_at LIMIT 100`,
		func(rows *sql.Rows) (EvidenceRow, error) {
			var item EvidenceRow
			err := rows.Scan(&item.ClaimID, &item.Claim, &item.Observation, &item.Relation,
				&item.Source, &item.Freshness, &item.Confidence)
			// An observation sourced from "HCP Terraform run notifications in
			// C0TENANTOPS" names the wrong half of where it came from.
			item.Source = r.resolveChannels(ctx, item.Source)
			item.Observation = r.resolveChannels(ctx, item.Observation)
			return item, err
		}, episodeID, episodeID)
}

type FailureGroup struct {
	Cause  string
	Key    string
	Count  int
	Latest time.Time
}

// Failures are grouped because a hundred failures are rarely a hundred
// problems, and a flat list of a hundred rows is not triage.
func (r *Reader) Failures(ctx context.Context) ([]FailureGroup, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT COALESCE(NULLIF(last_error,''),'(no error recorded)'), COUNT(*), MAX(updated_at)
	  FROM agent_runs WHERE terminal_state = 'failed'
	  GROUP BY 1 ORDER BY COUNT(*) DESC LIMIT 40`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	groups := []FailureGroup{}
	for rows.Next() {
		var group FailureGroup
		var latest string
		if err := rows.Scan(&group.Cause, &group.Count, &latest); err != nil {
			return nil, err
		}
		group.Latest = parseStamp(latest)
		// A hash, because the cause is free text containing slashes, quotes and
		// newlines. The page looks the cause back up from it.
		group.Key = fmt.Sprintf("%x", sha256.Sum256([]byte(group.Cause)))[:16]
		groups = append(groups, group)
	}
	return groups, rows.Err()
}

type Correction struct {
	ID        string
	EpisodeID string
	Text      string
	Class     string
	Created   time.Time
	Expires   time.Time
}

func (r *Reader) Corrections(ctx context.Context) ([]Correction, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT id, correction, correction_class, created_at, expires_at
	  FROM fixture_candidates WHERE status = 'pending'
	  ORDER BY created_at DESC LIMIT 50`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []Correction{}
	for rows.Next() {
		var item Correction
		var created, expires string
		if err := rows.Scan(&item.ID, &item.EpisodeID, &item.Text, &item.Class, &created, &expires); err != nil {
			return nil, err
		}
		item.Created, item.Expires = parseStamp(created), parseStamp(expires)
		items = append(items, item)
	}
	return items, rows.Err()
}

type ChannelMemoryRow struct {
	Channel   string
	Summary   string
	OpenLoops int
	Updated   time.Time
}

func (r *Reader) ChannelMemory(ctx context.Context) ([]ChannelMemoryRow, error) {
	if !r.live() {
		return nil, nil
	}
	// conversation_memories at channel level, not channel_memories: the latter
	// is the session-binding ledger, its state was being wiped to '{}' by every
	// ignore decision until the store grew the guard its sibling had, and rows
	// wiped before that fix stay empty until the next real memory update. The
	// conversation table kept the truth throughout — reading it shows the
	// summaries that "No current summary" was rendered on top of.
	rows, err := r.db.QueryContext(ctx, `
	  SELECT channel_id, COALESCE(state_json,'{}'), updated_at
	  FROM conversation_memories WHERE thread_ts = ''
	  ORDER BY updated_at DESC LIMIT 25`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []ChannelMemoryRow{}
	for rows.Next() {
		var item ChannelMemoryRow
		var state, updated string
		if err := rows.Scan(&item.Channel, &state, &updated); err != nil {
			return nil, err
		}
		item.Updated = parseStamp(updated)
		item.Channel = r.channelName(ctx, item.Channel)
		var decoded struct {
			SituationSummary string `json:"situation_summary"`
			OpenLoops        []any  `json:"open_loops"`
		}
		if json.Unmarshal([]byte(state), &decoded) == nil {
			item.Summary = decoded.SituationSummary
			item.OpenLoops = len(decoded.OpenLoops)
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

type ChannelConfigRow struct {
	Channel    string
	Mode       string
	Repository string
}

func (r *Reader) Channels(ctx context.Context) ([]ChannelConfigRow, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT channel_id, COALESCE(participation,''), COALESCE(repository,'')
	  FROM channel_configurations ORDER BY channel_id LIMIT 50`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []ChannelConfigRow{}
	for rows.Next() {
		var item ChannelConfigRow
		if err := rows.Scan(&item.Channel, &item.Mode, &item.Repository); err != nil {
			return nil, err
		}
		// Through channelName like everywhere else. This page built the "#" by
		// hand and rendered "#C0TENANTENG" for every configured channel, which
		// is the one page an operator opens to check which channel a setting
		// belongs to.
		item.Channel = r.channelName(ctx, item.Channel)
		items = append(items, item)
	}
	return items, rows.Err()
}

// MemoryEntry is one saved operational fact.
//
// Recall count is shown because it is the only evidence that a memory is worth
// keeping. A store nobody reads from is a store to prune, and that is invisible
// without it.
type MemoryEntry struct {
	ID                               string
	Subject, Predicate, Value, Scope string
	Recalls                          int
	Expires, LastRecalled            time.Time
}

func (r *Reader) MemoryEntries(ctx context.Context) ([]MemoryEntry, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT id, subject_key, predicate, value_json, scope_kind, scope_key,
	         recall_count, expires_at, COALESCE(last_recalled_at,'')
	  FROM memory_entries ORDER BY updated_at DESC LIMIT 100`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []MemoryEntry{}
	for rows.Next() {
		var item MemoryEntry
		var scopeKey, expires, recalled string
		if err := rows.Scan(&item.ID, &item.Subject, &item.Predicate, &item.Value, &item.Scope,
			&scopeKey, &item.Recalls, &expires, &recalled); err != nil {
			return nil, err
		}
		// A memory scoped to a channel showed "channel C0TENANTX04", which names
		// the scope and hides the channel.
		if scopeKey != "" {
			item.Scope += " " + r.resolveChannels(ctx, scopeKey)
		}
		item.Value = strings.Trim(item.Value, `"`)
		item.Expires, item.LastRecalled = parseStamp(expires), parseStamp(recalled)
		items = append(items, item)
	}
	return items, rows.Err()
}

// Rollup is synthesized continuity for a scope over a period — the lossy
// summary that survives when individual conversations age out.
type Rollup struct {
	Scope   string
	Sources int
	Recalls int
	From    time.Time
	To      time.Time
}

func (r *Reader) Rollups(ctx context.Context) ([]Rollup, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT scope_kind, scope_key, source_count, recall_count, period_start, period_end
	  FROM memory_rollups ORDER BY period_end DESC LIMIT 50`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []Rollup{}
	for rows.Next() {
		var item Rollup
		var kind, key, from, to string
		if err := rows.Scan(&kind, &key, &item.Sources, &item.Recalls, &from, &to); err != nil {
			return nil, err
		}
		item.Scope = kind + " " + r.resolveChannels(ctx, key)
		item.From, item.To = parseStamp(from), parseStamp(to)
		items = append(items, item)
	}
	return items, rows.Err()
}

// Conversation is per-channel-and-thread memory, distinct from the channel
// situation: there are twenty-one of these against four situations, and only
// the situations were visible anywhere.
type Conversation struct {
	Channel, ChannelID, Thread, Repository string
	Recalls                                int
	Updated                                time.Time
}

func (r *Reader) Conversations(ctx context.Context) ([]Conversation, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT channel_id, thread_ts, repository, recall_count, updated_at
	  FROM conversation_memories ORDER BY updated_at DESC LIMIT 60`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []Conversation{}
	for rows.Next() {
		var item Conversation
		var channel, updated string
		if err := rows.Scan(&channel, &item.Thread, &item.Repository, &item.Recalls, &updated); err != nil {
			return nil, err
		}
		item.ChannelID = channel
		item.Channel = r.channelName(ctx, channel)
		item.Updated = parseStamp(updated)
		if item.Thread == "" {
			item.Thread = "channel"
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

// ReviewItem is memory the host flagged as stale or duplicated and is holding
// for a person. Zero of them today, and no surface existed to notice that.
type ReviewItem struct {
	ID                   string
	Kind, Reason, Status string
	Entries              int
	Created              time.Time
}

func (r *Reader) MemoryReview(ctx context.Context) ([]ReviewItem, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT id, kind, reason, status, json_array_length(entry_ids_json), created_at
	  FROM memory_review_items
	  WHERE status = 'pending' ORDER BY created_at DESC LIMIT 50`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []ReviewItem{}
	for rows.Next() {
		var item ReviewItem
		var created string
		if err := rows.Scan(&item.ID, &item.Kind, &item.Reason, &item.Status,
			&item.Entries, &created); err != nil {
			return nil, err
		}
		item.Created = parseStamp(created)
		items = append(items, item)
	}
	return items, rows.Err()
}

// Feedback is what a person said about a Responder answer. It had no surface
// at all, which is a poor showing for the one entity that records a human
// telling the system it was wrong.
type Feedback struct {
	ID                                            string
	Category, Sentiment, Summary, Status, Channel string
	EpisodeID                                     string
	Created                                       time.Time
}

// Open reports whether the item still awaits a decision, which is what gates
// its actions: dismissing or converting a resolved item is the no-op the
// store refuses, so the page does not offer it.
func (f Feedback) Open() bool { return f.Status == "open" || f.Status == "" }

func (r *Reader) Feedback(ctx context.Context) ([]Feedback, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT id, category, sentiment, summary, COALESCE(status,''), channel_id,
	         COALESCE(episode_id,''), created_at
	  FROM feedback_items ORDER BY created_at DESC LIMIT 50`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []Feedback{}
	for rows.Next() {
		var item Feedback
		var channel, created string
		if err := rows.Scan(&item.ID, &item.Category, &item.Sentiment, &item.Summary,
			&item.Status, &channel, &item.EpisodeID, &created); err != nil {
			return nil, err
		}
		item.Channel = r.channelName(ctx, channel)
		item.Created = parseStamp(created)
		items = append(items, item)
	}
	return items, rows.Err()
}

// FailureRun is one run behind a grouped cause, so a group is a way in rather
// than a dead end. Ninety-eight failures collapsed to seven causes is triage;
// being unable to open one of them is a report.
//
// Retryable is decided here by the same rule the store enforces — only the
// episode's latest attempt can be requeued — so the page never offers a retry
// the store will refuse. Why carries the refusal for the rows that would get
// one, because a run without a button and without a reason reads as a
// rendering fault.
type FailureRun struct {
	RunID                    string
	EpisodeID, Channel, Mode string
	Attempts                 int
	Updated                  time.Time
	Retryable                bool
	Why                      string
}

// CauseForKey resolves the hash back to the error text.
func (r *Reader) CauseForKey(ctx context.Context, key string) string {
	groups, err := r.Failures(ctx)
	if err != nil {
		return ""
	}
	for _, group := range groups {
		if group.Key == key {
			return group.Cause
		}
	}
	return ""
}

func (r *Reader) FailureRuns(ctx context.Context, cause string) ([]FailureRun, error) {
	if !r.live() {
		return nil, nil
	}
	// Joined on the run's own episode_id, not on work_episodes.agent_run_id:
	// that column names the episode's first run, so every later attempt of a
	// retried episode rendered "no episode" over an episode that was right
	// there.
	rows, err := r.db.QueryContext(ctx, `
	  SELECT a.id, COALESCE(a.episode_id,''), COALESCE(a.channel_id,''), COALESCE(a.mode,''),
	         COALESCE(a.failure_count,0), a.updated_at,
	         COALESCE(a.attempt_id,''), COALESCE(e.latest_attempt_id,''),
	         COALESCE(e.lifecycle_state,'')
	  FROM agent_runs AS a
	  LEFT JOIN work_episodes AS e ON e.id = a.episode_id
	  WHERE a.terminal_state = 'failed'
	    AND COALESCE(NULLIF(a.last_error,''),'(no error recorded)') = ?
	  ORDER BY a.updated_at DESC LIMIT 100`, cause)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []FailureRun{}
	for rows.Next() {
		var item FailureRun
		var channel, updated, attempt, latest, episodeState string
		if err := rows.Scan(&item.RunID, &item.EpisodeID, &channel, &item.Mode,
			&item.Attempts, &updated, &attempt, &latest, &episodeState); err != nil {
			return nil, err
		}
		item.Channel = r.channelName(ctx, channel)
		item.Updated = parseStamp(updated)
		switch {
		case episodeState == "":
			item.Why = "no episode record to reopen"
		case attempt != latest:
			item.Why = "a newer attempt has run for this episode; retrying this one would race it"
		case episodeState == "completed":
			item.Why = "the episode completed on a later attempt"
		default:
			item.Retryable = true
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

// Knowledge is one learned fact inside a conversation's memory.
type Knowledge struct {
	Subject, Kind, Statement, Status, Source string
	Confidence                               int
}

// ConversationDetail unpacks the state blob that a list can only count.
//
// The goal, open loops and knowledge items are the substance of what Responder
// believes about a channel, and they were stored as one opaque JSON column that
// nothing rendered. "21 conversation memories" is a number; this is the content.
type ConversationDetail struct {
	Channel, Thread, Repository string
	Goal, Purpose, Summary      string
	Topics, OpenLoops           []string
	Decisions, Questions        []string
	Knowledge                   []Knowledge
	Recalls                     int
	Updated                     time.Time
}

func (r *Reader) Conversation(ctx context.Context, channelID, thread string) (ConversationDetail, error) {
	var detail ConversationDetail
	if !r.live() {
		return detail, nil
	}
	if thread == "channel" {
		thread = ""
	}
	var state, updated string
	err := r.db.QueryRowContext(ctx, `
	  SELECT repository, state_json, recall_count, updated_at
	  FROM conversation_memories WHERE channel_id = ? AND thread_ts = ?`,
		channelID, thread).Scan(&detail.Repository, &state, &detail.Recalls, &updated)
	if err != nil {
		return detail, err
	}
	detail.Channel = r.channelName(ctx, channelID)
	detail.Thread = thread
	detail.Updated = parseStamp(updated)

	var decoded struct {
		Goal             string `json:"goal"`
		ChannelPurpose   string `json:"channel_purpose"`
		SituationSummary string `json:"situation_summary"`
		ActiveTopics     []string
		OpenLoops        []string
		Decisions        []string
		Unresolved       []string `json:"unresolved_questions"`
		Knowledge        []struct {
			Subject    string `json:"subject"`
			Kind       string `json:"kind"`
			Statement  string `json:"statement"`
			Status     string `json:"status"`
			Confidence int    `json:"confidence"`
			SourceRef  string `json:"source_ref"`
		} `json:"knowledge"`
	}
	if err := json.Unmarshal([]byte(state), &decoded); err != nil {
		return detail, nil
	}
	detail.Goal, detail.Purpose = decoded.Goal, decoded.ChannelPurpose
	detail.Summary = decoded.SituationSummary
	detail.Topics, detail.OpenLoops = decoded.ActiveTopics, decoded.OpenLoops
	detail.Decisions, detail.Questions = decoded.Decisions, decoded.Unresolved
	for _, item := range decoded.Knowledge {
		detail.Knowledge = append(detail.Knowledge, Knowledge{
			Subject: item.Subject, Kind: item.Kind, Statement: item.Statement,
			Status: item.Status, Confidence: item.Confidence, Source: item.SourceRef,
		})
	}
	return detail, nil
}

// EpisodesForChannel is the link back: from anything that names a channel to
// the work that happened in it.
func (r *Reader) EpisodesForChannel(ctx context.Context, channelID string, limit int) ([]Item, error) {
	return r.scanItems(ctx, episodeSelect+`
	  WHERE r.channel_id = ? ORDER BY e.created_at DESC LIMIT ?`, channelID, limit)
}

// EpisodeFilter narrows the episode list to one slice of the work.
//
// It exists because the Usage page breaks spend down by model, channel,
// repository and kind, and a breakdown nobody can open is a report rather than
// triage: it says which model costs the most and gives no route to a single
// turn of it. Every list on this dashboard is a way in.
type EpisodeFilter struct {
	Channel, ChannelName string
	Repository, Mode     string
	Provider, Model      string
	// Query is free text over the commitment title and the episode status —
	// the two lines a person remembers about work they saw go past. State
	// narrows to one lifecycle state; Offset pages through what matched.
	Query, State string
	Offset       int
}

func (f EpisodeFilter) Active() bool {
	return f.Channel != "" || f.Repository != "" || f.Mode != "" ||
		f.Provider != "" || f.Model != "" || f.Query != "" || f.State != ""
}

// Describe says what the reader is looking at, in the words of the dimension
// they came from. A filtered list that looks like the unfiltered one is how a
// reader concludes that work stopped happening.
func (f EpisodeFilter) Describe() string {
	parts := []string{}
	if f.Query != "" {
		parts = append(parts, "matching \""+f.Query+"\"")
	}
	if f.Channel != "" {
		where := f.ChannelName
		if where == "" {
			where = f.Channel
		}
		parts = append(parts, "in "+where)
	}
	for _, named := range []struct{ label, value string }{
		{"state", f.State},
		{"repository", f.Repository}, {"kind", f.Mode},
		{"provider", f.Provider}, {"model", f.Model},
	} {
		if named.value != "" {
			parts = append(parts, named.label+" "+named.value)
		}
	}
	return strings.Join(parts, " · ")
}

// where builds the predicate.
//
// Provider and model are matched with EXISTS against the manifests rather than
// by joining them, because an episode holds one manifest per attempt and a join
// would return the episode once per attempt that used that model.
func (f EpisodeFilter) where() (string, []any) {
	clauses, args := []string{}, []any{}
	for _, term := range []struct{ sql, value string }{
		{"r.channel_id = ?", f.Channel},
		{"r.repository = ?", f.Repository},
		{"r.mode = ?", f.Mode},
		{"e.lifecycle_state = ?", f.State},
		{`EXISTS (SELECT 1 FROM context_manifests AS m
		    WHERE m.episode_id = e.id AND m.provider = ?)`, f.Provider},
		{`EXISTS (SELECT 1 FROM context_manifests AS m
		    WHERE m.episode_id = e.id AND m.model = ?)`, f.Model},
	} {
		if term.value != "" {
			clauses = append(clauses, term.sql)
			args = append(args, term.value)
		}
	}
	if f.Query != "" {
		// The searched text is escaped so an operator typing "100%" searches
		// for a percent sign rather than turning it into a wildcard. LIKE is
		// enough here: titles and statuses are one line each, and the corpus
		// is hundreds of rows, not millions.
		like := "%" + strings.NewReplacer(
			`\`, `\\`, `%`, `\%`, `_`, `\_`,
		).Replace(f.Query) + "%"
		clauses = append(clauses,
			`(COALESCE(c.title,'') LIKE ? ESCAPE '\' OR COALESCE(e.status,'') LIKE ? ESCAPE '\')`)
		args = append(args, like, like)
	}
	if len(clauses) == 0 {
		return "", nil
	}
	return " WHERE " + strings.Join(clauses, " AND "), args
}

func (r *Reader) EpisodesMatching(
	ctx context.Context,
	filter EpisodeFilter,
	limit int,
) ([]Item, error) {
	where, args := filter.where()
	return r.scanItems(ctx, episodeSelect+where+
		` ORDER BY e.created_at DESC LIMIT ? OFFSET ?`,
		append(args, limit, filter.Offset)...)
}

// CountMatching reports its failure, unlike Count.
//
// Count has one return value, so a broken query comes back as 0 — which on this
// dashboard means "none" and not "could not ask". A filtered list is exactly
// where that lie would land: "0 episodes" over a filter that never ran reads as
// a model nothing was spent on.
//
// Its FROM carries the same joins as episodeSelect, because the free-text
// clause reaches the commitment title: a count taken over fewer tables than
// the list it captions is how "N match" and the rows below it disagree.
func (r *Reader) CountMatching(ctx context.Context, filter EpisodeFilter) (int, error) {
	if !r.live() {
		return 0, nil
	}
	where, args := filter.where()
	var count int
	err := r.db.QueryRowContext(ctx, `
	  SELECT COUNT(*) FROM work_episodes AS e
	  LEFT JOIN commitments AS c ON c.episode_id = e.id
	  LEFT JOIN agent_runs AS r ON r.id = e.agent_run_id`+where, args...).Scan(&count)
	return count, err
}

// EpisodeStates lists the lifecycle states that actually occur, for the state
// dropdown. The full constant set would offer states no episode has ever been
// in, and an option that can only produce an empty page is a control that
// looks live and is not.
func (r *Reader) EpisodeStates(ctx context.Context) ([]string, error) {
	return collect(ctx, r,
		`SELECT DISTINCT lifecycle_state FROM work_episodes ORDER BY 1`,
		func(rows *sql.Rows) (string, error) {
			var state string
			err := rows.Scan(&state)
			return state, err
		})
}

// Schedule is one recurring task the operator has confirmed.
//
// The Configuration page rendered "No schedules" over a live schedule for a
// day, because the handler passed a nil slice where a query belonged — the
// section was scaffolding wearing the costume of an empty state.
type Schedule struct {
	Title, Prompt, Cadence, Channel, Repository, CatchUp, LastOutcome string
	Enabled                                                           bool
	NextRun, LastRun                                                  time.Time
	Runs                                                              int
}

func (r *Reader) Schedules(ctx context.Context) ([]Schedule, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT s.title, s.prompt, s.recurrence, s.interval_seconds, s.local_time, s.timezone,
	         s.channel_id, s.repository, s.catch_up, s.enabled, COALESCE(s.next_run_at,''),
	         COALESCE(s.last_run_at,''), s.last_outcome,
	         (SELECT COUNT(*) FROM scheduled_task_runs r WHERE r.task_id = s.id)
	  FROM scheduled_tasks s
	  WHERE julianday(s.expires_at) > julianday('now')
	  ORDER BY s.enabled DESC, s.next_run_at IS NULL, s.next_run_at LIMIT 50`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []Schedule{}
	for rows.Next() {
		var item Schedule
		var recurrence, localTime, timezone, next, last string
		var interval int
		if err := rows.Scan(&item.Title, &item.Prompt, &recurrence, &interval, &localTime,
			&timezone, &item.Channel, &item.Repository, &item.CatchUp, &item.Enabled,
			&next, &last, &item.LastOutcome, &item.Runs); err != nil {
			return nil, err
		}
		item.Channel = r.channelName(ctx, item.Channel)
		item.NextRun = parseStamp(next)
		item.LastRun = parseStamp(last)
		item.Cadence = recurrence
		switch {
		case recurrence == "interval" && interval > 0:
			item.Cadence = "every " + (time.Duration(interval) * time.Second).String()
		case localTime != "":
			item.Cadence = recurrence + " at " + localTime + " " + timezone
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

// Preference and StandingRule mirror what the App Home lists, because how
// Responder is configured belongs on the Configuration page and lived only in
// Slack.
type Preference struct {
	Name, Value, Scope string
	Enabled            bool
	Expires            time.Time
}

func (r *Reader) Preferences(ctx context.Context) ([]Preference, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT name, value, scope_kind, scope_key, enabled, expires_at
	  FROM responder_preferences ORDER BY updated_at DESC LIMIT 50`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []Preference{}
	for rows.Next() {
		var item Preference
		var kind, key, expires string
		if err := rows.Scan(&item.Name, &item.Value, &kind, &key, &item.Enabled, &expires); err != nil {
			return nil, err
		}
		item.Scope = kind
		if kind == "channel" && key != "" {
			item.Scope = r.channelName(ctx, key)
		} else if key != "" {
			item.Scope = kind + " " + key
		}
		item.Expires = parseStamp(expires)
		items = append(items, item)
	}
	return items, rows.Err()
}

type StandingRule struct {
	Trigger, Action, Channel string
	Enabled                  bool
	Runs                     int
	Expires                  time.Time
}

func (r *Reader) StandingRules(ctx context.Context) ([]StandingRule, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT trigger_name, action_name, channel_id, enabled, trigger_count, expires_at
	  FROM standing_rules ORDER BY updated_at DESC LIMIT 50`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []StandingRule{}
	for rows.Next() {
		var item StandingRule
		var channel, expires string
		if err := rows.Scan(&item.Trigger, &item.Action, &channel, &item.Enabled,
			&item.Runs, &expires); err != nil {
			return nil, err
		}
		item.Channel = r.channelName(ctx, channel)
		item.Expires = parseStamp(expires)
		items = append(items, item)
	}
	return items, rows.Err()
}
