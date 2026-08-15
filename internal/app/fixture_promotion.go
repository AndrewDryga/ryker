package app

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/evaluation"
	"github.com/AndrewDryga/responder/internal/store"
	"github.com/AndrewDryga/responder/internal/store/fixturepromotionstore"
)

// promotionWindow is the period the rate bound is measured over.
const promotionWindow = 7 * 24 * time.Hour

// promotionBatch bounds one sweep's reading of the approved queue.
const promotionBatch = 50

// fixturePromoter writes the corrections an operator kept into the corpus,
// without waiting for anyone to run a command.
//
// The review was never the bottleneck. An operator clicks Keep in App Home, and
// then `make promote-corrections` has to be run by hand in a checkout with a
// configuration — and that second step is the one that stopped happening: five
// learning loops, four of them ending in a human click, and three fixtures in
// the corpus for the whole life of the pipeline. Keeping is a judgement about a
// correction and is still human. Copying the kept thing into a file is not a
// judgement, and it is what this does.
//
// The double gate is preserved as far as a running host can honestly reach.
// Before a fixture is appended, the corpus is re-parsed with it in place — the
// same offline proof `make promote-corrections` gets from dev-check, which is
// what catches a case that will not decode, or a duplicate name that made the
// corpus reject the whole file after a gate had already passed. What a host
// cannot do is the credentialed half: replaying a fixture three times against
// the real model takes minutes and the maintenance lane cancels a work item at
// WorkerStallAfter, so `make eval-regressions` stays the gate that proves a
// promoted lesson still holds. A fixture that fails an offline check parks in
// quarantine and appears on the Decisions page rather than being retried every
// minute or dropped silently.
type fixturePromoter struct {
	cfg     config.Config
	store   *store.Store
	source  episodeSource
	corpus  string
	perWeek int
	log     *slog.Logger
}

// PromoteApprovedFixtures drains what the operator kept, up to the week's bound.
func (p *fixturePromoter) PromoteApprovedFixtures(ctx context.Context, now time.Time) error {
	if p.perWeek <= 0 || strings.TrimSpace(p.corpus) == "" {
		return nil
	}
	spent, err := p.store.FixturePromotions.PromotedSince(ctx, now.Add(-promotionWindow))
	if err != nil {
		return err
	}
	remaining := p.perWeek - spent
	if remaining <= 0 {
		return nil
	}
	approved, err := p.store.FixturePromotions.Unsettled(ctx, promotionBatch)
	if err != nil {
		return err
	}
	if len(approved) == 0 {
		return nil
	}
	// Already-promoted episodes are recognised by the source reference each
	// fixture carries, exactly as the command does. Two corrections routinely
	// land on one episode, and one episode replays once.
	present, err := promotedEpisodes(p.corpus)
	if err != nil {
		return err
	}
	for _, candidate := range approved {
		if remaining <= 0 {
			return nil
		}
		if err := ctx.Err(); err != nil {
			return nil
		}
		// An episode already in the corpus needs no receipt to be recognised,
		// and must not get one that says it failed: a process that died between
		// the corpus write and the receipt comes back to a fixture it cannot
		// tell from a duplicate.
		if present[candidate.EpisodeID] {
			continue
		}
		promoted, err := p.promoteOne(ctx, candidate, now)
		if err != nil {
			return err
		}
		if promoted {
			present[candidate.EpisodeID] = true
			remaining--
		}
	}
	return nil
}

// promoteOne builds one fixture, checks it, and writes it down — or records why
// it did not.
//
// The corpus is appended before the receipt is written. A process that dies
// between the two writes the same receipt on the next sweep and appends
// nothing, because the episode is by then in the corpus; the receipt insert is
// keyed on the candidate, so it stores once either way. The other order would
// lose the fixture: a receipt saying promoted with nothing in the corpus is a
// lesson nobody replays and nobody can find.
func (p *fixturePromoter) promoteOne(
	ctx context.Context,
	candidate core.FixtureCandidate,
	now time.Time,
) (bool, error) {
	fixture, err := buildPromotedFixture(ctx, p.source, p.cfg, candidate, io.Discard)
	if err != nil {
		return false, p.quarantine(ctx, candidate, now,
			fmt.Sprintf("the episode could not be recorded: %v", err))
	}
	encoded, err := json.Marshal(fixture)
	if err != nil {
		return false, p.quarantine(ctx, candidate, now,
			fmt.Sprintf("the fixture could not be encoded: %v", err))
	}
	if rejection := corpusRejection(p.corpus, string(encoded)); rejection != "" {
		return false, p.quarantine(ctx, candidate, now, rejection)
	}
	if err := appendCorpusLines(p.corpus, []string{string(encoded)}); err != nil {
		return false, err
	}
	p.log.Info(
		"promoted a kept correction into the regression corpus",
		"candidate", candidate.ID, "episode", candidate.EpisodeID,
		"class", candidate.CorrectionClass, "corpus", p.corpus,
	)
	return true, p.store.FixturePromotions.Record(
		ctx, candidate.ID, candidate.EpisodeID,
		fixturepromotionstore.OutcomePromoted, fixture.Name, now,
	)
}

func (p *fixturePromoter) quarantine(
	ctx context.Context,
	candidate core.FixtureCandidate,
	now time.Time,
	reason string,
) error {
	p.log.Warn(
		"a kept correction was held back from the regression corpus",
		"candidate", candidate.ID, "episode", candidate.EpisodeID, "reason", reason,
	)
	return p.store.FixturePromotions.Record(
		ctx, candidate.ID, candidate.EpisodeID,
		fixturepromotionstore.OutcomeQuarantined, reason, now,
	)
}

// corpusRejection reports why the corpus would refuse this fixture, or "".
//
// This is the offline half of the promotion gate, run before the write rather
// than after it. `make promote-corrections` learned the same lesson the
// expensive way: promotion appended two fixtures for one episode, the corpus
// validator rejected the file as a duplicate case name, and the gate that had
// been green before promotion was now red for a reason that had nothing to do
// with the product.
//
// Duplicate names are found by comparing what the corpus parsed to what it
// aggregated: replay evaluates every case exactly once, so a corpus whose case
// count is under its total has two cases answering to one name.
func corpusRejection(corpus string, line string) string {
	existing, err := os.ReadFile(corpus)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Sprintf("the corpus could not be read: %v", err)
	}
	candidate := string(existing)
	if candidate != "" && !strings.HasSuffix(candidate, "\n") {
		candidate += "\n"
	}
	summary, err := evaluation.EvaluateJSONL(strings.NewReader(candidate + line + "\n"))
	if err != nil {
		return fmt.Sprintf("the corpus would not parse with it: %v", err)
	}
	if len(summary.Cases) < summary.Total {
		return "another case in the corpus already answers to this name"
	}
	return ""
}

// newFixturePromoter installs the drain when this deployment can actually
// perform it, and reports nothing when it cannot.
//
// The corpus is not a configured path. It is a file inside Responder's own
// repository, and a deployment either has that checkout configured or does not
// — so the checkout to write into is whichever configured repository contains
// the corpus. That makes auto-promotion impossible to point at the wrong tree,
// and it needs no setting whose only correct value is one path on one machine.
func newFixturePromoter(
	cfg config.Config,
	st *store.Store,
	logger *slog.Logger,
) *fixturePromoter {
	if cfg.Limits.MaxAutoPromotedFixturesPerWeek <= 0 {
		return nil
	}
	corpus := configuredRegressionCorpus(cfg)
	if corpus == "" {
		return nil
	}
	if logger == nil {
		logger = slog.Default()
	}
	return &fixturePromoter{
		cfg:     cfg,
		store:   st,
		source:  storeEpisodeSource{store: st},
		corpus:  corpus,
		perWeek: cfg.Limits.MaxAutoPromotedFixturesPerWeek,
		log:     logger,
	}
}

func configuredRegressionCorpus(cfg config.Config) string {
	for _, name := range cfg.RepositoryContextKeys() {
		repository, ok := cfg.RepositoryContext(name)
		if !ok || strings.TrimSpace(repository.Path) == "" {
			continue
		}
		corpus := filepath.Join(repository.Path, filepath.FromSlash(regressionCorpusPath))
		if info, err := os.Stat(corpus); err == nil && info.Mode().IsRegular() {
			return corpus
		}
	}
	return ""
}
