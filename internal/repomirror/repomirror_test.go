package repomirror

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/hermeticgit"
)

// Every test here clones from a local fixture repository built by the git CLI.
// No network, no token, no GitHub: the failures worth pinning are the host's
// handling of a git result, and a test that needs a credential is a test that
// stops running.

const originSlug = "example/backend"

// origin builds a fixture repository with one commit on `main` and returns its
// path, ready to be cloned from as if it were a remote.
func origin(t *testing.T) string {
	t.Helper()
	path := t.TempDir()
	run(t, path, "init", "--quiet", "--initial-branch=main")
	commit(t, path, "README.md", "first\n", "first commit")
	return path
}

func commit(t *testing.T, path, name, body, message string) string {
	t.Helper()
	if err := os.WriteFile(filepath.Join(path, name), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	run(t, path, "add", name)
	runEnv(t, path, []string{
		"GIT_AUTHOR_NAME=Fixture", "GIT_AUTHOR_EMAIL=fixture@example.test",
		"GIT_COMMITTER_NAME=Fixture", "GIT_COMMITTER_EMAIL=fixture@example.test",
		"GIT_AUTHOR_DATE=2026-08-14T00:00:00Z", "GIT_COMMITTER_DATE=2026-08-14T00:00:00Z",
	}, "commit", "--quiet", "-m", message)
	return strings.TrimSpace(run(t, path, "rev-parse", "HEAD"))
}

func run(t *testing.T, path string, args ...string) string {
	t.Helper()
	return runEnv(t, path, nil, args...)
}

func runEnv(t *testing.T, path string, env []string, args ...string) string {
	t.Helper()
	output, err := hermeticgit.Run(context.Background(), path, path, env, nil, args...)
	if err != nil {
		t.Fatalf("git %v: %v", args, err)
	}
	return output
}

// manager builds a Manager rooted in a fresh state directory, cloning from
// remote instead of github.com.
func manager(t *testing.T, remote string, opts ...Option) *Manager {
	t.Helper()
	cfg := config.Config{StateDir: t.TempDir()}
	cfg.Limits.RepositoryFetchInterval = config.Duration{Duration: 15 * time.Minute}
	options := append([]Option{
		WithRemoteURL(func(string) string { return remote }),
		// A token source that would be a real credential if anything asked for
		// one. Nothing in these tests may reach a remote that could use it.
		WithToken(func(context.Context) (string, error) { return "ghp_fake_token_for_tests", nil }),
	}, opts...)
	return New(cfg, nil, options...)
}

// A repository declared by slug is cloned the first time it is needed and is
// fetched, not re-cloned, afterwards.
//
// This is the defect the package exists for: there was no `git fetch` anywhere
// in Responder, so "current repository content" — second in the evidence
// hierarchy, above config and confirmed memory — meant whatever a human last
// pulled.
func TestASlugRepositoryIsClonedOnceAndFetchedAfterwards(t *testing.T) {
	remote := origin(t)
	m := manager(t, remote)
	ctx := context.Background()

	first, err := m.Ensure(ctx, originSlug)
	if err != nil {
		t.Fatalf("first clone: %v", err)
	}
	if !first.Present || first.Revision == "" {
		t.Fatalf("first clone = %+v", first)
	}
	marker := filepath.Join(first.Path, ".responder-clone-identity")
	if err := os.WriteFile(marker, []byte("same directory"), 0o600); err != nil {
		t.Fatal(err)
	}

	head := commit(t, remote, "second.md", "second\n", "second commit")
	updated, err := m.Update(ctx, originSlug)
	if err != nil {
		t.Fatalf("update: %v", err)
	}
	if updated.Revision != head {
		t.Fatalf("clone is at %s, remote is at %s", updated.Revision, head)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatal("the clone was replaced rather than fetched; a re-clone per turn is not an update")
	}
	if updated.Failure != FailureNone {
		t.Fatalf("a successful update recorded failure %q: %s", updated.Failure, updated.Detail)
	}
	if m.FetchFailures() != 0 {
		t.Fatalf("fetch failures = %d after a clean update", m.FetchFailures())
	}
}

// Fetching twice with nothing to fetch is not a failure and is not a change.
func TestAnUpdateWithNothingNewIsNotAFailure(t *testing.T) {
	remote := origin(t)
	m := manager(t, remote)
	ctx := context.Background()

	first, err := m.Update(ctx, originSlug)
	if err != nil {
		t.Fatalf("first update: %v", err)
	}
	second, err := m.Update(ctx, originSlug)
	if err != nil {
		t.Fatalf("second update: %v", err)
	}
	if first.Revision != second.Revision {
		t.Fatalf("revision moved with no new commits: %s -> %s", first.Revision, second.Revision)
	}
	if second.Failure != FailureNone || m.FetchFailures() != 0 {
		t.Fatalf("an idempotent update recorded a failure: %+v", second)
	}
}

// Responder never modifies the work tree Coop forks from.
//
// A managed clone should never be dirty, but if it is — an operator poking
// around, a half-finished repair — the answer is stale evidence that says so,
// not `reset --hard` over whatever is in there. Destroying work while trying to
// freshen it is the one outcome worse than being out of date.
func TestADirtyManagedCloneIsReportedRatherThanReset(t *testing.T) {
	remote := origin(t)
	m := manager(t, remote)
	ctx := context.Background()

	clone, err := m.Ensure(ctx, originSlug)
	if err != nil {
		t.Fatal(err)
	}
	uncommitted := filepath.Join(clone.Path, "README.md")
	if err := os.WriteFile(uncommitted, []byte("edited by someone\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	commit(t, remote, "second.md", "second\n", "second commit")

	status, err := m.Update(ctx, originSlug)
	if Classify(err) != FailureLocal {
		t.Fatalf("dirty clone update = %v (class %q), want a local failure", err, Classify(err))
	}
	if !status.Stale {
		t.Fatal("a clone that could not be updated was not reported stale")
	}
	body, readErr := os.ReadFile(uncommitted)
	if readErr != nil || string(body) != "edited by someone\n" {
		t.Fatalf("Responder overwrote the work tree: %q, %v", string(body), readErr)
	}
}

// A corrupt clone is replaced beside and swapped in, not repaired in place and
// not left broken. The path does not change, so a session policy naming it
// stays correct across the repair.
func TestACorruptCloneIsReplacedAtomicallyAtTheSamePath(t *testing.T) {
	remote := origin(t)
	m := manager(t, remote)
	ctx := context.Background()

	clone, err := m.Ensure(ctx, originSlug)
	if err != nil {
		t.Fatal(err)
	}
	before := clone.Path
	// Destroy the object database while leaving the directory looking like a
	// repository, which is what a truncated disk or an interrupted gc leaves.
	if err := os.RemoveAll(filepath.Join(clone.Path, ".git", "objects")); err != nil {
		t.Fatal(err)
	}

	repaired, err := m.Update(ctx, originSlug)
	if err != nil {
		t.Fatalf("a corrupt clone was not repaired: %v", err)
	}
	if repaired.Path != before {
		t.Fatalf("the repaired clone moved: %s -> %s", before, repaired.Path)
	}
	if !repaired.Present || repaired.Revision == "" {
		t.Fatalf("repaired clone = %+v", repaired)
	}
	if repaired.Failure != FailureNone {
		t.Fatalf("a repaired clone still reports failure %q: %s", repaired.Failure, repaired.Detail)
	}
	entries, err := os.ReadDir(filepath.Dir(before))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.Contains(entry.Name(), ".corrupt-") {
			t.Fatalf("the retired corrupt clone was left behind: %s", entry.Name())
		}
	}
}

// A remote that is not there, a credential that does not work, and a host that
// cannot be reached need three different responses — a configuration fix, a
// person signing in, and waiting. Reporting them all as "fetch failed" is how
// an expired token spends a week looking like a network blip.
func TestFetchFailuresAreClassifiedByWhatWouldFixThem(t *testing.T) {
	for name, testCase := range map[string]struct {
		detail string
		want   FailureClass
	}{
		"a credential that is refused": {
			detail: "git clone: remote: Invalid username or password.\nfatal: Authentication failed for 'https://github.com/example/backend.git/'",
			want:   FailureAuth,
		},
		"a private repository with no credential": {
			detail: "git clone: fatal: could not read Username for 'https://github.com': terminal prompts disabled",
			want:   FailureAuth,
		},
		"a repository that does not exist": {
			detail: "git clone: remote: Repository not found.\nfatal: repository 'https://github.com/example/backend.git/' not found",
			want:   FailureMissing,
		},
		"a host that cannot be reached": {
			detail: "git fetch: fatal: unable to access 'https://github.com/example/backend.git/': Could not resolve host: github.com",
			want:   FailureNetwork,
		},
		"a connection that dies mid-transfer": {
			detail: "git fetch: fatal: the remote end hung up unexpectedly\nfatal: early EOF",
			want:   FailureNetwork,
		},
		"an object database that is broken": {
			detail: "git fetch: error: object file .git/objects/ab/cdef is empty\nfatal: loose object abcdef is corrupt",
			want:   FailureCorrupt,
		},
		"a directory that is no longer a repository": {
			detail: "git fetch: fatal: not a git repository: '.git'",
			want:   FailureCorrupt,
		},
	} {
		m := manager(t, t.TempDir())
		got := m.wrap(originSlug, errors.New(testCase.detail))
		if got.Class != testCase.want {
			t.Fatalf("%s classified as %q, want %q", name, got.Class, testCase.want)
		}
		if got.Detail == "" {
			t.Fatalf("%s lost the detail an operator needs", name)
		}
	}
}

// A remote that is unreachable leaves the previous clone in place and readable.
// A turn must still run against stale code rather than no code.
func TestAnUnreachableRemoteLeavesTheCloneReadableAndRecordsStaleness(t *testing.T) {
	remote := origin(t)
	m := manager(t, remote)
	ctx := context.Background()

	clone, err := m.Ensure(ctx, originSlug)
	if err != nil {
		t.Fatal(err)
	}
	revision := clone.Revision
	// Point the clone's origin at a directory that is not a repository, which
	// is what an unreachable remote looks like to git locally.
	if _, err := hermeticgit.Run(
		ctx, clone.Path, clone.Path, nil, nil,
		"remote", "set-url", "origin", filepath.Join(t.TempDir(), "gone"),
	); err != nil {
		t.Fatal(err)
	}

	status, err := m.Update(ctx, originSlug)
	if err == nil {
		t.Fatal("an unreachable remote reported success")
	}
	if !status.Present || status.Revision != revision {
		t.Fatalf("the clone stopped being readable after a failed fetch: %+v", status)
	}
	if !status.Stale || status.Failure == FailureNone {
		t.Fatalf("a failed fetch was not recorded as staleness: %+v", status)
	}
	if m.FetchFailures() != 1 {
		t.Fatalf("fetch failures = %d, want the one repository that failed", m.FetchFailures())
	}
	// And the failure clears when the remote comes back, so the gauge tracks
	// now rather than ever.
	if _, err := hermeticgit.Run(
		ctx, clone.Path, clone.Path, nil, nil, "remote", "set-url", "origin", remote,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Update(ctx, originSlug); err != nil {
		t.Fatalf("recovery update: %v", err)
	}
	if m.FetchFailures() != 0 {
		t.Fatalf("fetch failures = %d after recovery", m.FetchFailures())
	}
}

// A slug becomes a directory under the state directory and nothing else. This
// is the only place in the product that turns a repository name into a path, so
// it is the only place a traversal could turn into one.
func TestASlugOnlyEverBecomesADirectoryUnderTheRoot(t *testing.T) {
	root := "/var/lib/responder/repos"
	if path, err := Path(root, "example/backend"); err != nil ||
		path != filepath.Join(root, "example", "backend") {
		t.Fatalf("path = %q, %v", path, err)
	}
	for _, slug := range []string{
		"../../etc/passwd", "example/../../etc", "/etc/passwd", "example",
		"example/backend/extra", "github.com/example/backend", "", "example/..",
		"../example/backend", ".",
	} {
		if path, err := Path(root, slug); err == nil {
			t.Fatalf("slug %q became %q", slug, path)
		}
	}
}

// The policy path for a managed repository is resolved through symlinks.
//
// Coop's session service compares a policy's repository against `rev-parse
// --show-toplevel` on the EvalSymlinks-real path and rejects anything else, so
// a policy naming an aliased path fails at session creation with a message that
// mentions neither the alias nor the policy. On macOS this is not hypothetical:
// /var is a symlink to /private/var.
func TestAManagedRepositoryPolicyPathIsTheRealPath(t *testing.T) {
	state := t.TempDir()
	repository := config.Repository{GitHub: originSlug}
	target, err := Path(Root(state), originSlug)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(target, 0o700); err != nil {
		t.Fatal(err)
	}
	// Reach the same clone through an alias, the way a state directory under a
	// symlinked home or /var would.
	alias := filepath.Join(t.TempDir(), "alias")
	if err := os.Symlink(state, alias); err != nil {
		t.Skipf("symlinks are unavailable: %v", err)
	}
	path, err := RepositoryPath(alias, repository)
	if err != nil {
		t.Fatal(err)
	}
	real, err := filepath.EvalSymlinks(target)
	if err != nil {
		t.Fatal(err)
	}
	if path != real {
		t.Fatalf("policy path = %q, want the real path %q", path, real)
	}

	// An operator-maintained repository keeps the path it was configured with.
	configured := config.Repository{Path: "/srv/repos/backend"}
	if path, err := RepositoryPath(state, configured); err != nil || path != "/srv/repos/backend" {
		t.Fatalf("configured path = %q, %v", path, err)
	}
}

// Freshness is read from the clone, not remembered in this process, so a second
// process — `responder doctor` beside a serving instance — answers the same
// question rather than reporting everything as never fetched.
func TestFreshnessIsReadableFromASecondProcess(t *testing.T) {
	remote := origin(t)
	m := manager(t, remote)
	ctx := context.Background()

	if _, err := m.Update(ctx, originSlug); err != nil {
		t.Fatal(err)
	}
	// A different Manager over the same root is what doctor holds.
	cfg := config.Config{StateDir: filepath.Dir(m.root)}
	cfg.Limits.RepositoryFetchInterval = config.Duration{Duration: 15 * time.Minute}
	other := New(cfg, nil, WithRemoteURL(func(string) string { return remote }))
	status := other.Inspect(ctx, originSlug)
	if !status.Present || status.Revision == "" {
		t.Fatalf("a second process could not read the clone: %+v", status)
	}
	if status.FetchedAt.IsZero() {
		t.Fatal("a second process could not tell when the clone was last fetched")
	}
	if status.Stale {
		t.Fatalf("a clone fetched moments ago read as stale from another process: %+v", status)
	}
}

// Staleness is a clock question, and the clock is injected so the answer is not
// "wait fifteen minutes" in a test.
func TestACloneGoesStaleOnceItsIntervalHasPassed(t *testing.T) {
	remote := origin(t)
	// Anchored to the real clock, because the fetch time is a file's mtime and
	// a wholly invented "now" would sit before every clone ever made.
	now := time.Now().UTC()
	m := manager(t, remote, WithClock(func() time.Time { return now }))
	ctx := context.Background()

	status, err := m.Update(ctx, originSlug)
	if err != nil {
		t.Fatal(err)
	}
	if status.Stale {
		t.Fatalf("a clone fetched at the current instant read as stale: %+v", status)
	}
	now = now.Add(16 * time.Minute)
	if fresh := m.Inspect(ctx, originSlug); !fresh.Stale {
		t.Fatalf("a clone unfetched for longer than the interval read as fresh: %+v", fresh)
	}
	// A repository with no clone at all is stale, not fresh. An absent clone
	// reading as current is how "no evidence" becomes "no problem".
	if missing := m.Inspect(ctx, "example/never-cloned"); !missing.Stale || missing.Present {
		t.Fatalf("an absent clone = %+v", missing)
	}
}

// The clone directory tree is owner-private. It holds the working copy of every
// private repository this deployment reads.
func TestManagedClonesAreOwnerPrivate(t *testing.T) {
	remote := origin(t)
	m := manager(t, remote)
	if _, err := m.Ensure(context.Background(), originSlug); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{m.root, filepath.Join(m.root, "example")} {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if mode := info.Mode().Perm(); mode&0o077 != 0 {
			t.Fatalf("%s has mode %o; group and other must have nothing", path, mode)
		}
	}
}

// Managed repositories are collected from the configuration and nowhere else,
// deduplicated, so two repository contexts over one slug are cloned once.
func TestManagedSlugsComeOnlyFromConfiguration(t *testing.T) {
	cfg := config.Config{
		Repositories: map[string]config.Repository{
			"backend":  {GitHub: "example/backend", CoopPolicy: "backend-observe"},
			"frontend": {GitHub: "example/frontend", CoopPolicy: "frontend-observe"},
			"legacy":   {Path: "/srv/repos/legacy", CoopPolicy: "legacy-observe"},
		},
		RepositorySets: map[string]config.RepositorySet{
			"platform": {Primary: "backend", CoopPolicy: "platform-observe"},
		},
	}
	got := Slugs(cfg)
	want := []string{"example/backend", "example/frontend"}
	if len(got) != len(want) {
		t.Fatalf("managed slugs = %v, want %v", got, want)
	}
	for index := range want {
		if got[index] != want[index] {
			t.Fatalf("managed slugs = %v, want %v", got, want)
		}
	}
}
