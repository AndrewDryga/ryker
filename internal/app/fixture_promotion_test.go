package app

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/store"
)

// episodesByID answers for a whole queue of candidates, each with its own
// objective, so a drained batch produces fixtures with distinct names the way a
// real one does.
type episodesByID map[string]fakeEpisodeSource

func (e episodesByID) GetWorkEpisode(
	ctx context.Context, episodeID string,
) (core.WorkEpisode, error) {
	source, ok := e[episodeID]
	if !ok {
		return core.WorkEpisode{}, fmt.Errorf("no episode %s", episodeID)
	}
	return source.GetWorkEpisode(ctx, episodeID)
}

func (e episodesByID) ListEpisodeEvents(
	ctx context.Context, episodeID string, limit int,
) ([]core.WorkEpisodeEvent, error) {
	return e[episodeID].ListEpisodeEvents(ctx, episodeID, limit)
}

func (e episodesByID) ListEpisodeEvidence(
	ctx context.Context, episodeID string, limit int,
) ([]core.Evidence, error) {
	return e[episodeID].ListEpisodeEvidence(ctx, episodeID, limit)
}

func (e episodesByID) GetAgentRun(
	ctx context.Context, runID string,
) (core.AgentRun, error) {
	for _, source := range e {
		if source.run.ID == runID {
			return source.GetAgentRun(ctx, runID)
		}
	}
	return core.AgentRun{}, fmt.Errorf("no run %s", runID)
}

func (e episodesByID) GetSlackInput(
	ctx context.Context, inputID string,
) (core.SlackInput, error) {
	for _, source := range e {
		if source.input.ID == inputID {
			return source.GetSlackInput(ctx, inputID)
		}
	}
	return core.SlackInput{}, fmt.Errorf("no input %s", inputID)
}

func promotableEpisode(index int) fakeEpisodeSource {
	source := recordingFixtureSource("none")
	source.episode.ID = fmt.Sprintf("ep_%d", index)
	source.episode.Objective = fmt.Sprintf("assess rollout %d", index)
	source.episode.AgentRunID = fmt.Sprintf("run_%d", index)
	source.run.ID = source.episode.AgentRunID
	source.run.SourceID = fmt.Sprintf("slack_message_%d", index)
	source.input.ID = source.run.SourceID
	source.input.Text = fmt.Sprintf(
		"%s (episode %d)", recordingTriggerText, index,
	)
	return source
}

// promotionFixture builds a drain over a real database, a real corpus file, and
// a queue of approved corrections.
//
// The probe reads the receipts the way the control plane does — a second
// connection to the same file — because the promotion receipts are audit rows
// and audit rows are read by a reader that is not this store.
func promotionFixture(
	t *testing.T, candidates int,
) (*fixturePromoter, *store.Store, string, *sql.DB) {
	t.Helper()
	stateDir := filepath.Join(t.TempDir(), "state")
	st, err := store.Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	probe, err := sql.Open("sqlite", filepath.Join(stateDir, "responder.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { probe.Close() })
	ctx := context.Background()
	sources := episodesByID{}
	for index := 1; index <= candidates; index++ {
		source := promotableEpisode(index)
		sources[source.episode.ID] = source
		if err := st.RecordFixtureCandidate(ctx, core.FixtureCandidate{
			EpisodeID:       source.episode.ID,
			RunID:           source.run.ID,
			Capability:      "mentions-dms-and-proactive-messages",
			CorrectionClass: "incomplete",
			Correction:      "the reply claimed healthy without fresh evidence",
		}); err != nil {
			t.Fatal(err)
		}
	}
	pending, err := st.ListPendingFixtureCandidates(ctx, time.Now().UTC(), 100)
	if err != nil {
		t.Fatal(err)
	}
	for _, candidate := range pending {
		if err := st.ReviewFixtureCandidate(ctx, candidate.ID, "approved", "U_OPERATOR"); err != nil {
			t.Fatal(err)
		}
	}
	corpus := filepath.Join(t.TempDir(), "regressions.jsonl")
	if err := os.WriteFile(corpus, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	return &fixturePromoter{
		cfg: config.Config{}, store: st, source: sources, corpus: corpus,
		perWeek: 5, log: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}, st, corpus, probe
}

func corpusNames(t *testing.T, corpus string) []string {
	t.Helper()
	data, err := os.ReadFile(corpus)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var fixture struct {
			Name string `json:"name"`
		}
		if err := json.Unmarshal([]byte(line), &fixture); err != nil {
			t.Fatalf("corpus line does not decode: %v\n%s", err, line)
		}
		names = append(names, fixture.Name)
	}
	return names
}

// A kept correction reaches the corpus without anyone running a command, and
// reaches it exactly once.
//
// This is the whole slice. The pipeline produced three fixtures in its life
// because promotion needed `make promote-corrections` run by hand in a checkout
// after the operator had already clicked Keep, and that second step is the one
// that stopped happening. Once is the other half: the sweep runs every minute,
// so a drain that could not tell an already-promoted candidate from a new one
// would write the same lesson sixty times an hour and make every pass rate in
// the corpus a lie.
func TestAKeptCorrectionReachesTheCorpusWithoutACommand(t *testing.T) {
	promoter, _, corpus, _ := promotionFixture(t, 1)
	ctx := context.Background()
	now := time.Now().UTC()
	if err := promoter.PromoteApprovedFixtures(ctx, now); err != nil {
		t.Fatal(err)
	}
	names := corpusNames(t, corpus)
	if len(names) != 1 || !strings.Contains(names[0], "assess rollout 1") {
		t.Fatalf("the kept correction did not reach the corpus: %v", names)
	}
	if err := promoter.PromoteApprovedFixtures(ctx, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if again := corpusNames(t, corpus); len(again) != 1 {
		t.Fatalf("the next sweep promoted it again: %v", again)
	}
}

// A restart inside the week does not re-promote what the corpus already holds.
//
// The receipt and the corpus are two writes, and a process that dies between
// them must not produce a second fixture — nor must a corpus that was reverted
// by hand leave the candidate unreachable forever. Both are exercised here: the
// receipt is dropped as though the crash happened before it was written, and
// the corpus alone has to be enough to recognise the episode.
func TestARestartInsideTheWeekDoesNotPromoteTwice(t *testing.T) {
	promoter, st, corpus, probe := promotionFixture(t, 1)
	ctx := context.Background()
	now := time.Now().UTC()
	if err := promoter.PromoteApprovedFixtures(ctx, now); err != nil {
		t.Fatal(err)
	}
	approved, err := st.ListApprovedFixtureCandidates(ctx, 10)
	if err != nil || len(approved) != 1 {
		t.Fatalf("approved candidates = %v, %v", approved, err)
	}
	unsettled, err := st.FixturePromotions.Unsettled(ctx, 10)
	if err != nil || len(unsettled) != 0 {
		t.Fatalf("the promoted candidate is still unanswered: %v, %v", unsettled, err)
	}

	// The same drain, rebuilt the way a restarted process would rebuild it, and
	// with the receipt gone.
	if _, err := probe.ExecContext(ctx, `DELETE FROM audit_events`); err != nil {
		t.Fatal(err)
	}
	restarted := *promoter
	if err := restarted.PromoteApprovedFixtures(ctx, now.Add(2*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if names := corpusNames(t, corpus); len(names) != 1 {
		t.Fatalf("a restart promoted the same correction again: %v", names)
	}
	// And it was recognised rather than rejected. A drain that could not see its
	// own fixture in the corpus would rebuild it, find its name taken, and file
	// a quarantine against a lesson that is already kept — which reads on the
	// Decisions page as a failure that never happened.
	var quarantines int
	if err := probe.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM audit_events
		WHERE kind = 'fixture.promotion' AND outcome = 'quarantined'`,
	).Scan(&quarantines); err != nil {
		t.Fatal(err)
	}
	if quarantines != 0 {
		t.Fatalf("a restart quarantined a correction that is already in the corpus")
	}
}

// The week's budget bounds how much a release gate can grow unattended.
//
// The corpus is what a release is held to. Promotion that outruns the human
// reading its diffs turns the demotion review this is built around back into a
// rubber stamp, so the drain stops at the bound and picks up where it left off
// once the window has moved.
func TestThePromotionRateIsBoundedPerWeek(t *testing.T) {
	promoter, _, corpus, _ := promotionFixture(t, 7)
	promoter.perWeek = 5
	ctx := context.Background()
	now := time.Now().UTC()
	if err := promoter.PromoteApprovedFixtures(ctx, now); err != nil {
		t.Fatal(err)
	}
	if names := corpusNames(t, corpus); len(names) != 5 {
		t.Fatalf("the drain ignored its weekly bound: %d promoted", len(names))
	}
	if err := promoter.PromoteApprovedFixtures(ctx, now.Add(6*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if names := corpusNames(t, corpus); len(names) != 5 {
		t.Fatalf("the bound reset before the window did: %d promoted", len(names))
	}
	if err := promoter.PromoteApprovedFixtures(ctx, now.Add(8*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if names := corpusNames(t, corpus); len(names) != 7 {
		t.Fatalf("the rest never arrived once the window moved: %d promoted", len(names))
	}
}

// An answered candidate stops taking up room in the queue the drain reads.
//
// A fixture candidate keeps its approved status forever — it records what an
// operator decided, not a position in a queue — so the settled ones accumulate
// at the front of every list ordered by age. A drain that read the oldest fifty
// and filtered afterwards would, once fifty had been answered, spend every
// sweep re-reading those fifty and never reach the fifty-first: the loop goes
// quiet with a full queue behind it and nothing anywhere says so. The receipt
// is part of the query for that reason, and this holds the limit against it.
func TestAnsweredCandidatesDoNotCrowdOutTheQueue(t *testing.T) {
	promoter, st, _, _ := promotionFixture(t, 7)
	ctx := context.Background()
	promoter.perWeek = 5
	if err := promoter.PromoteApprovedFixtures(ctx, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	// Room for five, five of them answered: what comes back must be the two
	// nobody has decided about, not the five that are done.
	waiting, err := st.FixturePromotions.Unsettled(ctx, 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(waiting) != 2 {
		t.Fatalf("the answered candidates still fill the queue: %d waiting", len(waiting))
	}
	for _, candidate := range waiting {
		if candidate.EpisodeID != "ep_6" && candidate.EpisodeID != "ep_7" {
			t.Errorf("an already-answered candidate is still queued: %+v", candidate)
		}
	}
}

// A fixture the corpus would refuse is quarantined, not appended.
//
// promote-corrections learned this expensively: two corrections on one episode
// wrote two fixtures with one name, the corpus validator rejected the whole
// file, and a gate that had been green before promotion was red for a reason
// that had nothing to do with the product. The drain checks the corpus with the
// fixture in it before writing, and a rejected fixture parks with its reason
// where the Decisions page can show it rather than being retried every minute
// or dropped in a log line.
func TestAFixtureTheCorpusWouldRefuseIsQuarantined(t *testing.T) {
	promoter, st, corpus, probe := promotionFixture(t, 1)
	ctx := context.Background()
	now := time.Now().UTC()
	approved, err := st.ListApprovedFixtureCandidates(ctx, 10)
	if err != nil || len(approved) != 1 {
		t.Fatalf("approved candidates = %v, %v", approved, err)
	}
	// A case already answering to the name this fixture will take, filed under
	// a different episode so the source reference cannot recognise it.
	existing, err := json.Marshal(map[string]any{
		"name": "assess rollout 1", "kind": "watch",
		"tags":  []string{"episode-replay", "source:episode/ep_other"},
		"input": "an unrelated question",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(corpus, append(existing, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := promoter.PromoteApprovedFixtures(ctx, now); err != nil {
		t.Fatal(err)
	}
	if names := corpusNames(t, corpus); len(names) != 1 {
		t.Fatalf("a fixture the corpus would refuse was written anyway: %v", names)
	}
	var outcome, detail string
	if err := probe.QueryRowContext(ctx, `
		SELECT outcome, detail FROM audit_events WHERE kind = 'fixture.promotion'`,
	).Scan(&outcome, &detail); err != nil {
		t.Fatalf("no quarantine was recorded: %v", err)
	}
	if outcome != "quarantined" || !strings.Contains(detail, "already answers to this name") {
		t.Fatalf("quarantine = %q, %q", outcome, detail)
	}
	promoted, err := st.FixturePromotions.PromotedSince(ctx, now.Add(-time.Hour))
	if err != nil || promoted != 0 {
		t.Fatalf("a quarantine spent the week's budget: %d, %v", promoted, err)
	}
	// Quarantine is terminal for the automation. Even with the conflict gone —
	// somebody edited the corpus, or a rebase took the other case away — the
	// candidate waits for a human rather than promoting itself on the next
	// sweep, which is a minute away. A quarantine nothing has to answer for is
	// just a retry loop with a record of every attempt.
	if err := os.WriteFile(corpus, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := promoter.PromoteApprovedFixtures(ctx, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if names := corpusNames(t, corpus); len(names) != 0 {
		t.Fatalf("a quarantined candidate promoted itself once the conflict cleared: %v", names)
	}
	var receipts int
	if err := probe.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM audit_events WHERE kind = 'fixture.promotion'`,
	).Scan(&receipts); err != nil {
		t.Fatal(err)
	}
	if receipts != 1 {
		t.Fatalf("a quarantined candidate was retried: %d receipts", receipts)
	}
}

// An episode that cannot be rebuilt is quarantined rather than retried forever.
//
// recordEpisodeFixture refuses an episode whose trigger text cannot be
// recovered, because a fixture recorded without it asks half a question. The
// candidate stays approved and the drain sees it on every sweep, so without a
// receipt this is a log line once a minute and a lesson nobody is told is lost.
func TestAnEpisodeThatCannotBeRebuiltIsQuarantined(t *testing.T) {
	promoter, _, corpus, probe := promotionFixture(t, 1)
	ctx := context.Background()
	broken := promotableEpisode(1)
	broken.input.Text = ""
	broken.input.ActionID = ""
	promoter.source = episodesByID{broken.episode.ID: broken}

	if err := promoter.PromoteApprovedFixtures(ctx, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if names := corpusNames(t, corpus); len(names) != 0 {
		t.Fatalf("an unrecordable episode reached the corpus: %v", names)
	}
	var outcome, detail string
	if err := probe.QueryRowContext(ctx, `
		SELECT outcome, detail FROM audit_events WHERE kind = 'fixture.promotion'`,
	).Scan(&outcome, &detail); err != nil {
		t.Fatalf("no quarantine was recorded: %v", err)
	}
	if outcome != "quarantined" || !strings.Contains(detail, "could not be recorded") {
		t.Fatalf("quarantine = %q, %q", outcome, detail)
	}
}

// The drain installs itself only where it could actually write.
//
// The corpus is a file in Responder's own checkout, not a configured path, so a
// deployment either has that repository configured or has no business promoting
// anything. Getting this wrong in the other direction would be worse than the
// manual step it replaces: a drain pointed at a path that happens to exist
// would append fixtures into someone else's repository.
func TestTheDrainOnlyRunsWhereTheCorpusLives(t *testing.T) {
	st, err := store.Open(filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	checkout := t.TempDir()
	var cfg config.Config
	cfg.Limits.MaxAutoPromotedFixturesPerWeek = 5
	cfg.Repositories = map[string]config.Repository{
		"elsewhere": {Path: t.TempDir()},
		"responder": {Path: checkout},
	}
	if promoter := newFixturePromoter(cfg, st, logger); promoter != nil {
		t.Fatalf("the drain installed itself with no corpus anywhere: %s", promoter.corpus)
	}

	corpus := filepath.Join(checkout, filepath.FromSlash(regressionCorpusPath))
	if err := os.MkdirAll(filepath.Dir(corpus), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(corpus, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	promoter := newFixturePromoter(cfg, st, logger)
	if promoter == nil || promoter.corpus != corpus {
		t.Fatalf("the drain did not find the corpus in the configured checkout: %+v", promoter)
	}

	cfg.Limits.MaxAutoPromotedFixturesPerWeek = 0
	if off := newFixturePromoter(cfg, st, logger); off != nil {
		t.Fatal("a rate of zero still installed the drain")
	}
}
