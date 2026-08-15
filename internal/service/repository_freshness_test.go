package service

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/core"
	"github.com/AndrewDryga/responder/internal/hermeticgit"
	"github.com/AndrewDryga/responder/internal/repomirror"
	"github.com/AndrewDryga/responder/internal/slackui"
	"github.com/AndrewDryga/responder/internal/store"
)

// managedSlugConfig is serviceConfig's repository declared by slug instead of
// path, so the turn runs against a clone Responder owns.
func managedSlugConfig(t *testing.T) config.Config {
	t.Helper()
	root := t.TempDir()
	path := filepath.Join(root, "responder.yaml")
	body := `version: 1
state_dir: ` + filepath.Join(root, "state") + `
slack:
  team_id: T123ABC
  default_repository: repo
  operators: [U123ABC]
  invite_users: [U123ABC]
  watch_settle_delay: 0s
coop: {}
limits:
  engineering_task_creation_cooldown: 0s
  repository_fetch_interval: 1m
repositories:
  repo:
    display_name: Repository
    coop_policy: repo-observe
    contributor_policy: repo-contributor
    github: example/repo
webhooks:
  grafana:
    kind: grafana
    auth: bearer
    secret_env: GRAFANA_TOKEN
    repository: repo
`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

// fixtureOrigin is a local repository with one commit, standing in for GitHub.
// No network and no credential: what is being proven is the host's handling of
// a git result, and a test that needs a token is a test that stops running.
func fixtureOrigin(t *testing.T) string {
	t.Helper()
	path := t.TempDir()
	mustGit(t, path, "init", "--quiet", "--initial-branch=main")
	if err := os.WriteFile(filepath.Join(path, "README.md"), []byte("first\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	mustGit(t, path, "add", "README.md")
	mustGitEnv(t, path, []string{
		"GIT_AUTHOR_NAME=Fixture", "GIT_AUTHOR_EMAIL=fixture@example.test",
		"GIT_COMMITTER_NAME=Fixture", "GIT_COMMITTER_EMAIL=fixture@example.test",
		"GIT_AUTHOR_DATE=2026-08-14T00:00:00Z", "GIT_COMMITTER_DATE=2026-08-14T00:00:00Z",
	}, "commit", "--quiet", "-m", "first commit")
	return path
}

func mustGit(t *testing.T, path string, args ...string) string {
	t.Helper()
	return mustGitEnv(t, path, nil, args...)
}

func mustGitEnv(t *testing.T, path string, env []string, args ...string) string {
	t.Helper()
	output, err := hermeticgit.Run(context.Background(), path, path, env, nil, args...)
	if err != nil {
		t.Fatalf("git %v: %v", args, err)
	}
	return output
}

// runTriageTurnAgainst drives one Slack mention to a finished run and returns
// the repository reference from the attempt's context manifest.
func runTriageTurnAgainst(
	t *testing.T,
	cfg config.Config,
	remote string,
	inputID string,
	before func(*Service),
) core.ContextReference {
	t.Helper()
	ctx := context.Background()
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	coopClient := newFakeCoop()
	coopClient.completeOnSubmit = `{
		"action":"reply",
		"operations":[{"id":"complete","type":"complete_episode","completion":{
			"message":"The API is healthy.",
			"completion":{"status":"decision_ready","summary":"the API is healthy"}}}]
	}`
	svc := New(cfg, st, coopClient, &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.identity = slackui.Identity{
		TeamID: cfg.Slack.TeamID, BotUserID: "U999BOT", BotID: "B999BOT",
	}
	// The one thing the real service does differently: its clones come from
	// github.com. Everything else on this path is the shipped code.
	svc.Mirrors = repomirror.New(cfg, nil, repomirror.WithRemoteURL(
		func(string) string { return remote },
	))
	if before != nil {
		before(svc)
	}
	if created, err := st.AdmitSlackInput(ctx, core.SlackInput{
		ID: inputID, EnvelopeID: "env_" + inputID, EventID: "Ev" + inputID,
		Kind: "mention", TeamID: cfg.Slack.TeamID, ChannelID: "COPS",
		MessageTS: "1700.300", UserID: cfg.Slack.Operators[0],
		Text: "<@U999BOT> is the API healthy?",
	}); err != nil || !created {
		t.Fatalf("admit mention = %t, %v", created, err)
	}
	if err := svc.processSlackInput(ctx); err != nil {
		t.Fatal(err)
	}
	finishQueuedAgentRun(t, ctx, svc)

	run, err := st.GetAgentRunBySource(ctx, "watch", inputID)
	if err != nil {
		t.Fatalf("load the agent run: %v", err)
	}
	if run.State != core.AgentRunCompleted {
		t.Fatalf("the turn did not complete: state %q, %s", run.State, run.LastError)
	}
	manifest, err := st.GetLatestContextManifest(ctx, run.EpisodeID)
	if err != nil {
		t.Fatalf("load the attempt context manifest: %v", err)
	}
	for _, reference := range manifest.References {
		if reference.Kind == "repository" {
			return reference
		}
	}
	t.Fatalf("the manifest recorded no repository reference: %+v", manifest.References)
	return core.ContextReference{}
}

// A turn records how old the code it read was.
//
// The manifest has always carried the revision Coop forked from, and a
// revision alone answers nothing: a commit id looks equally current whether the
// checkout behind it was refreshed a minute ago or last month. Until Responder
// owned the clone nothing knew which — there was no `git fetch` anywhere in
// this product — so "how old was the code the model read" was unanswerable on
// every trace ever recorded.
func TestATurnRecordsTheAgeOfTheCodeItRead(t *testing.T) {
	cfg := managedSlugConfig(t)
	remote := fixtureOrigin(t)
	head := strings.TrimSpace(mustGit(t, remote, "rev-parse", "HEAD"))

	reference := runTriageTurnAgainst(t, cfg, remote, "slack_fresh", nil)
	metadata := reference.Metadata
	if metadata["mirror_freshness"] != "fresh" {
		t.Fatalf("a clone fetched during this turn was recorded as %q: %+v",
			metadata["mirror_freshness"], metadata)
	}
	if metadata["mirror_revision"] != head {
		t.Fatalf("recorded revision %q, want the remote's head %q",
			metadata["mirror_revision"], head)
	}
	if metadata["mirror_fetched_at"] == "" {
		t.Fatalf("the manifest does not say when the code was last fetched: %+v", metadata)
	}
	if metadata["managed_repository"] != "example/repo" {
		t.Fatalf("the manifest does not name the managed repository: %+v", metadata)
	}
	if metadata["mirror_stale_reason"] != "" {
		t.Fatalf("a successful fetch recorded a staleness reason: %+v", metadata)
	}
}

// A fetch that cannot happen degrades the turn's evidence. It does not stop the
// turn.
//
// This is the rule the whole freshness path is built around and the one worth
// holding shut. GitHub being unreachable is not Responder failing to work: an
// incident answered from older code, with the age written down, is worth more
// than an incident not answered at all. The failure has to be visible — on the
// manifest, in the gauge — and it must not reach the turn.
func TestAnUnreachableRemoteDegradesTheTurnRatherThanBlockingIt(t *testing.T) {
	cfg := managedSlugConfig(t)
	remote := fixtureOrigin(t)
	head := strings.TrimSpace(mustGit(t, remote, "rev-parse", "HEAD"))
	// A clone that exists and is old, with a remote that has gone away: the
	// shape of a token that expired or a host that stopped resolving.
	gone := filepath.Join(t.TempDir(), "no-such-remote")

	var mirrors *repomirror.Manager
	reference := runTriageTurnAgainst(t, cfg, gone, "slack_stale", func(svc *Service) {
		warm := repomirror.New(cfg, nil, repomirror.WithRemoteURL(
			func(string) string { return remote },
		))
		if _, err := warm.Ensure(context.Background(), "example/repo"); err != nil {
			t.Fatalf("seed the clone: %v", err)
		}
		clone, err := repomirror.Path(repomirror.Root(cfg.StateDir), "example/repo")
		if err != nil {
			t.Fatal(err)
		}
		// A clone remembers the remote it came from, so taking the remote away
		// means changing the clone's own origin — which is what an expired
		// token or a host that stopped resolving looks like from in here.
		mustGit(t, clone, "remote", "set-url", "origin", gone)
		// And age it past the fetch interval, so the prepare path tries at all
		// rather than finding it warm and skipping.
		ageClone(t, clone)
		mirrors = svc.Mirrors
	})

	metadata := reference.Metadata
	if metadata["mirror_freshness"] != "stale" {
		t.Fatalf("a turn that could not fetch recorded freshness %q: %+v",
			metadata["mirror_freshness"], metadata)
	}
	if metadata["mirror_stale_reason"] == "" {
		t.Fatalf("the manifest does not say why the code was stale: %+v", metadata)
	}
	// Still the revision that is actually on disk. A degraded turn reads real
	// code, and the manifest names the exact commit it read.
	if metadata["mirror_revision"] != head {
		t.Fatalf("recorded revision %q, want the revision on disk %q",
			metadata["mirror_revision"], head)
	}
	// And the failure is countable, which is what /metrics reads.
	if mirrors == nil || mirrors.FetchFailures() != 1 {
		t.Fatalf("the failed fetch was not counted for the gauge")
	}
}

// A repository nobody declared by slug records nothing at all, rather than
// recording a confident "fresh" about a directory Responder does not own and
// has never fetched.
func TestAnOperatorMaintainedCheckoutClaimsNoFreshness(t *testing.T) {
	cfg := serviceConfig(t)
	reference := runTriageTurnAgainst(t, cfg, t.TempDir(), "slack_unmanaged", nil)
	for key, value := range reference.Metadata {
		if strings.HasPrefix(key, "mirror_") || key == "managed_repository" {
			t.Fatalf("an unmanaged repository claimed %s = %q", key, value)
		}
	}
}

// The scheduled sweep spends its budget only on repositories that need it.
//
// The whole work item runs under limits.worker_stall_after — two minutes by
// default — and a git fetch of a large repository over a slow link is not fast.
// A sweep that fetched every repository in configured order every cycle would
// spend that budget on the first few and be cut off before the rest, every
// time, so on the thirteen-repository deployment the end of the list would be
// permanently stale with nothing anywhere saying so. Skipping what is already
// current is what makes each cycle continue rather than repeat, and it costs one
// stat of a file to decide.
func TestTheScheduledSweepSkipsRepositoriesThatAreAlreadyCurrent(t *testing.T) {
	cfg := managedSlugConfig(t)
	cfg.Repositories = map[string]config.Repository{
		"first":  {CoopPolicy: "first-observe", GitHub: "example/aaa"},
		"second": {CoopPolicy: "second-observe", GitHub: "example/bbb"},
	}
	remote := fixtureOrigin(t)
	st, err := store.Open(cfg.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	svc := New(cfg, st, newFakeCoop(), &fakeSlack{}, nil, slackui.NewSanitizer(12000), nil)
	svc.Mirrors = repomirror.New(cfg, nil, repomirror.WithRemoteURL(
		func(string) string { return remote },
	))
	ctx := context.Background()

	// One sweep clones both. Every managed repository is stale until it exists.
	svc.fetchManagedRepositories(ctx)
	for _, slug := range []string{"example/aaa", "example/bbb"} {
		if status := svc.Mirrors.Inspect(ctx, slug); !status.Present {
			t.Fatalf("%s was not cloned by the first sweep: %+v", slug, status)
		}
	}

	// Age one of them, and only that one may be touched by the next sweep.
	// FETCH_HEAD's mtime is the observation: git rewrites it on every fetch,
	// whether or not an object moved.
	fresh := lastFetch(t, cfg, "example/aaa")
	staleClone, err := repomirror.Path(repomirror.Root(cfg.StateDir), "example/bbb")
	if err != nil {
		t.Fatal(err)
	}
	ageClone(t, staleClone)

	svc.fetchManagedRepositories(ctx)

	if after := lastFetch(t, cfg, "example/aaa"); !after.Equal(fresh) {
		t.Fatalf(
			"the sweep re-fetched a repository that was already current; with a slow " +
				"repository at the top of the list, that is the whole budget spent before " +
				"the stale ones are reached",
		)
	}
	if status := svc.Mirrors.Inspect(ctx, "example/bbb"); status.Stale {
		t.Fatalf("the sweep left the stale repository stale: %+v", status)
	}
}

// lastFetch is when git last wrote the clone's fetch marker.
func lastFetch(t *testing.T, cfg config.Config, slug string) time.Time {
	t.Helper()
	clone, err := repomirror.Path(repomirror.Root(cfg.StateDir), slug)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"FETCH_HEAD", "HEAD"} {
		if info, err := os.Stat(filepath.Join(clone, ".git", name)); err == nil {
			return info.ModTime()
		}
	}
	t.Fatalf("%s has no fetch marker", slug)
	return time.Time{}
}

// ageClone backdates the fetch marker so the clone reads as stale without a
// test waiting out the interval.
func ageClone(t *testing.T, clone string) {
	t.Helper()
	old := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	for _, name := range []string{"FETCH_HEAD", "HEAD"} {
		path := filepath.Join(clone, ".git", name)
		if _, err := os.Stat(path); err != nil {
			continue
		}
		if err := os.Chtimes(path, old, old); err != nil {
			t.Fatal(err)
		}
	}
}
