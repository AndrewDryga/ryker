package publisher

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/ryker/internal/config"
	"github.com/AndrewDryga/ryker/internal/coop"
	"github.com/AndrewDryga/ryker/internal/core"
)

func TestPublishRecoversAfterPullRequestCreationResponseIsLost(t *testing.T) {
	source := filepath.Join(t.TempDir(), "source")
	mustGit(t, "", "init", "-q", "-b", "main", source)
	mustWrite(t, filepath.Join(source, "README.md"), "before\n")
	mustGit(t, source, "add", "README.md")
	mustGitEnv(t, source, []string{
		"GIT_AUTHOR_NAME=Test", "GIT_AUTHOR_EMAIL=test@example.com",
		"GIT_COMMITTER_NAME=Test", "GIT_COMMITTER_EMAIL=test@example.com",
	}, "commit", "-q", "-m", "base")
	parent := strings.TrimSpace(mustGit(t, source, "rev-parse", "HEAD"))
	mustWrite(t, filepath.Join(source, "README.md"), "after\n")
	patch := mustGit(t, source, "diff", "--binary", "HEAD")
	mustGit(t, source, "add", "README.md")
	tree := strings.TrimSpace(mustGit(t, source, "write-tree"))
	mustGit(t, source, "reset", "-q", "--hard", "HEAD")

	remote := filepath.Join(t.TempDir(), "remote.git")
	mustGit(t, "", "init", "-q", "--bare", remote)
	var created map[string]any
	prCreated := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			t.Errorf("missing GitHub authorization")
		}
		switch {
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/pulls"):
			if prCreated {
				_, _ = w.Write([]byte(`[{
					"number":41,"html_url":"https://github.example/pull/41",
					"draft":true,"head":{"ref":"ryker/inc-1234567890abcdef"}
				}]`))
			} else {
				_, _ = w.Write([]byte("[]"))
			}
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/pulls"):
			if err := json.NewDecoder(r.Body).Decode(&created); err != nil {
				t.Error(err)
			}
			prCreated = true
			http.Error(w, "response lost", http.StatusInternalServerError)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	t.Setenv("TEST_GITHUB_TOKEN", "test-token")

	client := New(config.GitHubConfig{
		Enabled: true, APIURL: server.URL, TokenEnv: "TEST_GITHUB_TOKEN",
		BranchPrefix: "ryker", CommitName: "Ryker",
		CommitEmail: "ryker@example.com",
	})
	client.remoteURL = func(string) string { return remote }
	incident := core.Incident{
		ID: "inc_1234567890abcdef", Title: "Update runtime packs",
		CoopSessionID: "remote_1", CreatedAt: time.Unix(1_700_000_000, 0).UTC(),
	}
	request := Request{
		StateDir: t.TempDir(),
		Incident: incident,
		Repository: config.Repository{
			Path: source, GitHubRepository: "owner/repository", GitHubBaseBranch: "main",
		},
		Review: coop.Review{
			OperationID: "op_review", ParentHead: parent, CandidateTree: tree,
			Patch: []byte(patch), Publishable: true, Gate: "passed", Rebase: "clean",
		},
	}
	partial, err := client.Publish(context.Background(), request)
	if err == nil || partial.HeadBranch == "" || partial.RemoteSHA == "" ||
		partial.RemoteSHA != partial.CommitSHA || partial.PRNumber != 0 {
		t.Fatalf("partial publication = %+v, %v", partial, err)
	}
	request.Existing = core.Publication{
		Repository: "owner/repository", BaseBranch: "main",
		HeadBranch: partial.HeadBranch, RemoteSHA: partial.RemoteSHA,
		State: core.PublicationFailed,
	}
	result, err := client.Publish(context.Background(), request)
	if err != nil {
		t.Fatalf("retry partial publication: %v", err)
	}
	if result.PRNumber != 41 || result.PRURL != "https://github.example/pull/41" {
		t.Fatalf("unexpected publication result: %#v", result)
	}
	if created["draft"] != true || created["head"] != result.HeadBranch {
		t.Fatalf("unexpected pull request request: %#v", created)
	}
	remoteTree := strings.TrimSpace(mustGit(
		t, "", "--git-dir="+remote, "rev-parse", result.HeadBranch+"^{tree}",
	))
	if remoteTree != tree {
		t.Fatalf("published tree %s, want reviewed tree %s", remoteTree, tree)
	}
}

// PR #20 was updated successfully, but GitHub's pull-request API still returned
// the previous head during the immediate post-push check. Ryker called the
// whole publication failed even though the branch and both checks were green.
func TestExistingPullRequestUpdateSurvivesGitHubHeadLagAfterPush(t *testing.T) {
	source := filepath.Join(t.TempDir(), "source")
	mustGit(t, "", "init", "-q", "-b", "main", source)
	mustWrite(t, filepath.Join(source, "README.md"), "base\n")
	mustGit(t, source, "add", "README.md")
	mustGitEnv(t, source, []string{
		"GIT_AUTHOR_NAME=Test", "GIT_AUTHOR_EMAIL=test@example.com",
		"GIT_COMMITTER_NAME=Test", "GIT_COMMITTER_EMAIL=test@example.com",
	}, "commit", "-q", "-m", "base")
	parent := strings.TrimSpace(mustGit(t, source, "rev-parse", "HEAD"))
	mustWrite(t, filepath.Join(source, "README.md"), "updated\n")
	patch := mustGit(t, source, "diff", "--binary", "HEAD")
	mustGit(t, source, "add", "README.md")
	tree := strings.TrimSpace(mustGit(t, source, "write-tree"))
	mustGit(t, source, "reset", "-q", "--hard", "HEAD")

	remote := filepath.Join(t.TempDir(), "remote.git")
	mustGit(t, "", "init", "-q", "--bare", remote)
	mustGit(t, source, "push", "-q", remote, "HEAD:refs/heads/existing-pr")
	oldHead := strings.TrimSpace(mustGit(t, "", "--git-dir="+remote, "rev-parse", "existing-pr"))
	const prURL = "https://github.example/owner/repository/pull/514"
	prReads := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || !strings.HasSuffix(r.URL.Path, "/pulls/514") {
			t.Errorf("unexpected GitHub mutation: %s %s", r.Method, r.URL.Path)
			http.NotFound(w, r)
			return
		}
		prReads++
		head := oldHead
		if prReads > 2 {
			head = strings.TrimSpace(mustGit(t, "", "--git-dir="+remote, "rev-parse", "existing-pr"))
		}
		_, _ = fmt.Fprintf(w, `{"number":514,"html_url":%q,"state":"open","draft":false,"merged":false,"head":{"ref":"existing-pr","sha":%q},"base":{"ref":"main"}}`, prURL, head)
	}))
	defer server.Close()
	t.Setenv("TEST_GITHUB_TOKEN", "test-token")
	client := New(config.GitHubConfig{
		Enabled: true, APIURL: server.URL, TokenEnv: "TEST_GITHUB_TOKEN",
		BranchPrefix: "ryker", CommitName: "Ryker",
		CommitEmail: "ryker@example.com",
	})
	client.remoteURL = func(string) string { return remote }
	request := Request{
		StateDir: t.TempDir(),
		Incident: core.Incident{
			ID: "inc_existing", Title: "Update existing PR",
			CoopSessionID: "remote_1", CreatedAt: time.Unix(1_700_000_000, 0).UTC(),
		},
		Repository: config.Repository{
			Path: source, GitHubRepository: "owner/repository", GitHubBaseBranch: "main",
		},
		Review: coop.Review{
			OperationID: "op_review", ParentHead: parent, CandidateTree: tree,
			Patch: []byte(patch), Publishable: true, Gate: "passed", Rebase: "clean",
		},
		Existing: core.Publication{
			Repository: "owner/repository", BaseBranch: "main",
			HeadBranch: "existing-pr", RemoteSHA: oldHead,
			PRNumber: 514, PRURL: prURL,
		},
	}
	result, err := client.Publish(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if result.PRNumber != 514 || result.PRURL != prURL ||
		result.HeadBranch != "existing-pr" || result.RemoteSHA != result.CommitSHA {
		t.Fatalf("existing PR result = %+v", result)
	}
	remoteTree := strings.TrimSpace(mustGit(
		t, "", "--git-dir="+remote, "rev-parse", "existing-pr^{tree}",
	))
	if remoteTree != tree {
		t.Fatalf("updated tree = %s, want %s", remoteTree, tree)
	}
	replayed, err := client.Publish(context.Background(), request)
	if err != nil {
		t.Fatalf("retry after successful push: %v", err)
	}
	if replayed.CommitSHA != result.CommitSHA || replayed.RemoteSHA != result.RemoteSHA ||
		replayed.PRNumber != result.PRNumber {
		t.Fatalf("replayed result = %+v, want %+v", replayed, result)
	}
}

func TestPullRequestContextReadsPrivateDiffAndDiscussion(t *testing.T) {
	const repository = "theblitzapp/blitz-infra"
	const pullPath = "/repos/" + repository + "/pulls/514"
	requests := make(map[string]int)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer private-token" {
			t.Errorf("authorization = %q", r.Header.Get("Authorization"))
		}
		requests[r.URL.RequestURI()]++
		switch {
		case r.URL.Path == pullPath && r.Header.Get("Accept") == "application/vnd.github.v3.diff":
			_, _ = w.Write([]byte("diff --git a/sentry.tf b/sentry.tf\n+symbolicator = true\n"))
		case r.URL.Path == pullPath:
			_, _ = w.Write([]byte(`{
				"number":514,"html_url":"https://github.com/theblitzapp/blitz-infra/pull/514",
				"title":"Deploy Sentry Symbolicator","body":"Use MinIO for symbols.",
				"state":"open","draft":false,"merged":false,
				"changed_files":3,"additions":41,"deletions":2,
				"user":{"login":"trevin"},
				"base":{"ref":"main","sha":"base-sha","repo":{"full_name":"theblitzapp/blitz-infra"}},
				"head":{"ref":"symbolicator","sha":"head-sha","repo":{"full_name":"theblitzapp/blitz-infra"}}
			}`))
		case r.URL.Path == "/repos/"+repository+"/issues/514/comments":
			_, _ = w.Write([]byte(`[{"body":"Needs GCP connectivity.","user":{"login":"andrew"}}]`))
		case r.URL.Path == pullPath+"/reviews":
			_, _ = w.Write([]byte(`[{"body":"Check bucket permissions.","state":"CHANGES_REQUESTED","user":{"login":"reviewer"}}]`))
		case r.URL.Path == pullPath+"/comments":
			_, _ = w.Write([]byte(`[{"body":"This needs a narrower policy.","path":"sentry.tf","line":42,"side":"RIGHT","user":{"login":"reviewer"}}]`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	t.Setenv("TEST_GITHUB_TOKEN", "private-token")
	client := New(config.GitHubConfig{
		Enabled: true, APIURL: server.URL, TokenEnv: "TEST_GITHUB_TOKEN",
	})

	got, err := client.PullRequestContext(context.Background(), repository, 514)
	if err != nil {
		t.Fatal(err)
	}
	if got.Number != 514 || got.Title != "Deploy Sentry Symbolicator" ||
		got.BaseRef != "main" || got.HeadRef != "symbolicator" ||
		got.BaseRepository != repository || got.HeadRepository != repository ||
		got.ChangedFiles != 3 || !strings.Contains(got.Diff, "+symbolicator = true") {
		t.Fatalf("pull request context = %+v", got)
	}
	if len(got.Comments) != 1 || got.Comments[0].Author != "andrew" ||
		len(got.Reviews) != 1 || got.Reviews[0].State != "CHANGES_REQUESTED" ||
		len(got.ReviewComments) != 1 || got.ReviewComments[0].Path != "sentry.tf" ||
		got.ReviewComments[0].Line != 42 || len(got.Warnings) != 0 {
		t.Fatalf("pull request discussion = comments %#v reviews %#v inline %#v warnings %#v", got.Comments, got.Reviews, got.ReviewComments, got.Warnings)
	}
	for _, uri := range []string{
		pullPath,
		pullPath,
		"/repos/" + repository + "/issues/514/comments?per_page=100",
		pullPath + "/reviews?per_page=100",
		pullPath + "/comments?per_page=100",
	} {
		if requests[uri] == 0 {
			t.Fatalf("GitHub request %q was not made: %#v", uri, requests)
		}
	}
}

func TestPublishRejectsConfiguredSecretAndInvalidObjectID(t *testing.T) {
	client := New(config.GitHubConfig{Enabled: true}, "logs-test-token")
	request := Request{
		Review: coop.Review{
			ParentHead:    strings.Repeat("a", 40),
			CandidateTree: strings.Repeat("b", 40),
			Patch:         []byte("+LOGS_TOKEN=logs-test-token\n"),
			Publishable:   true,
		},
	}
	if _, err := client.Publish(context.Background(), request); err == nil ||
		!strings.Contains(err.Error(), "configured secret") {
		t.Fatalf("configured secret publication = %v", err)
	}
	request.Review.Patch = []byte("+safe=true\n")
	request.Review.ParentHead = "--upload-pack=/usr/bin/false"
	if _, err := client.Publish(context.Background(), request); err == nil ||
		!strings.Contains(err.Error(), "invalid Git object ID") {
		t.Fatalf("invalid object publication = %v", err)
	}
}

func TestHeadBranchIsDeterministicAndHonorsDurablePublicationState(t *testing.T) {
	client := New(config.GitHubConfig{
		Enabled:      true,
		BranchPrefix: "ryker",
	})
	incident := core.Incident{
		ID:    "inc_1234567890abcdef",
		Title: "Update runtime packs",
	}
	first, err := client.HeadBranch(incident, core.Publication{})
	if err != nil {
		t.Fatal(err)
	}
	second, err := client.HeadBranch(incident, core.Publication{})
	if err != nil || second != first || first != "ryker/update-runtime-packs-7890abcdef" {
		t.Fatalf("planned branches = %q, %q, %v", first, second, err)
	}
	durable := "ryker/existing-reviewed-branch"
	got, err := client.HeadBranch(
		incident,
		core.Publication{HeadBranch: durable},
	)
	if err != nil || got != durable {
		t.Fatalf("durable branch = %q, %v", got, err)
	}
	if _, err := client.HeadBranch(
		incident,
		core.Publication{HeadBranch: "--upload-pack=bad"},
	); err == nil {
		t.Fatal("unsafe durable branch was accepted")
	}
}

func TestVerifyPublicationRequiresExactCurrentPullRequestHead(t *testing.T) {
	const sha = "0123456789abcdef0123456789abcdef01234567"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/owner/repository/pulls/41" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(`{
			"number": 41,
			"html_url": "https://github.example/pull/41",
			"draft": true,
			"head": {
				"ref": "ryker/change-123",
				"sha": "` + sha + `"
			}
		}`))
	}))
	defer server.Close()
	t.Setenv("TEST_GITHUB_TOKEN", "test-token")
	client := New(config.GitHubConfig{
		Enabled: true, APIURL: server.URL, TokenEnv: "TEST_GITHUB_TOKEN",
	})
	publication := core.Publication{
		Repository: "owner/repository", PRNumber: 41,
		HeadBranch: "ryker/change-123", RemoteSHA: sha,
	}
	if err := client.VerifyPublication(context.Background(), publication); err != nil {
		t.Fatal(err)
	}
	publication.RemoteSHA = strings.Repeat("f", 40)
	if err := client.VerifyPublication(context.Background(), publication); err == nil ||
		!strings.Contains(err.Error(), "no longer preserves") {
		t.Fatalf("moved publication verification = %v", err)
	}
}

func TestPublicationStatusAggregatesChecksAndMergedState(t *testing.T) {
	const sha = "0123456789abcdef0123456789abcdef01234567"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/owner/repository/pulls/41":
			_, _ = w.Write([]byte(`{
				"number":41,"state":"closed","merged":true,"draft":false,
				"merge_commit_sha":"abcdefabcdefabcdefabcdefabcdefabcdefabcd",
				"merged_at":"2026-08-02T10:00:00Z",
				"head":{"ref":"ryker/change-123","sha":"` + sha + `"}
			}`))
		case "/repos/owner/repository/commits/" + sha + "/check-runs":
			_, _ = w.Write([]byte(`{"check_runs":[
				{"status":"completed","conclusion":"success",
				 "details_url":"https://github.com/owner/repository/actions/runs/991/job/1"},
				{"status":"completed","conclusion":"skipped",
				 "details_url":"https://github.com/owner/repository/actions/runs/991/job/2"}
			]}`))
		case "/repos/owner/repository/commits/" + sha + "/status":
			_, _ = w.Write([]byte(`{"statuses":[{"state":"success",
				"target_url":"https://github.com/owner/repository/actions/runs/991"}]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	t.Setenv("TEST_GITHUB_TOKEN", "test-token")
	client := New(config.GitHubConfig{
		Enabled: true, APIURL: server.URL, TokenEnv: "TEST_GITHUB_TOKEN",
	})
	status, err := client.PublicationStatus(context.Background(), core.Publication{
		Repository: "owner/repository", PRNumber: 41, RemoteSHA: sha,
	})
	if err != nil {
		t.Fatal(err)
	}
	if status.PRState != "merged" || status.ChecksState != "passing" ||
		status.ChecksTotal != 3 || status.ChecksPassed != 3 || status.ChecksFailed != 0 ||
		status.ChecksURL != "https://github.com/owner/repository/actions/runs/991" ||
		status.MergeSHA == "" || status.MergedAt.IsZero() {
		t.Fatalf("publication status = %+v", status)
	}
}

func TestCheckSummaryLinksOnlyOneSharedGitHubWorkflowRun(t *testing.T) {
	const sha = "0123456789abcdef0123456789abcdef01234567"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/owner/repository/commits/" + sha + "/check-runs":
			_, _ = w.Write([]byte(`{"check_runs":[
				{"status":"completed","conclusion":"success",
				 "details_url":"https://github.com/owner/repository/actions/runs/991/job/1"},
				{"status":"completed","conclusion":"success",
				 "details_url":"https://github.com/owner/repository/actions/runs/992/job/2"}
			]}`))
		case "/repos/owner/repository/commits/" + sha + "/status":
			_, _ = w.Write([]byte(`{"statuses":[]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	client := New(config.GitHubConfig{Enabled: true, APIURL: server.URL})
	summary, err := client.commitChecks(context.Background(), "token", "owner/repository", sha)
	if err != nil {
		t.Fatal(err)
	}
	if summary.total != 2 || summary.passed != 2 || summary.url != "" {
		t.Fatalf("multi-run check summary = %+v", summary)
	}
}

func mustWrite(t *testing.T, path, value string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(value), 0o600); err != nil {
		t.Fatal(err)
	}
}

func mustGit(t *testing.T, work string, args ...string) string {
	t.Helper()
	return mustGitEnv(t, work, nil, args...)
}

func mustGitEnv(t *testing.T, work string, env []string, args ...string) string {
	t.Helper()
	command := exec.Command("git", args...)
	if work != "" {
		command.Dir = work
	}
	command.Env = append(os.Environ(), env...)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v: %s", strings.Join(args, " "), err, output)
	}
	return string(output)
}
