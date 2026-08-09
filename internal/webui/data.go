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
	"time"
)

// Reader is the dashboard's own read-only view of the database.
//
// A separate connection rather than the service's store, for two reasons. It
// cannot migrate, write or lock anything the running service depends on — a
// dashboard should never be able to hurt the thing it observes. And the queries
// here are presentation shapes that would otherwise grow internal/store, which
// is already at its line budget.
type Reader struct{ db *sql.DB }

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
// reader nothing. Cached for the life of the request set; the membership table
// is small and changes rarely.
func (r *Reader) channelName(ctx context.Context, id string) string {
	if id == "" || !r.live() {
		return ""
	}
	var name string
	if err := r.db.QueryRowContext(ctx,
		`SELECT channel_name FROM slack_channel_memberships WHERE channel_id = ?`, id).
		Scan(&name); err != nil || name == "" {
		return "#" + id
	}
	return "#" + name
}

// cleanTitle strips the source message's own markup. A title is usually the
// Slack message that started the work, so an alert arrives as the whole
// "<https://grafana…|[VA1 FIRING:1] …> *FIRING*" and fills a row with a URL.
func cleanTitle(title string) string {
	cleaned := slackLink.ReplaceAllString(strings.TrimSpace(title), "$1")
	cleaned = strings.TrimSpace(bareLink.ReplaceAllString(cleaned, ""))
	cleaned = strings.NewReplacer("*", "", "_", "", "`", "").Replace(cleaned)
	cleaned = strings.Join(strings.Fields(cleaned), " ")
	if cleaned == "" {
		return "Untitled work"
	}
	return cleaned
}

var (
	slackLink = regexp.MustCompile(`<https?://[^|>]+\|([^>]*)>`)
	bareLink  = regexp.MustCompile(`<?https?://[^\s|>]+>?`)
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
	Kind   string
	Actor  string
	Detail string
	At     time.Time
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
	for rows.Next() {
		var event Event
		var payload, at string
		if err := rows.Scan(&event.Kind, &event.Actor, &payload, &at); err != nil {
			return nil, err
		}
		event.At = parseStamp(at)
		event.Detail = summarizePayload(payload)
		events = append(events, event)
	}
	return events, rows.Err()
}

// summarizePayload picks the human-readable field out of an event payload.
// Rendering raw JSON would be the same mistake the Slack surface made with raw
// Grafana URLs: technically complete, unreadable in a list.
func summarizePayload(payload string) string {
	var decoded map[string]any
	if err := json.Unmarshal([]byte(payload), &decoded); err != nil {
		return ""
	}
	for _, key := range []string{"summary", "detail", "status", "phase", "reason", "message", "claim"} {
		if value, ok := decoded[key].(string); ok && strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

type EvidenceRow struct {
	Claim       string
	Observation string
	Source      string
	Confidence  string
}

func (r *Reader) Evidence(ctx context.Context, episodeID string) ([]EvidenceRow, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT COALESCE(claim,''), COALESCE(observation,''),
	         COALESCE(source_name,''), COALESCE(confidence,'')
	  FROM evidence WHERE episode_id = ? LIMIT 100`, episodeID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []EvidenceRow{}
	for rows.Next() {
		var item EvidenceRow
		if err := rows.Scan(&item.Claim, &item.Observation, &item.Source, &item.Confidence); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

type ManifestRow struct {
	Provider      string
	Model         string
	Effort        string
	PromptVersion string
}

func (r *Reader) Manifest(ctx context.Context, episodeID string) ManifestRow {
	var row ManifestRow
	if !r.live() {
		return row
	}
	_ = r.db.QueryRowContext(ctx, `
	  SELECT COALESCE(provider,''), COALESCE(model,''),
	         COALESCE(reasoning_effort,''), COALESCE(prompt_version,'')
	  FROM context_manifests WHERE episode_id = ?
	  ORDER BY version DESC LIMIT 1`, episodeID).
		Scan(&row.Provider, &row.Model, &row.Effort, &row.PromptVersion)
	return row
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
	ID      string
	Text    string
	Class   string
	Created time.Time
	Expires time.Time
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
		if err := rows.Scan(&item.ID, &item.Text, &item.Class, &created, &expires); err != nil {
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
	rows, err := r.db.QueryContext(ctx, `
	  SELECT channel_id, COALESCE(state_json,'{}'), updated_at
	  FROM channel_memories ORDER BY updated_at DESC LIMIT 25`)
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
		item.Channel = "#" + item.Channel
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
	Subject, Predicate, Value, Scope string
	Recalls                          int
	Expires, LastRecalled            time.Time
}

func (r *Reader) MemoryEntries(ctx context.Context) ([]MemoryEntry, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT subject_key, predicate, value_json, scope_kind, scope_key,
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
		if err := rows.Scan(&item.Subject, &item.Predicate, &item.Value, &item.Scope,
			&scopeKey, &item.Recalls, &expires, &recalled); err != nil {
			return nil, err
		}
		if scopeKey != "" {
			item.Scope += " " + scopeKey
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
		item.Scope = kind + " " + key
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
	Kind, Reason, Status string
	Created              time.Time
}

func (r *Reader) MemoryReview(ctx context.Context) ([]ReviewItem, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT kind, reason, status, created_at FROM memory_review_items
	  WHERE status = 'pending' ORDER BY created_at DESC LIMIT 50`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []ReviewItem{}
	for rows.Next() {
		var item ReviewItem
		var created string
		if err := rows.Scan(&item.Kind, &item.Reason, &item.Status, &created); err != nil {
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
	Category, Sentiment, Summary, Status, Channel string
	EpisodeID                                     string
	Created                                       time.Time
}

func (r *Reader) Feedback(ctx context.Context) ([]Feedback, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT category, sentiment, summary, COALESCE(status,''), channel_id,
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
		if err := rows.Scan(&item.Category, &item.Sentiment, &item.Summary,
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
type FailureRun struct {
	RunID                    string
	EpisodeID, Channel, Mode string
	Attempts                 int
	Updated                  time.Time
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
	rows, err := r.db.QueryContext(ctx, `
	  SELECT a.id, COALESCE(e.id,''), COALESCE(a.channel_id,''), COALESCE(a.mode,''),
	         COALESCE(a.failure_count,0), a.updated_at
	  FROM agent_runs AS a
	  LEFT JOIN work_episodes AS e ON e.agent_run_id = a.id
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
		var channel, updated string
		if err := rows.Scan(&item.RunID, &item.EpisodeID, &channel, &item.Mode,
			&item.Attempts, &updated); err != nil {
			return nil, err
		}
		item.Channel = r.channelName(ctx, channel)
		item.Updated = parseStamp(updated)
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
