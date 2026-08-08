package webui

import (
	"context"
	"database/sql"
	"encoding/json"
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
		groups = append(groups, group)
	}
	return groups, rows.Err()
}

type Correction struct {
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
	  SELECT correction, correction_class, created_at, expires_at
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
		if err := rows.Scan(&item.Text, &item.Class, &created, &expires); err != nil {
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
		item.Channel = "#" + item.Channel
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
