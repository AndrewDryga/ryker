package webui

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/decision"
)

// collect runs one presentation query.
//
// Every list here is the same three steps — open, scan, close — and the places
// that were written out by hand each got one of them slightly wrong. Having a
// single shape also means rows.Err() is never the thing that gets forgotten,
// which is how a truncated result set reads as a short one.
func collect[T any](
	ctx context.Context,
	reader *Reader,
	query string,
	scan func(*sql.Rows) (T, error),
	args ...any,
) ([]T, error) {
	if !reader.live() {
		return nil, nil
	}
	rows, err := reader.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []T{}
	for rows.Next() {
		item, err := scan(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

// episodeSources lists every id an episode's work was filed under.
//
// Evidence and coverage carry no episode_id. The store files them under
// source_input, which is the Slack input id when a watch produced them and the
// agent run id otherwise, so both have to be tried. The first version of this
// dashboard queried `FROM evidence WHERE episode_id = ?` — a column that has
// never existed — and because the handler discarded the error, every episode
// reported "No evidence was recorded" over as many as nineteen observations.
const episodeSources = `SELECT id FROM agent_runs WHERE episode_id = ?
  UNION SELECT source_id FROM agent_runs WHERE episode_id = ?`

// Turn is the model exchange behind an episode's last attempt: what was sent,
// what came back, and whether the host could read it.
//
// This is where "why did it say that" bottoms out. The prompt text is the part
// that is mostly absent — the manifest keeps a sha256 of the compiled prompt
// and only the engineering-task path retains the text — so the digest is shown
// when the text is not, rather than leaving the section looking empty.
type Turn struct {
	RunID, Mode, State, Error string
	AttemptNumber, Failures   int
	Prompt, PromptDigest      string
	RawResult                 string
	Created, Updated          time.Time
	Action, Reason, Message   string
	Reaction                  string
	Followups                 []string
	Attention                 string
	Completion                Completion
	Effects                   []SideEffect
	Operations                []Tally
	Prose, Unreadable         string
	Rejections                []Rejection
}

// Completion is the decision-ready boundary the model reported. Keeping it
// beside the public response makes a blocked investigation visibly different
// from a conversational reply that simply did not need an assessment.
type Completion struct {
	Status, Verdict, Summary, Blocker, Next string
	Gaps                                    []string
	// Kind is the machine's name for why the work stopped, and Attempts is
	// what the model already tried before it did. Both were recorded from the
	// beginning and neither was ever shown, so a blocked episode said only
	// that it was blocked — leaving the reader to guess what was missing and
	// to repeat work the model had already done.
	Kind     string
	Attempts []string
}

// SideEffect is durable or proposed state produced by an episode. The state is
// deliberately explicit: an offered rule is not a saved rule, and a requested
// approval is not an executed action.
type SideEffect struct {
	Kind, State, Title, Detail, ID string
	Before, After                  string
	At, ResponseAt                 time.Time
	Responded                      bool
}

type Tally struct {
	Name  string
	Count int
}

// Rejection is the host refusing the model's answer and the correction it
// handed back. 181 are on record and none had a surface, which is the
// difference between "it said nothing" and "it said something the contract
// could not read".
type Rejection struct {
	RunID, Outcome, Detail string
	At                     time.Time
}

// EpisodeArtifact is durable work around a model turn that is not represented
// by the episode event stream itself: the accepted commitment, a scheduled
// execution, a goal, a classifier decision, publication lifecycle, or a
// production quality finding. Keeping these records in one presentation type
// lets the trace order them with model calls and Slack deliveries without
// teaching the template every storage schema.
type EpisodeArtifact struct {
	ID, Kind, State, Title, Summary, Detail, DetailKind string
	At                                                  time.Time
	Stats                                               []ArtifactStat
}

type ArtifactStat struct {
	Label, Value string
}

// ActivityMoment is one thing the model did inside a turn, folded into the
// shape a reader wants rather than the shape the wire uses. Coop narrates a
// tool call as two events — it started, it finished — because the trace has to
// be readable while the turn is still running; by the time anyone opens the
// page those two are one row with a duration.
type ActivityMoment struct {
	// Kind is the presentation family: tool, thought, plan, permission, or
	// elided. It is not the Coop event type, which distinguishes a start from
	// a finish that this view has already joined.
	Kind, Title, ToolKind, Status, Detail string
	// Arguments is the whole recorded input, kept for the disclosure behind
	// Detail. Detail is what fits a table cell; this is what was actually sent.
	Arguments      string
	Entries        []ActivityPlanStep
	At             time.Time
	Duration, Tone string
	Dropped        int
}

type ActivityPlanStep struct {
	Content, Status, Priority string
}

// Activity returns the episode's narrated work in the order Coop produced it.
//
// A tool call that never reached a terminal update keeps an empty status: the
// turn ended while it was in flight, or the narration budget ran out mid-call.
// Showing it as running is honest; inventing a completion is not.
func (r *Reader) Activity(ctx context.Context, episodeID string) ([]ActivityMoment, error) {
	if !r.live() {
		return nil, nil
	}
	type activityRow struct {
		runID, kind, toolCallID, title, toolKind, status string
		detail                                           []byte
		at                                               time.Time
	}
	rows, err := collect(ctx, r, `
	  SELECT agent_run_id, kind, tool_call_id, title, tool_kind, status,
	         COALESCE(detail, CAST('' AS BLOB)), occurred_at
	  FROM agent_activity WHERE episode_id = ?
	  ORDER BY agent_run_id, sequence LIMIT 500`,
		func(scan *sql.Rows) (activityRow, error) {
			var row activityRow
			var at string
			err := scan.Scan(&row.runID, &row.kind, &row.toolCallID, &row.title,
				&row.toolKind, &row.status, &row.detail, &at)
			row.at = parseStamp(at)
			return row, err
		}, episodeID)
	if err != nil {
		return nil, err
	}
	moments := []ActivityMoment{}
	// Where each in-flight call landed, so its completion updates the row it
	// opened instead of appending a second one. Keyed by run as well as by
	// call: providers number tool calls per session, so an episode that ran
	// twice holds two "t1"s, and a call left open by the first run would
	// otherwise swallow the second run's completion.
	openCalls := map[string]int{}
	for _, row := range rows {
		key := row.runID + "\x00" + row.toolCallID
		switch row.kind {
		case "tool.completed":
			if index, ok := openCalls[key]; ok && row.toolCallID != "" {
				moments[index].Status = row.status
				moments[index].Tone = activityTone(row.status)
				if span := row.at.Sub(moments[index].At); span >= 0 {
					moments[index].Duration = compactDuration(span)
				}
				delete(openCalls, key)
				continue
			}
			// A completion whose start was never recorded still happened.
			moments = append(moments, ActivityMoment{
				Kind: "tool", Title: row.title, ToolKind: row.toolKind,
				Status: row.status, Tone: activityTone(row.status), At: row.at,
			})
		case "tool.started":
			if row.toolCallID != "" {
				openCalls[key] = len(moments)
			}
			label, summary, full := activityCall(row.title, row.detail)
			moments = append(moments, ActivityMoment{
				Kind: "tool", Title: label, ToolKind: row.toolKind,
				At: row.at, Detail: summary, Arguments: full,
			})
		case "model.thought":
			moments = append(moments, ActivityMoment{
				Kind: "thought", Title: row.title, At: row.at,
				Detail: activityDetailText(row.detail, "text"),
			})
		case "model.plan":
			moments = append(moments, ActivityMoment{
				Kind: "plan", Title: row.title, At: row.at,
				Entries: activityPlanSteps(row.detail),
			})
		case "permission.decided":
			moment := ActivityMoment{
				Kind: "permission", Title: row.title, At: row.at,
				Detail: activityDetailText(row.detail, "option_kind"),
			}
			if activityDetailText(row.detail, "outcome") == "cancelled" {
				moment.Tone = "warn"
			}
			moments = append(moments, moment)
		case "activity.elided":
			moments = append(moments, ActivityMoment{
				Kind: "elided", Title: row.title, At: row.at, Tone: "warn",
				Detail:  activityDetailText(row.detail, "reason"),
				Dropped: activityDetailInt(row.detail, "dropped"),
			})
		}
	}
	return moments, nil
}

// activityCall turns a recorded tool input into the three things a table
// needs: what to call the row, what fits in its arguments cell, and the whole
// record to put behind a disclosure.
//
// The raw shape is not what an operator is looking for. An Emisar call arrives
// as mcp.emisar.run_action carrying a 250-byte envelope, and the fact that
// matters — which action ran against which target — is two levels inside it.
// Printing the envelope in a cell said "an MCP tool was called" four times in
// a row and made the reader dig for the only part that differed.
func activityCall(title string, detail []byte) (label, summary, full string) {
	label = title
	input := activityInputObject(detail)
	if len(input) == 0 {
		return label, "", ""
	}
	full = activityPrettyJSON(input)

	var envelope struct {
		Server    string          `json:"server"`
		Tool      string          `json:"tool"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if json.Unmarshal(input, &envelope) == nil && envelope.Server != "" && envelope.Tool != "" {
		var call struct {
			ActionID string          `json:"action_id"`
			Args     json.RawMessage `json:"args"`
			Reason   string          `json:"reason"`
		}
		_ = json.Unmarshal(envelope.Arguments, &call)
		operation := call.ActionID
		if operation == "" {
			operation = envelope.Tool
		}
		label = envelope.Server + " · " + operation
		if summary = activityFields(call.Args); summary == "" {
			// No inner args: fall back to the envelope minus the parts that
			// are identical on every call from the same pack.
			summary = activityFields(envelope.Arguments, "action_id", "pack_ref", "runner_refs", "reason", "wait")
		}
		if call.Reason != "" {
			full = "Why: " + call.Reason + "\n\n" + full
		}
		return label, summary, full
	}
	return label, activityFields(input), full
}

// activityInputObject unwraps the stored {"input": …} envelope, treating an
// input that carries nothing as absent. Several adapters populate rawInput
// only for MCP calls, so an empty object is the common case and printing "{}"
// in a cell is worse than printing nothing.
func activityInputObject(detail []byte) json.RawMessage {
	if len(detail) == 0 {
		return nil
	}
	var wrapper struct {
		Input json.RawMessage `json:"input"`
	}
	if json.Unmarshal(detail, &wrapper) != nil {
		return nil
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(wrapper.Input, &fields) != nil || len(fields) == 0 {
		return nil
	}
	return wrapper.Input
}

// activityFields renders a flat object as "key=value · key=value", skipping
// the named keys. Values that are not scalars are compacted rather than
// expanded: the cell is a label, and the disclosure holds the real thing.
func activityFields(object json.RawMessage, skip ...string) string {
	if len(object) == 0 {
		return ""
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(object, &fields) != nil || len(fields) == 0 {
		return ""
	}
	omit := map[string]bool{}
	for _, key := range skip {
		omit[key] = true
	}
	names := make([]string, 0, len(fields))
	for name := range fields {
		if !omit[name] {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	parts := make([]string, 0, len(names))
	for _, name := range names {
		parts = append(parts, name+"="+activityScalar(fields[name]))
	}
	return truncateActivityCell(strings.Join(parts, " · "))
}

func activityScalar(raw json.RawMessage) string {
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return truncateActivityCell(text)
	}
	var compact bytes.Buffer
	if json.Compact(&compact, raw) != nil {
		return "?"
	}
	return truncateActivityCell(compact.String())
}

const activityCellBytes = 160

func truncateActivityCell(value string) string {
	return core.TruncateUTF8WithSuffix(value, activityCellBytes, "…")
}

func activityPrettyJSON(raw json.RawMessage) string {
	var indented bytes.Buffer
	if json.Indent(&indented, raw, "", "  ") != nil {
		return string(raw)
	}
	return indented.String()
}

func activityTone(status string) string {
	switch status {
	case "failed":
		return "bad"
	case "cancelled":
		return "warn"
	default:
		return ""
	}
}

func activityDetailText(detail []byte, field string) string {
	if len(detail) == 0 {
		return ""
	}
	var parsed map[string]json.RawMessage
	if json.Unmarshal(detail, &parsed) != nil {
		return ""
	}
	raw, ok := parsed[field]
	if !ok {
		return ""
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return text
	}
	// A tool's arguments are an object, not a string. Compacted rather than
	// pretty-printed: this is a label in a table cell, not a document.
	var compact bytes.Buffer
	if json.Compact(&compact, raw) != nil {
		return ""
	}
	return compact.String()
}

func activityDetailInt(detail []byte, field string) int {
	if len(detail) == 0 {
		return 0
	}
	var parsed map[string]int
	if json.Unmarshal(detail, &parsed) != nil {
		return 0
	}
	return parsed[field]
}

func activityPlanSteps(detail []byte) []ActivityPlanStep {
	if len(detail) == 0 {
		return nil
	}
	var parsed struct {
		Entries []ActivityPlanStep `json:"entries"`
	}
	if json.Unmarshal(detail, &parsed) != nil {
		return nil
	}
	return parsed.Entries
}

func (r *Reader) Turn(ctx context.Context, episodeID string) (Turn, error) {
	turns, err := r.Turns(ctx, episodeID)
	if err != nil || len(turns) == 0 {
		return Turn{}, err
	}
	return turns[len(turns)-1], nil
}

// Turns returns every model exchange owned by the episode in execution order.
// An episode may release its worker, wake later, and create another agent run;
// showing only the latest run hid the earlier answer and made rejections appear
// before any visible model call.
func (r *Reader) Turns(ctx context.Context, episodeID string) ([]Turn, error) {
	turns, err := collect(ctx, r, `
	  SELECT DISTINCT a.id, a.mode, COALESCE(a.terminal_state,''),
	         COALESCE(a.last_error,''), COALESCE(a.attempt_number,0),
	         COALESCE(a.failure_count,0),
	         COALESCE(a.prompt,''), COALESCE(CAST(a.result_json AS TEXT),''),
	         a.created_at, a.updated_at
	  FROM agent_runs AS a
	  LEFT JOIN episode_attempts AS t ON t.agent_run_id = a.id
	  WHERE a.episode_id = ? OR t.episode_id = ?
	  ORDER BY a.created_at, a.attempt_number, a.id`, func(rows *sql.Rows) (Turn, error) {
		var item Turn
		var created, updated string
		err := rows.Scan(&item.RunID, &item.Mode, &item.State, &item.Error,
			&item.AttemptNumber, &item.Failures, &item.Prompt, &item.RawResult, &created, &updated)
		item.Created, item.Updated = parseStamp(created), parseStamp(updated)
		return item, err
	}, episodeID, episodeID)
	if err != nil {
		return nil, err
	}
	for index := range turns {
		turn := &turns[index]
		turn.readResult(turn.RawResult)
		turn.Reason, turn.Message = r.resolveChannels(ctx, turn.Reason), r.resolveChannels(ctx, turn.Message)
		_ = r.db.QueryRowContext(ctx, `
		  SELECT f.content_digest FROM context_manifest_refs AS f
		  JOIN context_manifests AS m ON m.id = f.manifest_id
		  WHERE f.kind = 'compiled_prompt'
		    AND f.source_ref = 'agent-run:' || ? || ':prompt'
		  ORDER BY m.created_at DESC LIMIT 1`, turn.RunID).Scan(&turn.PromptDigest)
		turn.Rejections, err = collect(ctx, r, `
		  SELECT outcome, detail, created_at FROM audit_events
		  WHERE kind = 'result.correction' AND object_id = ?
		  ORDER BY created_at`, func(rows *sql.Rows) (Rejection, error) {
			var item Rejection
			var at string
			err := rows.Scan(&item.Outcome, &item.Detail, &at)
			item.RunID, item.At = turn.RunID, parseStamp(at)
			return item, err
		}, turn.RunID)
		if err != nil {
			return nil, err
		}
	}
	return turns, nil
}

// readResult reads the answer with the host's own parser.
//
// Not a second implementation, deliberately. The stored result arrives in three
// shapes — a bare envelope, an envelope fenced inside narration, and plain
// prose — and a display decoder that only handled the first one rendered a
// thousand characters of raw JSON where the reply should be. decision.
// ParseWatchDecision already handles all three, so the page shows what the host
// actually read, and a change to that parser changes this page with it.
func (t *Turn) readResult(result string) {
	trimmed := strings.TrimSpace(result)
	if trimmed == "" {
		return
	}
	parsed, err := decision.ParseWatchDecision(trimmed, time.Now().UTC())
	if err != nil {
		// The failure is the answer, not a gap: a result the host could not read
		// is why the episode retried, and the parser's own complaint says which
		// part of it was wrong.
		t.Prose, t.Unreadable = trimmed, err.Error()
		return
	}
	t.Action, t.Reason, t.Message = parsed.Action, parsed.Reason, parsed.Message
	t.Reaction, t.Followups = parsed.Reaction, parsed.FollowupMessages
	t.Attention = attentionLine(parsed.Attention)
	if parsed.Completion != nil {
		t.Completion = Completion{
			Status: parsed.Completion.Status, Verdict: parsed.Completion.Verdict,
			Summary: parsed.Completion.Summary, Blocker: parsed.Completion.Blocker,
			Next: parsed.Completion.NextAction, Gaps: parsed.Completion.MaterialGaps,
			Kind: parsed.Completion.BlockerKind, Attempts: parsed.Completion.Attempts,
		}
	}
	t.Effects = resultSideEffects(parsed, t.State)
	counts := map[string]int{}
	for _, operation := range parsed.Operations {
		counts[operation.Type]++
	}
	t.Operations = tally(counts)
}

func resultSideEffects(parsed decision.WatchDecision, terminalState string) []SideEffect {
	state := "reported"
	if terminalState == "completed" {
		state = "saved"
	}
	effects := []SideEffect{}
	add := func(kind, effectState, title, detail string) {
		if strings.TrimSpace(title) == "" && strings.TrimSpace(detail) == "" {
			return
		}
		effects = append(effects, SideEffect{
			Kind: kind, State: effectState, Title: title, Detail: detail,
		})
	}
	memory := parsed.Memory
	for _, item := range []struct {
		title, detail string
	}{
		{"Goal", memory.Goal},
		{"Channel purpose", memory.ChannelPurpose},
		{"Situation summary", memory.SituationSummary},
	} {
		if strings.TrimSpace(item.detail) == "" {
			continue
		}
		add("conversation memory", state, item.title, item.detail)
	}
	for _, item := range memory.Knowledge {
		detail := item.Statement
		if item.Kind != "" {
			detail += " · " + item.Kind
		}
		add("conversation memory", state, item.Subject, detail)
	}
	for _, group := range []struct {
		title string
		items []string
	}{
		{"Active topics", memory.ActiveTopics}, {"Open loops", memory.OpenLoops},
		{"Topology", memory.Topology}, {"Decisions", memory.Decisions},
		{"Unresolved questions", memory.UnresolvedQuestions},
	} {
		if len(group.items) > 0 {
			add("conversation memory", state, group.title, strings.Join(group.items, " · "))
		}
	}
	if offer := parsed.MemoryOffer; offer != nil {
		add("durable memory", "offered", offer.Subject,
			offer.Predicate+" = "+offer.Value+offerExpiry(offer.ExpiresIn))
	}
	if offer := parsed.PreferenceOffer; offer != nil {
		add("preference", "offered", offer.Name,
			offer.Value+" · "+offer.Scope+offerExpiry(offer.ExpiresIn))
	}
	if offer := parsed.RuleOffer; offer != nil {
		add("standing rule", "offered", offer.Trigger+" → "+offer.Action,
			offer.Repository+offerExpiry(offer.ExpiresIn))
	}
	for _, offer := range appendScheduleOffers(parsed.ScheduleOffer, parsed.ScheduleOffers) {
		add("scheduled task", "offered", offer.Title,
			offer.Recurrence+" · "+offer.StartAt+offerExpiry(offer.ExpiresIn))
	}
	if parsed.TaskTitle != "" {
		add("engineering task", "offered", parsed.TaskTitle, parsed.TaskRepository)
	}
	if approval := parsed.PendingApproval; approval != nil {
		add("Emisar approval", "waiting", approval.ActionID, approval.RunID)
	}
	for _, visual := range parsed.Visuals {
		add("visual", "attached", visual.Title, visual.AltText)
	}
	for _, update := range parsed.PublicationUpdates {
		add("publication", update.State, update.Kind, update.Summary)
	}
	return effects
}

func appendScheduleOffers(primary *core.ScheduleOffer, additional []*core.ScheduleOffer) []*core.ScheduleOffer {
	offers := make([]*core.ScheduleOffer, 0, 1+len(additional))
	if primary != nil {
		offers = append(offers, primary)
	}
	for _, offer := range additional {
		if offer != nil {
			offers = append(offers, offer)
		}
	}
	return offers
}

func offerExpiry(value string) string {
	if strings.TrimSpace(value) == "" {
		return ""
	}
	return " · expires in " + value
}

// SideEffects returns confirmed durable state attributable to this episode's
// source Slack event. Confirmation buttons are separate Slack inputs, so the
// episode cannot find their records by its own run id; the source event is the
// stable join key carried through every offer payload.
func (r *Reader) SideEffects(ctx context.Context, episodeID string) ([]SideEffect, error) {
	items, err := collect(ctx, r, `
	  WITH RECURSIVE descendants(id, path) AS (
	    SELECT id, ',' || ? || ',' || id || ',' FROM work_episodes WHERE parent_episode_id = ?
	    UNION ALL
	    SELECT child.id, descendants.path || child.id || ','
	      FROM work_episodes AS child JOIN descendants ON child.parent_episode_id = descendants.id
	      WHERE instr(descendants.path, ',' || child.id || ',') = 0
	  ), refs(ref) AS (
	    SELECT source_id FROM agent_runs WHERE episode_id = ?
	    UNION
	    SELECT s.event_id FROM slack_inputs AS s
	      JOIN agent_runs AS a ON a.source_id = s.id
	      WHERE a.episode_id = ? AND s.event_id != ''
	  ), effects(kind, state, title, detail, id, created_at, before_value, after_value, responded, response_at) AS (
	    SELECT 'preference', CASE WHEN enabled = 1 THEN 'saved' ELSE 'disabled' END,
	           name, value || ' · ' || scope_kind || ':' || scope_key, id, created_at, '', '', 0, ''
	      FROM responder_preferences WHERE source_ref IN (SELECT ref FROM refs)
	    UNION ALL
	    SELECT 'standing rule', CASE WHEN enabled = 1 THEN 'saved' ELSE 'disabled' END,
	           trigger_name || ' → ' || action_name,
	           repository || ' · ' || source_kind, id, created_at, '', '', 0, ''
	      FROM standing_rules WHERE source_ref IN (SELECT ref FROM refs)
	    UNION ALL
	    SELECT 'scheduled task', CASE WHEN enabled = 1 THEN 'saved' ELSE 'disabled' END,
	           title, recurrence || ' · ' || COALESCE(next_run_at, start_at), id, created_at, '', '', 0, ''
	      FROM scheduled_tasks WHERE source_ref IN (SELECT ref FROM refs)
	    UNION ALL
	    SELECT 'durable memory', 'saved', subject_key,
	           predicate || ' = ' || value_json, id, created_at, '', '', 0, ''
	      FROM memory_entries WHERE source_ref IN (SELECT ref FROM refs)
	    UNION ALL
	    SELECT 'work episode', child.lifecycle_state, child.objective,
	           child.mode || ' · ' || child.authority, child.id,
	           COALESCE(child.completed_at, child.updated_at, child.created_at), '', '',
	           EXISTS (
	             SELECT 1 FROM slack_deliveries AS delivery
	             WHERE delivery.episode_id = child.id AND delivery.state = 'sent'
	               AND delivery.response_root = 1 AND delivery.operation IN ('post','file')
	           ),
	           COALESCE((
	             SELECT MIN(delivery.updated_at) FROM slack_deliveries AS delivery
	             WHERE delivery.episode_id = child.id AND delivery.state = 'sent'
	               AND delivery.response_root = 1 AND delivery.operation IN ('post','file')
	           ), '')
	      FROM work_episodes AS child WHERE child.id IN (SELECT id FROM descendants)
	    UNION ALL
	    SELECT 'conversation memory', json_extract(entry.value, '$.state'),
	           json_extract(entry.value, '$.title'),
	           COALESCE(json_extract(entry.value, '$.kind'), ''),
	           audit.id || ':' || entry.key, audit.created_at,
	           COALESCE(json_extract(entry.value, '$.before'), ''),
	           COALESCE(json_extract(entry.value, '$.after'), ''), 0, ''
	      FROM conversation_memory_changes AS audit,
	           json_each(audit.changes_json) AS entry
	      WHERE audit.episode_id = ?
	  )
	  SELECT kind, state, title, detail, id, created_at, before_value, after_value,
	         responded, response_at FROM effects
	  ORDER BY created_at, kind, id`,
		func(rows *sql.Rows) (SideEffect, error) {
			var item SideEffect
			var at, responseAt string
			err := rows.Scan(
				&item.Kind, &item.State, &item.Title, &item.Detail, &item.ID, &at,
				&item.Before, &item.After, &item.Responded, &responseAt,
			)
			item.At, item.ResponseAt = parseStamp(at), parseStamp(responseAt)
			if separator := strings.LastIndex(item.Detail, " = "); separator >= 0 {
				var unquoted string
				if json.Unmarshal([]byte(item.Detail[separator+3:]), &unquoted) == nil {
					item.Detail = item.Detail[:separator+3] + unquoted
				}
			}
			return item, err
		}, episodeID, episodeID, episodeID, episodeID, episodeID)
	return items, err
}

// mergeSideEffects prefers transaction-confirmed memory changes over the
// memory snapshot inferred from the model result. Older episodes have no audit
// row, so their result projection remains a useful best-effort fallback.
func mergeSideEffects(inferred, confirmed []SideEffect) []SideEffect {
	hasConfirmedMemory := false
	for _, effect := range confirmed {
		if effect.Kind == "conversation memory" {
			hasConfirmedMemory = true
			break
		}
	}
	result := make([]SideEffect, 0, len(inferred)+len(confirmed))
	for _, effect := range inferred {
		if hasConfirmedMemory && effect.Kind == "conversation memory" {
			continue
		}
		result = append(result, effect)
	}
	return append(result, confirmed...)
}

// attentionLine formats only the scores the model actually sent.
//
// Urgency is absent from most watch results. Rendering it as 0 would read as
// "nothing urgent" rather than "not scored", which is the same lie as a zero
// standing in for a missing measurement anywhere else on this dashboard.
func attentionLine(scores decision.AttentionAssessment) string {
	parts := []string{}
	if scores.Addressee != "" {
		parts = append(parts, scores.Addressee)
	}
	for _, score := range []struct {
		name  string
		value int
	}{
		{"urgency", scores.Urgency}, {"confidence", scores.Confidence},
		{"novelty", scores.Novelty}, {"ownership", scores.Ownership},
	} {
		if score.value != 0 {
			parts = append(parts, fmt.Sprintf("%s %d", score.name, score.value))
		}
	}
	return strings.Join(parts, " · ")
}

// tally orders counted things by weight, so the operation a turn spent itself
// on leads rather than whichever key the map iterated first.
func tally(counts map[string]int) []Tally {
	items := make([]Tally, 0, len(counts))
	for name, count := range counts {
		items = append(items, Tally{name, count})
	}
	sort.Slice(items, func(a, b int) bool {
		if items[a].Count != items[b].Count {
			return items[a].Count > items[b].Count
		}
		return items[a].Name < items[b].Name
	})
	return items
}

// ClaimRow is one claim the episode had to settle and what the evidence did to
// it. The evidence table alone says what was observed; only the assessment says
// whether the thing being argued survived it.
type ClaimRow struct {
	Claim, Status, Confidence, Detail string
	Supporting, Contradicting         int
}

func (r *Reader) Claims(ctx context.Context, episodeID string) ([]ClaimRow, error) {
	return collect(ctx, r, `
	  SELECT claim_id, status, COALESCE(confidence,''), COALESCE(detail,''),
	         COALESCE(evidence_ids_json,'[]'), COALESCE(contradiction_ids_json,'[]')
	  FROM claim_assessments WHERE episode_id = ? ORDER BY claim_id`,
		func(rows *sql.Rows) (ClaimRow, error) {
			var item ClaimRow
			var supporting, contradicting string
			err := rows.Scan(&item.Claim, &item.Status, &item.Confidence, &item.Detail,
				&supporting, &contradicting)
			item.Detail = r.resolveChannels(ctx, item.Detail)
			item.Supporting, item.Contradicting = countIDs(supporting), countIDs(contradicting)
			return item, err
		}, episodeID)
}

func countIDs(list string) int {
	var ids []string
	if json.Unmarshal([]byte(list), &ids) != nil {
		return 0
	}
	return len(ids)
}

// CoverageRow is one layer of the system the episode was expected to assess.
//
// "unknown" is the load-bearing status: it separates a layer that was checked
// and found healthy from one nobody looked at, and an answer built on four
// unknowns is a different answer.
type CoverageRow struct {
	Layer, Status, Source, Detail string
	Observed                      time.Time
}

func (r *Reader) Coverage(ctx context.Context, episodeID string) ([]CoverageRow, error) {
	return collect(ctx, r, `
	  SELECT layer, status, COALESCE(source,''), COALESCE(detail,''), COALESCE(observed_at,'')
	  FROM coverage WHERE source_input IN (`+episodeSources+`)
	  ORDER BY layer`,
		func(rows *sql.Rows) (CoverageRow, error) {
			var item CoverageRow
			var observed string
			err := rows.Scan(&item.Layer, &item.Status, &item.Source, &item.Detail, &observed)
			item.Source, item.Detail = r.resolveChannels(ctx, item.Source), r.resolveChannels(ctx, item.Detail)
			item.Observed = parseStamp(observed)
			return item, err
		}, episodeID, episodeID)
}

// ContextRef is one thing that was actually in the prompt.
//
// The timeline records "5 references, manifest v1" and could not say which
// five. This is that list: the Slack message that started the work, the
// compiled prompt and assembled context by digest, the repository at a
// revision, the Coop policy, and any artifact handed in.
type ContextRef struct {
	Kind, What, Visibility, Digest, Omitted string
	// FullDigest keeps the untruncated hash for lookups — the retained
	// artifact body is keyed by it — while Digest stays display-short.
	FullDigest string
}

// ManifestRow is the frozen context envelope for the episode's latest attempt.
type ManifestRow struct {
	ID, RunID, AttemptID                   string
	Provider, Model, Effort, PromptVersion string
	Contract, ToolSchema, Preset           string
	SubmittedPrompt                        string
	Version, AttemptNumber                 int
	Created                                time.Time
	Refs                                   []ContextRef
	Omissions                              []string
}

func (r *Reader) Manifest(ctx context.Context, episodeID string) (ManifestRow, error) {
	rows, err := r.Manifests(ctx, episodeID)
	if err != nil || len(rows) == 0 {
		return ManifestRow{}, err
	}
	return rows[len(rows)-1], nil
}

// Manifests follows the immutable agent-run identity as well as episode_id.
// Recovery can attach an already-started run to a follow-up episode after its
// attempt and context manifest were frozen. Looking only at the manifest's
// original episode hides the model call while run-scoped audit corrections
// remain visible, which makes the trace appear to reject a result before any
// model ran.
func (r *Reader) Manifests(ctx context.Context, episodeID string) ([]ManifestRow, error) {
	if !r.live() {
		return nil, nil
	}
	rows, err := collect(ctx, r, `
	  SELECT DISTINCT m.id, a.id, m.attempt_id, t.attempt_number,
	         COALESCE(m.provider,''), COALESCE(m.model,''), COALESCE(m.reasoning_effort,''),
	         COALESCE(m.prompt_version,''), COALESCE(m.contract_version,''),
	         COALESCE(m.tool_schema_version,''), COALESCE(m.preset,''),
	         COALESCE(m.submitted_prompt,''), m.version,
	         COALESCE(m.omissions_json,'[]'), m.created_at
	  FROM context_manifests AS m
	  JOIN episode_attempts AS t ON t.id = m.attempt_id
	  JOIN agent_runs AS a ON a.id = t.agent_run_id
	  WHERE m.episode_id = ? OR a.episode_id = ?
	  ORDER BY m.created_at, m.id`, func(rows *sql.Rows) (ManifestRow, error) {
		var row ManifestRow
		var omissions, created string
		err := rows.Scan(&row.ID, &row.RunID, &row.AttemptID, &row.AttemptNumber,
			&row.Provider, &row.Model, &row.Effort, &row.PromptVersion,
			&row.Contract, &row.ToolSchema, &row.Preset, &row.SubmittedPrompt,
			&row.Version, &omissions, &created)
		row.Created = parseStamp(created)
		_ = json.Unmarshal([]byte(omissions), &row.Omissions)
		return row, err
	}, episodeID, episodeID)
	if err != nil {
		return nil, err
	}
	for index := range rows {
		rows[index].Refs, err = r.manifestRefs(ctx, rows[index].ID)
		if err != nil {
			return nil, err
		}
	}
	return rows, nil
}

func (r *Reader) manifestRefs(ctx context.Context, manifestID string) ([]ContextRef, error) {
	return collect(ctx, r, `
	  SELECT kind, source_ref, COALESCE(source_revision,''), visibility,
	         COALESCE(content_digest,''), COALESCE(omitted_reason,''),
	         COALESCE(metadata_json,'')
	  FROM context_manifest_refs WHERE manifest_id = ? ORDER BY ordinal`,
		func(rows *sql.Rows) (ContextRef, error) {
			var item ContextRef
			var ref, revision, metadata string
			err := rows.Scan(&item.Kind, &ref, &revision, &item.Visibility,
				&item.FullDigest, &item.Omitted, &metadata)
			item.Digest = truncate(item.FullDigest, 12)
			item.What = r.describeRef(ctx, item.Kind, ref, revision, metadata)
			return item, err
		}, manifestID)
}

// describeRef says what the reference points at rather than repeating the
// stored string. "agent-run:run_2e29…:prompt" restates the kind column and
// buries the only part a reader can use — which attempt it came from — and a
// bare channel id says nothing at all.
func (r *Reader) describeRef(ctx context.Context, kind, ref, revision, metadata string) string {
	var meta struct {
		ChannelID string `json:"channel_id"`
		ThreadTS  string `json:"thread_ts"`
		Name      string `json:"name"`
		MediaType string `json:"media_type"`
	}
	_ = json.Unmarshal([]byte(metadata), &meta)
	scheme, rest, found := strings.Cut(ref, ":")
	if !found {
		rest = ref
	}
	switch kind {
	case "source_input":
		where := r.channelName(ctx, meta.ChannelID)
		if where == "" {
			return scheme
		}
		if meta.ThreadTS != "" {
			where += " thread"
		}
		return scheme + " in " + where
	case "compiled_prompt", "assembled_context":
		runID, _, _ := strings.Cut(rest, ":")
		return "attempt " + truncate(runID, 16)
	case "repository":
		if revision != "" {
			return rest + " @ " + truncate(revision, 8)
		}
		return rest
	case "artifact":
		if meta.Name != "" && meta.MediaType != "" {
			return meta.Name + " (" + meta.MediaType + ")"
		}
		return rest
	default:
		return rest
	}
}

// RetainedArtifact is one stored input artifact body, openable from the
// trace's runtime-access table.
type RetainedArtifact struct {
	Digest, Name, MediaType string
	Body                    []byte
}

func (r *Reader) ContextArtifact(ctx context.Context, digest string) (RetainedArtifact, bool, error) {
	artifact := RetainedArtifact{Digest: strings.TrimSpace(digest)}
	if artifact.Digest == "" || !r.live() {
		return RetainedArtifact{}, false, nil
	}
	err := r.db.QueryRowContext(ctx, `
	  SELECT name, media_type, body FROM context_artifacts WHERE digest = ?`,
		artifact.Digest).Scan(&artifact.Name, &artifact.MediaType, &artifact.Body)
	if errors.Is(err, sql.ErrNoRows) {
		return RetainedArtifact{}, false, nil
	}
	if err != nil {
		return RetainedArtifact{}, false, err
	}
	return artifact, true, nil
}

// StoredArtifactDigests reports which of the given digests have a retained
// body, so the trace links only artifacts that will actually open.
func (r *Reader) StoredArtifactDigests(ctx context.Context, digests []string) (map[string]bool, error) {
	stored := map[string]bool{}
	if !r.live() || len(digests) == 0 {
		return stored, nil
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(digests)), ",")
	args := make([]any, 0, len(digests))
	for _, digest := range digests {
		args = append(args, digest)
	}
	found, err := collect(ctx, r,
		`SELECT digest FROM context_artifacts WHERE digest IN (`+placeholders+`)`,
		func(rows *sql.Rows) (string, error) {
			var digest string
			err := rows.Scan(&digest)
			return digest, err
		}, args...)
	if err != nil {
		return nil, err
	}
	for _, digest := range found {
		stored[digest] = true
	}
	return stored, nil
}

// Attempt is one try at the episode and what ended it. The brief asks for
// "retries, and what changed between them"; the failure class and the run's
// error are that difference.
type Attempt struct {
	Number                       int
	State, Failure, RunID, Error string
	Started, Completed           time.Time
}

func (r *Reader) Attempts(ctx context.Context, episodeID string) ([]Attempt, error) {
	return collect(ctx, r, `
	  SELECT t.attempt_number, t.state, COALESCE(t.failure_class,''), t.agent_run_id,
	         COALESCE(a.last_error,''), COALESCE(t.started_at,''), COALESCE(t.completed_at,'')
	  FROM episode_attempts AS t LEFT JOIN agent_runs AS a ON a.id = t.agent_run_id
	  WHERE t.episode_id = ? OR a.episode_id = ?
	  ORDER BY COALESCE(t.started_at, t.created_at), t.attempt_number`,
		func(rows *sql.Rows) (Attempt, error) {
			var item Attempt
			var started, completed string
			err := rows.Scan(&item.Number, &item.State, &item.Failure, &item.RunID,
				&item.Error, &started, &completed)
			item.Started, item.Completed = parseStamp(started), parseStamp(completed)
			return item, err
		}, episodeID, episodeID)
}

// Rejections returns every host correction attached to a run currently owned
// by the episode. Unlike Turn.Rejections, this is intentionally not limited to
// the latest run: the whole point of the timeline is to explain earlier failed
// model results too.
func (r *Reader) Rejections(ctx context.Context, episodeID string) ([]Rejection, error) {
	return collect(ctx, r, `
	  SELECT e.object_id, e.outcome, e.detail, e.created_at
	  FROM audit_events AS e
	  JOIN agent_runs AS a ON a.id = e.object_id
	  WHERE e.kind = 'result.correction' AND a.episode_id = ?
	  ORDER BY e.created_at`, func(rows *sql.Rows) (Rejection, error) {
		var item Rejection
		var at string
		err := rows.Scan(&item.RunID, &item.Outcome, &item.Detail, &at)
		item.At = parseStamp(at)
		return item, err
	}, episodeID)
}

// Artifacts returns every durable record that changes or explains the episode
// but is not already part of its kernel event stream. The query boundaries are
// deliberately small and typed: one broken optional projection should make the
// page name that projection as unavailable, never erase the rest of the trace.
func (r *Reader) Artifacts(ctx context.Context, episodeID string) ([]EpisodeArtifact, error) {
	if !r.live() {
		return nil, nil
	}
	items := []EpisodeArtifact{}
	var projectionErrors []error
	appendItems := func(name string, more []EpisodeArtifact, err error) {
		items = append(items, more...)
		if err != nil {
			projectionErrors = append(projectionErrors, fmt.Errorf("%s: %w", name, err))
		}
	}
	appendCollected := func(name, query string, scan func(*sql.Rows) (EpisodeArtifact, error), args ...any) {
		more, err := collect(ctx, r, query, scan, args...)
		appendItems(name, more, err)
	}

	appendCollected("commitments", `
	  SELECT c.episode_id, c.title, w.created_at
	  FROM commitments AS c JOIN work_episodes AS w ON w.id = c.episode_id
	  WHERE c.episode_id = ?`, func(rows *sql.Rows) (EpisodeArtifact, error) {
		var item EpisodeArtifact
		var at string
		err := rows.Scan(&item.ID, &item.Title, &at)
		item.Kind, item.State, item.At = "commitment", "accepted", parseStamp(at)
		item.Summary = "Responder accepted responsibility for this work."
		item.Stats = []ArtifactStat{{"Episode", item.ID}}
		return item, err
	}, episodeID)

	appendCollected("progress", `
	  SELECT id, sequence, phase, summary, created_at
	  FROM work_episode_progress WHERE episode_id = ? ORDER BY sequence`, func(rows *sql.Rows) (EpisodeArtifact, error) {
		var item EpisodeArtifact
		var sequence int
		var at string
		err := rows.Scan(&item.ID, &sequence, &item.State, &item.Summary, &at)
		item.Kind, item.Title, item.At = "progress", "Progress update", parseStamp(at)
		item.Stats = []ArtifactStat{{"Record", item.ID}, {"Sequence", fmt.Sprint(sequence)}, {"Phase", item.State}}
		return item, err
	}, episodeID)

	appendCollected("goals", `
	  SELECT id, kind, requested_outcome, completion_contract,
	         authority_requirement, required, state, blocker,
	         parent_goal_id, prerequisite_goal_ids_json,
	         writable_repository, read_only_repositories_json,
	         created_at, updated_at
	  FROM episode_goals WHERE episode_id = ? ORDER BY created_at, id`, func(rows *sql.Rows) (EpisodeArtifact, error) {
		var item EpisodeArtifact
		var goalKind, contract, authority, blocker, parent, prerequisites, writable, readOnly string
		var required int
		var created, updated string
		err := rows.Scan(&item.ID, &goalKind, &item.Title, &contract, &authority,
			&required, &item.State, &blocker, &parent, &prerequisites, &writable,
			&readOnly, &created, &updated)
		item.Kind, item.At = "goal", parseStamp(created)
		item.Summary = contract
		item.DetailKind = "text"
		item.Detail = strings.TrimSpace(strings.Join(nonempty(
			labelLine("Blocker", blocker), labelLine("Parent goal", parent),
			labelLine("Prerequisites", prettyJSON(prerequisites)),
			labelLine("Writable repository", writable),
			labelLine("Read-only repositories", prettyJSON(readOnly)),
			labelLine("Last updated", updated)), "\n"))
		item.Stats = []ArtifactStat{{"Goal", item.ID}, {"Goal type", goalKind}, {"Authority", authority}, {"Required", yesNo(required != 0)}}
		return item, err
	}, episodeID)

	appendCollected("scheduled runs", `
	  SELECT r.task_id, t.title, t.recurrence, t.timezone, r.scheduled_for,
	         r.source_input, r.agent_run_id, r.outcome, r.last_error, COALESCE(r.started_at,''),
	         COALESCE(r.completed_at,''), r.created_at
	  FROM scheduled_task_runs AS r
	  JOIN scheduled_tasks AS t ON t.id = r.task_id
	  WHERE r.episode_id = ? ORDER BY r.created_at`, func(rows *sql.Rows) (EpisodeArtifact, error) {
		var item EpisodeArtifact
		var taskID, recurrence, timezone, scheduledFor, sourceInput, agentRun, lastError, started, completed, created string
		err := rows.Scan(&taskID, &item.Title, &recurrence, &timezone, &scheduledFor,
			&sourceInput, &agentRun, &item.State, &lastError, &started, &completed, &created)
		item.ID = taskID + "@" + scheduledFor
		item.Kind, item.At = "scheduled_run", parseStamp(created)
		item.Summary = scheduleRunSummary(item.State, scheduledFor, timezone)
		item.Detail, item.DetailKind = lastError, "error"
		item.Stats = []ArtifactStat{{"Task", taskID}, {"Source input", fallback(sourceInput, "not recorded")},
			{"Agent run", fallback(agentRun, "not started")}, {"Recurrence", recurrence}, {"Scheduled for", scheduledFor},
			{"Started", fallback(started, "not started")}, {"Completed", fallback(completed, "not completed")}}
		return item, err
	}, episodeID)

	appendCollected("evaluation decisions", `
	  SELECT id, channel_id, source_input, mode, action, reason, evidence_count, coverage_count, created_at
	  FROM evaluation_decisions
	  WHERE source_input IN (`+episodeSources+`)
	  ORDER BY created_at`, func(rows *sql.Rows) (EpisodeArtifact, error) {
		var item EpisodeArtifact
		var channel, sourceInput, mode string
		var evidenceCount, coverageCount int
		var at string
		err := rows.Scan(&item.ID, &channel, &sourceInput, &mode, &item.State, &item.Summary,
			&evidenceCount, &coverageCount, &at)
		item.Kind, item.Title, item.At = "evaluation", "Evaluation decision", parseStamp(at)
		item.Stats = []ArtifactStat{{"Decision", item.ID}, {"Channel", r.channelName(ctx, channel)},
			{"Source input", sourceInput}, {"Mode", mode}, {"Action", item.State},
			{"Evidence", fmt.Sprint(evidenceCount)}, {"Coverage", fmt.Sprint(coverageCount)}}
		return item, err
	}, episodeID, episodeID)

	appendCollected("standing rule runs", `
	  SELECT rr.rule_id, rr.source_input, sr.trigger_name, sr.action_name, rr.outcome, rr.event_id,
	         rr.created_at
	  FROM standing_rule_runs AS rr
	  JOIN standing_rules AS sr ON sr.id = rr.rule_id
	  WHERE rr.source_input IN (`+episodeSources+`)
	  ORDER BY rr.created_at`, func(rows *sql.Rows) (EpisodeArtifact, error) {
		var item EpisodeArtifact
		var ruleID, sourceInput, trigger, action, eventID, at string
		err := rows.Scan(&ruleID, &sourceInput, &trigger, &action, &item.State, &eventID, &at)
		item.ID = ruleID + "@" + sourceInput
		item.Kind, item.Title, item.At = "standing_rule_run", "Standing rule ran", parseStamp(at)
		// The trigger and action are the rule's own identifiers, so they stay
		// exact; the sentence around them says what the run decided.
		item.Summary = "This channel's " + trigger + " rule matched, so Responder ran its " +
			action + " workflow" + standingRuleOutcomePhrase(item.State)
		item.Stats = []ArtifactStat{{"Rule", ruleID}, {"Source input", sourceInput},
			{"Event", eventID}, {"Outcome", item.State}}
		return item, err
	}, episodeID, episodeID)

	appendCollected("standing assignment actions", `
	  SELECT aa.id, aa.assignment_id, sa.signal_pattern, sa.change_class,
	         sa.repository, aa.correlation_key, aa.outcome, aa.created_at
	  FROM standing_assignment_actions AS aa
	  JOIN standing_assignments AS sa ON sa.id = aa.assignment_id
	  WHERE aa.episode_id = ?
	  ORDER BY aa.created_at`, func(rows *sql.Rows) (EpisodeArtifact, error) {
		var item EpisodeArtifact
		var assignmentID, signal, changeClass, repository, correlation, at string
		err := rows.Scan(&item.ID, &assignmentID, &signal, &changeClass, &repository,
			&correlation, &item.State, &at)
		item.Kind, item.Title, item.At = "standing_assignment_action", "Standing assignment ran", parseStamp(at)
		item.Summary = "Matched " + signal + " and recorded " + strings.ReplaceAll(changeClass, "_", " ") + " work."
		item.Stats = []ArtifactStat{{"Assignment", assignmentID}, {"Correlation", correlation},
			{"Signal", signal}, {"Change class", changeClass}, {"Repository", repository}, {"Outcome", item.State}}
		return item, err
	}, episodeID)

	appendCollected("feedback", `
	  SELECT id, category, sentiment, summary, details, user_id, source, status,
	         channel_id, message_ts, target_message_ts, created_at
	  FROM feedback_items WHERE episode_id = ?
	  ORDER BY created_at`, func(rows *sql.Rows) (EpisodeArtifact, error) {
		var item EpisodeArtifact
		var category, sentiment, userID, source, channel, messageTS, targetTS, at string
		err := rows.Scan(&item.ID, &category, &sentiment, &item.Summary, &item.Detail,
			&userID, &source, &item.State, &channel, &messageTS, &targetTS, &at)
		item.Kind, item.Title, item.At, item.DetailKind = "feedback", "Operator feedback", parseStamp(at), "text"
		from := r.userName(userID)
		if from != "" && from != userID {
			from = "@" + from
		}
		item.Stats = []ArtifactStat{{"Feedback", item.ID}, {"From", fallback(from, userID)},
			{"Category", category}, {"Sentiment", sentiment}, {"Source", source},
			{"Channel", fallback(r.channelName(ctx, channel), channel)}, {"Message", messageTS},
			{"About message", fallback(targetTS, "not recorded")}}
		return item, err
	}, episodeID)

	appendCollected("replay candidates", `
	  SELECT id, run_id, capability, correction_class, correction, status,
	         reviewed_by, created_at, expires_at
	  FROM fixture_candidates WHERE episode_id = ?
	  ORDER BY created_at`, func(rows *sql.Rows) (EpisodeArtifact, error) {
		var item EpisodeArtifact
		var runID, capability, correctionClass, reviewedBy, at, expires string
		err := rows.Scan(&item.ID, &runID, &capability, &correctionClass, &item.Detail,
			&item.State, &reviewedBy, &at, &expires)
		item.Kind, item.Title, item.At, item.DetailKind = "replay_candidate", "Replay case proposed", parseStamp(at), "text"
		item.Summary = "A correction from this episode was saved for regression review."
		item.Stats = []ArtifactStat{{"Candidate", item.ID}, {"Run", runID},
			{"Capability", fallback(capability, "general")}, {"Correction class", correctionClass},
			{"Reviewed by", fallback(reviewedBy, "not reviewed")}, {"Expires", expires}}
		return item, err
	}, episodeID)

	incidentIDs, err := r.episodeIncidentIDs(ctx, episodeID)
	if err != nil {
		projectionErrors = append(projectionErrors, fmt.Errorf("incidents: %w", err))
	}
	for _, incidentID := range incidentIDs {
		more, err := r.incidentArtifacts(ctx, incidentID)
		appendItems("incident "+incidentID, more, err)
	}

	appendCollected("quality findings", `
	  SELECT id, run_id, channel_id, verdict, disposition, severity, summary, expected_behavior,
	         evidence, code_evidence, regression_test, challenger_summary,
	         suspected_components, challenger_evidence, artifacts, created_at
	  FROM quality_findings
	  WHERE EXISTS (SELECT 1 FROM json_each(quality_findings.episode_ids) WHERE value = ?)
	  ORDER BY created_at`, func(rows *sql.Rows) (EpisodeArtifact, error) {
		var item EpisodeArtifact
		var runID, channel, disposition, severity, expected, evidence, codeEvidence, regression, challenger, suspected, challengerEvidence, artifacts, at string
		err := rows.Scan(&item.ID, &runID, &channel, &item.State, &disposition, &severity, &item.Summary,
			&expected, &evidence, &codeEvidence, &regression, &challenger, &suspected, &challengerEvidence, &artifacts, &at)
		item.Kind, item.Title, item.At = "quality_finding", "Production quality review", parseStamp(at)
		item.DetailKind = "text"
		item.Detail = strings.Join(nonempty(labelLine("Expected behavior", expected),
			labelLine("Evidence", prettyJSON(evidence)), labelLine("Code evidence", prettyJSON(codeEvidence)),
			labelLine("Suspected components", prettyJSON(suspected)),
			labelLine("Regression test", regression), labelLine("Adversarial review", challenger),
			labelLine("Adversarial evidence", prettyJSON(challengerEvidence)),
			labelLine("Artifacts", artifacts)), "\n\n")
		item.Stats = []ArtifactStat{{"Finding", item.ID}, {"Run", fallback(runID, "not recorded")},
			{"Channel", fallback(r.channelName(ctx, channel), "not recorded")},
			{"Verdict", item.State}, {"Severity", fallback(severity, "not rated")},
			{"Disposition", fallback(disposition, "not recorded")}}
		return item, err
	}, episodeID)

	sort.SliceStable(items, func(i, j int) bool {
		if items[i].At.Equal(items[j].At) {
			return items[i].Kind < items[j].Kind
		}
		return items[i].At.Before(items[j].At)
	})
	return items, errors.Join(projectionErrors...)
}

func (r *Reader) episodeIncidentIDs(ctx context.Context, episodeID string) ([]string, error) {
	return collect(ctx, r, `
	  SELECT DISTINCT incident_id FROM agent_runs
	  WHERE episode_id = ? AND incident_id != ''
	  UNION
	  SELECT DISTINCT a.incident_id FROM audit_events AS a
	  JOIN agent_runs AS r ON r.id = a.object_id OR r.source_id = a.object_id
	  WHERE r.episode_id = ? AND a.incident_id != ''`, func(rows *sql.Rows) (string, error) {
		var id string
		if err := rows.Scan(&id); err != nil {
			return "", err
		}
		return id, nil
	}, episodeID, episodeID)
}

func (r *Reader) incidentArtifacts(ctx context.Context, incidentID string) ([]EpisodeArtifact, error) {
	items := []EpisodeArtifact{}
	projectionErrors := []error{}
	appendItems := func(name string, more []EpisodeArtifact, err error) {
		items = append(items, more...)
		if err != nil {
			projectionErrors = append(projectionErrors, fmt.Errorf("%s: %w", name, err))
		}
	}
	timeline, err := collect(ctx, r, `
	  SELECT id, kind, title, detail, actor_id, created_at
	  FROM timeline_events WHERE incident_id = ? ORDER BY created_at`, func(rows *sql.Rows) (EpisodeArtifact, error) {
		var item EpisodeArtifact
		var actor, at, timelineKind string
		err := rows.Scan(&item.ID, &timelineKind, &item.Title, &item.Detail, &actor, &at)
		item.Kind, item.State, item.At, item.DetailKind = "incident_timeline", timelineKind, parseStamp(at), "text"
		item.Stats = []ArtifactStat{{"Record", item.ID}, {"Incident", incidentID}, {"Actor", fallback(actor, "system")}}
		return item, err
	}, incidentID)
	appendItems("timeline", timeline, err)
	lifecycle, err := collect(ctx, r, `
	  SELECT id, kind, state, summary, source_channel_id, source_message_ts, created_at
	  FROM publication_lifecycle_events WHERE incident_id = ? ORDER BY created_at`, func(rows *sql.Rows) (EpisodeArtifact, error) {
		var item EpisodeArtifact
		var channel, messageTS, at string
		err := rows.Scan(&item.ID, &item.Kind, &item.State, &item.Summary, &channel, &messageTS, &at)
		item.Kind, item.Title, item.At = "publication_lifecycle", "Publication update", parseStamp(at)
		item.Stats = []ArtifactStat{{"Record", item.ID}, {"Incident", incidentID}, {"Event", item.State},
			{"Source channel", fallback(channel, "not recorded")}, {"Source message", fallback(messageTS, "not recorded")}}
		return item, err
	}, incidentID)
	appendItems("publication lifecycle", lifecycle, err)
	publication, err := collect(ctx, r, `
	  SELECT incident_id, repository, base_branch, head_branch, parent_head,
	         candidate_tree, commit_sha, remote_sha, pr_number, pr_url, state,
	         last_error, created_at, updated_at, COALESCE(published_at,'')
	  FROM publications WHERE incident_id = ?`, func(rows *sql.Rows) (EpisodeArtifact, error) {
		var item EpisodeArtifact
		var repository, base, head, parent, tree, commit, remote, url, lastError, created, updated, published string
		var prNumber int
		err := rows.Scan(&item.ID, &repository, &base, &head, &parent, &tree, &commit,
			&remote, &prNumber, &url, &item.State, &lastError, &created, &updated, &published)
		item.Kind, item.Title, item.At = "publication", "Repository publication", parseStamp(created)
		item.Summary = publicationSummary(item.State, prNumber, url)
		item.Detail, item.DetailKind = lastError, "error"
		item.Stats = []ArtifactStat{{"Incident", item.ID}, {"Repository", repository}, {"Base", base}, {"Branch", head},
			{"Parent", parent}, {"Candidate tree", tree}, {"Commit", fallback(commit, "not committed")},
			{"Remote", fallback(remote, "not pushed")}, {"Pull request", fallback(url, "not created")},
			{"Published", fallback(published, "not published")}, {"Updated", updated}}
		return item, err
	}, incidentID)
	appendItems("publication", publication, err)
	return items, errors.Join(projectionErrors...)
}

func nonempty(values ...string) []string {
	kept := make([]string, 0, len(values))
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			kept = append(kept, value)
		}
	}
	return kept
}

func labelLine(label, value string) string {
	if strings.TrimSpace(value) == "" || value == "[]" || value == "{}" {
		return ""
	}
	return label + ": " + value
}

func yesNo(value bool) string {
	if value {
		return "yes"
	}
	return "no"
}

// scheduleRunSummary says when a scheduled run was due, in the timezone the
// schedule was written in. The stored instant carries nanoseconds and a UTC
// offset; neither belongs on a card about a daily 15:00 review.
func scheduleRunSummary(outcome, scheduledFor, timezone string) string {
	zone := fallback(timezone, "UTC")
	when := scheduledFor
	if due := parseStamp(scheduledFor); !due.IsZero() {
		if location, err := time.LoadLocation(zone); err == nil {
			when = due.In(location).Format("Mon 2 Jan, 15:04")
		} else {
			when = due.UTC().Format("Mon 2 Jan, 15:04")
		}
	}
	lead := "Nobody asked for this run — it came due on a schedule at " + when + " (" + zone + ")."
	switch outcome {
	case "completed":
		return lead + " It ran and finished."
	case "failed":
		return lead + " It ran and failed."
	case "skipped":
		return lead + " It was skipped."
	case "":
		return lead
	}
	return lead + " Outcome: " + strings.ReplaceAll(outcome, "_", " ") + "."
}

func publicationSummary(state string, prNumber int, url string) string {
	if prNumber > 0 {
		summary := fmt.Sprintf("Draft PR #%d is %s.", prNumber, state)
		if strings.TrimSpace(url) != "" {
			summary += " " + url
		}
		return summary
	}
	return "Publication is " + state + "."
}

// Delivery is a Slack post the episode queued.
//
// Sent deliveries are deleted once they pass the operational retention window,
// so this list thins with age: the oldest row on a production machine is five
// days newer than the oldest episode. An empty section here means pruned or
// never queued, not failed.
type Delivery struct {
	Kind, Operation, State, Channel, ThreadTS, MessageTS, Status, Error string
	Body                                                                string
	Retries                                                             int
	Created, At                                                         time.Time
}

func (r *Reader) Deliveries(ctx context.Context, episodeID string) ([]Delivery, error) {
	return collect(ctx, r, `
	  SELECT kind, operation, state, channel_id, COALESCE(thread_ts,''),
	         COALESCE(message_ts,''), COALESCE(status_text,''),
	         COALESCE(CAST(body_json AS TEXT),''), COALESCE(last_error,''),
	         failure_count, created_at, updated_at
	  FROM slack_deliveries WHERE episode_id = ? ORDER BY created_at`,
		func(rows *sql.Rows) (Delivery, error) {
			var item Delivery
			var channel, created, at string
			err := rows.Scan(&item.Kind, &item.Operation, &item.State, &channel,
				&item.ThreadTS, &item.MessageTS, &item.Status, &item.Body, &item.Error,
				&item.Retries, &created, &at)
			item.Channel, item.Created, item.At = r.channelName(ctx, channel),
				parseStamp(created), parseStamp(at)
			item.Body = prettyJSON(item.Body)
			return item, err
		}, episodeID)
}

// SourceInput is the Slack event that started an episode. It is deliberately
// read through the run rather than guessed from the episode title: titles are
// cleaned for scanning, while this record preserves the exact message and its
// attachment manifest.
type SourceInput struct {
	ID, Kind, UserID, Sender, ChannelID, Channel, ThreadTS, MessageTS string
	Text, Attachments                                                 string
	Received, Updated                                                 time.Time
}

// SlackHref is a permalink to the message this episode came from.
//
// The archives form rather than a deep link built from a team id: it needs
// only the channel and the timestamp, both of which the page already has, and
// Slack resolves the workspace itself. Blocked work is unblocked by answering
// in the thread, and a page that says what is missing while offering no way to
// go and supply it makes the reader hunt for a conversation Responder already
// knows the address of.
func (s SourceInput) SlackHref() string {
	if s.ChannelID == "" || s.MessageTS == "" {
		return ""
	}
	stamp := "p" + strings.ReplaceAll(s.MessageTS, ".", "")
	href := "https://slack.com/archives/" + s.ChannelID + "/" + stamp
	if s.ThreadTS != "" && s.ThreadTS != s.MessageTS {
		href += "?thread_ts=" + s.ThreadTS + "&cid=" + s.ChannelID
	}
	return href
}

// Wakeup is the durable subscription that let Responder release a worker and
// resume after an external object changed. It is read by trigger ID instead of
// episode ID because recovered follow-up episodes can be created after the
// subscription was stored on the episode that originally began the work.
type Wakeup struct {
	ID, EpisodeID, Kind, State, Matcher, Observation     string
	Due, PollAfter, Deadline, Created, Updated, Resolved time.Time
}

func (r *Reader) WakeupForTrigger(ctx context.Context, triggerID string) (Wakeup, error) {
	id := strings.TrimPrefix(triggerID, "episode_wakeup_")
	if id == "" || id == triggerID {
		return Wakeup{}, nil
	}
	return r.wakeup(ctx, id)
}

// Wakeups returns the complete subscription history visible from this episode.
// Direct wake-ups explain work the episode scheduled. A synthetic trigger may
// also point back to the wake-up stored by the parent episode, so include that
// record without duplicating it.
func (r *Reader) Wakeups(ctx context.Context, episodeID, triggerID string) ([]Wakeup, error) {
	items, err := collect(ctx, r, `
	  SELECT id, episode_id, kind, state,
	         COALESCE(CAST(event_matcher_json AS TEXT),'{}'),
	         COALESCE(CAST(last_observation_json AS TEXT),'{}'),
	         COALESCE(due_at,''), COALESCE(poll_after,''), COALESCE(deadline,''),
	         created_at, updated_at, COALESCE(resolved_at,'')
	  FROM episode_wakeups WHERE episode_id = ? ORDER BY created_at, id`, scanWakeup, episodeID)
	if err != nil {
		return nil, err
	}
	isWakeupTrigger := strings.HasPrefix(triggerID, "episode_wakeup_")
	triggerID = strings.TrimPrefix(triggerID, "episode_wakeup_")
	if isWakeupTrigger && triggerID != "" {
		seen := false
		for _, item := range items {
			seen = seen || item.ID == triggerID
		}
		if !seen {
			item, wakeErr := r.wakeup(ctx, triggerID)
			if wakeErr != nil {
				return nil, wakeErr
			}
			if item.ID != "" {
				items = append(items, item)
			}
		}
	}
	sort.SliceStable(items, func(i, j int) bool { return items[i].Created.Before(items[j].Created) })
	return items, nil
}

func (r *Reader) wakeup(ctx context.Context, id string) (Wakeup, error) {
	var item Wakeup
	if !r.live() {
		return item, nil
	}
	var due, pollAfter, deadline, created, updated, resolved string
	err := r.db.QueryRowContext(ctx, `
	  SELECT id, episode_id, kind, state,
	         COALESCE(CAST(event_matcher_json AS TEXT),'{}'),
	         COALESCE(CAST(last_observation_json AS TEXT),'{}'),
	         COALESCE(due_at,''), COALESCE(poll_after,''), COALESCE(deadline,''),
	         created_at, updated_at, COALESCE(resolved_at,'')
	  FROM episode_wakeups WHERE id = ?`, id).Scan(
		&item.ID, &item.EpisodeID, &item.Kind, &item.State,
		&item.Matcher, &item.Observation, &due, &pollAfter, &deadline,
		&created, &updated, &resolved,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return Wakeup{}, nil
	}
	if err != nil {
		return Wakeup{}, err
	}
	item.Matcher, item.Observation = prettyJSON(item.Matcher), prettyJSON(item.Observation)
	item.Due, item.PollAfter, item.Deadline = parseStamp(due), parseStamp(pollAfter), parseStamp(deadline)
	item.Created, item.Updated, item.Resolved = parseStamp(created), parseStamp(updated), parseStamp(resolved)
	return item, nil
}

func scanWakeup(rows *sql.Rows) (Wakeup, error) {
	var item Wakeup
	var due, pollAfter, deadline, created, updated, resolved string
	err := rows.Scan(&item.ID, &item.EpisodeID, &item.Kind, &item.State,
		&item.Matcher, &item.Observation, &due, &pollAfter, &deadline,
		&created, &updated, &resolved)
	item.Matcher, item.Observation = prettyJSON(item.Matcher), prettyJSON(item.Observation)
	item.Due, item.PollAfter, item.Deadline = parseStamp(due), parseStamp(pollAfter), parseStamp(deadline)
	item.Created, item.Updated, item.Resolved = parseStamp(created), parseStamp(updated), parseStamp(resolved)
	return item, err
}

type rowScanner interface {
	Scan(dest ...any) error
}

// TriggerInput is the exact durable input assigned to the episode's primary
// run. Follow-up episodes often use a synthetic recheck input, while
// SourceInput resolves the Slack message that originally anchored that work.
func (r *Reader) TriggerInput(ctx context.Context, episodeID string) (SourceInput, error) {
	var item SourceInput
	if !r.live() {
		return item, nil
	}
	err := r.scanSourceInput(ctx, r.db.QueryRowContext(ctx, `
	  SELECT s.id, s.kind, s.user_id, s.channel_id, s.thread_ts, s.message_ts,
	         s.text, COALESCE(CAST(s.attachments_json AS TEXT),'[]'),
	         s.received_at, s.updated_at
	  FROM work_episodes AS e
	  JOIN agent_runs AS a ON a.id = e.agent_run_id
	  JOIN slack_inputs AS s ON s.id = a.source_id
	  WHERE e.id = ?`, episodeID), &item)
	if errors.Is(err, sql.ErrNoRows) {
		// Older episode rows did not always retain agent_run_id. Use the first
		// chronological run rather than attempt_number: retries may restart at
		// one and otherwise displace the event that actually opened the episode.
		err = r.scanSourceInput(ctx, r.db.QueryRowContext(ctx, `
		  SELECT s.id, s.kind, s.user_id, s.channel_id, s.thread_ts, s.message_ts,
		         s.text, COALESCE(CAST(s.attachments_json AS TEXT),'[]'),
		         s.received_at, s.updated_at
		  FROM agent_runs AS a JOIN slack_inputs AS s ON s.id = a.source_id
		  WHERE a.episode_id = ?
		  ORDER BY a.created_at LIMIT 1`, episodeID), &item)
	}
	if errors.Is(err, sql.ErrNoRows) {
		return SourceInput{}, nil
	}
	return item, err
}

func (r *Reader) SourceInput(ctx context.Context, episodeID string) (SourceInput, error) {
	trigger, err := r.TriggerInput(ctx, episodeID)
	if err != nil || trigger.ID == "" || trigger.MessageTS != "" || trigger.ThreadTS == "" {
		return trigger, err
	}

	// Synthetic wake-ups have no Slack message timestamp. Their thread_ts is
	// the durable link back to the root Slack message that caused Responder to
	// wait for the external event in the first place.
	var root SourceInput
	err = r.scanSourceInput(ctx, r.db.QueryRowContext(ctx, `
	  SELECT s.id, s.kind, s.user_id, s.channel_id, s.thread_ts, s.message_ts,
	         s.text, COALESCE(CAST(s.attachments_json AS TEXT),'[]'),
	         s.received_at, s.updated_at
	  FROM work_episodes AS e
	  JOIN slack_inputs AS s
	    ON s.channel_id = e.channel_id AND s.message_ts = e.thread_ts
	  WHERE e.id = ?
	  ORDER BY s.received_at LIMIT 1`, episodeID), &root)
	if errors.Is(err, sql.ErrNoRows) {
		return trigger, nil
	}
	return root, err
}

func (r *Reader) scanSourceInput(ctx context.Context, row rowScanner, item *SourceInput) error {
	var channel, attachments, received, updated string
	err := row.Scan(&item.ID, &item.Kind, &item.UserID, &channel, &item.ThreadTS,
		&item.MessageTS, &item.Text, &attachments, &received, &updated)
	if err != nil {
		return err
	}
	item.ChannelID = channel
	item.Channel = r.channelName(ctx, channel)
	item.Sender = r.userName(item.UserID)
	if item.Sender != "" && item.Sender != item.UserID && !strings.HasPrefix(item.Sender, "@") {
		item.Sender = "@" + item.Sender
	}
	item.Text = r.resolveSlackText(ctx, item.Text)
	item.Attachments = prettyJSON(attachments)
	item.Received, item.Updated = parseStamp(received), parseStamp(updated)
	return nil
}

// standingRuleOutcomePhrase closes the standing-rule sentence with what the
// run decided. A rule can do its work and still stay silent — that is a
// deliberate outcome, not a missing reply.
func standingRuleOutcomePhrase(outcome string) string {
	switch outcome {
	case "reply":
		return ", which answered in the channel."
	case "ignore":
		return ", which found nothing worth saying and stayed silent."
	case "":
		return "."
	default:
		return " (" + strings.ReplaceAll(outcome, "_", " ") + ")."
	}
}
