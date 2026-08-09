package webui

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

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
	Prompt, PromptDigest      string
	Action, Reason, Message   string
	Attention                 string
	Operations                []Tally
	Prose, Unreadable         string
	Rejections                []Rejection
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
	Outcome, Detail string
	At              time.Time
}

func (r *Reader) Turn(ctx context.Context, episodeID string) (Turn, error) {
	var turn Turn
	if !r.live() {
		return turn, nil
	}
	var result string
	err := r.db.QueryRowContext(ctx, `
	  SELECT id, mode, COALESCE(terminal_state,''), COALESCE(last_error,''),
	         COALESCE(prompt,''), COALESCE(CAST(result_json AS TEXT),'')
	  FROM agent_runs WHERE episode_id = ?
	  ORDER BY attempt_number DESC, created_at DESC LIMIT 1`, episodeID).
		Scan(&turn.RunID, &turn.Mode, &turn.State, &turn.Error, &turn.Prompt, &result)
	if errors.Is(err, sql.ErrNoRows) {
		return turn, nil
	}
	if err != nil {
		return turn, err
	}
	turn.readResult(result)
	turn.Reason, turn.Message = r.resolveChannels(ctx, turn.Reason), r.resolveChannels(ctx, turn.Message)
	_ = r.db.QueryRowContext(ctx, `
	  SELECT f.content_digest FROM context_manifest_refs AS f
	  JOIN context_manifests AS m ON m.id = f.manifest_id
	  WHERE m.episode_id = ? AND f.kind = 'compiled_prompt'
	    AND f.source_ref = 'agent-run:' || ? || ':prompt'
	  ORDER BY m.version DESC LIMIT 1`, episodeID, turn.RunID).Scan(&turn.PromptDigest)
	turn.Rejections, err = collect(ctx, r, `
	  SELECT outcome, detail, created_at FROM audit_events
	  WHERE kind = 'result.correction' AND object_id = ?
	  ORDER BY created_at LIMIT 20`,
		func(rows *sql.Rows) (Rejection, error) {
			var item Rejection
			var at string
			err := rows.Scan(&item.Outcome, &item.Detail, &at)
			item.At = parseStamp(at)
			return item, err
		}, turn.RunID)
	return turn, err
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
	t.Attention = attentionLine(parsed.Attention)
	counts := map[string]int{}
	for _, operation := range parsed.Operations {
		counts[operation.Type]++
	}
	t.Operations = tally(counts)
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
	  FROM claim_assessments WHERE episode_id = ? ORDER BY claim_id LIMIT 100`,
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
	  ORDER BY layer LIMIT 40`,
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
}

// ManifestRow is the frozen context envelope for the episode's latest attempt.
type ManifestRow struct {
	Provider, Model, Effort, PromptVersion string
	Contract, ToolSchema, Preset           string
	Version                                int
	Created                                time.Time
	Refs                                   []ContextRef
	Omissions                              []string
}

func (r *Reader) Manifest(ctx context.Context, episodeID string) (ManifestRow, error) {
	var row ManifestRow
	if !r.live() {
		return row, nil
	}
	var id, omissions, created string
	err := r.db.QueryRowContext(ctx, `
	  SELECT id, COALESCE(provider,''), COALESCE(model,''), COALESCE(reasoning_effort,''),
	         COALESCE(prompt_version,''), COALESCE(contract_version,''),
	         COALESCE(tool_schema_version,''), COALESCE(preset,''), version,
	         COALESCE(omissions_json,'[]'), created_at
	  FROM context_manifests WHERE episode_id = ?
	  ORDER BY version DESC LIMIT 1`, episodeID).
		Scan(&id, &row.Provider, &row.Model, &row.Effort, &row.PromptVersion,
			&row.Contract, &row.ToolSchema, &row.Preset, &row.Version, &omissions, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return row, nil
	}
	if err != nil {
		return row, err
	}
	row.Created = parseStamp(created)
	_ = json.Unmarshal([]byte(omissions), &row.Omissions)
	row.Refs, err = r.manifestRefs(ctx, id)
	return row, err
}

func (r *Reader) manifestRefs(ctx context.Context, manifestID string) ([]ContextRef, error) {
	return collect(ctx, r, `
	  SELECT kind, source_ref, COALESCE(source_revision,''), visibility,
	         COALESCE(content_digest,''), COALESCE(omitted_reason,''),
	         COALESCE(metadata_json,'')
	  FROM context_manifest_refs WHERE manifest_id = ? ORDER BY ordinal LIMIT 200`,
		func(rows *sql.Rows) (ContextRef, error) {
			var item ContextRef
			var ref, revision, metadata string
			err := rows.Scan(&item.Kind, &ref, &revision, &item.Visibility,
				&item.Digest, &item.Omitted, &metadata)
			item.Digest = truncate(item.Digest, 12)
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
	  WHERE t.episode_id = ? ORDER BY t.attempt_number LIMIT 50`,
		func(rows *sql.Rows) (Attempt, error) {
			var item Attempt
			var started, completed string
			err := rows.Scan(&item.Number, &item.State, &item.Failure, &item.RunID,
				&item.Error, &started, &completed)
			item.Started, item.Completed = parseStamp(started), parseStamp(completed)
			return item, err
		}, episodeID)
}

// Delivery is a Slack post the episode queued.
//
// Sent deliveries are deleted once they pass the operational retention window,
// so this list thins with age: the oldest row on a production machine is five
// days newer than the oldest episode. An empty section here means pruned or
// never queued, not failed.
type Delivery struct {
	Kind, Operation, State, Channel, Status, Error string
	Attempts                                       int
	At                                             time.Time
}

func (r *Reader) Deliveries(ctx context.Context, episodeID string) ([]Delivery, error) {
	return collect(ctx, r, `
	  SELECT kind, operation, state, channel_id, COALESCE(status_text,''),
	         COALESCE(last_error,''), failure_count, updated_at
	  FROM slack_deliveries WHERE episode_id = ? ORDER BY created_at LIMIT 40`,
		func(rows *sql.Rows) (Delivery, error) {
			var item Delivery
			var channel, at string
			err := rows.Scan(&item.Kind, &item.Operation, &item.State, &channel,
				&item.Status, &item.Error, &item.Attempts, &at)
			item.Channel, item.At = r.channelName(ctx, channel), parseStamp(at)
			return item, err
		}, episodeID)
}
