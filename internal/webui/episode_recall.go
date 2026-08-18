package webui

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// The manifest kinds internal/service writes when it recalls past episodes.
// Spelled out here rather than imported because the dashboard reads the
// database and never the service package; a rename on that side has to reach
// this string through the manifests already on disk, which keep the old one.
const (
	similarEpisodeRefKind    = "similar_past_episode"
	similarPastEpisodesLayer = "similar_past_episodes"
	relatedTaskRefKind       = "related_engineering_task"
	relatedTasksLayer        = "related_engineering_tasks"
)

// recalledEpisodeName says which past episode a recall reference points at.
//
// "episode:ep_01K3QF…" is a coordinate a reader has to go paste somewhere else
// to understand, and this row is the only place the trace explains why a prompt
// spent budget on an incident that was already over. The projected objective —
// what that episode called itself — answers "which one is this" without leaving
// the page.
//
// blocked is named because the two terminal states recall accepts are not the
// same claim: a completed episode fixed something, a blocked one diagnosed
// something and stopped. Reading the second as the first is how "we solved this
// in July" gets said about an episode that never did.
func (r *Reader) recalledEpisodeName(ctx context.Context, episodeID, terminalState string) string {
	name := truncate(r.recalledEpisodeSummary(ctx, episodeID), 110)
	if name == "" {
		name = "episode " + truncate(episodeID, 16)
	}
	if terminalState == "blocked" {
		name += " (blocked, not verified)"
	}
	return name
}

// recalledEpisodeSummary reads the recall corpus's own headline for an episode.
//
// Read-only and tolerant of an absent row on purpose: retention prunes outcome
// rows on its own horizon while the manifest reference that cites them is kept
// forever, so an old trace linking to a pruned episode must still render. A
// missing row caches as the empty answer it is; a failed read does not, because
// a busy database for one page load should not blank this cell for the life of
// the process.
func (r *Reader) recalledEpisodeSummary(ctx context.Context, episodeID string) string {
	if episodeID == "" || !r.live() {
		return ""
	}
	if cached, ok := r.outcomes.Load(episodeID); ok {
		summary, _ := cached.(string)
		return summary
	}
	var objective, rootCause string
	err := r.lookup.QueryRowContext(ctx, `
	  SELECT objective, root_cause FROM episode_outcomes WHERE episode_id = ?`,
		episodeID).Scan(&objective, &rootCause)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return ""
	}
	summary := strings.TrimSpace(fallback(objective, rootCause))
	r.outcomes.Store(episodeID, summary)
	return summary
}

// OutcomeRow is what this episode became once it finished: the single flat row
// a later incident will actually read.
//
// It is a second surface, not a restatement of the trace. The trace explains
// one episode to a person; this row is the only part of it another episode can
// see, and the two disagree more often than anyone expects — retention prunes
// the triggering Slack message long before the outcome row, so a fingerprint is
// frequently built from a truncated objective headline while the timeline above
// still shows the operator's full sentence. Somebody asking "why did recall
// miss this" is asking about this row.
type OutcomeRow struct {
	EpisodeID, TerminalState          string
	Objective, RootCause, Remediation string
	Verification, SymptomFingerprint  string
	FingerprintSource, AlertGroupKey  string
	// Repository is here because recall scores it: two episodes bound to the
	// same repository rank closer together. Only the fields the scorer reads
	// are carried, so this row cannot quietly become a second episode summary
	// competing with the one at the top of the page.
	Repository     string
	Services       []string
	Verified       bool
	TerminalAt     time.Time
	TimeToDecision time.Duration
}

// EpisodeOutcome reads this episode's recall row, absent for anything that has
// not reached a terminal state recall accepts.
func (r *Reader) EpisodeOutcome(ctx context.Context, episodeID string) (OutcomeRow, error) {
	if !r.live() {
		return OutcomeRow{}, nil
	}
	var row OutcomeRow
	var services, terminalAt string
	var verified, seconds int
	err := r.db.QueryRowContext(ctx, `
	  SELECT episode_id, terminal_state, terminal_at, objective, symptom_fingerprint,
	         fingerprint_source, alert_group_key, services_json, root_cause,
	         remediation, verification, verified, time_to_decision_seconds, repository
	  FROM episode_outcomes WHERE episode_id = ?`, episodeID).Scan(
		&row.EpisodeID, &row.TerminalState, &terminalAt, &row.Objective,
		&row.SymptomFingerprint, &row.FingerprintSource, &row.AlertGroupKey,
		&services, &row.RootCause, &row.Remediation, &row.Verification,
		&verified, &seconds, &row.Repository)
	if errors.Is(err, sql.ErrNoRows) {
		return OutcomeRow{}, nil
	}
	if err != nil {
		return OutcomeRow{}, err
	}
	_ = json.Unmarshal([]byte(services), &row.Services)
	row.Verified = verified != 0
	row.TerminalAt = parseStamp(terminalAt)
	row.TimeToDecision = time.Duration(seconds) * time.Second
	return row, nil
}

// fingerprintSource names what a symptom fingerprint was actually built from.
//
// Every source here is legitimate and they are not equally strong, which is the
// whole reason the column exists. A recall ranked on the operator's own words is
// a different measurement from one ranked on a 180-byte display headline, and an
// operator reading a weak match needs to see which they are looking at before
// concluding the corpus is broken.
var fingerprintSource = map[string][2]string{
	"trigger_text": {"the trigger message",
		"Built from what the operator actually wrote, which is the strongest fingerprint available."},
	"trigger_control": {"a Slack control",
		"The trigger was a button or menu with no message text, so the control id and the objective stood in for it."},
	"alert_labels": {"alert labels",
		"No Slack input existed for this episode — it came from a webhook — so the alert's title and label values are the symptom."},
	"objective": {"the objective headline",
		"A weak fingerprint: the trigger text was gone by the time this row was written, leaving the truncated display objective. Recall can still match it, on fewer and blunter words than the operator used."},
}

// recallProjectionStep renders the episode's own row in the recall corpus.
//
// The corpus was inert until this projection existed, and a projection nobody
// can see is the next way it goes quiet: the row is written inside the terminal
// transaction and never mentioned again, so a wrong or empty root_cause would
// degrade every future recall silently, with no page anywhere admitting it.
func recallProjectionStep(outcome OutcomeRow, present func(string) string) TraceStep {
	source, known := fingerprintSource[outcome.FingerprintSource]
	if !known {
		source = [2]string{
			fallback(outcome.FingerprintSource, "an unrecorded source"),
			"This row does not name where its fingerprint came from, so how strong a match it can support is unknown.",
		}
	}
	tone := ""
	if outcome.TerminalState == "blocked" {
		// A blocked episode is still recalled, and is still the weaker source:
		// it diagnosed something and stopped rather than fixing it.
		tone = "warn"
	}
	stats := []TraceStat{
		{"Recorded as", fallback(outcome.TerminalState, "not recorded")},
		{"Fingerprinted from", source[0]},
		{"Remediation verified", verifiedLabel(outcome)},
	}
	if outcome.AlertGroupKey != "" {
		// Two episodes sharing this are the same alert firing twice, which is
		// the strongest signal recall has and the reason a reader should care
		// that the row carries one.
		stats = append(stats, TraceStat{"Alert group", outcome.AlertGroupKey})
	}
	if len(outcome.Services) > 0 {
		stats = append(stats, TraceStat{"Services", strings.Join(outcome.Services, " · ")})
	}
	if outcome.Repository != "" {
		stats = append(stats, TraceStat{"Repository", outcome.Repository})
	}
	if outcome.TimeToDecision > 0 {
		stats = append(stats, TraceStat{"Time to decision", compactDuration(outcome.TimeToDecision)})
	}
	return TraceStep{
		ID: "recall-projection", Stage: "Outcome", Actor: "Responder", State: "recorded",
		Icon: "db", Tone: tone, At: outcome.TerminalAt,
		Title:   "Recorded for future recall",
		Summary: present(fallback(outcome.RootCause, fallback(outcome.Objective, "This episode was projected with no cause recorded."))),
		Why:     "Finished episodes are flattened into one row each so a later incident can find this one by symptom. That row, not this page, is what recall reads.",
		Stats:   stats,
		Details: recallProjectionDetails(outcome, source[1], present),
	}
}

func verifiedLabel(outcome OutcomeRow) string {
	if outcome.Verified {
		return "yes"
	}
	// Not the same as "the fix failed". Recall ranks a verified outcome higher
	// and says "unverified" beside the rest, so the page has to draw the same
	// line the scorer does rather than printing a bare no.
	if strings.TrimSpace(outcome.Verification) != "" {
		return "no · verification recorded on a non-completed episode"
	}
	return "no · no verification step was recorded"
}

func recallProjectionDetails(outcome OutcomeRow, sourceNote string, present func(string) string) []TraceDetail {
	details := []TraceDetail{{
		Label: "Symptom fingerprint", Kind: "context", Status: "Matched on", Tone: "operational",
		Body:        fallback(present(outcome.SymptomFingerprint), "This row carries no fingerprint, so recall can never match it."),
		Description: sourceNote,
		Group:       "Recall projection",
		GroupDetail: "The flat row this episode leaves behind for the next one. Recall scores against these fields alone.",
		GroupCount:  1,
	}}
	for _, field := range []struct{ label, body, absent string }{
		{"Root cause", outcome.RootCause,
			"No cause was recorded, so this episode can be recalled but has nothing to tell the incident that finds it."},
		{"Remediation", outcome.Remediation,
			"No remediation was recorded: no Emisar action succeeded and no pull request shipped under this episode."},
		{"Verification", outcome.Verification,
			"No verification step was recorded, so nothing here says the fix was checked after it was applied."},
	} {
		if strings.TrimSpace(field.body) == "" {
			details = append(details, TraceDetail{
				Label: field.label, Kind: "missing", Status: "Not recorded",
				Description: field.absent, Tone: "trimmed", Inert: true,
			})
			continue
		}
		details = append(details, TraceDetail{
			Label: field.label, Body: present(field.body), Kind: "context",
			Status: "Recalled", Tone: "operational",
		})
	}
	details[0].GroupCount = len(details)
	return details
}
