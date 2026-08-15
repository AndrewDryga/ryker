package service

import (
	"context"
	"strings"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/repomirror"
)

// prepareFetchTimeout bounds the on-demand fetch a turn pays for.
//
// Seconds, and a hard ceiling. The whole point of the maintenance lane is that
// the common case is already warm, so this only fires on a cold or lapsed
// clone — and when it does, an incident turn must not sit behind a git fetch of
// a large repository over a slow link. Past the deadline the turn runs against
// what is on disk and the manifest says so.
const prepareFetchTimeout = 8 * time.Second

// refreshRepositoryForTurn brings a managed clone current before a turn reads
// it, and degrades rather than blocks.
//
// A fetch failure is recorded staleness, never a blocked turn. GitHub being
// unreachable is not Responder failing to work, and an incident answered from
// twenty-minute-old code with the age written down is worth more than an
// incident not answered at all. Nothing here returns an error for that reason:
// there is no caller that should stop.
func (s *Service) refreshRepositoryForTurn(ctx context.Context, repositoryName string) {
	slug, ok := s.managedSlug(repositoryName)
	if !ok {
		return
	}
	// Already warm. The maintenance lane fetches on its own schedule, so the
	// ordinary turn pays nothing at all.
	if status := s.Mirrors.Inspect(ctx, slug); !status.Stale {
		return
	}
	fetchCtx, cancel := context.WithTimeout(ctx, prepareFetchTimeout)
	defer cancel()
	if _, err := s.Mirrors.Update(fetchCtx, slug); err != nil {
		s.log.Warn(
			"repository content is stale for this turn",
			"repository", repositoryName,
			"github", slug,
			"failure", string(repomirror.Classify(err)),
			"error", err,
		)
	}
}

// managedSlug reports the slug a repository context is managed under.
func (s *Service) managedSlug(repositoryName string) (string, bool) {
	if s.Mirrors == nil || strings.TrimSpace(repositoryName) == "" {
		return "", false
	}
	repository, ok := s.cfg.RepositoryContext(repositoryName)
	if !ok || !repository.Managed() {
		return "", false
	}
	return strings.TrimSpace(repository.GitHub), true
}

// repositoryFreshness is what the attempt's context manifest records about the
// code the model was about to read. An unmanaged repository records nothing,
// because nothing here knows anything about it.
func (s *Service) repositoryFreshness(
	ctx context.Context,
	repositoryName string,
) map[string]string {
	slug, ok := s.managedSlug(repositoryName)
	if !ok {
		return nil
	}
	return s.Mirrors.Freshness(ctx, slug).Metadata()
}

// fetchManagedRepositories refreshes every managed clone on the maintenance
// lane.
//
// Errors are swallowed on purpose, and this is the one place that decision has
// to be stated. The watchdog pages when due work stops moving; if a fetch
// failure retried the work item, a GitHub outage would present as Responder's
// scheduler failing and page a person at three in the morning about somebody
// else's incident. The failure is real and is reported — as a gauge on
// /metrics, a line in doctor, a warning in the log, and recorded staleness on
// every manifest written while it lasts — through channels that describe
// degraded evidence rather than stalled work.
func (s *Service) fetchManagedRepositories(ctx context.Context) {
	if s.Mirrors == nil {
		return
	}
	for _, slug := range repomirror.Slugs(s.cfg) {
		if ctx.Err() != nil {
			return
		}
		// Skip what is already current, and skip it cheaply — one stat of a
		// file, no subprocess.
		//
		// This is also what keeps the sweep fair. The whole work item runs under
		// limits.worker_stall_after, two minutes by default, and one slow clone
		// can eat all of it; a loop that started from the top of the list every
		// cycle would then fetch the first repositories forever and never reach
		// the last, which on a thirteen-repository deployment means the bottom
		// of the alphabet is permanently stale. Skipping the fresh ones means
		// each cycle resumes where the deadline cut the previous one off.
		if status := s.Mirrors.Inspect(ctx, slug); !status.Stale {
			continue
		}
		fetchCtx, cancel := context.WithTimeout(ctx, maintenanceFetchTimeout)
		status, err := s.Mirrors.Update(fetchCtx, slug)
		cancel()
		if err != nil {
			s.log.Warn(
				"scheduled repository fetch failed; evidence from this repository is stale",
				"github", slug,
				"failure", string(repomirror.Classify(err)),
				"error", err,
			)
			continue
		}
		s.log.Debug(
			"managed repository is current",
			"github", slug, "revision", status.Revision, "branch", status.Branch,
		)
	}
}

// maintenanceFetchTimeout bounds one scheduled fetch. Generous compared with
// the prepare path — nobody is waiting — but well inside the work item's own
// stall deadline, so a repository whose host has stopped answering costs this
// sweep one minute rather than the whole lane's budget.
const maintenanceFetchTimeout = time.Minute

// ManagedRepositoryPath is the host path a session policy must name.
//
// The single resolution point for the whole product: config declares either a
// path or a slug, and this turns whichever it is into a directory. Nothing
// outside config and internal/repomirror constructs one, which is what keeps
// "Responder never accepts host paths from Slack or model output" true by
// construction rather than by review.
func ManagedRepositoryPath(cfg config.Config, repo config.Repository) (string, error) {
	return repomirror.RepositoryPath(cfg.StateDir, repo)
}
