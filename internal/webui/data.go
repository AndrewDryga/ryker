package webui

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/decision"
)

// Reader is the dashboard's own read-only view of the database.
//
// A separate connection rather than the service's store, for two reasons. It
// cannot migrate, write or lock anything the running service depends on — a
// dashboard should never be able to hurt the thing it observes. And the queries
// here are presentation shapes that would otherwise grow internal/store, which
// is already at its line budget.
type Reader struct {
	db         *sql.DB
	coop       *sql.DB
	channels   sync.Map
	identities sync.Map
}

// OpenCoopSessions attaches Coop's own session store, read-only.
//
// A second database rather than a join: workspaces belong to Coop, which
// records what it is holding and why, and Responder only keeps the references
// it needs. Reading the file directly keeps the dashboard's bargain — local,
// read-only, nothing fetched at render time — where asking Coop over its
// control socket would make the page unrenderable whenever Coop is restarting.
//
// A missing or unreadable file is not an error. It means this deployment has
// no Coop state to show, and the page says so rather than failing.
func (r *Reader) OpenCoopSessions(path string) {
	// Checked before opening, because sql.Open is lazy: it would hand back a
	// healthy-looking handle for a file that is not there, the page would
	// report Coop as attached, and the first query would fail. "Could not
	// load" for a deployment that simply has no Coop is the wrong answer to a
	// question nobody asked.
	if info, err := os.Stat(path); err != nil || info.IsDir() {
		return
	}
	db, err := sql.Open("sqlite", "file:"+path+"?mode=ro&_pragma=busy_timeout(2000)")
	if err != nil {
		return
	}
	db.SetMaxOpenConns(1)
	r.coop = db
}

func (r *Reader) SetSlackIdentities(labels map[string]string) {
	if r == nil {
		return
	}
	for id, label := range labels {
		if id != "" && strings.TrimSpace(label) != "" {
			r.identities.Store(id, strings.TrimSpace(label))
		}
	}
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
	if r != nil && r.coop != nil {
		r.coop.Close()
	}
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

	// Which model answered. Recorded per attempt on the context manifest and
	// carried on the row because "who did this work" is a scanning question:
	// it belonged on every list and appeared only in a table near the bottom
	// of one detail page, behind a conditional that was false for every row in
	// the database because nothing had ever populated the column.
	Provider string
	Model    string
	Effort   string

	// Answer is what the episode concluded, in the model's own words. A list
	// that shows only what came in makes every alert-driven row look the same
	// as the last one and says nothing about what Responder did with it.
	Answer string
	// Replied records whether any of this reached Slack. Almost nothing does —
	// 38 of 625 episodes on the busiest deployment posted a message — so the
	// rare row that spoke to somebody is worth marking, and the silent
	// majority is the normal case rather than a fault.
	Replied bool
	// Attempts above one means the work was retried, which is the cheapest
	// signal that something went wrong on the way to an answer.
	Attempts int
	// Run is the provider run id an alert-driven title carries as a suffix. It
	// is an identifier, not part of the sentence, and leaving it on the title
	// made two runs of the same alert render as the same row.
	Run string
}

// Answered names the model in one token for a list. Effort is included because
// on a ladder of claude:opus/max and claude:opus/high the effort is the whole
// difference between the two rungs.
func (i Item) Answered() string {
	if i.Model == "" {
		return ""
	}
	name := i.Model
	if i.Effort != "" {
		name += "/" + i.Effort
	}
	return name
}

// The manifest columns come from correlated subqueries rather than a join.
// An episode whose context was extended froze several manifests, and joining
// them would repeat the episode once per manifest — the same fan-out that
// turned 351 manifests into 953 rows on the Usage page before it keyed on the
// attempt. The latest manifest is the one that answered.
//
// The completion message is read out of the event with json_extract for the
// same reason: an episode has many events, and joining work_episode_events to
// reach the one closing statement would repeat the episode once per event it
// ever recorded. The subquery takes the latest completion and nothing else.
const episodeSelect = `
  SELECT e.id, COALESCE(c.title, ''), e.lifecycle_state, COALESCE(r.mode, ''),
         COALESCE(r.channel_id, ''), COALESCE(e.status, ''), COALESCE(e.next_action, ''),
         e.created_at, e.updated_at,
         COALESCE((SELECT m.provider FROM context_manifests m
                   WHERE m.episode_id = e.id ORDER BY m.version DESC LIMIT 1), ''),
         COALESCE((SELECT m.model FROM context_manifests m
                   WHERE m.episode_id = e.id ORDER BY m.version DESC LIMIT 1), ''),
         COALESCE((SELECT m.reasoning_effort FROM context_manifests m
                   WHERE m.episode_id = e.id ORDER BY m.version DESC LIMIT 1), ''),
         COALESCE((SELECT json_extract(CAST(v.payload_json AS TEXT), '$.completion.message')
                   FROM work_episode_events v
                   WHERE v.episode_id = e.id AND v.kind = 'completion_submitted'
                   ORDER BY v.created_at DESC LIMIT 1), ''),
         EXISTS(SELECT 1 FROM slack_deliveries d
                WHERE d.episode_id = e.id AND d.operation = 'post' AND d.state = 'sent'),
         (SELECT COUNT(*) FROM episode_attempts a WHERE a.episode_id = e.id),
         COALESCE(CAST(r.result_json AS TEXT), ''), COALESCE(r.last_error, '')
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
		var created, updated, result, lastError string
		if err := rows.Scan(&item.ID, &item.Title, &item.State, &item.Kind,
			&item.Channel, &item.Status, &item.Next, &created, &updated,
			&item.Provider, &item.Model, &item.Effort,
			&item.Answer, &item.Replied, &item.Attempts, &result, &lastError); err != nil {
			return nil, err
		}
		item.Created, item.Updated = parseStamp(created), parseStamp(updated)
		if item.Title == "" {
			item.Title = "Untitled work"
		}
		item.Channel = r.channelName(ctx, item.Channel)
		item.Title = cleanTitle(item.Title)
		item.Title, item.Run = splitRunTail(item.Title)
		item.Answer = answerLine(item.Answer, result, lastError, item.Status)
		item.Answer = truncate(strings.Join(strings.Fields(item.Answer), " "), 400)
		items = append(items, item)
	}
	return items, rows.Err()
}

// answerLine is what the row says the episode concluded.
//
// The completion event is the best source and covers a bit over half the
// episodes. The rest either never completed or answered without one, and for
// those the ranking is: what the model decided and why, then the error that
// stopped it, then the stored status when it is not one of the host's canned
// labels. A row with none of these shows nothing rather than a placeholder —
// "no answer recorded" in five hundred rows is noise, and the title is still
// there.
// splitRunTail lifts the provider run id off an alert-driven title.
//
// Two things made these titles unreadable in a list. The id is an identifier
// rather than part of the sentence, and it sat past the point where the row
// truncated, so two runs of the same alert rendered as the same row. And the
// title is stored already shortened, so what often arrives is "… · Run..." —
// a tail with no id left in it, which says nothing and still costs the width.
//
// The title's own trailing ellipsis stays. Removing it looked tidier on the
// titles that happened to end on a word and produced "15m avg I/" on the ones
// that did not: those dots are the only thing saying the sentence continues.
func splitRunTail(title string) (string, string) {
	if base, run, found := strings.Cut(title, " · Run "); found &&
		strings.HasPrefix(run, "run-") && !strings.Contains(run, " ") {
		return base, run
	}
	// The id was truncated away, leaving the label and whatever dots survived.
	for _, tail := range []string{" · Run...", " · Run…", " · Run..", " · Run."} {
		if base, found := strings.CutSuffix(title, tail); found {
			return base, ""
		}
	}
	return title, ""
}

func answerLine(completion, result, lastError, status string) string {
	if text := strings.TrimSpace(completion); text != "" {
		return text
	}
	if parsed, err := decision.ParseWatchDecision(strings.TrimSpace(result), time.Now().UTC()); err == nil {
		if text := strings.TrimSpace(parsed.Message); text != "" {
			return text
		}
		// An ignored message has no public words by definition; the reason it
		// was ignored is the only account of the turn there will ever be.
		if text := strings.TrimSpace(parsed.Reason); text != "" {
			return text
		}
	}
	if text := strings.TrimSpace(lastError); text != "" {
		return text
	}
	if text := strings.TrimSpace(status); text != "" && !cannedEpisodeStatus(text) {
		return text
	}
	return ""
}

// cannedEpisodeStatus recognizes the host's fixed status labels, which restate
// the lifecycle state the row already shows as a pill.
func cannedEpisodeStatus(status string) bool {
	return map[string]bool{
		"Accepted": true, "Completed": true, "Planning the work": true,
		"Investigating": true, "Preparing the result": true,
		"Needs operator attention": true, "Resuming work": true,
	}[status]
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
	// A D-prefixed id is a direct message: there is no channel name to find,
	// and "#D0TENANTX02" reads as a channel that failed to resolve rather than
	// as what it is. Other unknown ids stay bare — a "#" would dress a failed
	// lookup as a resolved one.
	if strings.HasPrefix(id, "D") {
		return "direct message"
	}
	return id
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
var slackUserID = regexp.MustCompile(`\bU[A-Z0-9]{8,}\b`)
var slackMention = regexp.MustCompile(`<@(U[A-Z0-9]{8,})>`)

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

func (r *Reader) userName(id string) string {
	if r == nil || id == "" {
		return id
	}
	if value, ok := r.identities.Load(id); ok {
		if name, _ := value.(string); name != "" {
			return name
		}
	}
	return id
}

func (r *Reader) resolveSlackText(ctx context.Context, text string) string {
	text = r.resolveChannels(ctx, text)
	text = slackMention.ReplaceAllStringFunc(text, func(mention string) string {
		matches := slackMention.FindStringSubmatch(mention)
		if len(matches) != 2 {
			return mention
		}
		name := r.userName(matches[1])
		if name == matches[1] {
			return mention
		}
		return "@" + name
	})
	return slackUserID.ReplaceAllStringFunc(text, func(id string) string {
		name := r.userName(id)
		if name == id {
			return id
		}
		return name
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
	// countFailedToday is the overview's failure number, and it is deliberately
	// not countFailedRuns.
	//
	// The hero sets four counts side by side and three of them are the state
	// right now: nothing in flight, one waiting, nothing held. The fourth was
	// every failure ever recorded, which on a deployment two weeks old was 120
	// against a 0, a 1 and a 0 — the loudest number on the page, in red, every
	// day, saying nothing about today. A number that cannot go down is not a
	// status. The whole history is still one click away on Failures, where it
	// is the subject rather than the alarm.
	countFailedToday = `SELECT COUNT(*) FROM agent_runs
	  WHERE terminal_state = 'failed'
	    AND updated_at > strftime('%Y-%m-%dT%H:%M:%f', 'now', '-1 day')`
	countInFlight = `SELECT COUNT(*) FROM work_episodes
	  WHERE lifecycle_state IN ('accepted','acknowledged','planning','working','retrying','verifying')`
	countRetained     = `SELECT COUNT(*) FROM coop_cleanup WHERE state = 'blocked'`
	countCleanupDone  = `SELECT COUNT(*) FROM coop_cleanup WHERE state = 'done'`
	countEpisodes     = `SELECT COUNT(*) FROM work_episodes`
	countTerminalRuns = `SELECT COUNT(*) FROM agent_runs WHERE terminal_state <> ''`
	countCorrections  = `SELECT COUNT(*) FROM fixture_candidates WHERE correction_class = ?`
	countAudited      = `SELECT COUNT(*) FROM audit_events`
	countAuditKind    = `SELECT COUNT(*) FROM audit_events WHERE kind = ?`
	// Counted over the whole table rather than the fifty rows the page lists,
	// because the point of the pair is the ratio and a ratio taken from a page
	// of the newest items is a ratio of whatever happened this week.
	countFeedbackSentiment = `SELECT COUNT(*) FROM feedback_items WHERE sentiment = ?`
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
	Payload string
	At      time.Time
	Elapsed string
	Attempt int
	Repeats int
	Span    string
	// Occurrences preserves every durable timestamp when consecutive duplicate
	// rows are folded for readability. A folded row is presentation, not data
	// loss: operators can still inspect exactly when each repeat happened.
	Occurrences []time.Time
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
	  ORDER BY sequence ASC`, episodeID)
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
		event.Occurrences = []time.Time{event.At}
		event.Detail = summarizePayload(event.Kind, payload)
		event.Payload = prettyJSON(payload)
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

func prettyJSON(value string) string {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return ""
	}
	var decoded any
	if json.Unmarshal([]byte(trimmed), &decoded) != nil {
		return trimmed
	}
	formatted, err := json.MarshalIndent(decoded, "", "  ")
	if err != nil {
		return trimmed
	}
	return string(formatted)
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
			folded[last].Occurrences = append(folded[last].Occurrences, event.Occurrences...)
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
	  ORDER BY created_at`,
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
	Pct    int
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
	// Pct is each cause's weight against the biggest one, so the table can
	// draw the comparison the eye would otherwise do over raw counts.
	if len(groups) > 0 && groups[0].Count > 0 {
		for index := range groups {
			groups[index].Pct = groups[index].Count * 100 / groups[0].Count
		}
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
	  SELECT id, episode_id, correction, correction_class, created_at, expires_at
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
	ID         string
	Channel    string
	Mode       string
	Repository string
	Member     bool
	Episodes   int
}

func (r *Reader) Channels(ctx context.Context) ([]ChannelConfigRow, error) {
	return r.KnownChannels(ctx)
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
	// Rewrites is how many times this entry's value has been replaced, and
	// LastRewrite why the most recent replacement happened.
	//
	// memory_supersessions had two writers, a pruner, a purpose-built index and
	// no reader at all, so the record that a remembered thing had changed under
	// an operator existed and could not be seen. It stores hashes rather than
	// values, so it can never show what the memory used to say — what it can
	// answer is "this has been rewritten three times, most recently by a
	// duplicate merge", which is the difference between a settled memory and a
	// contested one.
	Rewrites    int
	LastRewrite string
}

func (r *Reader) MemoryEntries(ctx context.Context) ([]MemoryEntry, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT m.id, m.subject_key, m.predicate, m.value_json, m.scope_kind, m.scope_key,
	         m.recall_count, m.expires_at, COALESCE(m.last_recalled_at,''),
	         (SELECT COUNT(*) FROM memory_supersessions s WHERE s.entry_id = m.id),
	         COALESCE((SELECT s.reason FROM memory_supersessions s
	                   WHERE s.entry_id = m.id
	                   ORDER BY s.created_at DESC LIMIT 1), '')
	  FROM memory_entries m ORDER BY m.updated_at DESC LIMIT 100`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []MemoryEntry{}
	for rows.Next() {
		var item MemoryEntry
		var scopeKey, expires, recalled string
		if err := rows.Scan(&item.ID, &item.Subject, &item.Predicate, &item.Value, &item.Scope,
			&scopeKey, &item.Recalls, &expires, &recalled,
			&item.Rewrites, &item.LastRewrite); err != nil {
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

// StateCount is one lifecycle state and how many episodes are in it, for the
// filter chips: a state the operator can only click into an empty page is a
// control that looks live and is not, so the chip carries its own count.
type StateCount struct {
	State string
	Count int
}

func (r *Reader) EpisodeStateCounts(ctx context.Context) ([]StateCount, error) {
	return collect(ctx, r,
		`SELECT lifecycle_state, COUNT(*) FROM work_episodes GROUP BY 1 ORDER BY 1`,
		func(rows *sql.Rows) (StateCount, error) {
			var item StateCount
			err := rows.Scan(&item.State, &item.Count)
			return item, err
		})
}

// ActivityDay is one day of episode volume for the overview sparkline: how
// much arrived, and how much of it ended failed. Days with no episodes are
// filled in by the caller so a quiet day renders as a gap in the ground, not
// a missing bar that shifts every other day sideways.
type ActivityDay struct {
	Day           time.Time
	Total, Failed int
}

func (r *Reader) EpisodeActivity(ctx context.Context, now time.Time, days int) ([]ActivityDay, error) {
	since := now.UTC().AddDate(0, 0, -(days - 1)).Truncate(24 * time.Hour)
	counted, err := collect(ctx, r, `
	  SELECT date(created_at), COUNT(*),
	         SUM(CASE WHEN lifecycle_state = 'failed' THEN 1 ELSE 0 END)
	  FROM work_episodes WHERE created_at >= ?
	  GROUP BY date(created_at) ORDER BY 1`,
		func(rows *sql.Rows) (ActivityDay, error) {
			var item ActivityDay
			var day string
			err := rows.Scan(&day, &item.Total, &item.Failed)
			item.Day, _ = time.Parse("2006-01-02", day)
			return item, err
		}, since.Format(core.TimestampFormat))
	if err != nil {
		return nil, err
	}
	byDay := make(map[string]ActivityDay, len(counted))
	for _, day := range counted {
		byDay[day.Day.Format("2006-01-02")] = day
	}
	filled := make([]ActivityDay, 0, days)
	for index := 0; index < days; index++ {
		day := since.AddDate(0, 0, index)
		item := byDay[day.Format("2006-01-02")]
		item.Day = day
		filled = append(filled, item)
	}
	return filled, nil
}

// Schedule is one recurring task the operator has confirmed.
//
// The Configuration page rendered "No schedules" over a live schedule for a
// day, because the handler passed a nil slice where a query belonged — the
// section was scaffolding wearing the costume of an empty state.
type Schedule struct {
	ID                                                                string
	Title, Prompt, Cadence, Channel, Repository, CatchUp, LastOutcome string
	// Recurrence is the stored word and Cadence the phrasing built from it.
	// Both are kept because "daily" is the rule and "daily at 09:00
	// America/Mexico_City" is the appointment, and a page about one schedule
	// needs to say which timezone that clock is in.
	Timezone, Recurrence string
	Enabled              bool
	NextRun, LastRun     time.Time
	StartAt, ExpiresAt   time.Time
	Runs                 int
}

const scheduleSelect = `
  SELECT s.id, s.title, s.prompt, s.recurrence, s.interval_seconds, s.local_time, s.timezone,
         s.channel_id, s.repository, s.catch_up, s.enabled, COALESCE(s.next_run_at,''),
         COALESCE(s.last_run_at,''), s.last_outcome, s.start_at, s.expires_at,
         (SELECT COUNT(*) FROM scheduled_task_runs r WHERE r.task_id = s.id)
  FROM scheduled_tasks s`

// scanSchedule shapes one row the same way for the list and for the schedule's
// own page. Written once because a schedule that reads "daily at 09:00
// America/Mexico_City" in the list and "daily" on the page it links to is two
// answers to the same question.
func (r *Reader) scanSchedule(ctx context.Context, rows *sql.Rows) (Schedule, error) {
	var item Schedule
	var localTime, next, last, start, expires string
	var interval int
	if err := rows.Scan(&item.ID, &item.Title, &item.Prompt, &item.Recurrence, &interval,
		&localTime, &item.Timezone, &item.Channel, &item.Repository, &item.CatchUp,
		&item.Enabled, &next, &last, &item.LastOutcome, &start, &expires, &item.Runs); err != nil {
		return Schedule{}, err
	}
	item.Channel = r.channelName(ctx, item.Channel)
	item.NextRun, item.LastRun = parseStamp(next), parseStamp(last)
	item.StartAt, item.ExpiresAt = parseStamp(start), parseStamp(expires)
	item.Cadence = item.Recurrence
	switch {
	case item.Recurrence == "interval" && interval > 0:
		item.Cadence = "every " + (time.Duration(interval) * time.Second).String()
	case localTime != "":
		item.Cadence = item.Recurrence + " at " + localTime + " " + item.Timezone
	}
	return item, nil
}

func (r *Reader) Schedules(ctx context.Context) ([]Schedule, error) {
	return collect(ctx, r, scheduleSelect+`
	  WHERE julianday(s.expires_at) > julianday('now')
	  ORDER BY s.enabled DESC, s.next_run_at IS NULL, s.next_run_at LIMIT 50`,
		func(rows *sql.Rows) (Schedule, error) { return r.scanSchedule(ctx, rows) })
}

// Schedule is one schedule by id, including ones that have expired.
//
// The list filters those out because an expired schedule will not fire again
// and does not belong in "what is coming up". A link to one still has to
// resolve: an execution that ran last week is a real record, and following it
// to a page that says the schedule never existed would be a lie about history.
func (r *Reader) Schedule(ctx context.Context, id string) (Schedule, bool, error) {
	if !r.live() || id == "" {
		return Schedule{}, false, nil
	}
	items, err := collect(ctx, r, scheduleSelect+` WHERE s.id = ? LIMIT 1`,
		func(rows *sql.Rows) (Schedule, error) { return r.scanSchedule(ctx, rows) }, id)
	if err != nil || len(items) == 0 {
		return Schedule{}, false, err
	}
	return items[0], true, nil
}

// ScheduleRun is one firing: when it was due, what became of it, and the
// episode it produced.
type ScheduleRun struct {
	ScheduledFor time.Time
	Started      time.Time
	Completed    time.Time
	Outcome      string
	EpisodeID    string
	Error        string
}

// Took is how long the firing ran. A skipped run never started, so it has no
// duration rather than a zero one.
func (s ScheduleRun) Took() string { return traceDuration(s.Started, s.Completed) }

// Reads names the outcome in words. The stored value is one token, and
// "skipped_overlap" in a list of otherwise plain English reads as a leaked
// column value.
func (s ScheduleRun) Reads() string {
	switch s.Outcome {
	case "skipped_missed":
		return "skipped, the window passed"
	case "skipped_overlap":
		return "skipped, still running"
	case "skipped_unauthorized":
		return "skipped, not authorized"
	}
	return strings.ReplaceAll(s.Outcome, "_", " ")
}

// ScheduleRuns lists a schedule's executions, newest first.
func (r *Reader) ScheduleRuns(ctx context.Context, id string, limit int) ([]ScheduleRun, error) {
	return collect(ctx, r, `
	  SELECT scheduled_for, COALESCE(started_at,''), COALESCE(completed_at,''),
	         outcome, episode_id, last_error
	  FROM scheduled_task_runs WHERE task_id = ?
	  ORDER BY scheduled_for DESC LIMIT ?`,
		func(rows *sql.Rows) (ScheduleRun, error) {
			var item ScheduleRun
			var scheduled, started, completed string
			err := rows.Scan(&scheduled, &started, &completed,
				&item.Outcome, &item.EpisodeID, &item.Error)
			item.ScheduledFor = parseStamp(scheduled)
			item.Started, item.Completed = parseStamp(started), parseStamp(completed)
			return item, err
		}, id, limit)
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

// StandingRule carries what the rule cost and what it produced, because a fire
// count on its own cannot say whether a rule is worth keeping. Runs is every
// fire ever; Acted and Quiet are the fires whose outcome was recorded, and they
// do not add up to Runs on any rule that predates migration 53.
type StandingRule struct {
	Trigger, Action, Channel string
	Enabled                  bool
	Runs, Acted, Quiet       int
	LastActed                time.Time
	Expires                  time.Time
}

// Recorded is the denominator the page may honestly divide by.
func (s StandingRule) Recorded() int { return s.Acted + s.Quiet }

// Idle reports a rule that has fired and, so far as anything was recorded,
// produced nothing at all. This is the row worth an operator's attention: it is
// costing a model turn per matching message and returning silence.
func (s StandingRule) Idle() bool { return s.Recorded() > 0 && s.Acted == 0 }

func (r *Reader) StandingRules(ctx context.Context) ([]StandingRule, error) {
	if !r.live() {
		return nil, nil
	}
	// Recency comes from the runs rather than a stored column, so an empty value
	// means "not inside the retained window" — see standingRuleSelect in
	// behaviorstore, which reads it the same way for Slack.
	rows, err := r.db.QueryContext(ctx, `
	  SELECT trigger_name, action_name, channel_id, enabled, trigger_count,
	         acted_count, quiet_count,
	         COALESCE((SELECT max(run.created_at) FROM standing_rule_runs run
	                   WHERE run.rule_id = standing_rules.id
	                     AND run.outcome NOT IN ('ignore', 'shadowed')), ''),
	         expires_at
	  FROM standing_rules ORDER BY updated_at DESC LIMIT 50`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []StandingRule{}
	for rows.Next() {
		var item StandingRule
		var channel, acted, expires string
		if err := rows.Scan(&item.Trigger, &item.Action, &channel, &item.Enabled,
			&item.Runs, &item.Acted, &item.Quiet, &acted, &expires); err != nil {
			return nil, err
		}
		item.Channel = r.channelName(ctx, channel)
		item.LastActed = parseStamp(acted)
		item.Expires = parseStamp(expires)
		items = append(items, item)
	}
	return items, rows.Err()
}

// ChannelSetting is one participation control with the reason it reads the way
// it does. The effective value alone is not enough to act on: "proactive is
// off" and "proactive is off because the workspace default says so and this
// channel has no opinion" lead to different edits.
type ChannelSetting struct {
	Name, Effective, Source string
	Channel, Global, Config string
	On                      bool
}

// ChannelRoll is one channel's whole history at a glance: how much work has
// happened there, how it turned out, and whether anything is live right now.
//
// The episodes list answers "what happened" and could answer "where" only by
// reading the channel column of six hundred rows. Work is not evenly spread —
// three channels hold most of it — so the shape of the fleet is a fact the
// list buried.
type ChannelRoll struct {
	ID, Name                string
	Repository              string
	Participation           string
	Total                   int
	Done, Failed, Other     int
	InFlight, NeedsDecision int
	Last                    time.Time
	// Segment widths for the outcome bar, in units of 100 and summing to 100
	// exactly. Computed here because a template cannot do arithmetic and the
	// stylesheet cannot carry data.
	DoneW, FailedW, OtherW int
	FailedX, OtherX        int
	// Direct marks a one-to-one conversation. It has no channel name and no
	// repository binding, so the card labels itself by what it is and puts the
	// conversation id where a repository would go.
	Direct bool
	// counterpart is the person on the other side of a direct message, used
	// only to name the card.
	counterpart string
}

// ChannelRolls groups every recorded episode by the channel it happened in.
//
// Direct messages and channels Responder has since left are kept: the work is
// on record and a page that silently drops it under-reports what ran. Rows
// with no channel at all — webhook-only work — are excluded, because there is
// no channel page to send them to.
func (r *Reader) ChannelRolls(ctx context.Context) ([]ChannelRoll, error) {
	rolls, err := collect(ctx, r, `
	  SELECT e.channel_id, COUNT(*),
	         SUM(e.lifecycle_state = 'completed'),
	         SUM(e.lifecycle_state IN ('failed','dead')),
	         SUM(e.lifecycle_state IN ('accepted','acknowledged','planning','working','retrying','verifying')),
	         SUM(e.lifecycle_state IN ('blocked','waiting_operator','waiting_approval')),
	         MAX(e.updated_at),
	         COALESCE(c.repository,''), COALESCE(c.participation,''),
	         COALESCE((SELECT s.user_id FROM slack_inputs AS s
	                   WHERE s.channel_id = e.channel_id AND s.user_id <> ''
	                   ORDER BY s.received_at DESC LIMIT 1), '')
	  FROM work_episodes AS e
	  LEFT JOIN channel_configurations AS c ON c.channel_id = e.channel_id
	  WHERE e.channel_id <> ''
	  GROUP BY e.channel_id
	  ORDER BY MAX(e.updated_at) DESC`, func(rows *sql.Rows) (ChannelRoll, error) {
		var item ChannelRoll
		var last string
		err := rows.Scan(&item.ID, &item.Total, &item.Done, &item.Failed,
			&item.InFlight, &item.NeedsDecision, &last, &item.Repository,
			&item.Participation, &item.counterpart)
		item.Last = parseStamp(last)
		return item, err
	})
	if err != nil {
		return nil, err
	}
	for index := range rolls {
		roll := &rolls[index]
		roll.Direct = strings.HasPrefix(roll.ID, "D")
		roll.Name = r.rollName(ctx, *roll)
		roll.Other = max(roll.Total-roll.Done-roll.Failed, 0)
		roll.DoneW, roll.FailedW, roll.OtherW = outcomeWidths(roll.Done, roll.Failed, roll.Other)
		roll.FailedX = roll.DoneW
		roll.OtherX = roll.DoneW + roll.FailedW
	}
	return rolls, nil
}

// rollName labels a card in a grid, where every other label is a channel name.
// A direct message has no channel name, so it says what it is and names the
// person when their name is known. The conversation id is not in the title:
// two unresolved DMs would then be two cards titled with a raw Slack id, which
// is neither readable nor a name. The id goes in the card's footer, where the
// repository sits for a channel — it disambiguates without shouting.
func (r *Reader) rollName(ctx context.Context, roll ChannelRoll) string {
	if !strings.HasPrefix(roll.ID, "D") {
		return r.channelName(ctx, roll.ID)
	}
	if name := r.userName(roll.counterpart); name != "" && name != roll.counterpart {
		return "direct message with " + strings.TrimPrefix(name, "@")
	}
	return "direct message"
}

// outcomeWidths splits a bar of 100 units across three counts without letting
// rounding lose or invent a unit: the remainder goes to whichever share is
// largest, so the segments always tile the bar exactly. A non-zero count keeps
// at least one unit, because a real outcome must not round away to nothing.
func outcomeWidths(done, failed, other int) (int, int, int) {
	total := done + failed + other
	if total == 0 {
		return 0, 0, 0
	}
	widths := []int{percent(done, total), percent(failed, total), percent(other, total)}
	for index, count := range []int{done, failed, other} {
		if count > 0 && widths[index] == 0 {
			widths[index] = 1
		}
	}
	sum := widths[0] + widths[1] + widths[2]
	largest := 0
	for index, width := range widths {
		if width > widths[largest] {
			largest = index
		}
	}
	widths[largest] += 100 - sum
	if widths[largest] < 0 {
		widths[largest] = 0
	}
	return widths[0], widths[1], widths[2]
}

// ChannelDetail is everything the dashboard knows about one channel.
type ChannelDetail struct {
	ID, Name, Repository, Participation, AlertPolicy string
	Member, Private, Configured                      bool
	Settings                                         []ChannelSetting
	Summary                                          string
	OpenLoops                                        int
	MemoryUpdated                                    time.Time
	Preferences                                      []Preference
	Rules                                            []StandingRule
	Schedules                                        []Schedule
	Episodes                                         []Item
	Blocked, Failed                                  int
}

// Channel gathers one channel's configuration, memory and history.
//
// Reported as (detail, found, error) rather than a bare error: a channel that
// Responder is a member of but has never been configured for is a real answer
// with a page worth showing, and collapsing it into "not found" would hide the
// channels most likely to need attention.
func (r *Reader) Channel(ctx context.Context, id string) (ChannelDetail, bool, error) {
	detail := ChannelDetail{ID: id, Name: r.channelName(ctx, id)}
	if !r.live() || id == "" {
		return detail, false, nil
	}

	var name string
	var private, present int
	membership := r.db.QueryRowContext(ctx, `
	  SELECT channel_name, private, present FROM slack_channel_memberships
	  WHERE channel_id = ?`, id).Scan(&name, &private, &present)
	if membership == nil {
		detail.Member, detail.Private = present == 1, private == 1
		if name != "" {
			detail.Name = "#" + name
		}
	}

	var participation, repository, alerts string
	configured := r.db.QueryRowContext(ctx, `
	  SELECT COALESCE(participation,''), COALESCE(repository,''), COALESCE(alert_policy,'')
	  FROM channel_configurations WHERE channel_id = ?`, id).
		Scan(&participation, &repository, &alerts)
	if configured == nil {
		detail.Configured = true
		detail.Participation, detail.Repository, detail.AlertPolicy = participation, repository, alerts
	}

	// A channel nothing has ever seen is not a channel. Membership,
	// configuration and recorded work are each enough on their own, so a
	// channel Responder was invited to but has not worked in still opens.
	seen := membership == nil || configured == nil ||
		r.Count(ctx, `SELECT COUNT(*) FROM agent_runs WHERE channel_id = ?`, id) > 0
	if !seen {
		return detail, false, nil
	}

	detail.Settings = r.channelSettings(ctx, id, participation)

	var state, updated string
	if r.db.QueryRowContext(ctx, `
	  SELECT COALESCE(state_json,'{}'), updated_at FROM conversation_memories
	  WHERE channel_id = ? AND thread_ts = ''`, id).Scan(&state, &updated) == nil {
		detail.MemoryUpdated = parseStamp(updated)
		var decoded struct {
			SituationSummary string `json:"situation_summary"`
			Goal             string `json:"goal"`
			OpenLoops        []any  `json:"open_loops"`
		}
		if json.Unmarshal([]byte(state), &decoded) == nil {
			detail.Summary = decoded.SituationSummary
			if detail.Summary == "" {
				detail.Summary = decoded.Goal
			}
			detail.OpenLoops = len(decoded.OpenLoops)
		}
	}

	for _, preference := range mustSlice(r.Preferences(ctx)) {
		if preference.Scope == detail.Name {
			detail.Preferences = append(detail.Preferences, preference)
		}
	}
	for _, rule := range mustSlice(r.StandingRules(ctx)) {
		if rule.Channel == detail.Name {
			detail.Rules = append(detail.Rules, rule)
		}
	}
	for _, schedule := range mustSlice(r.Schedules(ctx)) {
		if schedule.Channel == detail.Name {
			detail.Schedules = append(detail.Schedules, schedule)
		}
	}

	detail.Episodes, _ = r.EpisodesForChannel(ctx, id, 12)
	detail.Blocked = r.Count(ctx, `SELECT COUNT(*) FROM work_episodes e
	  JOIN agent_runs r ON r.id = e.agent_run_id
	  WHERE r.channel_id = ? AND e.lifecycle_state IN
	    ('blocked','waiting_operator','waiting_approval')`, id)
	detail.Failed = r.Count(ctx,
		`SELECT COUNT(*) FROM agent_runs WHERE channel_id = ? AND terminal_state = 'failed'`, id)
	return detail, true, nil
}

// mustSlice drops the error from a list this page treats as decoration. Used
// only where the section is a filtered view of a page that reports its own
// failures; nothing here is the answer to the page's question.
func mustSlice[T any](items []T, _ error) []T { return items }

// channelSettings resolves each override the way the host resolves it.
//
// The precedence is the slash command's, restated here because the dashboard
// reads the database directly and cannot call into the service to ask. It is
// the one duplication in this package, and it is why the row shows its source:
// if this drifts from service.shadowStatus, the page says which rule it
// believes it applied and the difference is visible rather than silent.
func (r *Reader) channelSettings(ctx context.Context, id, participation string) []ChannelSetting {
	settings := make([]ChannelSetting, 0, 2)
	for _, name := range []string{"proactive", "shadow"} {
		setting := ChannelSetting{
			Name:    name,
			Channel: r.slackSetting(ctx, "channel", id, name),
			Global:  r.slackSetting(ctx, "global", "", name),
			Config:  "inherit",
		}
		if participation != "" {
			setting.Config = "off"
			if participation == name {
				setting.Config = "on"
			}
		}
		switch {
		case setting.Channel != "inherit":
			setting.Effective, setting.Source = setting.Channel, "channel override"
		case setting.Config != "inherit":
			setting.Effective, setting.Source = setting.Config, "channel setup"
		case setting.Global != "inherit":
			setting.Effective, setting.Source = setting.Global, "workspace override"
		default:
			setting.Effective, setting.Source = "off", "deployment configuration"
		}
		setting.On = setting.Effective == "on"
		settings = append(settings, setting)
	}
	return settings
}

func (r *Reader) slackSetting(ctx context.Context, scope, channel, name string) string {
	var value string
	if err := r.db.QueryRowContext(ctx, `
	  SELECT value FROM slack_settings WHERE scope = ? AND channel_id = ? AND name = ?`,
		scope, channel, name).Scan(&value); err != nil || value == "" {
		return "inherit"
	}
	return value
}

// KnownChannels lists every channel the dashboard can open a page for.
func (r *Reader) KnownChannels(ctx context.Context) ([]ChannelConfigRow, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := r.db.QueryContext(ctx, `
	  SELECT m.channel_id, COALESCE(c.participation,''), COALESCE(c.repository,''),
	         COALESCE(m.present,0),
	         (SELECT COUNT(*) FROM agent_runs a WHERE a.channel_id = m.channel_id)
	  FROM slack_channel_memberships m
	  LEFT JOIN channel_configurations c ON c.channel_id = m.channel_id
	  WHERE m.present = 1 OR c.channel_id IS NOT NULL
	  ORDER BY m.channel_name LIMIT 100`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []ChannelConfigRow{}
	for rows.Next() {
		var item ChannelConfigRow
		var present int
		if err := rows.Scan(&item.ID, &item.Mode, &item.Repository, &present, &item.Episodes); err != nil {
			return nil, err
		}
		item.Member = present == 1
		item.Channel = r.channelName(ctx, item.ID)
		items = append(items, item)
	}
	return items, rows.Err()
}
