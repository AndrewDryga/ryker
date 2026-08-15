package app

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/core"
	episodepkg "github.com/AndrewDryga/responder/internal/episode"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/store/intelligencestore"
)

// The projection rides the transaction that makes an episode terminal, so it
// only fires forward. The deployed databases hold hundreds of completed and
// blocked episodes from before it existed, and recall cannot see one of them —
// which is the whole corpus this product's largest bet rests on. These tests
// hold the backfill shut at the two places it can quietly lie: writing under
// --dry-run, and reporting a corpus without saying how much of it was rebuilt
// from a 180-byte truncated headline instead of from what the operator wrote.

// finishedEpisodeAwaitingOutcome builds the state a deployed database is in:
// an episode that reached a terminal state with no recall row. The row the
// terminal transition writes is deleted afterwards, because that is the only
// honest way to reproduce an episode that finished before the projection
// existed.
func finishedEpisodeAwaitingOutcome(
	t *testing.T,
	st *store.Store,
	channelID string,
) core.WorkEpisode {
	t.Helper()
	ctx := context.Background()
	input := core.SlackInput{
		ID: "input-" + channelID, EnvelopeID: "env-" + channelID, EventID: "event-" + channelID,
		Kind: "bot_message", TeamID: "T1", ChannelID: channelID, MessageTS: "1700.1",
		Text: "checkout latency alert firing: p99 above threshold on the payments gateway",
	}
	if _, err := st.AdmitSlackInput(ctx, input); err != nil {
		t.Fatal(err)
	}
	run, created, err := st.QueueAgentRun(ctx, core.AgentRun{
		Mode: core.AgentRunTriage, ChannelID: channelID, ConversationKey: "channel:" + channelID,
		SourceKind: "watch", SourceID: input.ID, Prompt: "Investigate " + input.ID,
	})
	if err != nil || !created {
		t.Fatalf("queue episode: created=%t err=%v", created, err)
	}
	if _, err := st.Intelligence.RecordEvidence(ctx, []core.Evidence{{
		ChannelID: channelID, SourceInput: input.ID, Claim: "p99 latency is elevated",
		Observation: "p99 3.4s", SourceType: "metrics", SourceName: "grafana",
		Target: "payments-gateway", Freshness: "fresh", Confidence: "high",
	}}); err != nil {
		t.Fatal(err)
	}
	episode, err := st.GetWorkEpisodeByRun(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	payload, err := json.Marshal(map[string]any{
		"id": "complete", "type": "complete_episode",
		"completion": map[string]any{
			"message": "resolved",
			"alert_assessment": map[string]any{
				"verdict": "real_issue", "impact": "checkout p99 tripled",
				"cause":            "connection pool exhaustion on the payments gateway",
				"immediate_action": "raised the pool ceiling to 200",
				"verification":     "p99 returned to 380ms and held for ten minutes",
			},
			"completion": map[string]any{"status": "decision_ready", "summary": "pool exhaustion"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.AppendWorkEpisodeEvent(ctx, run.ID, core.WorkEpisodeEvent{
		Kind: episodepkg.EventCompletionSubmitted, Actor: "agent",
		IdempotencyKey: "result:complete", Payload: payload,
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.SetWorkEpisodePhase(
		ctx, run.ID, core.EpisodeCompleted, "completed", "Resolved", "", time.Time{},
	); err != nil {
		t.Fatal(err)
	}
	return episode
}

// backfillTestDatabase opens the database directly, the way
// lifecycle-divergence does. Closing it is the caller's job and the timing is
// load-bearing: SQLite checkpoints the write-ahead log when the last connection
// closes, so a handle left open is also a database whose recent writes exist
// only in responder.db-wal.
func backfillTestDatabase(t *testing.T, stateDir string) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	return db
}

// forgetRecallRows removes what the terminal transitions just projected, so the
// fixture stands in for the episodes that finished before the projection
// existed. It insists on deleting something: a fixture that silently stopped
// leaving rows behind would leave the backfill with nothing to do and every
// assertion below passing for the wrong reason.
func forgetRecallRows(t *testing.T, stateDir string) {
	t.Helper()
	db := backfillTestDatabase(t, stateDir)
	defer db.Close()
	result, err := db.Exec(`DELETE FROM episode_outcomes`)
	if err != nil {
		t.Fatal(err)
	}
	affected, err := result.RowsAffected()
	if err != nil {
		t.Fatal(err)
	}
	if affected == 0 {
		t.Fatal("the fixture left no recall rows to forget, so the backfill has nothing to rebuild")
	}
}

// pruneSlackInput deletes the originating row the way retention does on the
// operational horizon. Most backfilled episodes are in exactly this state,
// which is why the report has to say so.
func pruneSlackInput(t *testing.T, stateDir, inputID string) {
	t.Helper()
	db := backfillTestDatabase(t, stateDir)
	defer db.Close()
	if _, err := db.Exec(`DELETE FROM slack_inputs WHERE id = ?`, inputID); err != nil {
		t.Fatal(err)
	}
}

func countRecallRows(t *testing.T, stateDir string) int {
	t.Helper()
	db := backfillTestDatabase(t, stateDir)
	defer db.Close()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM episode_outcomes`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	return count
}

// reportedCount reads one fingerprint-source line out of the human report, so
// the assertion is on the number an operator actually reads rather than on the
// struct behind it or on the column widths.
func reportedCount(t *testing.T, report, source string) int {
	t.Helper()
	for _, line := range strings.Split(report, "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] == source {
			count, err := strconv.Atoi(fields[1])
			if err != nil {
				t.Fatalf("fingerprint line %q carries no count: %v", line, err)
			}
			return count
		}
	}
	t.Fatalf("the report never names the %q fingerprint source:\n%s", source, report)
	return 0
}

func runBackfill(t *testing.T, args ...string) string {
	t.Helper()
	var stdout, stderr bytes.Buffer
	if err := runBackfillOutcomes(args, &stdout, &stderr); err != nil {
		t.Fatalf("backfill-outcomes failed: %v\n%s", err, stderr.String())
	}
	return stdout.String()
}

// A backfilled corpus is mostly fallback by construction: retention has already
// deleted the slack_inputs row for most finished episodes, so the projection
// rebuilds their fingerprint from the 180-byte truncated objective instead of
// from what the operator wrote. That is a materially weaker recall source, and
// a report that gave a single row count would hide it entirely — the corpus
// would look four hundred rows strong while most of those rows can only match
// on vocabulary the incident never contained.
func TestBackfillNamesTheFingerprintSourceOfEveryRowItWrites(t *testing.T) {
	configPath, stateDir := writeInspectionConfig(t)
	st, err := store.Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	kept := finishedEpisodeAwaitingOutcome(t, st, "CKEPT")
	pruned := finishedEpisodeAwaitingOutcome(t, st, "CPRUNED")
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	forgetRecallRows(t, stateDir)
	pruneSlackInput(t, stateDir, "input-CPRUNED")

	report := runBackfill(t, "--config", configPath)

	if got := reportedCount(t, report, intelligencestore.FingerprintFromTrigger); got != 1 {
		t.Errorf("report counts %d rows from the real trigger text, want 1:\n%s", got, report)
	}
	if got := reportedCount(t, report, intelligencestore.FingerprintFromObjective); got != 1 {
		t.Errorf("report counts %d rows from the truncated objective, want 1:\n%s", got, report)
	}
	// The number is useless to an operator who is not told what it means.
	for _, required := range []string{"180 bytes", "weaker than the"} {
		if !strings.Contains(report, required) {
			t.Errorf("the report never says %q, so nothing tells a reader that a\n"+
				"fallback row is a weaker recall source:\n%s", required, report)
		}
	}

	reopened, err := store.Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	ctx := context.Background()
	keptOutcome, err := reopened.Intelligence.GetEpisodeOutcome(ctx, kept.ID)
	if err != nil {
		t.Fatalf("the episode with a surviving Slack input was not backfilled: %v", err)
	}
	if keptOutcome.FingerprintSource != intelligencestore.FingerprintFromTrigger {
		t.Errorf("fingerprint source = %q, want the real trigger text",
			keptOutcome.FingerprintSource)
	}
	if !strings.Contains(keptOutcome.SymptomFingerprint, "payments") {
		t.Errorf("symptom fingerprint = %q, want the words the operator wrote",
			keptOutcome.SymptomFingerprint)
	}
	prunedOutcome, err := reopened.Intelligence.GetEpisodeOutcome(ctx, pruned.ID)
	if err != nil {
		t.Fatalf("the episode whose Slack input retention removed was not backfilled: %v", err)
	}
	if prunedOutcome.FingerprintSource != intelligencestore.FingerprintFromObjective {
		t.Errorf("fingerprint source = %q, want the truncated objective it had to settle for",
			prunedOutcome.FingerprintSource)
	}
}

// --json is what a corpus audit reads, so it carries the same breakdown rather
// than a total that cannot be measured against anything.
func TestBackfillJSONCarriesTheSameFingerprintBreakdown(t *testing.T) {
	configPath, stateDir := writeInspectionConfig(t)
	st, err := store.Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	finishedEpisodeAwaitingOutcome(t, st, "CKEPT")
	finishedEpisodeAwaitingOutcome(t, st, "CPRUNED")
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	forgetRecallRows(t, stateDir)
	pruneSlackInput(t, stateDir, "input-CPRUNED")

	var report backfillOutcomesReport
	encoded := runBackfill(t, "--config", configPath, "--json")
	if err := json.Unmarshal([]byte(encoded), &report); err != nil {
		t.Fatalf("--json is not valid JSON: %v\n%s", err, encoded)
	}
	if report.Examined != 2 || report.Projected != 2 || report.Failed != 0 {
		t.Fatalf("report = %+v", report)
	}
	if report.FingerprintSource[intelligencestore.FingerprintFromTrigger] != 1 ||
		report.FingerprintSource[intelligencestore.FingerprintFromObjective] != 1 {
		t.Fatalf("fingerprint sources = %v", report.FingerprintSource)
	}
	if report.FallbackRows != 1 {
		t.Fatalf("fallback rows = %d, want the one row that lost its trigger text",
			report.FallbackRows)
	}
}

// A dry run that writes is worse than no dry run: an operator asks it what a
// backfill would do to a production corpus precisely because they are not ready
// to change one yet. The preview is produced by running the real projection
// against a private copy, so the assertion that matters is that the deployed
// database still has no row afterwards.
func TestADryRunPreviewsTheBackfillWithoutWritingARow(t *testing.T) {
	configPath, stateDir := writeInspectionConfig(t)
	st, err := store.Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	episode := finishedEpisodeAwaitingOutcome(t, st, "CKEPT")
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	forgetRecallRows(t, stateDir)

	report := runBackfill(t, "--config", configPath, "--dry-run")

	if got := reportedCount(t, report, intelligencestore.FingerprintFromTrigger); got != 1 {
		t.Errorf("dry run counts %d rows from the real trigger text, want 1:\n%s", got, report)
	}
	if !strings.Contains(report, "Would write") || !strings.Contains(report, "Dry run") {
		t.Errorf("the dry run does not say it wrote nothing:\n%s", report)
	}
	if rows := countRecallRows(t, stateDir); rows != 0 {
		t.Fatalf("a dry run wrote %d recall rows to the deployed database", rows)
	}
	reopened, err := store.Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if _, err := reopened.Intelligence.GetEpisodeOutcome(context.Background(), episode.ID); err == nil {
		t.Fatal("a dry run projected the episode into the deployed database")
	}
}

// The preview must count the same episodes the real run will, and the two read
// the database by different routes: the real run opens the deployed state
// directory, the preview opens a copy of it.
//
// The store runs PRAGMA journal_mode = WAL, so on a database that has not
// checkpointed — a live deployment, or one whose process died — everything
// committed recently is in responder.db-wal and none of it is in responder.db.
// A copy of the main file alone is a stale snapshot, and the first version of
// this command took exactly that copy: the dry run reported zero episodes to
// backfill against a database holding several hundred. Zero is the worst
// possible wrong answer here, because "nothing to backfill" and "already done"
// are the same sentence to whoever reads it, and the run the corpus is waiting
// for never happens.
func TestADryRunSeesEveryEpisodeARealRunWouldSee(t *testing.T) {
	configPath, stateDir := writeInspectionConfig(t)
	st, err := store.Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	finishedEpisodeAwaitingOutcome(t, st, "CKEPT")
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	// Held open on purpose for the rest of the test. While a connection is
	// open SQLite never checkpoints, so this DELETE stays in the write-ahead
	// log — which is the state every live deployment is in.
	uncheckpointed := backfillTestDatabase(t, stateDir)
	defer uncheckpointed.Close()
	if _, err := uncheckpointed.Exec(`DELETE FROM episode_outcomes`); err != nil {
		t.Fatal(err)
	}

	var preview backfillOutcomesReport
	encoded := runBackfill(t, "--config", configPath, "--dry-run", "--json")
	if err := json.Unmarshal([]byte(encoded), &preview); err != nil {
		t.Fatalf("--json is not valid JSON: %v\n%s", err, encoded)
	}
	var real backfillOutcomesReport
	encoded = runBackfill(t, "--config", configPath, "--json")
	if err := json.Unmarshal([]byte(encoded), &real); err != nil {
		t.Fatalf("--json is not valid JSON: %v\n%s", err, encoded)
	}
	if real.Examined != 1 || real.Projected != 1 {
		t.Fatalf("the real run did not see the uncheckpointed episode: %+v", real)
	}
	if preview.Examined != real.Examined || preview.Projected != real.Projected {
		t.Fatalf(
			"the preview promised %d rows and the real run wrote %d;\n"+
				"a preview taken from a stale copy is worse than no preview",
			preview.Projected, real.Projected,
		)
	}
	if preview.FingerprintSource[intelligencestore.FingerprintFromTrigger] !=
		real.FingerprintSource[intelligencestore.FingerprintFromTrigger] {
		t.Fatalf("preview sources %v, real sources %v",
			preview.FingerprintSource, real.FingerprintSource)
	}
}

// The backfill is an operational command with no bookkeeping of its own, so its
// only defence against being run twice — or against a first run that stopped at
// --limit — is that the rows it already wrote are no longer pending. Without
// that, a second run would rewrite every row in the corpus and reset the
// created_at an audit reads to tell backfilled history from live history.
func TestASecondBackfillFindsEveryRowAlreadyProjected(t *testing.T) {
	configPath, stateDir := writeInspectionConfig(t)
	st, err := store.Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	finishedEpisodeAwaitingOutcome(t, st, "CKEPT")
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
	forgetRecallRows(t, stateDir)

	first := runBackfill(t, "--config", configPath)
	if got := reportedCount(t, first, intelligencestore.FingerprintFromTrigger); got != 1 {
		t.Fatalf("the first run projected nothing:\n%s", first)
	}

	var report backfillOutcomesReport
	encoded := runBackfill(t, "--config", configPath, "--json")
	if err := json.Unmarshal([]byte(encoded), &report); err != nil {
		t.Fatalf("--json is not valid JSON: %v\n%s", err, encoded)
	}
	if report.Examined != 0 || report.Projected != 0 {
		t.Fatalf("a second backfill found work to do: %+v", report)
	}
	if rows := countRecallRows(t, stateDir); rows != 1 {
		t.Fatalf("the corpus holds %d rows after two backfills of one episode", rows)
	}
	human := runBackfill(t, "--config", configPath)
	if !strings.Contains(human, "nothing to backfill") {
		t.Errorf("a completed backfill does not say so plainly:\n%s", human)
	}
}

// Refusals an operator can hit by mistake, each of which would otherwise be
// read as a completed backfill: a mistyped --config pointing at a state
// directory with no deployment, a positional argument where a flag was meant,
// and a limit that selects nothing.
func TestBackfillRefusesWhatWouldLookLikeAnEmptyCorpus(t *testing.T) {
	configPath, _ := writeInspectionConfig(t)
	var stdout, stderr bytes.Buffer
	err := runBackfillOutcomes([]string{"--config", configPath}, &stdout, &stderr)
	if err == nil {
		t.Fatal("the backfill invented a deployment that does not exist")
	}
	if !strings.Contains(err.Error(), "no deployed database") {
		t.Errorf("a missing deployment reports %v, which does not say what is wrong", err)
	}
	for _, args := range [][]string{
		{"--config", configPath, "stray"},
		{"--config", configPath, "--limit", "0"},
	} {
		stdout.Reset()
		stderr.Reset()
		if err := runBackfillOutcomes(args, &stdout, &stderr); err == nil {
			t.Errorf("backfill accepted %v", args)
		}
	}
}
