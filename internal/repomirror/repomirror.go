// Package repomirror keeps the repositories Responder reads from current.
//
// Before it existed there was no `git fetch` anywhere in this product — not in
// Go, not in a script. Every policy repository was a directory an operator had
// cloned by hand and was expected to pull by hand, so "current repository
// content", which the evidence hierarchy ranks second and above configuration
// and confirmed memory, actually meant "content as of whenever a human last
// remembered". On the operator's machine that was 88 GB across 426 git
// directories and nobody's job.
//
// What this does NOT change is the security property the local checkout was
// for: the agent box reads code with no GitHub credential inside it. Coop still
// forks from a local directory. The token stays host-side and reaches git the
// way internal/publisher already sends it — as a per-invocation HTTP header,
// never a file, never an argument, never anything projected into a box or
// written into a Coop policy.
//
// Plain clones, not bare mirrors. Coop's session service validates a policy
// repository with realGitRepository: the EvalSymlinks-real path must equal
// `rev-parse --show-toplevel`. A bare repository has no work tree and fails
// that, and companion snapshots assume a work tree too. So these are ordinary
// clones — just Responder-owned and Responder-fetched.
//
// Full clones, not --filter=blob:none. A partial clone needs network and
// credentials at read time, inside the box, which is precisely the property
// this package must not create.
package repomirror

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/hermeticgit"
)

// FailureClass names why an update did not happen, because the four answers
// need four different responses: a person signs in, a network heals itself, a
// missing repository is a configuration error, and corruption is repaired by
// throwing the directory away.
type FailureClass string

const (
	FailureNone    FailureClass = ""
	FailureAuth    FailureClass = "auth"
	FailureNetwork FailureClass = "network"
	FailureMissing FailureClass = "missing"
	FailureCorrupt FailureClass = "corrupt"
	// FailureLocal is the clone itself refusing: a dirty work tree, a
	// non-fast-forward, a permission problem. Responder never resolves one of
	// these by writing to the work tree.
	FailureLocal FailureClass = "local"
)

// Error carries the classification with the detail, so a caller can decide
// without parsing git's prose a second time.
type Error struct {
	Class  FailureClass
	Slug   string
	Detail string
}

func (e *Error) Error() string {
	return fmt.Sprintf("%s clone %s: %s", e.Slug, e.Class, e.Detail)
}

// Classify reports the failure class of err, or FailureNone.
func Classify(err error) FailureClass {
	var failure *Error
	if errors.As(err, &failure) {
		return failure.Class
	}
	return FailureNone
}

// Status is everything Responder knows about one managed clone.
//
// FetchedAt comes from the clone itself rather than from memory, so `responder
// doctor` in a second process answers the same question the serving process
// would. git writes FETCH_HEAD on every fetch and on clone, whether or not any
// object moved, which is exactly the "we asked the remote at this time" fact
// wanted here.
type Status struct {
	Slug      string
	Path      string
	Present   bool
	Revision  string
	Branch    string
	FetchedAt time.Time
	Stale     bool
	Failure   FailureClass
	Detail    string
}

// Metadata is what a context manifest records about the code a model read.
//
// It lives here rather than beside the manifest because these are this
// package's words: what "stale" means, which four things can go wrong, and
// where the fetch time comes from. A manifest that spelled them itself would be
// a second definition of freshness, drifting from the one that measures it.
//
// The revision alone was never enough. A commit id looks equally current
// whether the checkout behind it was refreshed a minute ago or last month, and
// before Responder owned the clone nothing anywhere knew which — so "how old
// was the code the model read" was unanswerable on every trace ever recorded.
func (s Status) Metadata() map[string]string {
	metadata := map[string]string{
		"managed_repository": s.Slug,
		"mirror_revision":    s.Revision,
		"mirror_freshness":   "fresh",
	}
	if !s.FetchedAt.IsZero() {
		metadata["mirror_fetched_at"] = s.FetchedAt.UTC().Format(time.RFC3339)
	}
	if s.Stale {
		metadata["mirror_freshness"] = "stale"
	}
	if s.Failure != FailureNone {
		metadata["mirror_stale_reason"] = string(s.Failure)
		metadata["mirror_stale_detail"] = core.TruncateUTF8(s.Detail, 300)
	}
	return metadata
}

// Freshness is what Inspect knows plus what only the last attempt knows.
//
// A clone on disk looks identical whether its last fetch succeeded or the
// credential expired three hours ago, so the recorded failure has to be laid
// over the filesystem reading or a manifest would call stale evidence fresh.
func (m *Manager) Freshness(ctx context.Context, slug string) Status {
	status := m.Inspect(ctx, slug)
	if last, recorded := m.Last(slug); recorded && last.Failure != FailureNone {
		status.Failure, status.Detail, status.Stale = last.Failure, last.Detail, true
	}
	return status
}

// TokenSource yields the GitHub credential for one invocation.
type TokenSource func(context.Context) (string, error)

// Manager owns every managed clone under one root.
//
// One per root, deliberately. The root lives under the state directory, which
// already carries a single-process flock, and two managers over one root would
// be two things cloning, fetching and swapping the same directories. Two
// deployments get two roots; resist a shared cross-deployment cache, because
// disk is cheaper than coupling two instances' evidence.
type Manager struct {
	root      string
	token     TokenSource
	remoteURL func(slug string) string
	now       func() time.Time
	log       *slog.Logger
	staleFor  time.Duration

	mu    sync.Mutex
	last  map[string]Status
	locks map[string]*sync.Mutex
}

type Option func(*Manager)

// WithToken sets where the GitHub credential comes from. Absent one, a clone of
// a public repository still works and a private one fails as auth.
func WithToken(source TokenSource) Option {
	return func(m *Manager) { m.token = source }
}

// WithRemoteURL redirects clones at a local fixture. Tests use it; nothing in
// production does, and no Slack or model input can reach it.
func WithRemoteURL(remote func(slug string) string) Option {
	return func(m *Manager) { m.remoteURL = remote }
}

func WithClock(now func() time.Time) Option {
	return func(m *Manager) { m.now = now }
}

func WithLogger(log *slog.Logger) Option {
	return func(m *Manager) {
		if log != nil {
			m.log = log
		}
	}
}

// Root is the directory Responder keeps managed clones in.
func Root(stateDir string) string { return filepath.Join(stateDir, "repos") }

// New builds the manager for one configuration.
func New(cfg config.Config, log *slog.Logger, opts ...Option) *Manager {
	manager := &Manager{
		root:      Root(cfg.StateDir),
		remoteURL: func(slug string) string { return "https://github.com/" + slug + ".git" },
		now:       time.Now,
		log:       slog.Default(),
		staleFor:  cfg.Limits.RepositoryFetchInterval.Duration,
		last:      make(map[string]Status),
		locks:     make(map[string]*sync.Mutex),
	}
	if manager.staleFor <= 0 {
		manager.staleFor = 15 * time.Minute
	}
	if log != nil {
		manager.log = log
	}
	for _, opt := range opts {
		opt(manager)
	}
	return manager
}

// Path is where a slug's clone belongs, whether or not it is there yet.
//
// The only construction of a repository directory in this product. Nothing
// outside config and this package builds one, which is what keeps the rule that
// no host path arrives from Slack or model output true by construction.
func Path(root, slug string) (string, error) {
	slug = strings.TrimSpace(slug)
	if !config.ValidGitHubRepository(slug) {
		return "", fmt.Errorf("%q is not an owner/name repository slug", slug)
	}
	owner, name, _ := strings.Cut(slug, "/")
	return filepath.Join(root, owner, name), nil
}

func (m *Manager) Path(slug string) (string, error) { return Path(m.root, slug) }

// RepositoryPath is the host path a Coop session policy must name for repo.
//
// Resolved through EvalSymlinks for a managed clone, because Coop compares the
// policy's path against `rev-parse --show-toplevel` on the REAL path and
// rejects an alias — a policy naming a symlink fails at session time with a
// message about neither the symlink nor the policy.
func RepositoryPath(stateDir string, repo config.Repository) (string, error) {
	if !repo.Managed() {
		return strings.TrimSpace(repo.Path), nil
	}
	path, err := Path(Root(stateDir), repo.GitHub)
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		// Before the first clone there is nothing to resolve. The unresolved
		// path is still the right answer to "where will it be", and it is what
		// a generated policy should name once the clone lands.
		if os.IsNotExist(err) {
			return path, nil
		}
		return "", fmt.Errorf("resolve managed clone for %s: %w", repo.GitHub, err)
	}
	return resolved, nil
}

// Slugs lists every managed repository in cfg, in a stable order.
func Slugs(cfg config.Config) []string {
	seen := make(map[string]struct{})
	var slugs []string
	for _, key := range cfg.RepositoryContextKeys() {
		repository, ok := cfg.RepositoryContext(key)
		if !ok || !repository.Managed() {
			continue
		}
		slug := strings.TrimSpace(repository.GitHub)
		if _, done := seen[slug]; done {
			continue
		}
		seen[slug] = struct{}{}
		slugs = append(slugs, slug)
	}
	return slugs
}

// StaleAfter is how long a clone may go unfetched before it is called stale.
func (m *Manager) StaleAfter() time.Duration { return m.staleFor }

// slugLock serializes work on one clone without serializing the others: a slow
// fetch of a large repository must not hold up a small one, but two goroutines
// cloning into the same directory would race the swap.
func (m *Manager) slugLock(slug string) *sync.Mutex {
	m.mu.Lock()
	defer m.mu.Unlock()
	lock, ok := m.locks[slug]
	if !ok {
		lock = &sync.Mutex{}
		m.locks[slug] = lock
	}
	return lock
}

func (m *Manager) record(status Status) Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.last[status.Slug] = status
	return status
}

// Last returns the outcome of the most recent attempt on slug.
func (m *Manager) Last(slug string) (Status, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	status, ok := m.last[slug]
	return status, ok
}

// FetchFailures counts the managed clones whose latest attempt did not succeed.
//
// A gauge, not a counter, and deliberately kept out of anything that reads as
// work movement: the watchdog pages when due work stops moving, and a GitHub
// outage is not Responder failing to work. A failed fetch degrades an
// attempt's evidence to "stale, recorded" and shows up here and in doctor.
func (m *Manager) FetchFailures() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	failures := 0
	for _, status := range m.last {
		if status.Failure != FailureNone {
			failures++
		}
	}
	return failures
}

// Inspect reads a clone from disk without touching the network.
func (m *Manager) Inspect(ctx context.Context, slug string) Status {
	status := Status{Slug: slug}
	path, err := m.Path(slug)
	if err != nil {
		status.Failure, status.Detail = FailureMissing, err.Error()
		return status
	}
	status.Path = path
	info, err := os.Stat(filepath.Join(path, ".git"))
	if err != nil || !info.IsDir() {
		// Stale, not fresh. A repository nothing has ever cloned has no current
		// content by definition, and reporting it as up to date is how "no
		// evidence" quietly becomes "no problem" on a doctor line and a gauge.
		status.Detail, status.Stale = "no managed clone yet", true
		return status
	}
	status.Present = true
	status.Revision = m.revision(ctx, path)
	status.Branch = m.branch(ctx, path)
	status.FetchedAt = fetchedAt(path)
	status.Stale = m.stale(status)
	return status
}

func (m *Manager) stale(status Status) bool {
	if !status.Present {
		return true
	}
	if status.FetchedAt.IsZero() {
		return true
	}
	return m.now().UTC().Sub(status.FetchedAt) > m.staleFor
}

// Ensure guarantees a clone exists, cloning it on first use.
func (m *Manager) Ensure(ctx context.Context, slug string) (Status, error) {
	lock := m.slugLock(slug)
	lock.Lock()
	defer lock.Unlock()
	return m.ensureLocked(ctx, slug)
}

func (m *Manager) ensureLocked(ctx context.Context, slug string) (Status, error) {
	path, err := m.Path(slug)
	if err != nil {
		status := Status{Slug: slug, Failure: FailureMissing, Detail: err.Error(), Stale: true}
		return m.record(status), &Error{Class: FailureMissing, Slug: slug, Detail: err.Error()}
	}
	if info, statErr := os.Stat(filepath.Join(path, ".git")); statErr == nil && info.IsDir() {
		return m.Inspect(ctx, slug), nil
	}
	if err := m.clone(ctx, slug, path); err != nil {
		return m.recordFailure(ctx, slug, err), err
	}
	return m.record(m.Inspect(ctx, slug)), nil
}

// Update brings a clone level with its remote's default branch.
//
// Fetch and fast-forward only. Responder never modifies the work tree and never
// discards anything found in it: a dirty clone is reported as a local failure
// and left exactly as it is, because the one thing worse than stale evidence is
// destroying work while trying to freshen it.
func (m *Manager) Update(ctx context.Context, slug string) (Status, error) {
	lock := m.slugLock(slug)
	lock.Lock()
	defer lock.Unlock()

	status, err := m.ensureLocked(ctx, slug)
	if err != nil {
		return status, err
	}
	path := status.Path
	if _, err := m.git(ctx, path, true, "fetch", "--prune", "--quiet", "origin"); err != nil {
		failure := m.wrap(slug, err)
		if failure.Class == FailureCorrupt {
			if repaired, repairErr := m.recloneLocked(ctx, slug, path); repairErr == nil {
				return repaired, nil
			}
		}
		return m.recordFailure(ctx, slug, failure), failure
	}
	branch := m.branch(ctx, path)
	if branch == "" {
		failure := &Error{
			Class: FailureCorrupt, Slug: slug,
			Detail: "the managed clone is on no branch",
		}
		if repaired, repairErr := m.recloneLocked(ctx, slug, path); repairErr == nil {
			return repaired, nil
		}
		return m.recordFailure(ctx, slug, failure), failure
	}
	// A clean tree is checked before the fast-forward rather than after a
	// failure, so the message names what is actually wrong. `git merge
	// --ff-only` on a dirty tree reports a conflict, which reads as a history
	// problem and is not one.
	//
	// Tracked files only. An untracked file cannot be lost by a fast-forward —
	// git refuses one that would overwrite it, which arrives here as a failure
	// with git's own explanation — and treating one as dirty would let a stray
	// .DS_Store or a build artifact freeze a repository's evidence at whatever
	// day it appeared, silently, forever.
	if dirty, err := m.git(
		ctx, path, false, "status", "--porcelain", "--untracked-files=no",
	); err != nil || strings.TrimSpace(dirty) != "" {
		detail := "the managed clone has uncommitted changes; Responder will not touch them"
		if err != nil {
			detail = err.Error()
		}
		failure := &Error{Class: FailureLocal, Slug: slug, Detail: detail}
		return m.recordFailure(ctx, slug, failure), failure
	}
	if _, err := m.git(
		ctx, path, false, "merge", "--ff-only", "--quiet", "origin/"+branch,
	); err != nil {
		failure := m.wrap(slug, err)
		if failure.Class == FailureNetwork {
			failure.Class = FailureLocal
		}
		return m.recordFailure(ctx, slug, failure), failure
	}
	return m.record(m.Inspect(ctx, slug)), nil
}

// DryRunFetch asks the remote whether Responder could fetch, without writing
// anything. Doctor uses it so a token that has expired is found before the next
// incident does.
func (m *Manager) DryRunFetch(ctx context.Context, slug string) error {
	path, err := m.Path(slug)
	if err != nil {
		return &Error{Class: FailureMissing, Slug: slug, Detail: err.Error()}
	}
	work := path
	if info, statErr := os.Stat(filepath.Join(path, ".git")); statErr != nil || !info.IsDir() {
		// No clone yet: ask from the root, which exists once anything is
		// managed, so a first-run doctor still proves the credential.
		if mkErr := m.ensureRoot(); mkErr != nil {
			return &Error{Class: FailureLocal, Slug: slug, Detail: mkErr.Error()}
		}
		work = m.root
	}
	if _, err := m.git(
		ctx, work, true, "ls-remote", "--heads", "--quiet", m.remoteURL(slug),
	); err != nil {
		return m.wrap(slug, err)
	}
	return nil
}

func (m *Manager) recordFailure(ctx context.Context, slug string, err error) Status {
	status := m.Inspect(ctx, slug)
	var failure *Error
	if errors.As(err, &failure) {
		status.Failure, status.Detail = failure.Class, failure.Detail
	} else {
		status.Failure, status.Detail = FailureNetwork, err.Error()
	}
	status.Stale = true
	m.log.Warn(
		"managed repository clone is stale",
		"repository", slug, "failure", string(status.Failure), "detail", status.Detail,
	)
	return m.record(status)
}

func (m *Manager) clone(ctx context.Context, slug, path string) error {
	if err := m.ensureRoot(); err != nil {
		return &Error{Class: FailureLocal, Slug: slug, Detail: err.Error()}
	}
	parent := filepath.Dir(path)
	if err := os.MkdirAll(parent, 0o700); err != nil {
		return &Error{Class: FailureLocal, Slug: slug, Detail: err.Error()}
	}
	// Clone beside and rename in, always. A clone interrupted halfway leaves a
	// directory that looks present and is not a repository, and the next run
	// would take it for one.
	staging, err := os.MkdirTemp(parent, "."+filepath.Base(path)+".cloning-*")
	if err != nil {
		return &Error{Class: FailureLocal, Slug: slug, Detail: err.Error()}
	}
	defer os.RemoveAll(staging)
	if err := os.Chmod(staging, 0o700); err != nil {
		return &Error{Class: FailureLocal, Slug: slug, Detail: err.Error()}
	}
	target := filepath.Join(staging, "clone")
	if _, err := m.git(
		ctx, staging, true, "clone", "--quiet", "--", m.remoteURL(slug), target,
	); err != nil {
		return m.wrap(slug, err)
	}
	if err := os.Rename(target, path); err != nil {
		return &Error{Class: FailureLocal, Slug: slug, Detail: err.Error()}
	}
	m.log.Info("cloned managed repository", "repository", slug, "path", path)
	return nil
}

// recloneLocked replaces a corrupt clone with a fresh one, atomically.
//
// Clone beside, rename the broken one out, rename the new one in. Coop may be
// forking from the old directory at this moment: on POSIX an open file survives
// its directory being renamed, so a fork in flight completes against the copy
// it started on rather than half of each.
func (m *Manager) recloneLocked(ctx context.Context, slug, path string) (Status, error) {
	retired := filepath.Join(
		filepath.Dir(path),
		"."+filepath.Base(path)+".corrupt-"+m.now().UTC().Format("20060102T150405"),
	)
	if err := os.Rename(path, retired); err != nil {
		failure := &Error{Class: FailureCorrupt, Slug: slug, Detail: err.Error()}
		return m.recordFailure(ctx, slug, failure), failure
	}
	if err := m.clone(ctx, slug, path); err != nil {
		// Put the corrupt clone back rather than leaving nothing: stale
		// evidence beats absent evidence, and the next attempt retries.
		_ = os.Rename(retired, path)
		return m.recordFailure(ctx, slug, err), err
	}
	if err := os.RemoveAll(retired); err != nil {
		m.log.Warn("could not remove the corrupt clone", "repository", slug, "path", retired)
	}
	m.log.Warn("replaced a corrupt managed clone", "repository", slug, "path", path)
	return m.record(m.Inspect(ctx, slug)), nil
}

func (m *Manager) ensureRoot() error {
	if err := os.MkdirAll(m.root, 0o700); err != nil {
		return err
	}
	return os.Chmod(m.root, 0o700)
}

// git runs one hermetic invocation, injecting the credential only when the
// command talks to a remote.
//
// HOME is the root rather than the clone: Responder promises never to dirty a
// work tree Coop forks from, and anything git might write to a dotfile would
// otherwise land inside one and show up in `git status`.
func (m *Manager) git(
	ctx context.Context,
	dir string,
	authenticated bool,
	args ...string,
) (string, error) {
	var env []string
	if authenticated && m.token != nil {
		token, err := m.token(ctx)
		if err == nil && strings.TrimSpace(token) != "" {
			env = hermeticgit.AuthEnv(token)
		}
	}
	return hermeticgit.Run(ctx, dir, m.root, env, nil, args...)
}

func (m *Manager) revision(ctx context.Context, path string) string {
	output, err := m.git(ctx, path, false, "rev-parse", "--verify", "--end-of-options", "HEAD")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(output)
}

// branch is the branch a fast-forward should target: the clone's own checked
// out branch, falling back to whatever the remote calls its default.
func (m *Manager) branch(ctx context.Context, path string) string {
	if output, err := m.git(ctx, path, false, "symbolic-ref", "--short", "--quiet", "HEAD"); err == nil {
		if branch := strings.TrimSpace(output); branch != "" {
			return branch
		}
	}
	output, err := m.git(
		ctx, path, false, "symbolic-ref", "--short", "--quiet", "refs/remotes/origin/HEAD",
	)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(output), "origin/"))
}

// fetchedAt is when the remote was last asked.
//
// From FETCH_HEAD's mtime, which git rewrites on every fetch and on clone
// whether or not an object moved. Read from the filesystem rather than
// remembered in this process so `responder doctor`, which runs beside a serving
// instance and cannot see its memory, answers the same question.
func fetchedAt(path string) time.Time {
	for _, name := range []string{"FETCH_HEAD", "HEAD"} {
		if info, err := os.Stat(filepath.Join(path, ".git", name)); err == nil {
			return info.ModTime().UTC()
		}
	}
	return time.Time{}
}

// wrap turns git's prose into a class. The order matters: an authentication
// failure and a missing private repository both mention the URL, and "could not
// read Username" is what a credential-less clone of a private repository says.
func (m *Manager) wrap(slug string, err error) *Error {
	detail := strings.TrimSpace(err.Error())
	lower := strings.ToLower(detail)
	contains := func(needles ...string) bool {
		for _, needle := range needles {
			if strings.Contains(lower, needle) {
				return true
			}
		}
		return false
	}
	switch {
	case contains(
		"authentication failed", "could not read username", "could not read password",
		"invalid username or password", "terminal prompts disabled", "permission denied",
		"403 forbidden", "401 unauthorized", "bad credentials",
	):
		return &Error{Class: FailureAuth, Slug: slug, Detail: detail}
	case contains(
		"repository not found", "does not appear to be a git repository", "404 not found",
		"remote branch", "couldn't find remote ref", "not found",
	):
		return &Error{Class: FailureMissing, Slug: slug, Detail: detail}
	case contains(
		"bad object", "object file", "loose object", "did not send all necessary objects",
		"unable to read tree", "corrupt", "index file smaller than expected",
		"not a git repository", "broken link",
	):
		return &Error{Class: FailureCorrupt, Slug: slug, Detail: detail}
	default:
		return &Error{Class: FailureNetwork, Slug: slug, Detail: detail}
	}
}
