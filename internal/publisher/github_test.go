package publisher

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AndrewDryga/responder/internal/config"
	"github.com/AndrewDryga/responder/internal/coop"
	"github.com/AndrewDryga/responder/internal/core"
)

func TestPublishCreatesExactReviewedTreeAndDraftPR(t *testing.T) {
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
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			t.Errorf("missing GitHub authorization")
		}
		switch {
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/pulls"):
			_, _ = w.Write([]byte("[]"))
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/pulls"):
			if err := json.NewDecoder(r.Body).Decode(&created); err != nil {
				t.Error(err)
			}
			_, _ = w.Write([]byte(`{
				"number": 41,
				"html_url": "https://github.example/pull/41",
				"draft": true,
				"head": {"ref": "ignored"}
			}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	t.Setenv("TEST_GITHUB_TOKEN", "test-token")

	client := New(config.GitHubConfig{
		Enabled: true, APIURL: server.URL, TokenEnv: "TEST_GITHUB_TOKEN",
		BranchPrefix: "responder", CommitName: "Responder",
		CommitEmail: "responder@example.com",
	})
	client.remoteURL = func(string) string { return remote }
	incident := core.Incident{
		ID: "inc_1234567890abcdef", Title: "Update runtime packs",
		CoopSessionID: "remote_1", CreatedAt: time.Unix(1_700_000_000, 0).UTC(),
	}
	result, err := client.Publish(context.Background(), Request{
		StateDir: t.TempDir(),
		Incident: incident,
		Repository: config.Repository{
			Path: source, GitHubRepository: "owner/repository", GitHubBaseBranch: "main",
		},
		Review: coop.Review{
			OperationID: "op_review", ParentHead: parent, CandidateTree: tree,
			Patch: []byte(patch), Publishable: true, Gate: "passed", Rebase: "clean",
		},
	})
	if err != nil {
		t.Fatal(err)
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
		BranchPrefix: "responder",
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
	if err != nil || second != first || first != "responder/update-runtime-packs-7890abcdef" {
		t.Fatalf("planned branches = %q, %q, %v", first, second, err)
	}
	durable := "responder/existing-reviewed-branch"
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
				"ref": "responder/change-123",
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
		HeadBranch: "responder/change-123", RemoteSHA: sha,
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
